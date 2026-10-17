const std = @import("std");
const common = @import("../common.zig");

const SeedOpts = struct {
    data_dir: []const u8 = "/var/lib/dmozdb",
    categories: u32 = 1000,
    links: u64 = 100_000,
    depth: u32 = 4,
    server_cmd: ?[]const u8 = null,
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const seed_opts = try parseSeedOpts(leftovers.items);

    if (seed_opts.depth == 0) return error.InvalidDepth;
    if (seed_opts.categories == 0) return error.InvalidCategories;

    var maybe_child: ?std.process.Child = null;
    var argv_storage: std.ArrayList([]const u8) = .empty;
    defer argv_storage.deinit(allocator);

    if (seed_opts.server_cmd) |cmd| {
        try common.ensureDir(env.io, seed_opts.data_dir);
        try tokenize(cmd, &argv_storage, allocator);
        if (argv_storage.items.len == 0) return error.EmptyServerCmd;

        maybe_child = try std.process.spawn(env.io, .{ .argv = argv_storage.items, .stderr = .inherit });
    }
    defer if (maybe_child) |*c| c.kill(env.io);

    var rss = common.RssSampler{
        .io = env.io,
        .pid = if (maybe_child) |c| c.id orelse 0 else 0,
        .interval_ms = if (maybe_child != null) common_opts.rss_sample_ms else 0,
    };
    if (maybe_child != null and common_opts.rss_sample_ms > 0) {
        try rss.start();
    }
    defer if (maybe_child != null and common_opts.rss_sample_ms > 0) rss.stop();

    const stream_fd = try connectWithRetry(env.io, common_opts.connect_host, common_opts.port, 5_000);
    defer common.closeFd(stream_fd);
    try common.ping(stream_fd);

    const level_sizes = try planLevels(allocator, seed_opts.categories, seed_opts.depth);
    defer allocator.free(level_sizes);

    const t_start = common.now(env.io);

    const resp_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(resp_buf);
    const req_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(req_buf);

    const top_id: u64 = 1;

    var level_ids = try allocator.alloc([]u64, seed_opts.depth);
    defer {
        for (level_ids) |ids| allocator.free(ids);
        allocator.free(level_ids);
    }
    for (level_ids) |*ids| ids.* = &.{};

    var cat_counter: u32 = 0;
    var L: u32 = 0;
    while (L < seed_opts.depth) : (L += 1) {
        const want = level_sizes[L];
        const ids = try allocator.alloc(u64, want);
        level_ids[L] = ids;
        const parents: []const u64 = if (L == 0) &[_]u64{top_id} else level_ids[L - 1];

        var i: u32 = 0;
        while (i < want) : (i += 1) {
            const parent_id = parents[i % parents.len];
            cat_counter += 1;
            var name_buf: [32]u8 = undefined;
            var slug_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "C{d}", .{cat_counter});
            const slug = try std.fmt.bufPrint(&slug_buf, "c{d}", .{cat_counter});
            ids[i] = try common.createCategory(stream_fd, req_buf, resp_buf, parent_id, name, slug, "");
        }
    }

    const total_cats = cat_counter;
    const cat_id_min: u64 = top_id;
    const cat_id_max: u64 = level_ids[seed_opts.depth - 1][level_ids[seed_opts.depth - 1].len - 1];

    const leaves = level_ids[seed_opts.depth - 1];
    const link_ids = try common.createLinksRoundRobin(stream_fd, req_buf, resp_buf, leaves, seed_opts.links);

    var bench = common.Run.init(env, common_opts);
    bench.duration_ms = common.elapsedMs(env.io, t_start);

    var paths_arena = std.heap.ArenaAllocator.init(allocator);
    defer paths_arena.deinit();
    const sample_paths = try buildSamplePaths(paths_arena.allocator(), level_ids, seed_opts.depth);

    try writeSeedJson(env, seed_opts, total_cats, cat_id_min, cat_id_max, link_ids, leaves, sample_paths);

    if (maybe_child != null and common_opts.rss_sample_ms > 0) {
        bench.rss = .{ .peak = rss.peak.load(.monotonic), .final = rss.final.load(.monotonic), .note = null };
    }

    try bench.emit("seed", .{ .seed = .{
        .categories = seed_opts.categories,
        .links = seed_opts.links,
        .depth = seed_opts.depth,
    } }, @as(u64, total_cats) + seed_opts.links);
}

