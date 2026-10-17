const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

const Kind = enum { cache, boot };

const ColdOpts = struct {
    kind: ?Kind = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
    server_cmd: ?[]const u8 = null,
    reseed: bool = false,
};

const INLINE_SEED_CATEGORIES: u32 = 200;
const INLINE_SEED_LINKS: u64 = 2000;

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

    try common.ensureDir(opts.data_dir);

    switch (kind) {
        .cache => try runCache(allocator, common_opts, opts, server_cmd),
        .boot => try runBoot(allocator, common_opts, opts, server_cmd),
    }
}

const CacheCtx = struct {
    link_ids: common.IdRange,
    op_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    window_a: common.AtomicHistogram = .{},
    window_b: common.AtomicHistogram = .{},
    window_c: common.AtomicHistogram = .{},

    pub const REQ_BUF_SIZE: usize = 64;
    pub const RESP_BUF_SIZE: usize = 1 << 14;

    pub fn prngSeed(id: u32) u64 {
        return @as(u64, id) *% 0x9E37_79B9_7F4A_7C15;
    }

    pub fn nextFrame(self: *CacheCtx, w: *common.Worker) !common.Frame {
        var fb = common.FrameBuilder.init(w.req_buf, .get_link);
        fb.writeU64(self.link_ids.pick(w.rand));
        return .{ .bytes = fb.finalize(1) };
    }

    pub fn onResponse(self: *CacheCtx, _: []const u8, latency_ns: u64) bool {
        const idx = self.op_counter.fetchAdd(1, .monotonic);
        if (idx < 1000) {
            self.window_a.recordValue(latency_ns);
        } else if (idx < 5000) {
            self.window_b.recordValue(latency_ns);
        } else {
            self.window_c.recordValue(latency_ns);
        }
        return true;
    }
};

fn runCache(
    allocator: std.mem.Allocator,
    common_opts: common.CommonOpts,
    opts: ColdOpts,
    server_cmd: []const u8,
) !void {
    try ensureSeed(allocator, opts, server_cmd, common_opts);

    const seed_path = try common.seedPath(allocator, opts.data_dir);
    defer allocator.free(seed_path);
    const seed = try common.loadSeed(allocator, seed_path);
    defer seed.deinit();

    var child = try spawnServer(allocator, server_cmd, opts.data_dir);
    defer killChild(&child);

    try waitForPing(common_opts.connect_host, common_opts.port, 10_000);

    const total_ops: u64 = @as(u64, common_opts.workers) * common_opts.ops_per_worker;
    if (total_ops == 0) return error.NoOps;

    var run_opts = common_opts;
    run_opts.warmup_ops = 0;

    var ctx = CacheCtx{ .link_ids = seed.value.linkIds() };
    var bench = common.Run.init(allocator, run_opts);
    try bench.runWorkers(CacheCtx, &ctx);

    std.debug.print(
        "cold-cache curve (n={d}): " ++
            "win[0..1000]      p50={d}us p95={d}us p99={d}us samples={d}\n" ++
            "                  win[1000..5000]   p50={d}us p95={d}us p99={d}us samples={d}\n" ++
            "                  win[5000..end]    p50={d}us p95={d}us p99={d}us samples={d}\n",
        .{
            bench.opsCompleted(),
            ctx.window_a.percentile(50.0) / 1000,
            ctx.window_a.percentile(95.0) / 1000,
            ctx.window_a.percentile(99.0) / 1000,
            ctx.window_a.samples(),
            ctx.window_b.percentile(50.0) / 1000,
            ctx.window_b.percentile(95.0) / 1000,
            ctx.window_b.percentile(99.0) / 1000,
            ctx.window_b.samples(),
            ctx.window_c.percentile(50.0) / 1000,
            ctx.window_c.percentile(95.0) / 1000,
            ctx.window_c.percentile(99.0) / 1000,
            ctx.window_c.samples(),
        },
    );

    try bench.emit("cold", .{ .cold = .{
        .kind = "cache",
        .iterations = 1,
        .server_cmd = server_cmd,
    } }, bench.opsCompleted());
}

