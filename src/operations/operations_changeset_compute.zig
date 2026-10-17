const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const changeset = @import("../changeset.zig");
const inverted = @import("zigstore").inverted_index;
const category = @import("operations_category.zig");
const slug_mod = @import("operations_slug.zig");
const MAX_DEPTH = @import("operations_shared.zig").MAX_DEPTH;

const TokenSource = struct { text: []const u8, field: changeset.TokenField };

fn tokenize(sources: []const TokenSource, allocator: std.mem.Allocator) ![]changeset.Token {
    var out: std.ArrayList(changeset.Token) = .{};
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    for (sources) |f| {
        var iter = inverted.TokenIterator.init(f.text);
        while (iter.next(&tok_buf)) |tok| {
            try out.append(allocator, .{
                .text = try allocator.dupe(u8, tok),
                .field = f.field,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn categoryTokens(cat: *const schema.Category, allocator: std.mem.Allocator) ![]changeset.Token {
    return tokenize(&.{
        .{ .text = cat.name.slice(), .field = .name },
        .{ .text = cat.slug.slice(), .field = .slug },
        .{ .text = cat.description.slice(), .field = .desc },
    }, allocator);
}

pub fn linkTokens(link: *const schema.Link, allocator: std.mem.Allocator) ![]changeset.Token {
    return tokenize(&.{
        .{ .text = link.title.slice(), .field = .title },
        .{ .text = link.url.slice(), .field = .url },
        .{ .text = link.description.slice(), .field = .desc },
    }, allocator);
}

fn collectAncestorUpdates(
    db: *Directory,
    start_id: u64,
    link_count_subtree_delta: i64,
    child_count_subtree_delta: i64,
    allocator: std.mem.Allocator,
) ![]changeset.AncestorUpdate {
    var updates: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = start_id;
    var depth: usize = 0;
    while (current_id != 0 and depth < MAX_DEPTH) : (depth += 1) {
        const ancestor = (try category.getCategory(db, current_id)) orelse break;
        try updates.append(allocator, .{
            .cat_id = current_id,
            .link_count_subtree_delta = link_count_subtree_delta,
            .child_count_subtree_delta = child_count_subtree_delta,
        });
        current_id = ancestor.parent_id;
    }
    return updates.toOwnedSlice(allocator);
}

fn ownSlugPath(db: *Directory, cat: schema.Category, allocator: std.mem.Allocator) ![]const u8 {
    var path_buf: [2048]u8 = undefined;
    const path = (try slug_mod.buildSlugPath(db, cat.id, &path_buf)) orelse cat.slug.slice();
    return allocator.dupe(u8, path);
}

fn childSlugPath(db: *Directory, parent_id: u64, slug: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var path_buf: [2048]u8 = undefined;
    const path = (try slug_mod.composeChildSlugPath(db, parent_id, slug, &path_buf)) orelse slug;
    return allocator.dupe(u8, path);
}

pub fn computeCategoryInsertChangeSet(
    db: *Directory,
    cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const ancestor_updates = try collectAncestorUpdates(db, cat.parent_id, 0, 1, allocator);
    const tokens = try categoryTokens(&cat, allocator);

    const slug_slice = cat.slug.slice();
    const slug_path = try childSlugPath(db, cat.parent_id, slug_slice, allocator);

    const new_depth = std.mem.count(u8, slug_path, "/");
    var existing_id_buf: [16]u8 = undefined;
    const is_shallowest_for_slug: bool = blk: {
        const existing = (try db.categories_by_slug_only().search(slug_slice, &existing_id_buf)) orelse {
            break :blk true;
        };
        if (existing.len != 8) break :blk true;
        const existing_id = codec.decodeU64(existing);
        var existing_path_buf: [2048]u8 = undefined;
        const existing_path = (try slug_mod.buildSlugPath(db, existing_id, &existing_path_buf)) orelse {
            break :blk true;
        };
        const existing_depth = std.mem.count(u8, existing_path, "/");
        break :blk new_depth < existing_depth;
    };

    return changeset.ChangeSet{ .category_inserted = .{
        .cat = cat,
        .ancestor_updates = ancestor_updates,
        .tokens = tokens,
        .slug_path = slug_path,
        .is_shallowest_for_slug = is_shallowest_for_slug,
    } };
}

pub fn computeCategoryTextUpdateChangeSet(
    old_cat: schema.Category,
    new_cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    return changeset.ChangeSet{ .category_text_updated = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_tokens = try categoryTokens(&old_cat, allocator),
        .new_tokens = try categoryTokens(&new_cat, allocator),
    } };
}

const DescendantSwaps = struct {
    swaps: []changeset.SlugPathSwap,
    above_threshold: bool,
    enqueue: changeset.EnqueueOnApply,
};

fn collectDescendantSwaps(
    db: *Directory,
    root_id: u64,
    old_path: []const u8,
    new_path: []const u8,
    op: schema.RepairOp,
    allocator: std.mem.Allocator,
) !DescendantSwaps {
    const threshold = db.config.rename_inline_threshold;
    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    var above_threshold = false;
    var descendant_count: u32 = 0;

    var stack: std.ArrayList(u64) = .{};
    defer stack.deinit(allocator);
    try stack.append(allocator, root_id);

    const children_buf = try allocator.alloc(schema.Category, 256);
    walk: while (stack.pop()) |cur_id| {
        var offset: u32 = 0;
        while (true) {
            const children = try category.listChildren(db, cur_id, offset, 256, children_buf);
            if (children.len == 0) break;
            for (children) |child| {
                descendant_count += 1;
                if (descendant_count > threshold) {
                    above_threshold = true;
                    break :walk;
                }
                var d_old_buf: [2048]u8 = undefined;
                const d_old = slug_mod.composeOldDescendantPath(db, old_path, root_id, child.id, &d_old_buf) catch continue;
                var d_new_buf: [2048]u8 = undefined;
                const d_new = slug_mod.composeOldDescendantPath(db, new_path, root_id, child.id, &d_new_buf) catch continue;
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
        swaps.clearAndFree(allocator);
        enqueue = .{
            .seq = db.next_repair_seq.fetchAdd(1, .monotonic),
            .op = op,
            .old_slug_prefix = try allocator.dupe(u8, old_path),
            .created_at = std.time.milliTimestamp(),
        };
    }

    return .{
        .swaps = try swaps.toOwnedSlice(allocator),
        .above_threshold = above_threshold,
        .enqueue = enqueue,
    };
}

pub fn computeCategoryRenameChangeSet(
    db: *Directory,
    old_cat: schema.Category,
    new_cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const old_path = try ownSlugPath(db, old_cat, allocator);
    const new_path = try childSlugPath(db, new_cat.parent_id, new_cat.slug.slice(), allocator);

    const ds = try collectDescendantSwaps(db, new_cat.id, old_path, new_path, .renamed_slug, allocator);

    return changeset.ChangeSet{ .category_renamed = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_slug_path = old_path,
        .new_slug_path = new_path,
        .descendant_swaps = ds.swaps,
        .above_threshold = ds.above_threshold,
        .enqueue = ds.enqueue,
    } };
}

pub fn computeCategoryDeleteChangeSet(
    db: *Directory,
    cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const link_delta: i64 = @intCast(cat.link_count_subtree);
    return changeset.ChangeSet{ .category_deleted = .{
        .cat = cat,
        .ancestor_updates = try collectAncestorUpdates(db, cat.parent_id, -link_delta, -1, allocator),
        .tokens = try categoryTokens(&cat, allocator),
        .slug_path = try ownSlugPath(db, cat, allocator),
    } };
}

pub fn computeCategoryMoveChangeSet(
    db: *Directory,
    cat: schema.Category,
    new_parent_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const old_parent_id = cat.parent_id;

    var cat_post_move = cat;
    cat_post_move.parent_id = new_parent_id;
    cat_post_move.updated_at = std.time.timestamp();

    const link_subtree_delta: u64 = cat.link_count_subtree;
    const child_subtree_delta: u32 = cat.child_count_subtree + 1;
    const link_delta: i64 = @intCast(link_subtree_delta);
    const child_delta: i64 = @intCast(child_subtree_delta);

    const old_chain = try collectAncestorUpdates(db, old_parent_id, -link_delta, -child_delta, allocator);
    const new_chain = try collectAncestorUpdates(db, new_parent_id, link_delta, child_delta, allocator);

    const old_slug_path = try ownSlugPath(db, cat, allocator);
    const new_slug_path = try childSlugPath(db, new_parent_id, cat.slug.slice(), allocator);

    const ds = try collectDescendantSwaps(db, cat.id, old_slug_path, new_slug_path, .moved_parent, allocator);

    return changeset.ChangeSet{ .category_moved = .{
        .cat = cat_post_move,
        .old_parent_id = old_parent_id,
        .new_parent_id = new_parent_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
        .old_slug_path = old_slug_path,
        .new_slug_path = new_slug_path,
        .link_subtree_delta = link_subtree_delta,
        .child_subtree_delta = child_subtree_delta,
        .descendant_swaps = ds.swaps,
        .above_threshold = ds.above_threshold,
        .enqueue = ds.enqueue,
    } };
}

pub fn computeLinkInsertChangeSet(
    db: *Directory,
    link: schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    return changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = try collectAncestorUpdates(db, link.category_id, 1, 0, allocator),
        .tokens = try linkTokens(&link, allocator),
    } };
}

pub fn computeLinkTextUpdateChangeSet(
    old_link: schema.Link,
    new_link: schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    return changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = try linkTokens(&old_link, allocator),
        .new_tokens = try linkTokens(&new_link, allocator),
    } };
}

pub fn computeLinkDeleteChangeSet(
    db: *Directory,
    link: schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    return changeset.ChangeSet{ .link_deleted = .{
        .link = link,
        .ancestor_updates = try collectAncestorUpdates(db, link.category_id, -1, 0, allocator),
        .tokens = try linkTokens(&link, allocator),
    } };
}

pub fn computeLinkRecatChangeSet(
    db: *Directory,
    link: schema.Link,
    new_category_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const old_category_id = link.category_id;

    var link_post_move = link;
    link_post_move.category_id = new_category_id;
    link_post_move.updated_at = std.time.timestamp();

    return changeset.ChangeSet{ .link_recategorized = .{
        .link = link_post_move,
        .old_category_id = old_category_id,
        .old_chain_updates = try collectAncestorUpdates(db, old_category_id, -1, 0, allocator),
        .new_chain_updates = try collectAncestorUpdates(db, new_category_id, 1, 0, allocator),
    } };
}

test "computeCategoryRenameChangeSet: <= threshold populates descendant_swaps" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const parent_id = try category.createCategory(db, top_id, "Parent", "old", "");
    _ = try category.createCategory(db, parent_id, "C1", "c1", "");
    _ = try category.createCategory(db, parent_id, "C2", "c2", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    const old_cat = (try category.getCategory(db, parent_id)).?;
    var new_cat = old_cat;
    new_cat.slug = codec.FixedString(128).fromSlice("new");

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
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 5;

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const parent_id = try category.createCategory(db, top_id, "Parent", "old", "");
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "c{d}", .{i}) catch unreachable;
        _ = try category.createCategory(db, parent_id, "x", slug, "");
    }
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    const old_cat = (try category.getCategory(db, parent_id)).?;
    var new_cat = old_cat;
    new_cat.slug = codec.FixedString(128).fromSlice("new");

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
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 100;

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
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    try std.testing.expectEqual(@as(u32, 64), built);

    const old_top = (try category.getCategory(db, top_id)).?;
    var new_top = old_top;
    new_top.slug = codec.FixedString(128).fromSlice("topnew");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryRenameChangeSet(db, old_top, new_top, arena.allocator());
    const e = cs.category_renamed;

    try std.testing.expect(!e.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), e.enqueue.seq);

    try std.testing.expectEqual(@as(usize, built), e.descendant_swaps.len);

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
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const b_id = try category.createCategory(db, top_id, "B", "b", "");
    _ = try category.createCategory(db, a_id, "X", "x", "");
    _ = try category.createCategory(db, a_id, "Y", "y", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

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
    var db = try Directory.openTestInstance(allocator, &tmp);
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
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    const cat_a = (try category.getCategory(db, a_id)).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cs = try computeCategoryMoveChangeSet(db, cat_a, b_id, arena.allocator());
    const e = cs.category_moved;
    try std.testing.expect(e.above_threshold);
    try std.testing.expectEqual(@as(usize, 0), e.descendant_swaps.len);
    try std.testing.expect(e.enqueue.seq != 0);
    try std.testing.expectEqualStrings("top/a", e.enqueue.old_slug_prefix);
    try std.testing.expectEqual(schema.RepairOp.moved_parent, e.enqueue.op);
}
