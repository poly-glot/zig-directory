//! The `cold` workload owns the server process it measures: `--kind cache` starts a fresh
//! server and reports point-read latency over three op windows as its caches fill, `--kind boot`
//! restarts it repeatedly and times each boot to the first successful ping. Both need a seeded
//! data directory; `--reseed` builds a small inline fixture when `seed.json` is missing.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const Kind = enum { cache, boot };

const ColdOptions = struct {
    kind: ?Kind = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
    server_cmd: ?[]const u8 = null,
    reseed: bool = false,
};

const inline_seed_categories: u32 = 200;
const inline_seed_links: u64 = 2000;
const inline_seed_buffer_bytes: usize = 1 << 20;
const u32_digits_max: usize = 10;
const category_name_bytes_max: usize = 32;
const top_category_id: u64 = 1;

const boot_iterations_max: u64 = 10_000;
const boot_cooldown_ms: u64 = 200;
const argv_tokens_max: usize = 64;

const ping_attempts_max: u32 = 256;
const ping_backoff_ms_initial: u64 = 100;
const ping_backoff_ms_max: u64 = 1000;
const ping_timeout_seed_ms: u64 = 10_000;
const ping_timeout_boot_ms: u64 = 60_000;

// The cold-cache curve is reported over these op windows; the last one is open-ended.
const CacheWindow = struct { label: []const u8, ops_end: u64 };
const cache_windows = [_]CacheWindow{
    .{ .label = "ops[0..1000]   ", .ops_end = 1000 },
    .{ .label = "ops[1000..5000]", .ops_end = 5000 },
    .{ .label = "ops[5000..end] ", .ops_end = std.math.maxInt(u64) },
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_cold_options(leftovers.items);

    const kind = options.kind orelse {
        std.debug.print("cold: --kind {{cache|boot}} is required\n", .{});
        return error.MissingKind;
    };
    const server_cmd = options.server_cmd orelse {
        std.debug.print("cold: --server-cmd CMD is required\n", .{});
        return error.MissingServerCmd;
    };
    if (options.data_dir.len == 0) return error.InvalidDataDir;

    try common.ensure_dir(env.io, options.data_dir);

    switch (kind) {
        .cache => try run_cache(env, &common_options, &options, server_cmd),
        .boot => try run_boot(env, &common_options, &options, server_cmd),
    }
}

const CacheContext = struct {
    link_ids: common.IdRange,
    op_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    windows: [cache_windows.len]common.AtomicHistogram = @splat(common.AtomicHistogram{}),

    pub const request_buffer_size: usize = 64;
    pub const response_buffer_size: usize = 1 << 14;

    // An odd multiplier is a bijection modulo 2^64, so distinct workers get distinct streams.
    const prng_seed_multiplier: u64 = 0x9E37_79B9_7F4A_7C15;

    pub fn prng_seed(id: u32) u64 {
        comptime assert(prng_seed_multiplier % 2 == 1);
        const seed = @as(u64, id) *% prng_seed_multiplier;
        if (id != 0) assert(seed != 0);
        return seed;
    }

    pub fn next_frame(self: *CacheContext, worker: *common.Worker) !common.Frame {
        comptime assert(request_buffer_size >= common.request_header_size + @sizeOf(u64));

        var frame_builder = common.FrameBuilder.init(worker.request_buffer, .get_link);
        frame_builder.write_u64(self.link_ids.pick(worker.random));
        const frame = frame_builder.finalize(1);
        assert(frame.len == common.request_header_size + @sizeOf(u64));
        return .{ .bytes = frame };
    }

    pub fn on_response(self: *CacheContext, response: []const u8, latency_ns: u64) bool {
        comptime assert(cache_windows[0].ops_end < cache_windows[1].ops_end);
        assert(response.len >= common.response_header_size);

        const op_index = self.op_counter.fetchAdd(1, .monotonic);
        var window: usize = cache_windows.len - 1;
        for (cache_windows, 0..) |candidate, index| {
            if (op_index < candidate.ops_end) {
                window = index;
                break;
            }
        }
        self.windows[window].recordValue(latency_ns);
        return true;
    }
};

