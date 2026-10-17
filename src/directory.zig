const std = @import("std");
const zigstore = @import("zigstore");
const subtree_mod = @import("subtree.zig");
const verifier = @import("verifier.zig");
const changeset = @import("changeset.zig");
const apply_mod = @import("apply/apply.zig");
const wal_apply = @import("wal/wal_apply.zig");
const repair_worker = @import("repair/repair_worker.zig");
const histogram = zigstore.histogram;
const binary_protocol = @import("binary_protocol.zig");
const Config = @import("main.zig").Config;

const log = std.log.scoped(.directory);

pub const schema = zigstore.schema(.{
    .magic = 0x444D4F5A,
    .format_version = 5,
    .indexes = .{
        .{ .name = "categories_by_id", .key = .u64 },
        .{ .name = "cat_by_parent", .key = .{ .composite = &.{ "parent_id", "child_id" } } },
        .{ .name = "links_by_id", .key = .u64 },
        .{ .name = "link_by_category", .key = .{ .composite = &.{ "category_id", "link_id" } } },
        .{ .name = "link_by_url_hash", .key = .u64 },
        .{ .name = "link_by_submitter", .key = .{ .composite = &.{ "submitter_id", "link_id" } } },
        .{ .name = "categories_by_slug_path", .key = .bytes },
        .{ .name = "categories_by_slug_only", .key = .bytes },
        .{ .name = "categories_index_tree", .key = .bytes },
        .{ .name = "links_index_tree", .key = .bytes },
        .{ .name = "slug_path_repair_queue", .key = .u64 },
    },
    .memtable_indexes = &.{ "categories_by_id", "cat_by_parent", "links_by_id", "link_by_category", "link_by_url_hash", "link_by_submitter" },
    .counters = &.{ "next_category_id", "next_link_id", "next_repair_seq", "links_pending", "links_approved", "links_rejected", "derived_counts_version" },
});

pub const Store = zigstore.Engine(schema);

pub const Stats = struct {
    category_count: u64 = 0,
    link_count: u64 = 0,
    page_count: u32 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    wal_pending_batch_entries: u64 = 0,
};

pub const URL_BLOOM_INITIAL_CAPACITY: u64 = 1_000_000;
pub const DERIVED_COUNTS_VERSION: u64 = 1;
const MEMTABLE_FLUSH_INTERVAL_NS: u64 = 5 * std.time.ns_per_ms;

threadlocal var deferred_durable_seq: ?u64 = null;

