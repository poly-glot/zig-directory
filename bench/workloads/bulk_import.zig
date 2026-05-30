const std = @import("std");
const posix = std.posix;
const common = @import("../common.zig");

// `bench bulk_import` — exercises op=24 bulk_import.
//
// Each frame packs `--batch-size` items in a single bulk_import frame and
// the worker iterates until `--count` items have been imported. The frame
// builder reuses the per-link layout from the existing op=1 create_link
// path: `[u64 cat_id][u16 url_len][url][u16 title_len][title][u16 desc_len][desc]`.
//
// Bounds:
//   * batch-size is capped client-side at 4000 — a 4000-item batch with
//     short URLs comfortably fits in the server-side BULK_IMPORT_MAX_BYTES
//     cap (60 KB) and in the request_buf (64 KB). Larger batches trip the
//     server's reject path, which is interesting behaviour but not what a
//     throughput bench is measuring.
//   * count is capped at 10_000_000 — past that the wall-clock duration
//     dominates everything else; users wanting more should run multiple
//     bench invocations.

const HEADER_SIZE = common.HEADER_SIZE;

const OP_BULK_IMPORT: u8 = 24;
const SERVER_BULK_IMPORT_MAX_BYTES: usize = 60 * 1024;
const SERVER_BULK_IMPORT_MAX_ITEMS: u32 = 50_000;

const MAX_BATCH_SIZE: u32 = 4000;
const MAX_COUNT: u64 = 10_000_000;

const Opts = struct {
    count: u64 = 10_000,
    batch_size: u32 = 1000,
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    if (common_opts.workers == 0) return error.InvalidWorkers;
    if (opts.batch_size == 0) return error.InvalidBatchSize;
    if (opts.batch_size > MAX_BATCH_SIZE) {
        std.debug.print(
            "bulk_import: --batch-size {d} exceeds client-side cap {d} (server cap is {d} items / {d} bytes)\n",
            .{ opts.batch_size, MAX_BATCH_SIZE, SERVER_BULK_IMPORT_MAX_ITEMS, SERVER_BULK_IMPORT_MAX_BYTES },
        );
        return error.BatchSizeTooLarge;
    }
    if (opts.count > MAX_COUNT) {
        std.debug.print("bulk_import: --count {d} exceeds cap {d}\n", .{ opts.count, MAX_COUNT });
        return error.CountTooLarge;
    }

    // ── Spawn worker threads ─────────────────────────────────────
    const ctxs = try allocator.alloc(WorkerCtx, common_opts.workers);
    defer allocator.free(ctxs);
    const threads = try allocator.alloc(std.Thread, common_opts.workers);
    defer allocator.free(threads);

    // Split count across workers, rounding up so the total is at least `count`.
    const per_worker = (opts.count + common_opts.workers - 1) / common_opts.workers;

    const t_start = std.time.nanoTimestamp();

    for (ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .id = @intCast(i),
            .host = common_opts.connect_host,
            .port = common_opts.port,
            .total_items = per_worker,
            .batch_size = opts.batch_size,
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
    var items_total: u64 = 0;
    for (ctxs) |*ctx| {
        merged.merge(&ctx.histogram);
        errors.connect_failed += ctx.errors.connect_failed;
        errors.timeout += ctx.errors.timeout;
        errors.protocol_error += ctx.errors.protocol_error;
        ops_total += ctx.frames_completed;
        items_total += ctx.items_inserted;
    }

    // For bulk_import, throughput is item-rate — that's the user-visible
    // metric. Frames-per-sec is bookkept separately as histogram samples.
    const ops_per_sec: u64 = if (duration_ms > 0) items_total * 1000 / duration_ms else 0;

    const host = std.posix.getenv("HOSTNAME") orelse "unknown";
    const git_rev: []const u8 = common_opts.git_rev orelse "unknown";

    const record = common.BenchRecord{
        .ts = std.time.milliTimestamp(),
        .host = host,
        .git_rev = git_rev,
        .profile = common_opts.profile,
        .workload = "bulk_import",
        .params = .{ .create_link = .{
            .workers = common_opts.workers,
            .batch_size = opts.batch_size,
            .ops_per_worker = per_worker,
        } },
        .duration_ms = duration_ms,
        .ops_total = items_total,
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
    total_items: u64,
    batch_size: u32,
    histogram: common.Histogram = .{},
    errors: common.ErrorCounts = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    frames_completed: u64 = 0,
    items_inserted: u64 = 0,
};

fn workerMain(ctx: *WorkerCtx) void {
    workerRun(ctx) catch |err| {
        std.log.warn("bulk_import worker {d} fatal: {s}", .{ ctx.id, @errorName(err) });
    };
}

fn workerRun(ctx: *WorkerCtx) !void {
    const fd = tcpConnect(ctx.host, ctx.port) catch {
        ctx.errors.connect_failed += 1;
        return;
    };
    defer posix.close(fd);

    // 64 KB request buffer matches the server's per-connection cap; anything
    // larger would be rejected by the server-side BULK_IMPORT_MAX_BYTES check.
    const req_buf_storage = std.heap.page_allocator.alloc(u8, 1 << 16) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(req_buf_storage);
    const resp_buf_storage = std.heap.page_allocator.alloc(u8, 1 << 16) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(resp_buf_storage);

    // Each worker's URLs are namespaced by id to avoid duplicate-URL collisions
    // when multiple workers run concurrently.
    var counter: u64 = @as(u64, ctx.id) * 100_000_000;
    var items_remaining: u64 = ctx.total_items;

    while (items_remaining > 0) {
        const this_batch: u32 = @intCast(@min(@as(u64, ctx.batch_size), items_remaining));

        var fb = common.FrameBuilder.init(req_buf_storage, OP_BULK_IMPORT);
        var bi: u32 = 0;
        while (bi < this_batch) : (bi += 1) {
            counter += 1;
            var url_buf: [64]u8 = undefined;
            var title_buf: [32]u8 = undefined;
            const url = std.fmt.bufPrint(&url_buf, "https://bi{d}.t", .{counter}) catch unreachable;
            const title = std.fmt.bufPrint(&title_buf, "L{d}", .{counter}) catch unreachable;
            fb.writeU64(1); // category_id = top
            fb.writeU16LenPrefixed(url);
            fb.writeU16LenPrefixed(title);
            fb.writeU16LenPrefixed("");
        }
        const frame = fb.finalize(@intCast(this_batch));

        const t0 = std.time.nanoTimestamp();
        const resp_len = common.sendAndReceive(fd, frame, resp_buf_storage) catch {
            ctx.errors.protocol_error += 1;
            return;
        };
        const t1 = std.time.nanoTimestamp();

        if (resp_len < common.RESPONSE_HEADER_SIZE + 48 or resp_buf_storage[5] != 0) {
            ctx.errors.protocol_error += 1;
            return;
        }

        // Pull `inserted` (first u64 of payload) so we measure real DB writes.
        const inserted = std.mem.readInt(
            u64,
            resp_buf_storage[common.RESPONSE_HEADER_SIZE..][0..8],
            .little,
        );
        ctx.items_inserted += inserted;

        ctx.histogram.recordValue(@intCast(t1 - t0));
        ctx.frames_completed += 1;
        items_remaining -|= this_batch;
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
        if (std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.count = try std.fmt.parseInt(u64, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.batch_size = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else {
            std.debug.print("bulk_import: unknown flag: {s}\n", .{arg});
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
