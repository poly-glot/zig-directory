const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

// `bench cold` — server-lifecycle-aware workload with two sub-modes:
//   --kind=cache  : measure read latency on a freshly-booted server (cold
//                   internal caches), with stderr-only warmup gradient.
//   --kind=boot   : measure cold-boot wall-clock duration (spawn → first
//                   successful ping) over N iterations.
//
// In both modes, bench owns the server: it spawns dmozdb, waits for ping,
// runs its measurements, then SIGTERMs the child. Reseeding (--reseed)
// runs an inline mini-seed if seed.json is missing.

const HEADER_SIZE = common.HEADER_SIZE;

const Kind = enum { cache, boot };

const ColdOpts = struct {
    kind: ?Kind = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
    server_cmd: ?[]const u8 = null,
    reseed: bool = false,
};

const Op = enum(u8) {
    create_link = 1,
    create_category = 2,
    get_link = 3,
    ping = 255,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseColdOpts(leftovers.items);

    const kind = opts.kind orelse {
        std.debug.print("cold: --kind {{cache|boot}} is required\n", .{});
        return error.MissingKind;
    };
    const server_cmd = opts.server_cmd orelse {
        std.debug.print("cold: --server-cmd CMD is required\n", .{});
        return error.MissingServerCmd;
    };

    try ensureDir(opts.data_dir);

    switch (kind) {
        .cache => try runCache(allocator, common_opts, opts, server_cmd),
        .boot => try runBoot(allocator, common_opts, opts, server_cmd),
    }
}

// ─────────────────────────────────────────────────────────────────
// Sub-mode: cold cache
// ─────────────────────────────────────────────────────────────────

fn runCache(
    allocator: std.mem.Allocator,
    common_opts: common.CommonOpts,
    opts: ColdOpts,
    server_cmd: []const u8,
) !void {
    // 1. Make sure seed.json exists. Optionally reseed inline.
    try ensureSeed(allocator, opts, server_cmd, common_opts);

    const seed_path = try std.fmt.allocPrint(allocator, "{s}/seed.json", .{opts.data_dir});
    defer allocator.free(seed_path);
    const seed = try loadSeed(allocator, seed_path);

    // 2. Spawn server (fresh process → cold internal cache).
    var child = try spawnServer(allocator, server_cmd, opts.data_dir);
    defer killChild(&child);

    // 3. Wait for ping.
    try waitForPing(common_opts.connect_host, common_opts.port, 10_000);

    // 4. Run a single-threaded read sweep with windowed histograms so the
    //    warmup-vs-steady gradient is visible on stderr. We collapse the
    //    canonical record's `latency_ns` to the OVERALL stats (matching
    //    the standard schema). The per-window curve goes to stderr.
    const total_ops: u64 = @as(u64, common_opts.workers) * common_opts.ops_per_worker;
    if (total_ops == 0) return error.NoOps;

    var window_a = common.Histogram{}; // ops 0..1000
    var window_b = common.Histogram{}; // ops 1000..5000
    var window_c = common.Histogram{}; // ops 5000..end
    var overall = common.Histogram{};

    // Worker threads share the windowing scheme by op-index. To keep the
    // bucketing well-defined under concurrency, we serialize bucket choice
    // on a global atomic counter — the i-th measured op (across workers)
    // lands in the bucket that op-index dictates.
    const ctxs = try allocator.alloc(CacheCtx, common_opts.workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, common_opts.workers);
    defer allocator.free(threads);

    var op_counter = std.atomic.Value(u64).init(0);
    const t_start = std.time.nanoTimestamp();

    for (ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .id = @intCast(i),
            .host = common_opts.connect_host,
            .port = common_opts.port,
            .ops_per_worker = common_opts.ops_per_worker,
            .link_id_min = seed.link_id_min,
            .link_id_max = seed.link_id_max,
            .global_op_counter = &op_counter,
        };
    }
    for (ctxs, threads) |*ctx, *th| {
        th.* = try std.Thread.spawn(.{}, cacheWorkerMain, .{ctx});
    }
    for (threads) |th| th.join();

    const t_end = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(t_end - t_start);
    const duration_ms: u64 = duration_ns / std.time.ns_per_ms;

    // Merge worker histograms.
    var errors = common.ErrorCounts{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 };
    var ops_total: u64 = 0;
    for (ctxs) |*ctx| {
        window_a.merge(&ctx.window_a);
        window_b.merge(&ctx.window_b);
        window_c.merge(&ctx.window_c);
        overall.merge(&ctx.overall);
        errors.connect_failed += ctx.errors.connect_failed;
        errors.timeout += ctx.errors.timeout;
        errors.protocol_error += ctx.errors.protocol_error;
        ops_total += ctx.ops_completed;
    }

    // Log per-window p50/p95/p99 to stderr (informational only).
    std.debug.print(
        "cold-cache curve (n={d}): " ++
            "win[0..1000]      p50={d}us p95={d}us p99={d}us samples={d}\n" ++
            "                  win[1000..5000]   p50={d}us p95={d}us p99={d}us samples={d}\n" ++
            "                  win[5000..end]    p50={d}us p95={d}us p99={d}us samples={d}\n",
        .{
            ops_total,
            window_a.percentile(50.0) / 1000,
            window_a.percentile(95.0) / 1000,
            window_a.percentile(99.0) / 1000,
            window_a.total_count,
            window_b.percentile(50.0) / 1000,
            window_b.percentile(95.0) / 1000,
            window_b.percentile(99.0) / 1000,
            window_b.total_count,
            window_c.percentile(50.0) / 1000,
            window_c.percentile(95.0) / 1000,
            window_c.percentile(99.0) / 1000,
            window_c.total_count,
        },
    );

    const ops_per_sec: u64 = if (duration_ms > 0) ops_total * 1000 / duration_ms else 0;
    const host = std.posix.getenv("HOSTNAME") orelse "unknown";
    const git_rev: []const u8 = common_opts.git_rev orelse "unknown";

    const record = common.BenchRecord{
        .ts = std.time.milliTimestamp(),
        .host = host,
        .git_rev = git_rev,
        .profile = common_opts.profile,
        .workload = "cold",
        .params = .{ .cold = .{
            .kind = "cache",
            .iterations = 1,
            .server_cmd = server_cmd,
        } },
        .duration_ms = duration_ms,
        .ops_total = ops_total,
        .ops_per_sec = ops_per_sec,
        .latency_ns = .{
            .p50 = overall.percentile(50.0),
            .p95 = overall.percentile(95.0),
            .p99 = overall.percentile(99.0),
            .p99_9 = overall.percentile(99.9),
            .max = overall.max_recorded,
            .mean = overall.mean(),
            .samples = overall.total_count,
        },
        .rss_bytes = .{ .peak = 0, .final = 0, .note = "rss_unavailable" },
        .errors = errors,
    };

    try emitRecord(allocator, common_opts.output_path, record);
}

