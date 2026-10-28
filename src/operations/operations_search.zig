//! Keyword and hybrid search over the inverted index trees: the exact AND search the browse
//! pages use, the IDF-ranked OR search, and the hybrid variants that fuse keyword ranks with the
//! vector shortlist through reciprocal rank fusion. Posting lists come out of the trees in
//! ascending id order and every stage keeps them that way, which is what the intersection and
//! the deduplication rely on.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const BPlusTree = @import("zigstore").BPlusTree;
const inverted = @import("zigstore").inverted_index;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const category = @import("operations_category.zig");
const link_operations = @import("operations_link.zig");
const shared = @import("operations_shared.zig");
const ranking = @import("../ranking.zig");
const vector_index = @import("../vector_index.zig");
const vector_model = @import("../vector_model.zig");
const vector_ops = @import("operations_vector.zig");
const sites = @import("../facts/sites.zig");

const log = shared.log;

pub const postings_per_token_max: usize = 20_000;
const query_tokens_max: usize = 32;
pub const hybrid_candidates: usize = 200;
pub const category_candidates: usize = 3;
const category_nearest: usize = 50;

const ScoredId = ranking.ScoredId;

pub fn search_categories(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buffer: []schema.Category,
) ![]schema.Category {
    const hits = try search_via_index_tree(
        schema.Category,
        db,
        db.categories_index_tree(),
        query,
        limit,
        buffer,
        category.get_category,
    );
    assert(hits.len <= limit);
    return hits;
}

pub fn search_links(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buffer: []schema.Link,
) ![]schema.Link {
    const hits = try search_via_index_tree(
        schema.Link,
        db,
        db.links_index_tree(),
        query,
        limit,
        buffer,
        link_operations.get_link,
    );
    assert(hits.len <= limit);
    return hits;
}

pub fn search_categories_ranked(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buffer: []schema.Category,
) ![]schema.Category {
    const ranked = try ranked_ids(
        db.scratch(),
        db.categories_index_tree(),
        db.next_category_id.load(.monotonic),
        postings_per_token_max,
        query,
    );
    defer db.scratch().free(ranked);

    const hits = fetch_in_rank_order(
        schema.Category,
        db,
        ranked,
        limit,
        buffer,
        category.get_category,
    );
    assert(hits.len <= limit);
    assert(hits.len <= ranked.len);
    return hits;
}

pub fn search_links_ranked(
    db: *Directory,
    query: []const u8,
    limit: u32,
    buffer: []schema.Link,
    site_rows: ?[]RowSite,
) ![]schema.Link {
    const ranked = try ranked_ids(
        db.scratch(),
        db.links_index_tree(),
        link_corpus_size(db),
        postings_per_token_max,
        query,
    );
    defer db.scratch().free(ranked);

    const hits = try fetch_links(db, ranked, limit, buffer, site_rows);
    assert(hits.len <= limit);
    assert(hits.len <= ranked.len);
    return hits;
}

fn link_corpus_size(db: *Directory) u64 {
    return db.links_pending_count.load(.monotonic) +
        db.links_approved_count.load(.monotonic) +
        db.links_rejected_count.load(.monotonic);
}

pub fn postings_for_token(
    tree: *BPlusTree,
    token: []const u8,
    allocator: std.mem.Allocator,
    postings_cap: usize,
) ![]u64 {
    assert(token.len >= inverted.MIN_TOKEN_LEN);
    const key_buffer_len: usize = inverted.MAX_TOKEN_LEN + 8;
    if (token.len + 8 > key_buffer_len) return &[_]u64{};

    var key_low_buffer: [key_buffer_len]u8 = undefined;
    var key_high_buffer: [key_buffer_len]u8 = undefined;
    @memcpy(key_low_buffer[0..token.len], token);
    @memset(key_low_buffer[token.len..][0..8], 0);
    @memcpy(key_high_buffer[0..token.len], token);
    @memset(key_high_buffer[token.len..][0..8], 0xFF);

    var iterator = try tree.rangeScan(
        key_low_buffer[0 .. token.len + 8],
        key_high_buffer[0 .. token.len + 8],
    );
    defer iterator.deinit();

    var ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ids.deinit(allocator);

    while (try iterator.next()) |entry| {
        if (entry.key.len != token.len + 8) continue;
        if (!std.mem.eql(u8, entry.key[0..token.len], token)) break;
        if (ids.items.len == postings_cap) return error.PostingsCapExceeded;
        const id = codec.decodeU64(entry.key[token.len..][0..8]);
        if (ids.items.len > 0) assert(id > ids.items[ids.items.len - 1]);
        try ids.append(allocator, id);
    }

    assert(ids.items.len <= postings_cap);
    return try ids.toOwnedSlice(allocator);
}

