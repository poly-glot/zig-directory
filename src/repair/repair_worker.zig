const std = @import("std");
const Directory = @import("../directory.zig").Directory;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const operations = @import("../operations/operations.zig");

const log = std.log.scoped(.repair_worker);

pub fn tickOnce(db: *Directory) !void {
    db.repair_worker_mutex.lock();
    defer db.repair_worker_mutex.unlock();

    const max_tasks = db.config.repair_worker_max_tasks_per_tick;
    var processed: u32 = 0;
    while (processed < max_tasks) : (processed += 1) {
        if (db.slug_path_repair_queue().entryCount() == 0) break;
        const task = (try peekMin(db)) orelse break;
        try processTask(db, task);
    }

    db.repair_worker_last_tick_ms.store(std.time.milliTimestamp(), .release);

    const depth = db.slug_path_repair_queue().entryCount();
    if (depth >= 10000) {
        log.warn("queue depth {d} >= 10000; drain may be falling behind", .{depth});
    } else if (depth >= 1000) {
        log.warn("queue depth {d} >= 1000", .{depth});
    } else if (depth >= 100) {
        log.warn("queue depth {d} >= 100", .{depth});
    }
}

const QueuedTask = struct {
    seq: u64,
    task: schema.RepairTask,
};

fn peekMin(db: *Directory) !?QueuedTask {
    const start_key = [_]u8{0} ** 8;
    var iter = try db.slug_path_repair_queue().rangeScan(&start_key, null);
    if (try iter.next()) |entry| {
        if (entry.value.len < @sizeOf(schema.RepairTask)) return null;
        if (entry.key.len < 8) return null;
        const t = std.mem.bytesToValue(schema.RepairTask, entry.value[0..@sizeOf(schema.RepairTask)]);
        const seq = std.mem.readInt(u64, entry.key[0..8], .big);
        return QueuedTask{ .seq = seq, .task = t };
    }
    return null;
}

const WalkFrame = struct { id: u64, child_offset: u32 };

fn processTask(db: *Directory, qt: QueuedTask) !void {
    const t0 = std.time.milliTimestamp();
    var chunks: u32 = 0;

    const root_cat = try operations.getCategory(db, qt.task.cat_id);
    if (root_cat == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = qt.seq } });
        log.info("task seq={d} cat_id={d} cat-deleted; queue entry removed", .{ qt.seq, qt.task.cat_id });
        return;
    }

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    var stack: std.ArrayList(WalkFrame) = .{};
    try stack.append(arena.allocator(), .{ .id = qt.task.cat_id, .child_offset = 0 });

    while (stack.items.len > 0) {
        if (try processChunk(db, qt, &stack, arena.allocator())) chunks += 1;
    }

    try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = qt.seq } });
    _ = db.repair_worker_tasks_processed.fetchAdd(1, .monotonic);
    log.info("task seq={d} cat_id={d} op={s} chunks={d} processed in {d} ms", .{
        qt.seq, qt.task.cat_id, @tagName(qt.task.op), chunks, std.time.milliTimestamp() - t0,
    });
}

pub fn processOneChunk(db: *Directory) !void {
    const qt = (try peekMin(db)) orelse return;
    if ((try operations.getCategory(db, qt.task.cat_id)) == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = qt.seq } });
        return;
    }
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    var stack: std.ArrayList(WalkFrame) = .{};
    try stack.append(arena.allocator(), .{ .id = qt.task.cat_id, .child_offset = 0 });
    _ = try processChunk(db, qt, &stack, arena.allocator());
}

fn processChunk(
    db: *Directory,
    qt: QueuedTask,
    stack: *std.ArrayList(WalkFrame),
    stack_alloc: std.mem.Allocator,
) !bool {
    const chunk_size = db.config.repair_worker_chunk_size;
    var swap_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer swap_arena.deinit();
    const sa = swap_arena.allocator();

    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    const old_root_path = qt.task.old_slug_prefix.slice();

    while (stack.items.len > 0) {
        const f_idx = stack.items.len - 1;
        const cur_id = stack.items[f_idx].id;
        const cur_off = stack.items[f_idx].child_offset;

        var children_buf: [256]schema.Category = undefined;
        const children = try operations.listChildren(db, cur_id, cur_off, 256, &children_buf);
        if (children.len == 0) {
            _ = stack.pop();
            continue;
        }

        for (children, 0..) |child, i| {
            var d_old_buf: [2048]u8 = undefined;
            const d_old_opt = composeOldPath(db, old_root_path, qt.task.cat_id, child.id, &d_old_buf) catch null;
            var d_new_buf: [2048]u8 = undefined;
            const d_new_opt = try operations.buildCanonicalSlugPath(db, &child, &d_new_buf);

            try stack.append(stack_alloc, .{ .id = child.id, .child_offset = 0 });

            if (d_old_opt) |d_old| {
                if (d_new_opt) |d_new| {
                    if (!std.mem.eql(u8, d_old, d_new)) {
                        var v_buf: [16]u8 = undefined;
                        const at_old = (try db.categories_by_slug_path().search(d_old, &v_buf)) != null;
                        if (at_old) {
                            try swaps.append(sa, .{
                                .old_path = try sa.dupe(u8, d_old),
                                .new_path = try sa.dupe(u8, d_new),
                                .cat_id = child.id,
                            });
                        }
                    }
                }
            }

            if (swaps.items.len >= chunk_size) {
                stack.items[f_idx].child_offset = cur_off + @as(u32, @intCast(i)) + 1;
                try commitSwaps(db, qt.seq, swaps.items);
                return true;
            }
        }

        stack.items[f_idx].child_offset = cur_off + @as(u32, @intCast(children.len));
    }

    if (swaps.items.len == 0) return false;
    try commitSwaps(db, qt.seq, swaps.items);
    return true;
}

