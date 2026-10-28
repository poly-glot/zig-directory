//! Link appliers. The primary record, the category, URL-hash and submitter secondaries, the
//! token postings, the ancestor counts and the status counters move together under one change
//! set, so a crash between two of them is repaired by replaying the whole record.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;
const apply = @import("apply.zig");
const test_support = @import("../test_support.zig");
const vectors_per_write_max = @import("../operations/operations_vector.zig").vectors_per_write_max;
const entity_writes_max = @import("../operations/operations_facts.zig").entity_writes_max;

fn link_status_counter(db: *Directory, status: u8) ?*std.atomic.Value(u64) {
    return switch (status) {
        @intFromEnum(schema.LinkStatus.pending) => &db.links_pending_count,
        @intFromEnum(schema.LinkStatus.approved) => &db.links_approved_count,
        @intFromEnum(schema.LinkStatus.rejected) => &db.links_rejected_count,
        else => null,
    };
}

fn increment_link_status(db: *Directory, status: u8) void {
    const counter = link_status_counter(db, status) orelse return;
    _ = counter.fetchAdd(1, .monotonic);
}

fn decrement_link_status(db: *Directory, status: u8) void {
    const counter = link_status_counter(db, status) orelse return;
    const current = counter.load(.monotonic);
    if (current > 0) counter.store(current - 1, .monotonic);
}

fn url_hash_owner(db: *Directory, hash_key: *const [8]u8) !?u64 {
    var tree_buffer: [8]u8 = undefined;
    const owner_bytes: []const u8 = switch (db.memtable_link_by_url_hash().get(hash_key)) {
        .found => |value| value,
        .deleted => return null,
        .not_found => (try db.link_by_url_hash().search(hash_key, &tree_buffer)) orelse return null,
    };
    if (owner_bytes.len < 8) return null;
    return codec.decodeU64(owner_bytes[0..8]);
}

fn delete_url_hash_if_owned_by(db: *Directory, url: []const u8, link_id: u64) !void {
    assert(link_id != 0);
    const hash_key = codec.encodeU64(codec.hash(url));
    const owner = (try url_hash_owner(db, &hash_key)) orelse return;
    if (owner != link_id) return;
    try db.memtable_link_by_url_hash().delete(&hash_key);
    assert((try url_hash_owner(db, &hash_key)) == null);
}

pub fn apply_link_inserted(db: *Directory, effect: *const changeset.LinkInsertEffect) !void {
    assert(effect.link.id != 0);
    const id_key = codec.encodeU64(effect.link.id);

    const category_link_key = schema.CategoryLinkKey.encode(.{
        effect.link.category_id,
        effect.link.id,
    });
    try db.memtable_link_by_category().put(&category_link_key, &id_key);
    assert(db.memtable_link_by_category().get(&category_link_key) != .deleted);

    const hash_key = codec.encodeU64(codec.hash(effect.link.url.slice()));
    try db.memtable_link_by_url_hash().put(&hash_key, &id_key);
    assert(db.memtable_link_by_url_hash().get(&hash_key) != .deleted);

    if (effect.link.submitter_id != 0) {
        const submitter_link_key = schema.SubmitterLinkKey.encode(.{
            effect.link.submitter_id,
            effect.link.id,
        });
        try db.memtable_link_by_submitter().put(&submitter_link_key, &id_key);
    }

    try apply.write_tokens(db.links_index_tree(), effect.tokens, effect.link.id, .insert);

    try apply.cascade_ancestor_counts(
        db,
        effect.ancestor_updates,
        effect.link.category_id,
        .link_count,
        true,
    );

    try db.memtable_links_by_id().put(&id_key, std.mem.asBytes(&effect.link));
    assert(db.memtable_links_by_id().get(&id_key) != .deleted);
    db.note_issued_link_id(effect.link.id);
    assert(db.next_link_id.load(.monotonic) > effect.link.id);

    db.url_bloom.add(effect.link.url.slice());
    increment_link_status(db, effect.link.status);
    db.subtree_cache.invalidate_all();
}

pub fn apply_link_vectors_put(db: *Directory, effect: *const changeset.LinkVectorsPutEffect) !void {
    assert(effect.model != 0);
    assert(effect.vectors.len <= vectors_per_write_max);
    db.store.counter("embedding_model").* = effect.model;
    db.link_vector_index.model.store(effect.model, .release);

    for (effect.vectors) |vector| {
        assert(vector.id != 0);
        const encoded = db.link_vector_index.codebooks.encode(&vector);
        const record = schema.LinkVector{
            .vector = vector,
            .model_hash = db.link_vector_index.codebooks.hash,
            .cell = encoded.cell,
            .codes = encoded.codes,
        };
        const key = codec.encodeU64(vector.id);
        try db.link_vectors().insert(&key, std.mem.asBytes(&record));
        try db.link_vector_index.put(db.io, db.allocator, vector.id, &encoded);
    }
}