const QueryTokens = struct {
    buffers: [query_tokens_max][inverted.MAX_TOKEN_LEN]u8 = undefined,
    lengths: [query_tokens_max]u32 = undefined,
    count: u32 = 0,

    fn init(query: []const u8) QueryTokens {
        var self: QueryTokens = .{};
        var token_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
        var iterator = inverted.TokenIterator.init(query);
        while (self.count < query_tokens_max) {
            const token = iterator.next(&token_buffer) orelse break;
            assert(token.len >= inverted.MIN_TOKEN_LEN);
            assert(token.len <= inverted.MAX_TOKEN_LEN);
            if (self.contains(token)) continue;
            @memcpy(self.buffers[self.count][0..token.len], token);
            self.lengths[self.count] = @intCast(token.len);
            self.count += 1;
        }
        assert(self.count <= query_tokens_max);
        return self;
    }

    fn get(self: *const QueryTokens, i: usize) []const u8 {
        assert(i < self.count);
        assert(self.lengths[i] <= inverted.MAX_TOKEN_LEN);
        return self.buffers[i][0..self.lengths[i]];
    }

    fn contains(self: *const QueryTokens, token: []const u8) bool {
        assert(self.count <= query_tokens_max);
        for (0..self.count) |i| {
            if (std.mem.eql(u8, self.get(i), token)) return true;
        }
        return false;
    }
};

const plural_exceptions = std.StaticStringMap(void).initComptime(.{
    .{"news"},
    .{"series"},
    .{"species"},
    .{"lens"},
    .{"chess"},
    .{"athletics"},
    .{"physics"},
    .{"mathematics"},
    .{"economics"},
    .{"politics"},
    .{"ethics"},
    .{"linguistics"},
    .{"genetics"},
    .{"graphics"},
    .{"electronics"},
    .{"aerobics"},
    .{"gymnastics"},
    .{"texas"},
    .{"kansas"},
    .{"paris"},
    .{"wales"},
    .{"jesus"},
    .{"blues"},
    .{"jeans"},
    .{"glasses"},
});

fn is_vowel(c: u8) bool {
    assert(c >= 'a');
    assert(c <= 'z');
    return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u';
}

fn ends_with(token: []const u8, suffix: []const u8) bool {
    assert(suffix.len > 0);
    return std.mem.endsWith(u8, token, suffix);
}

fn takes_es(stem: []const u8) bool {
    assert(stem.len > 0);
    const sibilant = ends_with(stem, "s") or ends_with(stem, "x") or ends_with(stem, "z");
    return sibilant or ends_with(stem, "ch") or ends_with(stem, "sh");
}

// A token's variant is its other grammatical number, so a query in either spelling scores both
// as one term; words that only look plural, and tokens with digits, have no variant.
fn inflection(token: []const u8, buffer: *[inverted.MAX_TOKEN_LEN]u8) ?[]const u8 {
    assert(token.len <= inverted.MAX_TOKEN_LEN);
    if (token.len < 3 or plural_exceptions.has(token)) return null;
    if (ends_with(token, "ss") or ends_with(token, "us") or ends_with(token, "is")) return null;
    for (token) |c| if (c < 'a' or c > 'z') return null;

    const variant = inflection_variant(token, buffer);
    if (variant) |changed| assert(!std.mem.eql(u8, changed, token));
    return variant;
}

