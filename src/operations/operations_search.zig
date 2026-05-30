// Search operations split from the original monolithic operations.zig.
// Public surface:
//   - searchCategories : tokenised AND-search over `categories_index_tree`
//   - searchLinks      : tokenised AND-search over `links_index_tree`
//
// Internal helpers (`searchTreeByToken`, `searchViaIndexTree`) stay
// private to this file — no other operations_* file references them.

const std = @import("std");
const types = @import("../types.zig");
const Database = @import("../database.zig").Database;
const inverted = @import("../inverted_index.zig");
const category = @import("operations_category.zig");
const link_mod = @import("operations_link.zig");
const shared = @import("operations_shared.zig");

const log = shared.log;

/// Search categories by name, slug, or description.
/// Tokenises the query and intersects per-token posting lists from
/// `db.categories_index_tree`. AND semantics for multi-token queries.
pub fn searchCategories(
    db: *Database,
    query: []const u8,
    limit: u32,
    buf: []types.Category,
) ![]types.Category {
    return searchViaIndexTree(
        types.Category,
        db,
        &db.categories_index_tree,
        query,
        limit,
        buf,
        category.getCategory,
    );
}

/// Search links by title, URL, or description.
/// Tokenises the query and intersects per-token posting lists from
/// `db.links_index_tree`. AND semantics for multi-token queries.
pub fn searchLinks(
    db: *Database,
    query: []const u8,
    limit: u32,
    buf: []types.Link,
) ![]types.Link {
    return searchViaIndexTree(
        types.Link,
        db,
        &db.links_index_tree,
        query,
        limit,
        buf,
        link_mod.getLink,
    );
}

/// Range-scan `tree` for all entries whose key is `(token || doc_id_be)`,
/// returning the decoded doc-id set as an owned, ascending-sorted slice.
/// The caller owns the returned memory and must free it with `allocator`.
fn searchTreeByToken(
    tree: *@import("../btree/btree.zig").BPlusTree,
    token: []const u8,
    allocator: std.mem.Allocator,
) ![]u64 {
    const KEY_BUF_LEN: usize = inverted.MAX_TOKEN_LEN + 8;
    if (token.len + 8 > KEY_BUF_LEN) return &[_]u64{};

    var key_lo_buf: [KEY_BUF_LEN]u8 = undefined;
    var key_hi_buf: [KEY_BUF_LEN]u8 = undefined;
    @memcpy(key_lo_buf[0..token.len], token);
    @memset(key_lo_buf[token.len..][0..8], 0);
    @memcpy(key_hi_buf[0..token.len], token);
    @memset(key_hi_buf[token.len..][0..8], 0xFF);

    // RangeScanIterator treats `end_key` as exclusive (key < end_key stops),
    // so adding one to the upper bound (or using a sentinel above the max
    // doc_id) would skip the doc_id == max_u64 case. In practice doc_ids
    // never reach max_u64; the exclusive bound at (token||0xFF*8) means we
    // miss only that single hypothetical id, an acceptable trade-off.
    var iter = try tree.rangeScan(
        key_lo_buf[0 .. token.len + 8],
        key_hi_buf[0 .. token.len + 8],
    );

    var ids: std.ArrayListUnmanaged(u64) = .{};
    errdefer ids.deinit(allocator);

    while (try iter.next()) |kv| {
        // Defensive: rangeScan can include keys with the same prefix when
        // the iterator walks past the exclusive upper bound on a leaf
        // boundary. Stop as soon as the prefix no longer matches.
        if (kv.key.len != token.len + 8) continue;
        if (!std.mem.eql(u8, kv.key[0..token.len], token)) break;
        const id = std.mem.readInt(u64, kv.key[token.len..][0..8], .big);
        try ids.append(allocator, id);
    }

    return try ids.toOwnedSlice(allocator);
}

/// Generic index-tree-backed search: tokenise the query, range-scan the
/// posting list for each token, AND-intersect across tokens, then
/// hydrate the first `limit` matches via the provided getter.
fn searchViaIndexTree(
    comptime T: type,
    db: *Database,
    tree: *@import("../btree/btree.zig").BPlusTree,
    query: []const u8,
    limit: u32,
    buf: []T,
    comptime getter: fn (*Database, u64) anyerror!?T,
) ![]T {
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    if (max == 0) return buf[0..0];

    // Tokenise the query the same way documents are tokenised at index
    // time (lowercase ASCII alphanumeric runs of length [MIN_TOKEN_LEN,
    // MAX_TOKEN_LEN]). Tokens shorter than MIN_TOKEN_LEN are dropped by
    // TokenIterator, which mirrors the indexing pipeline.
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var iter = inverted.TokenIterator.init(query);

    // First token seeds the candidate set; each subsequent token
    // intersects against it (AND semantics). `candidates_full` retains
    // the full original allocation (so allocator.free sees the exact
    // length it was given), while `candidates_len` tracks the live
    // prefix shrunk by intersection.
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

        // Intersect candidates ∩ ids in place. Both slices are produced
        // by ascending range scans, so a two-pointer merge is O(n+m).
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try link_mod.createLink(db, top_id, "https://example.com/c", "Cannabis Stuff", "");

    var buf: [8]types.Link = undefined;
    const hits = try searchLinks(db, "cannabis", 8, &buf);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(link_id, hits[0].id);
}

test "search: B+Tree-backed category search finds tokenised name" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const cat_id = try category.createCategory(db, top_id, "Computers", "computers", "");

    var buf: [8]types.Category = undefined;
    const hits = try searchCategories(db, "computers", 8, &buf);

    // Both "Top" (whose slug "top" doesn't match) and "Computers" share no
    // tokens with the query except via "Computers" itself — only cat_id
    // should appear.
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    // l1 contains both "alpha" and "beta"; l2 contains only "alpha".
    const l1 = try link_mod.createLink(db, top_id, "https://example.com/1", "Alpha Beta", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/2", "Alpha Only", "");

    var buf: [8]types.Link = undefined;
    const hits = try searchLinks(db, "alpha beta", 8, &buf);

    // AND semantics: only l1 satisfies both tokens.
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(l1, hits[0].id);
}

test "search: AND-of-tokens — \"foo bar\" excludes the foo-only doc" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const foo_bar_test = try link_mod.createLink(db, top_id, "https://example.com/a", "foo bar test", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/b", "foo baz test", "");

    var buf: [8]types.Link = undefined;
    const hits = try searchLinks(db, "foo bar", 8, &buf);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(foo_bar_test, hits[0].id);
}

test "search: shared token \"test\" returns both docs in ascending id order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a = try link_mod.createLink(db, top_id, "https://example.com/a", "foo bar test", "");
    const b = try link_mod.createLink(db, top_id, "https://example.com/b", "foo baz test", "");

    var buf: [8]types.Link = undefined;
    const hits = try searchLinks(db, "test", 8, &buf);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    // Stable ordering: ids ascend.
    try std.testing.expect(hits[0].id < hits[1].id);
    try std.testing.expectEqual(a, hits[0].id);
    try std.testing.expectEqual(b, hits[1].id);
}

test "search: token absent from corpus returns empty result set" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/a", "foo bar test", "");
    _ = try link_mod.createLink(db, top_id, "https://example.com/b", "foo baz test", "");

    var buf: [8]types.Link = undefined;
    const hits = try searchLinks(db, "nonexistent", 8, &buf);
    try std.testing.expectEqual(@as(usize, 0), hits.len);
}
