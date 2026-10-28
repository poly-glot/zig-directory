//! The directory owns the store lifecycle: it upgrades and opens the typed store, replays the
//! WAL, starts and joins every background worker, and routes each request through one dispatch
//! that waits for the request's writes to become durable before the response leaves the process.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const subtree_module = @import("subtree.zig");
const verifier = @import("verifier.zig");
const changeset = @import("changeset.zig");
const apply_module = @import("apply/apply.zig");
const wal_apply = @import("wal/wal_apply.zig");
const repair_worker_module = @import("repair/repair_worker.zig");
const histogram = zigstore.histogram;
const binary_protocol = @import("binary_protocol.zig");
const scratch_memory = @import("scratch.zig");

const scratch_slabs_extra: u32 = 8;
const header_upgrade = @import("header_upgrade.zig");
const vector_index = @import("vector_index.zig");
const ivf_index = @import("ivf_index.zig");
const vector_model = @import("vector_model.zig");
const facts_index = @import("facts/facts_index.zig");
const Config = @import("main.zig").Config;

const log = std.log.scoped(.directory);

const v5_indexes = .{
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
};
const memtable_indexes = &.{
    "categories_by_id",
    "cat_by_parent",
    "links_by_id",
    "link_by_category",
    "link_by_url_hash",
    "link_by_submitter",
};
const v5_counters = .{
    "next_category_id",
    "next_link_id",
    "next_repair_seq",
    "links_pending",
    "links_approved",
    "links_rejected",
    "derived_counts_version",
};

pub const schema_v5 = zigstore.schema(.{
    .magic = 0x444D4F5A,
    .format_version = 5,
    .indexes = v5_indexes,
    .memtable_indexes = memtable_indexes,
    .counters = &v5_counters,
});

const v6_indexes = v5_indexes ++ .{.{ .name = "link_vectors", .key = .u64 }};
const v6_counters = v5_counters ++ .{"embedding_model"};

pub const schema_v6 = zigstore.schema(.{
    .magic = schema_v5.magic,
    .format_version = 6,
    .indexes = v6_indexes,
    .memtable_indexes = memtable_indexes,
    .counters = &v6_counters,
});

const v7_indexes = v6_indexes ++ .{.{ .name = "link_entities", .key = .u64 }};

pub const schema_v7 = zigstore.schema(.{
    .magic = schema_v5.magic,
    .format_version = 7,
    .indexes = v7_indexes,
    .memtable_indexes = memtable_indexes,
    .counters = &v6_counters,
});

const v8_indexes = v7_indexes ++ .{.{ .name = "category_vectors", .key = .u64 }};

pub const schema_v8 = zigstore.schema(.{
    .magic = schema_v5.magic,
    .format_version = 8,
    .indexes = v8_indexes,
    .memtable_indexes = memtable_indexes,
    .counters = &v6_counters,
});