const CacheCtx = struct {
    id: u32,
    host: []const u8,
    port: u16,
    ops_per_worker: u64,
    link_id_min: u64,
    link_id_max: u64,
    global_op_counter: *std.atomic.Value(u64),
    window_a: common.Histogram = .{},
    window_b: common.Histogram = .{},
    window_c: common.Histogram = .{},
    overall: common.Histogram = .{},
    errors: common.ErrorCounts = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    ops_completed: u64 = 0,
};

fn cacheWorkerMain(ctx: *CacheCtx) void {
    cacheWorkerRun(ctx) catch |err| {
        std.log.warn("cold-cache worker {d} fatal: {s}", .{ ctx.id, @errorName(err) });
    };
}

fn cacheWorkerRun(ctx: *CacheCtx) !void {
    const fd = tcpConnect(ctx.host, ctx.port) catch {
        ctx.errors.connect_failed += 1;
        return;
    };
    defer posix.close(fd);

    const req_buf = std.heap.page_allocator.alloc(u8, 64) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(req_buf);
    const resp_buf = std.heap.page_allocator.alloc(u8, 1 << 14) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(resp_buf);

    var prng = std.Random.DefaultPrng.init(@as(u64, ctx.id) * 0x9E37_79B9_7F4A_7C15);
    const rand = prng.random();
    const span: u64 = ctx.link_id_max - ctx.link_id_min + 1;

    while (ctx.ops_completed < ctx.ops_per_worker) {
        const link_id = ctx.link_id_min + rand.uintLessThan(u64, span);
        var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.get_link));
        fb.writeU64(link_id);
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

        const dt: u64 = @intCast(t1 - t0);
        ctx.overall.recordValue(dt);
        const idx = ctx.global_op_counter.fetchAdd(1, .monotonic);
        if (idx < 1000) {
            ctx.window_a.recordValue(dt);
        } else if (idx < 5000) {
            ctx.window_b.recordValue(dt);
        } else {
            ctx.window_c.recordValue(dt);
        }
        ctx.ops_completed += 1;
    }
}