fn parseSeedOpts(leftovers: []const []const u8) !SeedOpts {
    var opts = SeedOpts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else if (std.mem.eql(u8, arg, "--categories")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.categories = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--links")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.links = try std.fmt.parseInt(u64, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.depth = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--server-cmd")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.server_cmd = leftovers[i];
        } else {
            std.debug.print("seed: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn tokenize(s: []const u8, out: *std.ArrayList([]const u8), allocator: std.mem.Allocator) !void {
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| try out.append(allocator, tok);
}

fn connectWithRetry(io: std.Io, host: []const u8, port: u16, total_timeout_ms: u64) !i32 {
    const deadline = common.unixMillis(io) + @as(i64, @intCast(total_timeout_ms));
    var backoff_ms: u64 = 50;
    while (true) {
        if (common.tcpConnect(host, port)) |fd| return fd else |_| {}
        if (common.unixMillis(io) >= deadline) return error.ConnectTimeout;
        common.sleepMs(io, backoff_ms);
        backoff_ms = @min(backoff_ms * 2, 800);
    }
}

fn planLevels(allocator: std.mem.Allocator, total: u32, depth: u32) ![]u32 {
    const sizes = try allocator.alloc(u32, depth);
    errdefer allocator.free(sizes);

    const total_f = @as(f64, @floatFromInt(total));
    const depth_f = @as(f64, @floatFromInt(depth));
    const fanout = std.math.pow(f64, total_f, 1.0 / depth_f);

    var running: u32 = 0;
    var i: u32 = 0;
    while (i < depth - 1) : (i += 1) {
        const level_f = std.math.pow(f64, fanout, @as(f64, @floatFromInt(i + 1)));
        var n: u32 = @intFromFloat(@ceil(level_f));
        if (n == 0) n = 1;
        sizes[i] = n;
        running += n;
    }
    if (running >= total) {
        sizes[depth - 1] = 1;
        if (depth >= 2) {
            sizes[depth - 2] -|= (running + 1 - total);
            if (sizes[depth - 2] == 0) sizes[depth - 2] = 1;
        }
    } else {
        sizes[depth - 1] = total - running;
    }
    return sizes;
}

fn buildSamplePaths(
    arena: std.mem.Allocator,
    level_ids: []const []u64,
    depth: u32,
) ![]const []const u8 {
    const leaves = level_ids[depth - 1];
    const sample_n = @min(@as(usize, 10), leaves.len);
    const paths = try arena.alloc([]const u8, sample_n);

    var i: usize = 0;
    while (i < sample_n) : (i += 1) {
        var slugs: std.ArrayList([]const u8) = .empty;
        defer slugs.deinit(arena);
        try slugs.append(arena, "top");

        const idx_at_level: usize = i;
        var L: u32 = 0;
        while (L < depth) : (L += 1) {
            const this_level = level_ids[L];
            if (L == depth - 1) {
                const cat_id = this_level[idx_at_level];
                var buf: [32]u8 = undefined;
                const slug = try std.fmt.bufPrint(&buf, "c{d}", .{slugIndexFor(level_ids, L, cat_id)});
                const owned = try arena.dupe(u8, slug);
                try slugs.append(arena, owned);
            } else {
                const anc_idx = i % this_level.len;
                const cat_id = this_level[anc_idx];
                var buf: [32]u8 = undefined;
                const slug = try std.fmt.bufPrint(&buf, "c{d}", .{slugIndexFor(level_ids, L, cat_id)});
                const owned = try arena.dupe(u8, slug);
                try slugs.append(arena, owned);
            }
        }

        const joined = try std.mem.join(arena, "/", slugs.items);
        paths[i] = joined;
    }
    return paths;
}

fn slugIndexFor(level_ids: []const []u64, level: u32, cat_id: u64) u32 {
    var prior: u32 = 0;
    var i: u32 = 0;
    while (i < level) : (i += 1) prior += @intCast(level_ids[i].len);
    for (level_ids[level], 0..) |id, pos| {
        if (id == cat_id) return prior + @as(u32, @intCast(pos)) + 1;
    }
    return 0;
}

fn writeSeedJson(
    env: common.Env,
    opts: SeedOpts,
    user_categories: u32,
    cat_id_min: u64,
    cat_id_max: u64,
    link_ids: common.IdRange,
    leaves: []const u64,
    sample_paths: []const []const u8,
) !void {
    const allocator = env.allocator;
    try common.ensureDir(env.io, opts.data_dir);
    const path = try common.seedPath(allocator, opts.data_dir);
    defer allocator.free(path);

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
        .categories = user_categories,
        .links = opts.links,
        .depth = opts.depth,
        .category_id_min = cat_id_min,
        .category_id_max = cat_id_max,
        .link_id_min = link_ids.min,
        .link_id_max = link_ids.max,
        .leaf_category_ids = leaves,
        .sample_paths = sample_paths,
        .sample_query_tokens = &tokens,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    try common.writeFileAll(env.io, path, &.{ json, "\n" });
}
