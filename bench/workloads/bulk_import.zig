//! The `bulk_import` workload streams link batches through op 24, the server's bulk path, and
//! reports what the server says it inserted rather than what was sent, so the record's
//! ops_total is the number of links that actually landed.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const server_bulk_import_bytes_max: usize = 60 * 1024;
const server_bulk_import_items_max: u32 = 50_000;

const batch_size_max: u32 = 4000;
const count_max: u64 = 10_000_000;

// Each worker numbers its urls in its own block so two workers never create the same url.
const worker_url_namespace: u64 = 100_000_000;

const bulk_import_response_bytes: usize = 48;

const Options = struct {
    count: u64 = 10_000,
    batch_size: u32 = 1000,
};

const Context = struct {
    batch_size: u32,
    items_per_worker: u64,
    items_inserted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub const request_buffer_size: usize = 1 << 16;
    pub const response_buffer_size: usize = 1 << 16;

    pub fn next_frame(self: *Context, worker: *common.Worker) !common.Frame {
        comptime assert(count_max <= worker_url_namespace);
        assert(self.batch_size > 0);
        assert(self.batch_size <= batch_size_max);
        assert(worker.ops_completed < self.items_per_worker);

        const this_batch: u32 = @intCast(@min(
            @as(u64, self.batch_size),
            self.items_per_worker - worker.ops_completed,
        ));
        var frame_builder = common.FrameBuilder.init(worker.request_buffer, .bulk_import);
        var batch_index: u32 = 0;
        while (batch_index < this_batch) : (batch_index += 1) {
            worker.counter += 1;
            assert(worker.counter <= worker_url_namespace);
            try common.write_link_item(
                &frame_builder,
                .{
                    .category_id = 1,
                    .index = @as(u64, worker.id) * worker_url_namespace + worker.counter,
                },
                "https://bi{d}.t",
            );
        }
        return .{ .bytes = frame_builder.finalize(@intCast(this_batch)), .ops = this_batch };
    }

    pub fn on_response(self: *Context, response: []const u8, _: u64) bool {
        assert(response.len >= common.response_header_size);
        if (response.len < common.response_header_size + bulk_import_response_bytes) return false;
        if (response[common.response_status_offset] != common.status_ok) return false;
        const inserted = std.mem.readInt(
            u64,
            response[common.response_header_size..][0..8],
            .little,
        );
        if (inserted > self.batch_size) return false;
        _ = self.items_inserted.fetchAdd(inserted, .monotonic);
        return true;
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_options(leftovers.items);

    if (common_options.workers == 0) return error.InvalidWorkers;
    if (options.batch_size == 0) return error.InvalidBatchSize;
    if (options.batch_size > batch_size_max) {
        std.debug.print(
            "bulk_import: --batch-size {d} exceeds client-side cap {d} " ++
                "(server cap is {d} items / {d} bytes)\n",
            .{
                options.batch_size,
                batch_size_max,
                server_bulk_import_items_max,
                server_bulk_import_bytes_max,
            },
        );
        return error.BatchSizeTooLarge;
    }
    if (options.count > count_max) {
        std.debug.print(
            "bulk_import: --count {d} exceeds cap {d}\n",
            .{ options.count, count_max },
        );
        return error.CountTooLarge;
    }

    const workers: u64 = common_options.workers;
    const per_worker = @divFloor(options.count + workers - 1, workers);
    assert(per_worker * workers >= options.count);
    assert(per_worker <= count_max);

    var run_options = common_options;
    run_options.ops_per_worker = per_worker;
    run_options.warmup_ops = 0;

    var context = Context{ .batch_size = options.batch_size, .items_per_worker = per_worker };
    var bench = common.Run.init(env, run_options);
    try bench.run_workers(Context, &context);

    try bench.emit("bulk_import", .{ .create_link = .{
        .workers = common_options.workers,
        .batch_size = options.batch_size,
        .ops_per_worker = per_worker,
    } }, context.items_inserted.load(.monotonic));
}

fn parse_options(leftovers: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--count")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.count = try std.fmt.parseInt(u64, leftovers[i], 10);
        } else if (std.mem.eql(u8, arg, "--batch-size")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.batch_size = try std.fmt.parseInt(u32, leftovers[i], 10);
        } else {
            std.debug.print("bulk_import: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}
