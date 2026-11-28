//! Slug paths: resolving a client path such as `top/arts/music` to a category id, and composing
//! the canonical path of a category from its parent chain. A composed path always ends with the
//! slug of its last category, and a descendant's path always starts with its root's path.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const descendants_max = @import("../subtree.zig").descendants_max;
const category = @import("operations_category.zig");
const shared = @import("operations_shared.zig");
const OperationError = shared.OperationError;
const depth_max = shared.depth_max;
const slug_len_max = shared.slug_len_max;
const slug_path_len_max = shared.slug_path_len_max;

pub fn resolve_slug_path(db: *Directory, path: []const u8) !?u64 {
    if (path.len == 0) return null;

    var value_buffer: [8]u8 = undefined;
    var maybe_id: ?u64 = null;
    var resolved_path: []const u8 = path;
    var top_buffer: [2048]u8 = undefined;

    if (try db.categories_by_slug_path().search(path, &value_buffer)) |value| {
        if (value.len == 8) maybe_id = codec.decodeU64(value[0..8]);
    }
    if (maybe_id == null and !std.mem.startsWith(u8, path, "top/")) {
        const need = "top/".len + path.len;
        if (need <= top_buffer.len) {
            @memcpy(top_buffer[0.."top/".len], "top/");
            @memcpy(top_buffer["top/".len..need], path);
            const with_top = top_buffer[0..need];
            if (try db.categories_by_slug_path().search(with_top, &value_buffer)) |value| {
                if (value.len == 8) {
                    maybe_id = codec.decodeU64(value[0..8]);
                    resolved_path = with_top;
                }
            }
        }
    }
    if (maybe_id == null and std.mem.indexOfScalar(u8, path, '/') == null) {
        if (try db.categories_by_slug_only().search(path, &value_buffer)) |value| {
            if (value.len == 8) maybe_id = codec.decodeU64(value[0..8]);
        }
    }
    const category_id = maybe_id orelse return null;
    assert(resolved_path.len >= path.len);

    // While a rename or move is still being repaired, a stale path still maps to its id, so
    // the match only counts once the canonical path agrees with the one that matched.
    if (db.slug_path_repair_queue().entry_count == 0) return category_id;

    var path_buffer: [2048]u8 = undefined;
    const canonical = (try build_slug_path(db, category_id, &path_buffer)) orelse return null;
    assert(canonical.len > 0);
    if (!std.mem.eql(u8, canonical, resolved_path)) return null;
    return category_id;
}

// A slug is one path segment. An empty slug gives its category no path of its own, so a child
// would be indexed under its bare slug and could take over a root's entry; a slash would let one
// category answer for another's deeper path; control bytes and dot segments are not names.
// Punctuation and UTF-8 stay allowed: the imported DMOZ data uses them ("children's",
// "pokémon").
pub fn validate_slug(slug: []const u8) OperationError!void {
    assert(slug.len <= slug_len_max);
    if (slug.len == 0) return OperationError.InvalidSlug;
    if (std.mem.eql(u8, slug, ".")) return OperationError.InvalidSlug;
    if (std.mem.eql(u8, slug, "..")) return OperationError.InvalidSlug;
    for (slug) |byte| {
        if (byte == '/') return OperationError.InvalidSlug;
        if (byte < 0x20) return OperationError.InvalidSlug;
        if (byte == 0x7f) return OperationError.InvalidSlug;
    }
}

pub fn ensure_slug_path_free(
    db: *Directory,
    options: struct { parent_id: u64, own_id: u64 },
    slug: []const u8,
) !void {
    assert(slug.len <= slug_len_max);

    var path_buffer: [2048]u8 = undefined;
    const path = try compose_child_slug_path(db, options.parent_id, slug, &path_buffer);
    assert(std.mem.endsWith(u8, path, slug));
    assert(path.len <= slug_path_len_max);
    // A chain longer than `depth_max` cannot be walked by the ancestor updates or the path
    // builders, so its links would never reach the upper ancestors' counts.
    const depth = try chain_depth(db, options.parent_id) + 1;
    if (depth > depth_max) return OperationError.PathTooDeep;
    if (options.own_id != 0) {
        try ensure_subtree_fits(db, options.own_id, .{
            .suffix_len_max = @intCast(slug_path_len_max - path.len),
            .height_max = @intCast(depth_max - depth),
        });
    }

    var value_buffer: [8]u8 = undefined;
    const existing = (try db.categories_by_slug_path().search(path, &value_buffer)) orelse return;
    if (existing.len == 8 and codec.decodeU64(existing[0..8]) == options.own_id) return;
    return OperationError.DuplicateSlug;
}

