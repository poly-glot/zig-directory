const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Database = @import("../database.zig").Database;
const category = @import("operations_category.zig");

pub fn resolveSlugPath(db: *Database, path: []const u8) !?u64 {
    if (path.len == 0) return null;

    var v_buf: [8]u8 = undefined;
    var maybe_id: ?u64 = null;
    var resolved_path: []const u8 = path;
    var top_buf: [2048]u8 = undefined;

    if (try db.categories_by_slug_path.search(path, &v_buf)) |val| {
        if (val.len == 8) maybe_id = std.mem.readInt(u64, val[0..8], .big);
    }
    if (maybe_id == null and !std.mem.startsWith(u8, path, "top/")) {
        const need = "top/".len + path.len;
        if (need <= top_buf.len) {
            @memcpy(top_buf[0.."top/".len], "top/");
            @memcpy(top_buf["top/".len..need], path);
            const with_top = top_buf[0..need];
            if (try db.categories_by_slug_path.search(with_top, &v_buf)) |val| {
                if (val.len == 8) {
                    maybe_id = std.mem.readInt(u64, val[0..8], .big);
                    resolved_path = with_top;
                }
            }
        }
    }
    if (maybe_id == null and std.mem.indexOfScalar(u8, path, '/') == null) {
        if (try db.categories_by_slug_only.search(path, &v_buf)) |val| {
            if (val.len == 8) maybe_id = std.mem.readInt(u64, val[0..8], .big);
        }
    }
    const cat_id = maybe_id orelse return null;

    if (db.slug_path_repair_queue.entry_count == 0) return cat_id;

    const cat = (try category.getCategory(db, cat_id)) orelse return null;
    var path_buf: [2048]u8 = undefined;
    const canonical = (try buildCanonicalSlugPath(db, &cat, &path_buf)) orelse return null;
    if (!std.mem.eql(u8, canonical, resolved_path)) return null;
    return cat_id;
}

pub fn buildSlugPath(db: *Database, id: u64, buf: []u8) !?[]const u8 {
    var id_path: [64]u64 = undefined;
    const path_ids = try category.getCategoryPath(db, id, &id_path);

    var pos: usize = 0;
    for (path_ids, 0..) |cid, i| {
        const cat = (try category.getCategory(db, cid)) orelse return null;
        const slug = cat.slug.slice();
        if (slug.len == 0) continue;

        if (i > 0 and pos > 0) {
            if (pos >= buf.len) return null;
            buf[pos] = '/';
            pos += 1;
        }

        if (pos + slug.len > buf.len) return null;
        @memcpy(buf[pos..][0..slug.len], slug);
        pos += slug.len;
    }

    if (pos == 0) return null;
    return buf[0..pos];
}

pub fn buildCanonicalSlugPath(db: *Database, cat: *const schema.Category, buf: []u8) !?[]const u8 {
    var id_path: [64]u64 = undefined;
    const path_ids = try category.getCategoryPath(db, cat.id, &id_path);
    var pos: usize = 0;
    for (path_ids, 0..) |cid, i| {
        const c = if (cid == cat.id) cat.* else (try category.getCategory(db, cid)) orelse return null;
        const slug = c.slug.slice();
        if (slug.len == 0) continue;
        if (i > 0 and pos > 0) {
            if (pos >= buf.len) return null;
            buf[pos] = '/';
            pos += 1;
        }
        if (pos + slug.len > buf.len) return null;
        @memcpy(buf[pos..][0..slug.len], slug);
        pos += slug.len;
    }
    if (pos == 0) return null;
    return buf[0..pos];
}

test "resolveSlugPath: full path, single-segment fallback, miss" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const b_id = try category.createCategory(db, a_id, "B", "b", "");

    try std.testing.expectEqual(top_id, (try resolveSlugPath(db, "top")).?);

    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "top/a")).?);
    try std.testing.expectEqual(b_id, (try resolveSlugPath(db, "top/a/b")).?);

    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "a")).?);

    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, "nonexistent"));

    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, "x/a"));

    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, ""));

    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "a")).?);
    try std.testing.expectEqual(b_id, (try resolveSlugPath(db, "a/b")).?);
    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, "a/nonexistent"));
}

test "buildCanonicalSlugPath: composes path from cat + parent chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const child_id = try category.createCategory(db, top_id, "Child", "child", "");
    const child = (try category.getCategory(db, child_id)).?;
    var buf: [1024]u8 = undefined;
    const path = (try buildCanonicalSlugPath(db, &child, &buf)).?;
    try std.testing.expectEqualStrings("top/child", path);
}

test "resolveSlugPath: returns id for queue-empty fast path (steady state)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    try std.testing.expectEqual(top_id, (try resolveSlugPath(db, "top")).?);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue.entry_count);
}

test "resolveSlugPath: validation gate hides orphans during repair window" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    var v: [8]u8 = codec.encodeU64(a_id);
    try db.categories_by_slug_path.insert("top/old-a", &v);

    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "top/old-a")).?);

    var task = schema.RepairTask{ .cat_id = a_id, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue.insert(&key, std.mem.asBytes(&task));

    try std.testing.expect((try resolveSlugPath(db, "top/old-a")) == null);
    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "top/a")).?);
}
