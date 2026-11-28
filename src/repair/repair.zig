//! Rebuilds every derived index (slug paths, slug-only shortcuts, token postings) from the
//! primary category and link records, then drains the slug-path repair queue: the admin op
//! for an index that has drifted from its source of truth.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const codec = zigstore.codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const Store = @import("../directory.zig").Store;
const operations = @import("../operations/operations.zig");
const operations_slug = @import("../operations/operations_slug.zig");
const compute = @import("../operations/operations_changeset_compute.zig");
const depth_max = @import("../operations/operations_shared.zig").depth_max;
const slug_path_len_max = @import("../operations/operations_shared.zig").slug_path_len_max;
const apply = @import("../apply/apply.zig");
const repair_worker = @import("repair_worker.zig");

const log = std.log.scoped(.repair);

pub const RebuildError = error{RebuildExceedsCache};

pub const RebuildStats = struct {
    categories_rebuilt: u64,
    links_rebuilt: u64,
    queue_entries_drained: u64,
};

pub fn rebuild_all_indices(db: *Directory) !RebuildStats {
    const started_ms = db.now_millis();

    var stats = RebuildStats{
        .categories_rebuilt = 0,
        .links_rebuilt = 0,
        .queue_entries_drained = 0,
    };

    {
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);

        try db.drain_all_memtables();

        db.store.mt_drain_mutex.lockUncancelable(db.io);
        defer db.store.mt_drain_mutex.unlock(db.io);
        db.store.apply_mutex.lockUncancelable(db.io);
        defer db.store.apply_mutex.unlock(db.io);

        try ensure_rebuild_fits(db);
        var category_ids: std.ArrayListUnmanaged(u64) = .empty;
        defer category_ids.deinit(db.allocator);
        try rebuild_category_indices_collect_ids(db, &category_ids);
        try ensure_slug_paths_fit(db, category_ids.items);

        stats.categories_rebuilt = rebuild_category_indices(db, category_ids.items) catch |err|
            abort_half_built(err);
        assert(
            db.categories_by_slug_only().entryCount() <= db.categories_by_slug_path().entryCount(),
        );

        stats.links_rebuilt = rebuild_link_index(db) catch |err| abort_half_built(err);
        assert(db.links_index_tree().entryCount() <= stats.links_rebuilt);
    }

    stats.queue_entries_drained = try drain_repair_queue(db);

    log.info(
        "rebuild_index: cats={d} links={d} drained={d} in {d}ms",
        .{
            stats.categories_rebuilt,
            stats.links_rebuilt,
            stats.queue_entries_drained,
            db.now_millis() - started_ms,
        },
    );
    return stats;
}

// Once the first tree is truncated the store holds half-built indexes in dirty pages that only
// a checkpoint writes, and the drain and apply locks this thread holds keep every checkpoint
// out. Returning would release them; aborting with them held means the next process serves the
// last checkpoint plus the WAL, which is the store as it was before the rebuild began.
// The engine's truncate never leaves the root over a freed page (it installs the empty root
// before it frees one), but a truncate that fails part way returns with its tree already
// emptied, so this does not make a failed rebuild safe to return from: the old entries are
// gone once a truncate starts, nothing in the WAL can bring them back, and the tree being
// refilled, and every tree after it, is left empty or partial. Any checkpoint after a return
// would make those incomplete indexes durable.
fn abort_half_built(err: anyerror) noreturn {
    log.err(
        "rebuild_index failed after truncating an index: {} — aborting so no checkpoint " ++
            "persists the half-built indexes; recovery serves the store as it was",
        .{err},
    );
    @panic("rebuild_index failed half way");
}

// Entries read from the front of each tree to estimate its average entry size.
const entry_sample_count: u32 = 1024;
// The slot directory of a page spends this many bytes per entry beside its key and value.
const slot_entry_bytes: u64 = 16;
// A B+tree split leaves its leaves half full, so a tree may take twice its entry bytes.
const leaf_fill_divisor: u64 = 2;
// Only this fraction of the clean frames is planned for: freed pages turn dirty as free-list
// entries and the rebuilt trees reuse them, while the rest serves the primary-tree scans and
// any rebuilt tree that comes out larger than the one it replaces.
const clean_frames_divisor: u64 = 2;

