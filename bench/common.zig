const std = @import("std");
const posix = std.posix;
const zigstore = @import("zigstore");

pub const AtomicHistogram = zigstore.histogram.AtomicHistogram;

pub const REQUEST_HEADER_SIZE: usize = 8;

pub const RESPONSE_HEADER_SIZE: usize = 10;

const STATUS_OK: u8 = 0;

const LINK_BATCH: u64 = 100;

const BATCH_ITEM_BYTES: usize = 10;

pub const Op = enum(u8) {
    create_link = 1,
    create_category = 2,
    get_link = 3,
    browse_path = 11,
    list_children = 12,
    search = 14,
    list_subtree_links = 17,
    bulk_import = 24,
    ping = 255,
};

pub const FrameBuilder = struct {
    buf: []u8,
    pos: usize,

    pub fn init(buf: []u8, op: Op) FrameBuilder {
        buf[4] = @intFromEnum(op);
        buf[5] = 0;
        return .{ .buf = buf, .pos = REQUEST_HEADER_SIZE };
    }

    pub fn writeU8(self: *FrameBuilder, v: u8) void {
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    pub fn writeU16(self: *FrameBuilder, v: u16) void {
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .little);
        self.pos += 2;
    }

    pub fn writeU32(self: *FrameBuilder, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .little);
        self.pos += 4;
    }

    pub fn writeU64(self: *FrameBuilder, v: u64) void {
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .little);
        self.pos += 8;
    }

    pub fn writeBytes(self: *FrameBuilder, b: []const u8) void {
        @memcpy(self.buf[self.pos..][0..b.len], b);
        self.pos += b.len;
    }

    pub fn writeU16LenPrefixed(self: *FrameBuilder, b: []const u8) void {
        self.writeU16(@intCast(b.len));
        self.writeBytes(b);
    }

    pub fn finalize(self: *FrameBuilder, count: u16) []const u8 {
        std.mem.writeInt(u32, self.buf[0..4], @intCast(self.pos), .little);
        std.mem.writeInt(u16, self.buf[6..8], count, .little);
        return self.buf[0..self.pos];
    }
};

pub fn writeLinkItem(fb: *FrameBuilder, cat_id: u64, comptime url_fmt: []const u8, idx: u64) !void {
    var url_buf: [64]u8 = undefined;
    var title_buf: [32]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, url_fmt, .{idx});
    const title = try std.fmt.bufPrint(&title_buf, "L{d}", .{idx});
    fb.writeU64(cat_id);
    fb.writeU16LenPrefixed(url);
    fb.writeU16LenPrefixed(title);
    fb.writeU16LenPrefixed("");
}

pub fn sendAndReceive(stream_fd: i32, frame: []const u8, resp_buf: []u8) !usize {
    var sent: usize = 0;
    while (sent < frame.len) {
        const n = try posix.write(stream_fd, frame[sent..]);
        if (n == 0) return error.WriteEof;
        sent += n;
    }
    var read_total: usize = 0;
    while (read_total < RESPONSE_HEADER_SIZE) {
        const n = try posix.read(stream_fd, resp_buf[read_total..]);
        if (n == 0) return error.ReadEof;
        read_total += n;
    }
    const resp_len = std.mem.readInt(u32, resp_buf[0..4], .little);
    while (read_total < resp_len) {
        const n = try posix.read(stream_fd, resp_buf[read_total..]);
        if (n == 0) return error.ReadEof;
        read_total += n;
    }
    return resp_len;
}

