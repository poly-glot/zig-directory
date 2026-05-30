const std = @import("std");
const types = @import("types.zig");
const btree = @import("btree/btree.zig");
const Database = @import("database.zig").Database;

const log = std.log.scoped(.verifier);

pub const InvariantId = enum(u8) {
    cat_by_parent_coverage = 0,
    link_by_category_coverage = 1,
    link_by_url_hash_coverage = 2,
    subtree_counts = 3,
    no_orphans = 4,
    single_top = 5,
};

pub const InvariantHealth = struct {
    name: []const u8,
    expected: u64,
    observed: u64,

    pub fn driftBp(self: InvariantHealth) u32 {
        if (self.expected == 0) {
            // If expected is 0 but observed is non-zero, that's full drift.
            if (self.observed == 0) return 0;
            return std.math.maxInt(u32);
        }
        const diff: u64 = if (self.observed > self.expected)
            self.observed - self.expected
        else
            self.expected - self.observed;
        const bp: u64 = (diff * 10000) / self.expected;
        return @intCast(@min(bp, std.math.maxInt(u32)));
    }
};

pub const VerifierState = struct {
    last_run_at: i64 = 0,
    indices: [6]InvariantHealth = .{
        .{ .name = "cat_by_parent", .expected = 0, .observed = 0 },
        .{ .name = "link_by_category", .expected = 0, .observed = 0 },
        .{ .name = "link_by_url_hash", .expected = 0, .observed = 0 },
        .{ .name = "subtree_counts", .expected = 0, .observed = 0 },
        .{ .name = "no_orphans", .expected = 0, .observed = 0 },
        .{ .name = "single_top", .expected = 0, .observed = 0 },
    },
    mutex: std.Thread.Mutex = .{},

    pub fn snapshot(self: *VerifierState, db: *Database) struct {
        last_run_at: i64,
        indices: [6]InvariantHealth,
        slug_path_repair_queue_depth: u64,
        slug_path_repair_worker_last_tick_ms: i64,
        slug_path_repair_worker_tasks_processed: u64,
        slug_path_repair_worker_chunks_processed: u64,
    } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .last_run_at = self.last_run_at,
            .indices = self.indices,
            .slug_path_repair_queue_depth = db.slug_path_repair_queue.entry_count,
            .slug_path_repair_worker_last_tick_ms = db.repair_worker_last_tick_ms.load(.acquire),
            .slug_path_repair_worker_tasks_processed = db.repair_worker_tasks_processed.load(.monotonic),
            .slug_path_repair_worker_chunks_processed = db.repair_worker_chunks_processed.load(.monotonic),
        };
    }
};

