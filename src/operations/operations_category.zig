const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const link_mod = @import("operations_link.zig");

const OperationError = shared.OperationError;
const MAX_NAME_LEN = shared.MAX_NAME_LEN;
const MAX_SLUG_LEN = shared.MAX_SLUG_LEN;
const MAX_CATEGORY_DESC_LEN = shared.MAX_CATEGORY_DESC_LEN;

pub fn createCategory(
    db: *Directory,
    parent_id: u64,
    name: []const u8,
    slug_str: []const u8,
    desc: []const u8,
) !u64 {
    if (name.len > MAX_NAME_LEN or
        slug_str.len > MAX_SLUG_LEN or
        desc.len > MAX_CATEGORY_DESC_LEN) return OperationError.FieldTooLong;

    if (parent_id != 0) {
        if ((try getCategory(db, parent_id)) == null) return OperationError.ParentNotFound;
    }

    const id = db.next_category_id.fetchAdd(1, .monotonic);
    const now = std.time.timestamp();

    const cat = schema.Category{
        .id = id,
        .parent_id = parent_id,
        .name = codec.FixedString(64).fromSlice(name),
        .slug = codec.FixedString(128).fromSlice(slug_str),
        .description = codec.FixedString(1024).fromSlice(desc),
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

pub fn getCategory(db: *Directory, id: u64) !?schema.Category {
    const key = codec.encodeU64(id);
    const mt_result = db.mt_categories_by_id().get(&key);
    var tree_buf: [@sizeOf(schema.Category)]u8 = undefined;
    const val = switch (mt_result) {
        .found => |v| v,
        .deleted => return null,
        .not_found => (try db.categories_by_id().search(&key, &tree_buf)) orelse return null,
    };
    if (val.len != @sizeOf(schema.Category)) return OperationError.DatabaseCorrupted;
    return std.mem.bytesToValue(schema.Category, val[0..@sizeOf(schema.Category)]);
}

pub fn updateCategory(
    db: *Directory,
    id: u64,
    name: ?[]const u8,
    slug_str: ?[]const u8,
    desc: ?[]const u8,
) !void {
    if (name) |n| if (n.len > MAX_NAME_LEN) return OperationError.FieldTooLong;
    if (slug_str) |s| if (s.len > MAX_SLUG_LEN) return OperationError.FieldTooLong;
    if (desc) |d| if (d.len > MAX_CATEGORY_DESC_LEN) return OperationError.FieldTooLong;

    const old_cat = (try getCategory(db, id)) orelse return OperationError.CategoryNotFound;

    const slug_changed = if (slug_str) |s|
        !std.mem.eql(u8, s, old_cat.slug.slice())
    else
        false;

    if (!slug_changed) {
        var new_cat = old_cat;
        if (name) |n| new_cat.name = codec.FixedString(64).fromSlice(n);
        if (desc) |d| new_cat.description = codec.FixedString(1024).fromSlice(d);
        new_cat.updated_at = std.time.timestamp();

        var arena = std.heap.ArenaAllocator.init(db.allocator);
        defer arena.deinit();
        const cs = try compute.computeCategoryTextUpdateChangeSet(old_cat, new_cat, arena.allocator());

        try db.commit(cs);
        return;
    }

    var new_cat = old_cat;
    if (name) |n| new_cat.name = codec.FixedString(64).fromSlice(n);
    if (slug_str) |s| new_cat.slug = codec.FixedString(128).fromSlice(s);
    if (desc) |d| new_cat.description = codec.FixedString(1024).fromSlice(d);
    new_cat.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeCategoryRenameChangeSet(db, old_cat, new_cat, arena.allocator());

    try db.commit(cs);
}

pub fn deleteCategory(db: *Directory, id: u64) !void {
    if ((try getCategory(db, id)) == null) return OperationError.CategoryNotFound;

    var children_buf: [1]schema.Category = undefined;
    const children = try listChildren(db, id, 0, 1, &children_buf);
    if (children.len > 0) return OperationError.CategoryHasChildren;

    var links_buf: [64]schema.Link = undefined;
    while (true) {
        const links = (try link_mod.listLinks(db, id, 0, 64, &links_buf, null, 0)).items;
        if (links.len == 0) break;
        for (links) |link| {
            try link_mod.deleteLink(db, link.id);
        }
    }

    const cat = (try getCategory(db, id)) orelse return OperationError.CategoryNotFound;

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeCategoryDeleteChangeSet(db, cat, arena.allocator());

    try db.commit(cs);
}

pub fn moveCategory(db: *Directory, id: u64, new_parent_id: u64) !void {
    const old_cat = (try getCategory(db, id)) orelse return OperationError.CategoryNotFound;

    if (new_parent_id != 0) {
        if ((try getCategory(db, new_parent_id)) == null) return OperationError.ParentNotFound;
    }

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

    if (old_cat.parent_id == new_parent_id) return;

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

pub fn listChildren(
    db: *Directory,
    parent_id: u64,
    offset: u32,
    limit: u32,
    buf: []schema.Category,
) ![]schema.Category {
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    const start_key = schema.ParentChildKey.encode(.{ parent_id, 0 });
    const end_key = schema.ParentChildKey.encode(.{ parent_id, std.math.maxInt(u64) });

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));

    var iter = try db.cat_by_parent().rangeScan(&start_key, &end_key);
    defer iter.deinit();
    while (try iter.next()) |entry| {
        if (skipped < offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) break;

        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const child_id = codec.decodeU64(entry.value);
        if (try getCategory(db, child_id)) |cat| {
            buf[count] = cat;
            count += 1;
        }
    }

    return buf[0..count];
}

pub fn getCategoryPath(db: *Directory, id: u64, buf: []u64) ![]u64 {
    var path_len: usize = 0;
    var current_id = id;

    while (current_id != 0) {
        if (path_len >= buf.len) return OperationError.PathTooDeep;
        buf[path_len] = current_id;
        path_len += 1;

        const cat = (try getCategory(db, current_id)) orelse break;
        current_id = cat.parent_id;
    }

    if (path_len > 1) {
        std.mem.reverse(u64, buf[0..path_len]);
    }

    return buf[0..path_len];
}

pub fn walkAncestors(
    db: *Directory,
    id: u64,
    buf: []schema.Category,
) ![]schema.Category {
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
    if (depth > buf.len) depth = buf.len;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const aid = id_buf[depth - 1 - i];
        buf[i] = (try getCategory(db, aid)) orelse return buf[0..i];
    }
    return buf[0..depth];
}

