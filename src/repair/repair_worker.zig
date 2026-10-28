//! Background worker for the slug-path repairs that were too large to apply inline with a
//! rename or move. It walks the subtree with an explicit stack in bounded chunks, each
//! committed as its own WAL record, so a crash mid-walk resumes from the last chunk, and the
//! task leaves the queue only after every descendant is done.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const Directory = @import("../directory.zig").Directory;
const schema = @import("../schema.zig");
const changeset = @import("../changeset.zig");
const operations = @import("../operations/operations.zig");

const log = std.log.scoped(.repair_worker);

pub const slug_path_len_max: usize = 2048;

// One page of children per list_children call; a frame's child_offset resumes after it.
const children_per_page: u32 = 256;

pub fn tick_once(db: *Directory) !void {
    db.repair_worker_mutex.lockUncancelable(db.io);
    defer db.repair_worker_mutex.unlock(db.io);

    if (db.slug_path_repair_queue().entryCount() != 0) {
        if (try peek_min(db)) |queued| {
            assert(queued.seq != 0);
            try process_task(db, &queued);
        }
    }

    db.repair_worker_last_tick_ms.store(db.now_millis(), .release);

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

fn peek_min(db: *Directory) !?QueuedTask {
    const start_key: [8]u8 = @splat(0);
    var iterator = try db.slug_path_repair_queue().rangeScan(&start_key, null);
    defer iterator.deinit();
    const entry = (try iterator.next()) orelse return null;
    if (entry.value.len < @sizeOf(schema.RepairTask)) return null;
    if (entry.key.len < 8) return null;
    const seq = codec.decodeU64(entry.key[0..8]);
    if (seq == 0) return null;
    const task = std.mem.bytesToValue(
        schema.RepairTask,
        entry.value[0..@sizeOf(schema.RepairTask)],
    );
    return QueuedTask{ .seq = seq, .task = task };
}

const WalkFrame = struct { id: u64, child_offset: u32 };

fn process_task(db: *Directory, queued: *const QueuedTask) !void {
    assert(queued.seq != 0);
    const started_ms = db.now_millis();
    var chunks: u32 = 0;

    const root_category = try operations.get_category(db, queued.task.cat_id);
    if (root_category == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = queued.seq } });
        log.info(
            "task seq={d} cat_id={d} cat-deleted; queue entry removed",
            .{ queued.seq, queued.task.cat_id },
        );
        return;
    }

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();

    var stack: std.ArrayList(WalkFrame) = .empty;
    try stack.append(arena.allocator(), .{ .id = queued.task.cat_id, .child_offset = 0 });

    while (stack.items.len > 0) {
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        if (try process_chunk(db, queued, &stack, arena.allocator())) chunks += 1;
    }
    assert(db.repair_worker_chunks_processed.load(.monotonic) >= chunks);

    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = queued.seq } });
    _ = db.repair_worker_tasks_processed.fetchAdd(1, .monotonic);
    log.info("task seq={d} cat_id={d} op={s} chunks={d} processed in {d} ms", .{
        queued.seq,
        queued.task.cat_id,
        @tagName(queued.task.op),
        chunks,
        db.now_millis() - started_ms,
    });
}

fn process_one_chunk(db: *Directory) !void {
    const queued = (try peek_min(db)) orelse return;
    assert(queued.seq != 0);
    if ((try operations.get_category(db, queued.task.cat_id)) == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = queued.seq } });
        return;
    }

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();

    var stack: std.ArrayList(WalkFrame) = .empty;
    try stack.append(arena.allocator(), .{ .id = queued.task.cat_id, .child_offset = 0 });
    assert(stack.items.len == 1);
    _ = try process_chunk(db, &queued, &stack, arena.allocator());
}

fn plan_swap(
    db: *Directory,
    options: struct { root_id: u64, child_id: u64 },
    old_root_path: []const u8,
    swap_allocator: std.mem.Allocator,
) !?changeset.SlugPathSwap {
    assert(options.child_id != 0);
    var old_path_buffer: [slug_path_len_max]u8 = undefined;
    const old_path = (operations.compose_old_descendant_path(
        db,
        old_root_path,
        .{ .root_id = options.root_id, .descendant_id = options.child_id },
        &old_path_buffer,
    ) catch null) orelse
        return null;
    assert(std.mem.startsWith(u8, old_path, old_root_path));

    var new_path_buffer: [slug_path_len_max]u8 = undefined;
    const new_path = (try operations.build_slug_path(
        db,
        options.child_id,
        &new_path_buffer,
    )) orelse return null;
    assert(new_path.len > 0);

    if (std.mem.eql(u8, old_path, new_path)) return null;
    var value_buffer: [16]u8 = undefined;
    if ((try db.categories_by_slug_path().search(old_path, &value_buffer)) == null) return null;
    return changeset.SlugPathSwap{
        .old_path = try swap_allocator.dupe(u8, old_path),
        .new_path = try swap_allocator.dupe(u8, new_path),
        .cat_id = options.child_id,
    };
}