pub fn tcpConnect(host: []const u8, port: u16) !i32 {
    const addr = try std.net.Address.parseIp(host, port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

pub fn ping(stream_fd: i32) !void {
    var req: [REQUEST_HEADER_SIZE]u8 = undefined;
    var fb = FrameBuilder.init(&req, .ping);
    const frame = fb.finalize(0);
    var resp_buf: [64]u8 = undefined;
    const n = try sendAndReceive(stream_fd, frame, &resp_buf);
    if (n < RESPONSE_HEADER_SIZE) return error.ProtocolError;
    if (resp_buf[5] != STATUS_OK) return error.PingFailed;
}

pub fn createCategory(
    stream_fd: i32,
    req_buf: []u8,
    resp_buf: []u8,
    parent_id: u64,
    name: []const u8,
    slug: []const u8,
    desc: []const u8,
) !u64 {
    var fb = FrameBuilder.init(req_buf, .create_category);
    fb.writeU64(parent_id);
    fb.writeU16LenPrefixed(name);
    fb.writeU16LenPrefixed(slug);
    fb.writeU16LenPrefixed(desc);
    const frame = fb.finalize(1);
    const resp_len = try sendAndReceive(stream_fd, frame, resp_buf);
    if (resp_len < RESPONSE_HEADER_SIZE + BATCH_ITEM_BYTES) return error.ProtocolError;
    if (resp_buf[5] != STATUS_OK) {
        std.debug.print("create_category failed: server status={d} sub={d}\n", .{ resp_buf[5], resp_buf[6] });
        return error.CreateCategoryFailed;
    }
    const item_status = resp_buf[RESPONSE_HEADER_SIZE];
    if (item_status != STATUS_OK) {
        const item_sub = resp_buf[RESPONSE_HEADER_SIZE + 1];
        std.debug.print("create_category item failed: status={d} sub={d}\n", .{ item_status, item_sub });
        return error.CreateCategoryFailed;
    }
    return std.mem.readInt(u64, resp_buf[RESPONSE_HEADER_SIZE + 2 ..][0..8], .little);
}

pub const IdRange = struct {
    min: u64 = 0,
    max: u64 = 0,

    pub fn pick(self: IdRange, rand: std.Random) u64 {
        return self.min + rand.uintLessThan(u64, self.max - self.min + 1);
    }
};

pub fn createLinksRoundRobin(
    stream_fd: i32,
    req_buf: []u8,
    resp_buf: []u8,
    cat_ids: []const u64,
    count: u64,
) !IdRange {
    var range = IdRange{};
    var sent: u64 = 0;
    while (sent < count) {
        const batch = @min(LINK_BATCH, count - sent);
        var fb = FrameBuilder.init(req_buf, .create_link);
        var bi: u64 = 0;
        while (bi < batch) : (bi += 1) {
            const cat_id = cat_ids[@intCast((sent + bi) % cat_ids.len)];
            try writeLinkItem(&fb, cat_id, "https://b{d}.t", sent + bi + 1);
        }
        const frame = fb.finalize(@intCast(batch));
        const resp_len = try sendAndReceive(stream_fd, frame, resp_buf);
        try collectBatchIds(resp_buf[0..resp_len], @intCast(batch), &range);
        sent += batch;
    }
    return range;
}

fn collectBatchIds(resp: []const u8, expected_count: u16, range: *IdRange) !void {
    if (resp.len < RESPONSE_HEADER_SIZE) return error.ProtocolError;
    if (resp[5] != STATUS_OK) return error.ProtocolError;
    const count = std.mem.readInt(u16, resp[8..10], .little);
    if (count != expected_count) return error.ProtocolError;
    var off: usize = RESPONSE_HEADER_SIZE;
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        if (off + BATCH_ITEM_BYTES > resp.len) return error.ProtocolError;
        if (resp[off] != STATUS_OK) return error.BatchItemFailed;
        const id = std.mem.readInt(u64, resp[off + 2 ..][0..8], .little);
        if (range.min == 0 or id < range.min) range.min = id;
        if (id > range.max) range.max = id;
        off += BATCH_ITEM_BYTES;
    }
}

pub fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

pub fn seedPath(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/seed.json", .{data_dir});
}

pub const SeedInfo = struct {
    category_id_min: u64,
    category_id_max: u64,
    link_id_min: u64,
    link_id_max: u64,
    sample_paths: []const []const u8 = &.{},
    sample_query_tokens: []const []const u8 = &.{},

    pub fn linkIds(self: SeedInfo) IdRange {
        return .{ .min = self.link_id_min, .max = self.link_id_max };
    }

    pub fn categoryIds(self: SeedInfo) IdRange {
        return .{ .min = self.category_id_min, .max = self.category_id_max };
    }
};

pub fn loadSeed(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(SeedInfo) {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(allocator, 1 << 24);
    defer allocator.free(data);
    return std.json.parseFromSlice(SeedInfo, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
}

pub const LatencyStats = struct {
    p50: u64,
    p95: u64,
    p99: u64,
    p99_9: u64,
    max: u64,
    mean: u64,
    samples: u64,
};

pub const RssStats = struct {
    peak: u64,
    final: u64,
    note: ?[]const u8,
};

pub const RSS_UNAVAILABLE = RssStats{ .peak = 0, .final = 0, .note = "rss_unavailable" };

pub const ErrorCounts = struct {
    connect_failed: u64,
    timeout: u64,
    protocol_error: u64,
};

pub const WorkloadParams = union(enum) {
    seed: struct { categories: u32, links: u64, depth: u32 },
    create_link: struct { workers: u32, batch_size: u32, ops_per_worker: u64 },
    get_link: struct { workers: u32, ops_per_worker: u64, seed_path: []const u8 },
    browse: struct { kind: []const u8, workers: u32, ops_per_worker: u64, seed_path: []const u8 },
    search: struct { target: []const u8, workers: u32, ops_per_worker: u64, query_corpus_size: u32 },
    mixed: struct { workers: u32, read_pct: u32, ops_per_worker: u64 },
    cold: struct { kind: []const u8, iterations: u32, server_cmd: []const u8 },

    pub fn jsonStringify(self: WorkloadParams, jw: *std.json.Stringify) !void {
        switch (self) {
            inline else => |payload| try jw.write(payload),
        }
    }
};

pub const BenchRecord = struct {
    schema_version: u32 = 1,
    ts: i64,
    host: []const u8,
    git_rev: []const u8,
    profile: []const u8,
    workload: []const u8,
    params: WorkloadParams,
    duration_ms: u64,
    ops_total: u64,
    ops_per_sec: u64,
    latency_ns: LatencyStats,
    rss_bytes: RssStats,
    errors: ErrorCounts,
};

pub fn appendJsonLine(allocator: std.mem.Allocator, output_path: ?[]const u8, record: BenchRecord) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, record, .{});
    defer allocator.free(json);
    const path = output_path orelse return writeLine(std.fs.File.stdout(), json);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer file.close();
    try file.seekFromEnd(0);
    try writeLine(file, json);
}

fn writeLine(file: std.fs.File, json: []const u8) !void {
    try file.writeAll(json);
    try file.writeAll("\n");
}

pub const RssSampler = struct {
    pid: i32,
    interval_ms: u64,
    thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    final: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn start(self: *RssSampler) !void {
        if (self.interval_ms == 0) return;
        self.thread = try std.Thread.spawn(.{}, sampleLoop, .{self});
    }

    pub fn stop(self: *RssSampler) void {
        self.shutdown.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    fn sampleLoop(self: *RssSampler) void {
        while (!self.shutdown.load(.acquire)) {
            std.Thread.sleep(self.interval_ms * std.time.ns_per_ms);
            const rss = readRssBytes(self.pid) catch |err| {
                std.log.warn("rss sample failed: {s}", .{@errorName(err)});
                continue;
            };
            while (true) {
                const cur = self.peak.load(.monotonic);
                if (rss <= cur) break;
                if (self.peak.cmpxchgWeak(cur, rss, .monotonic, .monotonic) == null) break;
            }
            self.final.store(rss, .monotonic);
        }
    }

    fn readRssBytes(pid: i32) !u64 {
        var path_buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/status", .{pid});
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();
        var buf: [4096]u8 = undefined;
        const n = try f.readAll(&buf);
        var lines = std.mem.tokenizeScalar(u8, buf[0..n], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "VmRSS:")) {
                var parts = std.mem.tokenizeAny(u8, line, " \t");
                _ = parts.next();
                const kb_str = parts.next() orelse return error.ParseError;
                const kb = try std.fmt.parseInt(u64, kb_str, 10);
                return kb * 1024;
            }
        }
        return error.NoVmRSS;
    }
};