const descendant_children_per_page: u32 = 256;

const DescendantFrame = struct { id: u64, suffix_len: u32, height: u32 };

const SubtreeLimits = struct { suffix_len_max: u32, height_max: u32 };

fn chain_depth(db: *Directory, id: u64) !u32 {
    var id_path: [depth_max]u64 = undefined;
    const path_ids = try category.get_category_path(db, id, &id_path);
    assert(path_ids.len <= depth_max);
    if (id == 0) assert(path_ids.len == 0);
    return @intCast(path_ids.len);
}

// Every descendant path is the subtree root's path plus a suffix, and every descendant sits a
// fixed number of levels below the root, so the longest suffix and the height decide whether a
// rename or move keeps all of them within `slug_path_len_max` and `depth_max`, including
// subtrees the repair worker rewrites later. The walk reads the parent-child index, not the
// slug-path index, which a queued repair may still hold under an older prefix.
fn ensure_subtree_fits(db: *Directory, root_id: u64, limits: SubtreeLimits) !void {
    assert(root_id != 0);
    assert(limits.suffix_len_max <= slug_path_len_max);
    assert(limits.height_max < depth_max);
    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();
    const allocator = arena.allocator();

    const children_buffer = try allocator.alloc(schema.Category, descendant_children_per_page);
    var stack: std.ArrayList(DescendantFrame) = .empty;
    try stack.append(allocator, .{ .id = root_id, .suffix_len = 0, .height = 0 });
    var visited: u32 = 0;
    while (stack.pop()) |frame| {
        visited += 1;
        if (visited > descendants_max) return OperationError.CategoryTooLarge;
        assert(frame.suffix_len <= limits.suffix_len_max);
        assert(frame.height <= limits.height_max);
        try push_descendant_children(db, frame, limits, children_buffer, &stack, allocator);
    }
    assert(visited >= 1);
}

fn push_descendant_children(
    db: *Directory,
    frame: DescendantFrame,
    limits: SubtreeLimits,
    children_buffer: []schema.Category,
    stack: *std.ArrayList(DescendantFrame),
    allocator: std.mem.Allocator,
) !void {
    assert(children_buffer.len == descendant_children_per_page);
    const pages_max = @divFloor(descendants_max, descendant_children_per_page) + 1;
    var offset: u32 = 0;
    for (0..pages_max) |_| {
        const children = try category.list_children(
            db,
            frame.id,
            .{ .offset = offset, .limit = descendant_children_per_page },
            children_buffer,
        );
        assert(children.len <= descendant_children_per_page);
        for (children) |child| {
            const slug = child.slug.slice();
            // An empty slug adds no segment, as in `build_slug_path`.
            const segment_len: u32 = if (slug.len == 0) 0 else @intCast(1 + slug.len);
            const suffix_len = frame.suffix_len + segment_len;
            if (suffix_len > limits.suffix_len_max) return OperationError.PathTooLong;
            if (frame.height + 1 > limits.height_max) return OperationError.PathTooDeep;
            try stack.append(allocator, .{
                .id = child.id,
                .suffix_len = suffix_len,
                .height = frame.height + 1,
            });
        }
        if (children.len < descendant_children_per_page) return;
        offset += descendant_children_per_page;
    } else return OperationError.CategoryTooLarge;
}

pub fn compose_child_slug_path(
    db: *Directory,
    parent_id: u64,
    slug: []const u8,
    buffer: []u8,
) ![]const u8 {
    assert(slug.len <= slug_len_max);
    assert(buffer.len >= slug_path_len_max);
    if (parent_id == 0) {
        @memcpy(buffer[0..slug.len], slug);
        return buffer[0..slug.len];
    }
    // A parent without a path (every slug on its chain empty, left by data written before
    // slugs were validated) cannot anchor a child: the child would be indexed under its bare
    // slug and take over another category's path.
    const parent_path = (try build_slug_path(db, parent_id, buffer)) orelse
        return OperationError.InvalidSlug;
    assert(parent_path.len > 0);
    const total = parent_path.len + 1 + slug.len;
    if (total > slug_path_len_max) return OperationError.PathTooLong;
    buffer[parent_path.len] = '/';
    @memcpy(buffer[parent_path.len + 1 ..][0..slug.len], slug);
    const path = buffer[0..total];
    assert(std.mem.endsWith(u8, path, slug));
    return path;
}

