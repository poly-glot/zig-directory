const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const inverted = @import("zigstore").inverted_index;
const category = @import("operations_category.zig");
const link_mod = @import("operations_link.zig");
const shared = @import("operations_shared.zig");
const ranking = @import("../ranking.zig");
const vector_index = @import("../vector_index.zig");

const log = shared.log;

pub const MAX_POSTINGS_PER_TOKEN: usize = 20_000;
const MAX_QUERY_TOKENS: usize = 32;
pub const HYBRID_CANDIDATES: usize = 200;

const ScoredId = ranking.ScoredId;

pub fn searchCategories(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buf: []schema.Category,
) ![]schema.Category {
    return searchViaIndexTree(
        schema.Category,
        db,
        db.categories_index_tree(),
        query,
        limit,
        buf,
        category.getCategory,
    );
}

pub fn searchLinks(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buf: []schema.Link,
) ![]schema.Link {
    return searchViaIndexTree(
        schema.Link,
        db,
        db.links_index_tree(),
        query,
        limit,
        buf,
        link_mod.getLink,
    );
}

pub fn searchCategoriesRanked(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buf: []schema.Category,
) ![]schema.Category {
    return searchRanked(
        schema.Category,
        db,
        db.categories_index_tree(),
        db.next_category_id.load(.monotonic),
        MAX_POSTINGS_PER_TOKEN,
        query,
        limit,
        buf,
        category.getCategory,
    );
}

pub fn searchLinksRanked(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buf: []schema.Link,
) ![]schema.Link {
    return searchRanked(
        schema.Link,
        db,
        db.links_index_tree(),
        linkCorpusSize(db),
        MAX_POSTINGS_PER_TOKEN,
        query,
        limit,
        buf,
        link_mod.getLink,
    );
}

fn linkCorpusSize(db: *Directory) u64 {
    return db.links_pending_count.load(.monotonic) +
        db.links_approved_count.load(.monotonic) +
        db.links_rejected_count.load(.monotonic);
}

fn searchTreeByToken(
    tree: *@import("zigstore").BPlusTree,
    token: []const u8,
    allocator: std.mem.Allocator,
) ![]u64 {
    return postingsForToken(tree, token, allocator, std.math.maxInt(usize));
}

fn postingsForToken(
    tree: *@import("zigstore").BPlusTree,
    token: []const u8,
    allocator: std.mem.Allocator,
    postings_cap: usize,
) ![]u64 {
    const KEY_BUF_LEN: usize = inverted.MAX_TOKEN_LEN + 8;
    if (token.len + 8 > KEY_BUF_LEN) return &[_]u64{};

    var key_lo_buf: [KEY_BUF_LEN]u8 = undefined;
    var key_hi_buf: [KEY_BUF_LEN]u8 = undefined;
    @memcpy(key_lo_buf[0..token.len], token);
    @memset(key_lo_buf[token.len..][0..8], 0);
    @memcpy(key_hi_buf[0..token.len], token);
    @memset(key_hi_buf[token.len..][0..8], 0xFF);

    var iter = try tree.rangeScan(
        key_lo_buf[0 .. token.len + 8],
        key_hi_buf[0 .. token.len + 8],
    );
    defer iter.deinit();

    var ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ids.deinit(allocator);

    while (try iter.next()) |kv| {
        if (kv.key.len != token.len + 8) continue;
        if (!std.mem.eql(u8, kv.key[0..token.len], token)) break;
        if (ids.items.len == postings_cap) return error.PostingsCapExceeded;
        const id = codec.decodeU64(kv.key[token.len..][0..8]);
        try ids.append(allocator, id);
    }

    return try ids.toOwnedSlice(allocator);
}

const QueryTokens = struct {
    bufs: [MAX_QUERY_TOKENS][inverted.MAX_TOKEN_LEN]u8 = undefined,
    lens: [MAX_QUERY_TOKENS]usize = undefined,
    count: usize = 0,

    fn init(query: []const u8) QueryTokens {
        var self: QueryTokens = .{};
        var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
        var iter = inverted.TokenIterator.init(query);
        while (self.count < MAX_QUERY_TOKENS) {
            const tok = iter.next(&tok_buf) orelse break;
            if (self.contains(tok)) continue;
            @memcpy(self.bufs[self.count][0..tok.len], tok);
            self.lens[self.count] = tok.len;
            self.count += 1;
        }
        return self;
    }

    fn get(self: *const QueryTokens, i: usize) []const u8 {
        return self.bufs[i][0..self.lens[i]];
    }

    fn contains(self: *const QueryTokens, tok: []const u8) bool {
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.get(i), tok)) return true;
        }
        return false;
    }
};

fn inverseDocumentFrequency(corpus_size: u64, document_frequency: usize) f64 {
    const df: f64 = @floatFromInt(document_frequency);
    const n: f64 = @floatFromInt(@max(corpus_size, document_frequency));
    return @log(1.0 + (n - df + 0.5) / (df + 0.5));
}

