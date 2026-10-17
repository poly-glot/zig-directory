const std = @import("std");
const common = @import("../common.zig");

const Opts = struct {
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Ctx = struct {
    link_ids: common.IdRange,

    pub const REQ_BUF_SIZE: usize = 64;
    pub const RESP_BUF_SIZE: usize = 1 << 14;

    pub fn nextFrame(self: *Ctx, w: *common.Worker) !common.Frame {
        var fb = common.FrameBuilder.init(w.req_buf, .get_link);
        fb.writeU64(self.link_ids.pick(w.rand));
        return .{ .bytes = fb.finalize(1) };
    }
};

pub fn run(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var leftovers: std.ArrayList([]const u8) = .{};
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    const seed_path = try common.seedPath(allocator, opts.data_dir);
    defer allocator.free(seed_path);
    const seed = try common.loadSeed(allocator, seed_path);
    defer seed.deinit();

    var ctx = Ctx{ .link_ids = seed.value.linkIds() };
    var bench = common.Run.init(allocator, common_opts);
    try bench.runWorkers(Ctx, &ctx);

    try bench.emit("get_link", .{ .get_link = .{
        .workers = common_opts.workers,
        .ops_per_worker = common_opts.ops_per_worker,
        .seed_path = seed_path,
    } }, bench.opsCompleted());
}

fn parseOpts(leftovers: []const []const u8) !Opts {
    var opts = Opts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else {
            std.debug.print("get_link: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}
