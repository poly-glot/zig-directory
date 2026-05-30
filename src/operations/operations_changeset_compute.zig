// All `compute*ChangeSet` helpers, plus `composeOldDescendantPath`,
// split from the original monolithic operations.zig. These functions
// build `changeset.ChangeSet` payloads from current DB state — they
// read but do not mutate, leaving the actual mutation to `apply.zig`
// invoked through `db.commit`.
//
// Made `pub` so the orchestrating CRUD wrappers in
// `operations_category.zig` and `operations_link.zig` can import them.

const std = @import("std");
const types = @import("../types.zig");
const Database = @import("../database.zig").Database;
const changeset = @import("../changeset.zig");
const inverted = @import("../inverted_index.zig");
const category = @import("operations_category.zig");
const slug_mod = @import("operations_slug.zig");

/// Build a `category_inserted` ChangeSet for `cat` (which has not yet been
/// written to the DB). Walks the ancestor chain from `cat.parent_id` upward
/// emitting absolute `child_count_subtree` targets (each ancestor gains one
/// descendant). Tokenises name/slug/description, computes the new cat's
/// canonical full slug_path by appending `cat.slug` to the parent's path,
/// and decides `is_shallowest_for_slug` by consulting
/// `categories_by_slug_only` for any existing holder of the same leaf slug.
///
/// Allocations come from `allocator` (caller passes an arena freed after
/// `db.commit` returns).
pub fn computeCategoryInsertChangeSet(
    db: *Database,
    cat: types.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    // Walk ancestor chain, leaf-first. `cat` itself is NOT in the DB yet,
    // so we start at `cat.parent_id` — each ancestor's `child_count_subtree`
    // grows by one because the new category sits inside their subtree.
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = cat.parent_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const ancestor = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .new_link_count_subtree = ancestor.link_count_subtree,
            .new_child_count_subtree = ancestor.child_count_subtree + 1,
        });
        current_id = ancestor.parent_id;
    }

    // Tokenise name + slug + description. Token bytes are duped into the
    // arena so they outlive the local stack buffer.
    var tokens: std.ArrayList(changeset.Token) = .{};
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    const fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = cat.name.slice(), .field = .name },
        .{ .text = cat.slug.slice(), .field = .slug },
        .{ .text = cat.description.slice(), .field = .desc },
    };
    for (fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    // Compute canonical slug_path: parent's path + "/" + cat.slug, or just
    // cat.slug if the parent is the synthetic root (parent_id == 0). The
    // path lives in the arena so it outlives the local buffer.
    const slug_slice = cat.slug.slice();
    const slug_path: []const u8 = blk: {
        if (cat.parent_id == 0) {
            break :blk try allocator.dupe(u8, slug_slice);
        }
        var parent_buf: [2048]u8 = undefined;
        const parent_path = (try slug_mod.buildSlugPath(db, cat.parent_id, &parent_buf)) orelse {
            // Parent unresolvable — fall back to bare slug. Verifier will
            // surface drift if this ever happens for a non-root cat.
            break :blk try allocator.dupe(u8, slug_slice);
        };
        const total_len = parent_path.len + 1 + slug_slice.len;
        const out = try allocator.alloc(u8, total_len);
        @memcpy(out[0..parent_path.len], parent_path);
        out[parent_path.len] = '/';
        @memcpy(out[parent_path.len + 1 ..], slug_slice);
        break :blk out;
    };

    // Determine `is_shallowest_for_slug` by comparing the new cat's depth
    // (slash count in slug_path) to the existing holder's depth, if any.
    // Equal depth → existing wins (false). Strictly shallower → true.
    const new_depth = std.mem.count(u8, slug_path, "/");
    var existing_id_buf: [16]u8 = undefined;
    const is_shallowest_for_slug: bool = blk: {
        const existing = (try db.categories_by_slug_only.search(slug_slice, &existing_id_buf)) orelse {
            break :blk true;
        };
        if (existing.len != 8) break :blk true;
        const existing_id = types.decodeU64(existing);
        var existing_path_buf: [2048]u8 = undefined;
        const existing_path = (try slug_mod.buildSlugPath(db, existing_id, &existing_path_buf)) orelse {
            // Existing entry unresolvable — replace it.
            break :blk true;
        };
        const existing_depth = std.mem.count(u8, existing_path, "/");
        break :blk new_depth < existing_depth;
    };

    return changeset.ChangeSet{ .category_inserted = .{
        .cat = cat,
        .ancestor_updates = try ancestors.toOwnedSlice(allocator),
        .tokens = try tokens.toOwnedSlice(allocator),
        .slug_path = slug_path,
        .is_shallowest_for_slug = is_shallowest_for_slug,
    } };
}