pub const Directory = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    store: *Store,

    verifier_state: verifier.VerifierState,
    verifier_worker: ?*zigstore.Worker,
    verifier_interval_ns: u64,

    write_mutex: std.Io.Mutex,

    repair_worker: ?*zigstore.Worker,
    repair_worker_mutex: std.Io.Mutex,
    repair_worker_tasks_processed: std.atomic.Value(u64),
    repair_worker_chunks_processed: std.atomic.Value(u64),
    repair_worker_last_tick_ms: std.atomic.Value(i64),

    mt_flusher: ?*zigstore.Worker,
    checkpointer: ?*zigstore.Worker,

    subtree_cache: subtree_mod.SubtreeCache,

    url_bloom: zigstore.BloomFilter,
    url_bloom_ready: std.atomic.Value(bool),
    url_bloom_seeder: ?std.Thread,
    url_bloom_seeder_stop: std.atomic.Value(bool),

    next_category_id: std.atomic.Value(u64),
    next_link_id: std.atomic.Value(u64),
    next_repair_seq: std.atomic.Value(u64),

    links_pending_count: std.atomic.Value(u64),
    links_approved_count: std.atomic.Value(u64),
    links_rejected_count: std.atomic.Value(u64),

    op_latency: *[256]histogram.AtomicHistogram,

    const Self = @This();

    pub fn dispatch(ctx: *anyopaque, op_byte: u8, payload: []const u8, count: u16, resp: []u8, _: *zigstore.protocol.FrameGate) usize {
        const dir = asDir(ctx);
        deferred_durable_seq = 0;
        defer deferred_durable_seq = null;

        const written = binary_protocol.dispatch(dir, op_byte, payload, count, resp);
        dir.awaitDurable(deferred_durable_seq.?);
        return written;
    }

    pub fn processFrames(ctx: *anyopaque, conn: *zigstore.connection.Connection) void {
        const dir = asDir(ctx);
        zigstore.protocol.processFrames(ctx, conn, &Directory.dispatch, dir.op_latency, binary_protocol.RESPONSE_RESERVE);
    }

    pub fn handler() zigstore.Handler {
        return .{
            .process_frames = &Directory.processFrames,
            .header_size = zigstore.protocol.HEADER_SIZE,
            .on_shutdown = &Directory.checkpointOnShutdown,
        };
    }

    fn checkpointOnShutdown(ctx: *anyopaque) void {
        const dir = asDir(ctx);
        dir.checkpoint() catch |err| {
            log.err("checkpoint on shutdown failed: {} — recovery will replay on next boot", .{err});
        };
    }

    pub fn categories_by_id(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("categories_by_id");
    }
    pub fn cat_by_parent(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("cat_by_parent");
    }
    pub fn links_by_id(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("links_by_id");
    }
    pub fn link_by_category(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("link_by_category");
    }
    pub fn link_by_url_hash(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("link_by_url_hash");
    }
    pub fn link_by_submitter(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("link_by_submitter");
    }
    pub fn categories_by_slug_path(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("categories_by_slug_path");
    }
    pub fn categories_by_slug_only(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("categories_by_slug_only");
    }
    pub fn categories_index_tree(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("categories_index_tree");
    }
    pub fn links_index_tree(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("links_index_tree");
    }
    pub fn slug_path_repair_queue(self: *Self) *zigstore.BPlusTree {
        return self.store.tree("slug_path_repair_queue");
    }

    pub fn mt_categories_by_id(self: *Self) *zigstore.MemTable {
        return self.store.memtable("categories_by_id");
    }
    pub fn mt_cat_by_parent(self: *Self) *zigstore.MemTable {
        return self.store.memtable("cat_by_parent");
    }
    pub fn mt_links_by_id(self: *Self) *zigstore.MemTable {
        return self.store.memtable("links_by_id");
    }
    pub fn mt_link_by_category(self: *Self) *zigstore.MemTable {
        return self.store.memtable("link_by_category");
    }
    pub fn mt_link_by_url_hash(self: *Self) *zigstore.MemTable {
        return self.store.memtable("link_by_url_hash");
    }
    pub fn mt_link_by_submitter(self: *Self) *zigstore.MemTable {
        return self.store.memtable("link_by_submitter");
    }

    pub fn openTestInstance(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !*Self {
        var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
        const path = try allocator.dupe(u8, path_buf[0..path_len]);
        errdefer allocator.free(path);
        const dir = try Self.init(std.testing.io, allocator, .{
            .data_dir = path,
            .server = .{
                .cache_size_mb = 16,
                .thread_count = 1,
                .wal_batch_size = 32,
                .snapshot_interval_s = 3600,
            },
        });
        return dir;
    }

    pub fn deinitTestInstance(self: *Self) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        self.deinit();
        allocator.free(data_dir);
    }

    pub fn init(io: std.Io, allocator: std.mem.Allocator, config: Config) !*Self {
        const store = try Store.init(io, allocator, .{
            .data_dir = config.data_dir,
            .cache_size_mb = config.server.cache_size_mb,
            .wal_batch_size = config.server.wal_batch_size,
        });
        errdefer store.deinit();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const bloom_capacity = @max(store.tree("links_by_id").entryCount() *| 2, URL_BLOOM_INITIAL_CAPACITY);
        var url_bloom = try zigstore.BloomFilter.init(allocator, bloom_capacity);
        errdefer url_bloom.deinit();

        const op_latency = blk: {
            const arr = try allocator.create([256]histogram.AtomicHistogram);
            for (arr) |*h| h.* = .{};
            break :blk arr;
        };
        errdefer allocator.destroy(op_latency);

        const verifier_interval_ns = @as(u64, config.verifier_interval_s) * std.time.ns_per_s;

        self.* = Self{
            .io = io,
            .allocator = allocator,
            .config = config,
            .store = store,
            .verifier_state = .{},
            .verifier_worker = null,
            .verifier_interval_ns = verifier_interval_ns,
            .write_mutex = .init,
            .repair_worker = null,
            .repair_worker_mutex = .init,
            .repair_worker_tasks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_chunks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_last_tick_ms = std.atomic.Value(i64).init(0),
            .mt_flusher = null,
            .checkpointer = null,
            .subtree_cache = subtree_mod.SubtreeCache.init(io, allocator),
            .url_bloom = url_bloom,
            .url_bloom_ready = std.atomic.Value(bool).init(false),
            .url_bloom_seeder = null,
            .url_bloom_seeder_stop = std.atomic.Value(bool).init(false),
            .next_category_id = std.atomic.Value(u64).init(store.counter("next_category_id").*),
            .next_link_id = std.atomic.Value(u64).init(store.counter("next_link_id").*),
            .next_repair_seq = std.atomic.Value(u64).init(store.counter("next_repair_seq").*),
            .links_pending_count = std.atomic.Value(u64).init(store.counter("links_pending").*),
            .links_approved_count = std.atomic.Value(u64).init(store.counter("links_approved").*),
            .links_rejected_count = std.atomic.Value(u64).init(store.counter("links_rejected").*),
            .op_latency = op_latency,
        };

        if (store.was_empty) {
            self.next_category_id.store(1, .monotonic);
            self.next_link_id.store(1, .monotonic);
            self.next_repair_seq.store(1, .monotonic);
        }

        return self;
    }

    pub fn startBackgroundThreads(self: *Self) void {
        self.mt_flusher = self.store.spawnWorker(self, .{
            .interval_ns = MEMTABLE_FLUSH_INTERVAL_NS,
            .tick = &flushTick,
        }) catch blk: {
            log.warn("Memtable flusher thread failed to start", .{});
            break :blk null;
        };
        self.verifier_worker = self.store.spawnWorker(self, .{
            .interval_ns = self.verifier_interval_ns,
            .tick = &verifyTick,
        }) catch null;
        self.repair_worker = self.store.spawnWorker(self, .{
            .interval_ns = @as(u64, self.config.repair_worker_interval_ms) * std.time.ns_per_ms,
            .tick = &repairTick,
        }) catch null;
        self.checkpointer = self.store.spawnCheckpointer(self.config.server.snapshot_interval_s) catch blk: {
            log.warn("Checkpointer thread failed to start — only shutdown checkpoints will run", .{});
            break :blk null;
        };
        self.url_bloom_seeder = std.Thread.spawn(.{}, seedUrlBloomInBackground, .{self}) catch blk: {
            log.warn("url bloom seeder failed to start — duplicate checks keep reading the url index", .{});
            break :blk null;
        };
    }

    fn seedUrlBloomInBackground(self: *Self) void {
        const started = std.Io.Clock.awake.now(self.io);
        @import("operations/operations.zig").seedUrlBloom(self, .yield_half_the_disk) catch |err| {
            log.warn("url bloom seeding stopped: {} — duplicate checks keep reading the url index", .{err});
            return;
        };
        if (self.url_bloom_ready.load(.acquire)) {
            log.info("url bloom seeded in {d} ms", .{started.untilNow(self.io, .awake).toMilliseconds()});
        }
    }

    fn asDir(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn flushTick(ctx: *anyopaque) anyerror!void {
        try asDir(ctx).drainAllMemtables();
    }

    fn verifyTick(ctx: *anyopaque) anyerror!void {
        const self = asDir(ctx);
        try verifier.runOnce(self, &self.verifier_state);
    }

    fn repairTick(ctx: *anyopaque) anyerror!void {
        try repair_worker.tickOnce(asDir(ctx));
    }

    pub fn commit(self: *Self, cs: changeset.ChangeSet) !void {
        var applied: zigstore.CommitCompletion = .{};
        const seq = zigstore.commitSeq(changeset.ChangeSet, self.store, changeset.CHANGESET_OP, cs, self, &serializeChangeSet, &applyChangeSet, .{ .completion = &applied }) catch |err| switch (err) {
            error.WalFlushFailed => abortOnWalFlushFailure(),
            else => return err,
        };

        if (deferred_durable_seq) |pending| {
            deferred_durable_seq = @max(pending, seq);
            return;
        }
        self.awaitDurable(seq);
    }

    fn awaitDurable(self: *Self, seq: u64) void {
        if (seq == 0) return;
        if (self.store.wal_writer) |*wal| {
            wal.awaitDurable(seq) catch abortOnWalFlushFailure();
        }
    }

    fn abortOnWalFlushFailure() noreturn {
        log.err("WAL flush failed after apply — aborting so recovery serves only what is durable", .{});
        @panic("WAL flush failed");
    }

    fn serializeChangeSet(allocator: std.mem.Allocator, cs: changeset.ChangeSet) anyerror![]u8 {
        return changeset.encode(allocator, cs);
    }

    fn applyChangeSet(ctx: *anyopaque, cs: changeset.ChangeSet) anyerror!void {
        applyOrAbort(asDir(ctx), cs);
    }

    fn applyOrAbort(dir: *Self, cs: changeset.ChangeSet) void {
        apply_mod.apply(dir, cs) catch |err| {
            log.err("changeset apply failed after its WAL append: {} — aborting so recovery replays it whole", .{err});
            @panic("changeset apply failed after WAL append");
        };
        dir.syncPersistedCounters();
    }

    pub fn drainAllMemtables(self: *Self) !void {
        try self.store.drainMemtables();
    }

    pub fn drainOneMemtable(self: *Self, mt: *zigstore.MemTable, tree: *zigstore.BPlusTree) !void {
        try self.store.drainMemtableInto(mt, tree);
    }

    pub fn deinit(self: *Self) void {
        self.shutdown(true);
    }

    pub fn deinitCrashTestInstance(self: *Self) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        self.shutdown(false);
        allocator.free(data_dir);
    }

    fn shutdown(self: *Self, persist: bool) void {
        self.url_bloom_seeder_stop.store(true, .release);
        if (self.url_bloom_seeder) |t| t.join();
        if (self.checkpointer) |w| w.stop();
        if (self.repair_worker) |w| w.stop();
        if (self.verifier_worker) |w| w.stop();
        if (self.mt_flusher) |w| w.stop();

        if (persist) {
            self.checkpoint() catch |err| {
                log.err("checkpoint on shutdown failed: {} — recovery will replay on next boot", .{err});
            };
        } else {
            if (self.store.wal_writer) |*w| w.deinit();
        }

        self.url_bloom.deinit();
        self.subtree_cache.deinit();

        const allocator = self.allocator;
        if (persist) {
            self.store.deinit();
        } else {
            self.store.cache.deinit();
            self.store.journal.close(self.io);
            self.store.file.close(self.io);
            inline for (Store.schema_def.memtable_indexes) |name| {
                self.store.memtable(name).deinit();
            }
            allocator.destroy(self.store);
        }

        allocator.destroy(self.op_latency);
        allocator.destroy(self);
    }

    pub fn recover(self: *Self) !void {
        try self.store.recover(self, .{
            .apply_entry = &applyEntry,
            .on_replayed = &restoreDerivedCounts,
            .bootstrap = &bootstrapRoots,
        });

        log.info("recover: complete; ready to listen", .{});
    }

    fn applyEntry(ctx: *anyopaque, entry: zigstore.ReplayEntry) anyerror!void {
        const self = asDir(ctx);
        var applier = wal_apply.WalApplier{ .db = self };
        try applier.apply(entry);
    }

    fn restoreDerivedCounts(ctx: *anyopaque) anyerror!void {
        const self = asDir(ctx);
        syncCounterUp(&self.next_category_id, self.store.counter("next_category_id").*);
        syncCounterUp(&self.next_link_id, self.store.counter("next_link_id").*);
        syncCounterUp(&self.next_repair_seq, self.store.counter("next_repair_seq").*);

        if (self.derivedCountsCheckpointed()) return;
        try self.recountDerivedCounts();
    }

    pub fn derivedCountsCheckpointed(self: *Self) bool {
        return self.store.counter("derived_counts_version").* == DERIVED_COUNTS_VERSION;
    }

    fn recountDerivedCounts(self: *Self) !void {
        const ops = @import("operations/operations.zig");
        try ops.recomputeCategoryCounts(self);
        try ops.recountLinkStatuses(self);
        self.syncPersistedCounters();
        self.store.counter("derived_counts_version").* = DERIVED_COUNTS_VERSION;
        log.info("recover: derived counts recounted once; later boots restore them from the checkpoint", .{});
    }

    fn syncCounterUp(atomic: *std.atomic.Value(u64), persisted: u64) void {
        atomic.store(@max(atomic.load(.monotonic), persisted), .monotonic);
    }

    pub fn noteIssuedCategoryId(self: *Self, id: u64) void {
        syncCounterUp(&self.next_category_id, id + 1);
    }

    pub fn noteIssuedLinkId(self: *Self, id: u64) void {
        syncCounterUp(&self.next_link_id, id + 1);
    }

    pub fn noteIssuedRepairSeq(self: *Self, seq: u64) void {
        syncCounterUp(&self.next_repair_seq, seq + 1);
    }

    fn bootstrapRoots(ctx: *anyopaque) anyerror!void {
        const self = asDir(ctx);
        if (self.categories_by_id().entryCount() != 0) return;
        const ops = @import("operations/operations.zig");
        const top_id = try ops.createCategory(self, 0, "Top", "top", "");
        _ = try ops.createCategory(
            self,
            top_id,
            "Lost and Found",
            "lost-and-found",
            "Categories whose original parent could not be resolved.",
        );
        log.info("bootstrap: created canonical Top (id={d}) + Lost-and-Found", .{top_id});
    }

    fn syncPersistedCounters(self: *Self) void {
        self.store.counter("next_category_id").* = self.next_category_id.load(.monotonic);
        self.store.counter("next_link_id").* = self.next_link_id.load(.monotonic);
        self.store.counter("next_repair_seq").* = self.next_repair_seq.load(.monotonic);
        self.store.counter("links_pending").* = self.links_pending_count.load(.monotonic);
        self.store.counter("links_approved").* = self.links_approved_count.load(.monotonic);
        self.store.counter("links_rejected").* = self.links_rejected_count.load(.monotonic);
    }

    pub fn nowSeconds(self: *Self) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    pub fn nowMillis(self: *Self) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    pub fn checkpoint(self: *Self) !void {
        self.syncPersistedCounters();
        _ = try self.store.checkpoint();
    }

    pub fn getStats(self: *Self) Stats {
        self.drainOneMemtable(self.mt_categories_by_id(), self.categories_by_id()) catch |err| log.warn("stats: category drain skipped: {}", .{err});
        self.drainOneMemtable(self.mt_links_by_id(), self.links_by_id()) catch |err| log.warn("stats: link drain skipped: {}", .{err});

        const hits = self.store.cache.hit_count.load(.monotonic);
        const misses = self.store.cache.miss_count.load(.monotonic);

        const cat_count = self.categories_by_id().entryCount();
        const link_count = self.links_by_id().entryCount();
        const pg_count = blk: {
            self.store.cache.alloc_lock.lockUncancelable(self.io);
            defer self.store.cache.alloc_lock.unlock(self.io);
            break :blk self.store.cache.page_count;
        };

        const wal_pending: u64 = if (self.store.wal_writer) |*w| blk: {
            w.lock.lockUncancelable(self.io);
            defer w.lock.unlock(self.io);
            break :blk w.entry_count;
        } else 0;

        return Stats{
            .category_count = cat_count,
            .link_count = link_count,
            .page_count = pg_count,
            .cache_hits = hits,
            .cache_misses = misses,
            .wal_pending_batch_entries = wal_pending,
        };
    }
};

