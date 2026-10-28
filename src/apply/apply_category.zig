//! Category appliers. The primary record, the parent-child edge, the slug-path and slug-only
//! indexes, the token postings and the ancestor counts move together under one change set;
//! a rename or move that outgrows the inline threshold hands its descendants to the repair
//! queue instead of holding the write lock for the whole subtree.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;
const apply = @import("apply.zig");
const test_support = @import("../test_support.zig");
const vectors_per_write_max = @import("../operations/operations_vector.zig").vectors_per_write_max;

pub fn apply_category_inserted(
    db: *Directory,
    effect: *const changeset.CategoryInsertEffect,
) !void {
    assert(effect.cat.id != 0);
    assert(effect.cat.parent_id != effect.cat.id);
    const id_key = codec.encodeU64(effect.cat.id);

    const parent_child_key = schema.ParentChildKey.encode(.{
        effect.cat.parent_id,
        effect.cat.id,
    });
    try db.memtable_cat_by_parent().put(&parent_child_key, &id_key);
    assert(db.memtable_cat_by_parent().get(&parent_child_key) != .deleted);

    try db.categories_by_slug_path().insert(effect.slug_path, &id_key);

    if (effect.is_shallowest_for_slug) {
        try db.categories_by_slug_only().insert(effect.cat.slug.slice(), &id_key);
    }

    try apply.write_tokens(db.categories_index_tree(), effect.tokens, effect.cat.id, .insert);

    try apply.cascade_ancestor_counts(
        db,
        effect.ancestor_updates,
        effect.cat.parent_id,
        .child_count,
        true,
    );

    try db.memtable_categories_by_id().put(&id_key, std.mem.asBytes(&effect.cat));
    assert(db.memtable_categories_by_id().get(&id_key) != .deleted);
    db.note_issued_category_id(effect.cat.id);
    assert(db.next_category_id.load(.monotonic) > effect.cat.id);

    db.subtree_cache.invalidate_all();
}

fn enqueue_repair_task(
    db: *Directory,
    category_id: u64,
    enqueue: *const changeset.EnqueueOnApply,
) !void {
    if (enqueue.seq == 0) return;
    assert(category_id != 0);
    assert(enqueue.old_slug_prefix.len <= codec.FixedString(2048).capacity);
    const task = schema.RepairTask{
        .cat_id = category_id,
        .op = enqueue.op,
        .created_at = enqueue.created_at,
        .old_slug_prefix = codec.FixedString(2048).fromSlice(enqueue.old_slug_prefix),
    };
    const key = codec.encodeU64(enqueue.seq);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));
    db.note_issued_repair_seq(enqueue.seq);
    assert(db.next_repair_seq.load(.monotonic) > enqueue.seq);
}

pub fn apply_category_deleted(
    db: *Directory,
    effect: *const changeset.CategoryDeleteEffect,
) !void {
    assert(effect.cat.id != 0);
    assert(effect.cat.parent_id != effect.cat.id);
    const id_key = codec.encodeU64(effect.cat.id);

    const parent_child_key = schema.ParentChildKey.encode(.{
        effect.cat.parent_id,
        effect.cat.id,
    });
    try db.memtable_cat_by_parent().delete(&parent_child_key);
    assert(db.memtable_cat_by_parent().get(&parent_child_key) != .found);

    _ = try db.categories_by_slug_path().delete(effect.slug_path);

    const slug = effect.cat.slug.slice();
    var slug_only_buffer: [16]u8 = undefined;
    if (try db.categories_by_slug_only().search(slug, &slug_only_buffer)) |value| {
        if (std.mem.eql(u8, value, &id_key)) {
            _ = try db.categories_by_slug_only().delete(slug);
        }
    }

    try apply.write_tokens(db.categories_index_tree(), effect.tokens, effect.cat.id, .delete);

    try db.memtable_categories_by_id().delete(&id_key);
    assert(db.memtable_categories_by_id().get(&id_key) != .found);

    try apply.cascade_ancestor_counts(
        db,
        effect.ancestor_updates,
        effect.cat.parent_id,
        .child_count,
        false,
    );

    try delete_category_vector(db, effect.cat.id);

    db.subtree_cache.invalidate_all();
}

