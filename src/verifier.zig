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
    any_drift: bool = false,
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
            .slug_path_repair_queue_depth = db.slug_path_repair_queue.entryCount(),
            .slug_path_repair_worker_last_tick_ms = db.repair_worker_last_tick_ms.load(.acquire),
            .slug_path_repair_worker_tasks_processed = db.repair_worker_tasks_processed.load(.monotonic),
            .slug_path_repair_worker_chunks_processed = db.repair_worker_chunks_processed.load(.monotonic),
        };
    }
};

pub fn runOnce(db: *Database, state: *VerifierState) !void {
    const t0 = std.time.milliTimestamp();

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
        .expected = if (cat_count == 0) 0 else 1,
        .observed = top_count,
    };

    state.mutex.lock();
    state.last_run_at = std.time.timestamp();
    state.indices = indices;
    state.mutex.unlock();

    var any_drift = false;

    {
        const slug_path_count = try countTree(&db.categories_by_slug_path, "");
        if (slug_path_count != cat_count) {
            any_drift = true;
            log.warn(
                "invariant categories_by_slug_path coverage (expected={d} observed={d}) — manual intervention required",
                .{ cat_count, slug_path_count },
            );
        }
        if (cat_count > 0 and !(try treeNonEmpty(&db.categories_index_tree, ""))) {
            any_drift = true;
            log.warn("invariant categories_index empty while {d} categories exist — rebuild required", .{cat_count});
        }
        if (link_count > 0 and !(try treeNonEmpty(&db.links_index_tree, ""))) {
            any_drift = true;
            log.warn("invariant links_index empty while {d} links exist — rebuild required", .{link_count});
        }
    }

    for (indices) |inv| {
        const drift = inv.driftBp();
        if (drift == 0) continue;
        any_drift = true;
        log.warn(
            "invariant {s} drift {d}bp (expected={d} observed={d}) — manual intervention required",
            .{ inv.name, drift, inv.expected, inv.observed },
        );
    }

    state.mutex.lock();
    state.any_drift = any_drift;
    state.mutex.unlock();

    const elapsed = std.time.milliTimestamp() - t0;
    if (any_drift) {
        log.info("verifier: completed in {d}ms with drift (warn-only)", .{elapsed});
    } else {
        log.info("verifier: completed in {d}ms — all clean", .{elapsed});
    }
}

fn countTree(tree: *btree.BPlusTree, min_key: []const u8) !u64 {
    var iter = try tree.rangeScan(min_key, null);
    var count: u64 = 0;
    while (try iter.next()) |_| count += 1;
    return count;
}

fn treeNonEmpty(tree: *btree.BPlusTree, min_key: []const u8) !bool {
    var iter = try tree.rangeScan(min_key, null);
    return (try iter.next()) != null;
}

fn collectAllChildIds(db: *Database, parent_id: u64) ![]u64 {
    const ops = @import("operations/operations.zig");
    var ids: std.ArrayListUnmanaged(u64) = .{};
    errdefer ids.deinit(db.allocator);
    var buf: [4096]types.Category = undefined;
    var offset: u32 = 0;
    while (true) {
        const children = try ops.listChildren(db, parent_id, offset, buf.len, &buf);
        for (children) |c| try ids.append(db.allocator, c.id);
        if (children.len < buf.len) break;
        offset +|= @intCast(children.len);
    }
    return ids.toOwnedSlice(db.allocator);
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

fn countSubtreeDrift(db: *Database) !u64 {
    const ops = @import("operations/operations.zig");

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

    const Computed = struct { link_subtree: u64, child_subtree: u32 };
    var computed = std.AutoHashMap(u64, Computed).init(db.allocator);
    defer computed.deinit();

    const StackFrame = struct { id: u64, expanded: bool };
    var stack = std.ArrayList(StackFrame){};
    defer stack.deinit(db.allocator);
    try stack.append(db.allocator, .{ .id = top_id, .expanded = false });

    while (stack.items.len > 0) {
        const top = stack.items[stack.items.len - 1];
        if (!top.expanded) {
            stack.items[stack.items.len - 1].expanded = true;
            const child_ids = try collectAllChildIds(db, top.id);
            defer db.allocator.free(child_ids);
            for (child_ids) |cid| {
                try stack.append(db.allocator, .{ .id = cid, .expanded = false });
            }
            continue;
        }
        _ = stack.pop();

        const direct = direct_links.get(top.id) orelse 0;
        var sub_links: u64 = direct;
        var sub_children: u32 = 0;
        const child_ids = try collectAllChildIds(db, top.id);
        defer db.allocator.free(child_ids);
        for (child_ids) |cid| {
            const c_comp = computed.get(cid) orelse Computed{ .link_subtree = 0, .child_subtree = 0 };
            sub_links += c_comp.link_subtree;
            sub_children += 1 + c_comp.child_subtree;
        }
        try computed.put(top.id, .{ .link_subtree = sub_links, .child_subtree = sub_children });
    }

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
    _ = try ops.createLink(db, sibling_ids[0], "https://x.example", "x", "");

    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);

    {
        var cat = (try ops.getCategory(db, sibling_ids[0])).?;
        cat.link_count_subtree = 0;
        const id_key = types.encodeU64(sibling_ids[0]);
        try db.categories_by_id.insert(&id_key, std.mem.asBytes(&cat));
    }

    var state = VerifierState{};
    try runOnce(db, &state);

    const subtree = state.indices[@intFromEnum(InvariantId.subtree_counts)];
    try std.testing.expect(subtree.driftBp() > 0);

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

    var state = VerifierState{};
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        runOnce(db, &state) catch {};
    }
    t.join();

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

    var state = VerifierState{};
    var snap = state.snapshot(db);
    try std.testing.expectEqual(@as(u64, 0), snap.slug_path_repair_queue_depth);

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

    db.startBackgroundThreads();
    std.Thread.sleep(10 * std.time.ns_per_ms);

    const t0 = std.time.milliTimestamp();
    db.deinitTestInstance();
    const elapsed = std.time.milliTimestamp() - t0;

    try std.testing.expect(elapsed < 5_000);
}

test "H14: verifier flags slug-path coverage divergence" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top = try ops.createCategory(db, 0, "Top", "top", "");
    _ = try ops.createCategory(db, top, "Child", "child", "");

    var state = VerifierState{};
    try runOnce(db, &state);
    try std.testing.expect(!state.any_drift);

    _ = try db.categories_by_slug_path.delete("top/child");

    try runOnce(db, &state);
    try std.testing.expect(state.any_drift);
}
