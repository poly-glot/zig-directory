//! The verifier audits the derived indexes on a fixed interval: it counts what each secondary
//! index should hold against what it does hold and publishes the drift as health numbers. It
//! only reports; repair stays a separate, explicit operation, so a verifier bug cannot corrupt
//! data.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("schema.zig");
const btree = @import("zigstore");
const Directory = @import("directory.zig").Directory;

const log = std.log.scoped(.verifier);

pub const InvariantId = enum(u8) {
    cat_by_parent_coverage = 0,
    link_by_category_coverage = 1,
    link_by_url_hash_coverage = 2,
    subtree_counts = 3,
    no_orphans = 4,
    single_top = 5,
    link_category_exists = 6,
    link_vectors_have_links = 7,
};

pub const invariant_count = std.enums.values(InvariantId).len;

const composite_key_len: usize = 16;

pub const InvariantHealth = struct {
    name: []const u8,
    expected: u64,
    observed: u64,

    pub fn drift_bp(self: InvariantHealth) u32 {
        assert(self.name.len > 0);
        if (self.expected == 0) {
            if (self.observed == 0) return 0;
            return std.math.maxInt(u32);
        }
        assert(self.expected > 0);
        const diff: u64 = if (self.observed > self.expected)
            self.observed - self.expected
        else
            self.expected - self.observed;
        const bp: u64 = @divFloor(diff * 10000, self.expected);
        if (self.observed <= self.expected) assert(bp <= 10_000);
        return @intCast(@min(bp, std.math.maxInt(u32)));
    }
};

pub const VerifierState = struct {
    // Zero until the first run completes; the status frame reports it as never run.
    last_run_at: i64 = 0,
    any_drift: bool = false,
    indices: [invariant_count]InvariantHealth = .{
        .{ .name = "cat_by_parent", .expected = 0, .observed = 0 },
        .{ .name = "link_by_category", .expected = 0, .observed = 0 },
        .{ .name = "link_by_url_hash", .expected = 0, .observed = 0 },
        .{ .name = "subtree_counts", .expected = 0, .observed = 0 },
        .{ .name = "no_orphans", .expected = 0, .observed = 0 },
        .{ .name = "single_top", .expected = 0, .observed = 0 },
        .{ .name = "link_category_exists", .expected = 0, .observed = 0 },
        .{ .name = "link_vectors_have_links", .expected = 0, .observed = 0 },
    },
    mutex: std.Io.Mutex = .init,

    pub fn snapshot(self: *VerifierState, db: *Directory) struct {
        last_run_at: i64,
        indices: [invariant_count]InvariantHealth,
        slug_path_repair_queue_depth: u64,
        slug_path_repair_worker_last_tick_ms: i64,
        slug_path_repair_worker_tasks_processed: u64,
        slug_path_repair_worker_chunks_processed: u64,
    } {
        self.mutex.lockUncancelable(db.io);
        defer self.mutex.unlock(db.io);
        assert(self.last_run_at >= 0);
        if (self.any_drift) assert(self.last_run_at > 0);
        const last_tick_ms = db.repair_worker_last_tick_ms.load(.acquire);
        assert(last_tick_ms >= 0);
        return .{
            .last_run_at = self.last_run_at,
            .indices = self.indices,
            .slug_path_repair_queue_depth = db.slug_path_repair_queue().entryCount(),
            .slug_path_repair_worker_last_tick_ms = last_tick_ms,
            .slug_path_repair_worker_tasks_processed = db.repair_worker_tasks_processed.load(
                .monotonic,
            ),
            .slug_path_repair_worker_chunks_processed = db.repair_worker_chunks_processed.load(
                .monotonic,
            ),
        };
    }
};

pub const VerifierError = error{WritesDuringPass};