/// Build a `category_text_updated` ChangeSet from old + new category
/// snapshots whose `slug` field is identical. Tokenises name/slug/desc
/// for both versions into separate `Token` slices so apply can remove
/// the old postings from `categories_index_tree` and add the new ones.
/// All allocations live in `allocator` (caller passes an arena and frees
/// once `db.commit` returns).
pub fn computeCategoryTextUpdateChangeSet(
    old_cat: types.Category,
    new_cat: types.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;

    var old_tokens: std.ArrayList(changeset.Token) = .{};
    const old_fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = old_cat.name.slice(), .field = .name },
        .{ .text = old_cat.slug.slice(), .field = .slug },
        .{ .text = old_cat.description.slice(), .field = .desc },
    };
    for (old_fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try old_tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    var new_tokens: std.ArrayList(changeset.Token) = .{};
    const new_fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = new_cat.name.slice(), .field = .name },
        .{ .text = new_cat.slug.slice(), .field = .slug },
        .{ .text = new_cat.description.slice(), .field = .desc },
    };
    for (new_fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try new_tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    return changeset.ChangeSet{ .category_text_updated = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_tokens = try old_tokens.toOwnedSlice(allocator),
        .new_tokens = try new_tokens.toOwnedSlice(allocator),
    } };
}

/// Compose the OLD slug path of a descendant by concatenating the
/// rename-root's old path with the CURRENT relative tail from
/// `root_id` down to `descendant_id`. Used by computeRenameChangeSet
/// and computeMoveChangeSet (Task 11), and by the repair_worker. The
/// relative tail uses each intermediate ancestor's CURRENT slug —
/// those slugs did not change in the rename/move, so they are stable
/// under both old and new prefixes.
fn composeOldDescendantPath(
    db: *Database,
    old_root_path: []const u8,
    root_id: u64,
    descendant_id: u64,
    buf: []u8,
) ![]const u8 {
    // Build the relative chain by walking up from descendant to root.
    var chain: [64]u64 = undefined;
    var depth: u32 = 0;
    var cur = descendant_id;
    while (cur != root_id and depth < chain.len) : (depth += 1) {
        chain[depth] = cur;
        const c = (try category.getCategory(db, cur)) orelse return error.NotFound;
        cur = c.parent_id;
        if (cur == 0) return error.NotFound;
    }
    // chain[0..depth] is descendant → ... → child-of-root (deepest first).
    var pos: usize = 0;
    if (old_root_path.len > buf.len) return error.NotFound;
    @memcpy(buf[pos..][0..old_root_path.len], old_root_path);
    pos += old_root_path.len;

    // Append slugs in root → descendant order (reverse of chain).
    var idx: i32 = @intCast(@as(i64, @intCast(depth)) - 1);
    while (idx >= 0) : (idx -= 1) {
        const c = (try category.getCategory(db, chain[@intCast(idx)])) orelse return error.NotFound;
        const slug = c.slug.slice();
        if (slug.len == 0) continue;
        if (pos + 1 + slug.len > buf.len) return error.NotFound;
        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos..][0..slug.len], slug);
        pos += slug.len;
    }
    return buf[0..pos];
}