const SubtreeAgg = struct { link_subtree: u64, child_subtree: u32 };

pub fn recomputeCategoryCounts(db: *Directory) !void {
    const allocator = db.allocator;

    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());

    var direct_links = std.AutoHashMap(u64, u32).init(allocator);
    defer direct_links.deinit();
    {
        const min_key: [16]u8 = .{0} ** 16;
        var iter = try db.link_by_category().rangeScan(&min_key, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.key.len < 8) continue;
            const cid = codec.decodeU64(entry.key[0..8]);
            const gop = try direct_links.getOrPut(cid);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* +|= 1;
        }
    }

    var children_of = std.AutoHashMap(u64, std.ArrayListUnmanaged(u64)).init(allocator);
    defer {
        var vit = children_of.valueIterator();
        while (vit.next()) |list| list.deinit(allocator);
        children_of.deinit();
    }
    {
        const min_key: [16]u8 = .{0} ** 16;
        var iter = try db.cat_by_parent().rangeScan(&min_key, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.key.len < 16) continue;
            const parent = codec.decodeU64(entry.key[0..8]);
            const child = codec.decodeU64(entry.key[8..16]);
            const gop = try children_of.getOrPut(parent);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(allocator, child);
        }
    }

    var all_ids: std.ArrayListUnmanaged(u64) = .{};
    defer all_ids.deinit(allocator);
    {
        const min_key = codec.encodeU64(0);
        var iter = try db.categories_by_id().rangeScan(&min_key, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.value.len < @sizeOf(schema.Category)) continue;
            const cat = std.mem.bytesToValue(schema.Category, entry.value[0..@sizeOf(schema.Category)]);
            try all_ids.append(allocator, cat.id);
        }
    }

    var computed = std.AutoHashMap(u64, SubtreeAgg).init(allocator);
    defer computed.deinit();

    const Frame = struct { id: u64, expanded: bool };
    var stack: std.ArrayListUnmanaged(Frame) = .{};
    defer stack.deinit(allocator);
    var on_path = std.AutoHashMap(u64, void).init(allocator);
    defer on_path.deinit();

    for (all_ids.items) |root| {
        if (computed.contains(root)) continue;
        stack.clearRetainingCapacity();
        on_path.clearRetainingCapacity();
        try stack.append(allocator, .{ .id = root, .expanded = false });
        while (stack.items.len > 0) {
            const idx = stack.items.len - 1;
            const cur = stack.items[idx];
            if (!cur.expanded) {
                stack.items[idx].expanded = true;
                if (computed.contains(cur.id)) {
                    _ = stack.pop();
                    continue;
                }
                try on_path.put(cur.id, {});
                if (children_of.get(cur.id)) |kids| {
                    for (kids.items) |c| {
                        if (computed.contains(c)) continue;
                        if (on_path.contains(c)) continue;
                        try stack.append(allocator, .{ .id = c, .expanded = false });
                    }
                }
                continue;
            }
            _ = stack.pop();
            _ = on_path.remove(cur.id);
            if (computed.contains(cur.id)) continue;

            var sub_l: u64 = direct_links.get(cur.id) orelse 0;
            var sub_c: u32 = 0;
            if (children_of.get(cur.id)) |kids| {
                for (kids.items) |c| {
                    const cc = computed.get(c) orelse SubtreeAgg{ .link_subtree = 0, .child_subtree = 0 };
                    sub_l +%= cc.link_subtree;
                    sub_c +|= 1 +| cc.child_subtree;
                }
            }
            try computed.put(cur.id, .{ .link_subtree = sub_l, .child_subtree = sub_c });
        }
    }

    const now = std.time.timestamp();
    var rewritten: u64 = 0;
    {
        const min_key = codec.encodeU64(0);
        var iter = try db.categories_by_id().rangeScan(&min_key, null);
        defer iter.deinit();
        while (try iter.next()) |entry| {
            if (entry.value.len < @sizeOf(schema.Category)) continue;
            var cat = std.mem.bytesToValue(schema.Category, entry.value[0..@sizeOf(schema.Category)]);

            const new_link: u32 = direct_links.get(cat.id) orelse 0;
            const new_child: u32 = if (children_of.get(cat.id)) |k| @intCast(k.items.len) else 0;
            const agg = computed.get(cat.id) orelse SubtreeAgg{ .link_subtree = new_link, .child_subtree = 0 };

            if (cat.link_count == new_link and cat.child_count == new_child and
                cat.link_count_subtree == agg.link_subtree and cat.child_count_subtree == agg.child_subtree)
            {
                continue;
            }
            cat.link_count = new_link;
            cat.child_count = new_child;
            cat.link_count_subtree = agg.link_subtree;
            cat.child_count_subtree = agg.child_subtree;
            cat.updated_at = now;
            const id_key = codec.encodeU64(cat.id);
            try db.mt_categories_by_id().put(&id_key, std.mem.asBytes(&cat));
            rewritten += 1;
        }
    }

    if (rewritten > 0) {
        std.log.scoped(.recover).info(
            "recomputeCategoryCounts: corrected {d} categor{s}",
            .{ rewritten, if (rewritten == 1) "y" else "ies" },
        );
    }
}