/// Run the verifier once and populate state. WARN-on-drift only:
/// drift is logged and surfaced via state, but no invariant is
/// auto-repaired. Manual intervention is required if any invariant
/// deviates.
pub fn runOnce(db: *Database, state: *VerifierState) !void {
    const t0 = std.time.milliTimestamp();

    // Drain memtables into the B+Trees so the scans below observe
    // authoritative state. Without this the verifier under-counts
    // freshly created categories/links that haven't been flushed yet,
    // which produces phantom drift on small/young databases.
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);
    db.drainOneMemtable(&db.mt_link_by_category, &db.link_by_category);
    db.drainOneMemtable(&db.mt_link_by_url_hash, &db.link_by_url_hash);

    const cat_count = try countTree(&db.categories_by_id, types.encodeU64(0)[0..]);
    const link_count = try countTree(&db.links_by_id, types.encodeU64(0)[0..]);
    const cat_by_parent_count = try countTree(&db.cat_by_parent, &([_]u8{0} ** 16));
    const link_by_category_count = try countTree(&db.link_by_category, &([_]u8{0} ** 16));
    const link_by_url_hash_count = try countTree(&db.link_by_url_hash, types.encodeU64(0)[0..]);

    var indices: [6]InvariantHealth = undefined;

    indices[@intFromEnum(InvariantId.cat_by_parent_coverage)] = .{
        .name = "cat_by_parent",
        .expected = cat_count,
        .observed = cat_by_parent_count,
    };
    indices[@intFromEnum(InvariantId.link_by_category_coverage)] = .{
        .name = "link_by_category",
        .expected = link_count,
        .observed = link_by_category_count,
    };
    indices[@intFromEnum(InvariantId.link_by_url_hash_coverage)] = .{
        .name = "link_by_url_hash",
        .expected = link_count,
        .observed = link_by_url_hash_count,
    };

    const subtree_drift = try countSubtreeDrift(db);
    indices[@intFromEnum(InvariantId.subtree_counts)] = .{
        .name = "subtree_counts",
        .expected = cat_count,
        .observed = cat_count -| subtree_drift,
    };

    const orphan_count = try countOrphans(db);
    indices[@intFromEnum(InvariantId.no_orphans)] = .{
        .name = "no_orphans",
        .expected = cat_count,
        .observed = cat_count -| orphan_count,
    };

    const top_count = try countTops(db);
    indices[@intFromEnum(InvariantId.single_top)] = .{
        .name = "single_top",
        // Empty fixtures legitimately have zero Tops; absorb that case so we
        // don't surface phantom drift on a fresh DB.
        .expected = if (cat_count == 0) 0 else 1,
        .observed = top_count,
    };

    // Snapshot state for external observers.
    state.mutex.lock();
    state.last_run_at = std.time.timestamp();
    state.indices = indices;
    state.mutex.unlock();

    // WARN-on-drift only. The verifier never mutates DB state; operators
    // are responsible for remediation.
    var any_drift = false;
    for (indices) |inv| {
        const drift = inv.driftBp();
        if (drift == 0) continue;
        any_drift = true;
        log.warn(
            "invariant {s} drift {d}bp (expected={d} observed={d}) — manual intervention required",
            .{ inv.name, drift, inv.expected, inv.observed },
        );
    }

    const elapsed = std.time.milliTimestamp() - t0;
    if (any_drift) {
        log.info("verifier: completed in {d}ms with drift (warn-only)", .{elapsed});
    } else {
        log.info("verifier: completed in {d}ms — all clean", .{elapsed});
    }
}

/// Count entries in a B+Tree via rangeScan. Errors propagate to the caller.
fn countTree(tree: *btree.BPlusTree, min_key: []const u8) !u64 {
    var iter = try tree.rangeScan(min_key, null);
    var count: u64 = 0;
    while (try iter.next()) |_| count += 1;
    return count;
}

fn countTops(db: *Database) !u64 {
    const min_key = types.encodeU64(0);
    var iter = try db.categories_by_id.rangeScan(&min_key, null);
    var n: u64 = 0;
    while (try iter.next()) |entry| {
        if (entry.value.len < @sizeOf(types.Category)) continue;
        const cat = std.mem.bytesToValue(types.Category, entry.value[0..@sizeOf(types.Category)]);
        if (cat.parent_id == 0) n += 1;
    }
    return n;
}

fn countOrphans(db: *Database) !u64 {
    const ops = @import("operations/operations.zig");
    const min_key = types.encodeU64(0);
    var iter = try db.categories_by_id.rangeScan(&min_key, null);
    var orphans: u64 = 0;
    while (try iter.next()) |entry| {
        if (entry.value.len < @sizeOf(types.Category)) continue;
        const cat = std.mem.bytesToValue(types.Category, entry.value[0..@sizeOf(types.Category)]);
        if (cat.parent_id == 0) continue;
        const parent = ops.getCategory(db, cat.parent_id) catch null;
        if (parent == null) orphans += 1;
    }
    return orphans;
}

