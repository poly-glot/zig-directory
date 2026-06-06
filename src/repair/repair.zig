const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Database = @import("../database.zig").Database;
const operations_slug = @import("../operations/operations_slug.zig");
const inverted = @import("../inverted_index.zig");
const repair_worker = @import("repair_worker.zig");

const log = std.log.scoped(.repair);

pub const RebuildStats = struct {
    categories_rebuilt: u64,
    links_rebuilt: u64,
    queue_entries_drained: u64,
};

pub fn rebuildAllIndices(db: *Database) !RebuildStats {
    const t0 = std.time.milliTimestamp();

    var stats = RebuildStats{
        .categories_rebuilt = 0,
        .links_rebuilt = 0,
        .queue_entries_drained = 0,
    };

    {
        db.apply_mutex.lock();
        defer db.apply_mutex.unlock();

        db.drainAllMemtables();

        stats.categories_rebuilt = try rebuildCategoryIndices(db);

        stats.links_rebuilt = try rebuildLinkIndex(db);
    }

    stats.queue_entries_drained = try drainRepairQueue(db);

    log.info(
        "rebuild_index: cats={d} links={d} drained={d} in {d}ms",
        .{ stats.categories_rebuilt, stats.links_rebuilt, stats.queue_entries_drained, std.time.milliTimestamp() - t0 },
    );
    return stats;
}

fn rebuildCategoryIndices(db: *Database) !u64 {
    try db.categories_by_slug_path.truncate(db.allocator);
    try db.categories_by_slug_only.truncate(db.allocator);
    try db.categories_index_tree.truncate(db.allocator);

    const SlugBest = struct { depth: u32, cat_id: u64 };
    var slug_best = std.StringHashMap(SlugBest).init(db.allocator);
    defer {
        var it = slug_best.iterator();
        while (it.next()) |kv| db.allocator.free(kv.key_ptr.*);
        slug_best.deinit();
    }

    var written: u64 = 0;

    const min_key = codec.encodeU64(0);
    var iter = try db.categories_by_id.rangeScan(&min_key, null);
    var path_buf: [2048]u8 = undefined;
    var key_buf: [4096]u8 = undefined;
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;

    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(schema.Category)) continue;
        const cat = std.mem.bytesToValue(schema.Category, entry.value[0..@sizeOf(schema.Category)]);
        const id_key = codec.encodeU64(cat.id);

        const slug = cat.slug.slice();
        if (slug.len > 0) {
            if (try operations_slug.buildCanonicalSlugPath(db, &cat, &path_buf)) |full_path| {
                try db.categories_by_slug_path.insert(full_path, &id_key);
                written += 1;

                var depth: u32 = 0;
                for (full_path) |c| {
                    if (c == '/') depth += 1;
                }
                const owned_slug = try db.allocator.dupe(u8, slug);
                const gop = try slug_best.getOrPut(owned_slug);
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{ .depth = depth, .cat_id = cat.id };
                } else {
                    db.allocator.free(owned_slug);
                    if (depth < gop.value_ptr.depth) {
                        gop.value_ptr.* = .{ .depth = depth, .cat_id = cat.id };
                    }
                }
            }
        }

        const fields = [_][]const u8{
            cat.name.slice(),
            cat.slug.slice(),
            cat.description.slice(),
        };
        for (fields) |field| {
            var token_iter = inverted.TokenIterator.init(field);
            while (token_iter.next(&tok_buf)) |tok| {
                if (tok.len == 0 or tok.len + 8 > key_buf.len) continue;
                @memcpy(key_buf[0..tok.len], tok);
                @memcpy(key_buf[tok.len..][0..8], &id_key);
                try db.categories_index_tree.insert(key_buf[0 .. tok.len + 8], &.{});
                written += 1;
            }
        }
    }

    var sit = slug_best.iterator();
    while (sit.next()) |kv| {
        const id_key = codec.encodeU64(kv.value_ptr.cat_id);
        try db.categories_by_slug_only.insert(kv.key_ptr.*, &id_key);
        written += 1;
    }

    return written;
}