pub fn build_slug_path(db: *Directory, id: u64, buffer: []u8) !?[]const u8 {
    var id_path: [depth_max]u64 = undefined;
    const path_ids = try category.get_category_path(db, id, &id_path);
    assert(path_ids.len <= depth_max);
    if (path_ids.len > 0) assert(path_ids[path_ids.len - 1] == id);

    var position: usize = 0;
    for (path_ids, 0..) |path_id, i| {
        const path_category = (try category.get_category(db, path_id)) orelse return null;
        const slug = path_category.slug.slice();
        if (slug.len == 0) continue;

        if (i > 0 and position > 0) {
            if (position >= buffer.len) return null;
            buffer[position] = '/';
            position += 1;
        }

        if (position + slug.len > buffer.len) return null;
        @memcpy(buffer[position..][0..slug.len], slug);
        position += slug.len;
    }

    if (position == 0) return null;
    return buffer[0..position];
}

pub fn compose_old_descendant_path(
    db: *Directory,
    old_root_path: []const u8,
    options: struct { root_id: u64, descendant_id: u64 },
    buffer: []u8,
) ![]const u8 {
    var chain: [depth_max]u64 = undefined;
    var depth: u32 = 0;
    var current = options.descendant_id;
    while (current != options.root_id and depth < chain.len) : (depth += 1) {
        chain[depth] = current;
        const current_category = (try category.get_category(db, current)) orelse
            return error.NotFound;
        current = current_category.parent_id;
        if (current == 0) return error.NotFound;
    }
    if (current != options.root_id) return error.NotFound;
    if (depth > 0) assert(chain[0] == options.descendant_id);

    var position: usize = 0;
    if (old_root_path.len > buffer.len) return error.NotFound;
    @memcpy(buffer[position..][0..old_root_path.len], old_root_path);
    position += old_root_path.len;

    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const chain_category = (try category.get_category(db, chain[i])) orelse
            return error.NotFound;
        const slug = chain_category.slug.slice();
        if (slug.len == 0) continue;
        if (position + 1 + slug.len > buffer.len) return error.NotFound;
        buffer[position] = '/';
        position += 1;
        @memcpy(buffer[position..][0..slug.len], slug);
        position += slug.len;
    }
    const path = buffer[0..position];
    assert(std.mem.startsWith(u8, path, old_root_path));
    return path;
}

// Goal: a path resolves through the full path, the implicit `top/` prefix or a lone slug, and a
// miss or an empty path gives null. Method: a three-level tree, then every lookup form.
test "resolve_slug_path: full path, single-segment fallback, miss" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const b_id = try category.create_category(
        db,
        a_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );

    try std.testing.expectEqual(top_id, (try resolve_slug_path(db, "top")).?);

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "top/a")).?);
    try std.testing.expectEqual(b_id, (try resolve_slug_path(db, "top/a/b")).?);

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "a")).?);

    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, "nonexistent"));

    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, "x/a"));

    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, ""));

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "a")).?);
    try std.testing.expectEqual(b_id, (try resolve_slug_path(db, "a/b")).?);
    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, "a/nonexistent"));
}

// Goal: the canonical path joins the slugs of the parent chain with `/`. Method: a child under
// `top`, then its composed path.
test "build_slug_path: composes path from the parent chain" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const child_id = try category.create_category(
        db,
        top_id,
        .{ .name = "Child", .slug = "child", .description = "" },
    );
    var buffer: [1024]u8 = undefined;
    const path = (try build_slug_path(db, child_id, &buffer)).?;
    try std.testing.expectEqualStrings("top/child", path);
}

// Goal: with no repair pending a lookup returns the indexed id without rebuilding the path.
// Method: one category, a drained memtable, then a lookup and an empty repair queue.
test "resolve_slug_path: returns id for queue-empty fast path (steady state)" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try std.testing.expectEqual(top_id, (try resolve_slug_path(db, "top")).?);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
}

// Goal: while a repair task is queued, a stale path that still maps to an id resolves to
// nothing and only the canonical path resolves. Method: plant a stale index entry, then
// enqueue a repair task and look both paths up.
test "resolve_slug_path: validation gate hides orphans during repair window" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var value: [8]u8 = codec.encodeU64(a_id);
    try db.categories_by_slug_path().insert("top/old-a", &value);

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "top/old-a")).?);

    var task = schema.RepairTask{ .cat_id = a_id, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));

    try std.testing.expect((try resolve_slug_path(db, "top/old-a")) == null);
    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "top/a")).?);
}

