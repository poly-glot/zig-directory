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
    /// Number of WAL entries in the current (unflushed) batch, not total entries written.
    wal_pending_batch_entries: u64 = 0,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    config: Config,
    file: std.fs.File,
    header: file_header.FileHeader,
    cache: page_cache.PageCache,
    free_list: freelist.FreeList,

    // B+Tree indices
    categories_by_id: btree.BPlusTree,
    cat_by_parent: btree.BPlusTree,
    links_by_id: btree.BPlusTree,
    link_by_category: btree.BPlusTree,
    link_by_url_hash: btree.BPlusTree,
    link_by_submitter: btree.BPlusTree,

    // On-disk indexing trees: two slug lookups + token postings for
    // categories and links.
    categories_by_slug_path: btree.BPlusTree,
    categories_by_slug_only: btree.BPlusTree,
    categories_index_tree: btree.BPlusTree,
    links_index_tree: btree.BPlusTree,

    /// Slug-path repair queue (v4). Drained by repair_worker.
    slug_path_repair_queue: btree.BPlusTree,

    // MemTables — write buffers in front of each B+Tree.
    mt_categories_by_id: memtable.MemTable,
    mt_cat_by_parent: memtable.MemTable,
    mt_links_by_id: memtable.MemTable,
    mt_link_by_category: memtable.MemTable,
    mt_link_by_url_hash: memtable.MemTable,
    mt_link_by_submitter: memtable.MemTable,

    // Memtable flusher thread.
    mt_flusher: ?std.Thread,
    mt_flusher_shutdown: std.atomic.Value(bool),
    mt_flusher_cond: std.Thread.Condition,
    mt_flusher_mutex: std.Thread.Mutex,
    /// Guards drainOneMemtable/drainAllMemtables against concurrent execution.
    mt_drain_mutex: std.Thread.Mutex,

    /// Periodic integrity verifier — see src/verifier.zig.
    verifier_state: @import("verifier.zig").VerifierState,
    verifier_thread: ?std.Thread,
    verifier_shutdown: std.atomic.Value(bool),
    verifier_interval_ns: u64,
    /// Wakes the verifier thread on shutdown so it doesn't run out
    /// the full sleep interval before noticing the shutdown flag.
    verifier_cond: std.Thread.Condition,
    verifier_mutex: std.Thread.Mutex,

    /// Background drainer for `slug_path_repair_queue` — see
    /// src/repair_worker.zig. The interval-bound sleep is
    /// uninterruptible; deinit signals shutdown and joins, accepting up
    /// to one full interval of wait. This is acceptable given the
    /// default 1 s tick.
    repair_worker_thread: ?std.Thread,
    repair_worker_shutdown: std.atomic.Value(bool),
    /// Observability counters surfaced through op 18 `index_health`.
    /// Bumped by the repair worker; read by the binary-protocol handler.
    repair_worker_tasks_processed: std.atomic.Value(u64),
    repair_worker_chunks_processed: std.atomic.Value(u64),
    repair_worker_last_tick_ms: std.atomic.Value(i64),

    /// Cache of subtree descendant lists and link counts. Shared by
    /// the binary-protocol handlers for browse_path and
    /// list_subtree_links so a hot subtree (e.g. Regional) computes
    /// its descendant set at most once per write epoch.
    subtree_cache: @import("subtree.zig").SubtreeCache,

    // Bloom filter for fast duplicate URL rejection (lock-free).
    url_bloom: bloom.BloomFilter,

    // WAL
    wal_writer: ?wal_mod.WalWriter,

    /// Atomic ID counters — lock-free for the hot create path.
    /// Shadow header.next_category_id / next_link_id and are synced
    /// back into the header on flushHeader().
    next_category_id: std.atomic.Value(u64),
    next_link_id: std.atomic.Value(u64),

    /// Monotonic sequence allocator for `slug_path_repair_queue` keys.
    /// Lock-free; shadows header.next_repair_seq, synced by flushHeader.
    next_repair_seq: std.atomic.Value(u64),

    /// Materialised per-status link totals backing the O(1) op=36
    /// `counts_by_status` read (the admin chip strip on every /admin/links
    /// render). Recomputed from a single full `links_by_id` scan at boot
    /// (`recover` → `recountLinkStatuses`) and then maintained incrementally
    /// by the apply_link hooks (insert / delete / status-change). In-memory
    /// only — deliberately NOT persisted to the header: WAL replay is a
    /// changeset no-op, so the drained data file is the source of truth on
    /// every open and the boot scan reseeds these. That sidesteps the
    /// apply-time-vs-drain-time checkpoint skew that an on-disk counter would
    /// have to reconcile, and guarantees the counters cannot drift across a
    /// restart. Writes happen under `apply_mutex`; readers use atomic loads.
    links_pending_count: std.atomic.Value(u64),
    links_approved_count: std.atomic.Value(u64),
    links_rejected_count: std.atomic.Value(u64),

    /// Guards access to `header` and the underlying `file` seek/write
    /// operations so that `flushHeader` and `getStats` are thread-safe.
    header_lock: std.Thread.Mutex,

    /// Serialises the in-memory `apply` step of commits so that mutations
    /// against memtables / B+Trees observe the same WAL sequence order at
    /// runtime as a recovery-time replay would. Concurrent WAL `append`
    /// calls are serialised by the WAL writer's OWN lock and so do NOT
    /// touch this mutex — only `apply` does. Holding `apply_mutex` while
    /// peers append in the background is what gives the WAL flusher a
    /// fuller batch to fdatasync, recovering most of the group-commit
    /// throughput that a single `write_mutex` lost.
    apply_mutex: std.Thread.Mutex,
    /// Wake-up signal for commits that arrived at `apply_mutex` out of
    /// WAL-seq order. Each commit waits until `last_applied_seq + 1 == seq`,
    /// applies, then broadcasts.
    apply_cond: std.Thread.Condition,
    /// Highest WAL sequence that has finished its in-memory apply.
    /// Protected by `apply_mutex`.
    last_applied_seq: u64,

    /// Single-flight gate for on-demand snapshots (op 22). The periodic
    /// snapshot path runs from a different thread; CAS rejects a second
    /// concurrent caller with `error.SnapshotInProgress`.
    snapshot_in_progress: std.atomic.Value(bool),

    /// Per-op latency histograms — indexed by request op_byte. Records
    /// the wall-clock time each handler invocation took so op 23
    /// `op_latency_stats` can surface server-side p50/p95/p99 alongside
    /// the client-side bench numbers. Stored heap-side because the
    /// 256-entry array is ~4 MB; embedding it inline would inflate
    /// every test instance and stack frame that touches Database.
    op_latency: *[256]@import("histogram.zig").AtomicHistogram,

    const Self = @This();

    /// B+Tree field names paired with their corresponding header root
    /// fields and the per-tree entry-count fields. The triple is
    /// (tree_field, root_field, count_field) — used by Database.init,
    /// flushHeader, and the rest of the wiring so any new tree gets
    /// its count slot in lockstep.
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

    /// Open a Database rooted at the supplied tmpDir for unit tests.
    ///
    /// Wraps `Database.init` with a config pointing at the tmpDir's real
    /// path. Pair with `deinitTestInstance` so the duped `data_dir`
    /// slice is freed (regular `deinit` does not free `config.data_dir`
    /// — production `main.zig` keeps it alive for the process lifetime).
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

    /// Companion to `openTestInstance`: tears down the database and
    /// frees the duped `data_dir` slice.
    pub fn deinitTestInstance(self: *Self) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        self.deinit();
        allocator.free(data_dir);
    }

    /// Open (or create) the database at `{config.data_dir}/dmozdb.dat`.
    /// Returns a heap-allocated Database with stable internal pointers.
    pub fn init(allocator: std.mem.Allocator, config: Config) !*Self {
        // Ensure data directory exists.
        std.fs.makeDirAbsolute(config.data_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        // Build the file path.
        const path = try std.fmt.allocPrint(allocator, "{s}/dmozdb.dat", .{config.data_dir});
        defer allocator.free(path);

        // Open or create the data file.
        const file = try std.fs.createFileAbsolute(path, .{
            .read = true,
            .truncate = false,
        });
        errdefer file.close();

        const file_size = (try file.stat()).size;
        const is_new = file_size == 0;

        // Initialize or read the file header.
        var header: file_header.FileHeader = undefined;
        if (is_new) {
            header = file_header.FileHeader.init();

            // Allocate root pages for each primary B+Tree (pages 1..5),
            // the slug-path repair queue (page 6, v4), and the
            // link-by-submitter index (page 7, v5).
            header.category_root = 1;
            header.cat_by_parent_root = 2;
            header.link_root = 3;
            header.link_by_category_root = 4;
            header.link_by_url_hash_root = 5;
            header.slug_path_repair_queue_root = 6;
            header.link_by_submitter_root = 7;
            header.page_count = 8; // page 0 = header, pages 1-7 = B+Tree roots

            // Write header to page 0.
            const header_bytes = header.serialize();
            try file.seekTo(0);
            try file.writeAll(&header_bytes);

            // Write empty leaf pages for each B+Tree root.
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
            // Read and validate existing header.
            try file.seekTo(0);
            var header_buf: [page_mod.PAGE_SIZE]u8 = undefined;
            const bytes_read = try file.readAll(&header_buf);
            if (bytes_read < @sizeOf(file_header.FileHeader)) {
                return error.UnexpectedEof;
            }
            header = file_header.FileHeader.deserialize(&header_buf);

            header.validate() catch |err| {
                // Primary header is corrupt — try backup header.
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

                // Restore primary header from backup.
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

        // Initialize page cache.
        const cache_pages = (config.cache_size_mb * 1024 * 1024) / page_mod.PAGE_SIZE;
        const cache = try page_cache.PageCache.init(allocator, file, cache_pages);

        // Initialize WAL writer.
        const wal_writer = wal_mod.WalWriter.init(allocator, config.data_dir, config.wal_batch_size) catch |err| blk: {
            log.warn("Failed to open WAL file: {}, continuing without WAL", .{err});
            break :blk null;
        };

        // Heap-allocate to guarantee stable address for internal pointers.
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

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
            .repair_worker_tasks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_chunks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_last_tick_ms = std.atomic.Value(i64).init(0),
            .subtree_cache = @import("subtree.zig").SubtreeCache.init(allocator),
            .url_bloom = try bloom.BloomFilter.init(allocator, 1_000_000),
            .wal_writer = wal_writer,
            .next_category_id = std.atomic.Value(u64).init(header.next_category_id),
            .next_link_id = std.atomic.Value(u64).init(header.next_link_id),
            .next_repair_seq = std.atomic.Value(u64).init(header.next_repair_seq),
            // Seeded for real by recountLinkStatuses at the end of recover();
            // zero is correct for a fresh DB and for tests that skip recover()
            // and build state purely through apply hooks.
            .links_pending_count = std.atomic.Value(u64).init(0),
            .links_approved_count = std.atomic.Value(u64).init(0),
            .links_rejected_count = std.atomic.Value(u64).init(0),
            .header_lock = .{},
            .apply_mutex = .{},
            .apply_cond = .{},
            // Whatever the WAL ended at on boot is the watermark for "no
            // commit needs to wait for me before applying" — by definition
            // all those entries have either been applied via snapshot/drain
            // or are about to be re-applied by recovery (no-op today).
            .last_applied_seq = if (wal_writer) |w| w.sequence else 0,
            .snapshot_in_progress = std.atomic.Value(bool).init(false),
            .op_latency = blk: {
                const histogram = @import("histogram.zig");
                const arr = try allocator.create([256]histogram.AtomicHistogram);
                for (arr) |*h| h.* = .{};
                break :blk arr;
            },
        };

        // Wire up internal pointers now that the struct is at its final address.
        self.free_list.cache = &self.cache;
        inline for (tree_fields) |entry| {
            @field(self, entry[0]).cache = &self.cache;
            @field(self, entry[0]).free_list = &self.free_list;
            // Restore the per-tree entry counter from the header.
            // Fresh databases initialise this to zero alongside the empty
            // root page; later commits bump it and flushHeader persists it.
            @field(self, entry[0]).entry_count = @field(self.header, entry[2]);
        }

        // Start the WAL background flusher now that wal_writer is at its
        // final heap address (the flusher thread captures *WalWriter).
        if (self.wal_writer) |*w| {
            w.startFlusher() catch |err| {
                log.warn("WAL flusher thread failed to start: {}", .{err});
            };
        }

        // Background threads (memtable flusher, verifier) are NOT spawned
        // here. They contend for B+Tree locks with the migration in
        // recover() and can starve a long-running phase. Caller invokes
        // startBackgroundThreads after recover() succeeds.
        return self;
    }

    /// Spawn the memtable flusher and verifier threads. MUST be called
    /// after `recover()` returns — both threads acquire B+Tree locks on
    /// every tick and will starve any single-threaded loop (e.g. a
    /// migration phase) that holds those locks under contention. See
    /// `init` for the rationale on the deferred spawn.
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

    /// Commit a ChangeSet via the group-commit pipeline in `commit.zig`.
    /// See spec §5 (Write path mechanics).
    pub fn commit(self: *Self, cs: @import("changeset.zig").ChangeSet) !void {
        return @import("commit.zig").commit(self, cs);
    }

    /// Background thread: periodically drains memtables to B+Trees.
    fn memtableFlusherLoop(self: *Self) void {
        while (true) {
            // Hold the mutex across the shutdown check + wait so a signal
            // from `signalMemtableFlusher` / `deinit` cannot land between
            // them and be lost.
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
        // Final drain on shutdown.
        self.drainAllMemtables();
    }

    /// Signal the flusher thread to wake up (called when memtable is getting large).
    pub fn signalMemtableFlusher(self: *Self) void {
        self.mt_flusher_mutex.lock();
        defer self.mt_flusher_mutex.unlock();
        self.mt_flusher_cond.signal();
    }

    /// Drain all memtables into their corresponding B+Trees.
    /// Swaps all front/back buffers atomically (under each memtable's lock),
    /// then applies the back buffers to the B+Trees without holding memtable locks.
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

    /// Drain a single sharded memtable into its B+Tree.
    /// Thread-safe: serialized via mt_drain_mutex.
    pub fn drainOneMemtable(self: *Self, mt: *memtable.MemTable, tree: *btree.BPlusTree) void {
        self.mt_drain_mutex.lock();
        defer self.mt_drain_mutex.unlock();
        drainOneInner(self, mt, tree);
    }

    fn drainOneInner(_: *Self, mt: *memtable.MemTable, tree: *btree.BPlusTree) void {
        // Lock all shards, swap, unlock — fast atomic snapshot.
        mt.lockAll();
        var backs: [memtable.NUM_SHARDS]*memtable.MemTable.Buffer = undefined;
        for (0..memtable.NUM_SHARDS) |i| backs[i] = mt.swapShardLocked(i);
        mt.unlockAll();

        // Drain all shard back buffers into the B+Tree.
        //
        // A failure here means the entry is durable in the WAL but absent
        // from the B+Tree — readers would not see it, and the next drain
        // cycle has already cleared it from the memtable. Continuing in
        // that state silently corrupts the user-visible database, so the
        // safe move is to abort: a restart replays the WAL and restores
        // consistency.
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

        // Reset back buffers.
        mt.lockAll();
        for (0..memtable.NUM_SHARDS) |i| mt.resetShardBackLocked(i);
        mt.unlockAll();
    }

    fn verifierLoop(self: *Self) void {
        const verifier = @import("verifier.zig");
        // Wait on a condition variable so deinit can wake us up
        // immediately on shutdown — std.Thread.sleep can't be cancelled,
        // so a plain sleep would force deinit to wait out the full
        // interval (5 min default), which makes unit tests hang.
        // First sleep also avoids racing recover()'s WAL replay.
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

    /// Shut down the database, flushing all state to disk.
    pub fn deinit(self: *Self) void {
        // Stop the repair worker first so it can't issue a fresh
        // db.commit() (which would acquire apply_mutex and dirty pages)
        // while we're tearing down. Its sleep is uninterruptible, so the
        // join may wait up to one repair_worker_interval_ms.
        self.repair_worker_shutdown.store(true, .release);
        if (self.repair_worker_thread) |t| t.join();

        self.verifier_mutex.lock();
        self.verifier_shutdown.store(true, .release);
        self.verifier_cond.signal();
        self.verifier_mutex.unlock();
        if (self.verifier_thread) |t| t.join();
        // Stop memtable flusher thread and drain remaining entries.
        // Set the shutdown flag and signal under the flusher's mutex so
        // the flusher cannot miss the wakeup between its predicate check
        // and timedWait.
        self.mt_flusher_mutex.lock();
        self.mt_flusher_shutdown.store(true, .release);
        self.mt_flusher_cond.signal();
        self.mt_flusher_mutex.unlock();
        if (self.mt_flusher) |t| t.join();
        // Final synchronous drain of any remaining memtable entries.
        self.drainAllMemtables();

        // Flush dirty cache pages before anything else so that all
        // in-memory mutations reach disk.  This must happen before the
        // WAL is closed because a WAL replay on restart expects the
        // data file to be consistent up to the last checkpoint.
        self.cache.flushAll() catch |err| {
            log.err("Failed to flush page cache on shutdown: {}", .{err});
        };

        // Persist the header (page counts, root pages, etc.) after the
        // cache flush so the header reflects the latest state.
        self.flushHeader() catch |err| {
            log.err("Failed to flush header on shutdown: {}", .{err});
        };

        // Data + header are now durable, so every WAL entry is redundant.
        // Truncate the WAL so the next boot has nothing to replay — the
        // existence of these bytes is what makes startup slow.
        if (self.wal_writer) |*w| {
            w.truncateAfterCheckpoint() catch |err| {
                log.warn("WAL truncate on shutdown failed: {} — recovery will replay on next boot", .{err});
            };
            w.deinit();
        }

        self.url_bloom.deinit();
        self.subtree_cache.deinit();
        self.mt_categories_by_id.deinit();
        self.mt_cat_by_parent.deinit();
        self.mt_links_by_id.deinit();
        self.mt_link_by_category.deinit();
        self.mt_link_by_url_hash.deinit();
        self.mt_link_by_submitter.deinit();
        // FreeList is backed by page cache, no separate deinit needed.
        self.cache.deinit();
        self.file.close();

        // Free the heap-allocated Database struct.
        const allocator = self.allocator;
        allocator.destroy(self.op_latency);
        allocator.destroy(self);
    }

    /// Replay the WAL to recover from an unclean shutdown.
    pub fn recover(self: *Self) !void {
        // 1. Determine the last snapshot WAL sequence to skip already-applied entries.
        const min_seq = snapshot.SnapshotManager.getWalSequence(self.config.data_dir) catch 0;

        // 2. Replay WAL entries after the snapshot point.
        var applier = wal_apply.WalApplier{ .db = self };
        const last_seq = wal_replay.replayWal(self.config.data_dir, min_seq, &applier) catch |err| {
            log.err("WAL replay failed at sequence > {d}: {}. Aborting boot — see /admin/integrity for the path forward.", .{ min_seq, err });
            return err;
        };

        if (last_seq > 0) {
            log.info("WAL replay complete: applied entries up to sequence {d}", .{last_seq});
            // Sync header's replayed IDs into the atomic counters so
            // subsequent creates don't collide with replayed entries.
            self.next_category_id.store(self.header.next_category_id, .monotonic);
            self.next_link_id.store(self.header.next_link_id, .monotonic);
            self.next_repair_seq.store(self.header.next_repair_seq, .monotonic);
            // Flush replayed mutations to disk.
            self.cache.flushAll() catch |err| {
                log.err("Failed to flush after WAL replay: {}", .{err});
            };
            self.flushHeader() catch |err| {
                log.err("Failed to flush header after WAL replay: {}", .{err});
            };
        }

        // Bootstrap canonical Top + Lost-and-Found for a fresh DB. Previously
        // produced by migration phase 1 on first boot; now part of normal
        // recovery so a fresh data dir is immediately usable by the bench
        // harness, web app, and bulk importer.
        if (self.categories_by_id.entry_count == 0) {
            try self.bootstrapRootCategories();
        }

        // Materialise the per-status link counters from the (now consistent)
        // primary index so op=36 counts_by_status is an O(1) read instead of
        // a full links_by_id scan on every admin page load. Runs single-
        // threaded here, before startBackgroundThreads, so no writer races the
        // scan; live commits keep the counters current via apply_link from now
        // on. Non-fatal: a failure only degrades the chip counts to stale/zero
        // until the next boot, never blocks recovery.
        @import("operations/operations.zig").recountLinkStatuses(self) catch |err| {
            log.warn("recountLinkStatuses failed: {} — counts_by_status may read stale until next boot", .{err});
        };

        log.info("recover: complete; ready to listen", .{});
    }

    /// Create the canonical `Top` category (id=1) and a child `Lost and Found`
    /// (id=2) on a fresh database. Idempotent at the `entry_count == 0` gate;
    /// the caller is expected to check that condition before invoking.
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

    /// WAL replay callback that applies entries to ALL indices (primary + secondary).
    /// Write the current file header to page 0 with double-write for crash safety.
    /// First writes a backup header file, fsyncs it, then overwrites page 0.
    /// On recovery, if page 0 is corrupt, the backup can be used.
    /// Thread-safe: acquires header_lock to prevent interleaved seek/write.
    pub fn flushHeader(self: *Self) !void {
        self.header_lock.lock();
        defer self.header_lock.unlock();

        // Sync root pages and per-tree entry counts from B+Trees back
        // into the header before writing.
        inline for (tree_fields) |entry| {
            @field(self.header, entry[1]) = @field(self, entry[0]).root_page;
            @field(self.header, entry[2]) = @field(self, entry[0]).entry_count;
        }
        self.header.free_list_head = self.free_list.getHead();
        // Sync atomic ID counters back into the header for on-disk persistence.
        self.header.next_category_id = self.next_category_id.load(.monotonic);
        self.header.next_link_id = self.next_link_id.load(.monotonic);
        self.header.next_repair_seq = self.next_repair_seq.load(.monotonic);
        // Sync page_count from the cache (which extends the file via
        // allocatePage). Without this, the header would still report the
        // initial 7-page count after the file has grown to millions of
        // pages.
        self.cache.alloc_lock.lock();
        self.header.page_count = self.cache.page_count;
        self.cache.alloc_lock.unlock();

        const header_bytes = self.header.serialize();

        // 1. Write backup header file first (write-to-temp then rename).
        self.writeBackupHeader(&header_bytes) catch |err| {
            log.warn("Failed to write backup header: {}", .{err});
            // Non-fatal: continue writing primary header.
        };

        // 2. Write primary header to page 0.
        try self.file.seekTo(0);
        try self.file.writeAll(&header_bytes);
        try self.file.sync();
    }

    /// Write a backup copy of the header to `dmozdb.hdr.bak` using atomic
    /// temp-file + rename.
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

    /// Collect runtime statistics.
    /// Acquires header_lock to get a consistent snapshot of header fields.
    pub fn getStats(self: *Self) Stats {
        const hits = self.cache.hit_count.load(.monotonic);
        const misses = self.cache.miss_count.load(.monotonic);
        const cache_total = hits + misses;
        const hit_rate: f64 = if (cache_total > 0)
            @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(cache_total))
        else
            0.0;

        // Read ID counters from atomics (lock-free).
        const next_cat = self.next_category_id.load(.monotonic);
        const next_link = self.next_link_id.load(.monotonic);
        // page_count is only mutated under alloc_lock inside PageCache,
        // so a relaxed read is fine here.
        const pg_count = self.cache.page_count;

        // Read WAL pending count under the WAL's own lock to avoid a
        // data race on entry_count.
        const wal_pending: u64 = if (self.wal_writer) |*w| blk: {
            w.lock.lock();
            defer w.lock.unlock();
            break :blk w.entry_count;
        } else 0;

        return Stats{
            .category_count = if (next_cat > 0) next_cat - 1 else 0,
            .link_count = if (next_link > 0) next_link - 1 else 0,
            .page_count = pg_count,
            .free_page_count = 0, // FreeList is a linked list; count requires traversal.
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

    // First boot: insert a category, shut down — flushHeader should
    // persist the per-tree entry_count fields.
    {
        var db = try Database.openTestInstance(std.testing.allocator, &tmp);
        defer db.deinitTestInstance();

        const ops = @import("operations/operations.zig");
        const cat_id = try ops.createCategory(db, 0, "Test", "test", "");
        try std.testing.expect(cat_id > 0);
        // Drain memtables so the tree's entry_count reflects the insert.
        db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
        try std.testing.expect(db.categories_by_id.entry_count >= 1);
    }

    // Second boot: entry_count must be restored from the header. The
    // header is the only source of truth for per-tree counts on reopen.
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
        // Allocate three sequence numbers.
        _ = db.next_repair_seq.fetchAdd(1, .monotonic);
        _ = db.next_repair_seq.fetchAdd(1, .monotonic);
        _ = db.next_repair_seq.fetchAdd(1, .monotonic);
        try db.flushHeader();
    }
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        // Initial value 1 + 3 fetchAdds → next available is 4.
        try std.testing.expectEqual(@as(u64, 4), db.next_repair_seq.load(.monotonic));
    }
}

test "recover boot path: clean DB reopens cleanly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Phase 1: write data, run migration, deinit cleanly.
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try db.recover();
        const ops = @import("operations/operations.zig");
        const top_id = try ops.createCategory(db, 0, "Top", "top", "");
        _ = try ops.createCategory(db, top_id, "Arts", "arts", "");
    }

    // Phase 2: reopen — recover() must complete without error and the
    // category we created should be reachable via the slug-path B+Tree.
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try db.recover();
        const ops = @import("operations/operations.zig");
        const id = try ops.resolveSlugPath(db, "arts");
        try std.testing.expect(id != null);
    }
}
