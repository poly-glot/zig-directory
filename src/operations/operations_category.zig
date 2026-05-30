// Category CRUD + traversal helpers split from the original monolithic
// operations.zig. Public surface:
//   - createCategory   - listChildren
//   - getCategory      - getCategoryPath
//   - updateCategory   - walkAncestors
//   - deleteCategory
//   - moveCategory
//
// ChangeSet construction lives in `operations_changeset_compute.zig`.
// Link-side operations (`deleteLink`, `listLinks`) used by
// `deleteCategory` are imported from `operations_link.zig`.

const std = @import("std");
const types = @import("../types.zig");
const Database = @import("../database.zig").Database;
const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const link_mod = @import("operations_link.zig");

const OperationError = shared.OperationError;
const MAX_NAME_LEN = shared.MAX_NAME_LEN;
const MAX_SLUG_LEN = shared.MAX_SLUG_LEN;
const MAX_CATEGORY_DESC_LEN = shared.MAX_CATEGORY_DESC_LEN;

/// Create a new category under parent_id, returning the new category's id.
///
/// Builds a `category_inserted` ChangeSet and routes it through `db.commit`,
/// which encodes + WAL-appends + fsyncs + applies under `apply_mutex`. All
/// index writes (primary `categories_by_id`, secondary `cat_by_parent`,
/// slug-path B+Trees, inverted-index `categories_index_tree`, ancestor
/// count cascade, direct child_count bump on the parent, subtree_cache
/// invalidation) are performed by `applyCategoryInserted` — see `src/apply.zig`.
pub fn createCategory(
    db: *Database,
    parent_id: u64,
    name: []const u8,
    slug_str: []const u8,
    desc: []const u8,
) !u64 {
    if (name.len > MAX_NAME_LEN or
        slug_str.len > MAX_SLUG_LEN or
        desc.len > MAX_CATEGORY_DESC_LEN) return OperationError.FieldTooLong;

    // Validate parent exists if non-zero. parent_id == 0 means root.
    if (parent_id != 0) {
        if ((try getCategory(db, parent_id)) == null) return OperationError.ParentNotFound;
    }

    // Allocate a new category id via lock-free atomic increment.
    const id = db.next_category_id.fetchAdd(1, .monotonic);
    const now = std.time.timestamp();

    const cat = types.Category{
        .id = id,
        .parent_id = parent_id,
        .name = types.FixedString(64).fromSlice(name),
        .slug = types.FixedString(128).fromSlice(slug_str),
        .description = types.FixedString(1024).fromSlice(desc),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        ._pad0 = 0,
        .created_at = now,
        .updated_at = now,
    };

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeCategoryInsertChangeSet(db, cat, arena.allocator());

    try db.commit(cs);

    return id;
}

/// Retrieve a category by its id. Returns null if not found.
/// Checks the memtable first (recent writes), falls through to the
/// B+Tree. Counts are mutated only via the ancestor-cascade path through
/// the memtable, so the value returned here is authoritative.
pub fn getCategory(db: *Database, id: u64) !?types.Category {
    const key = types.encodeU64(id);
    const mt_result = db.mt_categories_by_id.get(&key);
    var tree_buf: [@sizeOf(types.Category)]u8 = undefined;
    const val = switch (mt_result) {
        .found => |v| v,
        .deleted => return null,
        .not_found => (try db.categories_by_id.search(&key, &tree_buf)) orelse return null,
    };
    if (val.len != @sizeOf(types.Category)) return OperationError.DatabaseCorrupted;
    return std.mem.bytesToValue(types.Category, val[0..@sizeOf(types.Category)]);
}