pub const CommonOpts = struct {
    profile: []const u8 = "unconstrained",
    output_path: ?[]const u8 = null,
    workers: u32 = 4,
    ops_per_worker: u64 = 10000,
    warmup_ops: u64 = 1000,
    connect_host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    rss_sample_ms: u64 = 200,
    git_rev: ?[]const u8 = null,
};

pub fn parseCommonOpts(
    args: *std.process.ArgIterator,
    leftovers: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !CommonOpts {
    var opts = CommonOpts{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile")) {
            opts.profile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            opts.output_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const v = args.next() orelse return error.MissingValue;
            opts.workers = try std.fmt.parseInt(u32, v, 10);
        } else if (std.mem.eql(u8, arg, "--ops-per-worker")) {
            const v = args.next() orelse return error.MissingValue;
            opts.ops_per_worker = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--warmup-ops")) {
            const v = args.next() orelse return error.MissingValue;
            opts.warmup_ops = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--connect-host")) {
            opts.connect_host = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const v = args.next() orelse return error.MissingValue;
            opts.port = try std.fmt.parseInt(u16, v, 10);
        } else if (std.mem.eql(u8, arg, "--rss-sample-ms")) {
            const v = args.next() orelse return error.MissingValue;
            opts.rss_sample_ms = try std.fmt.parseInt(u64, v, 10);
        } else if (std.mem.eql(u8, arg, "--git-rev")) {
            opts.git_rev = args.next() orelse return error.MissingValue;
        } else {
            try leftovers.append(allocator, arg);
        }
    }
    return opts;
}

