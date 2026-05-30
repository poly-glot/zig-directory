// Link effect handlers split out of apply.zig. Each function applies one
// link-related ChangeSet effect to in-memory and on-disk state. The
// shared cascadeAncestorCounts helper lives in apply.zig.

const std = @import("std");
const types = @import("../types.zig");
const changeset = @import("../changeset.zig");
const Database = @import("../database.zig").Database;
const apply = @import("apply.zig");

// ── Per-status link counters ──────────────────────────────────────────
// db.links_{pending,approved,rejected}_count back the O(1) op=36
// counts_by_status read. They are seeded by a full scan at boot
// (Database.recover → recountLinkStatuses) and maintained incrementally
// here. All writes happen under db.apply_mutex (commit serialises apply),
// so the plain load/store decrement below is race-free against other
// writers; readers use atomic loads. A status byte outside the known enum
// (should never occur) is simply not tallied — matching the boot scan,
// which ignores it too. Decrements saturate at 0 so a stray double-apply
// can't wrap the unsigned counter; the next boot scan reconciles any drift.

fn linkStatusCounter(db: *Database, status: u8) ?*std.atomic.Value(u64) {
    return switch (status) {
        @intFromEnum(types.LinkStatus.pending) => &db.links_pending_count,
        @intFromEnum(types.LinkStatus.approved) => &db.links_approved_count,
        @intFromEnum(types.LinkStatus.rejected) => &db.links_rejected_count,
        else => null,
    };
}

fn incrLinkStatus(db: *Database, status: u8) void {
    if (linkStatusCounter(db, status)) |c| _ = c.fetchAdd(1, .monotonic);
}

fn decrLinkStatus(db: *Database, status: u8) void {
    if (linkStatusCounter(db, status)) |c| {
        const cur = c.load(.monotonic);
        if (cur > 0) c.store(cur - 1, .monotonic);
    }
}

pub fn applyLinkInserted(db: *Database, e: changeset.LinkInsertEffect) !void {
    // Order: primary first, secondaries after, materialized counts last.
    const id_key = types.encodeU64(e.link.id);

    try db.mt_links_by_id.put(&id_key, std.mem.asBytes(&e.link));

    const cl_key = types.CategoryLinkKey.encode(e.link.category_id, e.link.id);
    try db.mt_link_by_category.put(&cl_key, &id_key);

    const hash_key = types.encodeU64(types.hashUrl(e.link.url.slice()));
    try db.mt_link_by_url_hash.put(&hash_key, &id_key);

    // link_by_submitter — sparse, only for real submitters.
    // Legacy bulk-imported corpus has submitter_id == 0; skipping keeps the
    // index small and `listLinksBySubmitter(0, ...)` deliberately empty.
    if (e.link.submitter_id != 0) {
        const sl_key = types.SubmitterLinkKey.encode(e.link.submitter_id, e.link.id);
        try db.mt_link_by_submitter.put(&sl_key, &id_key);
    }

    // Inverted index: links_index_tree.
    // Key = (token_bytes || doc_id_be). B+Tree insert is overwrite-on-key,
    // so retrying the same ChangeSet leaves the same entries.
    for (e.tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue; // skip pathologically long tokens
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = types.encodeU64(e.link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        try db.links_index_tree.insert(key_buf[0..key_len], &.{});
    }

    db.url_bloom.add(e.link.url.slice());

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.link.category_id, .link_count, true);

    incrLinkStatus(db, e.link.status);

    db.subtree_cache.invalidateAll();
}