fn inflection_variant(token: []const u8, buffer: *[inverted.MAX_TOKEN_LEN]u8) ?[]const u8 {
    assert(token.len >= 3);
    assert(token.len <= inverted.MAX_TOKEN_LEN);
    const plural_ies = token.len >= 5 and ends_with(token, "ies");
    if (plural_ies) return inflected(buffer, token[0 .. token.len - 3], "y");
    const plural_es = token.len >= 5 and ends_with(token, "es") and
        takes_es(token[0 .. token.len - 2]);
    if (plural_es) return inflected(buffer, token[0 .. token.len - 2], "");
    if (ends_with(token, "s")) return inflected(buffer, token[0 .. token.len - 1], "");
    if (ends_with(token, "y") and !is_vowel(token[token.len - 2])) {
        return inflected(buffer, token[0 .. token.len - 1], "ies");
    }
    if (takes_es(token)) return inflected(buffer, token, "es");
    return inflected(buffer, token, "s");
}

fn inflected(
    buffer: *[inverted.MAX_TOKEN_LEN]u8,
    stem: []const u8,
    suffix: []const u8,
) ?[]const u8 {
    assert(stem.len >= inverted.MIN_TOKEN_LEN);
    assert(suffix.len <= 3);
    if (stem.len + suffix.len > buffer.len) return null;
    @memcpy(buffer[0..stem.len], stem);
    @memcpy(buffer[stem.len..][0..suffix.len], suffix);
    return buffer[0 .. stem.len + suffix.len];
}

fn postings_for_term(
    tree: *BPlusTree,
    token: []const u8,
    allocator: std.mem.Allocator,
    postings_cap: usize,
) ![]u64 {
    assert(token.len >= inverted.MIN_TOKEN_LEN);
    var ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer ids.deinit(allocator);

    var variant_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    const forms = [_]?[]const u8{ token, inflection(token, &variant_buffer) };
    for (forms) |form| {
        const some = form orelse continue;
        const found = postings_for_token(
            tree,
            some,
            allocator,
            postings_cap,
        ) catch |err| switch (err) {
            error.PostingsCapExceeded => continue,
            else => {
                log.err("ranked_ids: rangeScan failed for token='{s}': {}", .{ some, err });
                return err;
            },
        };
        defer allocator.free(found);
        try ids.appendSlice(allocator, found);
    }

    std.sort.pdq(u64, ids.items, {}, std.sort.asc(u64));
    var unique: usize = 0;
    for (ids.items) |id| {
        if (unique > 0 and ids.items[unique - 1] == id) continue;
        if (unique > 0) assert(id > ids.items[unique - 1]);
        ids.items[unique] = id;
        unique += 1;
    }
    assert(unique <= ids.items.len);
    ids.items.len = unique;
    return ids.toOwnedSlice(allocator);
}

// BM25's idf with the corpus floored at the document frequency, so a term is never worth less
// than nothing and a stale corpus counter cannot flip a score negative.
fn inverse_document_frequency(corpus_size: u64, document_frequency: usize) f64 {
    const frequency: f64 = @floatFromInt(document_frequency);
    const corpus: f64 = @floatFromInt(@max(corpus_size, document_frequency));
    const idf = @log(1.0 + (corpus - frequency + 0.5) / (frequency + 0.5));
    assert(idf > 0);
    assert(std.math.isFinite(idf));
    return idf;
}

fn ranked_ids(
    allocator: std.mem.Allocator,
    tree: *BPlusTree,
    corpus_size: u64,
    postings_cap: usize,
    query: []const u8,
) ![]ScoredId {
    var scores: std.AutoHashMapUnmanaged(u64, f64) = .empty;
    defer scores.deinit(allocator);

    const tokens = QueryTokens.init(query);
    assert(tokens.count <= query_tokens_max);
    for (0..tokens.count) |i| {
        const ids = try postings_for_term(tree, tokens.get(i), allocator, postings_cap);
        defer allocator.free(ids);

        const idf = inverse_document_frequency(corpus_size, ids.len);
        for (ids) |id| {
            const entry = try scores.getOrPutValue(allocator, id, 0);
            entry.value_ptr.* += idf;
        }
    }

    const ranked = try allocator.alloc(ScoredId, scores.count());
    var iterator = scores.iterator();
    var filled: usize = 0;
    while (iterator.next()) |entry| : (filled += 1) {
        ranked[filled] = .{ .id = entry.key_ptr.*, .score = entry.value_ptr.* };
    }
    assert(filled == ranked.len);
    std.sort.pdq(ScoredId, ranked, {}, ScoredId.ranks_before);
    return ranked;
}