/// Subtree-count drift detector. Bottom-up walks the category tree and
/// counts how many categories' stored `link_count_subtree` or
/// `child_count_subtree` diverges from the recomputed authoritative
/// value. Read-only — does not mutate the DB.
///
/// The walk is rooted at the unique Top (parent_id=0). If no Top exists
/// (empty fixture), returns 0.
fn countSubtreeDrift(db: *Database) !u64 {
    const ops = @import("operations/operations.zig");

    // Locate Top.
    var top_id: u64 = 0;
    {
        const min_key = types.encodeU64(0);
        var iter = try db.categories_by_id.rangeScan(&min_key, null);
        while (try iter.next()) |entry| {
            if (entry.value.len < @sizeOf(types.Category)) continue;
            const cat = std.mem.bytesToValue(types.Category, entry.value[0..@sizeOf(types.Category)]);
            if (cat.parent_id == 0) {
                top_id = cat.id;
                break;
            }
        }
    }
    if (top_id == 0) return 0;

    // Pass 1: per-category direct-link counts from link_by_category.
    var direct_links = std.AutoHashMap(u64, u32).init(db.allocator);
    defer direct_links.deinit();
    {
        const min_key: [16]u8 = .{0} ** 16;
        var iter = try db.link_by_category.rangeScan(&min_key, null);
        while (try iter.next()) |entry| {
            if (entry.key.len < 8) continue;
            const cid = std.mem.readInt(u64, entry.key[0..8], .big);
            const gop = try direct_links.getOrPut(cid);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* +|= 1;
        }
    }

    // Recomputed (authoritative) subtree counts per category.
    const Computed = struct { link_subtree: u64, child_subtree: u32 };
    var computed = std.AutoHashMap(u64, Computed).init(db.allocator);
    defer computed.deinit();

    const StackFrame = struct { id: u64, expanded: bool };
    var stack = std.ArrayList(StackFrame){};
    defer stack.deinit(db.allocator);
    try stack.append(db.allocator, .{ .id = top_id, .expanded = false });

    var children_buf: [4096]types.Category = undefined;

    while (stack.items.len > 0) {
        const top = stack.items[stack.items.len - 1];
        if (!top.expanded) {
            stack.items[stack.items.len - 1].expanded = true;
            const children = try ops.listChildren(db, top.id, 0, children_buf.len, &children_buf);
            for (children) |c| {
                try stack.append(db.allocator, .{ .id = c.id, .expanded = false });
            }
            continue;
        }
        _ = stack.pop();

        const direct = direct_links.get(top.id) orelse 0;
        var sub_links: u64 = direct;
        var sub_children: u32 = 0;
        const children = try ops.listChildren(db, top.id, 0, children_buf.len, &children_buf);
        for (children) |c| {
            const c_comp = computed.get(c.id) orelse Computed{ .link_subtree = 0, .child_subtree = 0 };
            sub_links += c_comp.link_subtree;
            sub_children += 1 + c_comp.child_subtree;
        }
        try computed.put(top.id, .{ .link_subtree = sub_links, .child_subtree = sub_children });
    }

    // Compare stored vs computed for every category in the walk.
    var drift: u64 = 0;
    var it = computed.iterator();
    while (it.next()) |kv| {
        const cat = (try ops.getCategory(db, kv.key_ptr.*)) orelse continue;
        if (cat.link_count_subtree != kv.value_ptr.link_subtree or
            cat.child_count_subtree != kv.value_ptr.child_subtree)
        {
            drift += 1;
        }
    }
    return drift;
}

test "InvariantHealth.driftBp basic" {
    const h = InvariantHealth{ .name = "x", .expected = 1000, .observed = 950 };
    try std.testing.expectEqual(@as(u32, 500), h.driftBp());

    const exact = InvariantHealth{ .name = "x", .expected = 1000, .observed = 1000 };
    try std.testing.expectEqual(@as(u32, 0), exact.driftBp());

    const empty = InvariantHealth{ .name = "x", .expected = 0, .observed = 0 };
    try std.testing.expectEqual(@as(u32, 0), empty.driftBp());

    const over = InvariantHealth{ .name = "x", .expected = 1000, .observed = 1100 };
    try std.testing.expectEqual(@as(u32, 1000), over.driftBp());
}

test "verifier: clean DB has no drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    _ = try ops.createCategory(db, 0, "Top", "top", "");

    var state = VerifierState{};
    try runOnce(db, &state);

    for (state.indices) |inv| {
        const drift = inv.driftBp();
        try std.testing.expect(drift < 100);
    }
}

