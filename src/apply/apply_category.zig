const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;
const apply = @import("apply.zig");

pub fn applyCategoryInserted(db: *Directory, e: changeset.CategoryInsertEffect) !void {
    const id_key = codec.encodeU64(e.cat.id);

    const pc_key = schema.ParentChildKey.encode(.{ e.cat.parent_id, e.cat.id });
    try db.mt_cat_by_parent().put(&pc_key, &id_key);

    try db.categories_by_slug_path().insert(e.slug_path, &id_key);

    if (e.is_shallowest_for_slug) {
        try db.categories_by_slug_only().insert(e.cat.slug.slice(), &id_key);
    }

    try apply.writeTokens(db.categories_index_tree(), e.tokens, e.cat.id, .insert);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.cat.parent_id, .child_count, true);

    try db.mt_categories_by_id().put(&id_key, std.mem.asBytes(&e.cat));

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryDeleted(db: *Directory, e: changeset.CategoryDeleteEffect) !void {
    const id_key = codec.encodeU64(e.cat.id);

    const pc_key = schema.ParentChildKey.encode(.{ e.cat.parent_id, e.cat.id });
    try db.mt_cat_by_parent().delete(&pc_key);

    _ = try db.categories_by_slug_path().delete(e.slug_path);

    var slug_only_buf: [16]u8 = undefined;
    if (try db.categories_by_slug_only().search(e.cat.slug.slice(), &slug_only_buf)) |val| {
        if (val.len == 8 and std.mem.eql(u8, val, &id_key)) {
            _ = try db.categories_by_slug_only().delete(e.cat.slug.slice());
        }
    }

    try apply.writeTokens(db.categories_index_tree(), e.tokens, e.cat.id, .delete);

    try db.mt_categories_by_id().delete(&id_key);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.cat.parent_id, .child_count, false);

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryTextUpdated(db: *Directory, e: changeset.CategoryTextUpdateEffect) !void {
    const id_key = codec.encodeU64(e.new_cat.id);

    try db.mt_categories_by_id().put(&id_key, std.mem.asBytes(&e.new_cat));

    try apply.writeTokens(db.categories_index_tree(), e.old_tokens, e.new_cat.id, .delete);
    try apply.writeTokens(db.categories_index_tree(), e.new_tokens, e.new_cat.id, .insert);

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryRenamed(db: *Directory, e: changeset.CategoryRenameEffect) !void {
    const id_key = codec.encodeU64(e.new_cat.id);

    try db.mt_categories_by_id().put(&id_key, std.mem.asBytes(&e.new_cat));

    _ = try db.categories_by_slug_path().delete(e.old_slug_path);
    try db.categories_by_slug_path().insert(e.new_slug_path, &id_key);

    if (!std.mem.eql(u8, e.old_cat.slug.slice(), e.new_cat.slug.slice())) {
        var slug_only_buf: [16]u8 = undefined;
        if (try db.categories_by_slug_only().search(e.old_cat.slug.slice(), &slug_only_buf)) |val| {
            if (val.len == 8 and std.mem.eql(u8, val, &id_key)) {
                _ = try db.categories_by_slug_only().delete(e.old_cat.slug.slice());
            }
        }
        if ((try db.categories_by_slug_only().search(e.new_cat.slug.slice(), &slug_only_buf)) == null) {
            try db.categories_by_slug_only().insert(e.new_cat.slug.slice(), &id_key);
        }
    }

    for (e.descendant_swaps) |s| {
        _ = try db.categories_by_slug_path().delete(s.old_path);
        const d_id_key = codec.encodeU64(s.cat_id);
        try db.categories_by_slug_path().insert(s.new_path, &d_id_key);
    }

    if (e.enqueue.seq != 0) {
        var task = schema.RepairTask{
            .cat_id = e.new_cat.id,
            .op = e.enqueue.op,
            .created_at = e.enqueue.created_at,
            .old_slug_prefix = codec.FixedString(2048).fromSlice(e.enqueue.old_slug_prefix),
        };
        const key = codec.encodeU64(e.enqueue.seq);
        try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));
    }

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryMoved(db: *Directory, e: changeset.CategoryMoveEffect) !void {
    const id_key = codec.encodeU64(e.cat.id);

    try db.mt_categories_by_id().put(&id_key, std.mem.asBytes(&e.cat));

    const old_pc_key = schema.ParentChildKey.encode(.{ e.old_parent_id, e.cat.id });
    try db.mt_cat_by_parent().delete(&old_pc_key);
    const new_pc_key = schema.ParentChildKey.encode(.{ e.new_parent_id, e.cat.id });
    try db.mt_cat_by_parent().put(&new_pc_key, &id_key);

    _ = try db.categories_by_slug_path().delete(e.old_slug_path);
    try db.categories_by_slug_path().insert(e.new_slug_path, &id_key);

    for (e.descendant_swaps) |s| {
        _ = try db.categories_by_slug_path().delete(s.old_path);
        const d_id_key = codec.encodeU64(s.cat_id);
        try db.categories_by_slug_path().insert(s.new_path, &d_id_key);
    }

    if (e.enqueue.seq != 0) {
        var task = schema.RepairTask{
            .cat_id = e.cat.id,
            .op = e.enqueue.op,
            .created_at = e.enqueue.created_at,
            .old_slug_prefix = codec.FixedString(2048).fromSlice(e.enqueue.old_slug_prefix),
        };
        const key = codec.encodeU64(e.enqueue.seq);
        try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));
    }

    try apply.cascadeAncestorCounts(db, e.old_chain_updates, e.old_parent_id, .child_count, false);

    try apply.cascadeAncestorCounts(db, e.new_chain_updates, e.new_parent_id, .child_count, true);

    db.subtree_cache.invalidateAll();
}
test "applyCategoryInserted: writes primary + secondaries + slug paths + tokens + cascade" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_cat = schema.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("Test"),
        .slug = codec.FixedString(128).fromSlice("test"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "test"), .field = .name },
        .{ .text = try aa.dupe(u8, "test"), .field = .slug },
    });
    const cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = child_cat,
        .ancestor_updates = ancestors,
        .tokens = tokens,
        .slug_path = try aa.dupe(u8, "top/test"),
        .is_shallowest_for_slug = true,
    } };

    try db.commit(cs);

    const got_child = (try ops.getCategory(db, child_id)).?;
    try std.testing.expectEqual(child_id, got_child.id);
    try std.testing.expectEqual(top_id, got_child.parent_id);
    try std.testing.expectEqualStrings("Test", got_child.name.slice());
    try std.testing.expectEqualStrings("test", got_child.slug.slice());

    const pc_key = schema.ParentChildKey.encode(.{ top_id, child_id });
    var v_buf: [64]u8 = undefined;
    const pc_in_mt = db.mt_cat_by_parent().get(&pc_key);
    const pc_present = switch (pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent().search(&pc_key, &v_buf)) != null,
    };
    try std.testing.expect(pc_present);

    const child_id_be = codec.encodeU64(child_id);
    const slug_path_val = (try db.categories_by_slug_path().search("top/test", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_path_val);

    const slug_only_val = (try db.categories_by_slug_only().search("test", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_only_val);

    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..4], "test");
    @memcpy(token_key_buf[4..12], &child_id_be);
    try std.testing.expect((try db.categories_index_tree().search(token_key_buf[0..12], &v_buf)) != null);

    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count);
}