pub fn apply_category_vectors_put(
    db: *Directory,
    effect: *const changeset.CategoryVectorsPutEffect,
) !void {
    assert(effect.model != 0);
    assert(effect.vectors.len <= vectors_per_write_max);
    db.store.counter("embedding_model").* = effect.model;
    db.link_vector_index.model.store(effect.model, .release);
    db.category_vector_index.model.store(effect.model, .release);

    for (effect.vectors) |vector| {
        assert(vector.id != 0);
        const key = codec.encodeU64(vector.id);
        try db.category_vectors().insert(&key, std.mem.asBytes(&vector));
        try db.category_vector_index.put(db.io, db.allocator, &vector);
    }
}

fn delete_category_vector(db: *Directory, category_id: u64) !void {
    assert(category_id != 0);
    const key = codec.encodeU64(category_id);
    _ = try db.category_vectors().delete(&key);
    db.category_vector_index.remove(db.io, category_id);
}

pub fn apply_category_text_updated(
    db: *Directory,
    effect: *const changeset.CategoryTextUpdateEffect,
) !void {
    assert(effect.new_cat.id != 0);
    assert(effect.old_cat.id == effect.new_cat.id);
    assert(effect.old_cat.parent_id == effect.new_cat.parent_id);
    assert(effect.old_cat.slug.eql(effect.new_cat.slug.slice()));
    const id_key = codec.encodeU64(effect.new_cat.id);

    try db.memtable_categories_by_id().put(&id_key, std.mem.asBytes(&effect.new_cat));
    assert(db.memtable_categories_by_id().get(&id_key) != .deleted);

    try apply.write_tokens(
        db.categories_index_tree(),
        effect.old_tokens,
        effect.new_cat.id,
        .delete,
    );
    try apply.write_tokens(
        db.categories_index_tree(),
        effect.new_tokens,
        effect.new_cat.id,
        .insert,
    );

    db.subtree_cache.invalidate_all();
}

pub fn apply_category_renamed(
    db: *Directory,
    effect: *const changeset.CategoryRenameEffect,
) !void {
    assert(effect.new_cat.id != 0);
    assert(effect.old_cat.id == effect.new_cat.id);
    assert(effect.old_cat.parent_id == effect.new_cat.parent_id);
    assert(!effect.old_cat.slug.eql(effect.new_cat.slug.slice()));
    if (effect.above_threshold) assert(effect.descendant_swaps.len == 0);
    if (effect.above_threshold) assert(effect.enqueue.seq != 0);
    if (!effect.above_threshold) assert(effect.enqueue.seq == 0);
    const id_key = codec.encodeU64(effect.new_cat.id);

    try db.memtable_categories_by_id().put(&id_key, std.mem.asBytes(&effect.new_cat));
    assert(db.memtable_categories_by_id().get(&id_key) != .deleted);

    _ = try db.categories_by_slug_path().delete(effect.old_slug_path);
    try db.categories_by_slug_path().insert(effect.new_slug_path, &id_key);

    const old_slug = effect.old_cat.slug.slice();
    const new_slug = effect.new_cat.slug.slice();
    var slug_only_buffer: [16]u8 = undefined;
    if (try db.categories_by_slug_only().search(old_slug, &slug_only_buffer)) |value| {
        if (std.mem.eql(u8, value, &id_key)) {
            _ = try db.categories_by_slug_only().delete(old_slug);
        }
    }
    if ((try db.categories_by_slug_only().search(new_slug, &slug_only_buffer)) == null) {
        try db.categories_by_slug_only().insert(new_slug, &id_key);
    }

    for (effect.descendant_swaps) |swap| {
        _ = try db.categories_by_slug_path().delete(swap.old_path);
        const descendant_id_key = codec.encodeU64(swap.cat_id);
        try db.categories_by_slug_path().insert(swap.new_path, &descendant_id_key);
    }

    try enqueue_repair_task(db, effect.new_cat.id, &effect.enqueue);

    try delete_category_vector(db, effect.new_cat.id);

    db.subtree_cache.invalidate_all();
}

