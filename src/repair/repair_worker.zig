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
const depth_max = @import("../operations/operations_shared.zig").depth_max;

const log = std.log.scoped(.repair_worker);

// A path is composed from stored slugs before it is checked, and a store written before slug
// paths were capped holds longer ones, so the buffers have room for them; only a path within
// `slug_path_len_max` is ever indexed.
pub const slug_path_buffer_len = changeset.path_composed_len_max;
const slug_path_len_max = @import("../operations/operations_shared.zig").slug_path_len_max;

comptime {
    assert(slug_path_buffer_len > slug_path_len_max);
}

// One page of children per scan of cat_by_parent; a frame resumes after its last child.
const children_per_page: u32 = 256;

// The walk pushes one frame per child visited and pops a frame once its children run out, so
// a tree within depth_max holds at most one page of frames per level. A deeper walk means a
// corrupt or cyclic hierarchy and ends the task with an error instead of growing the stack.
const walk_frames_max: u32 = depth_max * children_per_page;

// Every chunk but the last visits at least one category, so no well-formed subtree needs more
// chunks than this; a walk that does is reported instead of running on.
const walk_chunks_max: u32 = 1 << 24;

pub const RepairWalkError = error{ RepairWalkTooDeep, RepairWalkTooLong };

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

// A frame resumes by key, after the last child it visited, so a sibling deleted or moved
// between two chunks cannot shift the rest of the page past the walk.
const WalkFrame = struct { id: u64, after_child_id: u64 };
const WalkStack = std.ArrayList(WalkFrame);

fn process_task(db: *Directory, queued: *const QueuedTask) !void {
    assert(queued.seq != 0);
    const started_ms = db.now_millis();

    const root_category = try operations.get_category(db, queued.task.cat_id);
    if (root_category == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = queued.seq } });
        log.info(
            "task seq={d} cat_id={d} cat-deleted; queue entry removed",
            .{ queued.seq, queued.task.cat_id },
        );
        return;
    }

    const frames = try db.allocator.alloc(WalkFrame, walk_frames_max);
    defer db.allocator.free(frames);

    var stack = WalkStack.initBuffer(frames);
    stack.appendAssumeCapacity(.{ .id = queued.task.cat_id, .after_child_id = 0 });

    // A walk error comes from the stored hierarchy (a cycle, or a tree deeper or wider than
    // any well-formed one), so every retry would fail the same way, and a queued task refuses
    // edits under its root for as long as it stays. The task is given up and logged; op 20
    // rebuilds the rows it could not reach.
    const chunks = walk_task(db, queued, &stack) catch |err| switch (err) {
        error.RepairWalkTooDeep, error.RepairWalkTooLong => {
            log.warn("task seq={d} cat_id={d} abandoned: {}; the hierarchy under it is " ++
                "corrupt and rebuild_index repairs its slug paths", .{
                queued.seq,
                queued.task.cat_id,
                err,
            });
            db.write_mutex.lockUncancelable(db.io);
            defer db.write_mutex.unlock(db.io);
            try db.commit(changeset.ChangeSet{
                .slug_path_repair_complete = .{ .seq = queued.seq },
            });
            return;
        },
        else => return err,
    };
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

// Returns the number of chunks that committed swaps.
fn walk_task(db: *Directory, queued: *const QueuedTask, stack: *WalkStack) !u32 {
    assert(stack.items.len == 1);
    var chunks: u32 = 0;
    var chunks_walked: u32 = 0;
    while (stack.items.len > 0) : (chunks_walked += 1) {
        if (chunks_walked >= walk_chunks_max) return RepairWalkError.RepairWalkTooLong;
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        if (try process_chunk(db, queued, stack)) chunks += 1;
    }
    assert(chunks <= chunks_walked);
    return chunks;
}

fn process_one_chunk(db: *Directory) !void {
    const queued = (try peek_min(db)) orelse return;
    assert(queued.seq != 0);
    if ((try operations.get_category(db, queued.task.cat_id)) == null) {
        try db.commit(changeset.ChangeSet{ .slug_path_repair_complete = .{ .seq = queued.seq } });
        return;
    }

    const frames = try db.allocator.alloc(WalkFrame, walk_frames_max);
    defer db.allocator.free(frames);

    var stack = WalkStack.initBuffer(frames);
    stack.appendAssumeCapacity(.{ .id = queued.task.cat_id, .after_child_id = 0 });
    assert(stack.items.len == 1);
    _ = try process_chunk(db, &queued, &stack);
}