test "openTestInstance: round-trips entry_count through checkpoint/init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var dir = try Directory.openTestInstance(std.testing.allocator, &tmp);
        defer dir.deinitTestInstance();

        const ops = @import("operations/operations.zig");
        const cat_id = try ops.createCategory(dir, 0, "Test", "test", "");
        try std.testing.expect(cat_id > 0);
        try dir.drainOneMemtable(dir.mt_categories_by_id(), dir.categories_by_id());
        try std.testing.expect(dir.categories_by_id().entryCount() >= 1);
    }

    {
        var dir = try Directory.openTestInstance(std.testing.allocator, &tmp);
        defer dir.deinitTestInstance();

        try std.testing.expect(dir.store.header.categories_by_id_count >= 1);
        try std.testing.expect(dir.categories_by_id().entryCount() >= 1);
    }
}

test "Directory: slug_path_repair_queue field exists and is empty after init" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try Directory.openTestInstance(allocator, &tmp);
    defer dir.deinitTestInstance();
    try std.testing.expectEqual(@as(u64, 0), dir.slug_path_repair_queue().entryCount());
}

test "next_repair_seq: persists across reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var dir = try Directory.openTestInstance(allocator, &tmp);
        defer dir.deinitTestInstance();
        _ = dir.next_repair_seq.fetchAdd(1, .monotonic);
        _ = dir.next_repair_seq.fetchAdd(1, .monotonic);
        _ = dir.next_repair_seq.fetchAdd(1, .monotonic);
        try dir.checkpoint();
    }
    {
        var dir = try Directory.openTestInstance(allocator, &tmp);
        defer dir.deinitTestInstance();
        try std.testing.expectEqual(@as(u64, 4), dir.next_repair_seq.load(.monotonic));
    }
}

