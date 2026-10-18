const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;
const apply = @import("apply.zig");
const test_support = @import("../test_support.zig");

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

fn urlHashOwner(db: *Directory, hash_key: *const [8]u8) !?u64 {
    const in_memtable = db.mt_link_by_url_hash().get(hash_key);
    const owner_bytes: []const u8 = switch (in_memtable) {
        .found => |v| v,
        .deleted => return null,
        .not_found => blk: {
            var tree_buf: [8]u8 = undefined;
            break :blk (try db.link_by_url_hash().search(hash_key, &tree_buf)) orelse return null;
        },
    };
    if (owner_bytes.len < 8) return null;
    return codec.decodeU64(owner_bytes[0..8]);
}

fn deleteUrlHashIfOwnedBy(db: *Directory, url: []const u8, link_id: u64) !void {
    const hash_key = codec.encodeU64(codec.hash(url));
    const owner = (try urlHashOwner(db, &hash_key)) orelse return;
    if (owner != link_id) return;
    try db.mt_link_by_url_hash().delete(&hash_key);
}

pub fn applyLinkInserted(db: *Directory, e: changeset.LinkInsertEffect) !void {
    const id_key = codec.encodeU64(e.link.id);

    const cl_key = schema.CategoryLinkKey.encode(.{ e.link.category_id, e.link.id });
    try db.mt_link_by_category().put(&cl_key, &id_key);

    const hash_key = codec.encodeU64(codec.hash(e.link.url.slice()));
    try db.mt_link_by_url_hash().put(&hash_key, &id_key);

    if (e.link.submitter_id != 0) {
        const sl_key = schema.SubmitterLinkKey.encode(.{ e.link.submitter_id, e.link.id });
        try db.mt_link_by_submitter().put(&sl_key, &id_key);
    }

    try apply.writeTokens(db.links_index_tree(), e.tokens, e.link.id, .insert);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.link.category_id, .link_count, true);

    try db.mt_links_by_id().put(&id_key, std.mem.asBytes(&e.link));
    db.noteIssuedLinkId(e.link.id);

    db.url_bloom.add(e.link.url.slice());
    incrLinkStatus(db, e.link.status);
    db.subtree_cache.invalidateAll();
}

pub fn applyLinkVectorsPut(db: *Directory, e: changeset.LinkVectorsPutEffect) !void {
    db.store.counter("embedding_model").* = e.model;
    db.vectors.model.store(e.model, .release);

    for (e.vectors) |v| {
        const key = codec.encodeU64(v.link_id);
        try db.link_vectors().insert(&key, std.mem.asBytes(&v));
        try db.vectors.put(db.io, db.allocator, v);
    }
}

fn deleteLinkVector(db: *Directory, link_id: u64) !void {
    const key = codec.encodeU64(link_id);
    _ = try db.link_vectors().delete(&key);
    db.vectors.remove(db.io, link_id);
}

pub fn applyLinkDeleted(db: *Directory, e: changeset.LinkDeleteEffect) !void {
    const id_key = codec.encodeU64(e.link.id);

    const cl_key = schema.CategoryLinkKey.encode(.{ e.link.category_id, e.link.id });
    try db.mt_link_by_category().delete(&cl_key);

    try deleteUrlHashIfOwnedBy(db, e.link.url.slice(), e.link.id);

    if (e.link.submitter_id != 0) {
        const sl_key = schema.SubmitterLinkKey.encode(.{ e.link.submitter_id, e.link.id });
        try db.mt_link_by_submitter().delete(&sl_key);
    }

    try apply.writeTokens(db.links_index_tree(), e.tokens, e.link.id, .delete);

    try db.mt_links_by_id().delete(&id_key);
    try deleteLinkVector(db, e.link.id);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.link.category_id, .link_count, false);

    decrLinkStatus(db, e.link.status);

    db.subtree_cache.invalidateAll();
}

