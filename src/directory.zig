const std = @import("std");
const zigstore = @import("zigstore");
const bloom = @import("bloom.zig");
const subtree_mod = @import("subtree.zig");
const verifier = @import("verifier.zig");
const changeset = @import("changeset.zig");
const wal_apply = @import("wal/wal_apply.zig");
const repair_worker = @import("repair/repair_worker.zig");
const histogram = @import("histogram.zig");
const memtable = @import("memtable.zig");
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
    .counters = &.{ "next_category_id", "next_link_id", "next_repair_seq" },
});

pub const Store = zigstore.Engine(schema);

pub const Stats = struct {
    category_count: u64 = 0,
    link_count: u64 = 0,
    page_count: u32 = 0,
    free_page_count: u32 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_hit_rate: f64 = 0.0,
    wal_pending_batch_entries: u64 = 0,
};

pub const Directory = struct {
    allocator: std.mem.Allocator,
    config: Config,
    store: *Store,

    verifier_state: verifier.VerifierState,
    verifier_worker: ?*zigstore.Worker,
    verifier_interval_ns: u64,

    repair_worker: ?*zigstore.Worker,
    repair_worker_mutex: std.Thread.Mutex,
    repair_worker_tasks_processed: std.atomic.Value(u64),
    repair_worker_chunks_processed: std.atomic.Value(u64),
    repair_worker_last_tick_ms: std.atomic.Value(i64),

    mt_flusher: ?*zigstore.Worker,

    subtree_cache: subtree_mod.SubtreeCache,

    url_bloom: bloom.BloomFilter,

    next_category_id: std.atomic.Value(u64),
    next_link_id: std.atomic.Value(u64),
    next_repair_seq: std.atomic.Value(u64),

    links_pending_count: std.atomic.Value(u64),
    links_approved_count: std.atomic.Value(u64),
    links_rejected_count: std.atomic.Value(u64),

    apply_mutex: std.Thread.Mutex,
    apply_cond: std.Thread.Condition,
    last_applied_seq: u64,

    snapshot_in_progress: std.atomic.Value(bool),

    op_latency: *[256]histogram.AtomicHistogram,

    const Self = @This();

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
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(path);
        const dir = try Self.init(allocator, .{
            .data_dir = path,
            .cache_size_mb = 16,
            .thread_count = 1,
            .wal_batch_size = 32,
            .snapshot_interval_s = 3600,
        });
        return dir;
    }

    pub fn deinitTestInstance(self: *Self) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        self.deinit();
        allocator.free(data_dir);
    }

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        const store = try Store.init(allocator, .{
            .data_dir = config.data_dir,
            .cache_size_mb = config.cache_size_mb,
            .wal_batch_size = config.wal_batch_size,
        });
        errdefer store.deinit();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var url_bloom = try bloom.BloomFilter.init(allocator, 1_000_000);
        errdefer url_bloom.deinit();

        const op_latency = blk: {
            const arr = try allocator.create([256]histogram.AtomicHistogram);
            for (arr) |*h| h.* = .{};
            break :blk arr;
        };
        errdefer allocator.destroy(op_latency);

        const verifier_interval_ns = blk: {
            const env = std.posix.getenv("DMOZDB_VERIFIER_INTERVAL_S") orelse break :blk 300 * std.time.ns_per_s;
            const secs = std.fmt.parseInt(u32, env, 10) catch 300;
            break :blk @as(u64, secs) * std.time.ns_per_s;
        };

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .store = store,
            .verifier_state = .{},
            .verifier_worker = null,
            .verifier_interval_ns = verifier_interval_ns,
            .repair_worker = null,
            .repair_worker_mutex = .{},
            .repair_worker_tasks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_chunks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_last_tick_ms = std.atomic.Value(i64).init(0),
            .mt_flusher = null,
            .subtree_cache = subtree_mod.SubtreeCache.init(allocator),
            .url_bloom = url_bloom,
            .next_category_id = std.atomic.Value(u64).init(store.counter("next_category_id").*),
            .next_link_id = std.atomic.Value(u64).init(store.counter("next_link_id").*),
            .next_repair_seq = std.atomic.Value(u64).init(store.counter("next_repair_seq").*),
            .links_pending_count = std.atomic.Value(u64).init(0),
            .links_approved_count = std.atomic.Value(u64).init(0),
            .links_rejected_count = std.atomic.Value(u64).init(0),
            .apply_mutex = .{},
            .apply_cond = .{},
            .last_applied_seq = if (store.wal_writer) |w| w.sequence else 0,
            .snapshot_in_progress = std.atomic.Value(bool).init(false),
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
            .interval_ns = 5 * std.time.ns_per_ms,
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
    }

    fn asDir(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }

    fn flushTick(ctx: *anyopaque) anyerror!void {
        asDir(ctx).drainAllMemtables();
    }

    fn verifyTick(ctx: *anyopaque) anyerror!void {
        const self = asDir(ctx);
        try verifier.runOnce(self, &self.verifier_state);
    }

    fn repairTick(ctx: *anyopaque) anyerror!void {
        try repair_worker.tickOnce(asDir(ctx));
    }

    pub fn commit(self: *Self, cs: changeset.ChangeSet) !void {
        return @import("commit.zig").commit(self, cs);
    }

    pub fn signalMemtableFlusher(self: *Self) void {
        self.drainAllMemtables();
    }

    pub fn drainAllMemtables(self: *Self) void {
        self.store.drainMemtables() catch |err| {
            log.err("memtable drain failed: {} — aborting to preserve WAL/B+Tree consistency", .{err});
            @panic("memtable drain failure");
        };
    }

    pub fn drainOneMemtable(self: *Self, mt: *zigstore.MemTable, tree: *zigstore.BPlusTree) void {
        self.store.mt_drain_mutex.lock();
        defer self.store.mt_drain_mutex.unlock();
        drainOneInner(mt, tree);
    }

    fn drainOneInner(mt: *zigstore.MemTable, tree: *zigstore.BPlusTree) void {
        const NUM_SHARDS = memtable.NUM_SHARDS;
        mt.lockAll();
        var backs: [NUM_SHARDS]*zigstore.MemTable.Buffer = undefined;
        for (0..NUM_SHARDS) |i| backs[i] = mt.swapShardLocked(i);
        mt.unlockAll();

        for (0..NUM_SHARDS) |i| {
            var it = backs[i].map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                if (val.tombstone) {
                    _ = tree.delete(key) catch |err| {
                        log.err("memtable drain: delete failed: {} — aborting to preserve WAL/B+Tree consistency", .{err});
                        @panic("memtable drain delete failure");
                    };
                } else {
                    tree.insert(key, val.value) catch |err| {
                        log.err("memtable drain: insert failed: {} — aborting to preserve WAL/B+Tree consistency", .{err});
                        @panic("memtable drain insert failure");
                    };
                }
            }
        }

        mt.lockAll();
        for (0..memtable.NUM_SHARDS) |i| mt.resetShardBackLocked(i);
        mt.unlockAll();
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
        if (self.repair_worker) |w| w.stop();
        if (self.verifier_worker) |w| w.stop();
        if (self.mt_flusher) |w| w.stop();

        if (persist) {
            self.drainAllMemtables();

            var data_durable = true;
            self.store.cache.flushAll() catch |err| {
                log.err("Failed to flush page cache on shutdown: {}", .{err});
                data_durable = false;
            };

            self.flushHeader() catch |err| {
                log.err("Failed to flush header on shutdown: {}", .{err});
                data_durable = false;
            };

            if (self.store.wal_writer) |*w| {
                if (data_durable) {
                    w.truncateAfterCheckpoint() catch |err| {
                        log.warn("WAL truncate on shutdown failed: {} — recovery will replay on next boot", .{err});
                    };
                } else {
                    log.warn("Skipping WAL truncate: data flush failed — recovery will replay on next boot", .{});
                }
            }
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
            self.store.file.close();
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
            .on_replayed = &recomputeCounts,
            .bootstrap = &bootstrapRoots,
        });

        @import("operations/operations.zig").recountLinkStatuses(self) catch |err| {
            log.warn("recountLinkStatuses failed: {} — counts_by_status may read stale until next boot", .{err});
        };

        log.info("recover: complete; ready to listen", .{});
    }

    fn applyEntry(ctx: *anyopaque, entry: zigstore.ReplayEntry) anyerror!void {
        const self = asDir(ctx);
        var applier = wal_apply.WalApplier{ .db = self };
        try applier.apply(entry);
    }

    fn recomputeCounts(ctx: *anyopaque) anyerror!void {
        const self = asDir(ctx);
        syncCounterUp(&self.next_category_id, self.store.counter("next_category_id").*);
        syncCounterUp(&self.next_link_id, self.store.counter("next_link_id").*);
        syncCounterUp(&self.next_repair_seq, self.store.counter("next_repair_seq").*);

        @import("operations/operations.zig").recomputeCategoryCounts(self) catch |err| {
            log.warn("recomputeCategoryCounts failed: {} — category counts may be off until reconciled", .{err});
        };
    }

    fn syncCounterUp(atomic: *std.atomic.Value(u64), persisted: u64) void {
        atomic.store(@max(atomic.load(.monotonic), persisted), .monotonic);
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

    pub fn flushHeader(self: *Self) !void {
        self.store.counter("next_category_id").* = self.next_category_id.load(.monotonic);
        self.store.counter("next_link_id").* = self.next_link_id.load(.monotonic);
        self.store.counter("next_repair_seq").* = self.next_repair_seq.load(.monotonic);
        try self.store.flushHeader();
    }

    pub fn getStats(self: *Self) Stats {
        self.drainOneMemtable(self.mt_categories_by_id(), self.categories_by_id());
        self.drainOneMemtable(self.mt_links_by_id(), self.links_by_id());

        const hits = self.store.cache.hit_count.load(.monotonic);
        const misses = self.store.cache.miss_count.load(.monotonic);
        const cache_total = hits + misses;
        const hit_rate: f64 = if (cache_total > 0)
            @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(cache_total))
        else
            0.0;

        const cat_count = self.categories_by_id().entryCount();
        const link_count = self.links_by_id().entryCount();
        const pg_count = blk: {
            self.store.cache.alloc_lock.lock();
            defer self.store.cache.alloc_lock.unlock();
            break :blk self.store.cache.page_count;
        };

        const wal_pending: u64 = if (self.store.wal_writer) |*w| blk: {
            w.lock.lock();
            defer w.lock.unlock();
            break :blk w.entry_count;
        } else 0;

        return Stats{
            .category_count = cat_count,
            .link_count = link_count,
            .page_count = pg_count,
            .free_page_count = 0,
            .cache_hits = hits,
            .cache_misses = misses,
            .cache_hit_rate = hit_rate,
            .wal_pending_batch_entries = wal_pending,
        };
    }
};

test "openTestInstance: round-trips entry_count through flushHeader/init" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var dir = try Directory.openTestInstance(std.testing.allocator, &tmp);
        defer dir.deinitTestInstance();

        const ops = @import("operations/operations.zig");
        const cat_id = try ops.createCategory(dir, 0, "Test", "test", "");
        try std.testing.expect(cat_id > 0);
        dir.drainOneMemtable(dir.mt_categories_by_id(), dir.categories_by_id());
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
        try dir.flushHeader();
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
        const top_id = try ops.createCategory(dir, 0, "Top", "top", "");
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
