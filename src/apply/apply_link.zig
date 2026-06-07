const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;
const apply = @import("apply.zig");

fn linkStatusCounter(db: *Directory, status: u8) ?*std.atomic.Value(u64) {
    return switch (status) {
        @intFromEnum(schema.LinkStatus.pending) => &db.links_pending_count,
        @intFromEnum(schema.LinkStatus.approved) => &db.links_approved_count,
        @intFromEnum(schema.LinkStatus.rejected) => &db.links_rejected_count,
        else => null,
    };
}

fn incrLinkStatus(db: *Directory, status: u8) void {
    if (linkStatusCounter(db, status)) |c| _ = c.fetchAdd(1, .monotonic);
}

fn decrLinkStatus(db: *Directory, status: u8) void {
    if (linkStatusCounter(db, status)) |c| {
        const cur = c.load(.monotonic);
        if (cur > 0) c.store(cur - 1, .monotonic);
    }
}

pub fn applyLinkInserted(db: *Directory, e: changeset.LinkInsertEffect) !void {
    const id_key = codec.encodeU64(e.link.id);

    const cl_key = schema.CategoryLinkKey.encode(e.link.category_id, e.link.id);
    try db.mt_link_by_category().put(&cl_key, &id_key);

    const hash_key = codec.encodeU64(codec.hash(e.link.url.slice()));
    try db.mt_link_by_url_hash().put(&hash_key, &id_key);

    if (e.link.submitter_id != 0) {
        const sl_key = schema.SubmitterLinkKey.encode(e.link.submitter_id, e.link.id);
        try db.mt_link_by_submitter().put(&sl_key, &id_key);
    }

    for (e.tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = codec.encodeU64(e.link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        try db.links_index_tree().insert(key_buf[0..key_len], &.{});
    }

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.link.category_id, .link_count, true);

    try db.mt_links_by_id().put(&id_key, std.mem.asBytes(&e.link));

    db.url_bloom.add(e.link.url.slice());
    incrLinkStatus(db, e.link.status);
    db.subtree_cache.invalidateAll();
}

pub fn applyLinkDeleted(db: *Directory, e: changeset.LinkDeleteEffect) !void {
    const id_key = codec.encodeU64(e.link.id);

    const cl_key = schema.CategoryLinkKey.encode(e.link.category_id, e.link.id);
    try db.mt_link_by_category().delete(&cl_key);

    const hash_key = codec.encodeU64(codec.hash(e.link.url.slice()));
    try db.mt_link_by_url_hash().delete(&hash_key);

    if (e.link.submitter_id != 0) {
        const sl_key = schema.SubmitterLinkKey.encode(e.link.submitter_id, e.link.id);
        try db.mt_link_by_submitter().delete(&sl_key);
    }

    for (e.tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = codec.encodeU64(e.link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        _ = try db.links_index_tree().delete(key_buf[0..key_len]);
    }

    try db.mt_links_by_id().delete(&id_key);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.link.category_id, .link_count, false);

    decrLinkStatus(db, e.link.status);

    db.subtree_cache.invalidateAll();
}

pub fn applyLinkTextUpdated(db: *Directory, e: changeset.LinkTextUpdateEffect) !void {
    const id_key = codec.encodeU64(e.new_link.id);

    try db.mt_links_by_id().put(&id_key, std.mem.asBytes(&e.new_link));

    for (e.old_tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = codec.encodeU64(e.new_link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        _ = try db.links_index_tree().delete(key_buf[0..key_len]);
    }
    for (e.new_tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = codec.encodeU64(e.new_link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        try db.links_index_tree().insert(key_buf[0..key_len], &.{});
    }

    if (!std.mem.eql(u8, e.old_link.url.slice(), e.new_link.url.slice())) {
        const old_hash_key = codec.encodeU64(codec.hash(e.old_link.url.slice()));
        try db.mt_link_by_url_hash().delete(&old_hash_key);
        const new_hash_key = codec.encodeU64(codec.hash(e.new_link.url.slice()));
        try db.mt_link_by_url_hash().put(&new_hash_key, &id_key);
        db.url_bloom.add(e.new_link.url.slice());
    }

    if (e.old_link.status != e.new_link.status) {
        decrLinkStatus(db, e.old_link.status);
        incrLinkStatus(db, e.new_link.status);
    }

    db.subtree_cache.invalidateAll();
}

pub fn applyLinkRecategorized(db: *Directory, e: changeset.LinkRecatEffect) !void {
    const id_key = codec.encodeU64(e.link.id);

    const old_cl_key = schema.CategoryLinkKey.encode(e.old_category_id, e.link.id);
    try db.mt_link_by_category().delete(&old_cl_key);

    try db.mt_links_by_id().put(&id_key, std.mem.asBytes(&e.link));

    const new_cl_key = schema.CategoryLinkKey.encode(e.link.category_id, e.link.id);
    try db.mt_link_by_category().put(&new_cl_key, &id_key);

    try apply.cascadeAncestorCounts(db, e.old_chain_updates, e.old_category_id, .link_count, false);

    try apply.cascadeAncestorCounts(db, e.new_chain_updates, e.link.category_id, .link_count, true);

    db.subtree_cache.invalidateAll();
}
test "applyLinkInserted: writes primary + secondaries + tokens + ancestor counts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 100;
    const link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice("https://x.example"),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
        .{ .text = try aa.dupe(u8, "world"), .field = .desc },
    });
    const cs = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    try db.commit(cs);

    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(link_id, got_link.id);

    const cl_key = schema.CategoryLinkKey.encode(cat_id, link_id);
    var v_buf: [64]u8 = undefined;
    const cl_in_mt = db.mt_link_by_category().get(&cl_key);
    const cl_present = switch (cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category().search(&cl_key, &v_buf)) != null,
    };
    try std.testing.expect(cl_present);

    const hash_key = codec.encodeU64(codec.hash("https://x.example"));
    const hash_in_mt = db.mt_link_by_url_hash().get(&hash_key);
    const hash_present = switch (hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash().search(&hash_key, &v_buf)) != null,
    };
    try std.testing.expect(hash_present);

    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..5], "hello");
    const link_id_be = codec.encodeU64(link_id);
    @memcpy(token_key_buf[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree().search(token_key_buf[0..13], &v_buf)) != null);

    const got_cat = (try ops.getCategory(db, cat_id)).?;
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), got_top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), got_cat.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_cat.link_count);
}