fn create_numbered_child(
    db: *Directory,
    parent_id: u64,
    options: struct { fill: u8, fill_len: u32, number: u32 },
) !u64 {
    var slug_buffer: [slug_len_max]u8 = undefined;
    assert(options.fill_len + 3 <= slug_buffer.len);
    @memset(slug_buffer[0..options.fill_len], options.fill);
    const digits = try std.fmt.bufPrint(
        slug_buffer[options.fill_len..],
        "{d:0>3}",
        .{options.number},
    );
    const slug = slug_buffer[0 .. options.fill_len + digits.len];
    const text: shared.CategoryText = .{ .name = "x", .slug = slug, .description = "" };
    return category.create_category(db, parent_id, text);
}

// Goal: `categories_by_slug_path` splits pages whose medians are `slug_path_len_max` bytes, the
// engine's `MAX_KEY_LEN`, and one byte more is refused before the WAL. Method: 200 siblings
// whose paths are exactly the maximum (several leaf splits), each found again by path, then a
// sibling one byte longer.
test "categories_by_slug_path splits pages full of slug_path_len_max keys" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent = try create_numbered_child(
        db,
        top,
        .{ .fill = 'p', .fill_len = 125, .number = 0 },
    );
    const prefix_len = "top/".len + slug_len_max + "/".len;
    const child_fill_len: u32 = shared.slug_path_len_max - prefix_len - 3;

    var ids: [200]u64 = undefined;
    for (&ids, 0..) |*id, number| {
        id.* = try create_numbered_child(
            db,
            parent,
            .{ .fill = 'c', .fill_len = child_fill_len, .number = @intCast(number) },
        );
    }
    for (ids) |id| {
        var path_buffer: [2048]u8 = undefined;
        const path = (try build_slug_path(db, id, &path_buffer)).?;
        try std.testing.expectEqual(shared.slug_path_len_max, path.len);
        try std.testing.expectEqual(id, (try resolve_slug_path(db, path)).?);
    }
    try std.testing.expectError(
        OperationError.PathTooLong,
        create_numbered_child(
            db,
            parent,
            .{ .fill = 'c', .fill_len = child_fill_len + 1, .number = 0 },
        ),
    );
}

// Goal: a rename or a move that would push any descendant's path past `slug_path_len_max` is
// refused before the WAL, also when the subtree is above the inline threshold and the repair
// worker would rewrite it later. Method: threshold 0; lengthen a parent's slug; move a
// subtree under a long-slugged parent; both leave the tree as it was.
test "a rename or move that would push a descendant path past the maximum is refused" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 0;

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const short = try category.create_category(
        db,
        top,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const leaf = try create_numbered_child(
        db,
        short,
        .{ .fill = 'x', .fill_len = 122, .number = 0 },
    );
    var long_slug: [slug_len_max]u8 = undefined;
    @memset(&long_slug, 'l');
    try std.testing.expectError(
        OperationError.PathTooLong,
        category.update_category(db, short, null, &long_slug, null),
    );
    try std.testing.expect((try category.get_category(db, short)).?.slug.eql("a"));

    const long = try category.create_category(
        db,
        top,
        .{ .name = "L", .slug = &long_slug, .description = "" },
    );
    try std.testing.expectError(
        OperationError.PathTooLong,
        category.move_category(db, .{ .id = short, .new_parent_id = long }),
    );
    try std.testing.expectEqual(top, (try category.get_category(db, short)).?.parent_id);
    var path_buffer: [2048]u8 = undefined;
    try std.testing.expectEqual(leaf, (try resolve_slug_path(
        db,
        (try build_slug_path(db, leaf, &path_buffer)).?,
    )).?);
}

// Goal: a category whose chain has no slug path, left by data written before slugs were
// validated, cannot anchor a child that would take over another category's path. Method:
// commit an empty-slug root past `create_category`, then try to create `top` under it.
test "a parent without a slug path cannot anchor a child" {
    const allocator = std.testing.allocator;
    const compute = @import("operations_changeset_compute.zig");
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const legacy = schema.Category{
        .id = db.next_category_id.fetchAdd(1, .monotonic),
        .name = codec.FixedString(64).fromSlice("Legacy"),
    };
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const change_set = try compute.compute_category_insert_change_set(
            db,
            &legacy,
            arena.allocator(),
        );
        try db.commit(change_set);
    }
    try std.testing.expectError(
        OperationError.InvalidSlug,
        category.create_category(db, legacy.id, .{ .name = "T", .slug = "top", .description = "" }),
    );
    try std.testing.expectEqual(top, (try resolve_slug_path(db, "top")).?);
}