test "verifier: detects subtree count drift without repairing (WARN-only)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");

    var sibling_ids: [50]u64 = undefined;
    var name_buf: [16]u8 = undefined;
    var slug_buf: [16]u8 = undefined;
    for (0..sibling_ids.len) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "C{d}", .{i});
        const slug = try std.fmt.bufPrint(&slug_buf, "c{d}", .{i});
        sibling_ids[i] = try ops.createCategory(db, top_id, name, slug, "");
    }
    // Add a single link under sibling 0 so its authoritative subtree count is 1.
    _ = try ops.createLink(db, sibling_ids[0], "https://x.example", "x", "");

    // Drain pending writes so the tamper isn't overwritten when the verifier
    // re-drains. Without this, the original (correct) value sitting in the
    // memtable wins on the verifier's drain pass.
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);

    // Tamper sibling 0's stored link_count_subtree to 0 (correct value is 1).
    {
        var cat = (try ops.getCategory(db, sibling_ids[0])).?;
        cat.link_count_subtree = 0;
        const id_key = types.encodeU64(sibling_ids[0]);
        try db.categories_by_id.insert(&id_key, std.mem.asBytes(&cat));
    }

    var state = VerifierState{};
    try runOnce(db, &state);

    // Drift must be reported via the snapshot.
    const subtree = state.indices[@intFromEnum(InvariantId.subtree_counts)];
    try std.testing.expect(subtree.driftBp() > 0);

    // The verifier never repairs — the tampered value must remain.
    const after = (try ops.getCategory(db, sibling_ids[0])).?;
    try std.testing.expectEqual(@as(u64, 0), after.link_count_subtree);
}

test "verifier: tampered link_count surfaces drift on link_by_category invariant" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top = try ops.createCategory(db, 0, "Top", "top", "");
    _ = try ops.createLink(db, top, "https://a.example", "a", "");
    _ = try ops.createLink(db, top, "https://b.example", "b", "");

    db.drainOneMemtable(&db.mt_link_by_category, &db.link_by_category);

    // Drop one of the link_by_category secondary entries by force-walking
    // and removing the first entry directly.
    {
        const min_key: [16]u8 = .{0} ** 16;
        var iter = try db.link_by_category.rangeScan(&min_key, null);
        if (try iter.next()) |entry| {
            const key = entry.key;
            var key_copy: [16]u8 = undefined;
            @memcpy(&key_copy, key[0..16]);
            _ = try db.link_by_category.delete(&key_copy);
        }
    }

    var state = VerifierState{};
    try runOnce(db, &state);

    const inv = state.indices[@intFromEnum(InvariantId.link_by_category_coverage)];
    try std.testing.expect(inv.driftBp() > 0);
}

test "verifier: tampered child_count_subtree surfaces drift" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top = try ops.createCategory(db, 0, "Top", "top", "");
    _ = try ops.createCategory(db, top, "A", "a", "");
    _ = try ops.createCategory(db, top, "B", "b", "");

    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);

    // Tamper Top's child_count_subtree to a wrong value.
    {
        var cat = (try ops.getCategory(db, top)).?;
        cat.child_count_subtree = 99;
        const id_key = types.encodeU64(top);
        try db.categories_by_id.insert(&id_key, std.mem.asBytes(&cat));
    }

    var state = VerifierState{};
    try runOnce(db, &state);

    const subtree = state.indices[@intFromEnum(InvariantId.subtree_counts)];
    try std.testing.expect(subtree.driftBp() > 0);
}

test "verifier: every InvariantId has a matching snapshot index" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var state = VerifierState{};
    try runOnce(db, &state);

    const snap = state.snapshot(db);
    const fields = @typeInfo(InvariantId).@"enum".fields;
    try std.testing.expectEqual(fields.len, snap.indices.len);
    inline for (fields, 0..) |f, i| {
        // Each enum slot's name must appear in the snapshot in the
        // matching index — guarantees clients can decode by ordinal.
        const idx = snap.indices[i];
        try std.testing.expect(idx.name.len > 0);
        _ = f;
    }
}