fn searchRanked(
    comptime T: type,
    db: *Directory,
    tree: *@import("zigstore").BPlusTree,
    corpus_size: u64,
    postings_cap: usize,
    query: []const u8,
    limit: u32,
    buf: []T,
    comptime getter: fn (*Directory, u64) anyerror!?T,
) ![]T {
    const ranked = try rankedIds(db.allocator, tree, corpus_size, postings_cap, query);
    defer db.allocator.free(ranked);
    return fetchInRankOrder(T, db, ranked, limit, buf, getter);
}

fn rankedIds(
    allocator: std.mem.Allocator,
    tree: *@import("zigstore").BPlusTree,
    corpus_size: u64,
    postings_cap: usize,
    query: []const u8,
) ![]ScoredId {
    var scores: std.AutoHashMapUnmanaged(u64, f64) = .empty;
    defer scores.deinit(allocator);

    const tokens = QueryTokens.init(query);
    for (0..tokens.count) |i| {
        const ids = postingsForToken(tree, tokens.get(i), allocator, postings_cap) catch |err| switch (err) {
            error.PostingsCapExceeded => continue,
            else => {
                log.err("rankedIds: rangeScan failed for token='{s}': {}", .{ tokens.get(i), err });
                return err;
            },
        };
        defer allocator.free(ids);

        const idf = inverseDocumentFrequency(corpus_size, ids.len);
        for (ids) |id| {
            const entry = try scores.getOrPutValue(allocator, id, 0);
            entry.value_ptr.* += idf;
        }
    }

    const ranked = try allocator.alloc(ScoredId, scores.count());
    var it = scores.iterator();
    var n: usize = 0;
    while (it.next()) |entry| : (n += 1) {
        ranked[n] = .{ .id = entry.key_ptr.*, .score = entry.value_ptr.* };
    }
    std.sort.pdq(ScoredId, ranked, {}, ScoredId.ranksBefore);
    return ranked;
}

fn fetchInRankOrder(
    comptime T: type,
    db: *Directory,
    ranked: []const ScoredId,
    limit: u32,
    buf: []T,
    comptime getter: fn (*Directory, u64) anyerror!?T,
) []T {
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var count: u32 = 0;
    for (ranked) |hit| {
        if (count >= max) break;
        if (getter(db, hit.id) catch null) |item| {
            buf[count] = item;
            count += 1;
        }
    }
    return buf[0..count];
}

pub const HybridLinks = struct {
    links: []schema.Link,
    vector_used: bool,
};

pub fn searchLinksHybrid(
    db: *Directory,
    query: []const u8,
    model: u64,
    query_embedding: *const vector_index.Embedding,
    limit: u32,
    buf: []schema.Link,
) !HybridLinks {
    const keyword = try rankedIds(db.allocator, db.links_index_tree(), linkCorpusSize(db), MAX_POSTINGS_PER_TOKEN, query);
    defer db.allocator.free(keyword);
    const keyword_top = keyword[0..@min(keyword.len, HYBRID_CANDIDATES)];

    const quantized = if (vectorHalfUsable(db, model)) vector_index.quantize(query_embedding) else null;
    const q = quantized orelse return .{
        .links = fetchInRankOrder(schema.Link, db, keyword, limit, buf, link_mod.getLink),
        .vector_used = false,
    };

    var nearest_buf: [HYBRID_CANDIDATES]ScoredId = undefined;
    const nearest = db.vectors.nearest(db.io, &q, &nearest_buf);

    const fused = try ranking.reciprocalRankFusion(db.allocator, &.{ keyword_top, nearest });
    defer db.allocator.free(fused);
    return .{
        .links = fetchInRankOrder(schema.Link, db, fused, limit, buf, link_mod.getLink),
        .vector_used = true,
    };
}

fn vectorHalfUsable(db: *Directory, model: u64) bool {
    return model != 0 and
        db.vectors.ready.load(.acquire) and
        db.vectors.model.load(.acquire) == model;
}

fn searchViaIndexTree(
    comptime T: type,
    db: *Directory,
    tree: *@import("zigstore").BPlusTree,
    query: []const u8,
    limit: u32,
    buf: []T,
    comptime getter: fn (*Directory, u64) anyerror!?T,
) ![]T {
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    if (max == 0) return buf[0..0];

    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var iter = inverted.TokenIterator.init(query);

    var candidates_full: ?[]u64 = null;
    var candidates_len: usize = 0;
    defer if (candidates_full) |c| db.allocator.free(c);

    var had_any_token = false;
    while (iter.next(&tok_buf)) |tok| {
        had_any_token = true;
        const ids = searchTreeByToken(tree, tok, db.allocator) catch |err| {
            log.err("searchViaIndexTree: rangeScan failed for token='{s}': {}", .{ tok, err });
            return err;
        };

        if (candidates_full == null) {
            candidates_full = ids;
            candidates_len = ids.len;
            continue;
        }
        defer db.allocator.free(ids);

        const cur = candidates_full.?[0..candidates_len];
        var write: usize = 0;
        var i: usize = 0;
        var j: usize = 0;
        while (i < cur.len and j < ids.len) {
            if (cur[i] == ids[j]) {
                cur[write] = cur[i];
                write += 1;
                i += 1;
                j += 1;
            } else if (cur[i] < ids[j]) {
                i += 1;
            } else {
                j += 1;
            }
        }
        candidates_len = write;

        if (candidates_len == 0) break;
    }

    if (!had_any_token or candidates_full == null) return buf[0..0];

    var count: u32 = 0;
    for (candidates_full.?[0..candidates_len]) |id| {
        if (count >= max) break;
        if (getter(db, id) catch null) |item| {
            buf[count] = item;
            count += 1;
        }
    }

    return buf[0..count];
}