fn plan_swap(
    db: *Directory,
    options: struct { root_id: u64, child_id: u64 },
    old_root_path: []const u8,
    swap_allocator: std.mem.Allocator,
) !?changeset.SlugPathSwap {
    assert(options.child_id != 0);
    var old_path_buffer: [slug_path_buffer_len]u8 = undefined;
    const old_path = (operations.compose_old_descendant_path(
        db,
        old_root_path,
        .{ .root_id = options.root_id, .descendant_id = options.child_id },
        &old_path_buffer,
    ) catch null) orelse
        return null;
    assert(std.mem.startsWith(u8, old_path, old_root_path));

    var new_path_buffer: [slug_path_buffer_len]u8 = undefined;
    const new_path = (try operations.build_slug_path(
        db,
        options.child_id,
        &new_path_buffer,
    )) orelse return null;
    assert(new_path.len > 0);
    assert(new_path.len <= new_path_buffer.len);

    if (std.mem.eql(u8, old_path, new_path)) return null;
    // Only a store written before paths were capped holds a descendant this long, and indexing
    // it would be refused on every retry and hold the task, which blocks edits under its root,
    // in the queue for good. The old path stays mapped and rebuild_index reports the category.
    if (new_path.len > slug_path_len_max) {
        log.warn("task skips category {d}: its {d}-byte slug path is over the key maximum", .{
            options.child_id,
            new_path.len,
        });
        return null;
    }
    var value_buffer: [16]u8 = undefined;
    if ((try db.categories_by_slug_path().search(old_path, &value_buffer)) == null) return null;
    return changeset.SlugPathSwap{
        .old_path = try swap_allocator.dupe(u8, old_path),
        .new_path = try swap_allocator.dupe(u8, new_path),
        .cat_id = options.child_id,
    };
}

// A chunk ends after `repair_worker_chunk_size` categories visited, swapped or not, so a task
// whose descendants need no swap still releases write_mutex between chunks.
fn process_chunk(db: *Directory, queued: *const QueuedTask, stack: *WalkStack) !bool {
    assert(stack.items.len > 0);
    const chunk_size = @max(db.config.repair_worker_chunk_size, 1);

    var swap_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer swap_arena.deinit();
    const swap_allocator = swap_arena.allocator();

    var swaps: std.ArrayList(changeset.SlugPathSwap) = .empty;
    const old_root_path = queued.task.old_slug_prefix.slice();
    var child_ids: [children_per_page]u64 = undefined;
    var visited: u32 = 0;

    while (stack.items.len > 0) {
        const frame_index = stack.items.len - 1;
        const children = try list_child_ids(db, stack.items[frame_index], &child_ids);
        if (children.len == 0) {
            _ = stack.pop();
            continue;
        }

        for (children) |child_id| {
            stack.items[frame_index].after_child_id = child_id;
            stack.appendBounded(.{ .id = child_id, .after_child_id = 0 }) catch
                return RepairWalkError.RepairWalkTooDeep;
            assert(stack.items.len <= walk_frames_max);
            visited += 1;

            if (try plan_swap(
                db,
                .{ .root_id = queued.task.cat_id, .child_id = child_id },
                old_root_path,
                swap_allocator,
            )) |swap| {
                try swaps.append(swap_allocator, swap);
            }
            if (visited >= chunk_size) break;
        }
        if (visited >= chunk_size) break;
    }

    assert(swaps.items.len <= visited);
    assert(visited <= chunk_size);
    if (swaps.items.len == 0) return false;
    try commit_swaps(db, queued.seq, swaps.items);
    return true;
}

