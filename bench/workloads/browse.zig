//! The `browse` workload drives the hierarchy ops: `path` resolves a sampled slug path (op 11),
//! `children` lists one page under a random category (op 12) and `subtree-links` pages the
//! links under a random subtree (op 17). The paths and id range come from the seed sidecar.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const Kind = enum { path, children, subtree_links };

const children_page_size: u32 = 20;
const subtree_links_page_size: u32 = 100;

const Options = struct {
    kind: ?Kind = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Context = struct {
    kind: Kind,
    category_ids: common.IdRange,
    sample_paths: []const []const u8,

    pub const request_buffer_size: usize = 1 << 14;
    pub const response_buffer_size: usize = 1 << 20;

    pub fn next_frame(self: *Context, worker: *common.Worker) !common.Frame {
        switch (self.kind) {
            .path => {
                assert(self.sample_paths.len > 0);
                const index = worker.random.uintLessThan(usize, self.sample_paths.len);
                const path = self.sample_paths[index];
                assert(path.len > 0);
                var frame_builder = common.FrameBuilder.init(worker.request_buffer, .browse_path);
                frame_builder.write_u16_len_prefixed(path);
                return .{ .bytes = frame_builder.finalize(1) };
            },
            .children => {
                var frame_builder = common.FrameBuilder.init(worker.request_buffer, .list_children);
                frame_builder.write_u64(self.category_ids.pick(worker.random));
                frame_builder.write_u32(0);
                frame_builder.write_u32(children_page_size);
                return .{ .bytes = frame_builder.finalize(1) };
            },
            .subtree_links => {
                var frame_builder = common.FrameBuilder.init(
                    worker.request_buffer,
                    .list_subtree_links,
                );
                frame_builder.write_u64(self.category_ids.pick(worker.random));
                frame_builder.write_u8(0);
                frame_builder.write_u32(0);
                frame_builder.write_u32(subtree_links_page_size);
                return .{ .bytes = frame_builder.finalize(1) };
            },
        }
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_options(leftovers.items);

    const kind = options.kind orelse {
        std.debug.print("browse: --kind {{path|children|subtree-links}} is required\n", .{});
        return error.MissingKind;
    };
    if (options.data_dir.len == 0) return error.InvalidDataDir;

    const seed_path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(seed_path);

    const seed = try common.load_seed(env.io, allocator, seed_path);
    defer seed.deinit();

    if (kind == .path) {
        if (seed.value.sample_paths.len == 0) {
            std.debug.print("browse: seed.json has no sample_paths\n", .{});
            return error.NoSamplePaths;
        }
        for (seed.value.sample_paths) |path| {
            if (path.len == 0) return error.InvalidSeed;
        }
    }

    var context = Context{
        .kind = kind,
        .category_ids = seed.value.category_ids(),
        .sample_paths = seed.value.sample_paths,
    };
    var bench = common.Run.init(env, common_options);
    try bench.run_workers(Context, &context);

    const kind_text: []const u8 = switch (kind) {
        .path => "path",
        .children => "children",
        .subtree_links => "subtree-links",
    };

    try bench.emit("browse", .{ .browse = .{
        .kind = kind_text,
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
        if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const value = leftovers[i];
            if (std.mem.eql(u8, value, "path")) {
                options.kind = .path;
            } else if (std.mem.eql(u8, value, "children")) {
                options.kind = .children;
            } else if (std.mem.eql(u8, value, "subtree-links")) {
                options.kind = .subtree_links;
            } else {
                std.debug.print("browse: invalid --kind: {s}\n", .{value});
                return error.InvalidKind;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.data_dir = leftovers[i];
        } else {
            std.debug.print("browse: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}