test "search: B+Tree-backed link search finds tokenised title" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try link_mod.createLink(db, top_id, "https://example.com/c", "Cannabis Stuff", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinks(db, "cannabis", 8, &buf);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(link_id, hits[0].id);
}

test "search: B+Tree-backed category search finds tokenised name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const cat_id = try category.createCategory(db, top_id, "Computers", "computers", "");

    var buf: [8]schema.Category = undefined;
    const hits = try searchCategories(db, "computers", 8, &buf);

    var found = false;
    for (hits) |c| if (c.id == cat_id) {
        found = true;
    };
    try std.testing.expect(found);
}

test "search: multi-token query AND-intersects per-token posting lists" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const l1 = try link_mod.createLink(db, top_id, "https://example.com/1", "Alpha Beta", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/2", "Alpha Only", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinks(db, "alpha beta", 8, &buf);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(l1, hits[0].id);
}

test "search: AND-of-tokens — \"foo bar\" excludes the foo-only doc" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const foo_bar_test = try link_mod.createLink(db, top_id, "https://example.com/a", "foo bar test", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/b", "foo baz test", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinks(db, "foo bar", 8, &buf);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(foo_bar_test, hits[0].id);
}

test "search: shared token \"test\" returns both docs in ascending id order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a = try link_mod.createLink(db, top_id, "https://example.com/a", "foo bar test", "");
    const b = try link_mod.createLink(db, top_id, "https://example.com/b", "foo baz test", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinks(db, "test", 8, &buf);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(hits[0].id < hits[1].id);
    try std.testing.expectEqual(a, hits[0].id);
    try std.testing.expectEqual(b, hits[1].id);
}

test "search: token absent from corpus returns empty result set" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/a", "foo bar test", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/b", "foo baz test", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinks(db, "nonexistent", 8, &buf);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

test "ranked search: a query sharing only some terms still matches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const alpha = try link_mod.createLink(db, top_id, "https://example.com/1", "Alpha Beta", "");

    var buf: [8]schema.Link = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try searchLinks(db, "alpha gamma", 8, &buf)).len);

    const hits = try searchLinksRanked(db, "alpha gamma", 8, &buf);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(alpha, hits[0].id);
}

test "ranked search: more matched terms rank first, then rarer terms" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const common_only = try link_mod.createLink(db, top_id, "https://example.com/1", "garden", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/2", "garden", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/3", "garden", "");
    const rare_only = try link_mod.createLink(db, top_id, "https://example.com/4", "bonsai", "");
    const both = try link_mod.createLink(db, top_id, "https://example.com/5", "garden bonsai", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinksRanked(db, "bonsai garden", 8, &buf);
    try std.testing.expectEqual(@as(usize, 5), hits.len);
    try std.testing.expectEqual(both, hits[0].id);
    try std.testing.expectEqual(rare_only, hits[1].id);
    try std.testing.expectEqual(common_only, hits[2].id);
}

test "ranked search: equal scores break ties on ascending id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const first = try link_mod.createLink(db, top_id, "https://example.com/1", "orchid", "");
    const second = try link_mod.createLink(db, top_id, "https://example.com/2", "orchid", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/3", "orchid", "");

    var buf: [2]schema.Link = undefined;
    const hits = try searchLinksRanked(db, "orchid", 8, &buf);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(first, hits[0].id);
    try std.testing.expectEqual(second, hits[1].id);
}

test "ranked search: repeated query terms count once" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const orchid = try link_mod.createLink(db, top_id, "https://example.com/1", "orchid", "");
    const fern = try link_mod.createLink(db, top_id, "https://example.com/2", "fern", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchLinksRanked(db, "orchid orchid orchid fern", 8, &buf);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(orchid, hits[0].id);
    try std.testing.expectEqual(fern, hits[1].id);
}

test "ranked search: a token past the postings cap contributes nothing" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/1", "www", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/2", "www", "");
    const rare = try link_mod.createLink(db, top_id, "https://example.com/3", "www bonsai", "");

    var buf: [8]schema.Link = undefined;
    const hits = try searchRanked(
        schema.Link,
        db,
        db.links_index_tree(),
        linkCorpusSize(db),
        2,
        "www bonsai",
        8,
        &buf,
        link_mod.getLink,
    );
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(rare, hits[0].id);
}

test "ranked search: categories rank by matched terms" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    _ = try category.createCategory(db, top_id, "Gardening", "gardening", "");
    const both = try category.createCategory(db, top_id, "Gardening Bonsai", "gardening-bonsai", "");

    var buf: [8]schema.Category = undefined;
    const hits = try searchCategoriesRanked(db, "bonsai gardening tools", 8, &buf);
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectEqual(both, hits[0].id);
}
