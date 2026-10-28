//! Slug paths: resolving a client path such as `top/arts/music` to a category id, and composing
//! the canonical path of a category from its parent chain. A composed path always ends with the
//! slug of its last category, and a descendant's path always starts with its root's path.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const category = @import("operations_category.zig");
const shared = @import("operations_shared.zig");
const OperationError = shared.OperationError;
const depth_max = shared.depth_max;
const slug_len_max = shared.slug_len_max;

pub fn resolve_slug_path(db: *Directory, path: []const u8) !?u64 {
    if (path.len == 0) return null;

    var value_buffer: [8]u8 = undefined;
    var maybe_id: ?u64 = null;
    var resolved_path: []const u8 = path;
    var top_buffer: [2048]u8 = undefined;

    if (try db.categories_by_slug_path().search(path, &value_buffer)) |value| {
        if (value.len == 8) maybe_id = codec.decodeU64(value[0..8]);
    }
    if (maybe_id == null and !std.mem.startsWith(u8, path, "top/")) {
        const need = "top/".len + path.len;
        if (need <= top_buffer.len) {
            @memcpy(top_buffer[0.."top/".len], "top/");
            @memcpy(top_buffer["top/".len..need], path);
            const with_top = top_buffer[0..need];
            if (try db.categories_by_slug_path().search(with_top, &value_buffer)) |value| {
                if (value.len == 8) {
                    maybe_id = codec.decodeU64(value[0..8]);
                    resolved_path = with_top;
                }
            }
        }
    }
    if (maybe_id == null and std.mem.indexOfScalar(u8, path, '/') == null) {
        if (try db.categories_by_slug_only().search(path, &value_buffer)) |value| {
            if (value.len == 8) maybe_id = codec.decodeU64(value[0..8]);
        }
    }
    const category_id = maybe_id orelse return null;
    assert(resolved_path.len >= path.len);

    // While a rename or move is still being repaired, a stale path still maps to its id, so
    // the match only counts once the canonical path agrees with the one that matched.
    if (db.slug_path_repair_queue().entry_count == 0) return category_id;

    var path_buffer: [2048]u8 = undefined;
    const canonical = (try build_slug_path(db, category_id, &path_buffer)) orelse return null;
    assert(canonical.len > 0);
    if (!std.mem.eql(u8, canonical, resolved_path)) return null;
    return category_id;
}

pub fn ensure_slug_path_free(
    db: *Directory,
    options: struct { parent_id: u64, own_id: u64 },
    slug: []const u8,
) !void {
    assert(slug.len <= slug_len_max);

    var path_buffer: [2048]u8 = undefined;
    const path = (try compose_child_slug_path(db, options.parent_id, slug, &path_buffer)) orelse
        return;
    assert(std.mem.endsWith(u8, path, slug));

    var value_buffer: [8]u8 = undefined;
    const existing = (try db.categories_by_slug_path().search(path, &value_buffer)) orelse return;
    if (existing.len == 8 and codec.decodeU64(existing[0..8]) == options.own_id) return;
    return OperationError.DuplicateSlug;
}

pub fn compose_child_slug_path(
    db: *Directory,
    parent_id: u64,
    slug: []const u8,
    buffer: []u8,
) !?[]const u8 {
    assert(slug.len <= slug_len_max);
    if (parent_id == 0) {
        if (slug.len > buffer.len) return null;
        @memcpy(buffer[0..slug.len], slug);
        return buffer[0..slug.len];
    }
    const parent_path = (try build_slug_path(db, parent_id, buffer)) orelse return null;
    assert(parent_path.len > 0);
    const total = parent_path.len + 1 + slug.len;
    if (total > buffer.len) return null;
    buffer[parent_path.len] = '/';
    @memcpy(buffer[parent_path.len + 1 ..][0..slug.len], slug);
    const path = buffer[0..total];
    assert(std.mem.endsWith(u8, path, slug));
    return path;
}