/// Build a `category_renamed` ChangeSet for a slug rename. Both `old_cat`
/// and `new_cat` share id and parent_id; only the `slug` (and possibly
/// name/description/updated_at) differs. Computes:
///
///  * `old_slug_path` — full canonical slug path BEFORE the rename, by
///    walking the live B+Tree (which still holds the old slug for `id`).
///  * `new_slug_path` — parent's full slug path + "/" + new_slug, or just
///    the new slug if the cat is at the root (parent_id == 0).
///  * `descendant_swaps` — `(old_path, new_path, cat_id)` tuples for every
///    descendant in the subtree, populated when the subtree size is at or
///    below `db.config.rename_inline_threshold`. Apply path uses these to
///    swap `categories_by_slug_path` entries inline.
///  * `above_threshold` + `enqueue` — when the subtree exceeds the
///    threshold, `descendant_swaps` is empty and an `EnqueueOnApply`
///    payload is built so the apply path can write a `slug_path_repair_queue`
///    entry for the background `repair_worker` to drain.
///
/// All slices are duped into `allocator` (caller passes an arena and frees
/// once `db.commit` returns).
pub fn computeCategoryRenameChangeSet(
    db: *Database,
    old_cat: types.Category,
    new_cat: types.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    // Old path: read directly from the live B+Tree (slug for `id` is still
    // the old slug at this point — caller has not yet routed through commit).
    var old_buf: [2048]u8 = undefined;
    const old_path_slice = (try slug_mod.buildSlugPath(db, old_cat.id, &old_buf)) orelse
        old_cat.slug.slice();
    const old_path = try allocator.dupe(u8, old_path_slice);

    // New path: parent's path (unchanged — parent_id is invariant under a
    // rename) + "/" + new_slug. Root cats just use the bare new slug.
    const new_slug = new_cat.slug.slice();
    const new_path: []const u8 = blk: {
        if (new_cat.parent_id == 0) {
            break :blk try allocator.dupe(u8, new_slug);
        }
        var parent_buf: [2048]u8 = undefined;
        const parent_path = (try slug_mod.buildSlugPath(db, new_cat.parent_id, &parent_buf)) orelse {
            // Parent unresolvable — fall back to bare slug. Verifier will
            // catch the drift if this ever fires for a non-root cat.
            break :blk try allocator.dupe(u8, new_slug);
        };
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, new_slug });
    };

    // Walk descendants depth-first via cat_by_parent. Cap at threshold + 1
    // so we can detect breach without walking the entire subtree.
    const threshold = db.config.rename_inline_threshold;
    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    var above_threshold = false;
    var descendant_count: u32 = 0;

    var stack: std.ArrayList(u64) = .{};
    defer stack.deinit(allocator);
    try stack.append(allocator, new_cat.id);

    walk: while (stack.pop()) |cur_id| {
        var children_buf: [256]types.Category = undefined;
        var offset: u32 = 0;
        while (true) {
            const children = try category.listChildren(db, cur_id, offset, 256, &children_buf);
            if (children.len == 0) break;
            for (children) |child| {
                descendant_count += 1;
                if (descendant_count > threshold) {
                    above_threshold = true;
                    break :walk;
                }
                var d_old_buf: [2048]u8 = undefined;
                const d_old = composeOldDescendantPath(db, old_path, new_cat.id, child.id, &d_old_buf) catch continue;
                var d_new_buf: [2048]u8 = undefined;
                // Mirror the move-compute pattern: compose `new_root_path +
                // relative_tail`. `buildCanonicalSlugPath` reads ancestors
                // from the live B+Tree, which still holds the OLD slug for
                // `new_cat.id` until apply runs — so it would silently
                // produce `top/old/leaf` instead of `top/new/leaf`. The
                // relative descendant tail is invariant under a rename of
                // an ancestor, so root-path swap is sufficient.
                const d_new = composeOldDescendantPath(db, new_path, new_cat.id, child.id, &d_new_buf) catch continue;
                try swaps.append(allocator, .{
                    .old_path = try allocator.dupe(u8, d_old),
                    .new_path = try allocator.dupe(u8, d_new),
                    .cat_id = child.id,
                });
                try stack.append(allocator, child.id);
            }
            offset += @intCast(children.len);
            if (children.len < 256) break;
        }
    }

    var enqueue: changeset.EnqueueOnApply = .{};
    if (above_threshold) {
        // Discard the partial swap list — repair_worker will rebuild from
        // the live tree once the queue entry is drained.
        swaps.clearAndFree(allocator);
        enqueue = .{
            .seq = db.next_repair_seq.fetchAdd(1, .monotonic),
            .op = .renamed_slug,
            .old_slug_prefix = try allocator.dupe(u8, old_path),
            .created_at = std.time.milliTimestamp(),
        };
    }

    return changeset.ChangeSet{ .category_renamed = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_slug_path = old_path,
        .new_slug_path = new_path,
        .descendant_swaps = try swaps.toOwnedSlice(allocator),
        .above_threshold = above_threshold,
        .enqueue = enqueue,
    } };
}

/// Build a `category_deleted` ChangeSet for `cat` (still present in the DB).
/// Walks the ancestor chain from `cat.parent_id` upward emitting absolute
/// `child_count_subtree` and `link_count_subtree` targets that subtract this
/// cat's contribution (saturating). Tokenises name/slug/description and
/// computes the cat's canonical full slug_path so applyCategoryDeleted can
/// remove the matching `categories_by_slug_path` entry.
///
/// Pre-condition (validated by the caller): `cat` has no children and no
/// surviving links. The link cascade has already drained
/// `cat.link_count_subtree` to zero, so the link subtraction is typically
/// a no-op; it's still computed explicitly to absorb any drift.
///
/// Allocations come from `allocator` (caller passes an arena freed after
/// `db.commit` returns).
pub fn computeCategoryDeleteChangeSet(
    db: *Database,
    cat: types.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    // Walk ancestor chain, leaf-first. Each ancestor's child_count_subtree
    // loses 1 (this cat); link_count_subtree loses cat.link_count_subtree
    // (this cat's already-drained subtree contribution). Saturating
    // subtract guards against any zero-count drift surfaced by the verifier.
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = cat.parent_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const ancestor = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .new_link_count_subtree = ancestor.link_count_subtree -| cat.link_count_subtree,
            .new_child_count_subtree = ancestor.child_count_subtree -| 1,
        });
        current_id = ancestor.parent_id;
    }

    // Tokenise name + slug + description. Token bytes are duped into the
    // arena so they outlive the local stack buffer. applyCategoryDeleted
    // uses these to remove the corresponding categories_index_tree entries.
    var tokens: std.ArrayList(changeset.Token) = .{};
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    const fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = cat.name.slice(), .field = .name },
        .{ .text = cat.slug.slice(), .field = .slug },
        .{ .text = cat.description.slice(), .field = .desc },
    };
    for (fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    // Compute the canonical slug_path of the cat being deleted. The cat is
    // still present in the DB, so buildSlugPath resolves cleanly. Path
    // lives in the arena so it outlives the local buffer.
    var path_buf: [2048]u8 = undefined;
    const path_slice = (try slug_mod.buildSlugPath(db, cat.id, &path_buf)) orelse cat.slug.slice();
    const slug_path = try allocator.dupe(u8, path_slice);

    return changeset.ChangeSet{ .category_deleted = .{
        .cat = cat,
        .ancestor_updates = try ancestors.toOwnedSlice(allocator),
        .tokens = try tokens.toOwnedSlice(allocator),
        .slug_path = slug_path,
    } };
}