// ─────────────────────────────────────────────────────────────────
// Sub-mode: cold boot
// ─────────────────────────────────────────────────────────────────

fn runBoot(
    allocator: std.mem.Allocator,
    common_opts: common.CommonOpts,
    opts: ColdOpts,
    server_cmd: []const u8,
) !void {
    // Caller controls iteration count via --ops-per-worker (default 10000
    // is too large for boot loops; users typically pass 1..10).
    const iterations = common_opts.ops_per_worker;
    if (iterations == 0) return error.NoOps;

    // Reseed if requested + missing. Boot doesn't strictly need seed.json,
    // but keeping the same precondition simplifies operator workflow and
    // ensures the data dir is non-empty (so boot has actual work to do).
    try ensureSeed(allocator, opts, server_cmd, common_opts);

    var hist = common.Histogram{};
    var per_iter = try allocator.alloc(u64, iterations);
    defer allocator.free(per_iter);

    const t_start_all = std.time.nanoTimestamp();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        var child = try spawnServer(allocator, server_cmd, opts.data_dir);
        // 60 s upper bound on cold-boot.
        try waitForPing(common_opts.connect_host, common_opts.port, 60_000);
        const t1 = std.time.nanoTimestamp();
        const dt_ns: u64 = @intCast(t1 - t0);
        per_iter[i] = dt_ns;
        hist.recordValue(dt_ns);
        killChild(&child);

        // Brief pause so the OS releases the listening port before the
        // next spawn — otherwise occasional EADDRINUSE flakes show up.
        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    const t_end_all = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(t_end_all - t_start_all);
    const duration_ms: u64 = duration_ns / std.time.ns_per_ms;

    // Per-iteration durations to stderr.
    std.debug.print("cold-boot iterations (ms): ", .{});
    for (per_iter, 0..) |ns, idx| {
        if (idx > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{ns / std.time.ns_per_ms});
    }
    std.debug.print("\n", .{});

    const ops_per_sec: u64 = if (duration_ms > 0) iterations * 1000 / duration_ms else 0;
    const host = std.posix.getenv("HOSTNAME") orelse "unknown";
    const git_rev: []const u8 = common_opts.git_rev orelse "unknown";

    const record = common.BenchRecord{
        .ts = std.time.milliTimestamp(),
        .host = host,
        .git_rev = git_rev,
        .profile = common_opts.profile,
        .workload = "cold",
        .params = .{ .cold = .{
            .kind = "boot",
            .iterations = @intCast(iterations),
            .server_cmd = server_cmd,
        } },
        .duration_ms = duration_ms,
        .ops_total = iterations,
        .ops_per_sec = ops_per_sec,
        .latency_ns = .{
            .p50 = hist.percentile(50.0),
            .p95 = hist.percentile(95.0),
            .p99 = hist.percentile(99.0),
            .p99_9 = hist.percentile(99.9),
            .max = hist.max_recorded,
            .mean = hist.mean(),
            .samples = hist.total_count,
        },
        .rss_bytes = .{ .peak = 0, .final = 0, .note = "rss_unavailable" },
        .errors = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    };

    try emitRecord(allocator, common_opts.output_path, record);
}

// ─────────────────────────────────────────────────────────────────
// Reseed: spawn server, run a small inline seed, kill it. Only fires
// when --reseed is set AND seed.json is missing. We use a small fixture
// (N=200/M=2000) — cold-cache is about read latency, not seed throughput.
// ─────────────────────────────────────────────────────────────────

