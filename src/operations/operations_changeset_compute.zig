const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Database = @import("../database.zig").Database;
const changeset = @import("../changeset.zig");
const inverted = @import("../inverted_index.zig");
const category = @import("operations_category.zig");
const slug_mod = @import("operations_slug.zig");

pub fn computeCategoryInsertChangeSet(
    db: *Database,
    cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = cat.parent_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const ancestor = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .link_count_subtree_delta = 0,
            .child_count_subtree_delta = 1,
        });
        current_id = ancestor.parent_id;
    }

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

    const slug_slice = cat.slug.slice();
    const slug_path: []const u8 = blk: {
        if (cat.parent_id == 0) {
            break :blk try allocator.dupe(u8, slug_slice);
        }
        var parent_buf: [2048]u8 = undefined;
        const parent_path = (try slug_mod.buildSlugPath(db, cat.parent_id, &parent_buf)) orelse {
            break :blk try allocator.dupe(u8, slug_slice);
        };
        const total_len = parent_path.len + 1 + slug_slice.len;
        const out = try allocator.alloc(u8, total_len);
        @memcpy(out[0..parent_path.len], parent_path);
        out[parent_path.len] = '/';
        @memcpy(out[parent_path.len + 1 ..], slug_slice);
        break :blk out;
    };

    const new_depth = std.mem.count(u8, slug_path, "/");
    var existing_id_buf: [16]u8 = undefined;
    const is_shallowest_for_slug: bool = blk: {
        const existing = (try db.categories_by_slug_only.search(slug_slice, &existing_id_buf)) orelse {
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
        .ancestor_updates = try ancestors.toOwnedSlice(allocator),
        .tokens = try tokens.toOwnedSlice(allocator),
        .slug_path = slug_path,
        .is_shallowest_for_slug = is_shallowest_for_slug,
    } };
}

pub fn computeCategoryTextUpdateChangeSet(
    old_cat: schema.Category,
    new_cat: schema.Category,
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

fn composeOldDescendantPath(
    db: *Database,
    old_root_path: []const u8,
    root_id: u64,
    descendant_id: u64,
    buf: []u8,
) ![]const u8 {
    var chain: [64]u64 = undefined;
    var depth: u32 = 0;
    var cur = descendant_id;
    while (cur != root_id and depth < chain.len) : (depth += 1) {
        chain[depth] = cur;
        const c = (try category.getCategory(db, cur)) orelse return error.NotFound;
        cur = c.parent_id;
        if (cur == 0) return error.NotFound;
    }
    var pos: usize = 0;
    if (old_root_path.len > buf.len) return error.NotFound;
    @memcpy(buf[pos..][0..old_root_path.len], old_root_path);
    pos += old_root_path.len;

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

pub fn computeCategoryRenameChangeSet(
    db: *Database,
    old_cat: schema.Category,
    new_cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var old_buf: [2048]u8 = undefined;
    const old_path_slice = (try slug_mod.buildSlugPath(db, old_cat.id, &old_buf)) orelse
        old_cat.slug.slice();
    const old_path = try allocator.dupe(u8, old_path_slice);

    const new_slug = new_cat.slug.slice();
    const new_path: []const u8 = blk: {
        if (new_cat.parent_id == 0) {
            break :blk try allocator.dupe(u8, new_slug);
        }
        var parent_buf: [2048]u8 = undefined;
        const parent_path = (try slug_mod.buildSlugPath(db, new_cat.parent_id, &parent_buf)) orelse {
            break :blk try allocator.dupe(u8, new_slug);
        };
        break :blk try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent_path, new_slug });
    };

    const threshold = db.config.rename_inline_threshold;
    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    var above_threshold = false;
    var descendant_count: u32 = 0;

    var stack: std.ArrayList(u64) = .{};
    defer stack.deinit(allocator);
    try stack.append(allocator, new_cat.id);

    walk: while (stack.pop()) |cur_id| {
        var children_buf: [256]schema.Category = undefined;
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

pub fn computeCategoryDeleteChangeSet(
    db: *Database,
    cat: schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = cat.parent_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const ancestor = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .link_count_subtree_delta = -@as(i64, @intCast(cat.link_count_subtree)),
            .child_count_subtree_delta = -1,
        });
        current_id = ancestor.parent_id;
    }

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

