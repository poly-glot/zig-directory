//! Drains the slug_path_repair_queue B+Tree.
//!
//! Each tick: pop the min-key task, walk its cat's descendants,
//! delete-old + insert-new in chunked ChangeSets (so progress is
//! WAL-durable), then commit a slug_path_repair_complete to remove
//! the queue entry. Idempotent on crash mid-walk.

const std = @import("std");
const Database = @import("../database.zig").Database;
const types = @import("../types.zig");
const changeset = @import("../changeset.zig");
const operations = @import("../operations/operations.zig");

const log = std.log.scoped(.repair_worker);

/// Public entry point for the background loop. Wakes every
/// db.config.repair_worker_interval_ms, processes up to
/// db.config.repair_worker_max_tasks_per_tick tasks per tick.
pub fn loop(db: *Database) void {
    while (!db.repair_worker_shutdown.load(.acquire)) {
        std.Thread.sleep(@as(u64, db.config.repair_worker_interval_ms) * std.time.ns_per_ms);
        if (db.repair_worker_shutdown.load(.acquire)) break;
        tickOnce(db) catch |err| {
            log.warn("tick failed: {}", .{err});
        };
    }
}

/// Synchronous single-tick entry point. Used by the loop and by tests.
pub fn tickOnce(db: *Database) !void {
    const max_tasks = db.config.repair_worker_max_tasks_per_tick;
    var processed: u32 = 0;
    while (processed < max_tasks) : (processed += 1) {
        if (db.slug_path_repair_queue.entry_count == 0) break;
        const task = (try peekMin(db)) orelse break;
        try processTask(db, task);
    }

    // Stamp tick completion for op 18 `index_health` observability.
    db.repair_worker_last_tick_ms.store(std.time.milliTimestamp(), .release);

    // Warn at queue-depth thresholds so operators see drain falling behind.
    const depth = db.slug_path_repair_queue.entry_count;
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
    task: types.RepairTask,
};

fn peekMin(db: *Database) !?QueuedTask {
    const start_key = [_]u8{0} ** 8;
    var iter = try db.slug_path_repair_queue.rangeScan(&start_key, null);
    if (try iter.next()) |entry| {
        if (entry.value.len < @sizeOf(types.RepairTask)) return null;
        if (entry.key.len < 8) return null;
        const t = std.mem.bytesToValue(types.RepairTask, entry.value[0..@sizeOf(types.RepairTask)]);
        const seq = std.mem.readInt(u64, entry.key[0..8], .big);
        return QueuedTask{ .seq = seq, .task = t };
    }
    return null;
}

fn processTask(db: *Database, qt: QueuedTask) !void {
    const t0 = std.time.milliTimestamp();
    var chunks: u32 = 0;

    // If the cat is gone, the queue entry is stale: just clean it up.
    const root_cat = try operations.getCategory(db, qt.task.cat_id);
    if (root_cat == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = qt.seq } });
        log.info("task seq={d} cat_id={d} cat-deleted; queue entry removed", .{ qt.seq, qt.task.cat_id });
        return;
    }

    while (true) {
        const did_work = try processChunk(db, qt);
        if (!did_work) break;
        chunks += 1;
    }

    // Final commit: remove the queue entry.
    try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = qt.seq } });
    _ = db.repair_worker_tasks_processed.fetchAdd(1, .monotonic);
    log.info("task seq={d} cat_id={d} op={s} chunks={d} processed in {d} ms", .{
        qt.seq, qt.task.cat_id, @tagName(qt.task.op), chunks, std.time.milliTimestamp() - t0,
    });
}

/// Process exactly one chunk of work for the head-of-queue task and
/// commit it. Exposed for tests that want to simulate a mid-walk crash
/// (the queue entry survives so a reopen can resume).
pub fn processOneChunk(db: *Database) !void {
    const qt = (try peekMin(db)) orelse return;
    // Skip stale tasks the same way processTask does.
    if ((try operations.getCategory(db, qt.task.cat_id)) == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = qt.seq } });
        return;
    }
    _ = try processChunk(db, qt);
}