fn ensureSeed(
    allocator: std.mem.Allocator,
    opts: ColdOpts,
    server_cmd: []const u8,
    common_opts: common.CommonOpts,
) !void {
    const seed_path = try std.fmt.allocPrint(allocator, "{s}/seed.json", .{opts.data_dir});
    defer allocator.free(seed_path);

    if (fileExists(seed_path)) return;

    if (!opts.reseed) {
        std.debug.print(
            "cold: seed.json missing at {s}. Run `bench seed --data-dir {s} ...` first, or pass --reseed.\n",
            .{ seed_path, opts.data_dir },
        );
        return error.SeedRequired;
    }

    std.debug.print("cold: --reseed: running inline seed (200 cats × 2000 links)\n", .{});

    var child = try spawnServer(allocator, server_cmd, opts.data_dir);
    defer killChild(&child);
    try waitForPing(common_opts.connect_host, common_opts.port, 10_000);

    // Build a 1-level tree of 200 categories and 2000 round-robin links.
    const fd = try tcpConnect(common_opts.connect_host, common_opts.port);
    defer posix.close(fd);

    const req_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(req_buf);
    const resp_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(resp_buf);

    const top_id: u64 = 1;
    const N_CATS: u32 = 200;
    const N_LINKS: u64 = 2000;

    const cat_ids = try allocator.alloc(u64, N_CATS);
    defer allocator.free(cat_ids);

    var ci: u32 = 0;
    while (ci < N_CATS) : (ci += 1) {
        var name_buf: [32]u8 = undefined;
        var slug_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "C{d}", .{ci + 1});
        const slug = try std.fmt.bufPrint(&slug_buf, "c{d}", .{ci + 1});
        cat_ids[ci] = try createCategory(fd, req_buf, resp_buf, top_id, name, slug, "");
    }

    const cat_id_min: u64 = top_id;
    const cat_id_max: u64 = cat_ids[cat_ids.len - 1];

    const BATCH: usize = 100;
    var counter: u64 = 0;
    var link_id_min: u64 = 0;
    var link_id_max: u64 = 0;
    while (counter < N_LINKS) {
        const remaining = N_LINKS - counter;
        const batch = @min(@as(u64, BATCH), remaining);
        var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.create_link));
        var bi: u64 = 0;
        while (bi < batch) : (bi += 1) {
            const idx = counter + bi + 1;
            const cat_id = cat_ids[@intCast((counter + bi) % cat_ids.len)];
            var url_buf: [64]u8 = undefined;
            var title_buf: [32]u8 = undefined;
            const url = try std.fmt.bufPrint(&url_buf, "https://b{d}.t", .{idx});
            const title = try std.fmt.bufPrint(&title_buf, "L{d}", .{idx});
            fb.writeU64(cat_id);
            fb.writeU16LenPrefixed(url);
            fb.writeU16LenPrefixed(title);
            fb.writeU16LenPrefixed("");
        }
        const frame = fb.finalize(@intCast(batch));
        const resp_len = try common.sendAndReceive(fd, frame, resp_buf);
        try checkBatchResponse(resp_buf[0..resp_len], @intCast(batch), &link_id_min, &link_id_max);
        counter += batch;
    }

    // Write a minimal seed.json compatible with loadSeed below.
    const SeedJson = struct {
        schema_version: u32,
        categories: u32,
        links: u64,
        depth: u32,
        category_id_min: u64,
        category_id_max: u64,
        link_id_min: u64,
        link_id_max: u64,
    };
    const payload = SeedJson{
        .schema_version = 1,
        .categories = N_CATS,
        .links = N_LINKS,
        .depth = 1,
        .category_id_min = cat_id_min,
        .category_id_max = cat_id_max,
        .link_id_min = link_id_min,
        .link_id_max = link_id_max,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    var f = try std.fs.cwd().createFile(seed_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(json);
    try f.writeAll("\n");

    std.debug.print("cold: inline seed complete ({d} cats, {d} links)\n", .{ N_CATS, N_LINKS });
}

// ─────────────────────────────────────────────────────────────────
// Server lifecycle
// ─────────────────────────────────────────────────────────────────

fn spawnServer(
    allocator: std.mem.Allocator,
    server_cmd: []const u8,
    data_dir: []const u8,
) !std.process.Child {
    var argv: std.ArrayList([]const u8) = .{};
    defer argv.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, server_cmd, " \t");
    while (it.next()) |tok| try argv.append(allocator, tok);
    if (argv.items.len == 0) return error.EmptyServerCmd;

    // env_map must outlive the child (the child reads it during spawn);
    // we leak the EnvMap deliberately because std.process.Child stores a
    // pointer to it and we can't free it until after wait(). For our
    // short-lived bench process this is fine.
    const env_map = try allocator.create(std.process.EnvMap);
    env_map.* = try std.process.getEnvMap(allocator);
    try env_map.put("DMOZDB_DATA_DIR", data_dir);

    var child = std.process.Child.init(argv.items, allocator);
    child.env_map = env_map;
    child.stderr_behavior = .Inherit; // dmozdb logs flow through bench stderr
    child.stdout_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn killChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
}