pub fn apply_category_moved(db: *Directory, effect: *const changeset.CategoryMoveEffect) !void {
    assert(effect.cat.id != 0);
    assert(effect.cat.parent_id == effect.new_parent_id);
    assert(effect.old_parent_id != effect.new_parent_id);
    assert(effect.new_parent_id != effect.cat.id);
    if (effect.above_threshold) assert(effect.descendant_swaps.len == 0);
    if (effect.above_threshold) assert(effect.enqueue.seq != 0);
    if (!effect.above_threshold) assert(effect.enqueue.seq == 0);
    const id_key = codec.encodeU64(effect.cat.id);

    try db.memtable_categories_by_id().put(&id_key, std.mem.asBytes(&effect.cat));
    assert(db.memtable_categories_by_id().get(&id_key) != .deleted);

    const old_parent_child_key = schema.ParentChildKey.encode(.{
        effect.old_parent_id,
        effect.cat.id,
    });
    try db.memtable_cat_by_parent().delete(&old_parent_child_key);
    assert(db.memtable_cat_by_parent().get(&old_parent_child_key) != .found);
    const new_parent_child_key = schema.ParentChildKey.encode(.{
        effect.new_parent_id,
        effect.cat.id,
    });
    try db.memtable_cat_by_parent().put(&new_parent_child_key, &id_key);
    assert(db.memtable_cat_by_parent().get(&new_parent_child_key) != .deleted);

    _ = try db.categories_by_slug_path().delete(effect.old_slug_path);
    try db.categories_by_slug_path().insert(effect.new_slug_path, &id_key);

    for (effect.descendant_swaps) |swap| {
        _ = try db.categories_by_slug_path().delete(swap.old_path);
        const descendant_id_key = codec.encodeU64(swap.cat_id);
        try db.categories_by_slug_path().insert(swap.new_path, &descendant_id_key);
    }

    try enqueue_repair_task(db, effect.cat.id, &effect.enqueue);

    try delete_category_vector(db, effect.cat.id);

    try apply.cascade_ancestor_counts(
        db,
        effect.old_chain_updates,
        effect.old_parent_id,
        .child_count,
        false,
    );

    try apply.cascade_ancestor_counts(
        db,
        effect.new_chain_updates,
        effect.new_parent_id,
        .child_count,
        true,
    );

    db.subtree_cache.invalidate_all();
}

// Commit one category insert and read back the record, the edge, both slug indexes, the
// postings and the parent's counts.
test "apply_category_inserted: writes primary + secondaries + slug paths + tokens + cascade" {
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
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_category = test_support.category(.{
        .id = child_id,
        .parent_id = top_id,
        .name = "Test",
        .slug = "test",
    });
    const ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .name },
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .slug },
    });
    const change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = child_category,
        .ancestor_updates = ancestors,
        .tokens = tokens,
        .slug_path = try arena_allocator.dupe(u8, "top/test"),
        .is_shallowest_for_slug = true,
    } };

    try db.commit(change_set);

    const got_child = (try ops.get_category(db, child_id)).?;
    try std.testing.expectEqual(child_id, got_child.id);
    try std.testing.expectEqual(top_id, got_child.parent_id);
    try std.testing.expectEqualStrings("Test", got_child.name.slice());
    try std.testing.expectEqualStrings("test", got_child.slug.slice());

    const parent_child_key = schema.ParentChildKey.encode(.{ top_id, child_id });
    var value_buffer: [64]u8 = undefined;
    const parent_child_present = try test_support.is_present(
        db.memtable_cat_by_parent(),
        db.cat_by_parent(),
        &parent_child_key,
    );
    try std.testing.expect(parent_child_present);

    const child_id_be = codec.encodeU64(child_id);
    const slug_path_value = (try db.categories_by_slug_path().search("top/test", &value_buffer)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_path_value);

    const slug_only_value = (try db.categories_by_slug_only().search("test", &value_buffer)).?;
    try std.testing.expectEqualSlices(u8, &child_id_be, slug_only_value);

    var token_key_buffer: [32]u8 = undefined;
    const token_key = test_support.token_key(&token_key_buffer, "test", child_id);
    try std.testing.expect(
        (try db.categories_index_tree().search(token_key, &value_buffer)) != null,
    );

    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count);
}