pub fn elapsedMs(since_ns: i128) u64 {
    const elapsed_ns: u64 = @intCast(std.time.nanoTimestamp() - since_ns);
    return elapsed_ns / std.time.ns_per_ms;
}

pub const Frame = struct {
    bytes: []const u8,
    ops: u64 = 1,
};

pub const Worker = struct {
    id: u32,
    rand: std.Random,
    req_buf: []u8,
    counter: u64 = 0,
    ops_completed: u64 = 0,
};

pub const Run = struct {
    allocator: std.mem.Allocator,
    opts: CommonOpts,
    histogram: AtomicHistogram = .{},
    ops_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connect_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    protocol_error: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    duration_ms: u64 = 0,
    rss: RssStats = RSS_UNAVAILABLE,

    pub fn init(allocator: std.mem.Allocator, opts: CommonOpts) Run {
        return .{ .allocator = allocator, .opts = opts };
    }

    pub fn runWorkers(self: *Run, comptime Ctx: type, ctx: *Ctx) !void {
        if (self.opts.workers == 0) return error.InvalidWorkers;

        const Main = struct {
            fn main(bench: *Run, c: *Ctx, id: u32) void {
                workerLoop(Ctx, bench, c, id) catch |err| {
                    std.log.warn("worker {d} fatal: {s}", .{ id, @errorName(err) });
                };
            }
        };

        const threads = try self.allocator.alloc(std.Thread, self.opts.workers);
        defer self.allocator.free(threads);

        const t_start = std.time.nanoTimestamp();
        for (threads, 0..) |*th, i| {
            th.* = try std.Thread.spawn(.{}, Main.main, .{ self, ctx, @as(u32, @intCast(i)) });
        }
        for (threads) |th| th.join();
        self.duration_ms = elapsedMs(t_start);
    }

    pub fn opsCompleted(self: *const Run) u64 {
        return self.ops_completed.load(.monotonic);
    }

    pub fn record(self: *const Run, workload: []const u8, params: WorkloadParams, ops_total: u64) BenchRecord {
        const h = &self.histogram;
        return .{
            .ts = std.time.milliTimestamp(),
            .host = posix.getenv("HOSTNAME") orelse "unknown",
            .git_rev = self.opts.git_rev orelse "unknown",
            .profile = self.opts.profile,
            .workload = workload,
            .params = params,
            .duration_ms = self.duration_ms,
            .ops_total = ops_total,
            .ops_per_sec = if (self.duration_ms > 0) ops_total * 1000 / self.duration_ms else 0,
            .latency_ns = .{
                .p50 = h.percentile(50.0),
                .p95 = h.percentile(95.0),
                .p99 = h.percentile(99.0),
                .p99_9 = h.percentile(99.9),
                .max = h.maxValue(),
                .mean = h.mean(),
                .samples = h.samples(),
            },
            .rss_bytes = self.rss,
            .errors = .{
                .connect_failed = self.connect_failed.load(.monotonic),
                .timeout = 0,
                .protocol_error = self.protocol_error.load(.monotonic),
            },
        };
    }

    pub fn emit(self: *const Run, workload: []const u8, params: WorkloadParams, ops_total: u64) !void {
        try appendJsonLine(self.allocator, self.opts.output_path, self.record(workload, params, ops_total));
    }
};

