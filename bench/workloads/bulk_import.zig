const std = @import("std");
const common = @import("../common.zig");

const SERVER_BULK_IMPORT_MAX_BYTES: usize = 60 * 1024;
const SERVER_BULK_IMPORT_MAX_ITEMS: u32 = 50_000;

const MAX_BATCH_SIZE: u32 = 4000;
const MAX_COUNT: u64 = 10_000_000;

const BULK_IMPORT_RESPONSE_BYTES: usize = 48;

const Opts = struct {
    count: u64 = 10_000,
    batch_size: u32 = 1000,
};

const Ctx = struct {
    batch_size: u32,
    items_per_worker: u64,
    items_inserted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub const REQ_BUF_SIZE: usize = 1 << 16;
    pub const RESP_BUF_SIZE: usize = 1 << 16;

    pub fn nextFrame(self: *Ctx, w: *common.Worker) !common.Frame {
        const this_batch: u32 = @intCast(@min(@as(u64, self.batch_size), self.items_per_worker - w.ops_completed));
        var fb = common.FrameBuilder.init(w.req_buf, .bulk_import);
        var bi: u32 = 0;
        while (bi < this_batch) : (bi += 1) {
            w.counter += 1;
            try common.writeLinkItem(&fb, 1, "https://bi{d}.t", @as(u64, w.id) * 100_000_000 + w.counter);
        }
        return .{ .bytes = fb.finalize(@intCast(this_batch)), .ops = this_batch };
    }

    pub fn onResponse(self: *Ctx, resp: []const u8, _: u64) bool {
        if (resp.len < common.RESPONSE_HEADER_SIZE + BULK_IMPORT_RESPONSE_BYTES or resp[5] != 0) return false;
        const inserted = std.mem.readInt(u64, resp[common.RESPONSE_HEADER_SIZE..][0..8], .little);
        _ = self.items_inserted.fetchAdd(inserted, .monotonic);
        return true;
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
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

    const per_worker = (opts.count + common_opts.workers - 1) / common_opts.workers;
    var run_opts = common_opts;
    run_opts.ops_per_worker = per_worker;
    run_opts.warmup_ops = 0;

    var ctx = Ctx{ .batch_size = opts.batch_size, .items_per_worker = per_worker };
    var bench = common.Run.init(env, run_opts);
    try bench.runWorkers(Ctx, &ctx);

    try bench.emit("bulk_import", .{ .create_link = .{
        .workers = common_opts.workers,
        .batch_size = opts.batch_size,
        .ops_per_worker = per_worker,
    } }, ctx.items_inserted.load(.monotonic));
}

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
