// Category effect handlers split out of apply.zig. Each function applies
// one category-related ChangeSet effect (insert/delete/text/rename/move).
// The shared cascadeAncestorCounts helper lives in apply.zig.

const std = @import("std");
const types = @import("../types.zig");
const changeset = @import("../changeset.zig");
const Database = @import("../database.zig").Database;
const apply = @import("apply.zig");

pub fn applyCategoryInserted(db: *Database, e: changeset.CategoryInsertEffect) !void {
    const id_key = types.encodeU64(e.cat.id);

    try db.mt_categories_by_id.put(&id_key, std.mem.asBytes(&e.cat));

    // cat_by_parent — value is the child id (8-byte BE).
    const pc_key = types.ParentChildKey.encode(e.cat.parent_id, e.cat.id);
    try db.mt_cat_by_parent.put(&pc_key, &id_key);

    // Slug paths: canonical full path → cat_id. categories_by_slug_path
    // has no memtable layer; insert is overwrite-on-key, so retries are
    // idempotent.
    try db.categories_by_slug_path.insert(e.slug_path, &id_key);

    // Slug-only: only insert when this category is the shallowest holder
    // of the leaf slug. Deeper duplicates of the same slug must not
    // overwrite the shallowest entry.
    if (e.is_shallowest_for_slug) {
        try db.categories_by_slug_only.insert(e.cat.slug.slice(), &id_key);
    }

    // Inverted index: categories_index_tree.
    // Key = (token_bytes || cat_id_be), value empty. Overwrite-on-key.
    for (e.tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue; // skip pathologically long tokens
        @memcpy(key_buf[0..t.text.len], t.text);
        const cat_id_be = types.encodeU64(e.cat.id);
        @memcpy(key_buf[t.text.len..][0..8], &cat_id_be);
        try db.categories_index_tree.insert(key_buf[0..key_len], &.{});
    }

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.cat.parent_id, .child_count, true);

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryDeleted(db: *Database, e: changeset.CategoryDeleteEffect) !void {
    // Pre-condition (validated outside apply): the category has no children
    // and no links. Order: secondaries first, primary last.
    const id_key = types.encodeU64(e.cat.id);

    const pc_key = types.ParentChildKey.encode(e.cat.parent_id, e.cat.id);
    try db.mt_cat_by_parent.delete(&pc_key);

    // categories_by_slug_path — direct B+Tree delete (no memtable layer).
    // delete returns false if absent, which is fine on retry.
    _ = try db.categories_by_slug_path.delete(e.slug_path);

    // categories_by_slug_only — only delete if it currently points at THIS
    // cat. A deeper sibling may be the shallowest holder of the slug, in
    // which case the slug_only entry refers to that other cat and we must
    // not touch it. Read first, compare value, then delete.
    var slug_only_buf: [16]u8 = undefined;
    if (try db.categories_by_slug_only.search(e.cat.slug.slice(), &slug_only_buf)) |val| {
        if (val.len == 8 and std.mem.eql(u8, val, &id_key)) {
            _ = try db.categories_by_slug_only.delete(e.cat.slug.slice());
        }
    }

    // Inverted index: categories_index_tree — delete each token entry.
    // Key = (token_bytes || cat_id_be).
    for (e.tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const cat_id_be = types.encodeU64(e.cat.id);
        @memcpy(key_buf[t.text.len..][0..8], &cat_id_be);
        _ = try db.categories_index_tree.delete(key_buf[0..key_len]);
    }

    try db.mt_categories_by_id.delete(&id_key);

    try apply.cascadeAncestorCounts(db, e.ancestor_updates, e.cat.parent_id, .child_count, false);

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryTextUpdated(db: *Database, e: changeset.CategoryTextUpdateEffect) !void {
    // Slug is unchanged on a text edit (name + description only). No
    // slug-path/slug-only mutation; no count cascade. Mirrors
    // applyLinkTextUpdated for the categories side.
    const id_key = types.encodeU64(e.new_cat.id);

    try db.mt_categories_by_id.put(&id_key, std.mem.asBytes(&e.new_cat));

    // Inverted index: remove old token entries, add new token entries.
    // categories_index_tree has no memtable layer; write directly. Delete
    // returns false if the key is absent, which is fine on retry. Insert
    // is overwrite-on-key, so any token that appears in both old_tokens
    // and new_tokens (e.g. an unchanged slug token) survives the swap
    // because the new_tokens insert re-creates the entry.
    for (e.old_tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const cat_id_be = types.encodeU64(e.new_cat.id);
        @memcpy(key_buf[t.text.len..][0..8], &cat_id_be);
        _ = try db.categories_index_tree.delete(key_buf[0..key_len]);
    }
    for (e.new_tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const cat_id_be = types.encodeU64(e.new_cat.id);
        @memcpy(key_buf[t.text.len..][0..8], &cat_id_be);
        try db.categories_index_tree.insert(key_buf[0..key_len], &.{});
    }

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryRenamed(db: *Database, e: changeset.CategoryRenameEffect) !void {
    const id_key = types.encodeU64(e.new_cat.id);

    try db.mt_categories_by_id.put(&id_key, std.mem.asBytes(&e.new_cat));

    // Slug-path tree: delete old path, insert new path for self.
    // categories_by_slug_path has no memtable layer; write directly.
    _ = try db.categories_by_slug_path.delete(e.old_slug_path);
    try db.categories_by_slug_path.insert(e.new_slug_path, &id_key);

    // Slug-only maintenance — only when the slug actually changed.
    // Best-effort per plan: drop the old entry if it pointed at this cat,
    // insert the new entry only if no existing slug_only entry holds the
    // new slug. The "find shallowest" is a follow-up; verifier picks up
    // drift in the meantime.
    if (!std.mem.eql(u8, e.old_cat.slug.slice(), e.new_cat.slug.slice())) {
        var slug_only_buf: [16]u8 = undefined;
        if (try db.categories_by_slug_only.search(e.old_cat.slug.slice(), &slug_only_buf)) |val| {
            if (val.len == 8 and std.mem.eql(u8, val, &id_key)) {
                _ = try db.categories_by_slug_only.delete(e.old_cat.slug.slice());
                // Note: not picking a successor here — verifier handles drift.
            }
        }
        if ((try db.categories_by_slug_only.search(e.new_cat.slug.slice(), &slug_only_buf)) == null) {
            try db.categories_by_slug_only.insert(e.new_cat.slug.slice(), &id_key);
        }
    }

    // Atomic descendant slug-path swaps. Empty when above_threshold
    // (cleanup deferred to repair_worker). Delete-old then insert-new
    // matches applySlugPathRepairChunk so both paths leave identical
    // state in `categories_by_slug_path`.
    for (e.descendant_swaps) |s| {
        _ = try db.categories_by_slug_path.delete(s.old_path);
        const d_id_key = types.encodeU64(s.cat_id);
        try db.categories_by_slug_path.insert(s.new_path, &d_id_key);
    }

    // Enqueue repair task when above_threshold (sentinel: seq != 0).
    if (e.enqueue.seq != 0) {
        var task = types.RepairTask{
            .cat_id = e.new_cat.id,
            .op = e.enqueue.op,
            .created_at = e.enqueue.created_at,
            .old_slug_prefix = types.FixedString(1024).fromSlice(e.enqueue.old_slug_prefix),
        };
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, e.enqueue.seq, .big);
        try db.slug_path_repair_queue.insert(&key, std.mem.asBytes(&task));
    }

    db.subtree_cache.invalidateAll();
}

pub fn applyCategoryMoved(db: *Database, e: changeset.CategoryMoveEffect) !void {
    const id_key = types.encodeU64(e.cat.id);

    // e.cat carries the new parent_id.
    try db.mt_categories_by_id.put(&id_key, std.mem.asBytes(&e.cat));

    // cat_by_parent — drop (old_parent, cat), add (new_parent, cat).
    // Memtable-fronted (matches every other cat_by_parent write).
    const old_pc_key = types.ParentChildKey.encode(e.old_parent_id, e.cat.id);
    try db.mt_cat_by_parent.delete(&old_pc_key);
    const new_pc_key = types.ParentChildKey.encode(e.new_parent_id, e.cat.id);
    try db.mt_cat_by_parent.put(&new_pc_key, &id_key);

    // Update slug-path tree for self — direct B+Tree (no memtable layer).
    // Slug-only is intentionally NOT touched: a move doesn't change the
    // leaf slug, only the ancestor chain.
    _ = try db.categories_by_slug_path.delete(e.old_slug_path);
    try db.categories_by_slug_path.insert(e.new_slug_path, &id_key);

    // Atomic descendant slug-path swaps. Empty when above_threshold
    // (cleanup deferred to repair_worker).
    for (e.descendant_swaps) |s| {
        _ = try db.categories_by_slug_path.delete(s.old_path);
        const d_id_key = types.encodeU64(s.cat_id);
        try db.categories_by_slug_path.insert(s.new_path, &d_id_key);
    }

    // Enqueue repair task when above_threshold (sentinel: seq != 0).
    if (e.enqueue.seq != 0) {
        var task = types.RepairTask{
            .cat_id = e.cat.id,
            .op = e.enqueue.op,
            .created_at = e.enqueue.created_at,
            .old_slug_prefix = types.FixedString(1024).fromSlice(e.enqueue.old_slug_prefix),
        };
        var key: [8]u8 = undefined;
        std.mem.writeInt(u64, &key, e.enqueue.seq, .big);
        try db.slug_path_repair_queue.insert(&key, std.mem.asBytes(&task));
    }

    try apply.cascadeAncestorCounts(db, e.old_chain_updates, e.old_parent_id, .child_count, false);

    try apply.cascadeAncestorCounts(db, e.new_chain_updates, e.new_parent_id, .child_count, true);

    db.subtree_cache.invalidateAll();
}
test "applyCategoryInserted: writes primary + secondaries + slug paths + tokens + cascade" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: top category exists. createCategory cascades child_count_subtree
    // up to root (id=0, absent), so top.child_count_subtree starts at 0.
    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Allocate a child id manually since we're synthesising the ChangeSet.
    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_cat = types.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("Test"),
        .slug = types.FixedString(128).fromSlice("test"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
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

    // Primary: getCategory(child_id) returns the synthesised cat.
    const got_child = (try ops.getCategory(db, child_id)).?;
    try std.testing.expectEqual(child_id, got_child.id);
    try std.testing.expectEqual(top_id, got_child.parent_id);
    try std.testing.expectEqualStrings("Test", got_child.name.slice());
    try std.testing.expectEqualStrings("test", got_child.slug.slice());

    // Secondary: cat_by_parent contains (top, child) — memtable then B+Tree.
    const pc_key = types.ParentChildKey.encode(top_id, child_id);
    var v_buf: [64]u8 = undefined;
    const pc_in_mt = db.mt_cat_by_parent.get(&pc_key);
    const pc_present = switch (pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent.search(&pc_key, &v_buf)) != null,
    };
    try std.testing.expect(pc_present);

    // Slug path: categories_by_slug_path["top/test"] → child_id (8-byte BE).
    const child_id_be = types.encodeU64(child_id);
    const slug_path_val = (try db.categories_by_slug_path.search("top/test", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_path_val);

    // Slug-only: categories_by_slug_only["test"] → child_id.
    const slug_only_val = (try db.categories_by_slug_only.search("test", &v_buf)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_only_val);

    // Inverted index: categories_index_tree has ("test" || child_id_be).
    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..4], "test");
    @memcpy(token_key_buf[4..12], &child_id_be);
    try std.testing.expect((try db.categories_index_tree.search(token_key_buf[0..12], &v_buf)) != null);

    // Cascade: top.child_count_subtree == 1.
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    // Direct child_count bumped on immediate parent (top went 0 → 1).
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count);
}