test "applyCategoryDeleted: reverses category_inserted (primary + secondaries + slug paths + tokens + cascade)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_cat = schema.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("Test"),
        .slug = codec.FixedString(128).fromSlice("test"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "test"), .field = .name },
        .{ .text = try aa.dupe(u8, "test"), .field = .slug },
    });
    const slug_path = try aa.dupe(u8, "top/test");
    const insert_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = child_cat,
        .ancestor_updates = insert_ancestors,
        .tokens = tokens,
        .slug_path = slug_path,
        .is_shallowest_for_slug = true,
    } };
    try db.commit(insert_cs);

    try std.testing.expect((try ops.getCategory(db, child_id)) != null);

    const delete_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = -1 },
    });
    const delete_cs = changeset.ChangeSet{ .category_deleted = .{
        .cat = child_cat,
        .ancestor_updates = delete_ancestors,
        .tokens = tokens,
        .slug_path = slug_path,
    } };
    try db.commit(delete_cs);

    try std.testing.expect((try ops.getCategory(db, child_id)) == null);

    const pc_key = schema.ParentChildKey.encode(.{ top_id, child_id });
    var v_buf: [64]u8 = undefined;
    const pc_in_mt = db.mt_cat_by_parent().get(&pc_key);
    const pc_present = switch (pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent().search(&pc_key, &v_buf)) != null,
    };
    try std.testing.expect(!pc_present);

    try std.testing.expect((try db.categories_by_slug_path().search("top/test", &v_buf)) == null);

    try std.testing.expect((try db.categories_by_slug_only().search("test", &v_buf)) == null);

    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..4], "test");
    const child_id_be = codec.encodeU64(child_id);
    @memcpy(token_key_buf[4..12], &child_id_be);
    try std.testing.expect((try db.categories_index_tree().search(token_key_buf[0..12], &v_buf)) == null);

    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), got_top.child_count);
}

