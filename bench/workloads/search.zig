const std = @import("std");
const common = @import("../common.zig");

const Target = enum { links, categories };

const Opts = struct {
    target: ?Target = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Ctx = struct {
    corpus: []const []const u8,

    pub const REQ_BUF_SIZE: usize = 1 << 14;
    pub const RESP_BUF_SIZE: usize = 1 << 20;

    pub fn nextFrame(self: *Ctx, w: *common.Worker) !common.Frame {
        const query = self.corpus[w.rand.uintLessThan(usize, self.corpus.len)];
        var fb = common.FrameBuilder.init(w.req_buf, .search);
        fb.writeU16LenPrefixed(query);
        fb.writeU32(50);
        return .{ .bytes = fb.finalize(1) };
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_opts = try common.parseCommonOpts(args, &leftovers, allocator);
    const opts = try parseOpts(leftovers.items);

    const target = opts.target orelse {
        std.debug.print("search: --target {{links|categories}} is required\n", .{});
        return error.MissingTarget;
    };

    const seed_path = try common.seedPath(allocator, opts.data_dir);
    defer allocator.free(seed_path);
    const seed = try common.loadSeed(env.io, allocator, seed_path);
    defer seed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const corpus = try buildCorpus(arena.allocator(), seed.value.sample_query_tokens);
    if (corpus.len == 0) {
        std.debug.print("search: empty query corpus\n", .{});
        return error.EmptyCorpus;
    }

    var ctx = Ctx{ .corpus = corpus };
    var bench = common.Run.init(env, common_opts);
    try bench.runWorkers(Ctx, &ctx);

    const target_str: []const u8 = switch (target) {
        .links => "links",
        .categories => "categories",
    };

    try bench.emit("search", .{ .search = .{
        .target = target_str,
        .workers = common_opts.workers,
        .ops_per_worker = common_opts.ops_per_worker,
        .query_corpus_size = @intCast(corpus.len),
    } }, bench.opsCompleted());
}

fn parseOpts(leftovers: []const []const u8) !Opts {
    var opts = Opts{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const v = leftovers[i];
            if (std.mem.eql(u8, v, "links")) {
                opts.target = .links;
            } else if (std.mem.eql(u8, v, "categories")) {
                opts.target = .categories;
            } else {
                std.debug.print("search: invalid --target: {s}\n", .{v});
                return error.InvalidTarget;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            opts.data_dir = leftovers[i];
        } else {
            std.debug.print("search: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return opts;
}

fn buildCorpus(arena: std.mem.Allocator, tokens: []const []const u8) ![]const []const u8 {
    const max_singletons: usize = @min(tokens.len, 20);
    const max_pairs: usize = if (tokens.len < 2) 0 else 10;

    var list: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < max_singletons) : (i += 1) {
        try list.append(arena, tokens[i]);
    }
    var pairs_added: usize = 0;
    var a: usize = 0;
    outer: while (a < tokens.len) : (a += 1) {
        var b: usize = a + 1;
        while (b < tokens.len) : (b += 1) {
            const joined = try std.fmt.allocPrint(arena, "{s} {s}", .{ tokens[a], tokens[b] });
            try list.append(arena, joined);
            pairs_added += 1;
            if (pairs_added >= max_pairs) break :outer;
        }
    }
    return list.items;
}