// Reads one page of child ids after the frame's last visited child, straight from the
// (parent, child) keys of cat_by_parent, which is the order the walk resumes in.
fn list_child_ids(
    db: *Directory,
    frame: WalkFrame,
    buffer: *[children_per_page]u64,
) ![]const u64 {
    assert(frame.id != 0);
    if (frame.after_child_id == std.math.maxInt(u64)) return buffer[0..0];
    assert(frame.after_child_id < std.math.maxInt(u64));
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const start_key = schema.ParentChildKey.encode(.{ frame.id, frame.after_child_id + 1 });
    const end_key = schema.ParentChildKey.encode(.{ frame.id, std.math.maxInt(u64) });
    var iterator = try db.cat_by_parent().rangeScan(&start_key, &end_key);
    defer iterator.deinit();

    var count: u32 = 0;
    while (count < children_per_page) : (count += 1) {
        const entry = (try iterator.next()) orelse break;
        if (entry.key.len != schema.ParentChildKey.encoded_size) {
            return operations.OperationError.DatabaseCorrupted;
        }
        buffer[count] = schema.ParentChildKey.decode(entry.key).child_id;
    }
    assert(count <= children_per_page);
    return buffer[0..count];
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

// Builds top/old with `child_count` children c0, c1, ... and renames old to new above a
// threshold of one, so the repair is queued; the returned ids are the parent, then the children.
fn queue_rename_of_parent(db: *Directory, child_ids: []u64) !u64 {
    assert(child_ids.len > 0);
    db.config.rename_inline_threshold = 1;
    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "P", .slug = "old", .description = "" },
    );
    for (child_ids, 0..) |*child_id, index| {
        var slug_buffer: [8]u8 = undefined;
        const slug = try std.fmt.bufPrint(&slug_buffer, "c{d}", .{index});
        child_id.* = try operations.create_category(
            db,
            parent_id,
            .{ .name = "x", .slug = slug, .description = "" },
        );
    }
    try db.drain_all_memtables();
    try operations.update_category(db, parent_id, null, "new", null);
    assert(db.slug_path_repair_queue().entryCount() == 1);
    return parent_id;
}

// Goal: a child that leaves the parent between two chunks does not make the walk skip the
// sibling after it. Method: chunk size two over six children; after the first chunk drop the
// (parent, c0) edge from cat_by_parent, as a delete applies it, then finish the task and expect
// every remaining child under the new path.
test "repair_worker: a child removed between chunks does not skip its next sibling" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.repair_worker_chunk_size = 2;

    var child_ids: [6]u64 = undefined;
    const parent_id = try queue_rename_of_parent(db, &child_ids);
    const queued = (try peek_min(db)).?;
    const frames = try allocator.alloc(WalkFrame, walk_frames_max);
    defer allocator.free(frames);
    var stack = WalkStack.initBuffer(frames);
    stack.appendAssumeCapacity(.{ .id = queued.task.cat_id, .after_child_id = 0 });

    try std.testing.expect(try process_chunk(db, &queued, &stack));
    const edge = schema.ParentChildKey.encode(.{ parent_id, child_ids[0] });
    try std.testing.expect(try db.cat_by_parent().delete(&edge));
    for (0..child_ids.len) |_| {
        if (stack.items.len == 0) break;
        _ = try process_chunk(db, &queued, &stack);
    }
    try std.testing.expectEqual(@as(usize, 0), stack.items.len);

    for (1..child_ids.len) |index| {
        var path_buffer: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "top/new/c{d}", .{index});
        const resolved = try operations.resolve_slug_path(db, path);
        try std.testing.expectEqual(child_ids[index], resolved.?);
    }
}

// Goal: a chunk with nothing to swap still ends after chunk_size visits, so write_mutex is
// released between chunks. Method: rename the parent twice and finish the first task, which
// leaves a second task with no rows to swap; one chunk of size two must leave work on the stack.
test "repair_worker: a chunk ends after chunk_size visits even when nothing needs a swap" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.repair_worker_chunk_size = 2;

    var child_ids: [6]u64 = undefined;
    const parent_id = try queue_rename_of_parent(db, &child_ids);
    try operations.update_category(db, parent_id, null, "newer", null);
    try tick_once(db);
    try std.testing.expectEqual(@as(u64, 1), db.slug_path_repair_queue().entryCount());

    const queued = (try peek_min(db)).?;
    const frames = try allocator.alloc(WalkFrame, walk_frames_max);
    defer allocator.free(frames);
    var stack = WalkStack.initBuffer(frames);
    stack.appendAssumeCapacity(.{ .id = queued.task.cat_id, .after_child_id = 0 });

    try std.testing.expect(!(try process_chunk(db, &queued, &stack)));
    try std.testing.expect(stack.items.len > 0);
}

