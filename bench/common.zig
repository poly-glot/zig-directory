const std = @import("std");
const posix = std.posix;

// Shared bench infrastructure. Tasks 2-5 of the implementation plan.

/// Request frames carry an 8-byte header — request format is unchanged.
pub const REQUEST_HEADER_SIZE: usize = 8;

/// Response frames carry a 10-byte header (status + sub_status + reserved + count).
pub const RESPONSE_HEADER_SIZE: usize = 10;

/// Back-compat alias used by the FrameBuilder (which constructs request
/// frames). All request-side callers should treat HEADER_SIZE as the
/// request header width.
pub const HEADER_SIZE: usize = REQUEST_HEADER_SIZE;

// ────────────────────────────────────────────────────────────────────────────
// Task 2 — TCP framing helpers
// ────────────────────────────────────────────────────────────────────────────

pub const FrameBuilder = struct {
    buf: []u8,
    pos: usize,

    pub fn init(buf: []u8, op: u8) FrameBuilder {
        // Reserve header; finalize() back-patches length.
        buf[4] = op;
        buf[5] = 0; // flags
        return .{ .buf = buf, .pos = HEADER_SIZE };
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

/// Send a frame and read the full response. Returns the response length.
///
/// First reads the 10-byte response header (so workloads that index into
/// `resp_buf[5]` for status, `resp_buf[6]` for sub_status, etc. observe a
/// fully-populated header), then keeps reading until the full frame is
/// drained. Response length includes the 10-byte header.
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

// ────────────────────────────────────────────────────────────────────────────
// Task 3 — HDR-lite Histogram
// ────────────────────────────────────────────────────────────────────────────

/// Log-linear histogram: 32 octaves × 64 sub-buckets covers 1 ns
/// to ~4 s with ±1.5% resolution. ~7.5 KB per histogram.
const NUM_OCTAVES: usize = 32;
const SUB_BUCKETS: usize = 64;

pub const Histogram = struct {
    buckets: [NUM_OCTAVES][SUB_BUCKETS]u32 = [_][SUB_BUCKETS]u32{[_]u32{0} ** SUB_BUCKETS} ** NUM_OCTAVES,
    total_count: u64 = 0,
    max_recorded: u64 = 0,
    sum: u64 = 0,

    pub fn recordValue(self: *Histogram, ns: u64) void {
        self.total_count += 1;
        self.sum += ns;
        if (ns > self.max_recorded) self.max_recorded = ns;
        if (ns == 0) {
            self.buckets[0][0] += 1;
            return;
        }
        // Octave = log2(ns); sub-bucket interpolates within the octave.
        const octave = @as(usize, @intCast(63 - @clz(ns)));
        const o = @min(octave, NUM_OCTAVES - 1);
        // Linear sub-bucket within [2^octave, 2^(octave+1)).
        const base: u64 = @as(u64, 1) << @intCast(o);
        const offset = ns - base;
        const sub = @min(@as(usize, @intCast((offset * SUB_BUCKETS) / base)), SUB_BUCKETS - 1);
        self.buckets[o][sub] += 1;
    }

    pub fn percentile(self: *const Histogram, pct: f64) u64 {
        if (self.total_count == 0) return 0;
        const target = @as(u64, @intFromFloat(@as(f64, @floatFromInt(self.total_count)) * pct / 100.0));
        var cum: u64 = 0;
        var o: usize = 0;
        while (o < NUM_OCTAVES) : (o += 1) {
            var s: usize = 0;
            while (s < SUB_BUCKETS) : (s += 1) {
                cum += self.buckets[o][s];
                if (cum >= target) {
                    const base: u64 = if (o == 0) 0 else @as(u64, 1) << @intCast(o);
                    const span: u64 = if (o == 0) SUB_BUCKETS else @as(u64, 1) << @intCast(o);
                    return base + (@as(u64, s) * span) / SUB_BUCKETS;
                }
            }
        }
        return self.max_recorded;
    }

    pub fn merge(self: *Histogram, other: *const Histogram) void {
        self.total_count += other.total_count;
        self.sum += other.sum;
        if (other.max_recorded > self.max_recorded) self.max_recorded = other.max_recorded;
        var o: usize = 0;
        while (o < NUM_OCTAVES) : (o += 1) {
            var s: usize = 0;
            while (s < SUB_BUCKETS) : (s += 1) {
                self.buckets[o][s] += other.buckets[o][s];
            }
        }
    }

    pub fn mean(self: *const Histogram) u64 {
        if (self.total_count == 0) return 0;
        return self.sum / self.total_count;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Task 4 — JSON Lines writer + BenchRecord schema
// ────────────────────────────────────────────────────────────────────────────

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

pub const ErrorCounts = struct {
    connect_failed: u64,
    timeout: u64,
    protocol_error: u64,
};

/// Tagged union of workload-specific parameters. Custom `jsonStringify`
/// flattens the active variant to a plain object (so the JSON shape is
/// `"params": { workers: ... }`, not `"params": { "create_link": {...} }`).
pub const WorkloadParams = union(enum) {
    seed: struct { categories: u32, links: u64, depth: u32 },
    create_link: struct { workers: u32, batch_size: u32, ops_per_worker: u64 },
    get_link: struct { workers: u32, ops_per_worker: u64, seed_path: []const u8 },
    browse: struct { kind: []const u8, workers: u32, ops_per_worker: u64, seed_path: []const u8 },
    search: struct { target: []const u8, workers: u32, ops_per_worker: u64, query_corpus_size: u32 },
    mixed: struct { workers: u32, read_pct: u32, ops_per_worker: u64 },
    cold: struct { kind: []const u8, iterations: u32, server_cmd: []const u8 },

    pub fn jsonStringify(self: WorkloadParams, jw: *std.json.Stringify) !void {
        // Emit the active variant's payload struct directly, without the
        // tag-name wrapper that std.json's default union encoder produces.
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

pub const JsonLineWriter = struct {
    file: std.fs.File,
    mutex: std.Thread.Mutex = .{},

    pub fn open(path: []const u8) !JsonLineWriter {
        // Create-or-open without truncation; seek to end so we append.
        const file = try std.fs.cwd().createFile(path, .{ .read = false, .truncate = false });
        try file.seekFromEnd(0);
        return .{ .file = file };
    }

    pub fn appendRecord(self: *JsonLineWriter, record: BenchRecord) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const json = try std.json.Stringify.valueAlloc(std.heap.page_allocator, record, .{});
        defer std.heap.page_allocator.free(json);
        try self.file.writeAll(json);
        try self.file.writeAll("\n");
    }

    pub fn close(self: *JsonLineWriter) void {
        self.file.close();
    }
};

// ────────────────────────────────────────────────────────────────────────────
// Task 5 — RSS sampler + WorkerCtx + CommonOpts parsing
// ────────────────────────────────────────────────────────────────────────────

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
            // Update peak with a CAS retry loop.
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
                _ = parts.next(); // "VmRSS:"
                const kb_str = parts.next() orelse return error.ParseError;
                const kb = try std.fmt.parseInt(u64, kb_str, 10);
                return kb * 1024;
            }
        }
        return error.NoVmRSS;
    }
};

pub const WorkerCtx = struct {
    id: u32,
    ops_per_worker: u64,
    warmup_ops: u64,
    histogram: Histogram = .{},
    errors: ErrorCounts = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    ops_completed: u64 = 0,
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

/// Parse common bench flags from `args`. Unknown flags (and any value paired
/// with them) are appended to `leftovers` for the workload-specific parser to
/// handle. The caller owns `leftovers` and is responsible for freeing it; the
/// stored slices are owned by `args`'s iterator and live as long as it does.
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

// ────────────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────────────

test "FrameBuilder: round-trip a create_link frame" {
    var buf: [256]u8 = undefined;
    var fb = FrameBuilder.init(&buf, 1); // op = create_link
    fb.writeU64(42); // category_id
    fb.writeU16LenPrefixed("https://example.com");
    fb.writeU16LenPrefixed("Example");
    fb.writeU16LenPrefixed("");
    const frame = fb.finalize(1); // count = 1

    const len = std.mem.readInt(u32, frame[0..4], .little);
    try std.testing.expectEqual(frame.len, len);
    try std.testing.expectEqual(@as(u8, 1), frame[4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, frame[6..8], .little));
}

test "Histogram: percentile resolution within 2% of true value" {
    var h = Histogram{};
    // Insert 1000 samples uniformly from 1us to 1ms.
    var i: u64 = 0;
    while (i < 1000) : (i += 1) {
        h.recordValue(1_000 + i * 1_000); // 1us..1ms in 1us steps
    }
    // True p50 ≈ 500us = 500_000 ns.
    const p50 = h.percentile(50.0);
    try std.testing.expect(p50 > 490_000 and p50 < 510_000);
    // True p99 ≈ 990us = 990_000 ns.
    const p99 = h.percentile(99.0);
    try std.testing.expect(p99 > 970_000 and p99 < 1_010_000);
}

test "Histogram: merge sums counts" {
    var a = Histogram{};
    var b = Histogram{};
    a.recordValue(100_000);
    a.recordValue(200_000);
    b.recordValue(300_000);
    a.merge(&b);
    try std.testing.expectEqual(@as(u64, 3), a.total_count);
    try std.testing.expectEqual(@as(u64, 300_000), a.max_recorded);
}

test "JsonLineWriter: appends valid JSONL lines" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const file = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.jsonl", .{path});
    defer std.testing.allocator.free(file);

    var w = try JsonLineWriter.open(file);
    defer w.close();

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
        .rss_bytes = .{ .peak = 100_000_000, .final = 90_000_000, .note = null },
        .errors = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    };
    try w.appendRecord(rec);
    try w.appendRecord(rec);

    // Read back and verify two valid JSON lines.
    const f = try std.fs.cwd().openFile(file, .{});
    defer f.close();
    const contents = try f.readToEndAlloc(std.testing.allocator, 1 << 20);
    defer std.testing.allocator.free(contents);
    var newline_count: usize = 0;
    for (contents) |b| {
        if (b == '\n') newline_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), newline_count);
}