test "recover boot path: clean DB reopens cleanly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var dir = try Directory.openTestInstance(allocator, &tmp);
        defer dir.deinitTestInstance();
        try dir.recover();
        const ops = @import("operations/operations.zig");
        const top_id = (try ops.resolveSlugPath(dir, "top")) orelse return error.BootstrapTopMissing;
        _ = try ops.createCategory(dir, top_id, "Arts", "arts", "");
    }

    {
        var dir = try Directory.openTestInstance(allocator, &tmp);
        defer dir.deinitTestInstance();
        try dir.recover();
        const ops = @import("operations/operations.zig");
        const id = try ops.resolveSlugPath(dir, "arts");
        try std.testing.expect(id != null);
    }
}

test "a commit made outside a dispatched request is durable when it returns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try Directory.openTestInstance(std.testing.allocator, &tmp);
    defer dir.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    _ = try ops.createCategory(dir, 0, "Top", "top", "");

    const wal = &dir.store.wal_writer.?;
    try std.testing.expectEqual(wal.getSequence(), dir.store.durableSeqPublished());
}

test "a changeset that reached the WAL is applied or the process aborts, never acked as failed" {
    const info = @typeInfo(@TypeOf(Directory.applyOrAbort)).@"fn";
    try std.testing.expectEqual(void, info.return_type.?);
}