fn delete_link_vector(db: *Directory, link_id: u64) !void {
    assert(link_id != 0);
    const key = codec.encodeU64(link_id);
    _ = try db.link_vectors().delete(&key);
    db.link_vector_index.remove(db.io, link_id);
}

pub fn apply_link_entities_put(db: *Directory, effect: changeset.LinkEntitiesPutEffect) !void {
    assert(effect.entries.len <= entity_writes_max);
    for (effect.entries) |entry| {
        assert(entry.link_id != 0);
        const key = codec.encodeU64(entry.link_id);
        try db.link_entities().insert(&key, entry.facts);
    }
}

fn delete_text_derived_facts(db: *Directory, link_id: u64) !void {
    assert(link_id != 0);
    try delete_link_vector(db, link_id);
    const key = codec.encodeU64(link_id);
    _ = try db.link_entities().delete(&key);
}

pub fn apply_link_deleted(db: *Directory, effect: *const changeset.LinkDeleteEffect) !void {
    assert(effect.link.id != 0);
    const id_key = codec.encodeU64(effect.link.id);

    const category_link_key = schema.CategoryLinkKey.encode(.{
        effect.link.category_id,
        effect.link.id,
    });
    try db.memtable_link_by_category().delete(&category_link_key);
    assert(db.memtable_link_by_category().get(&category_link_key) != .found);

    try delete_url_hash_if_owned_by(db, effect.link.url.slice(), effect.link.id);

    if (effect.link.submitter_id != 0) {
        const submitter_link_key = schema.SubmitterLinkKey.encode(.{
            effect.link.submitter_id,
            effect.link.id,
        });
        try db.memtable_link_by_submitter().delete(&submitter_link_key);
    }

    try apply.write_tokens(db.links_index_tree(), effect.tokens, effect.link.id, .delete);

    try db.memtable_links_by_id().delete(&id_key);
    assert(db.memtable_links_by_id().get(&id_key) != .found);
    try delete_text_derived_facts(db, effect.link.id);

    try apply.cascade_ancestor_counts(
        db,
        effect.ancestor_updates,
        effect.link.category_id,
        .link_count,
        false,
    );

    decrement_link_status(db, effect.link.status);

    db.subtree_cache.invalidate_all();
}

pub fn apply_link_text_updated(
    db: *Directory,
    effect: *const changeset.LinkTextUpdateEffect,
) !void {
    assert(effect.new_link.id != 0);
    assert(effect.old_link.id == effect.new_link.id);
    assert(effect.old_link.category_id == effect.new_link.category_id);
    const id_key = codec.encodeU64(effect.new_link.id);

    try db.memtable_links_by_id().put(&id_key, std.mem.asBytes(&effect.new_link));
    assert(db.memtable_links_by_id().get(&id_key) != .deleted);

    try apply.write_tokens(db.links_index_tree(), effect.old_tokens, effect.new_link.id, .delete);
    try apply.write_tokens(db.links_index_tree(), effect.new_tokens, effect.new_link.id, .insert);

    if (schema.embedded_text_changed(
        &effect.old_link,
        &effect.new_link,
    )) try delete_text_derived_facts(db, effect.new_link.id);

    if (!std.mem.eql(u8, effect.old_link.url.slice(), effect.new_link.url.slice())) {
        try delete_url_hash_if_owned_by(db, effect.old_link.url.slice(), effect.new_link.id);
        const new_hash_key = codec.encodeU64(codec.hash(effect.new_link.url.slice()));
        try db.memtable_link_by_url_hash().put(&new_hash_key, &id_key);
        assert(db.memtable_link_by_url_hash().get(&new_hash_key) != .deleted);
        db.url_bloom.add(effect.new_link.url.slice());
    }

    if (effect.old_link.status != effect.new_link.status) {
        decrement_link_status(db, effect.old_link.status);
        increment_link_status(db, effect.new_link.status);
    }

    db.subtree_cache.invalidate_all();
}