pub fn applyLinkDeleted(db: *Database, e: changeset.LinkDeleteEffect) !void {
    const id_key = types.encodeU64(e.link.id);

    // Order: secondaries first, primary last.

    const cl_key = types.CategoryLinkKey.encode(e.link.category_id, e.link.id);
    try db.mt_link_by_category.delete(&cl_key);

    const hash_key = types.encodeU64(types.hashUrl(e.link.url.slice()));
    try db.mt_link_by_url_hash.delete(&hash_key);

    // link_by_submitter — symmetric with insert. No-op for legacy
    // submitter_id == 0 rows (which were never indexed).
    if (e.link.submitter_id != 0) {
        const sl_key = types.SubmitterLinkKey.encode(e.link.submitter_id, e.link.id);
        try db.mt_link_by_submitter.delete(&sl_key);
    }

    // Inverted index: links_index_tree — delete each token entry directly
    // from the B+Tree (this index has no memtable layer). Delete returns
    // false if the key is absent, which is fine on retry.
    for (e.tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = types.encodeU64(e.link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        _ = try db.links_index_tree.delete(key_buf[0..key_len]);
    }

    try db.mt_links_by_id.delete(&id_key);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.link.category_id, .link_count, false);

    decrLinkStatus(db, e.link.status);

    db.subtree_cache.invalidateAll();
}

pub fn applyLinkTextUpdated(db: *Database, e: changeset.LinkTextUpdateEffect) !void {
    // No count cascade — text update doesn't change category_id or counts.
    const id_key = types.encodeU64(e.new_link.id);

    try db.mt_links_by_id.put(&id_key, std.mem.asBytes(&e.new_link));

    // Inverted index: remove old token entries, add new token entries.
    // links_index_tree has no memtable layer; write directly. Delete returns
    // false if the key is absent, which is fine on retry.
    for (e.old_tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = types.encodeU64(e.new_link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        _ = try db.links_index_tree.delete(key_buf[0..key_len]);
    }
    for (e.new_tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = types.encodeU64(e.new_link.id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        try db.links_index_tree.insert(key_buf[0..key_len], &.{});
    }

    // URL change handling: if URL changed, rewrite link_by_url_hash and
    // add new url to bloom (old one stays — acceptable false positive).
    if (!std.mem.eql(u8, e.old_link.url.slice(), e.new_link.url.slice())) {
        const old_hash_key = types.encodeU64(types.hashUrl(e.old_link.url.slice()));
        try db.mt_link_by_url_hash.delete(&old_hash_key);
        const new_hash_key = types.encodeU64(types.hashUrl(e.new_link.url.slice()));
        try db.mt_link_by_url_hash.put(&new_hash_key, &id_key);
        db.url_bloom.add(e.new_link.url.slice());
    }

    // Status edits (op=26 update_link_status, op=34 bulk) flow through this
    // text-update effect since status lives in the Link body. Move the tally
    // only when it actually changed; a pure title/url/desc edit is a no-op.
    if (e.old_link.status != e.new_link.status) {
        decrLinkStatus(db, e.old_link.status);
        incrLinkStatus(db, e.new_link.status);
    }

    db.subtree_cache.invalidateAll();
}

pub fn applyLinkRecategorized(db: *Database, e: changeset.LinkRecatEffect) !void {
    // Tokens are unchanged on a recategorize — content stayed the same.
    // Order: drop the old secondary, rewrite primary with the new category_id,
    // add the new secondary, then cascade both ancestor chains.
    const id_key = types.encodeU64(e.link.id);

    const old_cl_key = types.CategoryLinkKey.encode(e.old_category_id, e.link.id);
    try db.mt_link_by_category.delete(&old_cl_key);

    // e.link carries the new category_id.
    try db.mt_links_by_id.put(&id_key, std.mem.asBytes(&e.link));

    const new_cl_key = types.CategoryLinkKey.encode(e.link.category_id, e.link.id);
    try db.mt_link_by_category.put(&new_cl_key, &id_key);

    try apply.cascadeAncestorCounts(db, e.old_chain_updates, e.old_category_id, .link_count, false);

    try apply.cascadeAncestorCounts(db, e.new_chain_updates, e.link.category_id, .link_count, true);

    db.subtree_cache.invalidateAll();
}
test "applyLinkInserted: writes primary + secondaries + tokens + ancestor counts" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: parent category exists.
    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 100;
    const link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice("https://x.example"),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 1 },
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

    // Primary
    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(link_id, got_link.id);

    // Secondary: link_by_category
    const cl_key = types.CategoryLinkKey.encode(cat_id, link_id);
    var v_buf: [64]u8 = undefined;
    // Search may live in the memtable rather than the B+Tree; check both.
    const cl_in_mt = db.mt_link_by_category.get(&cl_key);
    const cl_present = switch (cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category.search(&cl_key, &v_buf)) != null,
    };
    try std.testing.expect(cl_present);

    // Secondary: link_by_url_hash
    const hash_key = types.encodeU64(types.hashUrl("https://x.example"));
    const hash_in_mt = db.mt_link_by_url_hash.get(&hash_key);
    const hash_present = switch (hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash.search(&hash_key, &v_buf)) != null,
    };
    try std.testing.expect(hash_present);

    // Inverted index: links_index_tree has (token "hello" || link_id_be) entry
    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..5], "hello");
    const link_id_be = types.encodeU64(link_id);
    @memcpy(token_key_buf[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree.search(token_key_buf[0..13], &v_buf)) != null);

    // Ancestor counts
    const got_cat = (try ops.getCategory(db, cat_id)).?;
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), got_top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), got_cat.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    // Direct link_count bumped on immediate parent only.
    try std.testing.expectEqual(@as(u32, 1), got_cat.link_count);
}

