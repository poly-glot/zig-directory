const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

// `bench search` — full-text search workload. Builds a small query
// corpus from seed.json sample tokens (singletons + pairs) and picks
// one per op. `--target` is recorded as metadata; the server returns
// both categories and links per request regardless.

const HEADER_SIZE = common.HEADER_SIZE;

const Target = enum { links, categories };

const Opts = struct {
    target: ?Target = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Op = enum(u8) {
    search = 14,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    if (common_opts.workers == 0) return error.InvalidWorkers;
    const target = opts.target orelse {
        std.debug.print("search: --target {{links|categories}} is required\n", .{});
        return error.MissingTarget;
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // ── Load seed.json + build corpus ────────────────────────────
    const seed_path = try std.fmt.allocPrint(allocator, "{s}/seed.json", .{opts.data_dir});
    defer allocator.free(seed_path);
    const tokens = try loadTokens(arena.allocator(), seed_path);
    const corpus = try buildCorpus(arena.allocator(), tokens);
    if (corpus.len == 0) {
        std.debug.print("search: empty query corpus\n", .{});
        return error.EmptyCorpus;
    }

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
            .corpus = corpus,
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

    const target_str: []const u8 = switch (target) {
        .links => "links",
        .categories => "categories",
    };

    const record = common.BenchRecord{
        .ts = std.time.milliTimestamp(),
        .host = host,
        .git_rev = git_rev,
        .profile = common_opts.profile,
        .workload = "search",
        .params = .{ .search = .{
            .target = target_str,
            .workers = common_opts.workers,
            .ops_per_worker = common_opts.ops_per_worker,
            .query_corpus_size = @intCast(corpus.len),
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
    corpus: []const []const u8,
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
    const resp_buf = std.heap.page_allocator.alloc(u8, 1 << 20) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(resp_buf);

    var prng = std.Random.DefaultPrng.init(ctx.id);
    const rand = prng.random();

    while (ctx.ops_completed < ctx.ops_per_worker) {
        const query = ctx.corpus[rand.uintLessThan(usize, ctx.corpus.len)];
        var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.search));
        fb.writeU16LenPrefixed(query);
        fb.writeU32(50); // limit
        const frame = fb.finalize(1);

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
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const v = leftovers[i];
            if (std.mem.eql(u8, v, "links")) {
                opts.target = .links;
            } else if (std.mem.eql(u8, v, "categories")) {
                opts.target = .categories;
            } else {
                std.debug.print("search: invalid --target: {s}\n", .{v});
                return error.InvalidTarget;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else {
            std.debug.print("search: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn loadTokens(arena: std.mem.Allocator, path: []const u8) ![]const []const u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const data = try f.readToEndAlloc(arena, 1 << 24);

    const Parsed = struct {
        sample_query_tokens: []const []const u8,
    };
    const parsed = try std.json.parseFromSliceLeaky(Parsed, arena, data, .{ .ignore_unknown_fields = true });
    return parsed.sample_query_tokens;
}

/// Up to ~20 single-token queries + ~10 two-token combinations.
/// All slices are arena-owned and stable for the bench's lifetime.
fn buildCorpus(arena: std.mem.Allocator, tokens: []const []const u8) ![]const []const u8 {
    const max_singletons: usize = @min(tokens.len, 20);
    const max_pairs: usize = if (tokens.len < 2) 0 else 10;

    var list: std.ArrayList([]const u8) = .{};
    var i: usize = 0;
    while (i < max_singletons) : (i += 1) {
        try list.append(arena, tokens[i]);
    }
    var pairs_added: usize = 0;
    var a: usize = 0;
    outer: while (a < tokens.len) : (a += 1) {
        var b: usize = a + 1;
        while (b < tokens.len) : (b += 1) {
            const joined = try std.fmt.allocPrint(arena, "{s} {s}", .{ tokens[a], tokens[b] });
            try list.append(arena, joined);
            pairs_added += 1;
            if (pairs_added >= max_pairs) break :outer;
        }
    }
    return list.items;
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
