const std = @import("std");
const common = @import("../common.zig");

const Opts = struct {
    batch: u32 = 10,
};

const Ctx = struct {
    batch: u32,

    pub const REQ_BUF_SIZE: usize = 1 << 20;
    pub const RESP_BUF_SIZE: usize = 1 << 20;

    pub fn nextFrame(self: *Ctx, w: *common.Worker) !common.Frame {
        var fb = common.FrameBuilder.init(w.req_buf, .create_link);
        var bi: u32 = 0;
        while (bi < self.batch) : (bi += 1) {
            w.counter += 1;
            try common.writeLinkItem(&fb, 1, "https://b{d}.t", @as(u64, w.id) * 10_000_000 + w.counter);
        }
        return .{ .bytes = fb.finalize(@intCast(self.batch)), .ops = self.batch };
    }

    pub fn onResponse(_: *Ctx, resp: []const u8, _: u64) bool {
        return resp[5] == 0;
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);
    if (opts.batch == 0) return error.InvalidBatch;

    var ctx = Ctx{ .batch = opts.batch };
    var bench = common.Run.init(allocator, common_opts);
    try bench.runWorkers(Ctx, &ctx);

    try bench.emit("create_link", .{ .create_link = .{
        .workers = common_opts.workers,
        .batch_size = opts.batch,
        .ops_per_worker = common_opts.ops_per_worker,
    } }, bench.opsCompleted());
}

fn parseOpts(leftovers: []const []const u8) !Opts {
    var opts = Opts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--batch")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.batch = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else {
            std.debug.print("create_link: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}
