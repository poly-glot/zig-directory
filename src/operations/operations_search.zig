const std = @import("std");
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const inverted = @import("zigstore").inverted_index;
const category = @import("operations_category.zig");
const link_mod = @import("operations_link.zig");
const shared = @import("operations_shared.zig");

const log = shared.log;

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

fn searchTreeByToken(
    tree: *@import("zigstore").BPlusTree,
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

    var iter = try tree.rangeScan(
        key_lo_buf[0 .. token.len + 8],
        key_hi_buf[0 .. token.len + 8],
    );

    var ids: std.ArrayListUnmanaged(u64) = .{};
    errdefer ids.deinit(allocator);

    while (try iter.next()) |kv| {
        if (kv.key.len != token.len + 8) continue;
        if (!std.mem.eql(u8, kv.key[0..token.len], token)) break;
        const id = std.mem.readInt(u64, kv.key[token.len..][0..8], .big);
        try ids.append(allocator, id);
    }

    return try ids.toOwnedSlice(allocator);
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
