const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

// `bench create_link` — write-hammer workload. Each worker holds an
// independent TCP connection and pushes batched create_link frames as
// fast as the server will accept them. Records per-frame latency into
// an HDR-lite histogram and emits a single JSONL bench record.

const HEADER_SIZE = common.HEADER_SIZE;

const Opts = struct {
    batch: u32 = 10,
};

const Op = enum(u8) {
    create_link = 1,
    ping = 255,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    if (common_opts.workers == 0) return error.InvalidWorkers;
    if (opts.batch == 0) return error.InvalidBatch;

    // ── Spawn worker threads ─────────────────────────────────────
    const ctxs = try allocator.alloc(WorkerCtx, common_opts.workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, common_opts.workers);
    defer allocator.free(threads);

    const t_start = std.time.nanoTimestamp();

    for (ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .id = @intCast(i),
            .host = common_opts.connect_host,
            .port = common_opts.port,
            .ops_per_worker = common_opts.ops_per_worker,
            .warmup_ops = common_opts.warmup_ops,
            .batch = opts.batch,
        };
    }
    for (ctxs, threads) |*ctx, *th| {
        th.* = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }
    for (threads) |th| th.join();

    const t_end = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(t_end - t_start);
    const duration_ms: u64 = duration_ns / std.time.ns_per_ms;

    // ── Merge histograms / errors ────────────────────────────────
    var merged = common.Histogram{};
    var errors = common.ErrorCounts{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 };
    var ops_total: u64 = 0;
    for (ctxs) |*ctx| {
        merged.merge(&ctx.histogram);
        errors.connect_failed += ctx.errors.connect_failed;
        errors.timeout += ctx.errors.timeout;
        errors.protocol_error += ctx.errors.protocol_error;
        ops_total += ctx.ops_completed;
    }

    const ops_per_sec: u64 = if (duration_ms > 0) ops_total * 1000 / duration_ms else 0;

    const host = std.posix.getenv("HOSTNAME") orelse "unknown";
    const git_rev: []const u8 = common_opts.git_rev orelse "unknown";

    const record = common.BenchRecord{
        .ts = std.time.milliTimestamp(),
        .host = host,
        .git_rev = git_rev,
        .profile = common_opts.profile,
        .workload = "create_link",
        .params = .{ .create_link = .{
            .workers = common_opts.workers,
            .batch_size = opts.batch,
            .ops_per_worker = common_opts.ops_per_worker,
        } },
        .duration_ms = duration_ms,
        .ops_total = ops_total,
        .ops_per_sec = ops_per_sec,
        .latency_ns = .{
            .p50 = merged.percentile(50.0),
            .p95 = merged.percentile(95.0),
            .p99 = merged.percentile(99.0),
            .p99_9 = merged.percentile(99.9),
            .max = merged.max_recorded,
            .mean = merged.mean(),
            .samples = merged.total_count,
        },
        .rss_bytes = .{ .peak = 0, .final = 0, .note = "rss_unavailable" },
        .errors = errors,
    };

    try emitRecord(allocator, common_opts.output_path, record);
}

// ─────────────────────────────────────────────────────────────────
// Worker
// ─────────────────────────────────────────────────────────────────

const WorkerCtx = struct {
    id: u32,
    host: []const u8,
    port: u16,
    ops_per_worker: u64,
    warmup_ops: u64,
    batch: u32,
    histogram: common.Histogram = .{},
    errors: common.ErrorCounts = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    ops_completed: u64 = 0,
};

fn workerMain(ctx: *WorkerCtx) void {
    workerRun(ctx) catch |err| {
        std.log.warn("worker {d} fatal: {s}", .{ ctx.id, @errorName(err) });
    };
}

fn workerRun(ctx: *WorkerCtx) !void {
    const fd = tcpConnect(ctx.host, ctx.port) catch {
        ctx.errors.connect_failed += 1;
        return;
    };
    defer posix.close(fd);

    const req_buf_storage = std.heap.page_allocator.alloc(u8, 1 << 20) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(req_buf_storage);
    const resp_buf_storage = std.heap.page_allocator.alloc(u8, 1 << 20) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(resp_buf_storage);

    var counter: u64 = @as(u64, ctx.id) * 10_000_000;

    while (ctx.ops_completed < ctx.ops_per_worker) {
        var fb = common.FrameBuilder.init(req_buf_storage, @intFromEnum(Op.create_link));
        var bi: u32 = 0;
        while (bi < ctx.batch) : (bi += 1) {
            counter += 1;
            var url_buf: [64]u8 = undefined;
            var title_buf: [32]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://b{d}.t", .{counter}) catch unreachable;
            const title = std.fmt.bufPrint(&title_buf, "L{d}", .{counter}) catch unreachable;
            fb.writeU64(1); // category_id = top
            fb.writeU16LenPrefixed(url);
            fb.writeU16LenPrefixed(title);
            fb.writeU16LenPrefixed("");
        }
        const frame = fb.finalize(@intCast(ctx.batch));

        const t0 = std.time.nanoTimestamp();
        const resp_len = common.sendAndReceive(fd, frame, resp_buf_storage) catch {
            ctx.errors.protocol_error += 1;
            return;
        };
        const t1 = std.time.nanoTimestamp();

        if (resp_len < common.RESPONSE_HEADER_SIZE or resp_buf_storage[5] != 0) {
            ctx.errors.protocol_error += 1;
            return;
        }

        if (ctx.ops_completed >= ctx.warmup_ops) {
            ctx.histogram.recordValue(@intCast(t1 - t0));
        }
        ctx.ops_completed += ctx.batch;
    }
}

// ─────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────

fn parseOpts(leftovers: []const []const u8) !Opts {
    var opts = Opts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--batch")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.batch = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else {
            std.debug.print("create_link: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn tcpConnect(host: []const u8, port: u16) !i32 {
    const addr = try std.net.Address.parseIp(host, port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

fn emitRecord(allocator: std.mem.Allocator, output_path: ?[]const u8, record: common.BenchRecord) !void {
    if (output_path) |path| {
        var w = try common.JsonLineWriter.open(path);
        defer w.close();
        try w.appendRecord(record);
    } else {
        const json = try std.json.Stringify.valueAlloc(allocator, record, .{});
        defer allocator.free(json);
        var stdout_buf: [4096]u8 = undefined;
        var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
        const w = &stdout_writer.interface;
        try w.writeAll(json);
        try w.writeAll("\n");
        try w.flush();
    }
}
