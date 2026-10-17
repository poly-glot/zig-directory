const std = @import("std");
const common = @import("../common.zig");

const Opts = struct {
    read_pct: ?u32 = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Ctx = struct {
    read_pct: u32,
    link_ids: common.IdRange,

    pub const REQ_BUF_SIZE: usize = 1 << 14;
    pub const RESP_BUF_SIZE: usize = 1 << 14;

    pub fn nextFrame(self: *Ctx, w: *common.Worker) !common.Frame {
        const die = w.rand.intRangeAtMost(u32, 1, 100);
        if (die <= self.read_pct) {
            var fb = common.FrameBuilder.init(w.req_buf, .get_link);
            fb.writeU64(self.link_ids.pick(w.rand));
            return .{ .bytes = fb.finalize(1) };
        }
        w.counter += 1;
        var fb = common.FrameBuilder.init(w.req_buf, .create_link);
        try common.writeLinkItem(&fb, 1, "https://b{d}.t", @as(u64, w.id) * 10_000_000 + w.counter);
        return .{ .bytes = fb.finalize(1) };
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    const read_pct = opts.read_pct orelse {
        std.debug.print("mixed: --read-pct PCT (0..100) is required\n", .{});
        return error.MissingReadPct;
    };
    if (read_pct > 100) return error.InvalidReadPct;

    const seed_path = try common.seedPath(allocator, opts.data_dir);
    defer allocator.free(seed_path);
    const seed = try common.loadSeed(allocator, seed_path);
    defer seed.deinit();

    var ctx = Ctx{ .read_pct = read_pct, .link_ids = seed.value.linkIds() };
    var bench = common.Run.init(allocator, common_opts);
    try bench.runWorkers(Ctx, &ctx);

    try bench.emit("mixed", .{ .mixed = .{
        .workers = common_opts.workers,
        .read_pct = read_pct,
        .ops_per_worker = common_opts.ops_per_worker,
    } }, bench.opsCompleted());
}

fn parseOpts(leftovers: []const []const u8) !Opts {
    var opts = Opts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--read-pct")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.read_pct = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else {
            std.debug.print("mixed: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}