fn commitSwaps(db: *Directory, seq: u64, swaps: []const changeset.SlugPathSwap) !void {
    try db.commit(changeset.ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = seq,
        .swaps = swaps,
    } });
    _ = db.repair_worker_chunks_processed.fetchAdd(1, .monotonic);
}

fn composeOldPath(
    db: *Directory,
    old_root_path: []const u8,
    root_id: u64,
    descendant_id: u64,
    buf: []u8,
) ![]const u8 {
    var chain: [64]u64 = undefined;
    var depth: u32 = 0;
    var cur = descendant_id;
    while (cur != root_id and depth < chain.len) : (depth += 1) {
        chain[depth] = cur;
        const c = (try operations.getCategory(db, cur)) orelse return error.NotFound;
        cur = c.parent_id;
        if (cur == 0) return error.NotFound;
    }
    if (cur != root_id) return error.NotFound;

    var pos: usize = 0;
    if (old_root_path.len > buf.len) return error.NotFound;
    @memcpy(buf[pos..][0..old_root_path.len], old_root_path);
    pos += old_root_path.len;

    var idx: i32 = @intCast(@as(i64, @intCast(depth)) - 1);
    while (idx >= 0) : (idx -= 1) {
        const c = (try operations.getCategory(db, chain[@intCast(idx)])) orelse return error.NotFound;
        const slug = c.slug.slice();
        if (slug.len == 0) continue;
        if (pos + 1 + slug.len > buf.len) return error.NotFound;
        buf[pos] = '/';
        pos += 1;
        @memcpy(buf[pos..][0..slug.len], slug);
        pos += slug.len;
    }
    return buf[0..pos];
}

test "repair_worker: drains a single queued task end-to-end" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 1;

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const parent_id = try ops.createCategory(db, top_id, "P", "old", "");
    _ = try ops.createCategory(db, parent_id, "C1", "c1", "");
    _ = try ops.createCategory(db, parent_id, "C2", "c2", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    try ops.updateCategory(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entry_count > 0);

    try tickOnce(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);

    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_by_slug_path().search("top/old/c1", &v_buf)) == null);
    try std.testing.expect((try db.categories_by_slug_path().search("top/new/c1", &v_buf)) != null);
}

test "repair_worker: handles cat deleted before drain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var task = schema.RepairTask{ .cat_id = 9999, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));

    try tickOnce(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
}

test "repair_worker: idempotent across simulated mid-walk crash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var db = try Directory.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        db.config.rename_inline_threshold = 1;
        db.config.repair_worker_chunk_size = 1;

        const ops = @import("../operations/operations.zig");
        const top_id = try ops.createCategory(db, 0, "Top", "top", "");
        const parent_id = try ops.createCategory(db, top_id, "P", "old", "");
        _ = try ops.createCategory(db, parent_id, "C1", "c1", "");
        _ = try ops.createCategory(db, parent_id, "C2", "c2", "");
        db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
        db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

        try ops.updateCategory(db, parent_id, null, "new", null);
        try processOneChunk(db);
    }

    {
        var db = try Directory.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try tickOnce(db);
        try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
    }
}

test "repair_worker: multi-chunk resumable walk repairs every descendant" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 5;
    db.config.repair_worker_chunk_size = 7;

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const parent_id = try ops.createCategory(db, top_id, "P", "old", "");
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "c{d}", .{i}) catch unreachable;
        const child = try ops.createCategory(db, parent_id, "x", slug, "");
        if (i == 0) _ = try ops.createCategory(db, child, "GC", "gc", "");
    }
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    try ops.updateCategory(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entryCount() > 0);

    try tickOnce(db);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entryCount());

    var j: u32 = 0;
    while (j < 30) : (j += 1) {
        var old_buf: [64]u8 = undefined;
        var new_buf: [64]u8 = undefined;
        const old = std.fmt.bufPrint(&old_buf, "top/old/c{d}", .{j}) catch unreachable;
        const new = std.fmt.bufPrint(&new_buf, "top/new/c{d}", .{j}) catch unreachable;
        try std.testing.expect((try ops.resolveSlugPath(db, old)) == null);
        try std.testing.expect((try ops.resolveSlugPath(db, new)) != null);
    }
    try std.testing.expect((try ops.resolveSlugPath(db, "top/old/c0/gc")) == null);
    try std.testing.expect((try ops.resolveSlugPath(db, "top/new/c0/gc")) != null);
}