/// Build a `category_moved` ChangeSet for `cat` (pre-move state: `cat.parent_id`
/// is still the old parent). The function flips parent_id and bumps updated_at
/// internally to record the post-move state in the ChangeSet. Walks both
/// ancestor chains emitting absolute `(link_count_subtree,
/// child_count_subtree)` targets that subtract the cat's contribution off
/// the old chain and add it back onto the new chain. The per-link-mass
/// moving is `cat.link_count_subtree`; the per-child-mass is
/// `cat.child_count_subtree + 1` (subtree size including self — this cat is
/// itself a descendant of every ancestor on both chains).
///
/// `old_slug_path` MUST be computed BEFORE this is called from the still-
/// pre-move B+Tree state (slug-path lookup walks the parent chain). The
/// new path is the new parent's path + "/" + cat.slug, with the bare slug
/// used for root cats.
///
/// Descendant rebuild: walks the subtree rooted at `cat.id` depth-first via
/// `cat_by_parent`, capped at `db.config.rename_inline_threshold + 1`.
/// Below threshold, populates `descendant_swaps` with `(old_path, new_path,
/// cat_id)` tuples computed via `composeOldDescendantPath` — once with the
/// pre-move root path, once with the post-move root path. Above threshold,
/// discards the partial swap list and emits an `EnqueueOnApply` payload
/// (op = `.moved_parent`) so the apply path enqueues a
/// `slug_path_repair_queue` entry for the background `repair_worker` to
/// drain.
///
/// Allocations come from `allocator` (caller passes an arena freed after
/// `db.commit` returns). Apply-side then routes the ChangeSet through
/// `applyCategoryMoved` which handles secondary swap, slug-path swap +
/// descendant rebuild, both chain cascades and the immediate-parent
/// `child_count` decrement/increment — see `src/apply.zig`.
pub fn computeCategoryMoveChangeSet(
    db: *Database,
    cat: types.Category, // pre-move state (cat.parent_id == old parent)
    new_parent_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const old_parent_id = cat.parent_id;

    // Post-move snapshot stored in the ChangeSet: parent_id flipped, updated_at
    // bumped. Subtree counts and slug carry over unchanged.
    var cat_post_move = cat;
    cat_post_move.parent_id = new_parent_id;
    cat_post_move.updated_at = std.time.timestamp();

    const link_subtree_delta: u64 = cat.link_count_subtree;
    // +1 for the moving cat itself — it counts as a descendant of every
    // ancestor on both chains.
    const child_subtree_delta: u32 = cat.child_count_subtree + 1;

    // Old chain: walk from old_parent_id upward, each ancestor decremented.
    // Saturating subtract guards against any zero-count drift.
    var old_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = old_parent_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            try old_chain.append(allocator, .{
                .cat_id = current_id,
                .new_link_count_subtree = ancestor.link_count_subtree -| link_subtree_delta,
                .new_child_count_subtree = ancestor.child_count_subtree -| child_subtree_delta,
            });
            current_id = ancestor.parent_id;
        }
    }

    // New chain: walk from new_parent_id upward, each ancestor incremented.
    // Shared-ancestor handling: when both chains contain the same cat (e.g.
    // moving between siblings, both chains end at the common parent), apply
    // processes old chain first then new chain, so the new chain's target
    // overwrites the old chain's. To land at the correct net value
    // (unchanged), the new chain's base must be the old chain's POST target
    // — not the pre-move B+Tree value — for any shared ancestor. Otherwise
    // the shared ancestor is double-counted (decremented then re-incremented
    // from the unchanged pre-move base, ending at base + delta).
    var new_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = new_parent_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            // Pick base: if ancestor appears in old_chain, use its
            // post-decrement target; else read the pre-move value. Linear
            // scan is fine — chain depths are bounded at 64.
            var base_link: u64 = ancestor.link_count_subtree;
            var base_child: u32 = ancestor.child_count_subtree;
            for (old_chain.items) |upd| {
                if (upd.cat_id == current_id) {
                    base_link = upd.new_link_count_subtree;
                    base_child = upd.new_child_count_subtree;
                    break;
                }
            }
            try new_chain.append(allocator, .{
                .cat_id = current_id,
                .new_link_count_subtree = base_link + link_subtree_delta,
                .new_child_count_subtree = base_child + child_subtree_delta,
            });
            current_id = ancestor.parent_id;
        }
    }

    // Old slug path: read from the live B+Tree BEFORE the move takes
    // effect (caller has not yet routed through commit, so the parent
    // chain still resolves to the pre-move path).
    var old_buf: [2048]u8 = undefined;
    const old_path_slice = (try slug_mod.buildSlugPath(db, cat.id, &old_buf)) orelse cat.slug.slice();
    const old_slug_path = try allocator.dupe(u8, old_path_slice);

    // New slug path: new parent's path (the new parent's own ancestry is
    // invariant under this move) + "/" + cat.slug. Root cats
    // (new_parent_id == 0) use the bare slug.
    const new_slug = cat.slug.slice();
    const new_slug_path: []const u8 = blk: {
        if (new_parent_id == 0) {
            break :blk try allocator.dupe(u8, new_slug);
        }
        var parent_buf: [2048]u8 = undefined;
        const parent_path = (try slug_mod.buildSlugPath(db, new_parent_id, &parent_buf)) orelse {
            // Parent unresolvable — fall back to bare slug. Verifier will
            // catch the drift if this ever fires for a non-root cat.
            break :blk try allocator.dupe(u8, new_slug);
        };
        const total_len = parent_path.len + 1 + new_slug.len;
        const out = try allocator.alloc(u8, total_len);
        @memcpy(out[0..parent_path.len], parent_path);
        out[parent_path.len] = '/';
        @memcpy(out[parent_path.len + 1 ..], new_slug);
        break :blk out;
    };

    // Walk descendants of `cat.id` depth-first via cat_by_parent. Cap at
    // threshold + 1 so we can detect breach without walking the entire
    // subtree. For each descendant, the OLD path is composed from
    // `old_slug_path` + relative tail; the NEW path is composed from
    // `new_slug_path` + the SAME relative tail (intermediate ancestors'
    // slugs do not change in a move — only `cat` itself moves).
    const threshold = db.config.rename_inline_threshold;
    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    var above_threshold = false;
    var descendant_count: u32 = 0;

    var stack: std.ArrayList(u64) = .{};
    defer stack.deinit(allocator);
    try stack.append(allocator, cat.id);

    walk: while (stack.pop()) |cur_id| {
        var children_buf: [256]types.Category = undefined;
        var offset: u32 = 0;
        while (true) {
            const children = try category.listChildren(db, cur_id, offset, 256, &children_buf);
            if (children.len == 0) break;
            for (children) |child| {
                descendant_count += 1;
                if (descendant_count > threshold) {
                    above_threshold = true;
                    break :walk;
                }
                var d_old_buf: [2048]u8 = undefined;
                const d_old = composeOldDescendantPath(db, old_slug_path, cat.id, child.id, &d_old_buf) catch continue;
                var d_new_buf: [2048]u8 = undefined;
                // Algorithm is generic: composing root_path + relative_tail.
                // Pass new_slug_path as the root to derive the descendant's
                // post-move path. Relative tail uses CURRENT slugs of
                // intermediate ancestors, which are unchanged by the move.
                const d_new = composeOldDescendantPath(db, new_slug_path, cat.id, child.id, &d_new_buf) catch continue;
                try swaps.append(allocator, .{
                    .old_path = try allocator.dupe(u8, d_old),
                    .new_path = try allocator.dupe(u8, d_new),
                    .cat_id = child.id,
                });
                try stack.append(allocator, child.id);
            }
            offset += @intCast(children.len);
            if (children.len < 256) break;
        }
    }

    var enqueue: changeset.EnqueueOnApply = .{};
    if (above_threshold) {
        // Discard the partial swap list — repair_worker will rebuild from
        // the live tree once the queue entry is drained.
        swaps.clearAndFree(allocator);
        enqueue = .{
            .seq = db.next_repair_seq.fetchAdd(1, .monotonic),
            .op = .moved_parent,
            .old_slug_prefix = try allocator.dupe(u8, old_slug_path),
            .created_at = std.time.milliTimestamp(),
        };
    }

    return changeset.ChangeSet{ .category_moved = .{
        .cat = cat_post_move,
        .old_parent_id = old_parent_id,
        .new_parent_id = new_parent_id,
        .old_chain_updates = try old_chain.toOwnedSlice(allocator),
        .new_chain_updates = try new_chain.toOwnedSlice(allocator),
        .old_slug_path = old_slug_path,
        .new_slug_path = new_slug_path,
        .link_subtree_delta = link_subtree_delta,
        .child_subtree_delta = child_subtree_delta,
        .descendant_swaps = try swaps.toOwnedSlice(allocator),
        .above_threshold = above_threshold,
        .enqueue = enqueue,
    } };
}

