//! Synchronous full rebuild of the four secondary indexing B+Trees and
//! drain of the slug-path repair queue. Implements the body of
//! `op=20 rebuild_index` (Slice 5a of the operations-surface uplift).
//!
//! Authoritative sources:
//!   - `categories_by_id` → `categories_by_slug_path`,
//!                          `categories_by_slug_only`,
//!                          `categories_index_tree`
//!   - `links_by_id`      → `links_index_tree`
//!
//! Concurrency: `rebuildAllIndices` acquires `db.apply_mutex` for the
//! full rebuild, blocking every writer until it returns. Acceptable for
//! an admin-triggered op; on a multi-100k-row DB this can take seconds.
//!
//! Counts in `RebuildStats` are the number of (key, value) entries
//! written into each tree, NOT the number of source rows walked. A row
//! with no slug or no tokens contributes nothing.

const std = @import("std");
const types = @import("../types.zig");
const Database = @import("../database.zig").Database;
const operations_slug = @import("../operations/operations_slug.zig");
const inverted = @import("../inverted_index.zig");
const repair_worker = @import("repair_worker.zig");

const log = std.log.scoped(.repair);

pub const RebuildStats = struct {
    /// Entries written into `categories_by_slug_path` +
    /// `categories_by_slug_only` + `categories_index_tree`.
    categories_rebuilt: u64,
    /// Entries written into `links_index_tree`.
    links_rebuilt: u64,
    /// Slug-path repair queue tasks processed during the drain phase.
    queue_entries_drained: u64,
};

/// Truncate then repopulate every secondary indexing tree from the
/// authoritative primary trees, then drain the slug-path repair queue.
///
/// Lock discipline: holds `db.apply_mutex` for the truncate+rebuild
/// phase only — every commit's apply is blocked while indexing trees
/// are in their transient (truncated) state. (WAL appends from peer
/// commits may still proceed; their apply will run after the rebuild
/// releases the mutex, against the rebuilt trees.) The queue-drain
/// phase runs after we release the mutex because each drained task
/// issues its own `db.commit` which itself acquires `apply_mutex`;
/// holding the mutex across the drain would self-deadlock.
///
/// Drain ordering rationale: the rebuild has already written canonical
/// slug-paths, so any in-flight rename swap the worker emits will hit
/// the "target already matches" idempotency gate in `processChunk` and
/// no-op. The drain is therefore mostly a queue-bookkeeping pass that
/// removes the now-redundant queue entries.
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

        // Make sure the primary trees see every recently-committed write
        // before we walk them; otherwise the rebuild would miss whatever
        // is still sitting in a memtable buffer.
        db.drainAllMemtables();

        stats.categories_rebuilt = try rebuildCategoryIndices(db);

        stats.links_rebuilt = try rebuildLinkIndex(db);
    }

    // Mutex released — each drained task takes apply_mutex itself.
    stats.queue_entries_drained = try drainRepairQueue(db);

    log.info(
        "rebuild_index: cats={d} links={d} drained={d} in {d}ms",
        .{ stats.categories_rebuilt, stats.links_rebuilt, stats.queue_entries_drained, std.time.milliTimestamp() - t0 },
    );
    return stats;
}

/// Walk `categories_by_id` once, truncating and repopulating the three
/// category-side indexing trees. Returns the total number of entries
/// written across all three trees.
fn rebuildCategoryIndices(db: *Database) !u64 {
    try db.categories_by_slug_path.truncate(db.allocator);
    try db.categories_by_slug_only.truncate(db.allocator);
    try db.categories_index_tree.truncate(db.allocator);

    // For slug_only we keep the shallowest-depth holder for each leaf
    // slug. Same algorithm as migration phase 9.
    const SlugBest = struct { depth: u32, cat_id: u64 };
    var slug_best = std.StringHashMap(SlugBest).init(db.allocator);
    defer {
        var it = slug_best.iterator();
        while (it.next()) |kv| db.allocator.free(kv.key_ptr.*);
        slug_best.deinit();
    }

    var written: u64 = 0;

    const min_key = types.encodeU64(0);
    var iter = try db.categories_by_id.rangeScan(&min_key, null);
    var path_buf: [2048]u8 = undefined;
    var key_buf: [4096]u8 = undefined;
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;

    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(types.Category)) continue;
        const cat = std.mem.bytesToValue(types.Category, entry.value[0..@sizeOf(types.Category)]);
        const id_key = types.encodeU64(cat.id);

        // 1. Slug path — only categories with a slug participate.
        const slug = cat.slug.slice();
        if (slug.len > 0) {
            if (try operations_slug.buildCanonicalSlugPath(db, &cat, &path_buf)) |full_path| {
                try db.categories_by_slug_path.insert(full_path, &id_key);
                written += 1;

                // 2. Slug-only — track shallowest-depth holder.
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

        // 3. Token index — name+slug+description.
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
                db.categories_index_tree.insert(key_buf[0 .. tok.len + 8], &.{}) catch continue;
                written += 1;
            }
        }
    }

    // Flush slug_only entries.
    var sit = slug_best.iterator();
    while (sit.next()) |kv| {
        const id_key = types.encodeU64(kv.value_ptr.cat_id);
        try db.categories_by_slug_only.insert(kv.key_ptr.*, &id_key);
        written += 1;
    }

    return written;
}