test "applyCategoryDeleted: reverses category_inserted (primary + secondaries + slug paths + tokens + cascade)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: top category exists.
    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Insert a child via category_inserted so we have a clean post-state
    // to delete from.
    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_cat = types.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("Test"),
        .slug = types.FixedString(128).fromSlice("test"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
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

    // Sanity: child is present after insert.
    try std.testing.expect((try ops.getCategory(db, child_id)) != null);

    // Now delete with ancestor counts back to 0.
    const delete_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 0 },
    });
    const delete_cs = changeset.ChangeSet{ .category_deleted = .{
        .cat = child_cat,
        .ancestor_updates = delete_ancestors,
        .tokens = tokens,
        .slug_path = slug_path,
    } };
    try db.commit(delete_cs);

    // Primary: getCategory returns null (memtable tombstone).
    try std.testing.expect((try ops.getCategory(db, child_id)) == null);

    // Secondary: cat_by_parent — memtable tombstone OR absent in B+Tree.
    const pc_key = types.ParentChildKey.encode(top_id, child_id);
    var v_buf: [64]u8 = undefined;
    const pc_in_mt = db.mt_cat_by_parent.get(&pc_key);
    const pc_present = switch (pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent.search(&pc_key, &v_buf)) != null,
    };
    try std.testing.expect(!pc_present);

    // Slug path: categories_by_slug_path["top/test"] absent.
    try std.testing.expect((try db.categories_by_slug_path.search("top/test", &v_buf)) == null);

    // Slug-only: categories_by_slug_only["test"] absent.
    try std.testing.expect((try db.categories_by_slug_only.search("test", &v_buf)) == null);

    // Inverted index: token entry ("test" || child_id_be) absent.
    var token_key_buf: [32]u8 = undefined;
    @memcpy(token_key_buf[0..4], "test");
    const child_id_be = types.encodeU64(child_id);
    @memcpy(token_key_buf[4..12], &child_id_be);
    try std.testing.expect((try db.categories_index_tree.search(token_key_buf[0..12], &v_buf)) == null);

    // Cascade: top.child_count_subtree back to 0; direct child_count back to 0.
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), got_top.child_count);
}