fn processChunk(db: *Database, qt: QueuedTask) !bool {
    const chunk_size = db.config.repair_worker_chunk_size;
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var swaps: std.ArrayList(changeset.SlugPathSwap) = .{};
    var stack: std.ArrayList(u64) = .{};
    try stack.append(aa, qt.task.cat_id);

    const old_root_path = qt.task.old_slug_prefix.slice();

    walk: while (stack.pop()) |cur_id| {
        var children_buf: [256]types.Category = undefined;
        var offset: u32 = 0;
        while (true) {
            const children = try operations.listChildren(db, cur_id, offset, 256, &children_buf);
            if (children.len == 0) break;
            for (children) |child| {
                var d_old_buf: [2048]u8 = undefined;
                const d_old_opt = composeOldPath(db, old_root_path, qt.task.cat_id, child.id, &d_old_buf) catch null;
                var d_new_buf: [2048]u8 = undefined;
                const d_new_opt = try operations.buildCanonicalSlugPath(db, &child, &d_new_buf);

                // Always recurse so descendants of this child get visited
                // even if we couldn't compute a path swap for the child
                // itself (e.g. ancestor lookup failed mid-walk).
                try stack.append(aa, child.id);

                if (d_old_opt) |d_old| {
                    if (d_new_opt) |d_new| {
                        if (!std.mem.eql(u8, d_old, d_new)) {
                            // Skip swaps whose target already matches: an
                            // earlier crash-recovered chunk may already have
                            // moved this descendant. Idempotent.
                            var v_buf: [16]u8 = undefined;
                            const at_old = (try db.categories_by_slug_path.search(d_old, &v_buf)) != null;
                            if (at_old) {
                                try swaps.append(aa, .{
                                    .old_path = try aa.dupe(u8, d_old),
                                    .new_path = try aa.dupe(u8, d_new),
                                    .cat_id = child.id,
                                });
                            }
                        }
                    }
                }

                if (swaps.items.len >= chunk_size) break :walk;
            }
            offset += @intCast(children.len);
            if (children.len < 256) break;
        }
    }

    if (swaps.items.len == 0) return false;

    try db.commit(changeset.ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = qt.seq,
        .swaps = swaps.items,
    } });
    _ = db.repair_worker_chunks_processed.fetchAdd(1, .monotonic);
    return true;
}

/// Reconstruct a descendant's pre-rename slug-path by walking from the
/// descendant up to the renamed root, then composing
/// `old_root_path + relative_tail` (where the tail uses CURRENT slugs of
/// intermediate ancestors — those are unchanged by a rename of `root_id`).
fn composeOldPath(
    db: *Database,
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 1;

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const parent_id = try ops.createCategory(db, top_id, "P", "old", "");
    _ = try ops.createCategory(db, parent_id, "C1", "c1", "");
    _ = try ops.createCategory(db, parent_id, "C2", "c2", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    // Trigger a > threshold rename (threshold=1, descendants=2).
    try ops.updateCategory(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue.entry_count > 0);

    // Run the worker tick directly (synchronous, no thread).
    try tickOnce(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);

    // After drain: old descendant paths gone, new ones present.
    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_by_slug_path.search("top/old/c1", &v_buf)) == null);
    try std.testing.expect((try db.categories_by_slug_path.search("top/new/c1", &v_buf)) != null);
}

test "repair_worker: handles cat deleted before drain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Plant an orphaned task (cat_id refers to non-existent cat).
    var task = types.RepairTask{ .cat_id = 9999, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue.insert(&key, std.mem.asBytes(&task));

    try tickOnce(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
}

test "repair_worker: idempotent across simulated mid-walk crash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Phase 1: seed > threshold rename, run worker partially.
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        db.config.rename_inline_threshold = 1;
        db.config.repair_worker_chunk_size = 1; // force two chunks

        const ops = @import("../operations/operations.zig");
        const top_id = try ops.createCategory(db, 0, "Top", "top", "");
        const parent_id = try ops.createCategory(db, top_id, "P", "old", "");
        _ = try ops.createCategory(db, parent_id, "C1", "c1", "");
        _ = try ops.createCategory(db, parent_id, "C2", "c2", "");
        db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
        db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

        try ops.updateCategory(db, parent_id, null, "new", null);
        // "Crash" mid-walk by calling processOneChunk only.
        try processOneChunk(db);
    }

    // Phase 2: reopen, run worker to completion.
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try tickOnce(db);
        try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
    }
}