fn fetch_in_rank_order(
    comptime T: type,
    db: *Directory,
    ranked: []const ScoredId,
    limit: u32,
    buffer: []T,
    comptime getter: fn (*Directory, u64) anyerror!?T,
) []T {
    const max = @min(limit, @as(u32, @intCast(buffer.len)));
    var count: u32 = 0;
    for (ranked) |hit| {
        if (count >= max) break;
        if (getter(db, hit.id) catch null) |item| {
            buffer[count] = item;
            count += 1;
        }
    }
    assert(count <= max);
    assert(count <= ranked.len);
    return buffer[0..count];
}

pub const RowSite = struct {
    key_buf: [sites.site_len_max]u8 = undefined,
    key_len: u8 = 0,
    more: u16 = 0,

    pub fn key(self: *const RowSite) []const u8 {
        assert(self.key_len <= self.key_buf.len);
        return self.key_buf[0..self.key_len];
    }
};

const links_per_site_max: u8 = 2;

const SiteTally = struct {
    shown: u8,
    last_row: u32,
};

fn fetch_links(
    db: *Directory,
    ranked: []const ScoredId,
    limit: u32,
    buffer: []schema.Link,
    site_rows: ?[]RowSite,
) ![]schema.Link {
    const rows = site_rows orelse {
        const hits = fetch_in_rank_order(
            schema.Link,
            db,
            ranked,
            limit,
            buffer,
            link_operations.get_link,
        );
        assert(hits.len <= limit);
        return hits;
    };
    const hits = try fetch_capped_per_site(db, ranked, limit, buffer, rows);
    assert(hits.len <= limit);
    return hits;
}

fn fetch_capped_per_site(
    db: *Directory,
    ranked: []const ScoredId,
    limit: u32,
    buffer: []schema.Link,
    rows: []RowSite,
) ![]schema.Link {
    const max = @min(limit, buffer.len, rows.len);
    var tallies: std.StringHashMapUnmanaged(SiteTally) = .empty;
    defer tallies.deinit(db.scratch());
    try tallies.ensureTotalCapacity(db.scratch(), @intCast(max));

    var count: usize = 0;
    for (ranked) |hit| {
        if (count == max) break;
        const link = (link_operations.get_link(db, hit.id) catch null) orelse continue;

        const row = &rows[count];
        row.* = .{};
        const site = sites.site_for(link.url.slice(), &row.key_buf);
        assert(site.key.len <= sites.site_len_max);
        row.key_len = @intCast(site.key.len);

        if (tallies.getPtr(row.key())) |tally| {
            if (tally.shown >= links_per_site_max) {
                assert(tally.last_row < count);
                rows[tally.last_row].more +|= 1;
                continue;
            }
            tally.* = .{ .shown = tally.shown + 1, .last_row = @intCast(count) };
            assert(tally.shown <= links_per_site_max);
        } else {
            tallies.putAssumeCapacityNoClobber(
                row.key(),
                .{ .shown = 1, .last_row = @intCast(count) },
            );
        }

        buffer[count] = link;
        count += 1;
    }
    assert(count <= max);
    return buffer[0..count];
}

pub const HybridLinks = struct {
    links: []schema.Link,
    vector_used: bool,
};