test "applyCategoryTextUpdated: rewrites primary, swaps token entries; slug+counts unchanged" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Set up: top + child via category_inserted so the child has tokens
    // "foo" + "test" already in categories_index_tree.
    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_cat = types.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("Foo"),
        .slug = types.FixedString(128).fromSlice("test"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const insert_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
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

    // Sanity: pre-state has both tokens present.
    var v_buf: [64]u8 = undefined;
    const child_id_be = types.encodeU64(child_id);
    var foo_key: [32]u8 = undefined;
    @memcpy(foo_key[0..3], "foo");
    @memcpy(foo_key[3..11], &child_id_be);
    try std.testing.expect((try db.categories_index_tree.search(foo_key[0..11], &v_buf)) != null);
    var test_key: [32]u8 = undefined;
    @memcpy(test_key[0..4], "test");
    @memcpy(test_key[4..12], &child_id_be);
    try std.testing.expect((try db.categories_index_tree.search(test_key[0..12], &v_buf)) != null);

    // Now apply a text update: same id, same parent, same slug; new name "Bar"
    // and new description.
    const new_cat = types.Category{
        .id = child_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("Bar"),
        .slug = types.FixedString(128).fromSlice("test"),
        .description = types.FixedString(1024).fromSlice("New desc"),
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

    // Primary: name is now "Bar", description updated, slug still "test".
    const got_child = (try ops.getCategory(db, child_id)).?;
    try std.testing.expectEqualStrings("Bar", got_child.name.slice());
    try std.testing.expectEqualStrings("New desc", got_child.description.slice());
    try std.testing.expectEqualStrings("test", got_child.slug.slice());

    // Old token "foo" entry absent.
    try std.testing.expect((try db.categories_index_tree.search(foo_key[0..11], &v_buf)) == null);

    // New token "bar" entry present.
    var bar_key: [32]u8 = undefined;
    @memcpy(bar_key[0..3], "bar");
    @memcpy(bar_key[3..11], &child_id_be);
    try std.testing.expect((try db.categories_index_tree.search(bar_key[0..11], &v_buf)) != null);

    // Persistent token "test" still present: B+Tree insert is overwrite-on-key,
    // so a token that appears in both old_tokens and new_tokens is reinserted
    // by the new_tokens pass after old_tokens removed it.
    try std.testing.expect((try db.categories_index_tree.search(test_key[0..12], &v_buf)) != null);

    // Counts untouched (no cascade): top.child_count_subtree still 1.
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count);
}