test "applyLinkInserted: retry is index-idempotent; recount reconciles delta double-count" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 200;
    const link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice("https://idempotent.example"),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const cs = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    try db.commit(cs);
    try std.testing.expectEqual(@as(u64, 1), (try ops.getCategory(db, cat_id)).?.link_count_subtree);

    try db.commit(cs);
    const after_second_cat = (try ops.getCategory(db, cat_id)).?;
    const after_second_top = (try ops.getCategory(db, top_id)).?;

    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(link_id, got_link.id);

    try std.testing.expectEqual(@as(u64, 2), after_second_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 2), after_second_top.link_count_subtree);

    try ops.recomputeCategoryCounts(db);
    try std.testing.expectEqual(@as(u64, 1), (try ops.getCategory(db, cat_id)).?.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), (try ops.getCategory(db, top_id)).?.link_count_subtree);
}

test "applyLinkDeleted: reverses link_inserted (primary + secondaries + tokens + counts)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 300;
    const link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice("https://reverse.example"),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
        .{ .text = try aa.dupe(u8, "world"), .field = .desc },
    });
    const insert_cs = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = insert_ancestors,
        .tokens = tokens,
    } };
    try db.commit(insert_cs);

    try std.testing.expect((try ops.getLink(db, link_id)) != null);

    const delete_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
    });
    const delete_cs = changeset.ChangeSet{ .link_deleted = .{
        .link = link,
        .ancestor_updates = delete_ancestors,
        .tokens = tokens,
    } };
    try db.commit(delete_cs);

    try std.testing.expect((try ops.getLink(db, link_id)) == null);

    const cl_key = schema.CategoryLinkKey.encode(cat_id, link_id);
    var v_buf: [64]u8 = undefined;
    const cl_in_mt = db.mt_link_by_category().get(&cl_key);
    const cl_present = switch (cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category().search(&cl_key, &v_buf)) != null,
    };
    try std.testing.expect(!cl_present);

    const hash_key = codec.encodeU64(codec.hash("https://reverse.example"));
    const hash_in_mt = db.mt_link_by_url_hash().get(&hash_key);
    const hash_present = switch (hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash().search(&hash_key, &v_buf)) != null,
    };
    try std.testing.expect(!hash_present);

    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..5], "hello");
    const link_id_be = codec.encodeU64(link_id);
    @memcpy(token_key_buf[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree().search(token_key_buf[0..13], &v_buf)) == null);

    const got_cat = (try ops.getCategory(db, cat_id)).?;
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 0), got_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 0), got_top.link_count_subtree);
}

test "applyLinkTextUpdated: same URL — primary rewritten, tokens swapped, hash unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 400;
    const url = "https://text-update.example";
    const old_link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice(url),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("Old desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const insert_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const insert_cs = changeset.ChangeSet{ .link_inserted = .{
        .link = old_link,
        .ancestor_updates = insert_ancestors,
        .tokens = insert_tokens,
    } };
    try db.commit(insert_cs);

    const new_link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice(url),
        .title = codec.FixedString(128).fromSlice("World"),
        .description = codec.FixedString(256).fromSlice("New desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const old_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const new_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "world"), .field = .title },
    });
    const update_cs = changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };
    try db.commit(update_cs);

    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqualStrings("World", got_link.title.slice());
    try std.testing.expectEqualStrings("New desc", got_link.description.slice());

    var v_buf: [64]u8 = undefined;
    var old_token_key: [32]u8 = undefined;
    @memcpy(old_token_key[0..5], "hello");
    const link_id_be = codec.encodeU64(link_id);
    @memcpy(old_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree().search(old_token_key[0..13], &v_buf)) == null);

    var new_token_key: [32]u8 = undefined;
    @memcpy(new_token_key[0..5], "world");
    @memcpy(new_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree().search(new_token_key[0..13], &v_buf)) != null);

    const hash_key = codec.encodeU64(codec.hash(url));
    const hash_in_mt = db.mt_link_by_url_hash().get(&hash_key);
    const hash_present = switch (hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash().search(&hash_key, &v_buf)) != null,
    };
    try std.testing.expect(hash_present);

    const got_cat = (try ops.getCategory(db, cat_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_cat.link_count);
}