test "applyCategoryTextUpdated: rewrites primary, swaps token entries; slug+counts unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_cat = schema.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("Foo"),
        .slug = codec.FixedString(128).fromSlice("test"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const insert_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "foo"), .field = .name },
        .{ .text = try aa.dupe(u8, "test"), .field = .slug },
    });
    const insert_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = child_cat,
        .ancestor_updates = insert_ancestors,
        .tokens = insert_tokens,
        .slug_path = try aa.dupe(u8, "top/test"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(insert_cs);

    var v_buf: [64]u8 = undefined;
    const child_id_be = codec.encodeU64(child_id);
    var foo_key: [32]u8 = undefined;
    @memcpy(foo_key[0..3], "foo");
    @memcpy(foo_key[3..11], &child_id_be);
    try std.testing.expect((try db.categories_index_tree().search(foo_key[0..11], &v_buf)) != null);
    var test_key: [32]u8 = undefined;
    @memcpy(test_key[0..4], "test");
    @memcpy(test_key[4..12], &child_id_be);
    try std.testing.expect((try db.categories_index_tree().search(test_key[0..12], &v_buf)) != null);

    const new_cat = schema.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("Bar"),
        .slug = codec.FixedString(128).fromSlice("test"),
        .description = codec.FixedString(1024).fromSlice("New desc"),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const old_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "foo"), .field = .name },
        .{ .text = try aa.dupe(u8, "test"), .field = .slug },
    });
    const new_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "bar"), .field = .name },
        .{ .text = try aa.dupe(u8, "test"), .field = .slug },
    });
    const update_cs = changeset.ChangeSet{ .category_text_updated = .{
        .old_cat = child_cat,
        .new_cat = new_cat,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };
    try db.commit(update_cs);

    const got_child = (try ops.getCategory(db, child_id)).?;
    try std.testing.expectEqualStrings("Bar", got_child.name.slice());
    try std.testing.expectEqualStrings("New desc", got_child.description.slice());
    try std.testing.expectEqualStrings("test", got_child.slug.slice());

    try std.testing.expect((try db.categories_index_tree().search(foo_key[0..11], &v_buf)) == null);

    var bar_key: [32]u8 = undefined;
    @memcpy(bar_key[0..3], "bar");
    @memcpy(bar_key[3..11], &child_id_be);
    try std.testing.expect((try db.categories_index_tree().search(bar_key[0..11], &v_buf)) != null);

    try std.testing.expect((try db.categories_index_tree().search(test_key[0..12], &v_buf)) != null);

    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count);
}