test "recomputeCategoryCounts: rebuilds drifted counts from indexes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, a_id, "B", "b", "");
    _ = try link_mod.createLink(db, b_id, "https://x1.example", "X1", "");
    _ = try link_mod.createLink(db, b_id, "https://x2.example", "X2", "");
    _ = try link_mod.createLink(db, a_id, "https://x3.example", "X3", "");

    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    {
        var tampered = (try getCategory(db, top_id)).?;
        tampered.link_count = 99;
        tampered.child_count = 99;
        tampered.link_count_subtree = 99;
        tampered.child_count_subtree = 99;
        const id_key = codec.encodeU64(top_id);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&tampered));
    }
    try std.testing.expectEqual(@as(u64, 99), (try getCategory(db, top_id)).?.link_count_subtree);

    try recomputeCategoryCounts(db);

    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.link_count);
    try std.testing.expectEqual(@as(u32, 1), top.child_count);
    try std.testing.expectEqual(@as(u64, 3), top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), top.child_count_subtree);

    const a = (try getCategory(db, a_id)).?;
    try std.testing.expectEqual(@as(u32, 1), a.link_count);
    try std.testing.expectEqual(@as(u32, 1), a.child_count);
    try std.testing.expectEqual(@as(u64, 3), a.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);

    const b = (try getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 2), b.link_count);
    try std.testing.expectEqual(@as(u64, 2), b.link_count_subtree);
}