// Goal: a category stored before slugs were validated, with no slug path of its own, can still
// be deleted, and deleting it never removes another category's path key. Method: commit an
// empty-slug root and an empty-slug child of `top` past `create_category`, delete both, then
// read `top` from the slug-path index itself: resolve_slug_path would fall back to the
// slug-only index and find `top` even with its path key gone.
test "a category without a slug path of its own can be deleted" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const legacy_root = try commit_empty_slug_category(db, 0);
    const legacy_child = try commit_empty_slug_category(db, top);

    try category.delete_category(db, legacy_root);
    try category.delete_category(db, legacy_child);
    try std.testing.expect((try category.get_category(db, legacy_root)) == null);
    try std.testing.expect((try category.get_category(db, legacy_child)) == null);
    var value_buffer: [16]u8 = undefined;
    const top_value = (try db.categories_by_slug_path().search("top", &value_buffer)) orelse
        return error.TopPathKeyDeleted;
    try std.testing.expectEqualSlices(u8, &codec.encodeU64(top), top_value);
}

// Goal: a category stored with an empty slug before slugs were validated can be given a slug,
// and the rename replaces the key its creation wrote; a rename to an invalid slug is still
// refused, and so is one of an empty-slug category with children. Method: commit an empty-slug
// root and an empty-slug child of `top` past `create_category`, try an invalid slug and a
// parent with a child, then rename both and read the slug-path index.
test "a category with an empty slug can be given a slug" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const legacy_root = try commit_empty_slug_category(db, 0);
    const legacy_child = try commit_empty_slug_category(db, top);
    const invalid = OperationError.InvalidSlug;
    const slash_slug = category.update_category(db, legacy_root, null, "a/b", null);
    try std.testing.expectError(invalid, slash_slug);

    const grandchild = try category.create_category(
        db,
        legacy_child,
        .{ .name = "G", .slug = "g", .description = "" },
    );
    const with_child = category.update_category(db, legacy_child, null, "c", null);
    try std.testing.expectError(invalid, with_child);
    try category.delete_category(db, grandchild);

    try category.update_category(db, legacy_root, null, "fixed", null);
    try category.update_category(db, legacy_child, null, "child", null);
    try std.testing.expectEqual(legacy_root, (try resolve_slug_path(db, "fixed")).?);
    try std.testing.expectEqual(legacy_child, (try resolve_slug_path(db, "top/child")).?);
    var value_buffer: [16]u8 = undefined;
    const slug_paths = db.categories_by_slug_path();
    const top_value = (try slug_paths.search("top", &value_buffer)).?;
    try std.testing.expectEqualSlices(u8, &codec.encodeU64(top), top_value);
    try std.testing.expect((try slug_paths.search("", &value_buffer)) == null);
    try std.testing.expect((try slug_paths.search("top/", &value_buffer)) == null);
}

fn commit_empty_slug_category(db: *Directory, parent_id: u64) !u64 {
    const compute = @import("operations_changeset_compute.zig");
    const legacy = schema.Category{
        .id = db.next_category_id.fetchAdd(1, .monotonic),
        .parent_id = parent_id,
        .name = codec.FixedString(64).fromSlice("Legacy"),
    };
    assert(legacy.slug.len == 0);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const change_set = try compute.compute_category_insert_change_set(
        db,
        &legacy,
        arena.allocator(),
    );
    try db.commit(change_set);
    return legacy.id;
}

// Goal: no create or move leaves a category more than `depth_max` levels down, where the
// ancestor updates stop and links would never reach the root's counts. Method: a chain of
// exactly `depth_max`, one child more, then a two-level subtree moved under the chain's
// next-to-last category.
test "create and move refuse a result deeper than depth_max" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    // One-byte slugs keep the deepest path at 127 bytes, so only the depth limit is in play.
    var chain: [depth_max]u64 = undefined;
    for (&chain, 0..) |*id, level| {
        const parent_id = if (level == 0) 0 else chain[level - 1];
        id.* = try category.create_category(
            db,
            parent_id,
            .{ .name = "d", .slug = "d", .description = "" },
        );
    }
    try std.testing.expectEqual(@as(u32, depth_max), try chain_depth(db, chain[depth_max - 1]));
    try std.testing.expectError(
        OperationError.PathTooDeep,
        create_numbered_child(
            db,
            chain[depth_max - 1],
            .{ .fill = 'x', .fill_len = 0, .number = 0 },
        ),
    );

    const mover = try create_numbered_child(
        db,
        chain[0],
        .{ .fill = 'm', .fill_len = 0, .number = 0 },
    );
    _ = try create_numbered_child(db, mover, .{ .fill = 'm', .fill_len = 0, .number = 1 });
    try std.testing.expectError(
        OperationError.PathTooDeep,
        category.move_category(db, .{ .id = mover, .new_parent_id = chain[depth_max - 2] }),
    );
    try category.move_category(db, .{ .id = mover, .new_parent_id = chain[depth_max - 3] });
}