/// Build a `link_inserted` ChangeSet for `link`. Walks the ancestor chain
/// from `link.category_id` upward, emitting an `AncestorUpdate` for each
/// visited category with `new_link_count_subtree = current + 1` and
/// `new_child_count_subtree = current` (unchanged on link insert). Tokenises
/// title/url/description into the `tokens` slice. All allocated slices and
/// duped token bytes live in `allocator` — pass an arena and `defer
/// arena.deinit()` once the caller is done with the ChangeSet (i.e., after
/// `db.commit` returns, since apply consumes the bytes synchronously).
pub fn computeLinkInsertChangeSet(
    db: *Database,
    link: types.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    // Walk ancestor chain, leaf-first. Stops on missing parent (orphan);
    // parent_id == 0 terminates the walk at the synthetic root.
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = link.category_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const cat = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .new_link_count_subtree = cat.link_count_subtree + 1,
            .new_child_count_subtree = cat.child_count_subtree,
        });
        current_id = cat.parent_id;
    }

    // Tokenise title + url + description. The TokenIterator writes into a
    // local stack buffer; we dupe each token into `allocator` so the bytes
    // outlive this loop iteration.
    var tokens: std.ArrayList(changeset.Token) = .{};
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    const fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = link.title.slice(), .field = .title },
        .{ .text = link.url.slice(), .field = .url },
        .{ .text = link.description.slice(), .field = .desc },
    };
    for (fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    return changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = try ancestors.toOwnedSlice(allocator),
        .tokens = try tokens.toOwnedSlice(allocator),
    } };
}