fn waitForPing(host: []const u8, port: u16, total_timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(total_timeout_ms));
    var backoff_ms: u64 = 100;
    while (true) {
        if (tryPing(host, port)) {
            return;
        } else |_| {}
        if (std.time.milliTimestamp() >= deadline) return error.PingTimeout;
        std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
        backoff_ms = @min(backoff_ms * 2, 1000);
    }
}

fn tryPing(host: []const u8, port: u16) !void {
    const fd = try tcpConnect(host, port);
    defer posix.close(fd);
    var req: [HEADER_SIZE]u8 = undefined;
    var fb = common.FrameBuilder.init(&req, @intFromEnum(Op.ping));
    const frame = fb.finalize(0);
    var resp_buf: [64]u8 = undefined;
    const n = try common.sendAndReceive(fd, frame, &resp_buf);
    if (n < common.RESPONSE_HEADER_SIZE) return error.ProtocolError;
    if (resp_buf[5] != 0) return error.PingFailed;
}

fn tcpConnect(host: []const u8, port: u16) !i32 {
    const addr = try std.net.Address.parseIp(host, port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

// ─────────────────────────────────────────────────────────────────
// Wire-protocol helpers (mirror of seed.zig versions)
// ─────────────────────────────────────────────────────────────────

fn createCategory(
    stream_fd: i32,
    req_buf: []u8,
    resp_buf: []u8,
    parent_id: u64,
    name: []const u8,
    slug: []const u8,
    desc: []const u8,
) !u64 {
    var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.create_category));
    fb.writeU64(parent_id);
    fb.writeU16LenPrefixed(name);
    fb.writeU16LenPrefixed(slug);
    fb.writeU16LenPrefixed(desc);
    const frame = fb.finalize(1);
    const resp_len = try common.sendAndReceive(stream_fd, frame, resp_buf);
    // Response: 10-byte header + per-item [u8 status][u8 sub_status][u64 id] = 10 bytes.
    if (resp_len < common.RESPONSE_HEADER_SIZE + 10) return error.ProtocolError;
    if (resp_buf[5] != 0) return error.CreateCategoryFailed;
    const item_status = resp_buf[common.RESPONSE_HEADER_SIZE];
    if (item_status != 0) return error.CreateCategoryFailed;
    // ID at offset RESPONSE_HEADER_SIZE + 2 (skipping item status + sub_status).
    return std.mem.readInt(u64, resp_buf[common.RESPONSE_HEADER_SIZE + 2 ..][0..8], .little);
}

fn checkBatchResponse(resp: []const u8, expected_count: u16, id_min: *u64, id_max: *u64) !void {
    if (resp.len < common.RESPONSE_HEADER_SIZE) return error.ProtocolError;
    if (resp[5] != 0) return error.ProtocolError;
    const count = std.mem.readInt(u16, resp[8..10], .little);
    if (count != expected_count) return error.ProtocolError;
    var off: usize = common.RESPONSE_HEADER_SIZE;
    const ITEM_BYTES: usize = 10; // [u8 status][u8 sub_status][u64 id]
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        if (off + ITEM_BYTES > resp.len) return error.ProtocolError;
        const status = resp[off];
        if (status != 0) return error.BatchItemFailed;
        const id = std.mem.readInt(u64, resp[off + 2 ..][0..8], .little);
        if (id_min.* == 0 or id < id_min.*) id_min.* = id;
        if (id > id_max.*) id_max.* = id;
        off += ITEM_BYTES;
    }
}

// ─────────────────────────────────────────────────────────────────
// Argument parsing + utility
// ─────────────────────────────────────────────────────────────────

fn parseColdOpts(leftovers: []const []const u8) !ColdOpts {
    var opts = ColdOpts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const v = leftovers[i];
            if (std.mem.eql(u8, v, "cache")) {
                opts.kind = .cache;
            } else if (std.mem.eql(u8, v, "boot")) {
                opts.kind = .boot;
            } else {
                std.debug.print("cold: --kind must be 'cache' or 'boot' (got {s})\n", .{v});
                return error.InvalidKind;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else if (std.mem.eql(u8, arg, "--server-cmd")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.server_cmd = leftovers[i];
        } else if (std.mem.eql(u8, arg, "--reseed")) {
            opts.reseed = true;
        } else {
            std.debug.print("cold: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

const SeedInfo = struct {
    link_id_min: u64,
    link_id_max: u64,
};

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