pub fn run_once(db: *Directory, state: *VerifierState) !void {
    const started_ms = db.now_millis();
    const sequence_before = write_sequence(db);
    const totals = try run_once_totals(db);
    const indices = try run_once_indices(db, totals);
    const slug_path_count = try count_tree(db.categories_by_slug_path(), "");
    log.info(
        "verifier: {d} of {d} links carry a vector",
        .{ totals.vector_count, totals.link_count },
    );

    // Each tree is counted at its own moment, so a write that lands during the pass reads as
    // drift on a consistent store. Such a pass publishes nothing and says so with an error, so
    // op 19 cannot report the previous pass, or none, as the one just run.
    const sequence_after = write_sequence(db);
    assert(sequence_after >= sequence_before);
    if (sequence_after != sequence_before) {
        log.info("verifier: {d} writes landed during the pass; drift not judged", .{
            sequence_after - sequence_before,
        });
        return VerifierError.WritesDuringPass;
    }

    state.mutex.lockUncancelable(db.io);
    state.last_run_at = db.now_seconds();
    state.indices = indices;
    assert(state.last_run_at > 0);
    state.mutex.unlock(db.io);

    var any_drift = try run_once_derived_drift(db, totals, slug_path_count);
    for (indices) |invariant| {
        const drift = invariant.drift_bp();
        if (drift == 0) continue;
        any_drift = true;
        log.warn(
            "invariant {s} drift {d}bp (expected={d} observed={d}) — " ++
                "manual intervention required",
            .{ invariant.name, drift, invariant.expected, invariant.observed },
        );
    }

    state.mutex.lockUncancelable(db.io);
    state.any_drift = any_drift;
    state.mutex.unlock(db.io);

    const elapsed_ms = db.now_millis() - started_ms;
    if (any_drift) {
        log.info("verifier: completed in {d}ms with drift (warn-only)", .{elapsed_ms});
    } else {
        log.info("verifier: completed in {d}ms — all clean", .{elapsed_ms});
    }
}

// Every commit appends to the WAL and applies while holding write_mutex, so the sequence read
// under it is a point no write straddles: equal readings around a pass mean none landed.
fn write_sequence(db: *Directory) u64 {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    if (db.store.wal_writer) |*wal| {
        const sequence = wal.getSequence();
        assert(sequence >= wal.durableSeqPublished());
        return sequence;
    }
    return 0;
}

const TreeTotals = struct {
    category_count: u64,
    link_count: u64,
    cat_by_parent_count: u64,
    link_by_category_count: u64,
    link_by_url_hash_count: u64,
    vector_count: u64,
};

// The memtables are drained first so a row written since the last flush is counted once, in
// its tree, instead of being missed by every scan below.
fn run_once_totals(db: *Directory) !TreeTotals {
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());
    try db.drain_one_memtable(db.memtable_link_by_category(), db.link_by_category());
    try db.drain_one_memtable(db.memtable_link_by_url_hash(), db.link_by_url_hash());

    comptime assert(composite_key_len == 2 * @sizeOf(u64));
    const u64_key_min = codec.encodeU64(0);
    const composite_key_min: [composite_key_len]u8 = @splat(0);
    return .{
        .category_count = try count_tree(db.categories_by_id(), &u64_key_min),
        .link_count = try count_tree(db.links_by_id(), &u64_key_min),
        .cat_by_parent_count = try count_tree(db.cat_by_parent(), &composite_key_min),
        .link_by_category_count = try count_tree(db.link_by_category(), &composite_key_min),
        .link_by_url_hash_count = try count_tree(db.link_by_url_hash(), &u64_key_min),
        .vector_count = try count_tree(db.link_vectors(), &u64_key_min),
    };
}

fn run_once_indices(db: *Directory, totals: TreeTotals) ![invariant_count]InvariantHealth {
    comptime {
        for (std.enums.values(InvariantId), 0..) |id, index| assert(@intFromEnum(id) == index);
    }
    var indices = (VerifierState{}).indices;
    run_once_set(&indices, .cat_by_parent_coverage, .{
        .expected = totals.category_count,
        .observed = totals.cat_by_parent_count,
    });
    run_once_set(&indices, .link_by_category_coverage, .{
        .expected = totals.link_count,
        .observed = totals.link_by_category_count,
    });
    run_once_set(&indices, .link_by_url_hash_coverage, .{
        .expected = totals.link_count,
        .observed = totals.link_by_url_hash_count,
    });

    const subtree_drift = try count_subtree_drift(db);
    run_once_set(&indices, .subtree_counts, .{
        .expected = totals.category_count,
        .observed = totals.category_count -| subtree_drift,
    });
    const orphan_count = try count_orphans(db);
    run_once_set(&indices, .no_orphans, .{
        .expected = totals.category_count,
        .observed = totals.category_count -| orphan_count,
    });
    const top_count = try count_tops(db);
    run_once_set(&indices, .single_top, .{
        .expected = if (totals.category_count == 0) 0 else 1,
        .observed = top_count,
    });
    const link_orphan_count = try count_links_with_missing_category(db);
    run_once_set(&indices, .link_category_exists, .{
        .expected = totals.link_count,
        .observed = totals.link_count -| link_orphan_count,
    });
    const vector_orphan_count = try count_vectors_with_missing_link(db);
    run_once_set(&indices, .link_vectors_have_links, .{
        .expected = totals.vector_count,
        .observed = totals.vector_count -| vector_orphan_count,
    });

    assert(indices[@intFromEnum(InvariantId.single_top)].expected <= 1);
    assert(indices[@intFromEnum(InvariantId.subtree_counts)].observed <= totals.category_count);
    assert(indices[@intFromEnum(InvariantId.no_orphans)].observed <= totals.category_count);
    assert(indices[@intFromEnum(InvariantId.link_category_exists)].observed <= totals.link_count);
    assert(
        indices[@intFromEnum(InvariantId.link_vectors_have_links)].observed <= totals.vector_count,
    );
    for (indices) |health| assert(health.name.len > 0);
    return indices;
}