test "applyLinkTextUpdated: URL changed — link_by_url_hash rewritten, bloom updated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 401;
    const old_url = "https://old.example";
    const new_url = "https://new.example";
    const old_link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice(old_url),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("Old desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const insert_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const insert_cs = changeset.ChangeSet{ .link_inserted = .{
        .link = old_link,
        .ancestor_updates = insert_ancestors,
        .tokens = insert_tokens,
    } };
    try db.commit(insert_cs);

    const new_link = schema.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = codec.FixedString(64).fromSlice(new_url),
        .title = codec.FixedString(128).fromSlice("World"),
        .description = codec.FixedString(256).fromSlice("New desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const old_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const new_tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "world"), .field = .title },
    });
    const update_cs = changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };
    try db.commit(update_cs);

    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqualStrings("World", got_link.title.slice());
    try std.testing.expectEqualStrings(new_url, got_link.url.slice());

    var v_buf: [64]u8 = undefined;

    const old_hash_key = codec.encodeU64(codec.hash(old_url));
    const old_hash_in_mt = db.mt_link_by_url_hash().get(&old_hash_key);
    const old_hash_present = switch (old_hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash().search(&old_hash_key, &v_buf)) != null,
    };
    try std.testing.expect(!old_hash_present);

    const new_hash_key = codec.encodeU64(codec.hash(new_url));
    const new_hash_in_mt = db.mt_link_by_url_hash().get(&new_hash_key);
    const new_hash_present = switch (new_hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash().search(&new_hash_key, &v_buf)) != null,
    };
    try std.testing.expect(new_hash_present);

    const link_id_be = codec.encodeU64(link_id);
    var old_token_key: [32]u8 = undefined;
    @memcpy(old_token_key[0..5], "hello");
    @memcpy(old_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree().search(old_token_key[0..13], &v_buf)) == null);

    var new_token_key: [32]u8 = undefined;
    @memcpy(new_token_key[0..5], "world");
    @memcpy(new_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree().search(new_token_key[0..13], &v_buf)) != null);

    try std.testing.expect(db.url_bloom.mayContain(new_url));
}

test "applyLinkRecategorized: swaps link_by_category and cascades both ancestor chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_a_id = try ops.createCategory(db, top_id, "A", "a", "");
    const cat_b_id = try ops.createCategory(db, top_id, "B", "b", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 500;
    const link_in_a = schema.Link{
        .id = link_id,
        .category_id = cat_a_id,
        .url = codec.FixedString(64).fromSlice("https://recat.example"),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_a_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const insert_cs = changeset.ChangeSet{ .link_inserted = .{
        .link = link_in_a,
        .ancestor_updates = insert_ancestors,
        .tokens = tokens,
    } };
    try db.commit(insert_cs);

    const link_in_b = schema.Link{
        .id = link_id,
        .category_id = cat_b_id,
        .url = codec.FixedString(64).fromSlice("https://recat.example"),
        .title = codec.FixedString(128).fromSlice("Hello"),
        .description = codec.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const old_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_a_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
    });
    const new_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_b_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const recat_cs = changeset.ChangeSet{ .link_recategorized = .{
        .link = link_in_b,
        .old_category_id = cat_a_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
    } };
    try db.commit(recat_cs);

    var v_buf: [64]u8 = undefined;

    const old_cl_key = schema.CategoryLinkKey.encode(cat_a_id, link_id);
    const old_cl_in_mt = db.mt_link_by_category().get(&old_cl_key);
    const old_cl_present = switch (old_cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category().search(&old_cl_key, &v_buf)) != null,
    };
    try std.testing.expect(!old_cl_present);

    const new_cl_key = schema.CategoryLinkKey.encode(cat_b_id, link_id);
    const new_cl_in_mt = db.mt_link_by_category().get(&new_cl_key);
    const new_cl_present = switch (new_cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category().search(&new_cl_key, &v_buf)) != null,
    };
    try std.testing.expect(new_cl_present);

    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(cat_b_id, got_link.category_id);

    const got_cat_a = (try ops.getCategory(db, cat_a_id)).?;
    const got_cat_b = (try ops.getCategory(db, cat_b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_cat_a.link_count);
    try std.testing.expectEqual(@as(u32, 1), got_cat_b.link_count);

    try std.testing.expectEqual(@as(u64, 0), got_cat_a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), got_cat_b.link_count_subtree);
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_top.link_count_subtree);
}