/// Build a `link_text_updated` ChangeSet from old + new link snapshots.
///
/// Tokenises title/url/description for both old and new versions into
/// separate `Token` slices so apply can remove the old postings and add
/// the new ones from `links_index_tree`. URL change is handled by apply
/// via `e.old_link.url` vs `e.new_link.url` comparison — no separate
/// flag in the effect. All allocations live in `allocator` (caller passes
/// an arena and frees once `db.commit` returns).
pub fn computeLinkTextUpdateChangeSet(
    old_link: types.Link,
    new_link: types.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;

    var old_tokens: std.ArrayList(changeset.Token) = .{};
    const old_fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = old_link.title.slice(), .field = .title },
        .{ .text = old_link.url.slice(), .field = .url },
        .{ .text = old_link.description.slice(), .field = .desc },
    };
    for (old_fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try old_tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    var new_tokens: std.ArrayList(changeset.Token) = .{};
    const new_fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = new_link.title.slice(), .field = .title },
        .{ .text = new_link.url.slice(), .field = .url },
        .{ .text = new_link.description.slice(), .field = .desc },
    };
    for (new_fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try new_tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    return changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = try old_tokens.toOwnedSlice(allocator),
        .new_tokens = try new_tokens.toOwnedSlice(allocator),
    } };
}

pub fn computeLinkDeleteChangeSet(
    db: *Database,
    link: types.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    // Walk ancestor chain, leaf-first. Mirrors computeLinkInsertChangeSet
    // but emits saturating-decrement targets so retries on a delete that
    // already partially applied do not wrap the count.
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = link.category_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const cat = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .new_link_count_subtree = cat.link_count_subtree -| 1,
            .new_child_count_subtree = cat.child_count_subtree,
        });
        current_id = cat.parent_id;
    }

    // Tokenise title + url + description. Same shape as the insert path —
    // applyLinkDeleted uses these to remove the corresponding token entries
    // from links_index_tree.
    var tokens: std.ArrayList(changeset.Token) = .{};
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    const fields = [_]struct { text: []const u8, field: changeset.TokenField }{
        .{ .text = link.title.slice(), .field = .title },
        .{ .text = link.url.slice(), .field = .url },
        .{ .text = link.description.slice(), .field = .desc },
    };
    for (fields) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try tokens.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }

    return changeset.ChangeSet{ .link_deleted = .{
        .link = link,
        .ancestor_updates = try ancestors.toOwnedSlice(allocator),
        .tokens = try tokens.toOwnedSlice(allocator),
    } };
}

