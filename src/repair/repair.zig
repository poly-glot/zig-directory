//! Rebuilds every derived index (slug paths, slug-only shortcuts, token postings) from the
//! primary category and link records, then drains the slug-path repair queue: the admin op
//! for an index that has drifted from its source of truth.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const operations = @import("../operations/operations.zig");
const operations_slug = @import("../operations/operations_slug.zig");
const compute = @import("../operations/operations_changeset_compute.zig");
const depth_max = @import("../operations/operations_shared.zig").depth_max;
const apply = @import("../apply/apply.zig");
const repair_worker = @import("repair_worker.zig");

const log = std.log.scoped(.repair);

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

        stats.categories_rebuilt = try rebuild_category_indices(db);
        assert(db.categories_by_slug_path().entryCount() <= db.categories_by_id().entryCount());
        assert(
            db.categories_by_slug_only().entryCount() <= db.categories_by_slug_path().entryCount(),
        );

        stats.links_rebuilt = try rebuild_link_index(db);
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

// The slug-only index maps a slug to the shallowest category carrying it, so a rebuild keeps
// the best candidate per slug and writes the index in one pass at the end.
const ShallowestCategory = struct { depth: u32, category_id: u64 };

fn rebuild_category_indices(db: *Directory) !u64 {
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

    var category_ids: std.ArrayListUnmanaged(u64) = .empty;
    defer category_ids.deinit(db.allocator);
    try rebuild_category_indices_collect_ids(db, &category_ids);

    var token_arena = std.heap.ArenaAllocator.init(db.allocator);
    defer token_arena.deinit();

    var written: u64 = 0;
    var path_buffer: [repair_worker.slug_path_len_max]u8 = undefined;
    for (category_ids.items) |category_id| {
        const category = (try operations.get_category(db, category_id)) orelse continue;
        const id_key = codec.encodeU64(category.id);

        const slug = category.slug.slice();
        if (slug.len > 0) {
            if (try operations_slug.build_slug_path(db, category.id, &path_buffer)) |full_path| {
                try db.categories_by_slug_path().insert(full_path, &id_key);
                written += 1;

                const depth: u32 = @intCast(std.mem.count(u8, full_path, "/"));
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
    assert(category_ids.items.len <= db.categories_by_id().entryCount());
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
