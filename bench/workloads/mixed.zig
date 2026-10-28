//! The `mixed` workload interleaves point reads and single-link creates on each worker's
//! connection; `--read-pct` is the share of reads, and 80 / 50 / 20 are the conventional
//! profiles. Each worker numbers its urls in its own block so creates never collide.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const read_pct_max: u32 = 100;
const worker_url_namespace: u64 = 10_000_000;

const Options = struct {
    read_pct: ?u32 = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Context = struct {
    read_pct: u32,
    link_ids: common.IdRange,

    pub const request_buffer_size: usize = 1 << 14;
    pub const response_buffer_size: usize = 1 << 14;

    pub fn next_frame(self: *Context, worker: *common.Worker) !common.Frame {
        assert(self.read_pct <= read_pct_max);

        const die = worker.random.intRangeAtMost(u32, 1, read_pct_max);
        assert(die >= 1);
        assert(die <= read_pct_max);
        if (die <= self.read_pct) {
            var frame_builder = common.FrameBuilder.init(worker.request_buffer, .get_link);
            frame_builder.write_u64(self.link_ids.pick(worker.random));
            return .{ .bytes = frame_builder.finalize(1) };
        }
        worker.counter += 1;
        assert(worker.counter <= worker_url_namespace);
        var frame_builder = common.FrameBuilder.init(worker.request_buffer, .create_link);
        try common.write_link_item(
            &frame_builder,
            .{
                .category_id = 1,
                .index = @as(u64, worker.id) * worker_url_namespace + worker.counter,
            },
            "https://b{d}.t",
        );
        return .{ .bytes = frame_builder.finalize(1) };
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_options(leftovers.items);

    const read_pct = options.read_pct orelse {
        std.debug.print("mixed: --read-pct PCT (0..100) is required\n", .{});
        return error.MissingReadPct;
    };
    if (read_pct > read_pct_max) return error.InvalidReadPct;
    if (options.data_dir.len == 0) return error.InvalidDataDir;
    if (common_options.ops_per_worker > worker_url_namespace) return error.TooManyLinksPerWorker;

    const seed_path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(seed_path);

    const seed = try common.load_seed(env.io, allocator, seed_path);
    defer seed.deinit();

    var context = Context{ .read_pct = read_pct, .link_ids = seed.value.link_ids() };
    var bench = common.Run.init(env, common_options);
    try bench.run_workers(Context, &context);

    try bench.emit("mixed", .{ .mixed = .{
        .workers = common_options.workers,
        .read_pct = read_pct,
        .ops_per_worker = common_options.ops_per_worker,
    } }, bench.ops_completed_total());
}

fn parse_options(leftovers: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--read-pct")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.read_pct = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.data_dir = leftovers[i];
        } else {
            std.debug.print("mixed: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}