pub fn search_links_hybrid(
    db: *Directory,
    query: []const u8,
    model: u64,
    query_embedding: *const vector_index.Embedding,
    limit: u32,
    buffer: []schema.Link,
    site_rows: ?[]RowSite,
) !HybridLinks {
    const keyword = try ranked_ids(
        db.scratch(),
        db.links_index_tree(),
        link_corpus_size(db),
        postings_per_token_max,
        query,
    );
    defer db.scratch().free(keyword);
    const keyword_top = keyword[0..@min(keyword.len, hybrid_candidates)];

    const quantized = if (vector_half_usable(db, model))
        vector_index.quantize(query_embedding)
    else
        null;
    const query_quantized = quantized orelse return .{
        .links = try fetch_links(db, keyword, limit, buffer, site_rows),
        .vector_used = false,
    };

    var unit = query_embedding.*;
    vector_model.normalize_in_place(&unit);

    var shortlist_buffer: [hybrid_candidates]ScoredId = undefined;
    const shortlist = db.link_vector_index.shortlist(db.io, &unit, &shortlist_buffer);
    assert(shortlist.len <= hybrid_candidates);
    var nearest_buffer: [hybrid_candidates]ScoredId = undefined;
    const nearest = try rerank_exact(db, shortlist, &query_quantized, &nearest_buffer);
    assert(nearest.len <= shortlist.len);

    var subtree_buffer: [hybrid_candidates]ScoredId = undefined;
    const subtree = try subtree_candidates(db, &unit, &query_quantized, &subtree_buffer);
    assert(subtree.len <= hybrid_candidates);

    const fused = try ranking.reciprocal_rank_fusion(
        db.scratch(),
        &.{ keyword_top, nearest, subtree },
    );
    defer db.scratch().free(fused);
    assert(fused.len <= keyword_top.len + nearest.len + subtree.len);

    return .{
        .links = try fetch_links(db, fused, limit, buffer, site_rows),
        .vector_used = true,
    };
}

fn rerank_exact(
    db: *Directory,
    shortlist: []const ScoredId,
    query: *const vector_index.Quantized,
    out: []ScoredId,
) ![]ScoredId {
    assert(query.scale > 0);
    var top = ranking.TopK.init(out);
    for (shortlist) |candidate| {
        const stored = (try vector_ops.get_link_vector(db, candidate.id)) orelse continue;
        top.offer(.{ .id = candidate.id, .score = vector_index.similarity(&stored, query) });
    }
    const ranked = top.sorted();
    assert(ranked.len <= out.len);
    assert(ranked.len <= shortlist.len);
    return ranked;
}

fn subtree_candidates(
    db: *Directory,
    unit: *const vector_model.Float,
    query: *const vector_index.Quantized,
    out: []ScoredId,
) ![]ScoredId {
    if (!db.category_vector_index.ready.load(.acquire)) return out[0..0];
    if (!db.facts.ready.load(.acquire)) return out[0..0];

    var roots_buffer: [category_candidates]ScoredId = undefined;
    const roots = db.category_vector_index.nearest(db.io, query, &roots_buffer);
    assert(roots.len <= category_candidates);
    var root_ids: [category_candidates]u64 = undefined;
    for (roots, root_ids[0..roots.len]) |root, *id| id.* = root.id;

    const ids = try db.facts.subtree_link_ids(db.io, db.scratch(), root_ids[0..roots.len]);
    defer db.scratch().free(ids);

    const scored = db.link_vector_index.score_ids(db.io, ids, unit, out);
    assert(scored.len <= out.len);
    assert(scored.len <= ids.len);
    return scored;
}

pub fn search_categories_hybrid(
    db: *Directory,
    query: []const u8,
    model: u64,
    query_embedding: *const vector_index.Embedding,
    limit: u32,
    buffer: []schema.Category,
) ![]schema.Category {
    const ranked = try ranked_ids(
        db.scratch(),
        db.categories_index_tree(),
        db.next_category_id.load(.monotonic),
        postings_per_token_max,
        query,
    );
    defer db.scratch().free(ranked);

    const quantized = if (category_half_usable(db, model))
        vector_index.quantize(query_embedding)
    else
        null;
    const query_quantized = quantized orelse {
        const hits = fetch_in_rank_order(
            schema.Category,
            db,
            ranked,
            limit,
            buffer,
            category.get_category,
        );
        assert(hits.len <= limit);
        return hits;
    };

    var nearest_buffer: [category_nearest]ScoredId = undefined;
    const nearest = db.category_vector_index.nearest(db.io, &query_quantized, &nearest_buffer);
    assert(nearest.len <= category_nearest);

    const ranked_top = ranked[0..@min(ranked.len, category_nearest)];
    const fused = try ranking.reciprocal_rank_fusion(db.scratch(), &.{ ranked_top, nearest });
    defer db.scratch().free(fused);
    assert(fused.len <= ranked_top.len + nearest.len);

    const hits = fetch_in_rank_order(
        schema.Category,
        db,
        fused,
        limit,
        buffer,
        category.get_category,
    );
    assert(hits.len <= limit);
    return hits;
}

