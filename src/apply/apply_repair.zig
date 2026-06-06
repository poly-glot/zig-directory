const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const Database = @import("../database.zig").Database;

pub fn applySlugPathRepairChunk(db: *Database, e: changeset.SlugPathRepairChunkEffect) !void {
    for (e.swaps) |s| {
        _ = try db.categories_by_slug_path.delete(s.old_path);
        const id_key = codec.encodeU64(s.cat_id);
        try db.categories_by_slug_path.insert(s.new_path, &id_key);
    }
}

pub fn applySlugPathRepairComplete(db: *Database, e: changeset.RepairTaskCompleteEffect) !void {
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, e.seq, .big);
    _ = try db.slug_path_repair_queue.delete(&key);
}
test "applySlugPathRepairChunk: applies swaps to categories_by_slug_path" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var v: [8]u8 = codec.encodeU64(123);
    try db.categories_by_slug_path.insert("old/path", &v);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const swaps = try aa.dupe(changeset.SlugPathSwap, &.{
        .{ .old_path = "old/path", .new_path = "new/path", .cat_id = 123 },
    });

    try db.commit(changeset.ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = 1,
        .swaps = swaps,
    } });

    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_by_slug_path.search("old/path", &v_buf)) == null);
    try std.testing.expect((try db.categories_by_slug_path.search("new/path", &v_buf)) != null);
}

test "applySlugPathRepairComplete: deletes queue entry by seq" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var task = schema.RepairTask{ .cat_id = 99, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue.insert(&key, std.mem.asBytes(&task));
    try std.testing.expectEqual(@as(u64, 1), db.slug_path_repair_queue.entry_count);

    try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = 1 } });

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
}