// Insert then delete the same category and expect every index entry and count gone.
test "apply_category_deleted: reverses category_inserted" {
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
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_category = test_support.category(.{
        .id = child_id,
        .parent_id = top_id,
        .name = "Test",
        .slug = "test",
    });
    const insert_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .name },
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .slug },
    });
    const slug_path = try arena_allocator.dupe(u8, "top/test");
    const insert_change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = child_category,
        .ancestor_updates = insert_ancestors,
        .tokens = tokens,
        .slug_path = slug_path,
        .is_shallowest_for_slug = true,
    } };
    try db.commit(insert_change_set);

    try std.testing.expect((try ops.get_category(db, child_id)) != null);

    const delete_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = -1 },
    });
    const delete_change_set = changeset.ChangeSet{ .category_deleted = .{
        .cat = child_category,
        .ancestor_updates = delete_ancestors,
        .tokens = tokens,
        .slug_path = slug_path,
    } };
    try db.commit(delete_change_set);

    try std.testing.expect((try ops.get_category(db, child_id)) == null);

    const parent_child_key = schema.ParentChildKey.encode(.{ top_id, child_id });
    var value_buffer: [64]u8 = undefined;
    const parent_child_present = try test_support.is_present(
        db.memtable_cat_by_parent(),
        db.cat_by_parent(),
        &parent_child_key,
    );
    try std.testing.expect(!parent_child_present);

    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/test", &value_buffer)) == null,
    );

    try std.testing.expect(
        (try db.categories_by_slug_only().search("test", &value_buffer)) == null,
    );

    var token_key_buffer: [32]u8 = undefined;
    const token_key = test_support.token_key(&token_key_buffer, "test", child_id);
    try std.testing.expect(
        (try db.categories_index_tree().search(token_key, &value_buffer)) == null,
    );

    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), got_top.child_count);
}

// A text update rewrites the record and swaps postings while slug and counts stay put.
test "apply_category_text_updated: rewrites primary, swaps token entries; slug+counts unchanged" {
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
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const child_id = db.next_category_id.fetchAdd(1, .monotonic);
    const child_category = test_support.category(.{
        .id = child_id,
        .parent_id = top_id,
        .name = "Foo",
        .slug = "test",
    });
    const insert_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const insert_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "foo"), .field = .name },
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .slug },
    });
    const insert_change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = child_category,
        .ancestor_updates = insert_ancestors,
        .tokens = insert_tokens,
        .slug_path = try arena_allocator.dupe(u8, "top/test"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(insert_change_set);

    var value_buffer: [64]u8 = undefined;
    var foo_key_buffer: [32]u8 = undefined;
    const foo_key = test_support.token_key(&foo_key_buffer, "foo", child_id);
    try std.testing.expect((try db.categories_index_tree().search(foo_key, &value_buffer)) != null);
    var test_key_buffer: [32]u8 = undefined;
    const test_key = test_support.token_key(&test_key_buffer, "test", child_id);
    try std.testing.expect(
        (try db.categories_index_tree().search(test_key, &value_buffer)) != null,
    );

    const new_category = test_support.category(.{
        .id = child_id,
        .parent_id = top_id,
        .name = "Bar",
        .slug = "test",
        .description = "New desc",
        .updated_at = 2000,
    });
    const old_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "foo"), .field = .name },
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .slug },
    });
    const new_tokens = try arena_allocator.dupe(changeset.Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "bar"), .field = .name },
        .{ .text = try arena_allocator.dupe(u8, "test"), .field = .slug },
    });
    const update_change_set = changeset.ChangeSet{ .category_text_updated = .{
        .old_cat = child_category,
        .new_cat = new_category,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };
    try db.commit(update_change_set);

    const got_child = (try ops.get_category(db, child_id)).?;
    try std.testing.expectEqualStrings("Bar", got_child.name.slice());
    try std.testing.expectEqualStrings("New desc", got_child.description.slice());
    try std.testing.expectEqualStrings("test", got_child.slug.slice());

    try std.testing.expect((try db.categories_index_tree().search(foo_key, &value_buffer)) == null);

    var bar_key_buffer: [32]u8 = undefined;
    const bar_key = test_support.token_key(&bar_key_buffer, "bar", child_id);
    try std.testing.expect((try db.categories_index_tree().search(bar_key, &value_buffer)) != null);

    try std.testing.expect(
        (try db.categories_index_tree().search(test_key, &value_buffer)) != null,
    );

    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), got_top.child_count);
}

