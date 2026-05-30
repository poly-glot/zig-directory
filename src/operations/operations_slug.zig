// Slug-path helpers split from the original monolithic operations.zig.
// Public surface:
//   - resolveSlugPath        : slug-path → category id (with single-segment
//                              fallback and repair-window validation gate)
//   - buildSlugPath          : id → canonical hierarchical slug-path
//   - buildCanonicalSlugPath : Category snapshot → canonical hierarchical
//                              slug-path (avoids one extra getCategory)

const std = @import("std");
const types = @import("../types.zig");
const Database = @import("../database.zig").Database;
const category = @import("operations_category.zig");

/// Resolve a URL slug path to a category id.
///
/// Performs a direct lookup in `categories_by_slug_path` (full canonical
/// path → category id). For single-segment paths, falls back to
/// `categories_by_slug_only` (slug → shallowest category id) so that
/// e.g. "arts" resolves to "top/arts" without the caller having to
/// supply the full path. For multi-segment paths that miss, retries
/// with a `top/` prefix so the Web UI can use clean URLs like
/// `/category/arts/performing_arts` whose canonical form is
/// `top/arts/performing_arts`.
pub fn resolveSlugPath(db: *Database, path: []const u8) !?u64 {
    if (path.len == 0) return null;

    var v_buf: [8]u8 = undefined;
    var maybe_id: ?u64 = null;
    // The path that actually produced the index hit. Differs from `path`
    // when the `top/`-prepended retry succeeded; used for the repair-
    // window canonical-path validation below.
    var resolved_path: []const u8 = path;
    var top_buf: [2048]u8 = undefined;

    if (try db.categories_by_slug_path.search(path, &v_buf)) |val| {
        if (val.len == 8) maybe_id = std.mem.readInt(u64, val[0..8], .big);
    }
    // `top/` is the canonical root; the Web UI strips it from URLs.
    // Retry the lookup with `top/` prepended so `arts/foo` resolves to
    // the same id as `top/arts/foo`.
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
    // Single-segment fallback: try slug-only.
    if (maybe_id == null and std.mem.indexOfScalar(u8, path, '/') == null) {
        if (try db.categories_by_slug_only.search(path, &v_buf)) |val| {
            if (val.len == 8) maybe_id = std.mem.readInt(u64, val[0..8], .big);
        }
    }
    const cat_id = maybe_id orelse return null;

    // Steady-state fast path: queue empty → no orphans possible.
    if (db.slug_path_repair_queue.entry_count == 0) return cat_id;

    // Repair window: validate that the cat's CURRENT canonical path
    // matches what we actually resolved. Mismatch → orphan, hide it.
    const cat = (try category.getCategory(db, cat_id)) orelse return null;
    var path_buf: [2048]u8 = undefined;
    const canonical = (try buildCanonicalSlugPath(db, &cat, &path_buf)) orelse return null;
    if (!std.mem.eql(u8, canonical, resolved_path)) return null;
    return cat_id;
}

/// Build the full hierarchical slug path for a category by walking up
/// the parent chain.  Returns e.g. "Computers/Programming/Zig" for a
/// category whose parent's parent is "Computers", parent is "Programming",
/// and own slug is "Zig".  The result is written into `buf` and a slice
/// is returned, or null if the path cannot be built.
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

/// Like `buildSlugPath`, but takes the leaf `Category` directly so the
/// caller doesn't pay for an extra `getCategory(id)`. Used by the
/// read-side validation gate in `resolveSlugPath` and by the
/// `repair_worker` descendant walk.
pub fn buildCanonicalSlugPath(db: *Database, cat: *const types.Category, buf: []u8) !?[]const u8 {
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

    // Single-segment "top" — the root category itself, via full-path lookup.
    try std.testing.expectEqual(top_id, (try resolveSlugPath(db, "top")).?);

    // Full canonical paths.
    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "top/a")).?);
    try std.testing.expectEqual(b_id, (try resolveSlugPath(db, "top/a/b")).?);

    // Single-segment "a" — falls back to slug-only and resolves to A.
    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "a")).?);

    // Miss.
    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, "nonexistent"));

    // Multi-segment miss MUST NOT fall back to slug-only — "x/a" is not a path.
    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, "x/a"));

    // Empty path.
    try std.testing.expectEqual(@as(?u64, null), try resolveSlugPath(db, ""));

    // `top/`-prepend retry: Web URLs strip the `top/` prefix, so `a/b`
    // must resolve to the same id as `top/a/b`.
    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "a")).?);
    try std.testing.expectEqual(b_id, (try resolveSlugPath(db, "a/b")).?);
    // Genuine misses must stay misses (no false positives from the retry).
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

    // Plant a fake orphan: an entry at "top/old-a" pointing at a_id, even
    // though a's actual slug is "a" (so canonical path is "top/a").
    var v: [8]u8 = types.encodeU64(a_id);
    try db.categories_by_slug_path.insert("top/old-a", &v);

    // Without a queue entry, the fast path returns a_id (orphan still resolvable).
    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "top/old-a")).?);

    // Plant a queue entry to flip the gate.
    var task = types.RepairTask{ .cat_id = a_id, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue.insert(&key, std.mem.asBytes(&task));

    // With the queue non-empty, validation kicks in and the orphan is hidden.
    try std.testing.expect((try resolveSlugPath(db, "top/old-a")) == null);
    // The canonical path still resolves.
    try std.testing.expectEqual(a_id, (try resolveSlugPath(db, "top/a")).?);
}