fn vector_half_usable(db: *Directory, model: u64) bool {
    return model != 0 and
        db.link_vector_index.ready.load(.acquire) and
        db.link_vector_index.model.load(.acquire) == model;
}

fn category_half_usable(db: *Directory, model: u64) bool {
    return model != 0 and
        db.category_vector_index.ready.load(.acquire) and
        db.category_vector_index.model.load(.acquire) == model;
}

fn search_via_index_tree(
    comptime T: type,
    db: *Directory,
    tree: *BPlusTree,
    query: []const u8,
    limit: u32,
    buffer: []T,
    comptime getter: fn (*Directory, u64) anyerror!?T,
) ![]T {
    const max = @min(limit, @as(u32, @intCast(buffer.len)));
    if (max == 0) return buffer[0..0];

    var token_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var iterator = inverted.TokenIterator.init(query);

    var candidates_full: ?[]u64 = null;
    var candidates_len: usize = 0;
    defer if (candidates_full) |candidates| db.scratch().free(candidates);

    var had_any_token = false;
    while (iterator.next(&token_buffer)) |token| {
        had_any_token = true;
        assert(token.len <= inverted.MAX_TOKEN_LEN);
        const ids = postings_for_token(
            tree,
            token,
            db.scratch(),
            std.math.maxInt(usize),
        ) catch |err| {
            log.err("search_via_index_tree: rangeScan failed for token='{s}': {}", .{ token, err });
            return err;
        };

        if (candidates_full == null) {
            candidates_full = ids;
            candidates_len = ids.len;
            continue;
        }
        defer db.scratch().free(ids);

        const current = candidates_full.?[0..candidates_len];
        candidates_len = search_via_index_tree_intersect(current, ids);
        if (candidates_len == 0) break;
    }
    if (!had_any_token) assert(candidates_full == null);
    if (candidates_full) |candidates| assert(candidates_len <= candidates.len);
    if (!had_any_token or candidates_full == null) return buffer[0..0];

    var count: u32 = 0;
    for (candidates_full.?[0..candidates_len]) |id| {
        if (count >= max) break;
        if (getter(db, id) catch null) |item| {
            buffer[count] = item;
            count += 1;
        }
    }

    assert(count <= max);
    return buffer[0..count];
}

// Both lists ascend, so one pass keeps the ids they share, in place and still ascending.
fn search_via_index_tree_intersect(current: []u64, ids: []const u64) usize {
    var write: usize = 0;
    var i: usize = 0;
    var j: usize = 0;
    while (i < current.len and j < ids.len) {
        if (current[i] == ids[j]) {
            current[write] = current[i];
            write += 1;
            i += 1;
            j += 1;
        } else if (current[i] < ids[j]) {
            i += 1;
        } else {
            j += 1;
        }
    }
    assert(write <= current.len);
    assert(write <= ids.len);
    return write;
}

// Goal: a title word finds its link through the token index. Method: one link, one word.
test "search: B+Tree-backed link search finds tokenised title" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/c", .title = "Cannabis Stuff", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links(db, "cannabis", 8, &buffer);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(link_id, hits[0].id);
}

// Goal: a name word finds its category through the token index. Method: one category, one
// word, then look for its id among the hits.
test "search: B+Tree-backed category search finds tokenised name" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const category_id = try category.create_category(
        db,
        top_id,
        .{ .name = "Computers", .slug = "computers", .description = "" },
    );

    var buffer: [8]schema.Category = undefined;
    const hits = try search_categories(db, "computers", 8, &buffer);

    var found = false;
    for (hits) |hit| if (hit.id == category_id) {
        found = true;
    };
    try std.testing.expect(found);
}

// Goal: every query token must match, so a link with only one of two tokens is left out.
// Method: `alpha beta` against an `alpha beta` link and an `alpha only` link.
test "search: multi-token query AND-intersects per-token posting lists" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const l1 = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/1", .title = "Alpha Beta", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/2", .title = "Alpha Only", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links(db, "alpha beta", 8, &buffer);

    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(l1, hits[0].id);
}