const Counts = struct { expected: u64, observed: u64 };

fn run_once_set(indices: *[invariant_count]InvariantHealth, id: InvariantId, counts: Counts) void {
    const slot = &indices[@intFromEnum(id)];
    assert(slot.expected == 0);
    assert(slot.observed == 0);
    slot.expected = counts.expected;
    slot.observed = counts.observed;
}

fn run_once_derived_drift(db: *Directory, totals: TreeTotals, slug_path_count: u64) !bool {
    var any_drift = false;
    if (slug_path_count != totals.category_count) {
        any_drift = true;
        log.warn(
            "invariant categories_by_slug_path coverage (expected={d} observed={d}) — " ++
                "manual intervention required",
            .{ totals.category_count, slug_path_count },
        );
    }
    if (totals.category_count > 0) {
        if (!(try tree_non_empty(db.categories_index_tree(), ""))) {
            any_drift = true;
            log.warn(
                "invariant categories_index empty while {d} categories exist — rebuild required",
                .{totals.category_count},
            );
        }
    }
    if (totals.link_count > 0) {
        if (!(try tree_non_empty(db.links_index_tree(), ""))) {
            any_drift = true;
            log.warn(
                "invariant links_index empty while {d} links exist — rebuild required",
                .{totals.link_count},
            );
        }
    }
    return any_drift;
}

// Every scan below holds its tree's shared lock only for one chunk: the rangeScan iterator keeps
// the lock until it is closed, and std.Io.RwLock queues each new reader behind a waiting writer,
// so one whole-tree pass stalled every get_link once a memtable drain queued (a 4.5 s pass on the
// 92k store took the worst read from 11 ms to 893 ms). Reopening after each chunk bounds that
// wait to one chunk of entries and the lookups made for them.
const scan_chunk_entries: u32 = 1024;
// Keys in these trees reach the slug-path maximum; one spare byte holds the successor suffix.
const scan_key_len_max: usize = 2048 + 1;
// No tree holds anywhere near this many chunks; reaching it means the scan is not advancing.
const scan_chunks_max: u64 = 1 << 32;

pub const ScanError = error{ ScanKeyTooLong, ScanTooLong };

/// `tree` is a `*BPlusTree`, or in a test a stand-in with the same `rangeScan`.
fn scan_chunked(tree: anytype, min_key: []const u8, visitor: anytype) !void {
    comptime assert(scan_chunk_entries > 0);
    assert(min_key.len < scan_key_len_max);
    var resume_buffer: [scan_key_len_max]u8 = undefined;
    var start_key: []const u8 = min_key;
    for (0..scan_chunks_max) |_| {
        var iterator = try tree.rangeScan(start_key, null);
        defer iterator.deinit();
        for (0..scan_chunk_entries) |visited| {
            const entry = (try iterator.next()) orelse return;
            try visitor.visit(entry);
            if (visited + 1 == scan_chunk_entries) {
                start_key = try successor_key(entry.key, &resume_buffer);
                assert(start_key.len <= scan_key_len_max);
            }
        }
        assert(start_key.ptr == &resume_buffer);
    }
    return ScanError.ScanTooLong;
}