fn rebuildLinkIndex(db: *Database) !u64 {
    try db.links_index_tree.truncate(db.allocator);

    var written: u64 = 0;

    const min_key = codec.encodeU64(0);
    var iter = try db.links_by_id.rangeScan(&min_key, null);
    var key_buf: [4096]u8 = undefined;
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;

    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(schema.Link)) continue;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        const id_key = codec.encodeU64(link.id);

        const fields = [_][]const u8{
            link.title.slice(),
            link.url.slice(),
            link.description.slice(),
        };
        for (fields) |field| {
            var token_iter = inverted.TokenIterator.init(field);
            while (token_iter.next(&tok_buf)) |tok| {
                if (tok.len == 0 or tok.len + 8 > key_buf.len) continue;
                @memcpy(key_buf[0..tok.len], tok);
                @memcpy(key_buf[tok.len..][0..8], &id_key);
                try db.links_index_tree.insert(key_buf[0 .. tok.len + 8], &.{});
                written += 1;
            }
        }
    }

    return written;
}

fn drainRepairQueue(db: *Database) !u64 {
    const start_processed = db.repair_worker_tasks_processed.load(.monotonic);
    const initial_depth = db.slug_path_repair_queue.entryCount();
    const max_iters: u64 = (initial_depth +| 16) *| 4;

    var iters: u64 = 0;
    while (db.slug_path_repair_queue.entryCount() > 0) : (iters += 1) {
        if (iters >= max_iters) {
            log.warn(
                "drain bailout after {d} ticks; queue depth still {d}",
                .{ iters, db.slug_path_repair_queue.entryCount() },
            );
            break;
        }
        try repair_worker.tickOnce(db);
    }

    const end_processed = db.repair_worker_tasks_processed.load(.monotonic);
    return end_processed - start_processed;
}

test "rebuildAllIndices: empty DB completes with zeros" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const stats = try rebuildAllIndices(db);
    try std.testing.expectEqual(@as(u64, 0), stats.categories_rebuilt);
    try std.testing.expectEqual(@as(u64, 0), stats.links_rebuilt);
    try std.testing.expectEqual(@as(u64, 0), stats.queue_entries_drained);
}

test "rebuildAllIndices: tampered slug-path entry is restored" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "Arts", "arts", "");
    db.drainAllMemtables();

    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_by_slug_path.search("top/arts", &v_buf)) != null);

    _ = try db.categories_by_slug_path.delete("top/arts");
    try std.testing.expect((try db.categories_by_slug_path.search("top/arts", &v_buf)) == null);

    const stats = try rebuildAllIndices(db);
    try std.testing.expect(stats.categories_rebuilt >= 2);
    try std.testing.expectEqual(@as(u64, 0), stats.queue_entries_drained);

    const found = (try db.categories_by_slug_path.search("top/arts", &v_buf)).?;
    try std.testing.expectEqual(a_id, std.mem.readInt(u64, found[0..8], .big));
}

test "rebuildAllIndices: stale token entry removed and re-added" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("../operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    _ = try ops.createCategory(db, top_id, "Programming", "programming", "");
    db.drainAllMemtables();

    const stale_tok = "programming";
    var stale_key: [stale_tok.len + 8]u8 = undefined;
    @memcpy(stale_key[0..stale_tok.len], stale_tok);
    const stale_cat_id = codec.encodeU64(99999);
    @memcpy(stale_key[stale_tok.len..][0..8], &stale_cat_id);
    try db.categories_index_tree.insert(&stale_key, &.{});

    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_index_tree.search(&stale_key, &v_buf)) != null);

    _ = try rebuildAllIndices(db);

    try std.testing.expect((try db.categories_index_tree.search(&stale_key, &v_buf)) == null);
    var prefix_iter = try db.categories_index_tree.rangeScan(stale_tok, null);
    var found_legit = false;
    while (try prefix_iter.next()) |e| {
        if (e.key.len < stale_tok.len) break;
        if (!std.mem.eql(u8, e.key[0..stale_tok.len], stale_tok)) break;
        found_legit = true;
        break;
    }
    try std.testing.expect(found_legit);
}

test "rebuildAllIndices: drains queued slug-path repair task" {
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
    db.drainAllMemtables();

    try ops.updateCategory(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue.entry_count > 0);

    const stats = try rebuildAllIndices(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
    try std.testing.expect(stats.queue_entries_drained >= 1);
}
