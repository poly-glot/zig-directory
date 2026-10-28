//! The `create_link` workload hammers op 1 with `--batch` links per frame from every worker.
//! Each worker numbers its urls in its own block, so a run's links are unique as long as a
//! worker's op count stays inside that block.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const batch_max: u32 = 4000;
const worker_url_namespace: u64 = 10_000_000;

const Options = struct {
    batch: u32 = 10,
};

const Context = struct {
    batch: u32,

    pub const request_buffer_size: usize = 1 << 20;
    pub const response_buffer_size: usize = 1 << 20;

    pub fn next_frame(self: *Context, worker: *common.Worker) !common.Frame {
        assert(self.batch > 0);
        assert(self.batch <= batch_max);

        var frame_builder = common.FrameBuilder.init(worker.request_buffer, .create_link);
        var batch_index: u32 = 0;
        while (batch_index < self.batch) : (batch_index += 1) {
            worker.counter += 1;
            assert(worker.counter <= worker_url_namespace);
            try common.write_link_item(
                &frame_builder,
                .{
                    .category_id = 1,
                    .index = @as(u64, worker.id) * worker_url_namespace + worker.counter,
                },
                "https://b{d}.t",
            );
        }
        return .{ .bytes = frame_builder.finalize(@intCast(self.batch)), .ops = self.batch };
    }

    pub fn on_response(_: *Context, response: []const u8, _: u64) bool {
        assert(response.len >= common.response_header_size);
        return response[common.response_status_offset] == common.status_ok;
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_options(leftovers.items);
    if (options.batch == 0) return error.InvalidBatch;
    if (options.batch > batch_max) return error.BatchTooLarge;
    if (common_options.ops_per_worker + options.batch > worker_url_namespace) {
        return error.TooManyLinksPerWorker;
    }

    var context = Context{ .batch = options.batch };
    var bench = common.Run.init(env, common_options);
    try bench.run_workers(Context, &context);

    try bench.emit("create_link", .{ .create_link = .{
        .workers = common_options.workers,
        .batch_size = options.batch,
        .ops_per_worker = common_options.ops_per_worker,
    } }, bench.ops_completed_total());
}

fn parse_options(leftovers: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--batch")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.batch = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else {
            std.debug.print("create_link: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}