// The smallest key after `key` in byte order is `key` with a zero byte appended.
fn successor_key(key: []const u8, buffer: *[scan_key_len_max]u8) ![]const u8 {
    if (key.len >= buffer.len) return ScanError.ScanKeyTooLong;
    @memcpy(buffer[0..key.len], key);
    buffer[key.len] = 0;
    const successor = buffer[0 .. key.len + 1];
    assert(successor.len == key.len + 1);
    assert(std.mem.order(u8, key, successor) == .lt);
    return successor;
}

const EntryCounter = struct {
    count: u64 = 0,

    fn visit(counter: *EntryCounter, entry: anytype) !void {
        _ = entry;
        assert(counter.count < std.math.maxInt(u64));
        counter.count += 1;
    }
};

fn count_tree(tree: *btree.BPlusTree, min_key: []const u8) !u64 {
    comptime assert(composite_key_len < scan_key_len_max);
    assert(min_key.len <= composite_key_len);
    var counter = EntryCounter{};
    try scan_chunked(tree, min_key, &counter);
    return counter.count;
}

fn tree_non_empty(tree: *btree.BPlusTree, min_key: []const u8) !bool {
    assert(min_key.len == 0);
    var iterator = try tree.rangeScan(min_key, null);
    defer iterator.deinit();
    return (try iterator.next()) != null;
}

fn category_of(entry: anytype) ?schema.Category {
    if (entry.value.len < @sizeOf(schema.Category)) return null;
    assert(entry.value.len >= @sizeOf(schema.Category));
    return std.mem.bytesToValue(schema.Category, entry.value[0..@sizeOf(schema.Category)]);
}

const TopCounter = struct {
    walked: u64 = 0,
    tops: u64 = 0,

    fn visit(counter: *TopCounter, entry: anytype) !void {
        counter.walked += 1;
        assert(counter.walked > 0);
        const category = category_of(entry) orelse return;
        if (category.parent_id == 0) counter.tops += 1;
        assert(counter.tops <= counter.walked);
    }
};

fn count_tops(db: *Directory) !u64 {
    const min_key = codec.encodeU64(0);
    var counter = TopCounter{};
    try scan_chunked(db.categories_by_id(), &min_key, &counter);
    assert(counter.tops <= counter.walked);
    return counter.tops;
}

const ParentCollector = struct {
    allocator: std.mem.Allocator,
    parents: std.ArrayListUnmanaged(u64) = .empty,
    walked: u64 = 0,

    fn visit(collector: *ParentCollector, entry: anytype) !void {
        collector.walked += 1;
        assert(collector.walked > 0);
        const category = category_of(entry) orelse return;
        if (category.parent_id == 0) return;
        try collector.parents.append(collector.allocator, category.parent_id);
        assert(collector.parents.items.len <= collector.walked);
    }
};

fn count_orphans(db: *Directory) !u64 {
    const ops = @import("operations/operations.zig");

    var collector = ParentCollector{ .allocator = db.allocator };
    defer collector.parents.deinit(db.allocator);
    const min_key = codec.encodeU64(0);
    try scan_chunked(db.categories_by_id(), &min_key, &collector);
    assert(collector.parents.items.len <= collector.walked);

    var orphans: u64 = 0;
    for (collector.parents.items) |parent_id| {
        assert(parent_id != 0);
        const parent = ops.get_category(db, parent_id) catch null;
        if (parent == null) orphans += 1;
    }
    assert(orphans <= collector.parents.items.len);
    return orphans;
}

const LinkCategoryChecker = struct {
    db: *Directory,
    category_exists: std.AutoHashMap(u64, bool),
    walked: u64 = 0,
    orphans: u64 = 0,

    fn visit(checker: *LinkCategoryChecker, entry: anytype) !void {
        const ops = @import("operations/operations.zig");
        checker.walked += 1;
        assert(checker.walked > 0);
        if (entry.value.len < @sizeOf(schema.Link)) return;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        const slot = try checker.category_exists.getOrPut(link.category_id);
        if (!slot.found_existing) {
            slot.value_ptr.* = (ops.get_category(checker.db, link.category_id) catch null) != null;
        }
        if (!slot.value_ptr.*) checker.orphans += 1;
        assert(checker.orphans <= checker.walked);
    }
};

