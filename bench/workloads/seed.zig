const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

// `bench seed` — populate a fresh dmozdb instance with a deterministic
// fixture (balanced category tree + round-robin links) so subsequent read
// workloads have stable IDs/slugs to reference. Writes a sidecar
// `seed.json` next to the data dir; emits a single JSONL bench record.

const SeedOpts = struct {
    data_dir: []const u8 = "/var/lib/dmozdb",
    categories: u32 = 1000,
    links: u64 = 100_000,
    depth: u32 = 4,
    server_cmd: ?[]const u8 = null,
};

const HEADER_SIZE = common.HEADER_SIZE;

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const seed_opts = try parseSeedOpts(leftovers.items);

    if (seed_opts.depth == 0) return error.InvalidDepth;
    if (seed_opts.categories == 0) return error.InvalidCategories;

    // ── Optional: spawn the server ────────────────────────────────
    var maybe_child: ?std.process.Child = null;
    var argv_storage: std.ArrayList([]const u8) = .{};
    defer argv_storage.deinit(allocator);

    if (seed_opts.server_cmd) |cmd| {
        try ensureDir(seed_opts.data_dir);
        try tokenize(cmd, &argv_storage, allocator);
        if (argv_storage.items.len == 0) return error.EmptyServerCmd;

        var child = std.process.Child.init(argv_storage.items, allocator);
        child.stderr_behavior = .Inherit; // simpler: dmozdb logs go to our stderr
        try child.spawn();
        maybe_child = child;
    }
    defer if (maybe_child) |*c| {
        _ = c.kill() catch {};
    };

    // ── RSS sampler (only if we own the server) ───────────────────
    var rss = common.RssSampler{
        .pid = if (maybe_child) |c| c.id else 0,
        .interval_ms = if (maybe_child != null) common_opts.rss_sample_ms else 0,
    };
    if (maybe_child != null and common_opts.rss_sample_ms > 0) {
        try rss.start();
    }
    defer if (maybe_child != null and common_opts.rss_sample_ms > 0) rss.stop();

    // ── Connect (with retries while server warms up) ──────────────
    const stream_fd = try connectWithRetry(common_opts.connect_host, common_opts.port, 5_000);
    defer posix.close(stream_fd);
    try ping(stream_fd);

    // ── Plan the tree: per-level fanout ───────────────────────────
    const level_sizes = try planLevels(allocator, seed_opts.categories, seed_opts.depth);
    defer allocator.free(level_sizes);

    const t_start = std.time.nanoTimestamp();

    // ── Buffers for protocol I/O ──────────────────────────────────
    var resp_buf = try allocator.alloc(u8, 1 << 20); // 1 MiB
    defer allocator.free(resp_buf);
    const req_buf = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(req_buf);

    // dmozdb's migration auto-creates synthetic Top at id=1 and
    // Lost+Found at id=2 on first boot. We treat Top as a given
    // and build user categories under it.
    const top_id: u64 = 1;

    // ── BFS-create category levels ────────────────────────────────
    // level_ids[L] holds the IDs at level L (L=0 => first level under Top).
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
            ids[i] = try createCategory(stream_fd, req_buf, resp_buf, parent_id, name, slug, "");
        }
    }

    const total_cats = cat_counter; // user categories (excludes Top)
    const cat_id_min: u64 = top_id; // includes Top in the range
    const cat_id_max: u64 = level_ids[seed_opts.depth - 1][level_ids[seed_opts.depth - 1].len - 1];

    // ── Create links round-robin across leaves ────────────────────
    const leaves = level_ids[seed_opts.depth - 1];
    const BATCH: usize = 100;
    var link_counter: u64 = 0;
    var link_id_min: u64 = 0;
    var link_id_max: u64 = 0;

    while (link_counter < seed_opts.links) {
        const remaining = seed_opts.links - link_counter;
        const batch = @min(@as(u64, BATCH), remaining);
        var fb = common.FrameBuilder.init(req_buf, @intFromEnum(Op.create_link));

        var bi: u64 = 0;
        while (bi < batch) : (bi += 1) {
            const idx: u64 = link_counter + bi + 1;
            const cat_id = leaves[@intCast((link_counter + bi) % leaves.len)];
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
        const resp_len = try common.sendAndReceive(stream_fd, frame, resp_buf);
        try checkBatchResponse(resp_buf[0..resp_len], @intCast(batch), &link_id_min, &link_id_max);

        link_counter += batch;
    }

    const t_end = std.time.nanoTimestamp();
    const duration_ns: u64 = @intCast(t_end - t_start);
    const duration_ms: u64 = duration_ns / std.time.ns_per_ms;

    // ── Build sample paths (first 10 leaves) ──────────────────────
    var paths_arena = std.heap.ArenaAllocator.init(allocator);
    defer paths_arena.deinit();
    const sample_paths = try buildSamplePaths(paths_arena.allocator(), level_ids, seed_opts.depth);

    // ── Write seed.json ───────────────────────────────────────────
    try writeSeedJson(allocator, seed_opts, total_cats, cat_id_min, cat_id_max, link_id_min, link_id_max, leaves, sample_paths);

    // ── Emit bench record ─────────────────────────────────────────
    const ops_total: u64 = @as(u64, total_cats) + seed_opts.links;
    const ops_per_sec: u64 = if (duration_ms > 0) ops_total * 1000 / duration_ms else 0;

    const rss_stats: common.RssStats = if (maybe_child != null and common_opts.rss_sample_ms > 0)
        .{ .peak = rss.peak.load(.monotonic), .final = rss.final.load(.monotonic), .note = null }
    else
        .{ .peak = 0, .final = 0, .note = "rss_unavailable" };

    const host = std.posix.getenv("HOSTNAME") orelse "unknown";
    const git_rev: []const u8 = common_opts.git_rev orelse "unknown";

    const record = common.BenchRecord{
        .ts = std.time.milliTimestamp(),
        .host = host,
        .git_rev = git_rev,
        .profile = common_opts.profile,
        .workload = "seed",
        .params = .{ .seed = .{
            .categories = seed_opts.categories,
            .links = seed_opts.links,
            .depth = seed_opts.depth,
        } },
        .duration_ms = duration_ms,
        .ops_total = ops_total,
        .ops_per_sec = ops_per_sec,
        .latency_ns = .{ .p50 = 0, .p95 = 0, .p99 = 0, .p99_9 = 0, .max = 0, .mean = 0, .samples = 0 },
        .rss_bytes = rss_stats,
        .errors = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    };

    if (common_opts.output_path) |path| {
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

// ─────────────────────────────────────────────────────────────────
// Argument parsing
// ─────────────────────────────────────────────────────────────────

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

fn ensureDir(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

// ─────────────────────────────────────────────────────────────────
// Server lifecycle helpers
// ─────────────────────────────────────────────────────────────────

fn connectWithRetry(host: []const u8, port: u16, total_timeout_ms: u64) !i32 {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(total_timeout_ms));
    var backoff_ms: u64 = 50;
    while (true) {
        if (tcpConnect(host, port)) |fd| return fd else |_| {}
        if (std.time.milliTimestamp() >= deadline) return error.ConnectTimeout;
        std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
        backoff_ms = @min(backoff_ms * 2, 800);
    }
}

fn tcpConnect(host: []const u8, port: u16) !i32 {
    const addr = try std.net.Address.parseIp(host, port);
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);
    try posix.connect(fd, &addr.any, addr.getOsSockLen());
    return fd;
}

fn ping(stream_fd: i32) !void {
    var req: [HEADER_SIZE]u8 = undefined;
    var fb = common.FrameBuilder.init(&req, 255);
    const frame = fb.finalize(0);
    var resp_buf: [64]u8 = undefined;
    const n = try common.sendAndReceive(stream_fd, frame, &resp_buf);
    if (n < common.RESPONSE_HEADER_SIZE) return error.ProtocolError;
    if (resp_buf[5] != 0) return error.PingFailed; // status=ok=0 in response byte 5
}

// ─────────────────────────────────────────────────────────────────
// Tree planning
// ─────────────────────────────────────────────────────────────────

/// Plan per-level sizes for a balanced tree of `total` categories at `depth`.
/// Levels grow geometrically with a fanout ≈ total^(1/depth), ceil-rounded so
/// the sum is at least `total`. The deepest level absorbs any rounding excess
/// so the actual total is exactly `total`.
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
    // Last level absorbs the remainder so the sum is exactly `total`.
    if (running >= total) {
        // Fanout overshot: shrink the last interior level to make room for ≥1 leaf.
        sizes[depth - 1] = 1;
        // Trim back the prior level so the overall sum hits `total`.
        // (This branch is hit only for tiny totals.)
        if (depth >= 2) {
            sizes[depth - 2] -|= (running + 1 - total);
            if (sizes[depth - 2] == 0) sizes[depth - 2] = 1;
        }
    } else {
        sizes[depth - 1] = total - running;
    }
    return sizes;
}