pub fn build_slug_path(db: *Directory, id: u64, buffer: []u8) !?[]const u8 {
    var id_path: [depth_max]u64 = undefined;
    const path_ids = try category.get_category_path(db, id, &id_path);
    assert(path_ids.len <= depth_max);
    if (path_ids.len > 0) assert(path_ids[path_ids.len - 1] == id);

    var position: usize = 0;
    for (path_ids, 0..) |path_id, i| {
        const path_category = (try category.get_category(db, path_id)) orelse return null;
        const slug = path_category.slug.slice();
        if (slug.len == 0) continue;

        if (i > 0 and position > 0) {
            if (position >= buffer.len) return null;
            buffer[position] = '/';
            position += 1;
        }

        if (position + slug.len > buffer.len) return null;
        @memcpy(buffer[position..][0..slug.len], slug);
        position += slug.len;
    }

    if (position == 0) return null;
    return buffer[0..position];
}

pub fn compose_old_descendant_path(
    db: *Directory,
    old_root_path: []const u8,
    options: struct { root_id: u64, descendant_id: u64 },
    buffer: []u8,
) ![]const u8 {
    var chain: [depth_max]u64 = undefined;
    var depth: u32 = 0;
    var current = options.descendant_id;
    while (current != options.root_id and depth < chain.len) : (depth += 1) {
        chain[depth] = current;
        const current_category = (try category.get_category(db, current)) orelse
            return error.NotFound;
        current = current_category.parent_id;
        if (current == 0) return error.NotFound;
    }
    if (current != options.root_id) return error.NotFound;
    if (depth > 0) assert(chain[0] == options.descendant_id);

    var position: usize = 0;
    if (old_root_path.len > buffer.len) return error.NotFound;
    @memcpy(buffer[position..][0..old_root_path.len], old_root_path);
    position += old_root_path.len;

    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const chain_category = (try category.get_category(db, chain[i])) orelse
            return error.NotFound;
        const slug = chain_category.slug.slice();
        if (slug.len == 0) continue;
        if (position + 1 + slug.len > buffer.len) return error.NotFound;
        buffer[position] = '/';
        position += 1;
        @memcpy(buffer[position..][0..slug.len], slug);
        position += slug.len;
    }
    const path = buffer[0..position];
    assert(std.mem.startsWith(u8, path, old_root_path));
    return path;
}

// Goal: a path resolves through the full path, the implicit `top/` prefix or a lone slug, and a
// miss or an empty path gives null. Method: a three-level tree, then every lookup form.
test "resolve_slug_path: full path, single-segment fallback, miss" {
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
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const b_id = try category.create_category(
        db,
        a_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );

    try std.testing.expectEqual(top_id, (try resolve_slug_path(db, "top")).?);

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "top/a")).?);
    try std.testing.expectEqual(b_id, (try resolve_slug_path(db, "top/a/b")).?);

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "a")).?);

    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, "nonexistent"));

    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, "x/a"));

    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, ""));

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "a")).?);
    try std.testing.expectEqual(b_id, (try resolve_slug_path(db, "a/b")).?);
    try std.testing.expectEqual(@as(?u64, null), try resolve_slug_path(db, "a/nonexistent"));
}

// Goal: the canonical path joins the slugs of the parent chain with `/`. Method: a child under
// `top`, then its composed path.
test "build_slug_path: composes path from the parent chain" {
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
    const child_id = try category.create_category(
        db,
        top_id,
        .{ .name = "Child", .slug = "child", .description = "" },
    );
    var buffer: [1024]u8 = undefined;
    const path = (try build_slug_path(db, child_id, &buffer)).?;
    try std.testing.expectEqualStrings("top/child", path);
}

// Goal: with no repair pending a lookup returns the indexed id without rebuilding the path.
// Method: one category, a drained memtable, then a lookup and an empty repair queue.
test "resolve_slug_path: returns id for queue-empty fast path (steady state)" {
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
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try std.testing.expectEqual(top_id, (try resolve_slug_path(db, "top")).?);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);
}

// Goal: while a repair task is queued, a stale path that still maps to an id resolves to
// nothing and only the canonical path resolves. Method: plant a stale index entry, then
// enqueue a repair task and look both paths up.
test "resolve_slug_path: validation gate hides orphans during repair window" {
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
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    var value: [8]u8 = codec.encodeU64(a_id);
    try db.categories_by_slug_path().insert("top/old-a", &value);

    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "top/old-a")).?);

    var task = schema.RepairTask{ .cat_id = a_id, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));

    try std.testing.expect((try resolve_slug_path(db, "top/old-a")) == null);
    try std.testing.expectEqual(a_id, (try resolve_slug_path(db, "top/a")).?);
}