fn count_links_with_missing_category(db: *Directory) !u64 {
    var checker = LinkCategoryChecker{
        .db = db,
        .category_exists = std.AutoHashMap(u64, bool).init(db.allocator),
    };
    defer checker.category_exists.deinit();

    const min_key = codec.encodeU64(0);
    try scan_chunked(db.links_by_id(), &min_key, &checker);
    assert(checker.category_exists.count() <= checker.walked);
    assert(checker.orphans <= checker.walked);
    return checker.orphans;
}

const VectorLinkChecker = struct {
    db: *Directory,
    walked: u64 = 0,
    orphans: u64 = 0,

    fn visit(checker: *VectorLinkChecker, entry: anytype) !void {
        const ops = @import("operations/operations.zig");
        checker.walked += 1;
        assert(checker.walked > 0);
        if (entry.key.len != @sizeOf(u64)) return error.DatabaseCorrupted;
        const link_id = codec.decodeU64(entry.key[0..8]);
        if ((ops.get_link(checker.db, link_id) catch null) == null) checker.orphans += 1;
        assert(checker.orphans <= checker.walked);
    }
};

fn count_vectors_with_missing_link(db: *Directory) !u64 {
    var checker = VectorLinkChecker{ .db = db };
    const min_key = codec.encodeU64(0);
    try scan_chunked(db.link_vectors(), &min_key, &checker);
    assert(checker.orphans <= checker.walked);
    return checker.orphans;
}

const ExpectedCounts = @import("operations/operations_category.zig").ExpectedCounts;

const SubtreeDriftCounter = struct {
    counts: *const @import("operations/operations_category.zig").CategoryCounts,
    walked: u64 = 0,
    drift: u64 = 0,

    fn visit(counter: *SubtreeDriftCounter, entry: anytype) !void {
        counter.walked += 1;
        assert(counter.walked > 0);
        const category = category_of(entry) orelse return;
        const want = counter.counts.expected_for(category.id);
        assert(want.link_count_subtree >= want.link_count);
        assert(want.child_count_subtree >= want.child_count);
        var have = ExpectedCounts.of_record(&category);
        // The direct counts are not this invariant, so only the subtree columns are compared.
        have.link_count = want.link_count;
        have.child_count = want.child_count;
        if (!std.meta.eql(have, want)) counter.drift += 1;
        assert(counter.drift <= counter.walked);
    }
};

fn count_subtree_drift(db: *Directory) !u64 {
    const ops = @import("operations/operations.zig");
    var counts = try ops.compute_category_counts(db);
    defer counts.deinit();

    var counter = SubtreeDriftCounter{ .counts = &counts };
    const min_key = codec.encodeU64(0);
    try scan_chunked(db.categories_by_id(), &min_key, &counter);
    assert(counter.drift <= counter.walked);
    return counter.drift;
}

// Goal: drift is a basis-point distance in either direction. Method: four hand-computed pairs.
test "InvariantHealth.drift_bp basic" {
    const under = InvariantHealth{ .name = "x", .expected = 1000, .observed = 950 };
    try std.testing.expectEqual(@as(u32, 500), under.drift_bp());

    const exact = InvariantHealth{ .name = "x", .expected = 1000, .observed = 1000 };
    try std.testing.expectEqual(@as(u32, 0), exact.drift_bp());

    const empty = InvariantHealth{ .name = "x", .expected = 0, .observed = 0 };
    try std.testing.expectEqual(@as(u32, 0), empty.drift_bp());

    const over = InvariantHealth{ .name = "x", .expected = 1000, .observed = 1100 };
    try std.testing.expectEqual(@as(u32, 1000), over.drift_bp());
}

// Goal: a consistent store reports no drift. Method: one category, run, read every invariant.
test "verifier: clean DB has no drift" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    _ = try ops.create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });

    var state = VerifierState{};
    try run_once(db, &state);

    for (state.indices) |invariant| {
        const drift = invariant.drift_bp();
        try std.testing.expect(drift < 100);
    }
}