// ─────────────────────────────────────────────────────────────────
// Wire-protocol helpers
// ─────────────────────────────────────────────────────────────────

const Op = enum(u8) {
    create_link = 1,
    create_category = 2,
    ping = 255,
};

const Status = enum(u8) {
    ok = 0,
};

/// Single create_category round-trip; returns the new ID. The protocol
/// supports batching here too, but per-call latency is fine for ≤1000
/// categories and keeping it simple makes the failure path cleaner.
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
    if (resp_buf[5] != @intFromEnum(Status.ok)) {
        std.debug.print("create_category failed: server status={d} sub={d}\n", .{ resp_buf[5], resp_buf[6] });
        return error.CreateCategoryFailed;
    }
    const item_status = resp_buf[common.RESPONSE_HEADER_SIZE];
    if (item_status != @intFromEnum(Status.ok)) {
        const item_sub = resp_buf[common.RESPONSE_HEADER_SIZE + 1];
        std.debug.print("create_category item failed: status={d} sub={d}\n", .{ item_status, item_sub });
        return error.CreateCategoryFailed;
    }
    // ID follows the [u8 status][u8 sub_status] pair.
    return std.mem.readInt(u64, resp_buf[common.RESPONSE_HEADER_SIZE + 2 ..][0..8], .little);
}