/// Update mutable fields of an existing category.
///
/// Splits on whether the slug actually changes:
///
///  * Slug unchanged (text-only edit: name and/or description) → builds a
///    `category_text_updated` ChangeSet and routes through `db.commit`,
///    which encodes + WAL-appends + fsyncs + applies under `apply_mutex`.
///    All index writes (primary `categories_by_id`, inverted-index
///    `categories_index_tree` token swap, subtree_cache invalidation) are
///    performed by `applyCategoryTextUpdated` — see `src/apply.zig`.
///
///  * Slug changed → builds a `category_renamed` ChangeSet (via
///    `computeCategoryRenameChangeSet`) and routes through `db.commit`.
///    All on-disk writes (primary `categories_by_id`, `categories_by_slug_path`
///    swap for self, slug-only maintenance, descendant slug-path rebuild,
///    subtree_cache invalidation) are performed by `applyCategoryRenamed`
///    — see `src/apply.zig`.
pub fn updateCategory(
    db: *Database,
    id: u64,
    name: ?[]const u8,
    slug_str: ?[]const u8,
    desc: ?[]const u8,
) !void {
    if (name) |n| if (n.len > MAX_NAME_LEN) return OperationError.FieldTooLong;
    if (slug_str) |s| if (s.len > MAX_SLUG_LEN) return OperationError.FieldTooLong;
    if (desc) |d| if (d.len > MAX_CATEGORY_DESC_LEN) return OperationError.FieldTooLong;

    const old_cat = (try getCategory(db, id)) orelse return OperationError.CategoryNotFound;

    // Detect a real slug change: only treat this as a rename if the
    // caller passed a slug AND it differs from the stored slug. A no-op
    // slug update (passing the same slug) routes through the cheaper
    // text-update path.
    const slug_changed = if (slug_str) |s|
        !std.mem.eql(u8, s, old_cat.slug.slice())
    else
        false;

    if (!slug_changed) {
        var new_cat = old_cat;
        if (name) |n| new_cat.name = types.FixedString(64).fromSlice(n);
        if (desc) |d| new_cat.description = types.FixedString(1024).fromSlice(d);
        new_cat.updated_at = std.time.timestamp();

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const cs = try compute.computeCategoryTextUpdateChangeSet(old_cat, new_cat, arena.allocator());

        try db.commit(cs);
        return;
    }

    // Build a category_renamed ChangeSet and route through db.commit so
    // the slug-path B+Trees swap atomically with the primary row.
    var new_cat = old_cat;
    if (name) |n| new_cat.name = types.FixedString(64).fromSlice(n);
    if (slug_str) |s| new_cat.slug = types.FixedString(128).fromSlice(s);
    if (desc) |d| new_cat.description = types.FixedString(1024).fromSlice(d);
    new_cat.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeCategoryRenameChangeSet(db, old_cat, new_cat, arena.allocator());

    try db.commit(cs);
}

/// Delete a category. Pre-condition: category has no children and no links.
///
/// Builds a `category_deleted` ChangeSet and routes it through `db.commit`,
/// which encodes + WAL-appends + fsyncs + applies under `apply_mutex`. All
/// index tombstones (primary `categories_by_id`, secondary `cat_by_parent`,
/// slug-path B+Trees, inverted-index `categories_index_tree`, ancestor
/// count cascade, parent's direct `child_count` decrement, subtree_cache
/// invalidation) are performed by `applyCategoryDeleted` — see `src/apply.zig`.
pub fn deleteCategory(db: *Database, id: u64) !void {
    // Pre-condition checks stay outside the ChangeSet path: they're caller
    // contract, not state mutations.
    if ((try getCategory(db, id)) == null) return OperationError.CategoryNotFound;

    // Reject deletion if category has children.
    var children_buf: [1]types.Category = undefined;
    const children = try listChildren(db, id, 0, 1, &children_buf);
    if (children.len > 0) return OperationError.CategoryHasChildren;

    // Delete all links in this category. deleteLink takes apply_mutex
    // itself (via db.commit), so this loop runs BEFORE our own ChangeSet
    // commit. Each deleteLink decrements link_count_subtree on every
    // ancestor — by the time the loop drains, the cat's own subtree
    // contribution to ancestors is zero.
    // Always use offset 0 because each deletion removes entries from the
    // index, so the remaining entries shift down. Incrementing offset
    // would skip entries.
    var links_buf: [64]types.Link = undefined;
    while (true) {
        const links = (try link_mod.listLinks(db, id, 0, 64, &links_buf, null, 0)).items;
        if (links.len == 0) break;
        for (links) |link| {
            try link_mod.deleteLink(db, link.id);
        }
    }

    // Re-read the cat AFTER the link cascade so the ChangeSet captures the
    // post-drain link_count_subtree (each deleteLink above drove this
    // category's count toward zero by mutating the memtable copy).
    const cat = (try getCategory(db, id)) orelse return OperationError.CategoryNotFound;

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeCategoryDeleteChangeSet(db, cat, arena.allocator());

    try db.commit(cs);
}