// A rebuild frees and refills the derived trees under the drain and apply locks, so no page can
// be flushed until it ends and the no-steal cache must hold every page it dirties. One that
// cannot fit is refused before anything is truncated, because a CacheFull half way leaves an
// emptied or partly refilled tree behind and the process must abort.
fn ensure_rebuild_fits(db: *Directory) !void {
    const trees = [_]*zigstore.BPlusTree{
        db.categories_by_slug_path(),
        db.categories_by_slug_only(),
        db.categories_index_tree(),
        db.links_index_tree(),
    };
    var bytes_estimate: u64 = 0;
    for (trees) |tree| bytes_estimate +|= try tree_bytes_estimate(tree);

    // The engine pads its header to exactly one page.
    const page_bytes: u64 = @sizeOf(Store.Header);
    comptime assert(page_bytes >= 4096);
    const bytes_planned = bytes_estimate *| leaf_fill_divisor;
    const pages_needed = std.math.divCeil(u64, bytes_planned, page_bytes) catch unreachable;
    const cache = &db.store.cache;
    const frames_clean: u64 = cache.capacity -| cache.dirty_count.load(.acquire);
    assert(frames_clean <= cache.capacity);
    const frames_planned = @divFloor(frames_clean, clean_frames_divisor);
    assert(frames_planned <= cache.capacity);

    if (pages_needed > frames_planned) {
        log.warn(
            "rebuild_index refused: the derived indexes need about {d} pages and the cache " ++
                "has {d} clean frames to spare; raise DMOZDB_CACHE_SIZE_MB",
            .{ pages_needed, frames_planned },
        );
        return RebuildError.RebuildExceedsCache;
    }
}

// The entry count comes from the superblock and may have drifted, which an estimate tolerates.
fn tree_bytes_estimate(tree: *zigstore.BPlusTree) !u64 {
    var iterator = try tree.rangeScan("", null);
    defer iterator.deinit();
    var sampled: u64 = 0;
    var sampled_bytes: u64 = 0;
    while (sampled < entry_sample_count) : (sampled += 1) {
        const entry = (try iterator.next()) orelse break;
        sampled_bytes += entry.key.len + entry.value.len + slot_entry_bytes;
    }
    assert(sampled <= entry_sample_count);
    assert(sampled_bytes >= sampled * slot_entry_bytes);
    if (sampled == 0) return 0;
    // The field is read under the scan's shared lock; entryCount() would take it a second time.
    return @divFloor(sampled_bytes *| @max(tree.entry_count, sampled), sampled);
}

// The stored hierarchy can make a rebuild certain to fail: a subtree moved below depth_max, a
// cycle, or a path longer than the tree can split on. Each is found here, before the first
// truncate, because past it a failure aborts the process and an admin retrying op 20 would
// crash the server on every attempt.
fn ensure_slug_paths_fit(db: *Directory, category_ids: []const u64) !void {
    var path_buffer: [repair_worker.slug_path_buffer_len]u8 = undefined;
    for (category_ids) |category_id| {
        const category = (try operations.get_category(db, category_id)) orelse continue;
        if (category.slug.slice().len == 0) continue;
        const path = try operations_slug.build_slug_path(db, category.id, &path_buffer);
        const full_path = path orelse continue;
        assert(full_path.len <= path_buffer.len);
        if (full_path.len > slug_path_len_max) {
            log.warn("rebuild_index refused: category {d} has a {d}-byte slug path", .{
                category.id,
                full_path.len,
            });
            return operations.OperationError.FieldTooLong;
        }
        if (slug_path_depth(full_path) >= depth_max) {
            log.warn("rebuild_index refused: category {d} sits below depth_max", .{category.id});
            return operations.OperationError.PathTooDeep;
        }
    }
}

fn slug_path_depth(full_path: []const u8) u32 {
    assert(full_path.len > 0);
    const depth: u32 = @intCast(std.mem.count(u8, full_path, "/"));
    assert(depth < full_path.len);
    return depth;
}

// The slug-only index maps a slug to the shallowest category carrying it, so a rebuild keeps
// the best candidate per slug and writes the index in one pass at the end.
const ShallowestCategory = struct { depth: u32, category_id: u64 };