pub fn apply_link_recategorized(db: *Directory, effect: *const changeset.LinkRecatEffect) !void {
    assert(effect.link.id != 0);
    assert(effect.link.category_id != 0);
    assert(effect.old_category_id != effect.link.category_id);
    const id_key = codec.encodeU64(effect.link.id);

    const old_category_link_key = schema.CategoryLinkKey.encode(.{
        effect.old_category_id,
        effect.link.id,
    });
    try db.memtable_link_by_category().delete(&old_category_link_key);
    assert(db.memtable_link_by_category().get(&old_category_link_key) != .found);

    try db.memtable_links_by_id().put(&id_key, std.mem.asBytes(&effect.link));
    assert(db.memtable_links_by_id().get(&id_key) != .deleted);

    const new_category_link_key = schema.CategoryLinkKey.encode(.{
        effect.link.category_id,
        effect.link.id,
    });
    try db.memtable_link_by_category().put(&new_category_link_key, &id_key);
    assert(db.memtable_link_by_category().get(&new_category_link_key) != .deleted);

    try apply.cascade_ancestor_counts(
        db,
        effect.old_chain_updates,
        effect.old_category_id,
        .link_count,
        false,
    );

    try apply.cascade_ancestor_counts(
        db,
        effect.new_chain_updates,
        effect.link.category_id,
        .link_count,
        true,
    );

    db.subtree_cache.invalidate_all();
}

// Commit one link insert and read back every index it touches plus both ancestors' counts.
test "apply_link_inserted: writes primary + secondaries + tokens + ancestor counts" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_id: u64 = 100;
    const link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = "https://x.example",
        .title = "Hello",
        .description = "World",
    });
    const ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
        .{ .text = try arena_allocator.dupe(u8, "world"), .field = .desc },
    });
    const change_set = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    try db.commit(change_set);

    const got_link = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqual(link_id, got_link.id);

    const category_link_key = schema.CategoryLinkKey.encode(.{ category_id, link_id });
    var value_buffer: [64]u8 = undefined;
    const category_link_present = try test_support.is_present(
        db.memtable_link_by_category(),
        db.link_by_category(),
        &category_link_key,
    );
    try std.testing.expect(category_link_present);

    const hash_key = codec.encodeU64(codec.hash("https://x.example"));
    const hash_present = try test_support.is_present(
        db.memtable_link_by_url_hash(),
        db.link_by_url_hash(),
        &hash_key,
    );
    try std.testing.expect(hash_present);

    var token_key_buffer: [32]u8 = undefined;
    const token_key = test_support.token_key(&token_key_buffer, "hello", link_id);
    try std.testing.expect((try db.links_index_tree().search(token_key, &value_buffer)) != null);

    const got_category = (try ops.get_category(db, category_id)).?;
    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_category.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), got_top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), got_category.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_category.link_count);
}

// Committing the same insert twice keeps the indexes single-valued but double-counts the
// subtree deltas; recompute_category_counts is what brings them back, so that is locked here.
test "apply_link_inserted: retry is index-idempotent; recount reconciles delta double-count" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_id: u64 = 200;
    const link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = "https://idempotent.example",
        .title = "Hello",
        .description = "World",
    });
    const ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
    });
    const change_set = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    try db.commit(change_set);
    try std.testing.expectEqual(
        @as(u64, 1),
        (try ops.get_category(db, category_id)).?.link_count_subtree,
    );

    try db.commit(change_set);
    const after_second_cat = (try ops.get_category(db, category_id)).?;
    const after_second_top = (try ops.get_category(db, top_id)).?;

    const got_link = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqual(link_id, got_link.id);

    try std.testing.expectEqual(@as(u64, 2), after_second_cat.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 2), after_second_top.link_count_subtree);

    try ops.recompute_category_counts(db);
    try std.testing.expectEqual(
        @as(u64, 1),
        (try ops.get_category(db, category_id)).?.link_count_subtree,
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        (try ops.get_category(db, top_id)).?.link_count_subtree,
    );
}