test "applyCategoryRenamed: rewrites self slug paths and rebuilds descendant slug paths" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Set up: top → C (slug "c") → D (slug "d") → E (slug "e") via
    // synthesised category_inserted ChangeSets.
    const top_id = db.next_category_id.fetchAdd(1, .monotonic);
    const top_cat = types.Category{
        .id = top_id,
        .parent_id = 0,
        .name = types.FixedString(64).fromSlice("Top"),
        .slug = types.FixedString(128).fromSlice("top"),
        .description = types.FixedString(1024).fromSlice(""),
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
    const c_cat = types.Category{
        .id = c_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("C"),
        .slug = types.FixedString(128).fromSlice("c"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const c_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
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
    const d_cat = types.Category{
        .id = d_id,
        .parent_id = c_id,
        .name = types.FixedString(64).fromSlice("D"),
        .slug = types.FixedString(128).fromSlice("d"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const d_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = c_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 2 },
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
    const e_cat = types.Category{
        .id = e_id,
        .parent_id = d_id,
        .name = types.FixedString(64).fromSlice("E"),
        .slug = types.FixedString(128).fromSlice("e"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const e_ancestors = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = d_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
        .{ .cat_id = c_id, .new_link_count_subtree = 0, .new_child_count_subtree = 2 },
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 3 },
    });
    const e_cs = changeset.ChangeSet{ .category_inserted = .{
        .cat = e_cat,
        .ancestor_updates = e_ancestors,
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/c/d/e"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(e_cs);

    // Sanity: initial slug paths in place.
    var v_buf: [64]u8 = undefined;
    const c_id_be = types.encodeU64(c_id);
    const d_id_be = types.encodeU64(d_id);
    const e_id_be = types.encodeU64(e_id);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path.search("top/c", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path.search("top/c/d", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &e_id_be, (try db.categories_by_slug_path.search("top/c/d/e", &v_buf)).?);

    // Build category_renamed ChangeSet for C: "c" → "newc".
    const c_renamed = types.Category{
        .id = c_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("C"),
        .slug = types.FixedString(128).fromSlice("newc"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 1,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    // Populate descendant_swaps as compute would for a below-threshold
    // rename of C (whose subtree is D, E). This is the contract the apply
    // path now consumes; absent these the descendants would not move.
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

    // Primary: getCategory(C.id).slug == "newc".
    const got_c = (try ops.getCategory(db, c_id)).?;
    try std.testing.expectEqualStrings("newc", got_c.slug.slice());

    // categories_by_slug_path: self moved.
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path.search("top/newc", &v_buf)).?);
    try std.testing.expect((try db.categories_by_slug_path.search("top/c", &v_buf)) == null);

    // Descendants reinserted under new ancestor slug.
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path.search("top/newc/d", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &e_id_be, (try db.categories_by_slug_path.search("top/newc/d/e", &v_buf)).?);

    // Slug-only swap.
    try std.testing.expect((try db.categories_by_slug_only.search("c", &v_buf)) == null);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_only.search("newc", &v_buf)).?);

    // Orphan absence: every old descendant slug-path must be gone after
    // apply consumes descendant_swaps. (Previously this block was a
    // deliberate non-assertion because rebuildDescendantSlugPaths didn't
    // delete old paths.) Slice 1 closes the gap.
    try std.testing.expect((try db.categories_by_slug_path.search("top/c/d", &v_buf)) == null);
    try std.testing.expect((try db.categories_by_slug_path.search("top/c/d/e", &v_buf)) == null);
}

test "applyCategoryMoved: swaps cat_by_parent + rebuilds slug paths + cascades both chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Set up: top → A, top → B (siblings), A → C, C → D.
    // Initial paths: "top/a", "top/b", "top/a/c", "top/a/c/d"
    // Move C from A to B. Expect: "top/b/c", "top/b/c/d"; A.child_count → 0,
    // B.child_count → 1; subtree counts cascade.
    const top_id = db.next_category_id.fetchAdd(1, .monotonic);
    const top_cat = types.Category{
        .id = top_id,
        .parent_id = 0,
        .name = types.FixedString(64).fromSlice("Top"),
        .slug = types.FixedString(128).fromSlice("top"),
        .description = types.FixedString(1024).fromSlice(""),
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
    const a_cat = types.Category{
        .id = a_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("A"),
        .slug = types.FixedString(128).fromSlice("a"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = a_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/a"),
        .is_shallowest_for_slug = true,
    } });

    const b_id = db.next_category_id.fetchAdd(1, .monotonic);
    const b_cat = types.Category{
        .id = b_id,
        .parent_id = top_id,
        .name = types.FixedString(64).fromSlice("B"),
        .slug = types.FixedString(128).fromSlice("b"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = b_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 2 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/b"),
        .is_shallowest_for_slug = true,
    } });

    const c_id = db.next_category_id.fetchAdd(1, .monotonic);
    const c_cat = types.Category{
        .id = c_id,
        .parent_id = a_id,
        .name = types.FixedString(64).fromSlice("C"),
        .slug = types.FixedString(128).fromSlice("c"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = c_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = a_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
            .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 3 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/a/c"),
        .is_shallowest_for_slug = true,
    } });

    const d_id = db.next_category_id.fetchAdd(1, .monotonic);
    const d_cat = types.Category{
        .id = d_id,
        .parent_id = c_id,
        .name = types.FixedString(64).fromSlice("D"),
        .slug = types.FixedString(128).fromSlice("d"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    try db.commit(.{ .category_inserted = .{
        .cat = d_cat,
        .ancestor_updates = try aa.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = c_id, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
            .{ .cat_id = a_id, .new_link_count_subtree = 0, .new_child_count_subtree = 2 },
            .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 4 },
        }),
        .tokens = &.{},
        .slug_path = try aa.dupe(u8, "top/a/c/d"),
        .is_shallowest_for_slug = true,
    } });

    // Sanity: initial paths in place.
    var v_buf: [64]u8 = undefined;
    const c_id_be = types.encodeU64(c_id);
    const d_id_be = types.encodeU64(d_id);
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path.search("top/a/c", &v_buf)).?);
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path.search("top/a/c/d", &v_buf)).?);

    // Build category_moved ChangeSet for C: parent A → parent B.
    // After move: A loses subtree of 2 (C + D). B gains subtree of 2.
    // top's child_count_subtree unchanged (4: A + B + C + D).
    const c_moved = types.Category{
        .id = c_id,
        .parent_id = b_id, // new parent
        .name = types.FixedString(64).fromSlice("C"),
        .slug = types.FixedString(128).fromSlice("c"),
        .description = types.FixedString(1024).fromSlice(""),
        .link_count = 0,
        .child_count = 1, // C still has D as a child
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 2000,
    };
    const old_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = a_id, .new_link_count_subtree = 0, .new_child_count_subtree = 0 },
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 4 },
    });
    const new_chain = try aa.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = b_id, .new_link_count_subtree = 0, .new_child_count_subtree = 2 },
        .{ .cat_id = top_id, .new_link_count_subtree = 0, .new_child_count_subtree = 4 },
    });
    // Below-threshold move populates descendant_swaps for every
    // descendant; the apply path consumes them to keep slug-path
    // entries free of orphans.
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

    // Primary: getCategory(C).parent_id == B.id.
    const got_c = (try ops.getCategory(db, c_id)).?;
    try std.testing.expectEqual(b_id, got_c.parent_id);

    // cat_by_parent: (B, C) present, (A, C) absent. Memtable-then-B+Tree.
    const old_pc_key = types.ParentChildKey.encode(a_id, c_id);
    const old_pc_in_mt = db.mt_cat_by_parent.get(&old_pc_key);
    const old_pc_present = switch (old_pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent.search(&old_pc_key, &v_buf)) != null,
    };
    try std.testing.expect(!old_pc_present);

    const new_pc_key = types.ParentChildKey.encode(b_id, c_id);
    const new_pc_in_mt = db.mt_cat_by_parent.get(&new_pc_key);
    const new_pc_present = switch (new_pc_in_mt) {
        .found => true,
        .deleted => false,
        .not_found => (try db.cat_by_parent.search(&new_pc_key, &v_buf)) != null,
    };
    try std.testing.expect(new_pc_present);

    // Slug paths: self moved, descendant rebuilt under new ancestry.
    try std.testing.expectEqualSlices(u8, &c_id_be, (try db.categories_by_slug_path.search("top/b/c", &v_buf)).?);
    try std.testing.expect((try db.categories_by_slug_path.search("top/a/c", &v_buf)) == null);
    try std.testing.expectEqualSlices(u8, &d_id_be, (try db.categories_by_slug_path.search("top/b/c/d", &v_buf)).?);

    // child_count: A drained to 0, B bumped to 1.
    const got_a = (try ops.getCategory(db, a_id)).?;
    const got_b = (try ops.getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_a.child_count);
    try std.testing.expectEqual(@as(u32, 1), got_b.child_count);

    // child_count_subtree: A=0, B=2 (C + D), top unchanged (4 = A+B+C+D).
    try std.testing.expectEqual(@as(u32, 0), got_a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), got_b.child_count_subtree);
    const got_top = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 4), got_top.child_count_subtree);

    // Orphan absence: the old descendant slug-path entry must be gone
    // after apply consumes descendant_swaps. (Previously this was a
    // deliberate non-assertion because rebuildDescendantSlugPaths didn't
    // delete old paths.) Slice 1 closes the gap.
    try std.testing.expect((try db.categories_by_slug_path.search("top/a/c/d", &v_buf)) == null);
}