fn run_cache(
    env: common.Env,
    common_options: *const common.CommonOptions,
    options: *const ColdOptions,
    server_cmd: []const u8,
) !void {
    const allocator = env.allocator;
    try ensure_seed(env, common_options, options, server_cmd);

    const seed_path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(seed_path);

    const seed = try common.load_seed(env.io, allocator, seed_path);
    defer seed.deinit();

    var child = try spawn_server(env, server_cmd, options.data_dir);
    defer child.kill(env.io);

    try wait_for_ping(
        env.io,
        common_options.connect_host,
        common_options.port,
        ping_timeout_seed_ms,
    );

    const total_ops: u64 = @as(u64, common_options.workers) * common_options.ops_per_worker;
    if (total_ops == 0) return error.NoOps;

    // The curve is the point: the first thousand ops are the cold window, so nothing is warmup.
    var run_options = common_options.*;
    run_options.warmup_ops = 0;

    var context = CacheContext{ .link_ids = seed.value.link_ids() };
    var bench = common.Run.init(env, run_options);
    try bench.run_workers(CacheContext, &context);

    const ops_completed = bench.ops_completed_total();
    assert(ops_completed <= total_ops);
    assert(context.op_counter.load(.monotonic) == ops_completed);
    var window_samples: u64 = 0;
    for (&context.windows) |*window| window_samples += window.samples();
    assert(window_samples == ops_completed);

    std.debug.print("cold-cache curve (n={d}):\n", .{ops_completed});
    for (&context.windows, cache_windows) |*window, descriptor| {
        std.debug.print(
            "  {s} p50={d}us p95={d}us p99={d}us samples={d}\n",
            .{
                descriptor.label,
                @divFloor(window.percentile(50.0), std.time.ns_per_us),
                @divFloor(window.percentile(95.0), std.time.ns_per_us),
                @divFloor(window.percentile(99.0), std.time.ns_per_us),
                window.samples(),
            },
        );
    }

    try bench.emit("cold", .{ .cold = .{
        .kind = "cache",
        .iterations = 1,
        .server_cmd = server_cmd,
    } }, ops_completed);
}

fn run_boot(
    env: common.Env,
    common_options: *const common.CommonOptions,
    options: *const ColdOptions,
    server_cmd: []const u8,
) !void {
    const allocator = env.allocator;
    const iterations = common_options.ops_per_worker;
    if (iterations == 0) return error.NoOps;
    if (iterations > boot_iterations_max) return error.TooManyIterations;

    try ensure_seed(env, common_options, options, server_cmd);

    var bench = common.Run.init(env, common_options.*);

    const per_iteration_ns = try allocator.alloc(u64, iterations);
    defer allocator.free(per_iteration_ns);

    const t_start_all = common.now(env.io);
    for (per_iteration_ns) |*boot_ns| {
        const t0 = common.now(env.io);
        var child = try spawn_server(env, server_cmd, options.data_dir);
        errdefer child.kill(env.io);
        try wait_for_ping(
            env.io,
            common_options.connect_host,
            common_options.port,
            ping_timeout_boot_ms,
        );
        boot_ns.* = common.elapsed_ns(env.io, t0);
        bench.histogram.recordValue(boot_ns.*);
        child.kill(env.io);

        common.sleep_ms(env.io, boot_cooldown_ms);
    }
    bench.duration_ms = common.elapsed_ms(env.io, t_start_all);

    var boot_ns_sum: u64 = 0;
    for (per_iteration_ns) |boot_ns| boot_ns_sum += boot_ns;
    assert(bench.histogram.samples() == iterations);
    assert(bench.histogram.maxValue() == std.mem.max(u64, per_iteration_ns));
    assert(bench.histogram.mean() == @divFloor(boot_ns_sum, iterations));

    std.debug.print("cold-boot iterations (ms): ", .{});
    for (per_iteration_ns, 0..) |boot_ns, index| {
        if (index > 0) std.debug.print(", ", .{});
        std.debug.print("{d}", .{@divFloor(boot_ns, std.time.ns_per_ms)});
    }
    std.debug.print("\n", .{});

    try bench.emit("cold", .{ .cold = .{
        .kind = "boot",
        .iterations = @intCast(iterations),
        .server_cmd = server_cmd,
    } }, iterations);
}

fn ensure_seed(
    env: common.Env,
    common_options: *const common.CommonOptions,
    options: *const ColdOptions,
    server_cmd: []const u8,
) !void {
    comptime assert(inline_seed_links >= inline_seed_categories);
    const allocator = env.allocator;

    const seed_path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(seed_path);

    if (file_exists(env.io, seed_path)) return;
    if (!options.reseed) {
        std.debug.print(
            "cold: seed.json missing at {s}. " ++
                "Run `bench seed --data-dir {s} ...` first, or pass --reseed.\n",
            .{ seed_path, options.data_dir },
        );
        return error.SeedRequired;
    }

    std.debug.print(
        "cold: --reseed: running inline seed ({d} categories x {d} links)\n",
        .{ inline_seed_categories, inline_seed_links },
    );

    var child = try spawn_server(env, server_cmd, options.data_dir);
    defer child.kill(env.io);
    try wait_for_ping(
        env.io,
        common_options.connect_host,
        common_options.port,
        ping_timeout_seed_ms,
    );

    const fd = try common.tcp_connect(common_options.connect_host, common_options.port);
    defer common.close_fd(fd);

    const request_buffer = try allocator.alloc(u8, inline_seed_buffer_bytes);
    defer allocator.free(request_buffer);

    const response_buffer = try allocator.alloc(u8, inline_seed_buffer_bytes);
    defer allocator.free(response_buffer);

    const category_ids = try allocator.alloc(u64, inline_seed_categories);
    defer allocator.free(category_ids);

    try create_inline_categories(fd, request_buffer, response_buffer, category_ids);
    const link_ids = try common.create_links_round_robin(
        fd,
        request_buffer,
        response_buffer,
        category_ids,
        inline_seed_links,
    );
    const category_id_max = std.mem.max(u64, category_ids);
    assert(category_id_max > top_category_id);

    try write_inline_seed_json(env, seed_path, category_id_max, link_ids);
    std.debug.print(
        "cold: inline seed complete ({d} categories, {d} links)\n",
        .{ inline_seed_categories, inline_seed_links },
    );
}