// Insert then delete the same link and expect every index entry and count gone.
test "apply_link_deleted: reverses link_inserted (primary + secondaries + tokens + counts)" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_id: u64 = 300;
    const link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = "https://reverse.example",
        .title = "Hello",
        .description = "World",
    });

    const insert_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
        .{ .text = try arena_allocator.dupe(u8, "world"), .field = .desc },
    });
    const insert_change_set = changeset.ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = insert_ancestors,
        .tokens = tokens,
    } };
    try db.commit(insert_change_set);

    try std.testing.expect((try ops.get_link(db, link_id)) != null);

    const delete_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
    });
    const delete_change_set = changeset.ChangeSet{ .link_deleted = .{
        .link = link,
        .ancestor_updates = delete_ancestors,
        .tokens = tokens,
    } };
    try db.commit(delete_change_set);

    try std.testing.expect((try ops.get_link(db, link_id)) == null);

    const category_link_key = schema.CategoryLinkKey.encode(.{ category_id, link_id });
    var value_buffer: [64]u8 = undefined;
    const category_link_present = try test_support.is_present(
        db.memtable_link_by_category(),
        db.link_by_category(),
        &category_link_key,
    );
    try std.testing.expect(!category_link_present);

    const hash_key = codec.encodeU64(codec.hash("https://reverse.example"));
    const hash_present = try test_support.is_present(
        db.memtable_link_by_url_hash(),
        db.link_by_url_hash(),
        &hash_key,
    );
    try std.testing.expect(!hash_present);

    var token_key_buffer: [32]u8 = undefined;
    const token_key = test_support.token_key(&token_key_buffer, "hello", link_id);
    try std.testing.expect((try db.links_index_tree().search(token_key, &value_buffer)) == null);

    const got_category = (try ops.get_category(db, category_id)).?;
    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 0), got_category.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 0), got_top.link_count_subtree);
}

// A text update with the same URL rewrites the record and swaps postings; the hash stays.
test "apply_link_text_updated: same URL — primary rewritten, tokens swapped, hash unchanged" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_id: u64 = 400;
    const url = "https://text-update.example";
    const old_link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = url,
        .title = "Hello",
        .description = "Old desc",
    });

    const insert_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const insert_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
    });
    const insert_change_set = changeset.ChangeSet{ .link_inserted = .{
        .link = old_link,
        .ancestor_updates = insert_ancestors,
        .tokens = insert_tokens,
    } };
    try db.commit(insert_change_set);

    const new_link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = url,
        .title = "World",
        .description = "New desc",
        .updated_at = 2000,
    });
    const old_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
    });
    const new_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "world"), .field = .title },
    });
    const update_change_set = changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };
    try db.commit(update_change_set);

    const got_link = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqualStrings("World", got_link.title.slice());
    try std.testing.expectEqualStrings("New desc", got_link.description.slice());

    var value_buffer: [64]u8 = undefined;
    var old_token_key_buffer: [32]u8 = undefined;
    const old_token_key = test_support.token_key(&old_token_key_buffer, "hello", link_id);
    try std.testing.expect(
        (try db.links_index_tree().search(old_token_key, &value_buffer)) == null,
    );

    var new_token_key_buffer: [32]u8 = undefined;
    const new_token_key = test_support.token_key(&new_token_key_buffer, "world", link_id);
    try std.testing.expect(
        (try db.links_index_tree().search(new_token_key, &value_buffer)) != null,
    );

    const hash_key = codec.encodeU64(codec.hash(url));
    const hash_present = try test_support.is_present(
        db.memtable_link_by_url_hash(),
        db.link_by_url_hash(),
        &hash_key,
    );
    try std.testing.expect(hash_present);

    const got_category = (try ops.get_category(db, category_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_category.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_category.link_count);
}

// A URL change moves the url-hash entry to the new hash and feeds the bloom filter.
test "apply_link_text_updated: URL changed — link_by_url_hash rewritten, bloom updated" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_id: u64 = 401;
    const old_url = "https://old.example";
    const new_url = "https://new.example";
    const old_link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = old_url,
        .title = "Hello",
        .description = "Old desc",
    });

    const insert_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const insert_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
    });
    const insert_change_set = changeset.ChangeSet{ .link_inserted = .{
        .link = old_link,
        .ancestor_updates = insert_ancestors,
        .tokens = insert_tokens,
    } };
    try db.commit(insert_change_set);

    const new_link = test_support.link(.{
        .id = link_id,
        .category_id = category_id,
        .url = new_url,
        .title = "World",
        .description = "New desc",
        .updated_at = 2000,
    });
    const old_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
    });
    const new_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "world"), .field = .title },
    });
    const update_change_set = changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };
    try db.commit(update_change_set);

    const got_link = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqualStrings("World", got_link.title.slice());
    try std.testing.expectEqualStrings(new_url, got_link.url.slice());

    var value_buffer: [64]u8 = undefined;

    const old_hash_key = codec.encodeU64(codec.hash(old_url));
    const old_hash_present = try test_support.is_present(
        db.memtable_link_by_url_hash(),
        db.link_by_url_hash(),
        &old_hash_key,
    );
    try std.testing.expect(!old_hash_present);

    const new_hash_key = codec.encodeU64(codec.hash(new_url));
    const new_hash_present = try test_support.is_present(
        db.memtable_link_by_url_hash(),
        db.link_by_url_hash(),
        &new_hash_key,
    );
    try std.testing.expect(new_hash_present);

    var old_token_key_buffer: [32]u8 = undefined;
    const old_token_key = test_support.token_key(&old_token_key_buffer, "hello", link_id);
    try std.testing.expect(
        (try db.links_index_tree().search(old_token_key, &value_buffer)) == null,
    );

    var new_token_key_buffer: [32]u8 = undefined;
    const new_token_key = test_support.token_key(&new_token_key_buffer, "world", link_id);
    try std.testing.expect(
        (try db.links_index_tree().search(new_token_key, &value_buffer)) != null,
    );

    try std.testing.expect(db.url_bloom.mayContain(new_url));
}