fn process_chunk(
    db: *Directory,
    queued: *const QueuedTask,
    stack: *std.ArrayList(WalkFrame),
    stack_allocator: std.mem.Allocator,
) !bool {
    assert(stack.items.len > 0);
    const chunk_size = db.config.repair_worker_chunk_size;

    var swap_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer swap_arena.deinit();
    const swap_allocator = swap_arena.allocator();

    var swaps: std.ArrayList(changeset.SlugPathSwap) = .empty;
    const old_root_path = queued.task.old_slug_prefix.slice();
    const children_buffer = try swap_allocator.alloc(schema.Category, children_per_page);

    while (stack.items.len > 0) {
        const frame_index = stack.items.len - 1;
        const current_id = stack.items[frame_index].id;
        const current_offset = stack.items[frame_index].child_offset;

        const children = try operations.list_children(
            db,
            current_id,
            .{ .offset = current_offset, .limit = children_per_page },
            children_buffer,
        );
        assert(children.len <= children_per_page);
        if (children.len == 0) {
            _ = stack.pop();
            continue;
        }

        for (children, 0..) |child, i| {
            try stack.append(stack_allocator, .{ .id = child.id, .child_offset = 0 });

            if (try plan_swap(
                db,
                .{ .root_id = queued.task.cat_id, .child_id = child.id },
                old_root_path,
                swap_allocator,
            )) |swap| {
                try swaps.append(swap_allocator, swap);
            }

            if (swaps.items.len >= chunk_size) {
                assert(i < children_per_page);
                const resume_offset = current_offset + @as(u32, @intCast(i)) + 1;
                assert(resume_offset > current_offset);
                stack.items[frame_index].child_offset = resume_offset;
                try commit_swaps(db, queued.seq, swaps.items);
                return true;
            }
        }

        const next_offset = current_offset + @as(u32, @intCast(children.len));
        assert(next_offset > current_offset);
        stack.items[frame_index].child_offset = next_offset;
    }

    assert(swaps.items.len <= chunk_size);
    if (swaps.items.len == 0) return false;
    try commit_swaps(db, queued.seq, swaps.items);
    return true;
}

fn commit_swaps(db: *Directory, seq: u64, swaps: []const changeset.SlugPathSwap) !void {
    assert(seq != 0);
    try db.commit(changeset.ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = seq,
        .swaps = swaps,
    } });
    _ = db.repair_worker_chunks_processed.fetchAdd(1, .monotonic);
}

// Rename "old" to "new" above a threshold of one so the swaps are queued, tick once, and
// expect the children resolvable under the new path only.
test "repair_worker: drains a single queued task end-to-end" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 1;

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "P", .slug = "old", .description = "" },
    );
    _ = try ops.create_category(db, parent_id, .{ .name = "C1", .slug = "c1", .description = "" });
    _ = try ops.create_category(db, parent_id, .{ .name = "C2", .slug = "c2", .description = "" });
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    try ops.update_category(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entry_count > 0);

    try tick_once(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);

    var value_buffer: [16]u8 = undefined;
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/old/c1", &value_buffer)) == null,
    );
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/new/c1", &value_buffer)) != null,
    );
}

// A task whose category no longer exists is completed and removed instead of blocking the queue.
test "repair_worker: handles category deleted before drain" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const task = schema.RepairTask{ .cat_id = 9999, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));

    try tick_once(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
}

// Process exactly one chunk of size one, drop the instance as a crash would, reopen and tick:
// the task must finish from where the committed chunk left it.
test "repair_worker: idempotent across simulated mid-walk crash" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    {
        var db = try Directory.open_test_instance(allocator, &temporary_directory);
        defer db.deinit_test_instance();
        db.config.rename_inline_threshold = 1;
        db.config.repair_worker_chunk_size = 1;

        const ops = @import("../operations/operations.zig");
        const top_id = try ops.create_category(
            db,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const parent_id = try ops.create_category(
            db,
            top_id,
            .{ .name = "P", .slug = "old", .description = "" },
        );
        _ = try ops.create_category(
            db,
            parent_id,
            .{ .name = "C1", .slug = "c1", .description = "" },
        );
        _ = try ops.create_category(
            db,
            parent_id,
            .{ .name = "C2", .slug = "c2", .description = "" },
        );
        try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
        try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

        try ops.update_category(db, parent_id, null, "new", null);
        try process_one_chunk(db);
    }

    {
        var db = try Directory.open_test_instance(allocator, &temporary_directory);
        defer db.deinit_test_instance();
        try tick_once(db);
        try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
    }
}

// Thirty children plus one grandchild with a chunk size of seven force several resumed chunks;
// every descendant must resolve under the new path and none under the old.
test "repair_worker: multi-chunk resumable walk repairs every descendant" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 5;
    db.config.repair_worker_chunk_size = 7;

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "P", .slug = "old", .description = "" },
    );
    var i: u32 = 0;
    while (i < 30) : (i += 1) {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "c{d}", .{i}) catch unreachable;
        const child = try ops.create_category(
            db,
            parent_id,
            .{ .name = "x", .slug = slug, .description = "" },
        );
        if (i == 0) _ = try ops.create_category(
            db,
            child,
            .{ .name = "GC", .slug = "gc", .description = "" },
        );
    }
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    try ops.update_category(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entryCount() > 0);

    try tick_once(db);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entryCount());

    var j: u32 = 0;
    while (j < 30) : (j += 1) {
        var old_buffer: [64]u8 = undefined;
        var new_buffer: [64]u8 = undefined;
        const old = std.fmt.bufPrint(&old_buffer, "top/old/c{d}", .{j}) catch unreachable;
        const new = std.fmt.bufPrint(&new_buffer, "top/new/c{d}", .{j}) catch unreachable;
        try std.testing.expect((try ops.resolve_slug_path(db, old)) == null);
        try std.testing.expect((try ops.resolve_slug_path(db, new)) != null);
    }
    try std.testing.expect((try ops.resolve_slug_path(db, "top/old/c0/gc")) == null);
    try std.testing.expect((try ops.resolve_slug_path(db, "top/new/c0/gc")) != null);
}