// Goal: the intersection keeps the document holding both tokens and drops the one holding
// just `foo`. Method: two links sharing `foo` and `test`, queried for `foo bar`.
test "search: AND-of-tokens — \"foo bar\" excludes the foo-only doc" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const foo_bar_test = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/a", .title = "foo bar test", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/b", .title = "foo baz test", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links(db, "foo bar", 8, &buffer);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(foo_bar_test, hits[0].id);
}

// Goal: a token shared by two links returns both, ascending by id. Method: two links, one
// shared token.
test "search: shared token \"test\" returns both docs in ascending id order" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/a", .title = "foo bar test", .description = "" },
    );
    const b = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/b", .title = "foo baz test", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links(db, "test", 8, &buffer);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expect(hits[0].id < hits[1].id);
    try std.testing.expectEqual(a, hits[0].id);
    try std.testing.expectEqual(b, hits[1].id);
}

// Goal: a token nobody holds gives an empty result. Method: two links, a missing word.
test "search: token absent from corpus returns empty result set" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/a", .title = "foo bar test", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/b", .title = "foo baz test", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links(db, "nonexistent", 8, &buffer);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}

// Goal: ranked search is an OR over terms where the exact search is an AND. Method: the same
// `alpha gamma` query against both searches.
test "ranked search: a query sharing only some terms still matches" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const alpha = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/1", .title = "Alpha Beta", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        (try search_links(db, "alpha gamma", 8, &buffer)).len,
    );

    const hits = try search_links_ranked(db, "alpha gamma", 8, &buffer, null);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(alpha, hits[0].id);
}

// Goal: a link matching both terms outranks one matching the rarer term, which outranks the
// common term. Method: three `garden` links, one `bonsai`, one with both.
test "ranked search: more matched terms rank first, then rarer terms" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const common_only = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/1", .title = "garden", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/2", .title = "garden", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/3", .title = "garden", .description = "" },
    );
    const rare_only = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/4", .title = "bonsai", .description = "" },
    );
    const both = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/5", .title = "garden bonsai", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links_ranked(db, "bonsai garden", 8, &buffer, null);
    try std.testing.expectEqual(@as(usize, 5), hits.len);
    try std.testing.expectEqual(both, hits[0].id);
    try std.testing.expectEqual(rare_only, hits[1].id);
    try std.testing.expectEqual(common_only, hits[2].id);
}

// Goal: equal scores order by id and the buffer caps the page. Method: three identical
// `orchid` links into a buffer of two.
test "ranked search: equal scores break ties on ascending id" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const first = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/1", .title = "orchid", .description = "" },
    );
    const second = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/2", .title = "orchid", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/3", .title = "orchid", .description = "" },
    );

    var buffer: [2]schema.Link = undefined;
    const hits = try search_links_ranked(db, "orchid", 8, &buffer, null);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(first, hits[0].id);
    try std.testing.expectEqual(second, hits[1].id);
}

// Goal: repeating a term in the query does not weight it. Method: `orchid` three times plus
// `fern`, then both links with orchid first.
test "ranked search: repeated query terms count once" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const orchid = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/1", .title = "orchid", .description = "" },
    );
    const fern = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/2", .title = "fern", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    const hits = try search_links_ranked(db, "orchid orchid orchid fern", 8, &buffer, null);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(orchid, hits[0].id);
    try std.testing.expectEqual(fern, hits[1].id);
}

// Goal: a term whose postings exceed the cap is skipped instead of truncated, so only the
// rare term scores. Method: cap of two against a token held by three links.
test "ranked search: a token past the postings cap contributes nothing" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/1", .title = "www", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/2", .title = "www", .description = "" },
    );
    const rare = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/3", .title = "www bonsai", .description = "" },
    );

    const ranked = try ranked_ids(
        allocator,
        db.links_index_tree(),
        link_corpus_size(db),
        2,
        "www bonsai",
    );
    defer allocator.free(ranked);
    try std.testing.expectEqual(@as(usize, 1), ranked.len);
    try std.testing.expectEqual(rare, ranked[0].id);
}