test "createCategory cascades child_count_subtree up the chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    _ = try createCategory(db, a_id, "B", "b", "");

    const top = (try getCategory(db, top_id)).?;
    const a = (try getCategory(db, a_id)).?;
    try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), top.child_count_subtree);
}

test "createCategory: indexing B+Trees populated by category_inserted ChangeSet" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const child_id = try createCategory(db, top_id, "Programming", "programming", "Code stuff");

    var v_buf: [64]u8 = undefined;
    const child_id_be = codec.encodeU64(child_id);

    const slug_path_val = (try db.categories_by_slug_path().search("top/programming", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_path_val);

    const slug_only_val = (try db.categories_by_slug_only().search("programming", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_only_val);

    var key_buf: [128]u8 = undefined;
    const expected_tokens = [_][]const u8{ "programming", "code", "stuff" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &child_id_be);
        const found = try db.categories_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), top.child_count_subtree);
}

test "deleteCategory cascades child_count_subtree decrement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
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
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const child_id = try createCategory(db, top_id, "Programming", "programming", "Code stuff");

    var v_buf: [64]u8 = undefined;
    const child_id_be = codec.encodeU64(child_id);

    try std.testing.expect((try db.categories_by_slug_path().search("top/programming", &v_buf)) != null);
    try std.testing.expect((try db.categories_by_slug_only().search("programming", &v_buf)) != null);

    try deleteCategory(db, child_id);

    try std.testing.expect((try db.categories_by_slug_path().search("top/programming", &v_buf)) == null);

    try std.testing.expect((try db.categories_by_slug_only().search("programming", &v_buf)) == null);

    var key_buf: [128]u8 = undefined;
    const expected_tokens = [_][]const u8{ "programming", "code", "stuff" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &child_id_be);
        try std.testing.expect((try db.categories_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf)) == null);
    }

    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.child_count_subtree);
}

test "updateCategory (text): name/desc tokens swapped in categories_index_tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const child_id = try createCategory(db, top_id, "Programming", "programming", "Code stuff");

    var v_buf: [64]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const child_id_be = codec.encodeU64(child_id);

    {
        const tokens = [_][]const u8{ "code", "stuff" };
        for (tokens) |tok| {
            @memcpy(key_buf[0..tok.len], tok);
            @memcpy(key_buf[tok.len..][0..8], &child_id_be);
            const found = try db.categories_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
            try std.testing.expect(found != null);
        }
    }

    try updateCategory(db, child_id, "Hacking", "programming", "Network tricks");

    {
        const tokens = [_][]const u8{ "code", "stuff" };
        for (tokens) |tok| {
            @memcpy(key_buf[0..tok.len], tok);
            @memcpy(key_buf[tok.len..][0..8], &child_id_be);
            const found = try db.categories_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
            try std.testing.expect(found == null);
        }
    }

    {
        const tokens = [_][]const u8{ "hacking", "network", "tricks" };
        for (tokens) |tok| {
            @memcpy(key_buf[0..tok.len], tok);
            @memcpy(key_buf[tok.len..][0..8], &child_id_be);
            const found = try db.categories_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
            try std.testing.expect(found != null);
        }
    }

    {
        const tok = "programming";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &child_id_be);
        const found = try db.categories_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    const cat = (try getCategory(db, child_id)).?;
    try std.testing.expect(cat.name.eql("Hacking"));
    try std.testing.expect(cat.slug.eql("programming"));
    try std.testing.expect(cat.description.eql("Network tricks"));
}