test "applyCategoryRenamed: rewrites self slug paths and rebuilds descendant slug paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const top_id = db.next_category_id.fetchAdd(1, .monotonic);
    const top_cat = schema.Category{
        .id = top_id,
        .parent_id = 0,
        .name = codec.FixedString(64).fromSlice("Top"),
        .slug = codec.FixedString(128).fromSlice("top"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const top_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = top_cat,
        .ancestor_updates = &.{},
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(top_cs);

    const c_id = db.next_category_id.fetchAdd(1, .monotonic);
    const c_cat = schema.Category{
        .id = c_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("C"),
        .slug = codec.FixedString(128).fromSlice("c"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const c_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const c_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = c_cat,
        .ancestor_updates = c_ancestors,
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/c"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(c_cs);

    const d_id = db.next_category_id.fetchAdd(1, .monotonic);
    const d_cat = schema.Category{
        .id = d_id,
        .parent_id = c_id,
        .name = codec.FixedString(64).fromSlice("D"),
        .slug = codec.FixedString(128).fromSlice("d"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const d_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = c_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const d_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = d_cat,
        .ancestor_updates = d_ancestors,
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/c/d"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(d_cs);

    const e_id = db.next_category_id.fetchAdd(1, .monotonic);
    const e_cat = schema.Category{
        .id = e_id,
        .parent_id = d_id,
        .name = codec.FixedString(64).fromSlice("E"),
        .slug = codec.FixedString(128).fromSlice("e"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const e_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = d_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        .{ .cat_id = c_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const e_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = e_cat,
        .ancestor_updates = e_ancestors,
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/c/d/e"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(e_cs);

    var v_buf: [64]u8 = undefined;
    const c_id_be = codec.encodeU64(c_id);
    const d_id_be = codec.encodeU64(d_id);
    const e_id_be = codec.encodeU64(e_id);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path().search("top/c", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path().search("top/c/d", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &e_id_be, (try db.categories_by_slug_path().search("top/c/d/e", &v_buf)).?);

    const c_renamed = schema.Category{
        .id = c_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("C"),
        .slug = codec.FixedString(128).fromSlice("newc"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 1,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const rename_swaps = try aa.dupe(changeset.SlugPathSwap, &.{
        .{ .old_path = "top/c/d", .new_path = "top/newc/d", .cat_id = d_id },
        .{ .old_path = "top/c/d/e", .new_path = "top/newc/d/e", .cat_id = e_id },
    });
    const rename_cs = changeset.ChangeSet{ .category_renamed = .{
        .old_cat = c_cat,
        .new_cat = c_renamed,
        .old_slug_path = try aa.dupe(u8, "top/c"),
        .new_slug_path = try aa.dupe(u8, "top/newc"),
        .descendant_swaps = rename_swaps,
        .above_threshold = false,
        .enqueue = .{},
    } };
    try db.commit(rename_cs);

    const got_c = (try ops.getCategory(db, c_id)).?;
    try std.testing.expectEqualStrings("newc", got_c.slug.slice());

    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path().search("top/newc", &v_buf)).?);
    try std.testing.expect((try db.categories_by_slug_path().search("top/c", &v_buf)) == null);

    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path().search("top/newc/d", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &e_id_be, (try db.categories_by_slug_path().search("top/newc/d/e", &v_buf)).?);

    try std.testing.expect((try db.categories_by_slug_only().search("c", &v_buf)) == null);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_only().search("newc", &v_buf)).?);

    try std.testing.expect((try db.categories_by_slug_path().search("top/c/d", &v_buf)) == null);
    try std.testing.expect((try db.categories_by_slug_path().search("top/c/d/e", &v_buf)) == null);
}

test "applyCategoryMoved: swaps cat_by_parent + rebuilds slug paths + cascades both chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const top_id = db.next_category_id.fetchAdd(1, .monotonic);
    const top_cat = schema.Category{
        .id = top_id,
        .parent_id = 0,
        .name = codec.FixedString(64).fromSlice("Top"),
        .slug = codec.FixedString(128).fromSlice("top"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = top_cat,
        .ancestor_updates = &.{},
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top"),
        .is_shallowest_for_slug = true,
    } });

    const a_id = db.next_category_id.fetchAdd(1, .monotonic);
    const a_cat = schema.Category{
        .id = a_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("A"),
        .slug = codec.FixedString(128).fromSlice("a"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = a_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/a"),
        .is_shallowest_for_slug = true,
    } });

    const b_id = db.next_category_id.fetchAdd(1, .monotonic);
    const b_cat = schema.Category{
        .id = b_id,
        .parent_id = top_id,
        .name = codec.FixedString(64).fromSlice("B"),
        .slug = codec.FixedString(128).fromSlice("b"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = b_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/b"),
        .is_shallowest_for_slug = true,
    } });

    const c_id = db.next_category_id.fetchAdd(1, .monotonic);
    const c_cat = schema.Category{
        .id = c_id,
        .parent_id = a_id,
        .name = codec.FixedString(64).fromSlice("C"),
        .slug = codec.FixedString(128).fromSlice("c"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = c_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = a_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/a/c"),
        .is_shallowest_for_slug = true,
    } });

    const d_id = db.next_category_id.fetchAdd(1, .monotonic);
    const d_cat = schema.Category{
        .id = d_id,
        .parent_id = c_id,
        .name = codec.FixedString(64).fromSlice("D"),
        .slug = codec.FixedString(128).fromSlice("d"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = d_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = c_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
            .{ .cat_id = a_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/a/c/d"),
        .is_shallowest_for_slug = true,
    } });

    var v_buf: [64]u8 = undefined;
    const c_id_be = codec.encodeU64(c_id);
    const d_id_be = codec.encodeU64(d_id);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path().search("top/a/c", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path().search("top/a/c/d", &v_buf)).?);

    const c_moved = schema.Category{
        .id = c_id,
        .parent_id = b_id,
        .name = codec.FixedString(64).fromSlice("C"),
        .slug = codec.FixedString(128).fromSlice("c"),
        .description = codec.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 1,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const old_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = a_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = -2 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = -2 },
    });
    const new_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = b_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 2 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 2 },
    });
    const move_swaps = try aa.dupe(changeset.SlugPathSwap, &.{
        .{ .old_path = "top/a/c/d", .new_path = "top/b/c/d", .cat_id = d_id },
    });
    const move_cs = changeset.ChangeSet{ .category_moved = .{
        .cat = c_moved,
        .old_parent_id = a_id,
        .new_parent_id = b_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
        .old_slug_path = try aa.dupe(u8, "top/a/c"),
        .new_slug_path = try aa.dupe(u8, "top/b/c"),
        .link_subtree_delta = 0,
        .child_subtree_delta = 0,
        .descendant_swaps = move_swaps,
        .above_threshold = false,
        .enqueue = .{},
    } };
    try db.commit(move_cs);

    const got_c = (try ops.getCategory(db, c_id)).?;
    try std.testing.expectEqual(b_id, got_c.parent_id);

    const old_pc_key = schema.ParentChildKey.encode(.{ a_id, c_id });
    const old_pc_in_mt = db.mt_cat_by_parent().get(&old_pc_key);
    const old_pc_present = switch (old_pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent().search(&old_pc_key, &v_buf)) != null,
    };
    try std.testing.expect(!old_pc_present);

    const new_pc_key = schema.ParentChildKey.encode(.{ b_id, c_id });
    const new_pc_in_mt = db.mt_cat_by_parent().get(&new_pc_key);
    const new_pc_present = switch (new_pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent().search(&new_pc_key, &v_buf)) != null,
    };
    try std.testing.expect(new_pc_present);

    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path().search("top/b/c", &v_buf)).?);
    try std.testing.expect((try db.categories_by_slug_path().search("top/a/c", &v_buf)) == null);
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path().search("top/b/c/d", &v_buf)).?);

    const got_a = (try ops.getCategory(db, a_id)).?;
    const got_b = (try ops.getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_a.child_count);
    try std.testing.expectEqual(@as(u32, 1), got_b.child_count);

    try std.testing.expectEqual(@as(u32, 0), got_a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), got_b.child_count_subtree);
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 4), got_top.child_count_subtree);

    try std.testing.expect((try db.categories_by_slug_path().search("top/a/c/d", &v_buf)) == null);
}