fn runBoot(
    allocator: std.mem.Allocator,
    common_opts: common.CommonOpts,
    opts: ColdOpts,
    server_cmd: []const u8,
) !void {
    const iterations = common_opts.ops_per_worker;
    if (iterations == 0) return error.NoOps;

    try ensureSeed(allocator, opts, server_cmd, common_opts);

    var bench = common.Run.init(allocator, common_opts);
    var per_iter = try allocator.alloc(u64, iterations);
    defer allocator.free(per_iter);

    const t_start_all = std.time.nanoTimestamp();
    var i: u64 = 0;
    while (i < iterations) : (i += 1) {
        const t0 = std.time.nanoTimestamp();
        var child = try spawnServer(allocator, server_cmd, opts.data_dir);
        try waitForPing(common_opts.connect_host, common_opts.port, 60_000);
        const dt_ns: u64 = @intCast(std.time.nanoTimestamp() - t0);
        per_iter[i] = dt_ns;
        bench.histogram.recordValue(dt_ns);
        killChild(&child);

        std.Thread.sleep(200 * std.time.ns_per_ms);
    }
    bench.duration_ms = common.elapsedMs(t_start_all);

    std.debug.print("cold-boot iterations (ms): ", .{});
    for (per_iter, 0..) |ns, idx| {
        if (idx > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{ns / std.time.ns_per_ms});
    }
    std.debug.print("\n", .{});

    try bench.emit("cold", .{ .cold = .{
        .kind = "boot",
        .iterations = @intCast(iterations),
        .server_cmd = server_cmd,
    } }, iterations);
}

fn ensureSeed(
    allocator: std.mem.Allocator,
    opts: ColdOpts,
    server_cmd: []const u8,
    common_opts: common.CommonOpts,
) !void {
    const seed_path = try common.seedPath(allocator, opts.data_dir);
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

    const fd = try common.tcpConnect(common_opts.connect_host, common_opts.port);
    defer posix.close(fd);

    const req_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(req_buf);
    const resp_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(resp_buf);

    const top_id: u64 = 1;

    const cat_ids = try allocator.alloc(u64, INLINE_SEED_CATEGORIES);
    defer allocator.free(cat_ids);

    var ci: u32 = 0;
    while (ci < INLINE_SEED_CATEGORIES) : (ci += 1) {
        var name_buf: [32]u8 = undefined;
        var slug_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "C{d}", .{ci + 1});
        const slug = try std.fmt.bufPrint(&slug_buf, "c{d}", .{ci + 1});
        cat_ids[ci] = try common.createCategory(fd, req_buf, resp_buf, top_id, name, slug, "");
    }

    const link_ids = try common.createLinksRoundRobin(fd, req_buf, resp_buf, cat_ids, INLINE_SEED_LINKS);

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
        .categories = INLINE_SEED_CATEGORIES,
        .links = INLINE_SEED_LINKS,
        .depth = 1,
        .category_id_min = top_id,
        .category_id_max = cat_ids[cat_ids.len - 1],
        .link_id_min = link_ids.min,
        .link_id_max = link_ids.max,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    var f = try std.fs.cwd().createFile(seed_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(json);
    try f.writeAll("\n");

    std.debug.print("cold: inline seed complete ({d} cats, {d} links)\n", .{ INLINE_SEED_CATEGORIES, INLINE_SEED_LINKS });
}

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

    const env_map = try allocator.create(std.process.EnvMap);
    env_map.* = try std.process.getEnvMap(allocator);
    try env_map.put("DMOZDB_DATA_DIR", data_dir);

    var child = std.process.Child.init(argv.items, allocator);
    child.env_map = env_map;
    child.stderr_behavior = .Inherit;
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
    const fd = try common.tcpConnect(host, port);
    defer posix.close(fd);
    try common.ping(fd);
}

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

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}