pub const schema = zigstore.schema(.{
    .magic = schema_v5.magic,
    .format_version = 9,
    .indexes = v8_indexes,
    .memtable_indexes = memtable_indexes,
    .counters = &v6_counters,
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

pub const url_bloom_capacity_initial: u64 = 1_000_000;
pub const derived_counts_version_current: u64 = 1;
const memtable_flush_interval_ns: u64 = 5 * std.time.ns_per_ms;
const test_vector_model_seed: u64 = 0x5EED;

// A zigstore response frame starts `[u32 total_len][u8 op]`, so the echoed op sits at byte 4.
const response_op_byte_offset: usize = 4;

threadlocal var deferred_durable_seq: ?u64 = null;

pub const Directory = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    store: *Store,
    scratch_pool: scratch_memory.Pool,

    verifier_state: verifier.VerifierState,
    verifier_worker: ?*zigstore.Worker,
    verifier_interval_ns: u64,

    write_mutex: std.Io.Mutex,

    repair_worker: ?*zigstore.Worker,
    repair_worker_mutex: std.Io.Mutex,
    repair_worker_tasks_processed: std.atomic.Value(u64),
    repair_worker_chunks_processed: std.atomic.Value(u64),
    repair_worker_last_tick_ms: std.atomic.Value(i64),

    memtable_flusher: ?*zigstore.Worker,
    checkpointer: ?*zigstore.Worker,

    subtree_cache: subtree_module.SubtreeCache,

    url_bloom: zigstore.BloomFilter,
    url_bloom_ready: std.atomic.Value(bool),
    url_bloom_seeder: ?std.Thread,
    url_bloom_seeder_stop: std.atomic.Value(bool),

    link_vector_index: ivf_index.LinkVectorIndex,
    category_vector_index: vector_index.VectorIndex,
    vector_loader: ?std.Thread,

    facts: facts_index.FactsIndex,
    facts_loader: ?std.Thread,
    derived_restored: @import("derived_snapshot.zig").Restored,
    checkpoint_last_s: i64,

    next_category_id: std.atomic.Value(u64),
    next_link_id: std.atomic.Value(u64),
    next_repair_seq: std.atomic.Value(u64),

    links_pending_count: std.atomic.Value(u64),
    links_approved_count: std.atomic.Value(u64),
    links_rejected_count: std.atomic.Value(u64),

    op_latency: *[256]histogram.AtomicHistogram,

    pub fn dispatch(
        context: *anyopaque,
        op_byte: u8,
        payload: []const u8,
        count: u16,
        response: []u8,
        _: *zigstore.protocol.FrameGate,
    ) usize {
        const directory = as_directory(context);
        assert(deferred_durable_seq == null);
        deferred_durable_seq = 0;
        defer deferred_durable_seq = null;
        scratch_memory.begin(&directory.scratch_pool);
        defer scratch_memory.end();

        const written = binary_protocol.dispatch(directory, op_byte, payload, count, response);
        assert(written <= response.len);
        if (written > 0) {
            assert(written >= zigstore.protocol.RESPONSE_HEADER_SIZE);
            assert(response[response_op_byte_offset] == op_byte);
        }
        directory.await_durable(deferred_durable_seq.?);
        return written;
    }

    /// Memory that lives no longer than the current request: the thread's scratch slab inside
    /// `dispatch`, the general-purpose allocator everywhere else (tests, the importer, startup).
    pub fn scratch(self: *Directory) std.mem.Allocator {
        assert(self.scratch_pool.count >= 1);
        return scratch_memory.allocator(self.allocator);
    }

    fn init_scratch_pool(config: Config) !scratch_memory.Pool {
        assert(config.scratch_slab_mb >= 1);
        const slab_bytes: u32 = config.scratch_slab_mb * 1024 * 1024;
        assert(slab_bytes >= scratch_memory.slab_bytes_min);
        return scratch_memory.Pool.init(.{
            .count = scratch_slab_count(config),
            .slab_bytes = slab_bytes,
        });
    }

    /// One slab per reactor thread, plus one for every thread that may call an operation
    /// outside a request (the test or import thread), capped by the pool.
    fn scratch_slab_count(config: Config) u32 {
        const reactors = @max(config.server.thread_count, 1) / 2 + 1;
        const count = @min(reactors + scratch_slabs_extra, scratch_memory.slabs_max);
        assert(count >= 1);
        assert(count <= scratch_memory.slabs_max);
        return count;
    }

    pub fn process_frames(context: *anyopaque, conn: *zigstore.connection.Connection) void {
        const directory = as_directory(context);
        zigstore.protocol.processFrames(
            context,
            conn,
            &Directory.dispatch,
            directory.op_latency,
            binary_protocol.response_reserve,
        );
    }

    pub fn handler() zigstore.Handler {
        comptime assert(binary_protocol.response_reserve >= zigstore.protocol.RESPONSE_HEADER_SIZE);
        return .{
            .process_frames = &Directory.process_frames,
            .header_size = zigstore.protocol.HEADER_SIZE,
            .on_shutdown = &Directory.checkpoint_on_shutdown,
        };
    }

    fn checkpoint_on_shutdown(context: *anyopaque) void {
        const directory = as_directory(context);
        _ = directory.checkpoint() catch |err| {
            log.err(
                "checkpoint on shutdown failed: {} — recovery will replay on next boot",
                .{err},
            );
        };
    }

    pub fn categories_by_id(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("categories_by_id");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn cat_by_parent(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("cat_by_parent");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn links_by_id(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("links_by_id");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn link_by_category(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("link_by_category");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn link_by_url_hash(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("link_by_url_hash");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn link_by_submitter(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("link_by_submitter");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn categories_by_slug_path(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("categories_by_slug_path");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn categories_by_slug_only(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("categories_by_slug_only");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn categories_index_tree(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("categories_index_tree");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn links_index_tree(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("links_index_tree");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn slug_path_repair_queue(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("slug_path_repair_queue");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn link_vectors(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("link_vectors");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn category_vectors(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("category_vectors");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }
    pub fn link_entities(self: *Directory) *zigstore.BPlusTree {
        const tree = self.store.tree("link_entities");
        assert(tree.cache == &self.store.cache);
        assert(tree.free_list == &self.store.free_list);
        return tree;
    }

    pub fn memtable_categories_by_id(self: *Directory) *zigstore.MemTable {
        const memtable = self.store.memtable("categories_by_id");
        assert(memtable.io.userdata == self.io.userdata);
        assert(memtable.allocator.ptr == self.allocator.ptr);
        return memtable;
    }
    pub fn memtable_cat_by_parent(self: *Directory) *zigstore.MemTable {
        const memtable = self.store.memtable("cat_by_parent");
        assert(memtable.io.userdata == self.io.userdata);
        assert(memtable.allocator.ptr == self.allocator.ptr);
        return memtable;
    }
    pub fn memtable_links_by_id(self: *Directory) *zigstore.MemTable {
        const memtable = self.store.memtable("links_by_id");
        assert(memtable.io.userdata == self.io.userdata);
        assert(memtable.allocator.ptr == self.allocator.ptr);
        return memtable;
    }
    pub fn memtable_link_by_category(self: *Directory) *zigstore.MemTable {
        const memtable = self.store.memtable("link_by_category");
        assert(memtable.io.userdata == self.io.userdata);
        assert(memtable.allocator.ptr == self.allocator.ptr);
        return memtable;
    }
    pub fn memtable_link_by_url_hash(self: *Directory) *zigstore.MemTable {
        const memtable = self.store.memtable("link_by_url_hash");
        assert(memtable.io.userdata == self.io.userdata);
        assert(memtable.allocator.ptr == self.allocator.ptr);
        return memtable;
    }
    pub fn memtable_link_by_submitter(self: *Directory) *zigstore.MemTable {
        const memtable = self.store.memtable("link_by_submitter");
        assert(memtable.io.userdata == self.io.userdata);
        assert(memtable.allocator.ptr == self.allocator.ptr);
        return memtable;
    }

    pub fn open_test_instance(
        allocator: std.mem.Allocator,
        temporary_directory: *std.testing.TmpDir,
    ) !*Directory {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path_len = try temporary_directory.dir.realPath(std.testing.io, &path_buffer);
        assert(path_len > 0);
        assert(path_len <= path_buffer.len);

        const path = try allocator.dupe(u8, path_buffer[0..path_len]);
        errdefer allocator.free(path);

        const model = try vector_model.Model.synthetic(allocator, test_vector_model_seed);
        errdefer model.deinit(allocator);

        const directory = try Directory.init(std.testing.io, allocator, .{
            .data_dir = path,
            .server = .{
                .cache_size_mb = 16,
                .thread_count = 1,
                .wal_batch_size = 32,
                .snapshot_interval_s = 3600,
            },
        }, model);
        assert(directory.config.data_dir.ptr == path.ptr);
        return directory;
    }

    pub fn deinit_test_instance(self: *Directory) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        const model = self.link_vector_index.codebooks;
        assert(data_dir.len > 0);
        self.deinit();
        model.deinit(allocator);
        allocator.free(data_dir);
    }

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        config: Config,
        model: *const vector_model.Model,
    ) !*Directory {
        try header_upgrade.upgrade_header(io, config.data_dir);

        const store = try Store.init(io, allocator, .{
            .data_dir = config.data_dir,
            .cache_size_mb = config.server.cache_size_mb,
            .wal_batch_size = config.server.wal_batch_size,
        });
        errdefer store.deinit();
        assert(store.header.format_version == schema.format_version);

        const self = try allocator.create(Directory);
        errdefer allocator.destroy(self);

        var url_bloom = try init_url_bloom(allocator, store.tree("links_by_id").entryCount());
        errdefer url_bloom.deinit();

        const op_latency = try init_op_latency(allocator);
        errdefer allocator.destroy(op_latency);

        var scratch_pool = try init_scratch_pool(config);
        errdefer scratch_pool.deinit();

        self.* = Directory{
            .io = io,
            .allocator = allocator,
            .config = config,
            .store = store,
            .scratch_pool = scratch_pool,
            .verifier_state = .{},
            .verifier_worker = null,
            .verifier_interval_ns = @as(u64, config.verifier_interval_s) * std.time.ns_per_s,
            .write_mutex = .init,
            .repair_worker = null,
            .repair_worker_mutex = .init,
            .repair_worker_tasks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_chunks_processed = std.atomic.Value(u64).init(0),
            .repair_worker_last_tick_ms = std.atomic.Value(i64).init(0),
            .memtable_flusher = null,
            .checkpointer = null,
            .subtree_cache = subtree_module.SubtreeCache.init(io, allocator),
            .url_bloom = url_bloom,
            .url_bloom_ready = std.atomic.Value(bool).init(false),
            .url_bloom_seeder = null,
            .url_bloom_seeder_stop = std.atomic.Value(bool).init(false),
            .link_vector_index = .{
                .codebooks = model,
                .model = .init(store.counter("embedding_model").*),
            },
            .category_vector_index = .{ .model = .init(store.counter("embedding_model").*) },
            .vector_loader = null,
            .facts = .{},
            .facts_loader = null,
            .derived_restored = .{},
            .checkpoint_last_s = 0,
            .next_category_id = std.atomic.Value(u64).init(store.counter("next_category_id").*),
            .next_link_id = std.atomic.Value(u64).init(store.counter("next_link_id").*),
            .next_repair_seq = std.atomic.Value(u64).init(store.counter("next_repair_seq").*),
            .links_pending_count = std.atomic.Value(u64).init(store.counter("links_pending").*),
            .links_approved_count = std.atomic.Value(u64).init(store.counter("links_approved").*),
            .links_rejected_count = std.atomic.Value(u64).init(store.counter("links_rejected").*),
            .op_latency = op_latency,
        };

        if (store.was_empty) self.init_fresh_counters();
        self.init_assert_wiring();
        self.init_assert_distinct();
        return self;
    }

    fn init_op_latency(allocator: std.mem.Allocator) !*[256]histogram.AtomicHistogram {
        const op_latency = try allocator.create([256]histogram.AtomicHistogram);
        for (op_latency) |*slot| slot.* = .{};
        assert(op_latency.len == 256);
        assert(op_latency[0].samples() == 0);
        assert(op_latency[255].samples() == 0);
        return op_latency;
    }

    /// A freshly formatted store has no ids issued yet; ids start at one so zero stays the
    /// "no such record" sentinel everywhere.
    fn init_fresh_counters(self: *Directory) void {
        assert(self.store.was_empty);
        assert(self.store.tree("categories_by_id").entryCount() == 0);
        self.next_category_id.store(1, .monotonic);
        self.next_link_id.store(1, .monotonic);
        self.next_repair_seq.store(1, .monotonic);
        assert(self.next_link_id.load(.monotonic) == 1);
    }

    // The bloom is sized for twice the links on disk so the seeded filter keeps its false
    // positive rate through a full re-import, and never below the initial capacity.
    fn init_url_bloom(allocator: std.mem.Allocator, link_count: u64) !zigstore.BloomFilter {
        const capacity = @max(link_count *| 2, url_bloom_capacity_initial);
        assert(capacity >= url_bloom_capacity_initial);
        assert(capacity >= link_count);
        return zigstore.BloomFilter.init(allocator, capacity);
    }

    // The store wires every tree at its persisted root and count and every memtable empty, so
    // right after init each accessor must hand back exactly what the superblock describes.
    fn init_assert_wiring(self: *Directory) void {
        const link_model = self.link_vector_index.model.load(.monotonic);
        const category_model = self.category_vector_index.model.load(.monotonic);
        assert(link_model == category_model);
        comptime {
            assert(schema_v6.format_version == schema_v5.format_version + 1);
            assert(schema_v7.format_version == schema_v6.format_version + 1);
            assert(schema_v8.format_version == schema_v7.format_version + 1);
            assert(schema.format_version == schema_v8.format_version + 1);
            assert(v6_indexes.len == v5_indexes.len + 1);
            assert(v7_indexes.len == v6_indexes.len + 1);
            assert(v8_indexes.len == v7_indexes.len + 1);
            assert(v6_counters.len == v5_counters.len + 1);
            assert(Store.schema_def.indexes.len == v8_indexes.len);
            assert(std.mem.eql(u8, v6_indexes[v6_indexes.len - 1].name, "link_vectors"));
            assert(std.mem.eql(u8, v7_indexes[v7_indexes.len - 1].name, "link_entities"));
            assert(std.mem.eql(u8, v8_indexes[v8_indexes.len - 1].name, "category_vectors"));
        }
        const header = &self.store.header;
        assert(self.categories_by_id().entry_count == header.categories_by_id_count);
        assert(self.cat_by_parent().entry_count == header.cat_by_parent_count);
        assert(self.links_by_id().entry_count == header.links_by_id_count);
        assert(self.link_by_category().entry_count == header.link_by_category_count);
        assert(self.link_by_url_hash().entry_count == header.link_by_url_hash_count);
        assert(self.link_by_submitter().entry_count == header.link_by_submitter_count);
        assert(self.categories_by_slug_path().entry_count == header.categories_by_slug_path_count);
        assert(self.categories_by_slug_only().entry_count == header.categories_by_slug_only_count);
        assert(self.categories_index_tree().entry_count == header.categories_index_tree_count);
        assert(self.links_index_tree().entry_count == header.links_index_tree_count);
        assert(self.slug_path_repair_queue().entry_count == header.slug_path_repair_queue_count);
        assert(self.link_vectors().entry_count == header.link_vectors_count);
        assert(self.category_vectors().entry_count == header.category_vectors_count);
        assert(self.link_entities().entry_count == header.link_entities_count);

        assert(self.memtable_categories_by_id().count() == 0);
        assert(self.memtable_cat_by_parent().count() == 0);
        assert(self.memtable_links_by_id().count() == 0);
        assert(self.memtable_link_by_category().count() == 0);
        assert(self.memtable_link_by_url_hash().count() == 0);
        assert(self.memtable_link_by_submitter().count() == 0);
    }

    // Two accessors naming the same tree would silently cross-write two indexes.
    fn init_assert_distinct(self: *Directory) void {
        const trees = [_]*zigstore.BPlusTree{
            self.categories_by_id(),
            self.cat_by_parent(),
            self.links_by_id(),
            self.link_by_category(),
            self.link_by_url_hash(),
            self.link_by_submitter(),
            self.categories_by_slug_path(),
            self.categories_by_slug_only(),
            self.categories_index_tree(),
            self.links_index_tree(),
            self.slug_path_repair_queue(),
            self.link_vectors(),
            self.category_vectors(),
            self.link_entities(),
        };
        comptime assert(trees.len == Store.schema_def.indexes.len);
        for (trees, 0..) |tree, index| {
            for (trees[index + 1 ..]) |other| assert(tree != other);
        }

        const memtables = [_]*zigstore.MemTable{
            self.memtable_categories_by_id(),
            self.memtable_cat_by_parent(),
            self.memtable_links_by_id(),
            self.memtable_link_by_category(),
            self.memtable_link_by_url_hash(),
            self.memtable_link_by_submitter(),
        };
        comptime assert(memtables.len == Store.schema_def.memtable_indexes.len);
        for (memtables, 0..) |memtable, index| {
            for (memtables[index + 1 ..]) |other| assert(memtable != other);
        }
    }

    pub fn start_background_threads(self: *Directory) void {
        self.assert_background_idle();
        self.memtable_flusher = self.store.spawnWorker(self, .{
            .interval_ns = memtable_flush_interval_ns,
            .tick = &flush_tick,
        }) catch blk: {
            log.warn("Memtable flusher thread failed to start", .{});
            break :blk null;
        };
        self.verifier_worker = self.store.spawnWorker(self, .{
            .interval_ns = self.verifier_interval_ns,
            .tick = &verify_tick,
        }) catch null;
        self.repair_worker = self.store.spawnWorker(self, .{
            .interval_ns = @as(u64, self.config.repair_worker_interval_ms) * std.time.ns_per_ms,
            .tick = &repair_tick,
        }) catch null;
        // Our own checkpoint worker, not zigstore's: a derived snapshot is only worth writing
        // right after a checkpoint, stamped with the sequence it made durable.
        self.checkpoint_last_s = self.now_seconds();
        self.checkpointer = self.store.spawnWorker(self, .{
            .interval_ns = std.time.ns_per_s,
            .tick = &checkpoint_tick,
        }) catch blk: {
            log.warn(
                "Checkpointer thread failed to start — only shutdown checkpoints will run",
                .{},
            );
            break :blk null;
        };
        self.start_index_loaders();
    }

    // A restored index is complete once recovery has replayed the WAL tail into it, so it is
    // ready here; only an index the snapshot did not carry is rebuilt from the store.
    fn start_index_loaders(self: *Directory) void {
        const restored = self.derived_restored;
        assert(self.url_bloom_seeder == null);
        assert(self.facts_loader == null);
        if (restored.url_bloom) {
            self.url_bloom_ready.store(true, .release);
        } else {
            self.url_bloom_seeder = std.Thread.spawn(
                .{},
                seed_url_bloom_in_background,
                .{self},
            ) catch blk: {
                log.warn(
                    "url bloom seeder failed to start — duplicate checks keep reading " ++
                        "the url index",
                    .{},
                );
                break :blk null;
            };
        }
        if (restored.link_vectors) self.link_vector_index.ready.store(true, .release);
        if (restored.category_vectors) self.category_vector_index.ready.store(true, .release);
        if (!restored.link_vectors or !restored.category_vectors) {
            self.vector_loader = std.Thread.spawn(
                .{},
                load_vectors_in_background,
                .{self},
            ) catch blk: {
                log.warn(
                    "vector loader failed to start — hybrid search stays keyword-only",
                    .{},
                );
                break :blk null;
            };
        }
        if (restored.facts) {
            self.facts.ready.store(true, .release);
        } else {
            self.facts_loader = std.Thread.spawn(
                .{},
                load_facts_in_background,
                .{self},
            ) catch blk: {
                log.warn("facts loader failed to start — query_links answers not ready", .{});
                break :blk null;
            };
        }
    }

    // WAL replay and the first spawn both need the trees to themselves: no worker may be
    // draining, verifying or loading while entries are still being applied.
    fn assert_background_idle(self: *Directory) void {
        assert(self.memtable_flusher == null);
        assert(self.verifier_worker == null);
        assert(self.repair_worker == null);
        assert(self.checkpointer == null);
        assert(self.url_bloom_seeder == null);
        assert(self.vector_loader == null);
        assert(self.facts_loader == null);
    }

    fn load_facts_in_background(self: *Directory) void {
        assert(!self.facts.ready.load(.acquire));
        const started = std.Io.Clock.awake.now(self.io);
        @import("operations/operations.zig").load_facts_index(self) catch |err| {
            log.warn("facts index load stopped: {} — query_links answers not ready", .{err});
            return;
        };
        if (self.facts.ready.load(.acquire)) {
            log.info(
                "facts index loaded {d} links, {d} categories and entities for {d} links in {d} ms",
                .{
                    self.facts.link_count(self.io),
                    self.facts.category_count(self.io),
                    self.facts.entity_count(self.io),
                    started.untilNow(self.io, .awake).toMilliseconds(),
                },
            );
        }
    }

    fn load_vectors_in_background(self: *Directory) void {
        const restored = self.derived_restored;
        assert(!restored.link_vectors or !restored.category_vectors);
        if (restored.link_vectors) assert(self.link_vector_index.ready.load(.acquire));
        if (!restored.link_vectors) self.load_link_vectors();
        if (!restored.category_vectors) self.load_category_vectors();
    }

    fn load_link_vectors(self: *Directory) void {
        assert(!self.link_vector_index.ready.load(.acquire));
        assert(!self.derived_restored.link_vectors);
        const started = std.Io.Clock.awake.now(self.io);
        @import("operations/operations.zig").load_vector_index(self) catch |err| {
            log.warn("vector index load stopped: {} — hybrid search stays keyword-only", .{err});
            return;
        };
        if (self.link_vector_index.ready.load(.acquire)) {
            log.info(
                "vector index loaded {d} vectors in {d} ms",
                .{
                    self.link_vector_index.count(self.io),
                    started.untilNow(self.io, .awake).toMilliseconds(),
                },
            );
        }
    }

    fn load_category_vectors(self: *Directory) void {
        assert(!self.category_vector_index.ready.load(.acquire));
        assert(!self.derived_restored.category_vectors);
        const started = std.Io.Clock.awake.now(self.io);
        @import("operations/operations.zig").load_category_vector_index(self) catch |err| {
            log.warn(
                "category vector index load stopped: {} — search ignores category meaning",
                .{err},
            );
            return;
        };
        if (self.category_vector_index.ready.load(.acquire)) {
            log.info(
                "category vector index loaded {d} vectors in {d} ms",
                .{
                    self.category_vector_index.count(self.io),
                    started.untilNow(self.io, .awake).toMilliseconds(),
                },
            );
        }
    }

    fn seed_url_bloom_in_background(self: *Directory) void {
        assert(!self.url_bloom_ready.load(.acquire));
        const started = std.Io.Clock.awake.now(self.io);
        @import("operations/operations.zig").seed_url_bloom(
            self,
            .yield_half_the_disk,
        ) catch |err| {
            log.warn(
                "url bloom seeding stopped: {} — duplicate checks keep reading the url index",
                .{err},
            );
            return;
        };
        if (self.url_bloom_ready.load(.acquire)) {
            log.info(
                "url bloom seeded in {d} ms",
                .{started.untilNow(self.io, .awake).toMilliseconds()},
            );
        }
    }

    fn as_directory(context: *anyopaque) *Directory {
        return @ptrCast(@alignCast(context));
    }

    // Every tick eases dirty-page pressure, as zigstore's own checkpointer did; the checkpoint
    // itself runs on `snapshot_interval_s` and the derived snapshot follows it at once.
    fn checkpoint_tick(context: *anyopaque) anyerror!void {
        const self = as_directory(context);
        try self.store.relieveDirtyPressure();
        const now = self.now_seconds();
        const interval: i64 = self.config.server.snapshot_interval_s;
        assert(interval >= 0);
        if (now - self.checkpoint_last_s < interval) return;
        const seq = try self.checkpoint();
        self.checkpoint_last_s = now;
        assert(self.store.header.seq == seq);
        @import("derived_snapshot.zig").write(self, seq) catch |err| {
            log.warn(
                "derived snapshot not written: {} — the next boot scans the store",
                .{err},
            );
        };
    }

    fn flush_tick(context: *anyopaque) anyerror!void {
        try as_directory(context).drain_all_memtables();
    }

    fn verify_tick(context: *anyopaque) anyerror!void {
        const self = as_directory(context);
        try verifier.run_once(self, &self.verifier_state);
    }

    fn repair_tick(context: *anyopaque) anyerror!void {
        try repair_worker_module.tick_once(as_directory(context));
    }

    pub fn commit(self: *Directory, change_set: changeset.ChangeSet) !void {
        var applied: zigstore.CommitCompletion = .{};
        const seq = zigstore.commitSeq(
            changeset.ChangeSet,
            self.store,
            changeset.changeset_op,
            change_set,
            self,
            &serialize_change_set,
            &apply_change_set,
            .{ .completion = &applied },
        ) catch |err| switch (err) {
            error.WalFlushFailed => abort_on_wal_flush_failure(),
            else => return err,
        };
        assert(seq > 0);
        assert(applied.seq == seq);
        assert(!applied.needs_quorum);

        // Inside a dispatched request the wait is deferred to the end of the request, so a
        // bulk op pays one durability wait instead of one per change set.
        if (deferred_durable_seq) |pending| {
            assert(seq > pending);
            deferred_durable_seq = seq;
            return;
        }
        self.await_durable(seq);
    }

    fn await_durable(self: *Directory, seq: u64) void {
        if (seq == 0) return;
        if (self.store.wal_writer) |*wal| {
            wal.awaitDurable(seq) catch abort_on_wal_flush_failure();
            assert(wal.durableSeqPublished() >= seq);
        }
    }

    fn abort_on_wal_flush_failure() noreturn {
        log.err(
            "WAL flush failed after apply — aborting so recovery serves only what is durable",
            .{},
        );
        @panic("WAL flush failed");
    }

    fn serialize_change_set(
        allocator: std.mem.Allocator,
        change_set: changeset.ChangeSet,
    ) anyerror![]u8 {
        const bytes = try changeset.encode(allocator, change_set);
        assert(bytes.len >= 2);
        assert(bytes[0] == changeset.schema_version);
        return bytes;
    }

    fn apply_change_set(context: *anyopaque, change_set: changeset.ChangeSet) anyerror!void {
        apply_or_abort(as_directory(context), change_set);
    }

    fn apply_or_abort(directory: *Directory, change_set: changeset.ChangeSet) void {
        apply_module.apply(directory, &change_set) catch |err| {
            log.err(
                "changeset apply failed after its WAL append: {} — " ++
                    "aborting so recovery replays it whole",
                .{err},
            );
            @panic("changeset apply failed after WAL append");
        };
        directory.sync_persisted_counters();
    }

    pub fn drain_all_memtables(self: *Directory) !void {
        try self.store.drainMemtables();
    }

    pub fn drain_one_memtable(
        self: *Directory,
        memtable: *zigstore.MemTable,
        tree: *zigstore.BPlusTree,
    ) !void {
        try self.store.drainMemtableInto(memtable, tree);
    }

    pub fn deinit(self: *Directory) void {
        self.shutdown(true);
    }

    pub fn deinit_crash_test_instance(self: *Directory) void {
        const allocator = self.allocator;
        const data_dir = self.config.data_dir;
        const model = self.link_vector_index.codebooks;
        assert(data_dir.len > 0);
        self.shutdown(false);
        model.deinit(allocator);
        allocator.free(data_dir);
    }

    fn shutdown(self: *Directory, persist: bool) void {
        assert(!self.url_bloom_seeder_stop.load(.acquire));
        assert(!self.link_vector_index.loader_stop.load(.acquire));
        assert(!self.category_vector_index.loader_stop.load(.acquire));
        assert(!self.facts.loader_stop.load(.acquire));
        self.url_bloom_seeder_stop.store(true, .release);
        if (self.url_bloom_seeder) |thread| thread.join();
        self.link_vector_index.loader_stop.store(true, .release);
        self.category_vector_index.loader_stop.store(true, .release);
        if (self.vector_loader) |thread| thread.join();
        self.facts.loader_stop.store(true, .release);
        if (self.facts_loader) |thread| thread.join();
        if (self.checkpointer) |worker| worker.stop();
        if (self.repair_worker) |worker| worker.stop();
        if (self.verifier_worker) |worker| worker.stop();
        if (self.memtable_flusher) |worker| worker.stop();

        if (persist) {
            if (self.checkpoint()) |seq| {
                @import("derived_snapshot.zig").write(self, seq) catch |err| {
                    log.warn(
                        "derived snapshot not written on shutdown: {} — the next boot scans",
                        .{err},
                    );
                };
            } else |err| {
                log.err(
                    "checkpoint on shutdown failed: {} — recovery will replay on next boot",
                    .{err},
                );
            }
        } else {
            if (self.store.wal_writer) |*wal| wal.deinit();
        }

        self.url_bloom.deinit();
        self.link_vector_index.deinit(self.allocator);
        self.category_vector_index.deinit(self.allocator);
        self.facts.deinit(self.allocator);
        self.subtree_cache.deinit();
        self.scratch_pool.deinit();

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

    pub fn recover(self: *Directory) !void {
        self.assert_background_idle();
        // Before replay: the snapshot stands at the superblock's sequence, and the tail above
        // it is applied into the restored indexes by the same path that built them.
        self.derived_restored = @import("derived_snapshot.zig").restore(self);
        try self.store.recover(self, .{
            .apply_entry = &apply_entry,
            .on_replayed = &restore_derived_counts,
            .bootstrap = &bootstrap_roots,
        });
        assert(self.derived_counts_checkpointed());

        log.info("recover: complete; ready to listen", .{});
    }

    fn apply_entry(context: *anyopaque, entry: zigstore.ReplayEntry) anyerror!void {
        const self = as_directory(context);
        assert(entry.sequence > self.store.header.seq);
        var applier = wal_apply.WalApplier{ .db = self };
        try applier.apply(entry);
    }

    fn restore_derived_counts(context: *anyopaque) anyerror!void {
        const self = as_directory(context);
        const store = self.store;
        sync_counter_up(&self.next_category_id, store.counter("next_category_id").*);
        sync_counter_up(&self.next_link_id, store.counter("next_link_id").*);
        sync_counter_up(&self.next_repair_seq, store.counter("next_repair_seq").*);
        assert(self.next_category_id.load(.monotonic) >= store.counter("next_category_id").*);
        assert(self.next_link_id.load(.monotonic) >= store.counter("next_link_id").*);
        assert(self.next_repair_seq.load(.monotonic) >= store.counter("next_repair_seq").*);

        if (self.derived_counts_checkpointed()) return;
        try self.recount_derived_counts();
    }

    pub fn derived_counts_checkpointed(self: *Directory) bool {
        return self.store.counter("derived_counts_version").* == derived_counts_version_current;
    }

    fn recount_derived_counts(self: *Directory) !void {
        assert(!self.derived_counts_checkpointed());
        const ops = @import("operations/operations.zig");
        try ops.recompute_category_counts(self);
        try ops.recount_link_statuses(self);
        self.sync_persisted_counters();
        self.store.counter("derived_counts_version").* = derived_counts_version_current;
        assert(self.derived_counts_checkpointed());
        log.info(
            "recover: derived counts recounted once; later boots restore them from the checkpoint",
            .{},
        );
    }

    // One atomic max: a load followed by a store could roll back an id that a request thread
    // issued with fetchAdd in between, and that id would then be handed out twice.
    fn sync_counter_up(atomic: *std.atomic.Value(u64), persisted: u64) void {
        const before = atomic.fetchMax(persisted, .monotonic);
        assert(atomic.load(.monotonic) >= before);
        assert(atomic.load(.monotonic) >= persisted);
    }

    pub fn note_issued_category_id(self: *Directory, id: u64) void {
        sync_counter_up(&self.next_category_id, id + 1);
        assert(self.next_category_id.load(.monotonic) > id);
    }

    pub fn note_issued_link_id(self: *Directory, id: u64) void {
        sync_counter_up(&self.next_link_id, id + 1);
        assert(self.next_link_id.load(.monotonic) > id);
    }

    pub fn note_issued_repair_seq(self: *Directory, seq: u64) void {
        sync_counter_up(&self.next_repair_seq, seq + 1);
        assert(self.next_repair_seq.load(.monotonic) > seq);
    }

    fn bootstrap_roots(context: *anyopaque) anyerror!void {
        const self = as_directory(context);
        assert(self.store.was_empty);
        if (self.categories_by_id().entryCount() != 0) return;
        const ops = @import("operations/operations.zig");
        const top_id = try ops.create_category(
            self,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const lost_and_found_id = try ops.create_category(
            self,
            top_id,
            .{
                .name = "Lost and Found",
                .slug = "lost-and-found",
                .description = "Categories whose original parent could not be resolved.",
            },
        );
        assert(top_id > 0);
        assert(lost_and_found_id > top_id);
        assert(self.next_category_id.load(.monotonic) > lost_and_found_id);
        log.info("bootstrap: created canonical Top (id={d}) + Lost-and-Found", .{top_id});
    }

    fn sync_persisted_counters(self: *Directory) void {
        self.store.counter("next_category_id").* = self.next_category_id.load(.monotonic);
        self.store.counter("next_link_id").* = self.next_link_id.load(.monotonic);
        self.store.counter("next_repair_seq").* = self.next_repair_seq.load(.monotonic);
        self.store.counter("links_pending").* = self.links_pending_count.load(.monotonic);
        self.store.counter("links_approved").* = self.links_approved_count.load(.monotonic);
        self.store.counter("links_rejected").* = self.links_rejected_count.load(.monotonic);
    }

    pub fn now_seconds(self: *Directory) i64 {
        return std.Io.Clock.real.now(self.io).toSeconds();
    }

    pub fn now_millis(self: *Directory) i64 {
        return std.Io.Clock.real.now(self.io).toMilliseconds();
    }

    pub fn checkpoint(self: *Directory) !u64 {
        self.sync_persisted_counters();
        const seq = try self.store.checkpoint();
        assert(self.store.header.seq == seq);
        assert(self.store.header.format_version == schema.format_version);
        return seq;
    }

    pub fn get_stats(self: *Directory) Stats {
        self.drain_one_memtable(
            self.memtable_categories_by_id(),
            self.categories_by_id(),
        ) catch |err| log.warn("stats: category drain skipped: {}", .{err});
        self.drain_one_memtable(
            self.memtable_links_by_id(),
            self.links_by_id(),
        ) catch |err| log.warn("stats: link drain skipped: {}", .{err});

        const hits = self.store.cache.hit_count.load(.monotonic);
        const misses = self.store.cache.miss_count.load(.monotonic);

        const category_count = self.categories_by_id().entryCount();
        const link_count = self.links_by_id().entryCount();
        const page_count = blk: {
            self.store.cache.alloc_lock.lockUncancelable(self.io);
            defer self.store.cache.alloc_lock.unlock(self.io);
            break :blk self.store.cache.page_count;
        };
        if (category_count > 0) assert(page_count > 0);
        if (link_count > 0) assert(page_count > 0);

        const wal_pending: u64 = if (self.store.wal_writer) |*wal| blk: {
            wal.lock.lockUncancelable(self.io);
            defer wal.lock.unlock(self.io);
            break :blk wal.entry_count;
        } else 0;

        return Stats{
            .category_count = category_count,
            .link_count = link_count,
            .page_count = page_count,
            .cache_hits = hits,
            .cache_misses = misses,
            .wal_pending_batch_entries = wal_pending,
        };
    }
};

// Goal: a tree count written at checkpoint comes back on reopen. Method: insert, drain, reopen.
test "open_test_instance: round-trips entry_count through checkpoint/init" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    {
        var directory = try Directory.open_test_instance(
            std.testing.allocator,
            &temporary_directory,
        );
        defer directory.deinit_test_instance();

        const ops = @import("operations/operations.zig");
        const category_id = try ops.create_category(
            directory,
            0,
            .{ .name = "Test", .slug = "test", .description = "" },
        );
        try std.testing.expect(category_id > 0);
        try directory.drain_one_memtable(
            directory.memtable_categories_by_id(),
            directory.categories_by_id(),
        );
        try std.testing.expect(directory.categories_by_id().entryCount() >= 1);
    }

    {
        var directory = try Directory.open_test_instance(
            std.testing.allocator,
            &temporary_directory,
        );
        defer directory.deinit_test_instance();

        try std.testing.expect(directory.store.header.categories_by_id_count >= 1);
        try std.testing.expect(directory.categories_by_id().entryCount() >= 1);
    }
}

// Goal: a fresh store starts with an empty repair queue. Method: open and count the tree.
test "Directory: slug_path_repair_queue field exists and is empty after init" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var directory = try Directory.open_test_instance(allocator, &temporary_directory);
    defer directory.deinit_test_instance();
    try std.testing.expectEqual(@as(u64, 0), directory.slug_path_repair_queue().entryCount());
}

// Goal: the repair sequence counter survives a checkpoint. Method: bump it, checkpoint, reopen.
test "next_repair_seq: persists across reopen" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        _ = directory.next_repair_seq.fetchAdd(1, .monotonic);
        _ = directory.next_repair_seq.fetchAdd(1, .monotonic);
        _ = directory.next_repair_seq.fetchAdd(1, .monotonic);
        _ = try directory.checkpoint();
    }
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try std.testing.expectEqual(@as(u64, 4), directory.next_repair_seq.load(.monotonic));
    }
}

// Goal: a cleanly closed store recovers with its bootstrap roots and data. Method: two boots.
test "recover boot path: clean DB reopens cleanly" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        const ops = @import("operations/operations.zig");
        const top_id = (try ops.resolve_slug_path(directory, "top")) orelse
            return error.BootstrapTopMissing;
        _ = try ops.create_category(
            directory,
            top_id,
            .{ .name = "Arts", .slug = "arts", .description = "" },
        );
    }

    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        const ops = @import("operations/operations.zig");
        const id = try ops.resolve_slug_path(directory, "arts");
        try std.testing.expect(id != null);
    }
}

// Goal: commit outside dispatch waits for durability itself. Method: compare WAL and durable seq.
test "a commit made outside a dispatched request is durable when it returns" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var directory = try Directory.open_test_instance(std.testing.allocator, &temporary_directory);
    defer directory.deinit_test_instance();

    const ops = @import("operations/operations.zig");
    _ = try ops.create_category(directory, 0, .{ .name = "Top", .slug = "top", .description = "" });

    const wal = &directory.store.wal_writer.?;
    try std.testing.expectEqual(wal.getSequence(), directory.store.durableSeqPublished());
}

// Goal: apply after the WAL append cannot fail softly. Method: the apply path returns no error.
test "a changeset that reached the WAL is applied or the process aborts, never acked as failed" {
    const info = @typeInfo(@TypeOf(Directory.apply_or_abort)).@"fn";
    try std.testing.expectEqual(void, info.return_type.?);
}

const derived_snapshot = @import("derived_snapshot.zig");
const link_operations = @import("operations/operations_link.zig");
const category_operations = @import("operations/operations_category.zig");

fn seed_two_links(directory: *Directory, out: *[2]u64) !u64 {
    const ops = @import("operations/operations.zig");
    const top = (try ops.resolve_slug_path(directory, "top")) orelse
        return error.BootstrapTopMissing;
    const arts = try category_operations.create_category(
        directory,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    out[0] = try link_operations.create_link(
        directory,
        arts,
        .{ .url = "http://one.tripod.com/", .title = "One", .description = "" },
    );
    out[1] = try link_operations.create_link(
        directory,
        arts,
        .{ .url = "http://two.tripod.com/", .title = "Two", .description = "" },
    );
    assert(out[0] != out[1]);
    assert(arts != top);
    return arts;
}

fn load_every_index(directory: *Directory) !void {
    const ops = @import("operations/operations.zig");
    try ops.load_facts_index(directory);
    try ops.load_vector_index(directory);
    try ops.load_category_vector_index(directory);
    try ops.seed_url_bloom(directory, .full_speed);
    assert(directory.facts.ready.load(.acquire));
    assert(directory.url_bloom_ready.load(.acquire));
}

// Goal: a clean shutdown leaves a snapshot the next boot restores instead of scanning, and
// the WAL tail written after it is replayed on top. Method: three boots. Write and shut down;
// reopen and check every index restored; insert and delete, crash, reopen and check the facts
// match the acknowledged writes, not the snapshot.
test "derived snapshot: restored on reopen and caught up by the WAL tail after a crash" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var links: [2]u64 = undefined;
    var arts: u64 = 0;
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        try std.testing.expect(!directory.derived_restored.facts);
        arts = try seed_two_links(directory, &links);
        try load_every_index(directory);
    }
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_crash_test_instance();
        try directory.recover();
        try std.testing.expect(directory.derived_restored.facts);
        try std.testing.expect(directory.derived_restored.url_bloom);
        try std.testing.expect(directory.derived_restored.category_vectors);
        try std.testing.expect(directory.derived_restored.link_vectors);
        directory.start_background_threads();
        try std.testing.expect(directory.facts.ready.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), directory.facts.link_count(directory.io));
        try std.testing.expect(directory.url_bloom.mayContain("http://two.tripod.com/"));
        _ = try link_operations.create_link(
            directory,
            arts,
            .{ .url = "http://three.tripod.com/", .title = "Three", .description = "" },
        );
        try link_operations.delete_link(directory, links[0]);
    }
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        try std.testing.expect(directory.derived_restored.facts);
        directory.start_background_threads();
        try std.testing.expect(directory.facts.ready.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), directory.facts.link_count(directory.io));
        try std.testing.expect(!directory.facts.links.contains(links[0]));
        try std.testing.expect(directory.facts.links.contains(links[1]));
        try std.testing.expect(directory.url_bloom.mayContain("http://three.tripod.com/"));
    }
}