// Move a link from A to B and expect the category index and both chains' counts to follow.
test "apply_link_recategorized: swaps link_by_category and cascades both ancestor chains" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_a_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const category_b_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link_id: u64 = 500;
    const link_in_a = test_support.link(.{
        .id = link_id,
        .category_id = category_a_id,
        .url = "https://recat.example",
        .title = "Hello",
        .description = "World",
    });

    const insert_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_a_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "hello"), .field = .title },
    });
    const insert_change_set = changeset.ChangeSet{ .link_inserted = .{
        .link = link_in_a,
        .ancestor_updates = insert_ancestors,
        .tokens = tokens,
    } };
    try db.commit(insert_change_set);

    const link_in_b = test_support.link(.{
        .id = link_id,
        .category_id = category_b_id,
        .url = "https://recat.example",
        .title = "Hello",
        .description = "World",
        .updated_at = 2000,
    });
    const old_chain = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{
            .cat_id = category_a_id,
            .link_count_subtree_delta = -1,
            .child_count_subtree_delta = 0,
        },
        .{ .cat_id = top_id, .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
    });
    const new_chain = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = category_b_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
    });
    const recat_change_set = changeset.ChangeSet{ .link_recategorized = .{
        .link = link_in_b,
        .old_category_id = category_a_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
    } };
    try db.commit(recat_change_set);

    const old_category_link_key = schema.CategoryLinkKey.encode(.{ category_a_id, link_id });
    const old_category_link_present = try test_support.is_present(
        db.memtable_link_by_category(),
        db.link_by_category(),
        &old_category_link_key,
    );
    try std.testing.expect(!old_category_link_present);

    const new_category_link_key = schema.CategoryLinkKey.encode(.{ category_b_id, link_id });
    const new_category_link_present = try test_support.is_present(
        db.memtable_link_by_category(),
        db.link_by_category(),
        &new_category_link_key,
    );
    try std.testing.expect(new_category_link_present);

    const got_link = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqual(category_b_id, got_link.category_id);

    const got_category_a = (try ops.get_category(db, category_a_id)).?;
    const got_category_b = (try ops.get_category(db, category_b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_category_a.link_count);
    try std.testing.expectEqual(@as(u32, 1), got_category_b.link_count);

    try std.testing.expectEqual(@as(u64, 0), got_category_a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), got_category_b.link_count_subtree);
    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), got_top.link_count_subtree);
}

// Two links share a URL; deleting the first must not remove the hash entry the second owns.
test "deleting a link whose url hash maps to another link leaves that link's hash entry intact" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const no_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{});
    const no_tokens = try arena_allocator.dupe(changeset.Token, &.{});

    const shared_url = "https://collide.example";
    const first = schema.Link{
        .id = 300,
        .category_id = top_id,
        .url = codec.FixedString(64).fromSlice(shared_url),
    };
    const second = schema.Link{
        .id = 301,
        .category_id = top_id,
        .url = codec.FixedString(64).fromSlice(shared_url),
    };
    try db.commit(.{ .link_inserted = .{
        .link = first,
        .ancestor_updates = no_ancestors,
        .tokens = no_tokens,
    } });
    try db.commit(.{ .link_inserted = .{
        .link = second,
        .ancestor_updates = no_ancestors,
        .tokens = no_tokens,
    } });

    try db.commit(.{ .link_deleted = .{
        .link = first,
        .ancestor_updates = no_ancestors,
        .tokens = no_tokens,
    } });

    const hash_key = codec.encodeU64(codec.hash(shared_url));
    try std.testing.expectEqual(@as(?u64, 301), try url_hash_owner(db, &hash_key));
}
