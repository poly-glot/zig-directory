const std = @import("std");
const page_mod = @import("page.zig");
const file_header = @import("file_header.zig");
const btree = @import("btree/btree.zig");
const page_cache = @import("page_cache.zig");
const freelist = @import("freelist.zig");
const memtable = @import("memtable.zig");
const bloom = @import("bloom.zig");
const wal_mod = @import("wal/wal.zig");
const wal_replay = @import("wal/wal_replay.zig");
const wal_apply = @import("wal/wal_apply.zig");
const snapshot = @import("snapshot.zig");
const Config = @import("main.zig").Config;

const log = std.log.scoped(.database);

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

pub const Database = struct {
    allocator: std.mem.Allocator,
    config: Config,
    file: std.fs.File,
    header: file_header.FileHeader,
    cache: page_cache.PageCache,
    free_list: freelist.FreeList,

    categories_by_id: btree.BPlusTree,
    cat_by_parent: btree.BPlusTree,
    links_by_id: btree.BPlusTree,
    link_by_category: btree.BPlusTree,
    link_by_url_hash: btree.BPlusTree,
    link_by_submitter: btree.BPlusTree,

    categories_by_slug_path: btree.BPlusTree,
    categories_by_slug_only: btree.BPlusTree,
    categories_index_tree: btree.BPlusTree,
    links_index_tree: btree.BPlusTree,

    slug_path_repair_queue: btree.BPlusTree,

    mt_categories_by_id: memtable.MemTable,
    mt_cat_by_parent: memtable.MemTable,
    mt_links_by_id: memtable.MemTable,
    mt_link_by_category: memtable.MemTable,
    mt_link_by_url_hash: memtable.MemTable,
    mt_link_by_submitter: memtable.MemTable,

    mt_flusher: ?std.Thread,
    mt_flusher_shutdown: std.atomic.Value(bool),
    mt_flusher_cond: std.Thread.Condition,
    mt_flusher_mutex: std.Thread.Mutex,
    mt_drain_mutex: std.Thread.Mutex,

    verifier_state: @import("verifier.zig").VerifierState,
    verifier_thread: ?std.Thread,
    verifier_shutdown: std.atomic.Value(bool),
    verifier_interval_ns: u64,
    verifier_cond: std.Thread.Condition,
    verifier_mutex: std.Thread.Mutex,

    repair_worker_thread: ?std.Thread,
    repair_worker_shutdown: std.atomic.Value(bool),
    repair_worker_mutex: std.Thread.Mutex,
    repair_worker_tasks_processed: std.atomic.Value(u64),
    repair_worker_chunks_processed: std.atomic.Value(u64),
    repair_worker_last_tick_ms: std.atomic.Value(i64),

    subtree_cache: @import("subtree.zig").SubtreeCache,

    url_bloom: bloom.BloomFilter,

    wal_writer: ?wal_mod.WalWriter,

    next_category_id: std.atomic.Value(u64),
    next_link_id: std.atomic.Value(u64),

    next_repair_seq: std.atomic.Value(u64),

    links_pending_count: std.atomic.Value(u64),
    links_approved_count: std.atomic.Value(u64),
    links_rejected_count: std.atomic.Value(u64),

    header_lock: std.Thread.Mutex,

    apply_mutex: std.Thread.Mutex,
    apply_cond: std.Thread.Condition,
    last_applied_seq: u64,

    snapshot_in_progress: std.atomic.Value(bool),

    op_latency: *[256]@import("histogram.zig").AtomicHistogram,

    const Self = @This();

    const tree_fields = .{
        .{ "categories_by_id", "category_root", "categories_by_id_count" },
        .{ "cat_by_parent", "cat_by_parent_root", "cat_by_parent_count" },
        .{ "links_by_id", "link_root", "links_by_id_count" },
        .{ "link_by_category", "link_by_category_root", "link_by_category_count" },
        .{ "link_by_url_hash", "link_by_url_hash_root", "link_by_url_hash_count" },
        .{ "link_by_submitter", "link_by_submitter_root", "link_by_submitter_count" },
        .{ "categories_by_slug_path", "categories_by_slug_path_root", "categories_by_slug_path_count" },
        .{ "categories_by_slug_only", "categories_by_slug_only_root", "categories_by_slug_only_count" },
        .{ "categories_index_tree", "categories_index_root", "categories_index_count" },
        .{ "links_index_tree", "links_index_root", "links_index_count" },
        .{ "slug_path_repair_queue", "slug_path_repair_queue_root", "slug_path_repair_queue_count" },
    };

    pub fn openTestInstance(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir) !*Self {
        const path = try tmp.dir.realpathAlloc(allocator, ".");
        errdefer allocator.free(path);
        const db = try Self.init(allocator, .{
            .data_dir = path,
            .cache_size_mb = 16,
            .thread_count = 1,
            .wal_batch_size = 32,
            .snapshot_interval_s = 3600,
        });
        return db;
    }

    pub fn deinitTestInstance(self: *Self) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        self.deinit();
        allocator.free(data_dir);
    }

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        std.fs.makeDirAbsolute(config.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const path = try std.fmt.allocPrint(allocator, "{s}/dmozdb.dat", .{config.data_dir});
        defer allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();

        const file_size = (try file.stat()).size;
        const is_new = file_size == 0;

        var header: file_header.FileHeader = undefined;
        if (is_new) {
            header = file_header.FileHeader.init();

            header.category_root = 1;
            header.cat_by_parent_root = 2;
            header.link_root = 3;
            header.link_by_category_root = 4;
            header.link_by_url_hash_root = 5;
            header.slug_path_repair_queue_root = 6;
            header.link_by_submitter_root = 7;
            header.page_count = 8;

            const header_bytes = header.serialize();
            try file.seekTo(0);
            try file.writeAll(&header_bytes);

            var empty_page: page_mod.Page = undefined;
            inline for (1..8) |pid| {
                page_mod.initLeaf(&empty_page, pid);
                const page_bytes = std.mem.asBytes(&empty_page);
                try file.seekTo(pid * page_mod.PAGE_SIZE);
                try file.writeAll(page_bytes);
            }

            try file.sync();
            log.info("Created new database file with {d} initial pages", .{header.page_count});
        } else {
            try file.seekTo(0);
            var header_buf: [page_mod.PAGE_SIZE]u8 = undefined;
            const bytes_read = try file.readAll(&header_buf);
            if (bytes_read < @sizeOf(file_header.FileHeader)) {
                return error.UnexpectedEof;
            }
            header = file_header.FileHeader.deserialize(&header_buf);

            header.validate() catch |err| {
                log.warn("Primary header validation failed: {}, trying backup", .{err});
                const bak_path = try std.fmt.allocPrint(allocator, "{s}/dmozdb.hdr.bak", .{config.data_dir});
                defer allocator.free(bak_path);

                const bak_file = std.fs.cwd().openFile(bak_path, .{ .mode = .read_only }) catch {
                    log.err("No backup header found, cannot recover", .{});
                    return err;
                };
                defer bak_file.close();

                var bak_buf: [page_mod.PAGE_SIZE]u8 = undefined;
                const bak_read = bak_file.readAll(&bak_buf) catch {
                    return err;
                };
                if (bak_read < @sizeOf(file_header.FileHeader)) return err;

                header = file_header.FileHeader.deserialize(&bak_buf);
                try header.validate();
                log.info("Recovered from backup header", .{});

                try file.seekTo(0);
                try file.writeAll(&bak_buf);
                try file.sync();
            };

            log.info("Opened existing database: {d} categories, {d} links, {d} pages", .{
                header.next_category_id -| 1,
                header.next_link_id -| 1,
                header.page_count,
            });
        }

        const cache_pages = (config.cache_size_mb * 1024 * 1024) / page_mod.PAGE_SIZE;
        var cache = try page_cache.PageCache.init(allocator, file, cache_pages);
        errdefer cache.deinit();

        var wal_writer = wal_mod.WalWriter.init(allocator, config.data_dir, config.wal_batch_size) catch |err| blk: {
            log.warn("Failed to open WAL file: {}, continuing without WAL", .{err});
            break :blk null;
        };
        errdefer if (wal_writer) |*w| w.deinit();

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var url_bloom = try bloom.BloomFilter.init(allocator, 1_000_000);
        errdefer url_bloom.deinit();

        const op_latency = blk: {
            const histogram = @import("histogram.zig");
            const arr = try allocator.create([256]histogram.AtomicHistogram);
            for (arr) |*h| h.* = .{};
            break :blk arr;
        };
        errdefer allocator.destroy(op_latency);

        self.* = Self{
            .allocator = allocator,
            .config = config,
            .file = file,
            .header = header,
            .cache = cache,
            .free_list = .{ .head = header.free_list_head, .cache = undefined, .mutex = .{} },
            .categories_by_id = .{ .cache = undefined, .free_list = undefined, .root_page = header.category_root, .lock = .{} },
            .cat_by_parent = .{ .cache = undefined, .free_list = undefined, .root_page = header.cat_by_parent_root, .lock = .{} },
            .links_by_id = .{ .cache = undefined, .free_list = undefined, .root_page = header.link_root, .lock = .{} },
            .link_by_category = .{ .cache = undefined, .free_list = undefined, .root_page = header.link_by_category_root, .lock = .{} },
            .link_by_url_hash = .{ .cache = undefined, .free_list = undefined, .root_page = header.link_by_url_hash_root, .lock = .{} },
            .link_by_submitter = .{ .cache = undefined, .free_list = undefined, .root_page = header.link_by_submitter_root, .lock = .{} },
            .categories_by_slug_path = .{ .cache = undefined, .free_list = undefined, .root_page = header.categories_by_slug_path_root, .lock = .{} },
            .categories_by_slug_only = .{ .cache = undefined, .free_list = undefined, .root_page = header.categories_by_slug_only_root, .lock = .{} },
            .categories_index_tree = .{ .cache = undefined, .free_list = undefined, .root_page = header.categories_index_root, .lock = .{} },
            .links_index_tree = .{ .cache = undefined, .free_list = undefined, .root_page = header.links_index_root, .lock = .{} },
            .slug_path_repair_queue = .{ .cache = undefined, .free_list = undefined, .root_page = header.slug_path_repair_queue_root, .lock = .{} },
            .mt_categories_by_id = memtable.MemTable.init(allocator),
            .mt_cat_by_parent = memtable.MemTable.init(allocator),
            .mt_links_by_id = memtable.MemTable.init(allocator),
            .mt_link_by_category = memtable.MemTable.init(allocator),
            .mt_link_by_url_hash = memtable.MemTable.init(allocator),
            .mt_link_by_submitter = memtable.MemTable.init(allocator),
            .mt_flusher = null,
            .mt_flusher_shutdown = std.atomic.Value(bool).init(false),
            .mt_flusher_cond = .{},
            .mt_flusher_mutex = .{},
            .mt_drain_mutex = .{},
            .verifier_state = .{},
            .verifier_thread = null,
            .verifier_shutdown = std.atomic.Value(bool).init(false),
            .verifier_interval_ns = blk: {
                const env = std.posix.getenv("DMOZDB_VERIFIER_INTERVAL_S") orelse break :blk 300 * std.time.ns_per_s;
                const secs = std.fmt.parseInt(u32, env, 10) catch 300;
                break :blk @as(u64, secs) * std.time.ns_per_s;
            },
            .verifier_cond = .{},
            .verifier_mutex = .{},
            .repair_worker_thread = null,
            .repair_worker_shutdown = std.atomic.Value(bool).init(false),
            .repair_worker_mutex = .{},
            .repair_worker_tasks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_chunks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_last_tick_ms = std.atomic.Value(i64).init(0),
            .subtree_cache = @import("subtree.zig").SubtreeCache.init(allocator),
            .url_bloom = url_bloom,
            .wal_writer = wal_writer,
            .next_category_id = std.atomic.Value(u64).init(header.next_category_id),
            .next_link_id = std.atomic.Value(u64).init(header.next_link_id),
            .next_repair_seq = std.atomic.Value(u64).init(header.next_repair_seq),
            .links_pending_count = std.atomic.Value(u64).init(0),
            .links_approved_count = std.atomic.Value(u64).init(0),
            .links_rejected_count = std.atomic.Value(u64).init(0),
            .header_lock = .{},
            .apply_mutex = .{},
            .apply_cond = .{},
            .last_applied_seq = if (wal_writer) |w| w.sequence else 0,
            .snapshot_in_progress = std.atomic.Value(bool).init(false),
            .op_latency = op_latency,
        };

        self.free_list.cache = &self.cache;
        inline for (tree_fields) |entry| {
            @field(self, entry[0]).cache = &self.cache;
            @field(self, entry[0]).free_list = &self.free_list;
            @field(self, entry[0]).entry_count = @field(self.header, entry[2]);
        }

        if (self.wal_writer) |*w| {
            w.startFlusher() catch |err| {
                log.warn("WAL flusher thread failed to start: {}", .{err});
            };
        }

        return self;
    }

    pub fn startBackgroundThreads(self: *Self) void {
        self.mt_flusher = std.Thread.spawn(.{}, memtableFlusherLoop, .{self}) catch blk: {
            log.warn("Memtable flusher thread failed to start", .{});
            break :blk null;
        };
        self.verifier_thread = std.Thread.spawn(.{}, verifierLoop, .{self}) catch null;
        self.repair_worker_thread = std.Thread.spawn(
            .{},
            @import("repair/repair_worker.zig").loop,
            .{self},
        ) catch null;
    }

    pub fn commit(self: *Self, cs: @import("changeset.zig").ChangeSet) !void {
        return @import("commit.zig").commit(self, cs);
    }

    fn memtableFlusherLoop(self: *Self) void {
        while (true) {
            self.mt_flusher_mutex.lock();
            const should_stop = self.mt_flusher_shutdown.load(.acquire);
            if (!should_stop) {
                self.mt_flusher_cond.timedWait(
                    &self.mt_flusher_mutex,
                    5 * std.time.ns_per_ms,
                ) catch {};
            }
            self.mt_flusher_mutex.unlock();

            if (self.mt_flusher_shutdown.load(.acquire)) break;
            self.drainAllMemtables();
        }
        self.drainAllMemtables();
    }

    pub fn signalMemtableFlusher(self: *Self) void {
        self.mt_flusher_mutex.lock();
        defer self.mt_flusher_mutex.unlock();
        self.mt_flusher_cond.signal();
    }

    pub fn drainAllMemtables(self: *Self) void {
        self.mt_drain_mutex.lock();
        defer self.mt_drain_mutex.unlock();
        self.drainAllMemtablesInner();
    }

    fn drainAllMemtablesInner(self: *Self) void {
        const mts = [_]*memtable.MemTable{
            &self.mt_categories_by_id,
            &self.mt_cat_by_parent,
            &self.mt_links_by_id,
            &self.mt_link_by_category,
            &self.mt_link_by_url_hash,
            &self.mt_link_by_submitter,
        };
        const trees = [_]*btree.BPlusTree{
            &self.categories_by_id,
            &self.cat_by_parent,
            &self.links_by_id,
            &self.link_by_category,
            &self.link_by_url_hash,
            &self.link_by_submitter,
        };

        for (mts, 0..) |mt, mi| {
            drainOneInner(self, mt, trees[mi]);
        }
    }

    pub fn drainOneMemtable(self: *Self, mt: *memtable.MemTable, tree: *btree.BPlusTree) void {
        self.mt_drain_mutex.lock();
        defer self.mt_drain_mutex.unlock();
        drainOneInner(self, mt, tree);
    }

    fn drainOneInner(_: *Self, mt: *memtable.MemTable, tree: *btree.BPlusTree) void {
        mt.lockAll();
        var backs: [memtable.NUM_SHARDS]*memtable.MemTable.Buffer = undefined;
        for (0..memtable.NUM_SHARDS) |i| backs[i] = mt.swapShardLocked(i);
        mt.unlockAll();

        for (0..memtable.NUM_SHARDS) |i| {
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

    fn verifierLoop(self: *Self) void {
        const verifier = @import("verifier.zig");
        while (true) {
            self.verifier_mutex.lock();
            const should_stop = self.verifier_shutdown.load(.acquire);
            if (!should_stop) {
                self.verifier_cond.timedWait(
                    &self.verifier_mutex,
                    self.verifier_interval_ns,
                ) catch {};
            }
            self.verifier_mutex.unlock();

            if (self.verifier_shutdown.load(.acquire)) break;
            verifier.runOnce(self, &self.verifier_state) catch |err| {
                log.warn("verifier run failed: {}", .{err});
            };
        }
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
        self.repair_worker_shutdown.store(true, .release);
        if (self.repair_worker_thread) |t| t.join();

        self.verifier_mutex.lock();
        self.verifier_shutdown.store(true, .release);
        self.verifier_cond.signal();
        self.verifier_mutex.unlock();
        if (self.verifier_thread) |t| t.join();
        self.mt_flusher_mutex.lock();
        self.mt_flusher_shutdown.store(true, .release);
        self.mt_flusher_cond.signal();
        self.mt_flusher_mutex.unlock();
        if (self.mt_flusher) |t| t.join();

        if (persist) {
            self.drainAllMemtables();

            var data_durable = true;
            self.cache.flushAll() catch |err| {
                log.err("Failed to flush page cache on shutdown: {}", .{err});
                data_durable = false;
            };

            self.flushHeader() catch |err| {
                log.err("Failed to flush header on shutdown: {}", .{err});
                data_durable = false;
            };

            if (self.wal_writer) |*w| {
                if (data_durable) {
                    w.truncateAfterCheckpoint() catch |err| {
                        log.warn("WAL truncate on shutdown failed: {} — recovery will replay on next boot", .{err});
                    };
                } else {
                    log.warn("Skipping WAL truncate: data flush failed — recovery will replay on next boot", .{});
                }
            }
        }

        if (self.wal_writer) |*w| w.deinit();

        self.url_bloom.deinit();
        self.subtree_cache.deinit();
        self.mt_categories_by_id.deinit();
        self.mt_cat_by_parent.deinit();
        self.mt_links_by_id.deinit();
        self.mt_link_by_category.deinit();
        self.mt_link_by_url_hash.deinit();
        self.mt_link_by_submitter.deinit();
        self.cache.deinit();
        self.file.close();

        const allocator = self.allocator;
        allocator.destroy(self.op_latency);
        allocator.destroy(self);
    }

    pub fn recover(self: *Self) !void {
        const min_seq = snapshot.SnapshotManager.getWalSequence(self.config.data_dir) catch 0;

        var applier = wal_apply.WalApplier{ .db = self };
        const last_seq = wal_replay.replayWal(self.config.data_dir, min_seq, &applier) catch |err| {
            log.err("WAL replay failed at sequence > {d}: {}. Aborting boot — see /admin/integrity for the path forward.", .{ min_seq, err });
            return err;
        };

        if (last_seq > 0) {
            log.info("WAL replay complete: applied entries up to sequence {d}", .{last_seq});
            self.next_category_id.store(self.header.next_category_id, .monotonic);
            self.next_link_id.store(self.header.next_link_id, .monotonic);
            self.next_repair_seq.store(self.header.next_repair_seq, .monotonic);

            @import("operations/operations.zig").recomputeCategoryCounts(self) catch |err| {
                log.warn("recomputeCategoryCounts failed: {} — category counts may be off until reconciled", .{err});
            };
            self.drainAllMemtables();

            self.cache.flushAll() catch |err| {
                log.err("Failed to flush after WAL replay: {}", .{err});
            };
            self.flushHeader() catch |err| {
                log.err("Failed to flush header after WAL replay: {}", .{err});
            };
        }

        if (self.categories_by_id.entry_count == 0) {
            try self.bootstrapRootCategories();
        }

        @import("operations/operations.zig").recountLinkStatuses(self) catch |err| {
            log.warn("recountLinkStatuses failed: {} — counts_by_status may read stale until next boot", .{err});
        };

        log.info("recover: complete; ready to listen", .{});
    }

    fn bootstrapRootCategories(self: *Self) !void {
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
        self.header_lock.lock();
        defer self.header_lock.unlock();

        inline for (tree_fields) |entry| {
            @field(self.header, entry[1]) = @field(self, entry[0]).root_page;
            @field(self.header, entry[2]) = @field(self, entry[0]).entry_count;
        }
        self.header.free_list_head = self.free_list.getHead();
        self.header.next_category_id = self.next_category_id.load(.monotonic);
        self.header.next_link_id = self.next_link_id.load(.monotonic);
        self.header.next_repair_seq = self.next_repair_seq.load(.monotonic);
        self.cache.alloc_lock.lock();
        self.header.page_count = self.cache.page_count;
        self.cache.alloc_lock.unlock();

        const header_bytes = self.header.serialize();

        self.writeBackupHeader(&header_bytes) catch |err| {
            log.warn("Failed to write backup header: {}", .{err});
        };

        try self.file.seekTo(0);
        try self.file.writeAll(&header_bytes);
        try self.file.sync();
    }

    fn writeBackupHeader(self: *Self, header_bytes: []const u8) !void {
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}/dmozdb.hdr.tmp", .{self.config.data_dir});
        defer self.allocator.free(tmp_path);
        const bak_path = try std.fmt.allocPrint(self.allocator, "{s}/dmozdb.hdr.bak", .{self.config.data_dir});
        defer self.allocator.free(bak_path);

        {
            const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer tmp_file.close();
            try tmp_file.writeAll(header_bytes);
            try tmp_file.sync();
        }

        std.fs.cwd().rename(tmp_path, bak_path) catch |err| {
            log.warn("Failed to rename backup header: {}", .{err});
        };
    }

    pub fn getStats(self: *Self) Stats {
        self.drainOneMemtable(&self.mt_categories_by_id, &self.categories_by_id);
        self.drainOneMemtable(&self.mt_links_by_id, &self.links_by_id);

        const hits = self.cache.hit_count.load(.monotonic);
        const misses = self.cache.miss_count.load(.monotonic);
        const cache_total = hits + misses;
        const hit_rate: f64 = if (cache_total > 0)
            @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(cache_total))
        else
            0.0;

        const cat_count = self.categories_by_id.entry_count;
        const link_count = self.links_by_id.entry_count;
        const pg_count = blk: {
            self.cache.alloc_lock.lock();
            defer self.cache.alloc_lock.unlock();
            break :blk self.cache.page_count;
        };

        const wal_pending: u64 = if (self.wal_writer) |*w| blk: {
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
        var db = try Database.openTestInstance(std.testing.allocator, &tmp);
        defer db.deinitTestInstance();

        const ops = @import("operations/operations.zig");
        const cat_id = try ops.createCategory(db, 0, "Test", "test", "");
        try std.testing.expect(cat_id > 0);
        db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
        try std.testing.expect(db.categories_by_id.entry_count >= 1);
    }

    {
        var db = try Database.openTestInstance(std.testing.allocator, &tmp);
        defer db.deinitTestInstance();

        try std.testing.expect(db.header.categories_by_id_count >= 1);
        try std.testing.expect(db.categories_by_id.entry_count >= 1);
    }
}

test "Database: slug_path_repair_queue field exists and is empty after init" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
}

test "next_repair_seq: persists across reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        _ = db.next_repair_seq.fetchAdd(1, .monotonic);
        _ = db.next_repair_seq.fetchAdd(1, .monotonic);
        _ = db.next_repair_seq.fetchAdd(1, .monotonic);
        try db.flushHeader();
    }
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try std.testing.expectEqual(@as(u64, 4), db.next_repair_seq.load(.monotonic));
    }
}

test "recover boot path: clean DB reopens cleanly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try db.recover();
        const ops = @import("operations/operations.zig");
        const top_id = try ops.createCategory(db, 0, "Top", "top", "");
        _ = try ops.createCategory(db, top_id, "Arts", "arts", "");
    }

    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try db.recover();
        const ops = @import("operations/operations.zig");
        const id = try ops.resolveSlugPath(db, "arts");
        try std.testing.expect(id != null);
    }
}
