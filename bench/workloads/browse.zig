const std = @import("std");
const common = @import("../common.zig");

const Kind = enum { path, children, subtree_links };

const Opts = struct {
    kind: ?Kind = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Ctx = struct {
    kind: Kind,
    category_ids: common.IdRange,
    sample_paths: []const []const u8,

    pub const REQ_BUF_SIZE: usize = 1 << 14;
    pub const RESP_BUF_SIZE: usize = 1 << 20;

    pub fn nextFrame(self: *Ctx, w: *common.Worker) !common.Frame {
        switch (self.kind) {
            .path => {
                const path = self.sample_paths[w.rand.uintLessThan(usize, self.sample_paths.len)];
                var fb = common.FrameBuilder.init(w.req_buf, .browse_path);
                fb.writeU16LenPrefixed(path);
                return .{ .bytes = fb.finalize(1) };
            },
            .children => {
                var fb = common.FrameBuilder.init(w.req_buf, .list_children);
                fb.writeU64(self.category_ids.pick(w.rand));
                fb.writeU32(0);
                fb.writeU32(20);
                return .{ .bytes = fb.finalize(1) };
            },
            .subtree_links => {
                var fb = common.FrameBuilder.init(w.req_buf, .list_subtree_links);
                fb.writeU64(self.category_ids.pick(w.rand));
                fb.writeU8(0);
                fb.writeU32(0);
                fb.writeU32(100);
                return .{ .bytes = fb.finalize(1) };
            },
        }
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    const kind = opts.kind orelse {
        std.debug.print("browse: --kind {{path|children|subtree-links}} is required\n", .{});
        return error.MissingKind;
    };

    const seed_path = try common.seedPath(allocator, opts.data_dir);
    defer allocator.free(seed_path);
    const seed = try common.loadSeed(env.io, allocator, seed_path);
    defer seed.deinit();

    if (kind == .path and seed.value.sample_paths.len == 0) {
        std.debug.print("browse: seed.json has no sample_paths\n", .{});
        return error.NoSamplePaths;
    }

    var ctx = Ctx{
        .kind = kind,
        .category_ids = seed.value.categoryIds(),
        .sample_paths = seed.value.sample_paths,
    };
    var bench = common.Run.init(env, common_opts);
    try bench.runWorkers(Ctx, &ctx);

    const kind_str: []const u8 = switch (kind) {
        .path => "path",
        .children => "children",
        .subtree_links => "subtree-links",
    };

    try bench.emit("browse", .{ .browse = .{
        .kind = kind_str,
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
        if (std.mem.eql(u8, arg, "--kind")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const v = leftovers[i];
            if (std.mem.eql(u8, v, "path")) {
                opts.kind = .path;
            } else if (std.mem.eql(u8, v, "children")) {
                opts.kind = .children;
            } else if (std.mem.eql(u8, v, "subtree-links")) {
                opts.kind = .subtree_links;
            } else {
                std.debug.print("browse: invalid --kind: {s}\n", .{v});
                return error.InvalidKind;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else {
            std.debug.print("browse: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}