test "computeCategoryRenameChangeSet: <= threshold populates descendant_swaps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const parent_id = try category.createCategory(db, top_id, "Parent", "old", "");
    _ = try category.createCategory(db, parent_id, "C1", "c1", "");
    _ = try category.createCategory(db, parent_id, "C2", "c2", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    const old_cat = (try category.getCategory(db, parent_id)).?;
    var new_cat = old_cat;
    new_cat.slug = types.FixedString(128).fromSlice("new");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryRenameChangeSet(db, old_cat, new_cat, arena.allocator());
    const e = cs.category_renamed;
    try std.testing.expectEqual(@as(usize, 2), e.descendant_swaps.len);
    try std.testing.expect(!e.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), e.enqueue.seq);
}

test "computeCategoryRenameChangeSet: > threshold sets above_threshold + populates enqueue" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 5; // override for test

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const parent_id = try category.createCategory(db, top_id, "Parent", "old", "");
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "c{d}", .{i}) catch unreachable;
        _ = try category.createCategory(db, parent_id, "x", slug, "");
    }
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    const old_cat = (try category.getCategory(db, parent_id)).?;
    var new_cat = old_cat;
    new_cat.slug = types.FixedString(128).fromSlice("new");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryRenameChangeSet(db, old_cat, new_cat, arena.allocator());
    const e = cs.category_renamed;
    try std.testing.expect(e.above_threshold);
    try std.testing.expectEqual(@as(usize, 0), e.descendant_swaps.len);
    try std.testing.expect(e.enqueue.seq != 0);
    try std.testing.expectEqualStrings("top/old", e.enqueue.old_slug_prefix);
}

test "computeCategoryRenameChangeSet: descendant walk silently caps at depth 64" {
    // Locks in current depth-cap behavior of the rename pipeline.
    //
    // Both `getCategoryPath` (used by `buildSlugPath` /
    // `buildCanonicalSlugPath`) and `composeOldDescendantPath` cap their
    // ancestor walks at 64 entries:
    //   - `buildSlugPath` uses a `[64]u64` id_path buffer; deeper cats
    //     trigger `OperationError.PathTooDeep` from `getCategoryPath`
    //     (which `createCategory` does NOT swallow — it only swallows
    //     a `null` return).
    //   - `composeOldDescendantPath` uses a `[64]u64` chain buffer;
    //     deeper relative tails silently truncate (no error returned),
    //     yielding a wrong path.
    //
    // We build the deepest chain that is actually constructible under
    // these limits and rename the root. The test is intentionally
    // empirical: assertions describe what the pipeline actually does,
    // not what it ideally should do. A future change to either cap will
    // shift these counts and surface itself here.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 100; // keep walk inline

    // Build Top → c1 → c2 → ... → cN until createCategory itself
    // refuses (PathTooDeep). This empirically gives us the deepest
    // legal chain. We also count how many descendants Top has.
    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    var deepest_id = top_id;
    var built: u32 = 0;
    var i: u32 = 1;
    while (i <= 70) : (i += 1) {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "c{d}", .{i}) catch unreachable;
        const child_id = category.createCategory(db, deepest_id, "x", slug, "") catch break;
        deepest_id = child_id;
        built += 1;
    }
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    // Empirically: createCategory tops out at 64 descendants below Top
    // (Top + c1..c64 = 65 cats total). The 65th descendant (c65) would
    // need a 65-slot id_path in `buildSlugPath`'s `[64]u64`, so its
    // creation fails with PathTooDeep before we ever get to a rename.
    // This means the chain that reaches the rename pipeline cannot
    // exercise composeOldDescendantPath's own 64-slot chain[] beyond
    // its limit — buildSlugPath's cap fires first.
    try std.testing.expectEqual(@as(u32, 64), built);

    // Rename Top: "top" → "topnew".
    const old_top = (try category.getCategory(db, top_id)).?;
    var new_top = old_top;
    new_top.slug = types.FixedString(128).fromSlice("topnew");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryRenameChangeSet(db, old_top, new_top, arena.allocator());
    const e = cs.category_renamed;

    // Inline path (under threshold of 100): no enqueue, swaps populated.
    try std.testing.expect(!e.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), e.enqueue.seq);

    // Lock in: every descendant we managed to *create* is captured in
    // the swaps list. The cap on createCategory is what bounds the
    // chain — `composeOldDescendantPath`'s own 64-slot chain[] is wide
    // enough for every cat reachable through `buildSlugPath`, so no
    // descendant is silently dropped here.
    try std.testing.expectEqual(@as(usize, built), e.descendant_swaps.len);

    // Confirm the deepest descendant's swap path is well-formed (no
    // silent truncation in composeOldDescendantPath for chains that
    // buildSlugPath itself accepted).
    var deepest_swap_found = false;
    for (e.descendant_swaps) |sw| {
        if (sw.cat_id == deepest_id) {
            deepest_swap_found = true;
            try std.testing.expect(std.mem.startsWith(u8, sw.old_path, "top/"));
            try std.testing.expect(std.mem.startsWith(u8, sw.new_path, "topnew/"));
        }
    }
    try std.testing.expect(deepest_swap_found);
}