pub fn computeCategoryMoveChangeSet(
    db: *Database,
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

    var old_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = old_parent_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            try old_chain.append(allocator, .{
                .cat_id = current_id,
                .link_count_subtree_delta = -@as(i64, @intCast(link_subtree_delta)),
                .child_count_subtree_delta = -@as(i64, @intCast(child_subtree_delta)),
            });
            current_id = ancestor.parent_id;
        }
    }

    var new_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = new_parent_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            try new_chain.append(allocator, .{
                .cat_id = current_id,
                .link_count_subtree_delta = @as(i64, @intCast(link_subtree_delta)),
                .child_count_subtree_delta = @as(i64, @intCast(child_subtree_delta)),
            });
            current_id = ancestor.parent_id;
        }
    }

    var old_buf: [2048]u8 = undefined;
    const old_path_slice = (try slug_mod.buildSlugPath(db, cat.id, &old_buf)) orelse cat.slug.slice();
    const old_slug_path = try allocator.dupe(u8, old_path_slice);

    const new_slug = cat.slug.slice();
    const new_slug_path: []const u8 = blk: {
        if (new_parent_id == 0) {
            break :blk try allocator.dupe(u8, new_slug);
        }
        var parent_buf: [2048]u8 = undefined;
        const parent_path = (try slug_mod.buildSlugPath(db, new_parent_id, &parent_buf)) orelse {
            break :blk try allocator.dupe(u8, new_slug);
        };
        const total_len = parent_path.len + 1 + new_slug.len;
        const out = try allocator.alloc(u8, total_len);
        @memcpy(out[0..parent_path.len], parent_path);
        out[parent_path.len] = '/';
        @memcpy(out[parent_path.len + 1 ..], new_slug);
        break :blk out;
    };

    const threshold = db.config.rename_inline_threshold;
    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    var above_threshold = false;
    var descendant_count: u32 = 0;

    var stack: std.ArrayList(u64) = .{};
    defer stack.deinit(allocator);
    try stack.append(allocator, cat.id);

    walk: while (stack.pop()) |cur_id| {
        var children_buf: [256]schema.Category = undefined;
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

pub fn computeLinkInsertChangeSet(
    db: *Database,
    link: schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = link.category_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const cat = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .link_count_subtree_delta = 1,
            .child_count_subtree_delta = 0,
        });
        current_id = cat.parent_id;
    }

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

pub fn computeLinkTextUpdateChangeSet(
    old_link: schema.Link,
    new_link: schema.Link,
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
    link: schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    var ancestors: std.ArrayList(changeset.AncestorUpdate) = .{};
    var current_id = link.category_id;
    var depth: u32 = 0;
    while (current_id != 0 and depth < 64) : (depth += 1) {
        const cat = (try category.getCategory(db, current_id)) orelse break;
        try ancestors.append(allocator, .{
            .cat_id = current_id,
            .link_count_subtree_delta = -1,
            .child_count_subtree_delta = 0,
        });
        current_id = cat.parent_id;
    }

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
    var db = try Database.openTestInstance(allocator, &tmp);
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
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

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
    var db = try Database.openTestInstance(allocator, &tmp);
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
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

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
    try std.testing.expectEqual(schema.RepairOp.moved_parent, e.enqueue.op);
}

pub fn computeLinkRecatChangeSet(
    db: *Database,
    link: schema.Link,
    new_category_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    const old_category_id = link.category_id;

    var link_post_move = link;
    link_post_move.category_id = new_category_id;
    link_post_move.updated_at = std.time.timestamp();

    var old_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = old_category_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            try old_chain.append(allocator, .{
                .cat_id = current_id,
                .link_count_subtree_delta = -1,
                .child_count_subtree_delta = 0,
            });
            current_id = ancestor.parent_id;
        }
    }

    var new_chain: std.ArrayList(changeset.AncestorUpdate) = .{};
    {
        var current_id = new_category_id;
        var depth: u32 = 0;
        while (current_id != 0 and depth < 64) : (depth += 1) {
            const ancestor = (try category.getCategory(db, current_id)) orelse break;
            try new_chain.append(allocator, .{
                .cat_id = current_id,
                .link_count_subtree_delta = 1,
                .child_count_subtree_delta = 0,
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