// Rename C under Top with two inline descendant swaps; own and descendant paths move.
test "apply_category_renamed: rewrites self slug paths and rebuilds descendant slug paths" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const top_id = db.next_category_id.fetchAdd(1, .monotonic);
    const top_category = test_support.category(.{
        .id = top_id,
        .parent_id = 0,
        .name = "Top",
        .slug = "top",
    });
    const top_change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = top_category,
        .ancestor_updates = &.{},
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(top_change_set);

    const c_id = db.next_category_id.fetchAdd(1, .monotonic);
    const c_category = test_support.category(.{
        .id = c_id,
        .parent_id = top_id,
        .name = "C",
        .slug = "c",
    });
    const c_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const c_change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = c_category,
        .ancestor_updates = c_ancestors,
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/c"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(c_change_set);

    const d_id = db.next_category_id.fetchAdd(1, .monotonic);
    const d_category = test_support.category(.{
        .id = d_id,
        .parent_id = c_id,
        .name = "D",
        .slug = "d",
    });
    const d_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = c_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const d_change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = d_category,
        .ancestor_updates = d_ancestors,
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/c/d"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(d_change_set);

    const e_id = db.next_category_id.fetchAdd(1, .monotonic);
    const e_category = test_support.category(.{
        .id = e_id,
        .parent_id = d_id,
        .name = "E",
        .slug = "e",
    });
    const e_ancestors = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = d_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        .{ .cat_id = c_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const e_change_set = changeset.ChangeSet{ .category_inserted = .{
        .cat = e_category,
        .ancestor_updates = e_ancestors,
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/c/d/e"),
        .is_shallowest_for_slug = true,
    } };
    try db.commit(e_change_set);

    var value_buffer: [64]u8 = undefined;
    const c_id_be = codec.encodeU64(c_id);
    const d_id_be = codec.encodeU64(d_id);
    const e_id_be = codec.encodeU64(e_id);
    try std.testing.expectEqualSlices(
        u8,
        &c_id_be,
        (try db.categories_by_slug_path().search("top/c", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &d_id_be,
        (try db.categories_by_slug_path().search("top/c/d", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &e_id_be,
        (try db.categories_by_slug_path().search("top/c/d/e", &value_buffer)).?,
    );

    const c_renamed = test_support.category(.{
        .id = c_id,
        .parent_id = top_id,
        .name = "C",
        .slug = "newc",
        .child_count = 1,
        .updated_at = 2000,
    });
    const rename_swaps = try arena_allocator.dupe(changeset.SlugPathSwap, &.{
        .{ .old_path = "top/c/d", .new_path = "top/newc/d", .cat_id = d_id },
        .{ .old_path = "top/c/d/e", .new_path = "top/newc/d/e", .cat_id = e_id },
    });
    const rename_change_set = changeset.ChangeSet{ .category_renamed = .{
        .old_cat = c_category,
        .new_cat = c_renamed,
        .old_slug_path = try arena_allocator.dupe(u8, "top/c"),
        .new_slug_path = try arena_allocator.dupe(u8, "top/newc"),
        .descendant_swaps = rename_swaps,
        .above_threshold = false,
        .enqueue = .{},
    } };
    try db.commit(rename_change_set);

    const got_c = (try ops.get_category(db, c_id)).?;
    try std.testing.expectEqualStrings("newc", got_c.slug.slice());

    try std.testing.expectEqualSlices(
        u8,
        &c_id_be,
        (try db.categories_by_slug_path().search("top/newc", &value_buffer)).?,
    );
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/c", &value_buffer)) == null,
    );

    try std.testing.expectEqualSlices(
        u8,
        &d_id_be,
        (try db.categories_by_slug_path().search("top/newc/d", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &e_id_be,
        (try db.categories_by_slug_path().search("top/newc/d/e", &value_buffer)).?,
    );

    try std.testing.expect((try db.categories_by_slug_only().search("c", &value_buffer)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &c_id_be,
        (try db.categories_by_slug_only().search("newc", &value_buffer)).?,
    );

    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/c/d", &value_buffer)) == null,
    );
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/c/d/e", &value_buffer)) == null,
    );
}

// Move C from A to B: the edge, the slug paths and both ancestor chains' counts follow.
test "apply_category_moved: swaps cat_by_parent + rebuilds slug paths + cascades both chains" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("../operations/operations.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const top_id = db.next_category_id.fetchAdd(1, .monotonic);
    const top_category = test_support.category(.{
        .id = top_id,
        .parent_id = 0,
        .name = "Top",
        .slug = "top",
    });
    try db.commit(.{ .category_inserted = .{
        .cat = top_category,
        .ancestor_updates = &.{},
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top"),
        .is_shallowest_for_slug = true,
    } });

    const a_id = db.next_category_id.fetchAdd(1, .monotonic);
    const a_category = test_support.category(.{
        .id = a_id,
        .parent_id = top_id,
        .name = "A",
        .slug = "a",
    });
    try db.commit(.{ .category_inserted = .{
        .cat = a_category,
        .ancestor_updates = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/a"),
        .is_shallowest_for_slug = true,
    } });

    const b_id = db.next_category_id.fetchAdd(1, .monotonic);
    const b_category = test_support.category(.{
        .id = b_id,
        .parent_id = top_id,
        .name = "B",
        .slug = "b",
    });
    try db.commit(.{ .category_inserted = .{
        .cat = b_category,
        .ancestor_updates = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/b"),
        .is_shallowest_for_slug = true,
    } });

    const c_id = db.next_category_id.fetchAdd(1, .monotonic);
    const c_category = test_support.category(.{
        .id = c_id,
        .parent_id = a_id,
        .name = "C",
        .slug = "c",
    });
    try db.commit(.{ .category_inserted = .{
        .cat = c_category,
        .ancestor_updates = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = a_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/a/c"),
        .is_shallowest_for_slug = true,
    } });

    const d_id = db.next_category_id.fetchAdd(1, .monotonic);
    const d_category = test_support.category(.{
        .id = d_id,
        .parent_id = c_id,
        .name = "D",
        .slug = "d",
    });
    try db.commit(.{ .category_inserted = .{
        .cat = d_category,
        .ancestor_updates = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
            .{ .cat_id = c_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
            .{ .cat_id = a_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
            .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        }),
        .tokens = &.{},
        .slug_path = try arena_allocator.dupe(u8, "top/a/c/d"),
        .is_shallowest_for_slug = true,
    } });

    var value_buffer: [64]u8 = undefined;
    const c_id_be = codec.encodeU64(c_id);
    const d_id_be = codec.encodeU64(d_id);
    try std.testing.expectEqualSlices(
        u8,
        &c_id_be,
        (try db.categories_by_slug_path().search("top/a/c", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &d_id_be,
        (try db.categories_by_slug_path().search("top/a/c/d", &value_buffer)).?,
    );

    const c_moved = test_support.category(.{
        .id = c_id,
        .parent_id = b_id,
        .name = "C",
        .slug = "c",
        .child_count = 1,
        .updated_at = 2000,
    });
    const old_chain = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = a_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = -2 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = -2 },
    });
    const new_chain = try arena_allocator.dupe(changeset.AncestorUpdate, &.{
        .{ .cat_id = b_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 2 },
        .{ .cat_id = top_id, .link_count_subtree_delta = 0, .child_count_subtree_delta = 2 },
    });
    const move_swaps = try arena_allocator.dupe(changeset.SlugPathSwap, &.{
        .{ .old_path = "top/a/c/d", .new_path = "top/b/c/d", .cat_id = d_id },
    });
    const move_change_set = changeset.ChangeSet{ .category_moved = .{
        .cat = c_moved,
        .old_parent_id = a_id,
        .new_parent_id = b_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
        .old_slug_path = try arena_allocator.dupe(u8, "top/a/c"),
        .new_slug_path = try arena_allocator.dupe(u8, "top/b/c"),
        .link_subtree_delta = 0,
        .child_subtree_delta = 0,
        .descendant_swaps = move_swaps,
        .above_threshold = false,
        .enqueue = .{},
    } };
    try db.commit(move_change_set);

    const got_c = (try ops.get_category(db, c_id)).?;
    try std.testing.expectEqual(b_id, got_c.parent_id);

    const old_parent_child_key = schema.ParentChildKey.encode(.{ a_id, c_id });
    const old_parent_child_present = try test_support.is_present(
        db.memtable_cat_by_parent(),
        db.cat_by_parent(),
        &old_parent_child_key,
    );
    try std.testing.expect(!old_parent_child_present);

    const new_parent_child_key = schema.ParentChildKey.encode(.{ b_id, c_id });
    const new_parent_child_present = try test_support.is_present(
        db.memtable_cat_by_parent(),
        db.cat_by_parent(),
        &new_parent_child_key,
    );
    try std.testing.expect(new_parent_child_present);

    try std.testing.expectEqualSlices(
        u8,
        &c_id_be,
        (try db.categories_by_slug_path().search("top/b/c", &value_buffer)).?,
    );
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/a/c", &value_buffer)) == null,
    );
    try std.testing.expectEqualSlices(
        u8,
        &d_id_be,
        (try db.categories_by_slug_path().search("top/b/c/d", &value_buffer)).?,
    );

    const got_a = (try ops.get_category(db, a_id)).?;
    const got_b = (try ops.get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), got_a.child_count);
    try std.testing.expectEqual(@as(u32, 1), got_b.child_count);

    try std.testing.expectEqual(@as(u32, 0), got_a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), got_b.child_count_subtree);
    const got_top = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 4), got_top.child_count_subtree);

    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/a/c/d", &value_buffer)) == null,
    );
}