fn create_inline_categories(
    fd: i32,
    request_buffer: []u8,
    response_buffer: []u8,
    category_ids: []u64,
) !void {
    comptime assert(category_name_bytes_max >= 1 + u32_digits_max);
    assert(category_ids.len == inline_seed_categories);

    for (category_ids, 1..) |*category_id, number| {
        var name_buffer: [category_name_bytes_max]u8 = undefined;
        var slug_buffer: [category_name_bytes_max]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "C{d}", .{number});
        const slug = try std.fmt.bufPrint(&slug_buffer, "c{d}", .{number});
        category_id.* = try common.create_category(
            fd,
            request_buffer,
            response_buffer,
            top_category_id,
            .{ .name = name, .slug = slug, .description = "" },
        );
    }
    for (category_ids) |category_id| assert(category_id != 0);
}

fn write_inline_seed_json(
    env: common.Env,
    seed_path: []const u8,
    category_id_max: u64,
    link_ids: common.IdRange,
) !void {
    comptime assert(inline_seed_links > 0);
    assert(category_id_max > top_category_id);
    assert(link_ids.min != 0);
    assert(link_ids.min <= link_ids.max);
    const allocator = env.allocator;

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
        .categories = inline_seed_categories,
        .links = inline_seed_links,
        .depth = 1,
        .category_id_min = top_category_id,
        .category_id_max = category_id_max,
        .link_id_min = link_ids.min,
        .link_id_max = link_ids.max,
    };
    const json = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(json);

    try common.write_file_all(env.io, seed_path, &.{ json, "\n" });
}

fn spawn_server(
    env: common.Env,
    server_cmd: []const u8,
    data_dir: []const u8,
) !std.process.Child {
    assert(data_dir.len > 0);
    const allocator = env.allocator;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    var tokens = std.mem.tokenizeAny(u8, server_cmd, " \t");
    while (tokens.next()) |token| {
        if (argv.items.len == argv_tokens_max) return error.ServerCmdTooLong;
        try argv.append(allocator, token);
    }
    if (argv.items.len == 0) return error.EmptyServerCmd;

    var environ = try env.environ.clone(allocator);
    defer environ.deinit();
    try environ.put("DMOZDB_DATA_DIR", data_dir);

    return std.process.spawn(env.io, .{
        .argv = argv.items,
        .environ_map = &environ,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn wait_for_ping(io: std.Io, host: []const u8, port: u16, total_timeout_ms: u64) !void {
    comptime assert(ping_backoff_ms_max <= ping_timeout_seed_ms);
    assert(host.len > 0);
    assert(port != 0);
    assert(total_timeout_ms >= ping_backoff_ms_max);

    const deadline = common.unix_millis(io) + @as(i64, @intCast(total_timeout_ms));
    var backoff_ms: u64 = ping_backoff_ms_initial;
    for (0..ping_attempts_max) |_| {
        if (try_ping(host, port)) {
            return;
        } else |_| {}
        if (common.unix_millis(io) >= deadline) return error.PingTimeout;
        common.sleep_ms(io, backoff_ms);
        backoff_ms = @min(backoff_ms * 2, ping_backoff_ms_max);
    }
    return error.PingTimeout;
}

fn try_ping(host: []const u8, port: u16) !void {
    assert(port != 0);
    const fd = try common.tcp_connect(host, port);
    defer common.close_fd(fd);
    try common.ping(fd);
}

fn parse_cold_options(leftovers: []const []const u8) !ColdOptions {
    var options = ColdOptions{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const value = leftovers[i];
            if (std.mem.eql(u8, value, "cache")) {
                options.kind = .cache;
            } else if (std.mem.eql(u8, value, "boot")) {
                options.kind = .boot;
            } else {
                std.debug.print("cold: --kind must be 'cache' or 'boot' (got {s})\n", .{value});
                return error.InvalidKind;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.data_dir = leftovers[i];
        } else if (std.mem.eql(u8, arg, "--server-cmd")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.server_cmd = leftovers[i];
        } else if (std.mem.eql(u8, arg, "--reseed")) {
            options.reseed = true;
        } else {
            std.debug.print("cold: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}

fn file_exists(io: std.Io, path: []const u8) bool {
    assert(path.len > 0);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}