test "computeCategoryMoveChangeSet: <= threshold populates descendant_swaps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const b_id = try category.createCategory(db, top_id, "B", "b", "");
    _ = try category.createCategory(db, a_id, "X", "x", "");
    _ = try category.createCategory(db, a_id, "Y", "y", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    const cat_a = (try category.getCategory(db, a_id)).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryMoveChangeSet(db, cat_a, b_id, arena.allocator());
    const e = cs.category_moved;
    try std.testing.expectEqual(@as(usize, 2), e.descendant_swaps.len);
    try std.testing.expect(!e.above_threshold);
}

test "computeCategoryMoveChangeSet: > threshold sets above_threshold + populates enqueue" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 3;

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const b_id = try category.createCategory(db, top_id, "B", "b", "");
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "x{d}", .{i}) catch unreachable;
        _ = try category.createCategory(db, a_id, "x", slug, "");
    }
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    const cat_a = (try category.getCategory(db, a_id)).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryMoveChangeSet(db, cat_a, b_id, arena.allocator());
    const e = cs.category_moved;
    try std.testing.expect(e.above_threshold);
    try std.testing.expectEqual(@as(usize, 0), e.descendant_swaps.len);
    try std.testing.expect(e.enqueue.seq != 0);
    try std.testing.expectEqualStrings("top/a", e.enqueue.old_slug_prefix);
    try std.testing.expectEqual(types.RepairOp.moved_parent, e.enqueue.op);
}

/// Build a `link_recategorized` ChangeSet that moves `link` from its
/// current `link.category_id` to `new_category_id`. Walks both ancestor
/// chains and emits absolute `(link_count_subtree, child_count_subtree)`
/// targets: the old chain decrements by 1 link, the new chain increments
/// by 1 link. `child_count_subtree` is unchanged on both chains because a
/// link is not a category.
///
/// Shared-ancestor handling: apply processes old chain first then new
/// chain (see `applyLinkRecategorized` in `src/apply_link.zig`), so when
/// the same ancestor appears on both chains (e.g. moving between
/// siblings under the same parent) the new chain's target is computed
/// from the post-old-decrement state. Concretely: if ancestor A appears
/// in the old chain with new_link_count_subtree=N, and in the new chain,
/// we set the new-chain target to N+1 (not the current_value+1) so the
/// final cascade lands on the right number.
///
/// Allocations come from `allocator` (caller passes an arena freed after
/// `db.commit` returns).
pub fn computeLinkRecatChangeSet(
    db: *Database,
    link: types.Link, // pre-move state (link.category_id is OLD)
    new_category_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const old_category_id = link.category_id;

    // Post-move snapshot stored in the ChangeSet: category_id flipped, updated_at bumped.
    var link_post_move = link;
    link_post_move.category_id = new_category_id;
    link_post_move.updated_at = std.time.timestamp();

    // Old chain: walk from old_category_id upward, each ancestor decrements link_count_subtree by 1.
    var old_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = old_category_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            try old_chain.append(allocator, .{
                .cat_id = current_id,
                .new_link_count_subtree = ancestor.link_count_subtree -| 1,
                .new_child_count_subtree = ancestor.child_count_subtree,
            });
            current_id = ancestor.parent_id;
        }
    }

    // New chain: walk from new_category_id upward, each ancestor increments link_count_subtree by 1.
    // For ancestors that also appear in old_chain (shared ancestors), base off the post-old value
    // instead of the pre-move value so the absolute target is correct after both cascades.
    var new_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = new_category_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            var base_link_count = ancestor.link_count_subtree;
            for (old_chain.items) |old_upd| {
                if (old_upd.cat_id == current_id) {
                    base_link_count = old_upd.new_link_count_subtree;
                    break;
                }
            }
            try new_chain.append(allocator, .{
                .cat_id = current_id,
                .new_link_count_subtree = base_link_count + 1,
                .new_child_count_subtree = ancestor.child_count_subtree,
            });
            current_id = ancestor.parent_id;
        }
    }

    return changeset.ChangeSet{ .link_recategorized = .{
        .link = link_post_move,
        .old_category_id = old_category_id,
        .old_chain_updates = try old_chain.toOwnedSlice(allocator),
        .new_chain_updates = try new_chain.toOwnedSlice(allocator),
    } };
}