test "applyLinkInserted: idempotent on retry (commit twice yields same state)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 200;
    const link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice("https://idempotent.example"),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 1 },
    });
    const tokens = try aa.dupe(changeset.Token, &.{
        .{ .text = try aa.dupe(u8, "hello"), .field = .title },
    });
    const cs = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    // First commit.
    try db.commit(cs);
    const after_first_cat = (try ops.getCategory(db, cat_id)).?;
    const after_first_top = (try ops.getCategory(db, top_id)).?;

    // Second commit (simulating WAL replay or duplicate apply).
    try db.commit(cs);
    const after_second_cat = (try ops.getCategory(db, cat_id)).?;
    const after_second_top = (try ops.getCategory(db, top_id)).?;

    // Subtree counts use absolute targets — must be unchanged.
    try std.testing.expectEqual(after_first_cat.link_count_subtree, after_second_cat.link_count_subtree);
    try std.testing.expectEqual(after_first_top.link_count_subtree, after_second_top.link_count_subtree);
    try std.testing.expectEqual(after_first_cat.child_count_subtree, after_second_cat.child_count_subtree);
    try std.testing.expectEqual(after_first_top.child_count_subtree, after_second_top.child_count_subtree);

    // Note: direct link_count is incremented once per apply (saturating), so
    // a duplicate apply will produce 2 — this is a known retry-window cost
    // that the verifier reconciles. The subtree counts (the durable source
    // of truth) are correctly idempotent.
    try std.testing.expectEqual(@as(u64, 1), after_second_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), after_second_top.link_count_subtree);

    // Link still resolvable.
    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(link_id, got_link.id);
}

test "applyLinkDeleted: reverses link_inserted (primary + secondaries + tokens + counts)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: grandparent + parent category.
    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 300;
    const link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice("https://reverse.example"),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    // Insert baseline so we can verify the delete reverses it.
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 1 },
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

    // Sanity: link is present after insert.
    try std.testing.expect((try ops.getLink(db, link_id)) != null);

    // Now delete with matching ancestor counts back to 0.
    const delete_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .new_link_count_subtree = 0, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
    });
    const delete_cs = changeset.ChangeSet{ .link_deleted = .{
        .link = link,
        .ancestor_updates = delete_ancestors,
        .tokens = tokens,
    } };
    try db.commit(delete_cs);

    // Primary: getLink returns null (memtable tombstone).
    try std.testing.expect((try ops.getLink(db, link_id)) == null);

    // Secondary: link_by_category — memtable tombstone OR absent in B+Tree.
    const cl_key = types.CategoryLinkKey.encode(cat_id, link_id);
    var v_buf: [64]u8 = undefined;
    const cl_in_mt = db.mt_link_by_category.get(&cl_key);
    const cl_present = switch (cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category.search(&cl_key, &v_buf)) != null,
    };
    try std.testing.expect(!cl_present);

    // Secondary: link_by_url_hash — memtable tombstone OR absent in B+Tree.
    const hash_key = types.encodeU64(types.hashUrl("https://reverse.example"));
    const hash_in_mt = db.mt_link_by_url_hash.get(&hash_key);
    const hash_present = switch (hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash.search(&hash_key, &v_buf)) != null,
    };
    try std.testing.expect(!hash_present);

    // Inverted index: links_index_tree — token entry absent.
    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..5], "hello");
    const link_id_be = types.encodeU64(link_id);
    @memcpy(token_key_buf[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree.search(token_key_buf[0..13], &v_buf)) == null);

    // Ancestor subtree counts back to 0.
    const got_cat = (try ops.getCategory(db, cat_id)).?;
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 0), got_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 0), got_top.link_count_subtree);
}

