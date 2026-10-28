//! The `seed` workload builds the deterministic fixture every read workload samples from: a
//! category tree of the requested depth, links spread round-robin over its leaves, and the
//! `seed.json` sidecar with the id ranges and up to ten sample paths. A level plan always sums
//! to the requested category count with at least one category per level, so the sidecar
//! describes exactly what the server holds.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const SeedOptions = struct {
    data_dir: []const u8 = "/var/lib/dmozdb",
    categories: u32 = 1000,
    links: u64 = 100_000,
    depth: u32 = 4,
    server_cmd: ?[]const u8 = null,
};

const SeedOutcome = struct {
    categories_created: u32,
    duration_ms: u64,
};

const Fixture = struct {
    categories_created: u32,
    category_ids: common.IdRange,
    link_ids: common.IdRange,
    level_ids: []const []u64,
};

const depth_max: u32 = 16;
const categories_max: u32 = 1_000_000;
const u32_digits_max: usize = 10;
const category_name_bytes_max: usize = 32;
const seed_buffer_bytes: usize = 1 << 20;
const top_category_id: u64 = 1;
const sample_paths_max: usize = 10;
const argv_tokens_max: usize = 64;

const connect_attempts_max: u32 = 256;
const connect_timeout_ms: u64 = 5_000;
const connect_backoff_ms_initial: u64 = 50;
const connect_backoff_ms_max: u64 = 800;

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const seed_options = try parse_seed_options(leftovers.items);
    if (seed_options.depth == 0) return error.InvalidDepth;
    if (seed_options.depth > depth_max) return error.DepthTooLarge;
    if (seed_options.categories == 0) return error.InvalidCategories;
    if (seed_options.categories > categories_max) return error.TooManyCategories;
    if (seed_options.categories < seed_options.depth) return error.TooFewCategories;
    if (seed_options.data_dir.len == 0) return error.InvalidDataDir;

    var argv_storage: std.ArrayList([]const u8) = .empty;
    defer argv_storage.deinit(allocator);

    var maybe_child: ?std.process.Child = null;
    if (seed_options.server_cmd) |server_cmd| {
        maybe_child = try spawn_server(env, server_cmd, seed_options.data_dir, &argv_storage);
    }
    defer if (maybe_child) |*child| child.kill(env.io);

    const rss_sampling = maybe_child != null and common_options.rss_sample_ms > 0;
    var rss = common.RssSampler{
        .io = env.io,
        .pid = if (maybe_child) |child| child.id orelse 0 else 0,
        .interval_ms = if (rss_sampling) common_options.rss_sample_ms else 0,
    };
    if (rss_sampling) try rss.start();
    defer if (rss_sampling) rss.stop();

    const stream_fd = try connect_with_retry(
        env.io,
        common_options.connect_host,
        common_options.port,
    );
    defer common.close_fd(stream_fd);
    try common.ping(stream_fd);

    const outcome = try seed_server(env, stream_fd, &seed_options);

    var bench = common.Run.init(env, common_options);
    bench.duration_ms = outcome.duration_ms;
    if (rss_sampling) {
        bench.rss = .{
            .peak = rss.peak.load(.monotonic),
            .final = rss.final.load(.monotonic),
            .note = null,
        };
    }
    try bench.emit("seed", .{ .seed = .{
        .categories = seed_options.categories,
        .links = seed_options.links,
        .depth = seed_options.depth,
    } }, @as(u64, outcome.categories_created) + seed_options.links);
}