/// Move a category to a new parent.
///
/// Builds a `category_moved` ChangeSet (via `computeCategoryMoveChangeSet`)
/// and routes it through `db.commit`, which encodes + WAL-appends + fsyncs
/// + applies under `apply_mutex`. All on-disk writes (primary
/// `categories_by_id` parent_id flip, `cat_by_parent` swap, slug-path B+Tree
/// swap for self + descendant rebuild, both chain subtree cascades, immediate
/// parents' direct `child_count` adjustment, subtree_cache invalidation) are
/// performed by `applyCategoryMoved` — see `src/apply.zig`.
pub fn moveCategory(db: *Database, id: u64, new_parent_id: u64) !void {
    const old_cat = (try getCategory(db, id)) orelse return OperationError.CategoryNotFound;

    // Validate new parent exists.
    if (new_parent_id != 0) {
        if ((try getCategory(db, new_parent_id)) == null) return OperationError.ParentNotFound;
    }

    // Check for circular hierarchy: walk from new_parent up to root.
    // A chain longer than MAX_HIERARCHY_DEPTH is itself an error: we
    // cannot prove the absence of a cycle, so refuse rather than
    // silently allowing a potentially circular move.
    if (new_parent_id != 0) {
        const MAX_HIERARCHY_DEPTH = 256;
        var walk_id = new_parent_id;
        var depth: u32 = 0;
        while (walk_id != 0) : (depth += 1) {
            if (depth >= MAX_HIERARCHY_DEPTH) return OperationError.PathTooDeep;
            if (walk_id == id) return OperationError.CircularHierarchy;
            const walk_cat = (try getCategory(db, walk_id)) orelse break;
            walk_id = walk_cat.parent_id;
        }
    }

    if (old_cat.parent_id == new_parent_id) return; // no-op move

    // computeCategoryMoveChangeSet takes the pre-move cat and flips parent_id
    // + bumps updated_at internally (the post-move snapshot lands in the
    // ChangeSet's `.cat` field).
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeCategoryMoveChangeSet(
        db,
        old_cat,
        new_parent_id,
        arena.allocator(),
    );

    try db.commit(cs);
}

/// List child categories of a parent, with pagination.
pub fn listChildren(
    db: *Database,
    parent_id: u64,
    offset: u32,
    limit: u32,
    buf: []types.Category,
) ![]types.Category {
    // Drain memtable so range scan sees fresh data. Serialized via drain mutex.
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    // Build range prefix for cat_by_parent: all keys starting with parent_id.
    const start_key = types.ParentChildKey.encode(parent_id, 0);
    const end_key = types.ParentChildKey.encode(parent_id, std.math.maxInt(u64));

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));

    var iter = try db.cat_by_parent.rangeScan(&start_key, &end_key);
    while (try iter.next()) |entry| {
        if (skipped < offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) break;

        // The value is the encoded category id.
        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const child_id = types.decodeU64(entry.value);
        if (try getCategory(db, child_id)) |cat| {
            buf[count] = cat;
            count += 1;
        }
    }

    return buf[0..count];
}

/// Walk from a category up to root, returning the path of category ids.
/// The result is ordered from root to the given id.
pub fn getCategoryPath(db: *Database, id: u64, buf: []u64) ![]u64 {
    var path_len: usize = 0;
    var current_id = id;

    while (current_id != 0) {
        if (path_len >= buf.len) return OperationError.PathTooDeep;
        buf[path_len] = current_id;
        path_len += 1;

        const cat = (try getCategory(db, current_id)) orelse break;
        current_id = cat.parent_id;
    }

    // Reverse to get root-first order.
    if (path_len > 1) {
        std.mem.reverse(u64, buf[0..path_len]);
    }

    return buf[0..path_len];
}

/// Walk from `id` up to root, returning ancestors EXCLUDING the target itself.
/// Order: root first, target's parent last. Empty list when the target is itself
/// a root (parent_id == 0). Caller's buffer caps the depth.
pub fn walkAncestors(
    db: *Database,
    id: u64,
    buf: []types.Category,
) ![]types.Category {
    // First collect ids walking up; then reverse and look up each Category.
    var id_buf: [64]u64 = undefined;
    var depth: usize = 0;

    const cat = (try getCategory(db, id)) orelse return buf[0..0];
    var cur = cat.parent_id;
    while (cur != 0 and depth < id_buf.len) {
        id_buf[depth] = cur;
        depth += 1;
        const ancestor = (try getCategory(db, cur)) orelse break;
        cur = ancestor.parent_id;
    }
    // id_buf[0..depth] is leaf-up; reverse into the result buffer (root-first).
    if (depth > buf.len) depth = buf.len;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const aid = id_buf[depth - 1 - i];
        buf[i] = (try getCategory(db, aid)) orelse return buf[0..i];
    }
    return buf[0..depth];
}