test "updateCategory (slug rename): slug-path B+Trees swapped + descendants rebuilt" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const cat_id = try createCategory(db, top_id, "Cat", "old", "");
    const child_id = try createCategory(db, cat_id, "Child", "leaf", "");

    var v_buf: [64]u8 = undefined;
    const cat_id_be = codec.encodeU64(cat_id);
    const child_id_be = codec.encodeU64(child_id);

    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_path().search("top/old", &v_buf)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &child_id_be,
        (try db.categories_by_slug_path().search("top/old/leaf", &v_buf)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_only().search("old", &v_buf)).?,
    );

    try updateCategory(db, cat_id, null, "new", null);

    try std.testing.expect((try db.categories_by_slug_path().search("top/old", &v_buf)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_path().search("top/new", &v_buf)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &child_id_be,
        (try db.categories_by_slug_path().search("top/new/leaf", &v_buf)).?,
    );

    try std.testing.expect((try db.categories_by_slug_only().search("old", &v_buf)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &cat_id_be,
        (try db.categories_by_slug_only().search("new", &v_buf)).?,
    );

    const got = (try getCategory(db, cat_id)).?;
    try std.testing.expect(got.slug.eql("new"));
}

test "deep chain: createCategory cascades to all ancestors" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, a_id, "B", "b", "");
    _ = try createCategory(db, b_id, "C", "c", "");

    const top = (try getCategory(db, top_id)).?;
    const a = (try getCategory(db, a_id)).?;
    const b = (try getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 1), b.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 3), top.child_count_subtree);
}

test "moveCategory cascades counts in both old and new chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, a_id, "B", "b", "");
    _ = try link_mod.createLink(db, b_id, "https://x.example", "x", "");
    const c_id = try createCategory(db, top_id, "C", "c", "");

    {
        const a = (try getCategory(db, a_id)).?;
        try std.testing.expectEqual(@as(u64, 1), a.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
        const c = (try getCategory(db, c_id)).?;
        try std.testing.expectEqual(@as(u64, 0), c.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 0), c.child_count_subtree);
    }

    try moveCategory(db, b_id, c_id);

    const a = (try getCategory(db, a_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), a.child_count_subtree);
    const c = (try getCategory(db, c_id)).?;
    try std.testing.expectEqual(@as(u64, 1), c.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), c.child_count_subtree);
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
}

test "moveCategory carrying multiple descendants" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const x_id = try createCategory(db, top_id, "X", "x", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const a1_id = try createCategory(db, a_id, "A1", "a1", "");
    _ = try createCategory(db, a1_id, "A2", "a2", "");
    _ = try link_mod.createLink(db, a1_id, "https://1.example", "1", "");
    _ = try link_mod.createLink(db, a_id, "https://2.example", "2", "");

    {
        const a = (try getCategory(db, a_id)).?;
        try std.testing.expectEqual(@as(u64, 2), a.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 2), a.child_count_subtree);
    }

    try moveCategory(db, a_id, x_id);

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
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    _ = try link_mod.createLink(db, a_id, "https://x.example", "x", "");

    const before = (try getCategory(db, top_id)).?.link_count_subtree;
    try moveCategory(db, a_id, top_id);
    const after = (try getCategory(db, top_id)).?.link_count_subtree;
    try std.testing.expectEqual(before, after);
}

test "moveCategory: cat_by_parent + slug-path B+Trees swapped" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try createCategory(db, 0, "Top", "top", "");
    const a_id = try createCategory(db, top_id, "A", "a", "");
    const b_id = try createCategory(db, top_id, "B", "b", "");
    const c_id = try createCategory(db, a_id, "C", "c", "");

    {
        const a = (try getCategory(db, a_id)).?;
        const b = (try getCategory(db, b_id)).?;
        try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
        try std.testing.expectEqual(@as(u32, 0), b.child_count_subtree);
    }

    try moveCategory(db, c_id, b_id);

    var v_buf: [64]u8 = undefined;
    {
        const old_pc_key = schema.ParentChildKey.encode(.{ a_id, c_id });
        const mt_old = db.mt_cat_by_parent().get(&old_pc_key);
        const old_present = switch (mt_old) {
            .found => true,
            .deleted => false,
            .not_found => (try db.cat_by_parent().search(&old_pc_key, &v_buf)) != null,
        };
        try std.testing.expect(!old_present);

        const new_pc_key = schema.ParentChildKey.encode(.{ b_id, c_id });
        const mt_new = db.mt_cat_by_parent().get(&new_pc_key);
        const new_present = switch (mt_new) {
            .found => true,
            .deleted => false,
            .not_found => (try db.cat_by_parent().search(&new_pc_key, &v_buf)) != null,
        };
        try std.testing.expect(new_present);
    }

    const c_id_be = codec.encodeU64(c_id);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path().search("top/b/c", &v_buf)).?);
    try std.testing.expect((try db.categories_by_slug_path().search("top/a/c", &v_buf)) == null);

    const a = (try getCategory(db, a_id)).?;
    const b = (try getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), b.child_count_subtree);
    const top = (try getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 3), top.child_count_subtree);
}
