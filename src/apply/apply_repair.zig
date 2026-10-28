//! Appliers for the background slug-path repair: a chunk swaps a batch of descendant slug
//! paths, and completion removes the queued task so a restart never re-runs a finished repair.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;

pub fn apply_slug_path_repair_chunk(
    db: *Directory,
    effect: *const changeset.SlugPathRepairChunkEffect,
) !void {
    assert(effect.task_seq != 0);
    for (effect.swaps) |swap| {
        assert(swap.cat_id != 0);
        assert(swap.new_path.len > 0);
        assert(!std.mem.eql(u8, swap.old_path, swap.new_path));
        _ = try db.categories_by_slug_path().delete(swap.old_path);
        const id_key = codec.encodeU64(swap.cat_id);
        try db.categories_by_slug_path().insert(swap.new_path, &id_key);
    }
}

pub fn apply_slug_path_repair_complete(
    db: *Directory,
    effect: changeset.RepairTaskCompleteEffect,
) !void {
    assert(effect.seq != 0);
    const key = codec.encodeU64(effect.seq);
    _ = try db.slug_path_repair_queue().delete(&key);
    var value_buffer: [@sizeOf(schema.RepairTask)]u8 = undefined;
    assert((try db.slug_path_repair_queue().search(&key, &value_buffer)) == null);
}

// Commit one chunk swapping "old/path" for "new/path" and read both keys back from the tree.
test "apply_slug_path_repair_chunk: applies swaps to categories_by_slug_path" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var value: [8]u8 = codec.encodeU64(123);
    try db.categories_by_slug_path().insert("old/path", &value);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const swaps = try arena_allocator.dupe(changeset.SlugPathSwap, &.{
        .{ .old_path = "old/path", .new_path = "new/path", .cat_id = 123 },
    });

    try db.commit(changeset.ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = 1,
        .swaps = swaps,
    } });

    var value_buffer: [16]u8 = undefined;
    try std.testing.expect(
        (try db.categories_by_slug_path().search("old/path", &value_buffer)) == null,
    );
    try std.testing.expect(
        (try db.categories_by_slug_path().search("new/path", &value_buffer)) != null,
    );
}

// Queue one task under seq 1, commit its completion, and expect the queue to be empty.
test "apply_slug_path_repair_complete: deletes queue entry by seq" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const task = schema.RepairTask{ .cat_id = 99, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));
    try std.testing.expectEqual(@as(u64, 1), db.slug_path_repair_queue().entry_count);

    try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = 1 } });

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
}