// Goal: a cyclic hierarchy ends the walk at the declared stack maximum instead of growing without
// bound, and the task is given up rather than refusing edits under its root for good. Method:
// queue a repair of the parent, add an edge that makes the parent a child of its own child, tick,
// and expect an empty queue and a rename under the parent accepted.
test "repair_worker: a cycle in cat_by_parent stops the walk at the frame maximum" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var child_ids: [2]u64 = undefined;
    const parent_id = try queue_rename_of_parent(db, &child_ids);
    const back_edge = schema.ParentChildKey.encode(.{ child_ids[0], parent_id });
    try db.cat_by_parent().insert(&back_edge, &codec.encodeU64(parent_id));

    try tick_once(db);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entryCount());
    try operations.update_category(db, child_ids[1], null, "c1x", null);
}

// Goal: while an ancestor's repair is queued, a rename, move or delete inside its subtree is
// refused, because the descendant rows still carry the old prefix and the edit would strand
// them. Method: queue a rename of the parent, try each edit on a child, then let the worker
// finish and expect the rename through and one slug row per category.
test "repair_worker: an edit under a queued repair waits for it instead of stranding rows" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var child_ids: [2]u64 = undefined;
    const parent_id = try queue_rename_of_parent(db, &child_ids);
    const top_id = (try operations.resolve_slug_path(db, "top")).?;
    const pending = error.SlugRepairPending;
    try std.testing.expectError(
        pending,
        operations.update_category(db, child_ids[0], null, "c0x", null),
    );
    try std.testing.expectError(
        pending,
        operations.move_category(db, .{ .id = child_ids[0], .new_parent_id = top_id }),
    );
    try std.testing.expectError(pending, operations.delete_category(db, child_ids[1]));

    try tick_once(db);
    try operations.update_category(db, child_ids[0], null, "c0x", null);
    const renamed = try operations.resolve_slug_path(db, "top/new/c0x");
    try std.testing.expectEqual(child_ids[0], renamed.?);
    try std.testing.expect((try operations.resolve_slug_path(db, "top/old/c0")) == null);
    try db.drain_all_memtables();
    try std.testing.expectEqual(
        db.categories_by_id().entryCount(),
        db.categories_by_slug_path().entryCount(),
    );
    assert(parent_id != top_id);
}

// Goal: a queued repair whose subtree holds a path over the key maximum, as a store written
// before paths were capped can, repairs every other descendant and leaves the queue, instead of
// committing a key the engine refuses after the WAL append. Method: rename a parent's stored
// slug to 128 bytes by rewriting its record and queue the task the rename would have queued, so
// one child's new path is 261 bytes and its sibling's fits, then tick once.
test "repair_worker: a descendant path over the key maximum is skipped, the rest repaired" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "P", .slug = "old", .description = "" },
    );
    const long_slug: [128]u8 = @splat('c');
    _ = try operations.create_category(
        db,
        parent_id,
        .{ .name = "Long", .slug = &long_slug, .description = "" },
    );
    _ = try operations.create_category(
        db,
        parent_id,
        .{ .name = "Short", .slug = "d", .description = "" },
    );
    try db.drain_all_memtables();

    var parent = (try operations.get_category(db, parent_id)).?;
    parent.slug = .fromSlice(&@as([128]u8, @splat('p')));
    try db.categories_by_id().insert(&codec.encodeU64(parent_id), std.mem.asBytes(&parent));
    const task = schema.RepairTask{
        .cat_id = parent_id,
        .op = .renamed_slug,
        .old_slug_prefix = .fromSlice("top/old"),
    };
    try db.slug_path_repair_queue().insert(&codec.encodeU64(1), std.mem.asBytes(&task));

    try tick_once(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entryCount());
    var path_buffer: [slug_path_buffer_len]u8 = undefined;
    const short_path = try std.fmt.bufPrint(&path_buffer, "top/{s}/d", .{&parent.slug.data});
    var value_buffer: [8]u8 = undefined;
    try std.testing.expect(
        (try db.categories_by_slug_path().search(short_path, &value_buffer)) != null,
    );
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/old/d", &value_buffer)) == null,
    );
    const old_long_path = try std.fmt.bufPrint(&path_buffer, "top/old/{s}", .{&long_slug});
    try std.testing.expect(
        (try db.categories_by_slug_path().search(old_long_path, &value_buffer)) != null,
    );
}