// Goal: a wrong subtree count is reported, not fixed. Method: tamper one row, run, re-read it.
test "verifier: detects subtree count drift without repairing (WARN-only)" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    var sibling_ids: [50]u64 = undefined;
    var name_buffer: [16]u8 = undefined;
    var slug_buffer: [16]u8 = undefined;
    for (0..sibling_ids.len) |i| {
        const name = try std.fmt.bufPrint(&name_buffer, "C{d}", .{i});
        const slug = try std.fmt.bufPrint(&slug_buffer, "c{d}", .{i});
        sibling_ids[i] = try ops.create_category(
            db,
            top_id,
            .{ .name = name, .slug = slug, .description = "" },
        );
    }
    _ = try ops.create_link(
        db,
        sibling_ids[0],
        .{ .url = "https://x.example", .title = "x", .description = "" },
    );

    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());

    {
        var category = (try ops.get_category(db, sibling_ids[0])).?;
        category.link_count_subtree = 0;
        const id_key = codec.encodeU64(sibling_ids[0]);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&category));
    }

    var state = VerifierState{};
    try run_once(db, &state);

    const subtree = state.indices[@intFromEnum(InvariantId.subtree_counts)];
    try std.testing.expect(subtree.drift_bp() > 0);

    const after = (try ops.get_category(db, sibling_ids[0])).?;
    try std.testing.expectEqual(@as(u64, 0), after.link_count_subtree);
}

// Goal: a missing link_by_category row shows as coverage drift. Method: delete one row and run.
test "verifier: tampered link_count surfaces drift on link_by_category invariant" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try ops.create_link(
        db,
        top,
        .{ .url = "https://a.example", .title = "a", .description = "" },
    );
    _ = try ops.create_link(
        db,
        top,
        .{ .url = "https://b.example", .title = "b", .description = "" },
    );

    try db.drain_one_memtable(db.memtable_link_by_category(), db.link_by_category());

    {
        var key_copy: [16]u8 = undefined;
        var found = false;
        {
            const min_key: [16]u8 = @splat(0);
            var iterator = try db.link_by_category().rangeScan(&min_key, null);
            defer iterator.deinit();
            if (try iterator.next()) |entry| {
                @memcpy(&key_copy, entry.key[0..16]);
                found = true;
            }
        }
        if (found) _ = try db.link_by_category().delete(&key_copy);
    }

    var state = VerifierState{};
    try run_once(db, &state);

    const invariant = state.indices[@intFromEnum(InvariantId.link_by_category_coverage)];
    try std.testing.expect(invariant.drift_bp() > 0);
}

// Goal: a wrong child subtree count is reported. Method: tamper the root's count and run.
test "verifier: tampered child_count_subtree surfaces drift" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try ops.create_category(db, top, .{ .name = "A", .slug = "a", .description = "" });
    _ = try ops.create_category(db, top, .{ .name = "B", .slug = "b", .description = "" });

    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());

    {
        var category = (try ops.get_category(db, top)).?;
        category.child_count_subtree = 99;
        const id_key = codec.encodeU64(top);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&category));
    }

    var state = VerifierState{};
    try run_once(db, &state);

    const subtree = state.indices[@intFromEnum(InvariantId.subtree_counts)];
    try std.testing.expect(subtree.drift_bp() > 0);
}

// Goal: the snapshot carries one named slot per invariant. Method: run, snapshot, check names.
test "verifier: every InvariantId has a matching snapshot index" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var state = VerifierState{};
    try run_once(db, &state);

    const snapshot = state.snapshot(db);
    try std.testing.expectEqual(invariant_count, snapshot.indices.len);
    for (snapshot.indices) |health| {
        try std.testing.expect(health.name.len > 0);
    }
}

// Goal: a run is read-only on the primary trees. Method: compare entry counts before and after.
test "verifier: run_once does not mutate categories_by_id count" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try ops.create_category(db, top, .{ .name = "A", .slug = "a", .description = "" });
    _ = try ops.create_link(
        db,
        top,
        .{ .url = "https://x.example", .title = "x", .description = "" },
    );

    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());

    const before_categories = db.categories_by_id().entry_count;
    const before_links = db.links_by_id().entry_count;

    var state = VerifierState{};
    try run_once(db, &state);

    try std.testing.expectEqual(before_categories, db.categories_by_id().entry_count);
    try std.testing.expectEqual(before_links, db.links_by_id().entry_count);
}