fn parse_seed_options(leftovers: []const []const u8) !SeedOptions {
    var options = SeedOptions{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.data_dir = leftovers[i];
        } else if (std.mem.eql(u8, arg, "--categories")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.categories = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--links")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.links = try std.fmt.parseInt(u64, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.depth = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--server-cmd")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.server_cmd = leftovers[i];
        } else {
            std.debug.print("seed: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}

fn spawn_server(
    env: common.Env,
    server_cmd: []const u8,
    data_dir: []const u8,
    argv_storage: *std.ArrayList([]const u8),
) !std.process.Child {
    assert(data_dir.len > 0);
    assert(argv_storage.items.len == 0);

    try common.ensure_dir(env.io, data_dir);
    try tokenize(server_cmd, argv_storage, env.allocator);
    if (argv_storage.items.len == 0) return error.EmptyServerCmd;

    return std.process.spawn(
        env.io,
        .{ .argv = argv_storage.items, .stderr = .inherit },
    );
}

fn tokenize(text: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |token| {
        if (out.items.len == argv_tokens_max) return error.ServerCmdTooLong;
        try out.append(allocator, token);
    }
}

fn connect_with_retry(io: std.Io, host: []const u8, port: u16) !i32 {
    comptime assert(connect_backoff_ms_max <= connect_timeout_ms);
    assert(host.len > 0);
    assert(port != 0);

    const deadline = common.unix_millis(io) + @as(i64, @intCast(connect_timeout_ms));
    var backoff_ms: u64 = connect_backoff_ms_initial;
    for (0..connect_attempts_max) |_| {
        if (common.tcp_connect(host, port)) |fd| return fd else |_| {}
        if (common.unix_millis(io) >= deadline) return error.ConnectTimeout;
        common.sleep_ms(io, backoff_ms);
        backoff_ms = @min(backoff_ms * 2, connect_backoff_ms_max);
    }
    return error.ConnectTimeout;
}

fn seed_server(env: common.Env, stream_fd: i32, options: *const SeedOptions) !SeedOutcome {
    assert(options.depth > 0);
    assert(options.depth <= depth_max);
    const allocator = env.allocator;

    const level_sizes = try plan_levels(
        allocator,
        .{ .total = options.categories, .depth = options.depth },
    );
    defer allocator.free(level_sizes);

    const request_buffer = try allocator.alloc(u8, seed_buffer_bytes);
    defer allocator.free(request_buffer);

    const response_buffer = try allocator.alloc(u8, seed_buffer_bytes);
    defer allocator.free(response_buffer);

    const level_ids = try allocator.alloc([]u64, options.depth);
    defer {
        for (level_ids) |ids| allocator.free(ids);
        allocator.free(level_ids);
    }
    for (level_ids) |*ids| ids.* = &.{};
    for (level_ids, level_sizes) |*ids, size| ids.* = try allocator.alloc(u64, size);

    const t_start = common.now(env.io);
    const categories_created = try create_category_levels(
        stream_fd,
        request_buffer,
        response_buffer,
        level_ids,
    );
    assert(categories_created == options.categories);

    const leaves = level_ids[options.depth - 1];
    const link_ids = try common.create_links_round_robin(
        stream_fd,
        request_buffer,
        response_buffer,
        leaves,
        options.links,
    );
    const duration_ms = common.elapsed_ms(env.io, t_start);

    const fixture = Fixture{
        .categories_created = categories_created,
        .category_ids = .{ .min = top_category_id, .max = std.mem.max(u64, leaves) },
        .link_ids = link_ids,
        .level_ids = level_ids,
    };
    try write_seed_json(env, options, &fixture);
    return .{ .categories_created = categories_created, .duration_ms = duration_ms };
}

fn create_category_levels(
    stream_fd: i32,
    request_buffer: []u8,
    response_buffer: []u8,
    level_ids: []const []u64,
) !u32 {
    comptime assert(category_name_bytes_max >= 1 + u32_digits_max);
    assert(level_ids.len > 0);
    assert(level_ids.len <= depth_max);

    var planned: usize = 0;
    var counter: u32 = 0;
    for (level_ids, 0..) |ids, level| {
        assert(ids.len > 0);
        planned += ids.len;
        const parents: []const u64 = if (level == 0)
            &[_]u64{top_category_id}
        else
            level_ids[level - 1];
        for (ids, 0..) |*id, index| {
            const parent_id = parents[index % parents.len];
            counter += 1;
            var name_buffer: [category_name_bytes_max]u8 = undefined;
            var slug_buffer: [category_name_bytes_max]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buffer, "C{d}", .{counter});
            const slug = try std.fmt.bufPrint(&slug_buffer, "c{d}", .{counter});
            id.* = try common.create_category(
                stream_fd,
                request_buffer,
                response_buffer,
                parent_id,
                .{ .name = name, .slug = slug, .description = "" },
            );
        }
    }
    assert(counter == planned);
    return counter;
}

fn plan_levels(allocator: std.mem.Allocator, options: struct { total: u32, depth: u32 }) ![]u32 {
    assert(options.depth > 0);
    assert(options.depth <= depth_max);
    assert(options.total >= options.depth);

    const sizes = try allocator.alloc(u32, options.depth);
    errdefer allocator.free(sizes);

    const total_f = @as(f64, @floatFromInt(options.total));
    const depth_f = @as(f64, @floatFromInt(options.depth));
    const fanout = std.math.pow(f64, total_f, 1.0 / depth_f);

    // Every level below this one still needs at least one category, which caps each level so
    // the last one is never left empty.
    var remaining: u32 = options.total;
    for (sizes[0 .. options.depth - 1], 0..) |*size, level| {
        const levels_after: u32 = options.depth - @as(u32, @intCast(level)) - 1;
        const level_f = std.math.pow(f64, fanout, @as(f64, @floatFromInt(level + 1)));
        const wanted: u32 = @intFromFloat(@ceil(level_f));
        size.* = std.math.clamp(wanted, 1, remaining - levels_after);
        remaining -= size.*;
    }
    sizes[options.depth - 1] = remaining;

    var planned: u32 = 0;
    for (sizes) |size| {
        assert(size > 0);
        planned += size;
    }
    assert(planned == options.total);
    return sizes;
}

fn build_sample_paths(arena: std.mem.Allocator, level_ids: []const []u64) ![]const []const u8 {
    assert(level_ids.len > 0);
    assert(level_ids.len <= depth_max);

    const depth = level_ids.len;
    var first_number: [depth_max]u32 = undefined;
    var counter: u32 = 1;
    for (level_ids, 0..) |ids, level| {
        first_number[level] = counter;
        counter += @intCast(ids.len);
    }

    const leaves = level_ids[depth - 1];
    assert(leaves.len > 0);
    const sample_count = @min(sample_paths_max, leaves.len);
    const paths = try arena.alloc([]const u8, sample_count);

    // A category at index i of one level hangs under index i modulo the parent level's size,
    // so a sample path is recovered by walking that relation up from the leaf.
    for (paths, 0..) |*path, sample| {
        var slugs: [depth_max + 1][]const u8 = undefined;
        slugs[0] = "top";
        var position: usize = sample;
        var level: usize = depth;
        while (level > 0) : (level -= 1) {
            assert(position < level_ids[level - 1].len);
            const number = first_number[level - 1] + @as(u32, @intCast(position));
            slugs[level] = try std.fmt.allocPrint(arena, "c{d}", .{number});
            if (level >= 2) position = position % level_ids[level - 2].len;
        }
        path.* = try std.mem.join(arena, "/", slugs[0 .. depth + 1]);
    }
    return paths;
}

fn write_seed_json(env: common.Env, options: *const SeedOptions, fixture: *const Fixture) !void {
    assert(fixture.level_ids.len == options.depth);
    assert(fixture.category_ids.min <= fixture.category_ids.max);
    assert(fixture.link_ids.min <= fixture.link_ids.max);
    const allocator = env.allocator;

    try common.ensure_dir(env.io, options.data_dir);
    const path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(path);

    var paths_arena = std.heap.ArenaAllocator.init(allocator);
    defer paths_arena.deinit();
    const sample_paths = try build_sample_paths(paths_arena.allocator(), fixture.level_ids);

    const SeedJson = struct {
        schema_version: u32,
        categories: u32,
        links: u64,
        depth: u32,
        category_id_min: u64,
        category_id_max: u64,
        link_id_min: u64,
        link_id_max: u64,
        leaf_category_ids: []const u64,
        sample_paths: []const []const u8,
        sample_query_tokens: []const []const u8,
    };
    const tokens = [_][]const u8{ "test", "link", "top", "c1", "c2" };
    const payload = SeedJson{
        .schema_version = 1,
        .categories = fixture.categories_created,
        .links = options.links,
        .depth = options.depth,
        .category_id_min = fixture.category_ids.min,
        .category_id_max = fixture.category_ids.max,
        .link_id_min = fixture.link_ids.min,
        .link_id_max = fixture.link_ids.max,
        .leaf_category_ids = fixture.level_ids[fixture.level_ids.len - 1],
        .sample_paths = sample_paths,
        .sample_query_tokens = &tokens,
    };
    const json = try std.json.Stringify.valueAlloc(
        allocator,
        payload,
        .{ .whitespace = .indent_2 },
    );
    defer allocator.free(json);

    try common.write_file_all(env.io, path, &.{ json, "\n" });
}