fn rebuild_category_indices(db: *Directory, category_ids: []const u64) !u64 {
    try db.categories_by_slug_path().truncate(db.allocator);
    try db.categories_by_slug_only().truncate(db.allocator);
    try db.categories_index_tree().truncate(db.allocator);
    assert(db.categories_by_slug_path().entryCount() == 0);
    assert(db.categories_index_tree().entryCount() == 0);

    var shallowest = std.StringHashMap(ShallowestCategory).init(db.allocator);
    defer {
        var slug_iterator = shallowest.iterator();
        while (slug_iterator.next()) |entry| db.allocator.free(entry.key_ptr.*);
        shallowest.deinit();
    }

    var token_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer token_arena.deinit();

    var written: u64 = 0;
    var path_buffer: [repair_worker.slug_path_buffer_len]u8 = undefined;
    for (category_ids) |category_id| {
        const category = (try operations.get_category(db, category_id)) orelse continue;
        const id_key = codec.encodeU64(category.id);

        const slug = category.slug.slice();
        if (slug.len > 0) {
            if (try operations_slug.build_slug_path(db, category.id, &path_buffer)) |full_path| {
                try db.categories_by_slug_path().insert(full_path, &id_key);
                written += 1;

                const depth = slug_path_depth(full_path);
                assert(depth < depth_max);
                try rebuild_category_indices_note_shallowest(db.allocator, &shallowest, slug, .{
                    .depth = depth,
                    .category_id = category.id,
                });
            }
        }

        _ = token_arena.reset(.retain_capacity);
        const tokens = try compute.category_tokens(&category, token_arena.allocator());
        try apply.write_tokens(db.categories_index_tree(), tokens, category.id, .insert);
        written += tokens.len;
    }

    var slug_iterator = shallowest.iterator();
    while (slug_iterator.next()) |entry| {
        const id_key = codec.encodeU64(entry.value_ptr.category_id);
        try db.categories_by_slug_only().insert(entry.key_ptr.*, &id_key);
        written += 1;
    }
    assert(db.categories_by_slug_only().entryCount() == shallowest.count());

    return written;
}

fn rebuild_category_indices_collect_ids(
    db: *Directory,
    category_ids: *std.ArrayListUnmanaged(u64),
) !void {
    assert(category_ids.items.len == 0);
    {
        const min_key = codec.encodeU64(0);
        var iterator = try db.categories_by_id().rangeScan(&min_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.value.len != @sizeOf(schema.Category)) continue;
            const category = std.mem.bytesToValue(
                schema.Category,
                entry.value[0..@sizeOf(schema.Category)],
            );
            try category_ids.append(db.allocator, category.id);
        }
    }
    // The entry count is read from the superblock, so it is disk input and may have drifted
    // from the rows a scan finds; a repair op exists for exactly that store.
    const entry_count = db.categories_by_id().entryCount();
    if (category_ids.items.len != entry_count) {
        log.warn("categories_by_id: scanned {d} categories, its entry count says {d}", .{
            category_ids.items.len,
            entry_count,
        });
    }
}

fn rebuild_category_indices_note_shallowest(
    allocator: std.mem.Allocator,
    shallowest: *std.StringHashMap(ShallowestCategory),
    slug: []const u8,
    candidate: ShallowestCategory,
) !void {
    assert(slug.len > 0);
    assert(candidate.category_id != 0);

    const owned_slug = try allocator.dupe(u8, slug);
    errdefer allocator.free(owned_slug);

    const slot = try shallowest.getOrPut(owned_slug);
    if (!slot.found_existing) {
        slot.value_ptr.* = candidate;
    } else {
        allocator.free(owned_slug);
        if (candidate.depth < slot.value_ptr.depth) slot.value_ptr.* = candidate;
    }
    assert(slot.value_ptr.depth <= candidate.depth);
}

fn rebuild_link_index(db: *Directory) !u64 {
    try db.links_index_tree().truncate(db.allocator);
    assert(db.links_index_tree().entryCount() == 0);

    var token_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer token_arena.deinit();

    var written: u64 = 0;
    const min_key = codec.encodeU64(0);
    var iterator = try db.links_by_id().rangeScan(&min_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        if (entry.value.len != @sizeOf(schema.Link)) continue;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);

        _ = token_arena.reset(.retain_capacity);
        const tokens = try compute.link_tokens(&link, token_arena.allocator());
        try apply.write_tokens(db.links_index_tree(), tokens, link.id, .insert);
        written += tokens.len;
    }

    assert(db.links_index_tree().entryCount() <= written);
    return written;
}