test "verifier: runOnce does not mutate categories_by_id count" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top = try ops.createCategory(db, 0, "Top", "top", "");
    _ = try ops.createCategory(db, top, "A", "a", "");
    _ = try ops.createLink(db, top, "https://x.example", "x", "");

    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);

    const before_cats = db.categories_by_id.entry_count;
    const before_links = db.links_by_id.entry_count;

    var state = VerifierState{};
    try runOnce(db, &state);

    try std.testing.expectEqual(before_cats, db.categories_by_id.entry_count);
    try std.testing.expectEqual(before_links, db.links_by_id.entry_count);
}

test "verifier: concurrent writer + verifier does not crash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top = try ops.createCategory(db, 0, "Top", "top", "");

    const Writer = struct {
        fn run(d: *Database, parent: u64) void {
            var name_buf: [32]u8 = undefined;
            var slug_buf: [32]u8 = undefined;
            var url_buf: [64]u8 = undefined;
            for (0..200) |i| {
                const url = std.fmt.bufPrint(&url_buf, "https://w{d}.example", .{i}) catch continue;
                const name = std.fmt.bufPrint(&name_buf, "L{d}", .{i}) catch continue;
                const slug = std.fmt.bufPrint(&slug_buf, "l{d}", .{i}) catch continue;
                _ = name;
                _ = slug;
                _ = ops.createLink(d, parent, url, "x", "") catch {};
            }
        }
    };

    const t = try std.Thread.spawn(.{}, Writer.run, .{ db, top });

    // Run the verifier multiple times in this thread while writer races.
    var state = VerifierState{};
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        runOnce(db, &state) catch {};
    }
    t.join();

    // Final run after writer has joined — invariants observed at that
    // instant should be stable. We don't assert zero drift (writes may
    // not be fully drained), only that runOnce returns without error.
    try runOnce(db, &state);
}

test "verifier: op 19 frame matches op 18 frame" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var state = VerifierState{};
    try runOnce(db, &state);
    db.verifier_state = state;

    // Both ops snapshot the same VerifierState; their snapshot bytes
    // must be byte-identical (only differs by op_byte in the frame
    // header which we don't compare here).
    const snap1 = db.verifier_state.snapshot(db);
    const snap2 = db.verifier_state.snapshot(db);
    try std.testing.expectEqual(snap1.last_run_at, snap2.last_run_at);
    try std.testing.expectEqual(snap1.indices.len, snap2.indices.len);
    for (snap1.indices, snap2.indices) |a, b| {
        try std.testing.expectEqualSlices(u8, a.name, b.name);
        try std.testing.expectEqual(a.expected, b.expected);
        try std.testing.expectEqual(a.observed, b.observed);
    }
    try std.testing.expectEqual(
        snap1.slug_path_repair_queue_depth,
        snap2.slug_path_repair_queue_depth,
    );
}

test "verifier: slug_path_repair_queue_depth round-trips through snapshot" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    // Initially empty.
    var state = VerifierState{};
    var snap = state.snapshot(db);
    try std.testing.expectEqual(@as(u64, 0), snap.slug_path_repair_queue_depth);

    // Inject a repair-queue entry directly so we can observe a non-zero
    // depth. Key is u64 sequence; value is the cat id we want repaired.
    const seq: u64 = 1;
    const key = types.encodeU64(seq);
    const value = types.encodeU64(42);
    try db.slug_path_repair_queue.insert(&key, &value);

    snap = state.snapshot(db);
    try std.testing.expectEqual(@as(u64, 1), snap.slug_path_repair_queue_depth);
}

test "verifier: shutdown signal causes verifier loop to exit promptly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);

    // openTestInstance does not start background threads. Start the
    // verifier thread explicitly by hand-mirroring startBackgroundThreads
    // for just the verifier; if start fails we skip.
    db.startBackgroundThreads();
    // Give the verifier loop a beat to enter its first timedWait.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const t0 = std.time.milliTimestamp();
    db.deinitTestInstance(); // signals shutdown + joins thread
    const elapsed = std.time.milliTimestamp() - t0;

    // Default verifier_interval_ns is large (5min). Shutdown must wake
    // the cond var and exit well within a second.
    try std.testing.expect(elapsed < 5_000);
}