/// Walk `links_by_id` once, truncate `links_index_tree`, and reinsert
/// every (token‖link_id_be) entry. Returns the number of entries
/// written.
fn rebuildLinkIndex(db: *Database) !u64 {
    try db.links_index_tree.truncate(db.allocator);

    var written: u64 = 0;

    const min_key = types.encodeU64(0);
    var iter = try db.links_by_id.rangeScan(&min_key, null);
    var key_buf: [4096]u8 = undefined;
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;

    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(types.Link)) continue;
        const link = std.mem.bytesToValue(types.Link, entry.value[0..@sizeOf(types.Link)]);
        const id_key = types.encodeU64(link.id);

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
                db.links_index_tree.insert(key_buf[0 .. tok.len + 8], &.{}) catch continue;
                written += 1;
            }
        }
    }

    return written;
}

/// Synchronously drain every queued slug-path repair task. We loop on
/// `tickOnce` (which respects the configured per-tick cap) until the
/// queue is empty. Returns the number of tasks processed.
fn drainRepairQueue(db: *Database) !u64 {
    const start_processed = db.repair_worker_tasks_processed.load(.monotonic);
    // Safety bound: if a task somehow fails to remove its queue entry
    // we'd loop forever. Cap at the queue depth at entry plus a
    // generous slack for the (rare) re-enqueue case.
    const initial_depth = db.slug_path_repair_queue.entry_count;
    const max_iters: u64 = (initial_depth +| 16) *| 4;

    var iters: u64 = 0;
    while (db.slug_path_repair_queue.entry_count > 0) : (iters += 1) {
        if (iters >= max_iters) {
            log.warn(
                "drain bailout after {d} ticks; queue depth still {d}",
                .{ iters, db.slug_path_repair_queue.entry_count },
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

    // Sanity: canonical entry exists.
    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_by_slug_path.search("top/arts", &v_buf)) != null);

    // Tamper: blow away the canonical entry.
    _ = try db.categories_by_slug_path.delete("top/arts");
    try std.testing.expect((try db.categories_by_slug_path.search("top/arts", &v_buf)) == null);

    const stats = try rebuildAllIndices(db);
    // 2 cats × (1 slug_path + tokens) + 2 slug_only entries → at minimum 2 path
    // entries reinstated.
    try std.testing.expect(stats.categories_rebuilt >= 2);
    try std.testing.expectEqual(@as(u64, 0), stats.queue_entries_drained);

    // Restored.
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

    // Plant a stale token entry that points at a nonexistent cat id.
    // Rebuild MUST drop it (truncate-and-repopulate semantics).
    const stale_tok = "programming";
    var stale_key: [stale_tok.len + 8]u8 = undefined;
    @memcpy(stale_key[0..stale_tok.len], stale_tok);
    const stale_cat_id = types.encodeU64(99999);
    @memcpy(stale_key[stale_tok.len..][0..8], &stale_cat_id);
    try db.categories_index_tree.insert(&stale_key, &.{});

    var v_buf: [16]u8 = undefined;
    try std.testing.expect((try db.categories_index_tree.search(&stale_key, &v_buf)) != null);

    _ = try rebuildAllIndices(db);

    // Stale entry gone.
    try std.testing.expect((try db.categories_index_tree.search(&stale_key, &v_buf)) == null);
    // The legit "programming" token for the real cat is still searchable
    // (any (programming, real_cat_id) entry → range scan over the prefix
    // returns at least one hit).
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

    // Trigger an above-threshold rename so the queue gets a task.
    try ops.updateCategory(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue.entry_count > 0);

    const stats = try rebuildAllIndices(db);

    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
    try std.testing.expect(stats.queue_entries_drained >= 1);
}