fn drain_repair_queue(db: *Directory) !u64 {
    const start_processed = db.repair_worker_tasks_processed.load(.monotonic);
    const initial_depth = db.slug_path_repair_queue().entryCount();
    const iterations_max: u64 = (initial_depth +| 16) *| 4;

    var iterations: u64 = 0;
    while (db.slug_path_repair_queue().entryCount() > 0) : (iterations += 1) {
        if (iterations >= iterations_max) {
            log.warn(
                "drain bailout after {d} ticks; queue depth still {d}",
                .{ iterations, db.slug_path_repair_queue().entryCount() },
            );
            break;
        }
        try repair_worker.tick_once(db);
    }
    assert(iterations <= iterations_max);

    const end_processed = db.repair_worker_tasks_processed.load(.monotonic);
    assert(end_processed >= start_processed);
    return end_processed - start_processed;
}

// An empty store rebuilds to zero counts without error.
test "rebuild_all_indices: empty DB completes with zeros" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const stats = try rebuild_all_indices(db);
    try std.testing.expectEqual(@as(u64, 0), stats.categories_rebuilt);
    try std.testing.expectEqual(@as(u64, 0), stats.links_rebuilt);
    try std.testing.expectEqual(@as(u64, 0), stats.queue_entries_drained);
}

// Delete the slug-path entry of top/arts behind the store's back; the rebuild must restore
// it from the primary record.
test "rebuild_all_indices: tampered slug-path entry is restored" {
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
    const a_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    try db.drain_all_memtables();

    var value_buffer: [16]u8 = undefined;
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/arts", &value_buffer)) != null,
    );

    _ = try db.categories_by_slug_path().delete("top/arts");
    try std.testing.expect(
        (try db.categories_by_slug_path().search("top/arts", &value_buffer)) == null,
    );

    const stats = try rebuild_all_indices(db);
    try std.testing.expect(stats.categories_rebuilt >= 2);
    try std.testing.expectEqual(@as(u64, 0), stats.queue_entries_drained);

    const found = (try db.categories_by_slug_path().search("top/arts", &value_buffer)).?;
    try std.testing.expectEqual(a_id, std.mem.readInt(u64, found[0..8], .big));
}

// Plant a "programming" posting for a category that does not exist; the rebuild must drop it
// and keep the legitimate posting for the real category.
test "rebuild_all_indices: stale token entry removed and re-added" {
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
    _ = try ops.create_category(
        db,
        top_id,
        .{ .name = "Programming", .slug = "programming", .description = "" },
    );
    try db.drain_all_memtables();

    const stale_token = "programming";
    var stale_key: [stale_token.len + 8]u8 = undefined;
    @memcpy(stale_key[0..stale_token.len], stale_token);
    const stale_category_id = codec.encodeU64(99999);
    @memcpy(stale_key[stale_token.len..][0..8], &stale_category_id);
    try db.categories_index_tree().insert(&stale_key, &.{});

    var value_buffer: [16]u8 = undefined;
    try std.testing.expect(
        (try db.categories_index_tree().search(&stale_key, &value_buffer)) != null,
    );

    _ = try rebuild_all_indices(db);

    try std.testing.expect(
        (try db.categories_index_tree().search(&stale_key, &value_buffer)) == null,
    );
    var prefix_iterator = try db.categories_index_tree().rangeScan(stale_token, null);
    defer prefix_iterator.deinit();
    var found_legitimate = false;
    while (try prefix_iterator.next()) |entry| {
        if (entry.key.len < stale_token.len) break;
        if (!std.mem.eql(u8, entry.key[0..stale_token.len], stale_token)) break;
        found_legitimate = true;
        break;
    }
    try std.testing.expect(found_legitimate);
}

// A rename above the inline threshold leaves a queued task; the rebuild drains it.
test "rebuild_all_indices: drains queued slug-path repair task" {
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
    try db.drain_all_memtables();

    try ops.update_category(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entry_count > 0);

    const stats = try rebuild_all_indices(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
    try std.testing.expect(stats.queue_entries_drained >= 1);
}

// Goal: a rebuild whose derived trees cannot fit in the cache is refused before anything is
// truncated. Method: fill the links index of a 16 MB test store with about 6 MB of 4 KB
// entries, checkpoint so the cache is clean, rebuild, and expect the refusal with every entry
// still in place.
test "rebuild_all_indices: refuses a rebuild larger than the cache and truncates nothing" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const entry_count: u64 = 1500;
    const value: [4096]u8 = @splat(0xA5);
    for (0..entry_count) |index| {
        const key = codec.encodeU64(index);
        try db.links_index_tree().insert(&key, &value);
    }
    _ = try db.checkpoint();
    try std.testing.expectEqual(entry_count, db.links_index_tree().entryCount());

    try std.testing.expectError(RebuildError.RebuildExceedsCache, rebuild_all_indices(db));
    try std.testing.expectEqual(entry_count, db.links_index_tree().entryCount());
    const last_key = codec.encodeU64(entry_count - 1);
    var value_buffer: [4096]u8 = undefined;
    try std.testing.expect((try db.links_index_tree().search(&last_key, &value_buffer)) != null);
}

