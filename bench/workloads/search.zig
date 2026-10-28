//! The `search` workload sends token queries (op 14) drawn from a corpus of the seed sidecar's
//! sample tokens: every single token first, then token pairs, capped so the corpus stays small
//! enough that each query repeats and the server's index path is what gets measured.

const std = @import("std");
const assert = std.debug.assert;
const common = @import("../common.zig");

const Target = enum { links, categories };

const search_limit: u32 = 50;
const corpus_singletons_max: usize = 20;
const corpus_pairs_max: usize = 10;

const Options = struct {
    target: ?Target = null,
    data_dir: []const u8 = "/var/lib/dmozdb",
};

const Context = struct {
    corpus: []const []const u8,

    pub const request_buffer_size: usize = 1 << 14;
    pub const response_buffer_size: usize = 1 << 20;

    pub fn next_frame(self: *Context, worker: *common.Worker) !common.Frame {
        assert(self.corpus.len > 0);
        const query = self.corpus[worker.random.uintLessThan(usize, self.corpus.len)];
        assert(query.len > 0);

        var frame_builder = common.FrameBuilder.init(worker.request_buffer, .search);
        frame_builder.write_u16_len_prefixed(query);
        frame_builder.write_u32(search_limit);
        return .{ .bytes = frame_builder.finalize(1) };
    }
};

pub fn run(env: common.Env, args: *std.process.Args.Iterator) !void {
    const allocator = env.allocator;
    var leftovers: std.ArrayList([]const u8) = .empty;
    defer leftovers.deinit(allocator);

    const common_options = try common.parse_common_options(args, &leftovers, allocator);
    const options = try parse_options(leftovers.items);

    const target = options.target orelse {
        std.debug.print("search: --target {{links|categories}} is required\n", .{});
        return error.MissingTarget;
    };
    if (options.data_dir.len == 0) return error.InvalidDataDir;

    const seed_path = try common.seed_path(allocator, options.data_dir);
    defer allocator.free(seed_path);

    const seed = try common.load_seed(env.io, allocator, seed_path);
    defer seed.deinit();

    for (seed.value.sample_query_tokens) |token| {
        if (token.len == 0) return error.InvalidSeed;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const corpus = try build_corpus(arena.allocator(), seed.value.sample_query_tokens);
    if (corpus.len == 0) {
        std.debug.print("search: empty query corpus\n", .{});
        return error.EmptyCorpus;
    }

    var context = Context{ .corpus = corpus };
    var bench = common.Run.init(env, common_options);
    try bench.run_workers(Context, &context);

    const target_text: []const u8 = switch (target) {
        .links => "links",
        .categories => "categories",
    };

    try bench.emit("search", .{ .search = .{
        .target = target_text,
        .workers = common_options.workers,
        .ops_per_worker = common_options.ops_per_worker,
        .query_corpus_size = @intCast(corpus.len),
    } }, bench.ops_completed_total());
}

fn parse_options(leftovers: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < leftovers.len) : (i += 1) {
        const arg = leftovers[i];
        if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            const value = leftovers[i];
            if (std.mem.eql(u8, value, "links")) {
                options.target = .links;
            } else if (std.mem.eql(u8, value, "categories")) {
                options.target = .categories;
            } else {
                std.debug.print("search: invalid --target: {s}\n", .{value});
                return error.InvalidTarget;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            i += 1;
            if (i >= leftovers.len) return error.MissingValue;
            options.data_dir = leftovers[i];
        } else {
            std.debug.print("search: unknown flag: {s}\n", .{arg});
            return error.UnknownFlag;
        }
    }
    return options;
}

fn build_corpus(arena: std.mem.Allocator, tokens: []const []const u8) ![]const []const u8 {
    const singletons = @min(tokens.len, corpus_singletons_max);
    const pairs_max: usize = if (tokens.len < 2) 0 else corpus_pairs_max;

    var list: std.ArrayList([]const u8) = .empty;
    try list.ensureTotalCapacity(arena, singletons + pairs_max);
    for (tokens[0..singletons]) |token| try list.append(arena, token);

    var pairs_added: usize = 0;
    outer: for (tokens, 0..) |first, index| {
        for (tokens[index + 1 ..]) |second| {
            const joined = try std.fmt.allocPrint(arena, "{s} {s}", .{ first, second });
            try list.append(arena, joined);
            pairs_added += 1;
            if (pairs_added >= pairs_max) break :outer;
        }
    }
    assert(pairs_added <= pairs_max);
    assert(list.items.len == singletons + pairs_added);
    assert(list.items.len <= corpus_singletons_max + corpus_pairs_max);
    return list.items;
}