// Goal: the verifier tolerates concurrent writes. Method: a writer thread races five runs.
test "verifier: concurrent writer + verifier does not crash" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    const Writer = struct {
        fn run(directory: *Directory, parent: u64) void {
            assert(parent > 0);
            var url_buffer: [64]u8 = undefined;
            for (0..200) |i| {
                const url = std.fmt.bufPrint(&url_buffer, "https://w{d}.example", .{i}) catch
                    continue;
                _ = ops.create_link(
                    directory,
                    parent,
                    .{ .url = url, .title = "x", .description = "" },
                ) catch {};
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Writer.run, .{ db, top });

    var state = VerifierState{};
    for (0..5) |_| {
        run_once(db, &state) catch {};
    }
    thread.join();

    try run_once(db, &state);
}

// Goal: two snapshots of one state agree field by field. Method: run once, snapshot twice.
test "verifier: op 19 frame matches op 18 frame" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var state = VerifierState{};
    try run_once(db, &state);
    db.verifier_state = state;

    const first = db.verifier_state.snapshot(db);
    const second = db.verifier_state.snapshot(db);
    try std.testing.expectEqual(first.last_run_at, second.last_run_at);
    try std.testing.expectEqual(first.indices.len, second.indices.len);
    for (first.indices, second.indices) |a, b| {
        try std.testing.expectEqualSlices(u8, a.name, b.name);
        try std.testing.expectEqual(a.expected, b.expected);
        try std.testing.expectEqual(a.observed, b.observed);
    }
    try std.testing.expectEqual(
        first.slug_path_repair_queue_depth,
        second.slug_path_repair_queue_depth,
    );
}

// Goal: the queue depth in a snapshot is live. Method: snapshot, enqueue one task, snapshot.
test "verifier: slug_path_repair_queue_depth round-trips through snapshot" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var state = VerifierState{};
    var snapshot = state.snapshot(db);
    try std.testing.expectEqual(@as(u64, 0), snapshot.slug_path_repair_queue_depth);

    const seq: u64 = 1;
    const key = codec.encodeU64(seq);
    const value = codec.encodeU64(42);
    try db.slug_path_repair_queue().insert(&key, &value);

    snapshot = state.snapshot(db);
    try std.testing.expectEqual(@as(u64, 1), snapshot.slug_path_repair_queue_depth);
}

// Goal: shutdown does not wait a whole verifier interval. Method: start workers, time deinit.
test "verifier: shutdown signal causes verifier loop to exit promptly" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);

    db.start_background_threads();
    try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);

    const started = std.Io.Clock.awake.now(std.testing.io);
    db.deinit_test_instance();
    const elapsed_ms = started.durationTo(std.Io.Clock.awake.now(std.testing.io)).toMilliseconds();

    try std.testing.expect(elapsed_ms < 5_000);
}

// Goal: a missing slug path row flips any_drift. Method: clean run, delete a row, run again.
test "H14: verifier flags slug-path coverage divergence" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try ops.create_category(db, top, .{ .name = "Child", .slug = "child", .description = "" });

    var state = VerifierState{};
    try run_once(db, &state);
    try std.testing.expect(!state.any_drift);

    _ = try db.categories_by_slug_path().delete("top/child");

    try run_once(db, &state);
    try std.testing.expect(state.any_drift);
}

// Goal: a link whose category row vanished counts as uncovered. Method: delete the category row.
test "verifier reports a link whose category no longer exists" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const doomed = try ops.create_category(
        db,
        top,
        .{ .name = "Doomed", .slug = "doomed", .description = "" },
    );
    _ = try ops.create_link(
        db,
        doomed,
        .{ .url = "https://orphan.example", .title = "Orphan", .description = "" },
    );

    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    const doomed_key = codec.encodeU64(doomed);
    _ = try db.categories_by_id().delete(&doomed_key);

    var state = VerifierState{};
    try run_once(db, &state);

    const invariant = state.indices[@intFromEnum(InvariantId.link_category_exists)];
    try std.testing.expectEqual(@as(u64, 1), invariant.expected);
    try std.testing.expectEqual(@as(u64, 0), invariant.observed);
    try std.testing.expect(invariant.drift_bp() > 0);
}