// Goal: a snapshot from an older checkpoint is never restored. Method: shut down cleanly so a
// snapshot exists, reopen, write a link and checkpoint without snapshotting, crash, reopen:
// nothing restores and the facts loader still finds every link.
test "derived snapshot: a stale snapshot is ignored and the store is scanned" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var links: [2]u64 = undefined;
    var arts: u64 = 0;
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        arts = try seed_two_links(directory, &links);
        try load_every_index(directory);
    }
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_crash_test_instance();
        try directory.recover();
        try std.testing.expect(directory.derived_restored.facts);
        _ = try link_operations.create_link(
            directory,
            arts,
            .{ .url = "http://three.tripod.com/", .title = "Three", .description = "" },
        );
        _ = try directory.checkpoint();
    }
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        try std.testing.expect(!directory.derived_restored.facts);
        try std.testing.expect(!directory.derived_restored.link_vectors);
        try load_every_index(directory);
        try std.testing.expectEqual(@as(usize, 3), directory.facts.link_count(directory.io));
    }
}

// Goal: a damaged snapshot never poisons an index. Method: shut down cleanly, cut the file
// short inside the facts section, reopen: nothing restores, the loaders rebuild everything.
test "derived snapshot: a truncated file is ignored and the indexes load by scanning" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var links: [2]u64 = undefined;
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        _ = try seed_two_links(directory, &links);
        try load_every_index(directory);
    }
    {
        const file = try temporary_directory.dir.openFile(
            std.testing.io,
            derived_snapshot.file_name,
            .{ .mode = .read_write },
        );
        defer file.close(std.testing.io);
        try std.testing.expect((try file.length(std.testing.io)) > 120);
        try file.setLength(std.testing.io, 120);
    }
    {
        var directory = try Directory.open_test_instance(allocator, &temporary_directory);
        defer directory.deinit_test_instance();
        try directory.recover();
        try std.testing.expect(!directory.derived_restored.facts);
        try std.testing.expect(!directory.derived_restored.url_bloom);
        try std.testing.expectEqual(@as(usize, 0), directory.facts.links.count());
        try load_every_index(directory);
        try std.testing.expectEqual(@as(usize, 2), directory.facts.link_count(directory.io));
    }
}