pub fn applyLinkTextUpdated(db: *Directory, e: changeset.LinkTextUpdateEffect) !void {
    const id_key = codec.encodeU64(e.new_link.id);

    try db.mt_links_by_id().put(&id_key, std.mem.asBytes(&e.new_link));

    try apply.writeTokens(db.links_index_tree(), e.old_tokens, e.new_link.id, .delete);
    try apply.writeTokens(db.links_index_tree(), e.new_tokens, e.new_link.id, .insert);

    if (schema.embeddedTextChanged(e.old_link, e.new_link)) try deleteLinkVector(db, e.new_link.id);

    if (!std.mem.eql(u8, e.old_link.url.slice(), e.new_link.url.slice())) {
        try deleteUrlHashIfOwnedBy(db, e.old_link.url.slice(), e.new_link.id);
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

    const old_cl_key = schema.CategoryLinkKey.encode(.{ e.old_category_id, e.link.id });
    try db.mt_link_by_category().delete(&old_cl_key);

    try db.mt_links_by_id().put(&id_key, std.mem.asBytes(&e.link));

    const new_cl_key = schema.CategoryLinkKey.encode(.{ e.link.category_id, e.link.id });
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
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 100;
    const link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = "https://x.example",
        .title = "Hello",
        .description = "World",
    });
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

    const cl_key = schema.CategoryLinkKey.encode(.{ cat_id, link_id });
    var v_buf: [64]u8 = undefined;
    const cl_present = try test_support.isPresent(db.mt_link_by_category(), db.link_by_category(), &cl_key);
    try std.testing.expect(cl_present);

    const hash_key = codec.encodeU64(codec.hash("https://x.example"));
    const hash_present = try test_support.isPresent(db.mt_link_by_url_hash(), db.link_by_url_hash(), &hash_key);
    try std.testing.expect(hash_present);

    var token_key_buf: [32]u8 = undefined;
    const token_key = test_support.tokenKey(&token_key_buf, "hello", link_id);
    try std.testing.expect((try db.links_index_tree().search(token_key, &v_buf)) != null);

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
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 200;
    const link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = "https://idempotent.example",
        .title = "Hello",
        .description = "World",
    });
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
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 300;
    const link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = "https://reverse.example",
        .title = "Hello",
        .description = "World",
    });

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

    const cl_key = schema.CategoryLinkKey.encode(.{ cat_id, link_id });
    var v_buf: [64]u8 = undefined;
    const cl_present = try test_support.isPresent(db.mt_link_by_category(), db.link_by_category(), &cl_key);
    try std.testing.expect(!cl_present);

    const hash_key = codec.encodeU64(codec.hash("https://reverse.example"));
    const hash_present = try test_support.isPresent(db.mt_link_by_url_hash(), db.link_by_url_hash(), &hash_key);
    try std.testing.expect(!hash_present);

    var token_key_buf: [32]u8 = undefined;
    const token_key = test_support.tokenKey(&token_key_buf, "hello", link_id);
    try std.testing.expect((try db.links_index_tree().search(token_key, &v_buf)) == null);

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
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 400;
    const url = "https://text-update.example";
    const old_link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = url,
        .title = "Hello",
        .description = "Old desc",
    });

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

    const new_link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = url,
        .title = "World",
        .description = "New desc",
        .updated_at = 2000,
    });
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
    var old_token_key_buf: [32]u8 = undefined;
    const old_token_key = test_support.tokenKey(&old_token_key_buf, "hello", link_id);
    try std.testing.expect((try db.links_index_tree().search(old_token_key, &v_buf)) == null);

    var new_token_key_buf: [32]u8 = undefined;
    const new_token_key = test_support.tokenKey(&new_token_key_buf, "world", link_id);
    try std.testing.expect((try db.links_index_tree().search(new_token_key, &v_buf)) != null);

    const hash_key = codec.encodeU64(codec.hash(url));
    const hash_present = try test_support.isPresent(db.mt_link_by_url_hash(), db.link_by_url_hash(), &hash_key);
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
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 401;
    const old_url = "https://old.example";
    const new_url = "https://new.example";
    const old_link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = old_url,
        .title = "Hello",
        .description = "Old desc",
    });

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

    const new_link = test_support.link(.{
        .id = link_id,
        .category_id = cat_id,
        .url = new_url,
        .title = "World",
        .description = "New desc",
        .updated_at = 2000,
    });
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
    const old_hash_present = try test_support.isPresent(db.mt_link_by_url_hash(), db.link_by_url_hash(), &old_hash_key);
    try std.testing.expect(!old_hash_present);

    const new_hash_key = codec.encodeU64(codec.hash(new_url));
    const new_hash_present = try test_support.isPresent(db.mt_link_by_url_hash(), db.link_by_url_hash(), &new_hash_key);
    try std.testing.expect(new_hash_present);

    var old_token_key_buf: [32]u8 = undefined;
    const old_token_key = test_support.tokenKey(&old_token_key_buf, "hello", link_id);
    try std.testing.expect((try db.links_index_tree().search(old_token_key, &v_buf)) == null);

    var new_token_key_buf: [32]u8 = undefined;
    const new_token_key = test_support.tokenKey(&new_token_key_buf, "world", link_id);
    try std.testing.expect((try db.links_index_tree().search(new_token_key, &v_buf)) != null);

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
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 500;
    const link_in_a = test_support.link(.{
        .id = link_id,
        .category_id = cat_a_id,
        .url = "https://recat.example",
        .title = "Hello",
        .description = "World",
    });

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

    const link_in_b = test_support.link(.{
        .id = link_id,
        .category_id = cat_b_id,
        .url = "https://recat.example",
        .title = "Hello",
        .description = "World",
        .updated_at = 2000,
    });
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

    const old_cl_key = schema.CategoryLinkKey.encode(.{ cat_a_id, link_id });
    const old_cl_present = try test_support.isPresent(db.mt_link_by_category(), db.link_by_category(), &old_cl_key);
    try std.testing.expect(!old_cl_present);

    const new_cl_key = schema.CategoryLinkKey.encode(.{ cat_b_id, link_id });
    const new_cl_present = try test_support.isPresent(db.mt_link_by_category(), db.link_by_category(), &new_cl_key);
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

test "deleting a link whose url hash maps to another link leaves that link's hash entry intact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const no_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{});
    const no_tokens = try aa.dupe(changeset.Token, &.{});

    const shared_url = "https://collide.example";
    const first = schema.Link{ .id = 300, .category_id = top_id, .url = codec.FixedString(64).fromSlice(shared_url) };
    const second = schema.Link{ .id = 301, .category_id = top_id, .url = codec.FixedString(64).fromSlice(shared_url) };
    try db.commit(.{ .link_inserted = .{ .link = first, .ancestor_updates = no_ancestors, .tokens = no_tokens } });
    try db.commit(.{ .link_inserted = .{ .link = second, .ancestor_updates = no_ancestors, .tokens = no_tokens } });

    try db.commit(.{ .link_deleted = .{ .link = first, .ancestor_updates = no_ancestors, .tokens = no_tokens } });

    const hash_key = codec.encodeU64(codec.hash(shared_url));
    try std.testing.expectEqual(@as(?u64, 301), try urlHashOwner(db, &hash_key));
}