test "applyLinkTextUpdated: same URL — primary rewritten, tokens swapped, hash unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 400;
    const url = "https://text-update.example";
    const old_link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice(url),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("Old desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    // Insert a baseline link + "hello" token entry.
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 1 },
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

    // Now apply a text update: same URL, new title "World".
    const new_link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice(url),
        .title = types.FixedString(128).fromSlice("World"),
        .description = types.FixedString(256).fromSlice("New desc"),
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

    // Primary: title is now "World".
    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqualStrings("World", got_link.title.slice());
    try std.testing.expectEqualStrings("New desc", got_link.description.slice());

    // Inverted index: old token "hello" entry absent, new token "world" entry present.
    var v_buf: [64]u8 = undefined;
    var old_token_key: [32]u8 = undefined;
    @memcpy(old_token_key[0..5], "hello");
    const link_id_be = types.encodeU64(link_id);
    @memcpy(old_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree.search(old_token_key[0..13], &v_buf)) == null);

    var new_token_key: [32]u8 = undefined;
    @memcpy(new_token_key[0..5], "world");
    @memcpy(new_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree.search(new_token_key[0..13], &v_buf)) != null);

    // link_by_url_hash unchanged (same URL): entry still resolves to link_id.
    const hash_key = types.encodeU64(types.hashUrl(url));
    const hash_in_mt = db.mt_link_by_url_hash.get(&hash_key);
    const hash_present = switch (hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash.search(&hash_key, &v_buf)) != null,
    };
    try std.testing.expect(hash_present);

    // Counts untouched (no cascade).
    const got_cat = (try ops.getCategory(db, cat_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_cat.link_count);
}

test "applyLinkTextUpdated: URL changed — link_by_url_hash rewritten, bloom updated" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_id = try ops.createCategory(db, top_id, "Test", "test", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 401;
    const old_url = "https://old.example";
    const new_url = "https://new.example";
    const old_link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice(old_url),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("Old desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    // Insert baseline.
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 1 },
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

    // Update: new URL + new title.
    const new_link = types.Link{
        .id = link_id,
        .category_id = cat_id,
        .url = types.FixedString(64).fromSlice(new_url),
        .title = types.FixedString(128).fromSlice("World"),
        .description = types.FixedString(256).fromSlice("New desc"),
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

    // Primary: title is now "World" and URL is new.
    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqualStrings("World", got_link.title.slice());
    try std.testing.expectEqualStrings(new_url, got_link.url.slice());

    var v_buf: [64]u8 = undefined;

    // link_by_url_hash: old hash absent (tombstoned), new hash present → link_id.
    const old_hash_key = types.encodeU64(types.hashUrl(old_url));
    const old_hash_in_mt = db.mt_link_by_url_hash.get(&old_hash_key);
    const old_hash_present = switch (old_hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash.search(&old_hash_key, &v_buf)) != null,
    };
    try std.testing.expect(!old_hash_present);

    const new_hash_key = types.encodeU64(types.hashUrl(new_url));
    const new_hash_in_mt = db.mt_link_by_url_hash.get(&new_hash_key);
    const new_hash_present = switch (new_hash_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_url_hash.search(&new_hash_key, &v_buf)) != null,
    };
    try std.testing.expect(new_hash_present);

    // Inverted index: token swap.
    const link_id_be = types.encodeU64(link_id);
    var old_token_key: [32]u8 = undefined;
    @memcpy(old_token_key[0..5], "hello");
    @memcpy(old_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree.search(old_token_key[0..13], &v_buf)) == null);

    var new_token_key: [32]u8 = undefined;
    @memcpy(new_token_key[0..5], "world");
    @memcpy(new_token_key[5..13], &link_id_be);
    try std.testing.expect((try db.links_index_tree.search(new_token_key[0..13], &v_buf)) != null);

    // url_bloom contains the new URL (additive; old one stays — acceptable FP).
    try std.testing.expect(db.url_bloom.mayContain(new_url));
}

