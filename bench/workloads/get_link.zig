//! The `get_link` workload measures random point reads (op 3) over the link id range the seed
//! sidecar recorded, one connection per worker.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const Options = struct {
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Context = struct {
    link_ids: common.IdRange,

    pub const request_buffer_size: usize = 64;
    pub const response_buffer_size: usize = 1 << 14;

    pub fn next_frame(self: *Context, worker: *common.Worker) !common.Frame {
        comptime assert(request_buffer_size >= common.request_header_size + @sizeOf(u64));

        var frame_builder = common.FrameBuilder.init(worker.request_buffer, .get_link);
        frame_builder.write_u64(self.link_ids.pick(worker.random));
        const frame = frame_builder.finalize(1);
        assert(frame.len == common.request_header_size + @sizeOf(u64));
        return .{ .bytes = frame };
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_options(leftovers.items);
    if (options.data_dir.len == 0) return error.InvalidDataDir;

    const seed_path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(seed_path);

    const seed = try common.load_seed(env.io, allocator, seed_path);
    defer seed.deinit();

    var context = Context{ .link_ids = seed.value.link_ids() };
    var bench = common.Run.init(env, common_options);
    try bench.run_workers(Context, &context);

    try bench.emit("get_link", .{ .get_link = .{
        .workers = common_options.workers,
        .ops_per_worker = common_options.ops_per_worker,
        .seed_path = seed_path,
    } }, bench.ops_completed_total());
}

fn parse_options(leftovers: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.data_dir = leftovers[i];
        } else {
            std.debug.print("get_link: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}
