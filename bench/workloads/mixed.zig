const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

// `bench mixed` — RW workload with --read-pct controlling the
// get_link / create_link split. Reads draw random IDs from the seeded
// link range; writes use a per-worker monotonic counter (offset by
// worker id) so concurrent workers never collide on URL.

const HEADER_SIZE = common.HEADER_SIZE;

const Opts = struct {
    read_pct: ?u32 = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Op = enum(u8) {
    create_link = 1,
    get_link = 3,
};

const SeedInfo = struct {
    link_id_min: u64,
    link_id_max: u64,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    if (common_opts.workers == 0) return error.InvalidWorkers;
    const read_pct = opts.read_pct orelse {
        std.debug.print("mixed: --read-pct PCT (0..100) is required\n", .{});
        return error.MissingReadPct;
    };
    if (read_pct > 100) return error.InvalidReadPct;

    // ── Load seed.json ───────────────────────────────────────────
    const seed_path = try std.fmt.allocPrint(allocator, "{s}/seed.json", .{opts.data_dir});
    defer allocator.free(seed_path);
    const seed = try loadSeed(allocator, seed_path);

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
            .read_pct = read_pct,
            .link_id_min = seed.link_id_min,
            .link_id_max = seed.link_id_max,
        };
    }
    for (ctxs, threads) |*ctx, *th| {
        th.* = try std.Thread.spawn(.{}, workerMain, .{ctx});
    }
    for (threads) |th| th.join();

    const t_end = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(t_end - t_start);
    const duration_ms: u64 = duration_ns / std.time.ns_per_ms;

    // ── Merge ────────────────────────────────────────────────────
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
        .workload = "mixed",
        .params = .{ .mixed = .{
            .workers = common_opts.workers,
            .read_pct = read_pct,
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
    read_pct: u32,
    link_id_min: u64,
    link_id_max: u64,
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

    const req_buf = std.heap.page_allocator.alloc(u8, 1 << 14) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(req_buf);
    const resp_buf = std.heap.page_allocator.alloc(u8, 1 << 14) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(resp_buf);

    var prng = std.Random.DefaultPrng.init(ctx.id);
    const rand = prng.random();
    const span: u64 = ctx.link_id_max - ctx.link_id_min + 1;
    var write_counter: u64 = @as(u64, ctx.id) * 10_000_000;

    while (ctx.ops_completed < ctx.ops_per_worker) {
        const die = rand.intRangeAtMost(u32, 1, 100);
        const frame = if (die <= ctx.read_pct) blk: {
            // Read: get_link
            const link_id = ctx.link_id_min + rand.uintLessThan(u64, span);
            var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.get_link));
            fb.writeU64(link_id);
            break :blk fb.finalize(1);
        } else blk: {
            // Write: create_link batch=1
            write_counter += 1;
            var url_buf: [64]u8 = undefined;
            var title_buf: [32]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://b{d}.t", .{write_counter}) catch unreachable;
            const title = std.fmt.bufPrint(&title_buf, "L{d}", .{write_counter}) catch unreachable;
            var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.create_link));
            fb.writeU64(1); // category_id = top
            fb.writeU16LenPrefixed(url);
            fb.writeU16LenPrefixed(title);
            fb.writeU16LenPrefixed("");
            break :blk fb.finalize(1);
        };

        const t0 = std.time.nanoTimestamp();
        const resp_len = common.sendAndReceive(fd, frame, resp_buf) catch {
            ctx.errors.protocol_error += 1;
            return;
        };
        const t1 = std.time.nanoTimestamp();

        if (resp_len < common.RESPONSE_HEADER_SIZE) {
            ctx.errors.protocol_error += 1;
            return;
        }

        if (ctx.ops_completed >= ctx.warmup_ops) {
            ctx.histogram.recordValue(@intCast(t1 - t0));
        }
        ctx.ops_completed += 1;
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
        if (std.mem.eql(u8, arg, "--read-pct")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.read_pct = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else {
            std.debug.print("mixed: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn loadSeed(allocator: std.mem.Allocator, path: []const u8) !SeedInfo {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(allocator, 1 << 24);
    defer allocator.free(data);

    const Parsed = struct {
        link_id_min: u64,
        link_id_max: u64,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, data, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return .{
        .link_id_min = parsed.value.link_id_min,
        .link_id_max = parsed.value.link_id_max,
    };
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