// A writer that blocks on the tree's exclusive lock until the scan lets go of it.
// Stands in for the tree in `scan_chunked` so the test sees each chunk begin. A writer's tryLock
// succeeds only while no reader holds the tree, so a pass that carried its shared lock from one
// chunk into the next fails it at the next chunk's start, with no second thread and no timing.
const ChunkStartProbe = struct {
    tree: *btree.BPlusTree,
    chunks: u32 = 0,
    chunks_started_locked: u32 = 0,

    fn rangeScan(
        probe: *ChunkStartProbe,
        start_key: []const u8,
        end_key: ?[]const u8,
    ) @TypeOf(probe.tree.rangeScan(start_key, end_key)) {
        assert(start_key.len <= scan_key_len_max);
        probe.chunks += 1;
        if (probe.tree.lock.tryLock(probe.tree.io)) {
            probe.tree.lock.unlock(probe.tree.io);
        } else {
            probe.chunks_started_locked += 1;
        }
        assert(probe.chunks_started_locked <= probe.chunks);
        return probe.tree.rangeScan(start_key, end_key);
    }
};

// Goal: a verifier scan gives the tree's lock up between chunks, so a queued writer gets in,
// instead of holding it shared for the whole pass. Method: count 5,000 rows through a stand-in
// tree that tries the writer's lock as each chunk starts; every try must succeed, and the pass
// must take one chunk per scan_chunk_entries rows.
test "verifier: a scan releases the tree lock between chunks" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const tree = db.categories_by_slug_path();
    const row_count: u32 = 5000;
    comptime assert(row_count > 4 * scan_chunk_entries);
    comptime assert(row_count % scan_chunk_entries != 0);
    for (0..row_count) |index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "k{d:0>6}", .{index});
        try tree.insert(key, &codec.encodeU64(index + 1));
    }

    var probe = ChunkStartProbe{ .tree = tree };
    var counter = EntryCounter{};
    try scan_chunked(&probe, "", &counter);

    try std.testing.expectEqual(@as(u64, row_count), counter.count);
    const chunks_expected: u32 = @divFloor(row_count, scan_chunk_entries) + 1;
    try std.testing.expectEqual(chunks_expected, probe.chunks);
    try std.testing.expectEqual(@as(u32, 0), probe.chunks_started_locked);
}

// Goal: resuming after a chunk neither skips nor repeats a key, including keys that are
// prefixes of one another. Method: count a tree whose keys straddle several chunk boundaries.
test "verifier: chunked count resumes exactly after the last key" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const tree = db.categories_by_slug_path();
    const prefix_keys = [_][]const u8{ "a", "a\x00", "a\x00\x00", "ab" };
    for (prefix_keys) |key| try tree.insert(key, &codec.encodeU64(1));
    for (0..3 * scan_chunk_entries) |index| {
        var key_buffer: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "a{d:0>6}", .{index});
        try tree.insert(key, &codec.encodeU64(index + 1));
    }
    const expected: u64 = prefix_keys.len + 3 * scan_chunk_entries;
    try std.testing.expectEqual(expected, try count_tree(tree, ""));
}

// Goal: writes landing during a pass are never reported as drift on a consistent store. Method:
// a writer thread creates links throughout twenty passes; no pass may report drift, and a quiet
// pass after it stops must report none either.
test "verifier: writes during a pass are not reported as drift" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    const top_text: ops.CategoryText = .{ .name = "Top", .slug = "top", .description = "" };
    const top = try ops.create_category(db, 0, top_text);
    var stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, DriftProbeWriter.run, .{ db, top, &stop });

    var drifted_runs: u32 = 0;
    for (0..20) |_| {
        var state = VerifierState{};
        run_once(db, &state) catch continue;
        if (state.any_drift) drifted_runs += 1;
    }
    stop.store(true, .release);
    thread.join();

    var quiet = VerifierState{};
    try run_once(db, &quiet);
    try std.testing.expect(!quiet.any_drift);
    try std.testing.expect(quiet.last_run_at > 0);
    try std.testing.expectEqual(@as(u32, 0), drifted_runs);
}

const DriftProbeWriter = struct {
    fn run(directory: *Directory, parent: u64, stop: *std.atomic.Value(bool)) void {
        const ops = @import("operations/operations.zig");
        assert(parent != 0);
        var url_buffer: [64]u8 = undefined;
        for (0..100_000) |index| {
            if (stop.load(.acquire)) return;
            const url = std.fmt.bufPrint(&url_buffer, "https://w{d}.example", .{index}) catch
                unreachable;
            assert(url.len > 0);
            const text: ops.LinkText = .{ .url = url, .title = "x", .description = "" };
            _ = ops.create_link(directory, parent, text) catch {};
        }
    }
};