test "createCategory cascades child_count_subtree up the chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    _ = try createCategory(db, a_id, "B", "b", "");

    const top = (try getCategory(db, top_id)).?;
    const a = (try getCategory(db, a_id)).?;
    try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree); // B
    try std.testing.expectEqual(@as(u32, 2), top.child_count_subtree); // A + B
}

test "createCategory: indexing B+Trees populated by category_inserted ChangeSet" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: top + child cat. Both pass through computeCategoryInsertChangeSet
    // → db.commit → applyCategoryInserted, which is what we're verifying here.
    const top_id = try createCategory(db, 0, "Top", "top", "");
    const child_id = try createCategory(db, top_id, "Programming", "programming", "Code stuff");

    var v_buf: [64]u8 = undefined;
    const child_id_be = types.encodeU64(child_id);

    // categories_by_slug_path: full canonical path → child_id (8-byte BE).
    const slug_path_val = (try db.categories_by_slug_path.search("top/programming", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_path_val);

    // categories_by_slug_only: leaf slug → child_id (since this is the
    // shallowest holder of "programming").
    const slug_only_val = (try db.categories_by_slug_only.search("programming", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_only_val);

    // categories_index_tree: token entries for name + slug + description.
    // Key = token_bytes || encodeU64(child_id), value empty.
    var key_buf: [128]u8 = undefined;
    const expected_tokens = [_][]const u8{ "programming", "code", "stuff" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &child_id_be);
        const found = try db.categories_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    // Parent's child_count_subtree was bumped by the cascade.
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), top.child_count_subtree);
}

test "deleteCategory cascades child_count_subtree decrement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    try deleteCategory(db, a_id);

    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.child_count_subtree);
}

test "deleteCategory: indexing B+Trees tombstoned by category_deleted ChangeSet" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // createCategory + deleteCategory: both routed through the ChangeSet
    // path, so this test covers the round-trip on the on-disk indexes.
    const top_id = try createCategory(db, 0, "Top", "top", "");
    const child_id = try createCategory(db, top_id, "Programming", "programming", "Code stuff");

    var v_buf: [64]u8 = undefined;
    const child_id_be = types.encodeU64(child_id);

    // Sanity: insert populated everything.
    try std.testing.expect((try db.categories_by_slug_path.search("top/programming", &v_buf)) != null);
    try std.testing.expect((try db.categories_by_slug_only.search("programming", &v_buf)) != null);

    try deleteCategory(db, child_id);

    // categories_by_slug_path: full canonical path entry gone.
    try std.testing.expect((try db.categories_by_slug_path.search("top/programming", &v_buf)) == null);

    // categories_by_slug_only: leaf "programming" entry gone (it pointed at
    // this cat — the only holder of that slug).
    try std.testing.expect((try db.categories_by_slug_only.search("programming", &v_buf)) == null);

    // categories_index_tree: every token entry for name/slug/desc absent.
    var key_buf: [128]u8 = undefined;
    const expected_tokens = [_][]const u8{ "programming", "code", "stuff" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &child_id_be);
        try std.testing.expect((try db.categories_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf)) == null);
    }

    // Parent's child_count_subtree back to 0 (the cascade ran).
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.child_count_subtree);
}