/// Walk a batched create response, asserting all items succeeded and
/// updating the running min/max link IDs. Per-item layout is now
/// [u8 status][u8 sub_status][u64 id] = 10 bytes (sub_status was added
/// in the operations-surface uplift).
fn checkBatchResponse(resp: []const u8, expected_count: u16, id_min: *u64, id_max: *u64) !void {
    if (resp.len < common.RESPONSE_HEADER_SIZE) return error.ProtocolError;
    if (resp[5] != @intFromEnum(Status.ok)) return error.ProtocolError;
    const count = std.mem.readInt(u16, resp[8..10], .little);
    if (count != expected_count) return error.ProtocolError;
    var off: usize = common.RESPONSE_HEADER_SIZE;
    const ITEM_BYTES: usize = 10; // [u8 status][u8 sub_status][u64 id]
    var i: u16 = 0;
    while (i < count) : (i += 1) {
        if (off + ITEM_BYTES > resp.len) return error.ProtocolError;
        const status = resp[off];
        if (status != @intFromEnum(Status.ok)) return error.BatchItemFailed;
        const id = std.mem.readInt(u64, resp[off + 2 ..][0..8], .little);
        if (id_min.* == 0 or id < id_min.*) id_min.* = id;
        if (id > id_max.*) id_max.* = id;
        off += ITEM_BYTES;
    }
}

// ─────────────────────────────────────────────────────────────────
// seed.json output
// ─────────────────────────────────────────────────────────────────

fn buildSamplePaths(
    arena: std.mem.Allocator,
    level_ids: []const []u64,
    depth: u32,
) ![]const []const u8 {
    // For the first 10 leaves, build "top/cA/cB/.../cZ" by walking
    // back up the round-robin parent chain we constructed.
    const leaves = level_ids[depth - 1];
    const sample_n = @min(@as(usize, 10), leaves.len);
    const paths = try arena.alloc([]const u8, sample_n);

    var i: usize = 0;
    while (i < sample_n) : (i += 1) {
        var slugs: std.ArrayList([]const u8) = .{};
        defer slugs.deinit(arena);
        try slugs.append(arena, "top");

        // Walk down: at level L, the index in that level for this leaf is
        // (leaf_idx_in_level) % parents_at_level_L. We reconstruct the
        // round-robin chain by tracking the index at each level.
        const idx_at_level: usize = i;
        var L: u32 = 0;
        while (L < depth) : (L += 1) {
            const this_level = level_ids[L];
            // At construction, child i in level L+1 had parent = parents[i % parents.len].
            // For the leaf at index i in the deepest level, its slug at this level is
            // the BFS-allocated category at index (idx_at_level) of `this_level`...
            // but only when L == depth - 1 (the leaf itself). For intermediate
            // levels, idx_at_level shrinks via modulus.
            if (L == depth - 1) {
                // This is the leaf itself.
                const cat_id = this_level[idx_at_level];
                var buf: [32]u8 = undefined;
                const slug = try std.fmt.bufPrint(&buf, "c{d}", .{slugIndexFor(level_ids, L, cat_id)});
                const owned = try arena.dupe(u8, slug);
                try slugs.append(arena, owned);
            } else {
                // Walk up: this leaf's parent at level L is at index
                // (i % this_level.len). But we want the chain from root down,
                // so we recompute: at construction, level L's category j had
                // parent = level L-1's category at index j % parents.len.
                // For our leaf at deepest level index i, its level-L ancestor
                // is reached by reverse-mapping: the leaf was created with
                // parent at level depth-2's index (i % size[depth-2]),
                // which was created with parent at level depth-3's index
                // ((i % size[depth-2]) % size[depth-3]), etc. Simpler:
                // ancestor index at level L = i % this_level.len, since
                // each level wraps independently from i.
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

/// Map a category ID back to its 1-based slug index. We assigned slugs
/// "c1", "c2", ... in BFS order, so the slug index is the count of all
/// categories created at or before this one. Equivalently:
///   sum(level_sizes[0..L]) + position_in_level + 1
fn slugIndexFor(level_ids: []const []u64, level: u32, cat_id: u64) u32 {
    var prior: u32 = 0;
    var i: u32 = 0;
    while (i < level) : (i += 1) prior += @intCast(level_ids[i].len);
    for (level_ids[level], 0..) |id, pos| {
        if (id == cat_id) return prior + @as(u32, @intCast(pos)) + 1;
    }
    return 0; // unreachable in practice
}

fn writeSeedJson(
    allocator: std.mem.Allocator,
    opts: SeedOpts,
    user_categories: u32,
    cat_id_min: u64,
    cat_id_max: u64,
    link_id_min: u64,
    link_id_max: u64,
    leaves: []const u64,
    sample_paths: []const []const u8,
) !void {
    try ensureDir(opts.data_dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/seed.json", .{opts.data_dir});
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
        .link_id_min = link_id_min,
        .link_id_max = link_id_max,
        .leaf_category_ids = leaves,
        .sample_paths = sample_paths,
        .sample_query_tokens = &tokens,
    };

    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(json);
    try f.writeAll("\n");
}