// Goal: a store whose persisted entry counts drifted from its rows still rebuilds. Method:
// create two categories, lower the categories_by_id entry count below the rows it holds, as the
// shipped 92k store has it, and rebuild.
test "rebuild_all_indices: a drifted categories_by_id entry count does not stop the rebuild" {
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
    const arts_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    try db.drain_all_memtables();
    db.categories_by_id().entry_count = 1;

    const stats = try rebuild_all_indices(db);
    try std.testing.expect(stats.categories_rebuilt >= 2);
    try std.testing.expectEqual(arts_id, (try operations.resolve_slug_path(db, "top/arts")).?);
}

// Goal: a subtree moved below depth_max refuses the rebuild before anything is truncated,
// instead of aborting the process half way. Method: chains of 60 and 10 categories, the second
// re-parented under the end of the first by rewriting its record, as a store written before
// move checked the subtree's height holds it, then rebuild and expect PathTooDeep with the
// slug-path index untouched.
test "rebuild_all_indices: a subtree below depth_max is refused before any truncate" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const deep_end = try create_chain(db, "a", 60);
    const moved_top = try create_chain(db, "b", 10);
    try db.drain_all_memtables();
    var moved = (try operations.get_category(db, moved_top.top)).?;
    moved.parent_id = deep_end.end;
    try db.categories_by_id().insert(&codec.encodeU64(moved.id), std.mem.asBytes(&moved));
    const slug_path_count = db.categories_by_slug_path().entryCount();
    try std.testing.expect(slug_path_count >= 60);

    try std.testing.expectError(
        operations.OperationError.PathTooDeep,
        rebuild_all_indices(db),
    );
    try std.testing.expectEqual(slug_path_count, db.categories_by_slug_path().entryCount());
    try std.testing.expectEqual(deep_end.top, (try operations.resolve_slug_path(db, "a0")).?);
}

// Goal: a slug path longer than the tree can split on refuses the rebuild before anything is
// truncated. Method: a three-level chain whose stored slugs are rewritten to 100 bytes each, as
// a store written before slug paths were capped holds them, then rebuild and expect
// FieldTooLong with the slug-path index untouched.
test "rebuild_all_indices: a slug path over the key maximum is refused before any truncate" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const chain = try create_chain(db, "c", 3);
    try db.drain_all_memtables();
    const slug_path_count = db.categories_by_slug_path().entryCount();
    const long_slug: [100]u8 = @splat('x');
    var category_id = chain.end;
    for (0..3) |_| {
        var category = (try operations.get_category(db, category_id)).?;
        category.slug = .fromSlice(&long_slug);
        const id_key = codec.encodeU64(category_id);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&category));
        category_id = category.parent_id;
    }
    try std.testing.expectEqual(@as(u64, 0), category_id);

    try std.testing.expectError(
        operations.OperationError.FieldTooLong,
        rebuild_all_indices(db),
    );
    try std.testing.expectEqual(slug_path_count, db.categories_by_slug_path().entryCount());
    try std.testing.expectEqual(chain.top, (try operations.resolve_slug_path(db, "c0")).?);
}

const Chain = struct { top: u64, end: u64 };

// Creates `length` nested categories slugged <prefix>0, <prefix>1, ... under the root.
fn create_chain(db: *Directory, prefix: []const u8, length: u32) !Chain {
    assert(length > 0);
    var chain: Chain = .{ .top = 0, .end = 0 };
    for (0..length) |index| {
        var slug_buffer: [16]u8 = undefined;
        const slug = try std.fmt.bufPrint(&slug_buffer, "{s}{d}", .{ prefix, index });
        chain.end = try operations.create_category(
            db,
            chain.end,
            .{ .name = "x", .slug = slug, .description = "" },
        );
        if (index == 0) chain.top = chain.end;
    }
    assert(chain.top != 0);
    return chain;
}