// Goal: the category variant ranks by matched terms too. Method: a `gardening` and a
// `gardening bonsai` category, queried for three words.
test "ranked search: categories rank by matched terms" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try category.create_category(
        db,
        top_id,
        .{ .name = "Gardening", .slug = "gardening", .description = "" },
    );
    const both = try category.create_category(
        db,
        top_id,
        .{ .name = "Gardening Bonsai", .slug = "gardening-bonsai", .description = "" },
    );

    var buffer: [8]schema.Category = undefined;
    const hits = try search_categories_ranked(db, "bonsai gardening tools", 8, &buffer);
    try std.testing.expect(hits.len >= 2);
    try std.testing.expectEqual(both, hits[0].id);
}

// Goal: at most two links per site are shown, the hosts of one domain fold into one site and
// the overflow is counted on that site's last row, while hosted member pages stay separate
// sites. Method: four example.com links over three hosts and two tripod member pages.
test "ranked search caps the links shown per site" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const first = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://www.example.com/a", .title = "Bonsai A", .description = "" },
    );
    const second = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://shop.example.com/b", .title = "Bonsai B", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/c", .title = "Bonsai C", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/d", .title = "Bonsai D", .description = "" },
    );
    const ada = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "http://members.tripod.com/~ada/", .title = "Bonsai Ada", .description = "" },
    );
    const bob = try link_operations.create_link(
        db,
        top_id,
        .{ .url = "http://members.tripod.com/~bob/", .title = "Bonsai Bob", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    var rows: [8]RowSite = undefined;
    const hits = try search_links_ranked(db, "bonsai", 8, &buffer, &rows);

    try std.testing.expectEqual(@as(usize, 4), hits.len);
    for (
        [_]u64{ first, second, ada, bob },
        hits,
    ) |expected, hit| try std.testing.expectEqual(expected, hit.id);

    try std.testing.expectEqualStrings("example.com", rows[1].key());
    try std.testing.expectEqual(@as(u16, 2), rows[1].more);
    try std.testing.expectEqual(@as(u16, 0), rows[0].more);
    try std.testing.expectEqualStrings("members.tripod.com/~ada", rows[2].key());
    try std.testing.expectEqualStrings("members.tripod.com/~bob", rows[3].key());
    try std.testing.expectEqual(@as(u16, 0), rows[3].more);
}

// Goal: the inflection rules map a word to its other number and leave the exceptions alone.
// Method: a table of tokens and their expected variants.
test "inflection pairs a word with its plural or singular and leaves non-plural s-words alone" {
    var buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    const cases = [_]struct { token: []const u8, variant: ?[]const u8 }{
        .{ .token = "biography", .variant = "biographies" },
        .{ .token = "biographies", .variant = "biography" },
        .{ .token = "politicians", .variant = "politician" },
        .{ .token = "poet", .variant = "poets" },
        .{ .token = "churches", .variant = "church" },
        .{ .token = "church", .variant = "churches" },
        .{ .token = "news", .variant = null },
        .{ .token = "status", .variant = null },
        .{ .token = "days", .variant = "day" },
        .{ .token = "day", .variant = "days" },
    };
    for (cases) |case| {
        try std.testing.expectEqualDeep(case.variant, inflection(case.token, &buffer));
    }
}

// Goal: a query in either number finds links in both numbers as one term, and an exception
// such as `news` is not inflected. Method: `biography` and `biographies` links, both queries.
test "ranked search scores a word and its plural as one term, so either spelling finds both links" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(std.testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const singular = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://one.example", .title = "Keats biography", .description = "" },
    );
    const plural = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://two.example", .title = "Famous biographies", .description = "" },
    );
    const other = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://three.example", .title = "New arrivals", .description = "" },
    );

    var buffer: [8]schema.Link = undefined;
    for ([_][]const u8{ "biography", "biographies" }) |query| {
        const found = try search_links_ranked(db, query, 8, &buffer, null);
        try std.testing.expectEqual(@as(usize, 2), found.len);
        const ids = [_]u64{ found[0].id, found[1].id };
        try std.testing.expect(std.mem.indexOfScalar(u64, &ids, singular) != null);
        try std.testing.expect(std.mem.indexOfScalar(u64, &ids, plural) != null);
    }

    const news = try search_links_ranked(db, "news", 8, &buffer, null);
    try std.testing.expectEqual(@as(usize, 0), news.len);
    _ = other;
}