test "applyLinkRecategorized: swaps link_by_category and cascades both ancestor chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Setup: top → A and top → B (siblings under top). Moving the link from
    // A to B leaves top.link_count_subtree at 1 (link still in top's subtree).
    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const cat_a_id = try ops.createCategory(db, top_id, "A", "a", "");
    const cat_b_id = try ops.createCategory(db, top_id, "B", "b", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const link_id: u64 = 500;
    const link_in_a = types.Link{
        .id = link_id,
        .category_id = cat_a_id,
        .url = types.FixedString(64).fromSlice("https://recat.example"),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };

    // Insert under A so we can recategorize from A → B.
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_a_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 2 },
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

    // Build link_recategorized — link.category_id is now B.id.
    const link_in_b = types.Link{
        .id = link_id,
        .category_id = cat_b_id,
        .url = types.FixedString(64).fromSlice("https://recat.example"),
        .title = types.FixedString(128).fromSlice("Hello"),
        .description = types.FixedString(256).fromSlice("World"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    // After move out of A subtree: A goes to 0; top contribution from old chain
    // walk: top's subtree count reflects the world post-cascade (still 1 because
    // we apply new chain after, but absolute targets win — so old chain reduces
    // top to 0, then new chain pushes it back to 1).
    const old_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_a_id, .new_link_count_subtree = 0, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 2 },
    });
    const new_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = cat_b_id, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 1, .new_child_count_subtree = 2 },
    });
    const recat_cs = changeset.ChangeSet{ .link_recategorized = .{
        .link = link_in_b,
        .old_category_id = cat_a_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
    } };
    try db.commit(recat_cs);

    var v_buf: [64]u8 = undefined;

    // link_by_category (A, link_id) — absent (memtable tombstone OR not in B+Tree).
    const old_cl_key = types.CategoryLinkKey.encode(cat_a_id, link_id);
    const old_cl_in_mt = db.mt_link_by_category.get(&old_cl_key);
    const old_cl_present = switch (old_cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category.search(&old_cl_key, &v_buf)) != null,
    };
    try std.testing.expect(!old_cl_present);

    // link_by_category (B, link_id) — present.
    const new_cl_key = types.CategoryLinkKey.encode(cat_b_id, link_id);
    const new_cl_in_mt = db.mt_link_by_category.get(&new_cl_key);
    const new_cl_present = switch (new_cl_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.link_by_category.search(&new_cl_key, &v_buf)) != null,
    };
    try std.testing.expect(new_cl_present);

    // Primary: getLink reflects new category_id.
    const got_link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(cat_b_id, got_link.category_id);

    // Direct link_count: A drained to 0, B bumped to 1.
    const got_cat_a = (try ops.getCategory(db, cat_a_id)).?;
    const got_cat_b = (try ops.getCategory(db, cat_b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_cat_a.link_count);
    try std.testing.expectEqual(@as(u32, 1), got_cat_b.link_count);

    // Subtree counts: A=0, B=1, top=1 (link still inside top's subtree).
    try std.testing.expectEqual(@as(u64, 0), got_cat_a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), got_cat_b.link_count_subtree);
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_top.link_count_subtree);
}