test "updateCategory (text): name/desc tokens swapped in categories_index_tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Create a cat then update its name + description WITHOUT touching the
    // slug. Routes through computeCategoryTextUpdateChangeSet → db.commit
    // → applyCategoryTextUpdated, which is what we're verifying.
    const top_id = try createCategory(db, 0, "Top", "top", "");
    const child_id = try createCategory(db, top_id, "Programming", "programming", "Code stuff");

    var v_buf: [64]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const child_id_be = types.encodeU64(child_id);

    // Sanity: old text-only tokens exist before the update.
    {
        const tokens = [_][]const u8{ "code", "stuff" };
        for (tokens) |tok| {
            @memcpy(key_buf[0..tok.len], tok);
            @memcpy(key_buf[tok.len..][0..8], &child_id_be);
            const found = try db.categories_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
            try std.testing.expect(found != null);
        }
    }

    // Update name + description, leaving slug "programming" untouched so we
    // exercise the text-only path (not the slug-rename path).
    try updateCategory(db, child_id, "Hacking", "programming", "Network tricks");

    // Old text-only tokens are gone for this cat.
    {
        const tokens = [_][]const u8{ "code", "stuff" };
        for (tokens) |tok| {
            @memcpy(key_buf[0..tok.len], tok);
            @memcpy(key_buf[tok.len..][0..8], &child_id_be);
            const found = try db.categories_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
            try std.testing.expect(found == null);
        }
    }

    // New text-only tokens are present.
    {
        const tokens = [_][]const u8{ "hacking", "network", "tricks" };
        for (tokens) |tok| {
            @memcpy(key_buf[0..tok.len], tok);
            @memcpy(key_buf[tok.len..][0..8], &child_id_be);
            const found = try db.categories_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
            try std.testing.expect(found != null);
        }
    }

    // The slug token persists across the swap because the slug bytes are
    // identical in old_tokens and new_tokens; the new_tokens insert
    // (overwrite-on-key) reinstates the entry the old_tokens delete
    // removed.
    {
        const tok = "programming";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &child_id_be);
        const found = try db.categories_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    // Primary reflects the new fields; slug is unchanged.
    const cat = (try getCategory(db, child_id)).?;
    try std.testing.expect(cat.name.eql("Hacking"));
    try std.testing.expect(cat.slug.eql("programming"));
    try std.testing.expect(cat.description.eql("Network tricks"));
}

test "updateCategory (slug rename): slug-path B+Trees swapped + descendants rebuilt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: top → cat (slug "old") → child (slug "leaf"). Renaming `cat`
    // exercises both the self-swap in categories_by_slug_path AND the
    // descendant rebuild path inside applyCategoryRenamed (via db.commit).
    const top_id = try createCategory(db, 0, "Top", "top", "");
    const cat_id = try createCategory(db, top_id, "Cat", "old", "");
    const child_id = try createCategory(db, cat_id, "Child", "leaf", "");

    var v_buf: [64]u8 = undefined;
    const cat_id_be = types.encodeU64(cat_id);
    const child_id_be = types.encodeU64(child_id);

    // Sanity: initial slug-path entries are present.
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_path.search("top/old", &v_buf)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &child_id_be,
        (try db.categories_by_slug_path.search("top/old/leaf", &v_buf)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_only.search("old", &v_buf)).?,
    );

    // Rename cat: "old" → "new". Routes through computeCategoryRenameChangeSet
    // → db.commit → applyCategoryRenamed.
    try updateCategory(db, cat_id, null, "new", null);

    // categories_by_slug_path: old self path gone, new self path present,
    // descendant present under the new ancestor slug.
    try std.testing.expect((try db.categories_by_slug_path.search("top/old", &v_buf)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_path.search("top/new", &v_buf)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &child_id_be,
        (try db.categories_by_slug_path.search("top/new/leaf", &v_buf)).?,
    );

    // categories_by_slug_only: old leaf-slug entry gone, new entry holds the cat.
    try std.testing.expect((try db.categories_by_slug_only.search("old", &v_buf)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_only.search("new", &v_buf)).?,
    );

    // Primary reflects the new slug.
    const got = (try getCategory(db, cat_id)).?;
    try std.testing.expect(got.slug.eql("new"));
}

test "deep chain: createCategory cascades to all ancestors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, a_id, "B", "b", "");
    _ = try createCategory(db, b_id, "C", "c", "");

    const top = (try getCategory(db, top_id)).?;
    const a = (try getCategory(db, a_id)).?;
    const b = (try getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 1), b.child_count_subtree); // C
    try std.testing.expectEqual(@as(u32, 2), a.child_count_subtree); // B + C
    try std.testing.expectEqual(@as(u32, 3), top.child_count_subtree); // A + B + C
}