fn workerLoop(comptime Ctx: type, bench: *Run, ctx: *Ctx, id: u32) !void {
    const fd = tcpConnect(bench.opts.connect_host, bench.opts.port) catch {
        _ = bench.connect_failed.fetchAdd(1, .monotonic);
        return;
    };
    defer posix.close(fd);

    const req_buf = try bench.allocator.alloc(u8, Ctx.REQ_BUF_SIZE);
    defer bench.allocator.free(req_buf);
    const resp_buf = try bench.allocator.alloc(u8, Ctx.RESP_BUF_SIZE);
    defer bench.allocator.free(resp_buf);

    const seed: u64 = if (@hasDecl(Ctx, "prngSeed")) Ctx.prngSeed(id) else id;
    var prng = std.Random.DefaultPrng.init(seed);
    var worker = Worker{ .id = id, .rand = prng.random(), .req_buf = req_buf };
    defer _ = bench.ops_completed.fetchAdd(worker.ops_completed, .monotonic);

    while (worker.ops_completed < bench.opts.ops_per_worker) {
        const frame = try ctx.nextFrame(&worker);

        const t0 = std.time.nanoTimestamp();
        const resp_len = sendAndReceive(fd, frame.bytes, resp_buf) catch {
            _ = bench.protocol_error.fetchAdd(1, .monotonic);
            return;
        };
        const latency_ns: u64 = @intCast(std.time.nanoTimestamp() - t0);

        if (resp_len < RESPONSE_HEADER_SIZE or !accepted(Ctx, ctx, resp_buf[0..resp_len], latency_ns)) {
            _ = bench.protocol_error.fetchAdd(1, .monotonic);
            return;
        }

        if (worker.ops_completed >= bench.opts.warmup_ops) bench.histogram.recordValue(latency_ns);
        worker.ops_completed += frame.ops;
    }
}

fn accepted(comptime Ctx: type, ctx: *Ctx, resp: []const u8, latency_ns: u64) bool {
    if (!@hasDecl(Ctx, "onResponse")) return true;
    return ctx.onResponse(resp, latency_ns);
}

test "FrameBuilder: round-trip a create_link frame" {
    var buf: [256]u8 = undefined;
    var fb = FrameBuilder.init(&buf, .create_link);
    fb.writeU64(42);
    fb.writeU16LenPrefixed("https://example.com");
    fb.writeU16LenPrefixed("Example");
    fb.writeU16LenPrefixed("");
    const frame = fb.finalize(1);

    const len = std.mem.readInt(u32, frame[0..4], .little);
    try std.testing.expectEqual(frame.len, len);
    try std.testing.expectEqual(@as(u8, 1), frame[4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, frame[6..8], .little));
}

test "Run.record: an empty histogram reports all-zero latency so seed keeps its baseline shape" {
    const bench = Run.init(std.testing.allocator, .{});
    const rec = bench.record("seed", .{ .seed = .{ .categories = 1, .links = 1, .depth = 1 } }, 2);
    try std.testing.expectEqual(@as(u64, 0), rec.latency_ns.p99);
    try std.testing.expectEqual(@as(u64, 0), rec.latency_ns.mean);
    try std.testing.expectEqual(@as(u64, 0), rec.latency_ns.samples);
    try std.testing.expectEqual(@as(u64, 0), rec.ops_per_sec);
    try std.testing.expectEqualStrings("rss_unavailable", rec.rss_bytes.note.?);
}

test "appendJsonLine: appends one JSONL line per record" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const file = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.jsonl", .{path});
    defer std.testing.allocator.free(file);

    const rec = BenchRecord{
        .ts = 1714838400000,
        .host = "test",
        .git_rev = "deadbeef",
        .profile = "unconstrained",
        .workload = "create_link",
        .params = .{ .create_link = .{ .workers = 4, .batch_size = 10, .ops_per_worker = 1000 } },
        .duration_ms = 1234,
        .ops_total = 4000,
        .ops_per_sec = 3243,
        .latency_ns = .{ .p50 = 100, .p95 = 200, .p99 = 300, .p99_9 = 400, .max = 500, .mean = 150, .samples = 4000 },
        .rss_bytes = RSS_UNAVAILABLE,
        .errors = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    };
    try appendJsonLine(std.testing.allocator, file, rec);
    try appendJsonLine(std.testing.allocator, file, rec);

    const f = try std.fs.cwd().openFile(file, .{});
    defer f.close();
    const contents = try f.readToEndAlloc(std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "\n"));
}