test "moveCategory cascades counts in both old and new chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, a_id, "B", "b", "");
    _ = try link_mod.createLink(db, b_id, "https://x.example", "x", "");
    const c_id = try createCategory(db, top_id, "C", "c", "");

    // Pre-move state
    {
        const a = (try getCategory(db, a_id)).?;
        try std.testing.expectEqual(@as(u64, 1), a.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
        const c = (try getCategory(db, c_id)).?;
        try std.testing.expectEqual(@as(u64, 0), c.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 0), c.child_count_subtree);
    }

    try moveCategory(db, b_id, c_id);

    // Post-move state
    const a = (try getCategory(db, a_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), a.child_count_subtree);
    const c = (try getCategory(db, c_id)).?;
    try std.testing.expectEqual(@as(u64, 1), c.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), c.child_count_subtree);
    // Top unchanged (link still under it via C now).
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
}

test "moveCategory carrying multiple descendants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const x_id = try createCategory(db, top_id, "X", "x", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const a1_id = try createCategory(db, a_id, "A1", "a1", "");
    _ = try createCategory(db, a1_id, "A2", "a2", "");
    _ = try link_mod.createLink(db, a1_id, "https://1.example", "1", "");
    _ = try link_mod.createLink(db, a_id, "https://2.example", "2", "");

    // Before move:
    // A.subtree: links=2, children=2 (A1, A2)
    // X.subtree: links=0, children=0
    // Top.subtree: links=2, children=4 (X, A, A1, A2)
    {
        const a = (try getCategory(db, a_id)).?;
        try std.testing.expectEqual(@as(u64, 2), a.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 2), a.child_count_subtree);
    }

    // Move A under X.
    try moveCategory(db, a_id, x_id);

    // After move:
    // X.subtree: links=2, children=3 (A, A1, A2)
    // Top.subtree: links=2, children=4 (unchanged — same total)
    const x = (try getCategory(db, x_id)).?;
    try std.testing.expectEqual(@as(u64, 2), x.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 3), x.child_count_subtree);
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 2), top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 4), top.child_count_subtree);
}

test "moveCategory same parent is no-op for counts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    _ = try link_mod.createLink(db, a_id, "https://x.example", "x", "");

    const before = (try getCategory(db, top_id)).?.link_count_subtree;
    try moveCategory(db, a_id, top_id); // same parent
    const after = (try getCategory(db, top_id)).?.link_count_subtree;
    try std.testing.expectEqual(before, after);
}

test "moveCategory: cat_by_parent + slug-path B+Trees swapped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: top → A, top → B, A → C. Move C from A to B.
    // Expect: cat_by_parent has (B, C) not (A, C); categories_by_slug_path
    // has "top/b/c" not "top/a/c"; A.child_count_subtree decremented,
    // B.child_count_subtree incremented.
    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, top_id, "B", "b", "");
    const c_id = try createCategory(db, a_id, "C", "c", "");

    // Pre-move state — sanity: A has C as a child, B has none.
    {
        const a = (try getCategory(db, a_id)).?;
        const b = (try getCategory(db, b_id)).?;
        try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
        try std.testing.expectEqual(@as(u32, 0), b.child_count_subtree);
    }

    try moveCategory(db, c_id, b_id);

    // cat_by_parent: (A, C) absent, (B, C) present. Memtable-then-B+Tree.
    var v_buf: [64]u8 = undefined;
    {
        const old_pc_key = types.ParentChildKey.encode(a_id, c_id);
        const mt_old = db.mt_cat_by_parent.get(&old_pc_key);
        const old_present = switch (mt_old) {
            .found => true,
            .deleted => false,
            .not_found => (try db.cat_by_parent.search(&old_pc_key, &v_buf)) != null,
        };
        try std.testing.expect(!old_present);

        const new_pc_key = types.ParentChildKey.encode(b_id, c_id);
        const mt_new = db.mt_cat_by_parent.get(&new_pc_key);
        const new_present = switch (mt_new) {
            .found => true,
            .deleted => false,
            .not_found => (try db.cat_by_parent.search(&new_pc_key, &v_buf)) != null,
        };
        try std.testing.expect(new_present);
    }

    // categories_by_slug_path: "top/b/c" present, "top/a/c" absent.
    const c_id_be = types.encodeU64(c_id);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path.search("top/b/c", &v_buf)).?);
    try std.testing.expect((try db.categories_by_slug_path.search("top/a/c", &v_buf)) == null);

    // Subtree counts: A drained, B bumped. Top unchanged (C still under it).
    const a = (try getCategory(db, a_id)).?;
    const b = (try getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), b.child_count_subtree);
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 3), top.child_count_subtree);
}
