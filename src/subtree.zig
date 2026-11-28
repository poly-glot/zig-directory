//! Subtree walks over the parent-child index: an explicit queue bounded by descendants_max
//! collects a root's descendants without recursion, and a per-root cache keeps the descendant
//! lists and link totals of the roots that browse requests hit repeatedly.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("schema.zig");
const Directory = @import("directory.zig").Directory;
const Page = @import("operations/operations_shared.zig").Page;

const log = std.log.scoped(.subtree);

pub const descendants_max: u32 = 1_000_000;
pub const SubtreeError = error{ SubtreeTooLarge, OutOfMemory };

// The cache holds at most this many descendant ids over all its roots, 32 MiB, and starts
// over when a put would pass it. Unknown roots are never cached, so this bounds what a caller
// walking real categories can pin: every root of a 632k-category tree some seven levels deep
// would hold about 4.4M ids, just past it.
pub const cached_ids_max: u64 = 1 << 22;

/// Counts the cache's invalidations; a type of its own so it cannot be mistaken for an id.
pub const Generation = enum(u64) { _ };

pub const SubtreeCache = struct {
    descendants: std.AutoHashMap(u64, []u64),
    ids_cached: u64,
    // Bumped by every invalidation. A walk that began before a write must not cache what it
    // read, so a reader takes the generation before it drains and puts only if it is unchanged.
    generation: Generation,
    mutex: std.Io.RwLock,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) SubtreeCache {
        return .{
            .descendants = std.AutoHashMap(u64, []u64).init(allocator),
            .ids_cached = 0,
            .generation = @enumFromInt(0),
            .mutex = .init,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubtreeCache) void {
        self.free_descendant_lists();
        self.descendants.deinit();
    }

    fn free_descendant_lists(self: *SubtreeCache) void {
        const cached = self.descendants.count();
        var freed: u32 = 0;
        var iterator = self.descendants.iterator();
        while (iterator.next()) |entry| : (freed += 1) {
            assert(freed < cached);
            self.allocator.free(entry.value_ptr.*);
        }
        assert(freed == cached);
        self.descendants.clearRetainingCapacity();
        self.ids_cached = 0;
    }

    pub fn generation_now(self: *SubtreeCache) Generation {
        self.mutex.lockSharedUncancelable(self.io);
        defer self.mutex.unlockShared(self.io);
        return self.generation;
    }

    pub fn get_descendants_copy(
        self: *SubtreeCache,
        root: u64,
        allocator: std.mem.Allocator,
    ) !?[]u64 {
        self.mutex.lockSharedUncancelable(self.io);
        defer self.mutex.unlockShared(self.io);
        const hit = self.descendants.get(root) orelse return null;
        assert(hit.len >= 1);
        assert(hit.len <= descendants_max);
        return try allocator.dupe(u64, hit);
    }

    /// Caches `ids` under `root` unless an invalidation has run since the caller read
    /// `generation_seen`, in which case the list may predate a write and is dropped.
    pub fn put_descendants_copy(
        self: *SubtreeCache,
        root: u64,
        ids: []const u64,
        generation_seen: Generation,
    ) !void {
        assert(ids.len >= 1);
        assert(ids.len <= descendants_max);
        comptime assert(descendants_max <= cached_ids_max);

        const copy = try self.allocator.dupe(u64, ids);
        var kept = false;
        defer if (!kept) self.allocator.free(copy);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.generation != generation_seen) return;
        if (self.descendants.fetchRemove(root)) |stale| {
            self.ids_cached -= stale.value.len;
            self.allocator.free(stale.value);
        }
        if (self.ids_cached + @as(u64, copy.len) > cached_ids_max) self.free_descendant_lists();
        try self.descendants.putNoClobber(root, copy);
        kept = true;
        self.ids_cached += copy.len;
        assert(self.ids_cached <= cached_ids_max);
    }

    pub fn invalidate_all(self: *SubtreeCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.free_descendant_lists();
        self.generation = @enumFromInt(@intFromEnum(self.generation) + 1);
        assert(self.descendants.count() == 0);
        assert(self.ids_cached == 0);
    }
};

pub fn collect_descendants(
    categories_by_parent: anytype,
    root: u64,
    allocator: std.mem.Allocator,
) ![]u64 {
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();
    var queue: std.ArrayListUnmanaged(u64) = .empty;
    defer queue.deinit(allocator);
    var result: std.ArrayListUnmanaged(u64) = .empty;
    errdefer result.deinit(allocator);

    try visited.put(root, {});
    try queue.append(allocator, root);
    try result.append(allocator, root);

    var popped: u32 = 0;
    while (queue.pop()) |current| : (popped += 1) {
        assert(popped < descendants_max);
        assert(visited.contains(current));
        const start_key = schema.ParentChildKey.encode(.{ current, 0 });
        var iterator = try categories_by_parent.rangeScan(&start_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.key.len < 16) return error.Corrupted;
            if (codec.decodeU64(entry.key[0..8]) != current) break;
            const child = codec.decodeU64(entry.key[8..16]);
            const slot = try visited.getOrPut(child);
            if (slot.found_existing) continue;
            if (visited.count() > descendants_max) return SubtreeError.SubtreeTooLarge;
            try queue.append(allocator, child);
            try result.append(allocator, child);
        }
        assert(queue.items.len <= descendants_max);
    }

    assert(result.items.len >= 1);
    assert(result.items.len == visited.count());
    std.mem.sort(u64, result.items, {}, std.sort.asc(u64));
    return result.toOwnedSlice(allocator);
}

/// A link_by_category row: the category it is filed under and the link. The caller compares
/// the category with the link record's own, since a row can outlive a move (see
/// `write_subtree_link_rows`).
pub const SubtreeLinkRow = struct { category_id: u64, link_id: u64 };

pub fn list_subtree_link_rows(
    link_by_category: anytype,
    descendants: []const u64,
    page: Page,
    allocator: std.mem.Allocator,
) ![]SubtreeLinkRow {
    assert(page.after_id == 0);
    assert(page.status_filter == null);
    assert(descendants.len <= descendants_max);
    var page_ids: std.ArrayListUnmanaged(SubtreeLinkRow) = .empty;
    errdefer page_ids.deinit(allocator);

    var skipped: u64 = 0;
    const offset_u64: u64 = page.offset;

    for (descendants) |category_id| {
        if (page_ids.items.len >= page.limit) break;
        const start_key = schema.CategoryLinkKey.encode(.{ category_id, 0 });
        var iterator = try link_by_category.rangeScan(&start_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.key.len < 16) return error.Corrupted;
            if (codec.decodeU64(entry.key[0..8]) != category_id) break;
            if (skipped < offset_u64) {
                skipped += 1;
                continue;
            }
            const link_id = codec.decodeU64(entry.key[8..16]);
            try page_ids.append(allocator, .{ .category_id = category_id, .link_id = link_id });
            if (page_ids.items.len >= page.limit) break;
        }
    }

    assert(skipped <= offset_u64);
    assert(page_ids.items.len <= page.limit);
    return page_ids.toOwnedSlice(allocator);
}

/// `generation_seen` is the cache's generation read before the caller drained the parent
/// index, so a walk that raced a write is returned but not cached.
pub fn collect_descendants_cached(
    categories_by_parent: anytype,
    root: u64,
    cache: *SubtreeCache,
    allocator: std.mem.Allocator,
    generation_seen: Generation,
) ![]u64 {
    if (try cache.get_descendants_copy(root, allocator)) |copy| return copy;
    const fresh = try collect_descendants(categories_by_parent, root, allocator);
    assert(fresh.len >= 1);
    assert(fresh.len <= descendants_max);
    cache.put_descendants_copy(root, fresh, generation_seen) catch |err| {
        log.warn("descendants of {d} not cached: {}", .{ root, err });
    };
    return fresh;
}

// Walk a five-node tree rooted at 1 and expect the root included and the ids sorted.
test "collect_descendants returns inclusive sorted set on a tiny synthetic tree" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(std.testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const categories_by_parent = db.cat_by_parent();
    const edges = [_][2]u64{ .{ 1, 2 }, .{ 1, 3 }, .{ 2, 4 }, .{ 2, 5 } };
    inline for (edges) |edge| {
        const key = schema.ParentChildKey.encode(.{ edge[0], edge[1] });
        const value = codec.encodeU64(edge[1]);
        try categories_by_parent.insert(&key, &value);
    }

    const result = try collect_descendants(categories_by_parent, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 4, 5 }, result);
}

// Edges 1->1, 1->2, 2->1 form cycles; the visited set must still terminate with {1, 2, 3}.
test "collect_descendants tolerates cycles via the visited set" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(std.testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const categories_by_parent = db.cat_by_parent();
    const edges = [_][2]u64{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 3 } };
    inline for (edges) |edge| {
        const key = schema.ParentChildKey.encode(.{ edge[0], edge[1] });
        const value = codec.encodeU64(edge[1]);
        try categories_by_parent.insert(&key, &value);
    }

    const result = try collect_descendants(categories_by_parent, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3 }, result);
}

// Thirty links across three categories: a page of 15, the next page of 15 starting at link
// 206, and a page of 3 ending at link 103.
test "list_subtree_link_rows: total counts everything; page slice is bounded" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(std.testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const link_by_category = db.link_by_category();
    var category_id: u64 = 1;
    while (category_id <= 3) : (category_id += 1) {
        var link_index: u64 = 1;
        while (link_index <= 10) : (link_index += 1) {
            const link_id = category_id * 100 + link_index;
            const key = schema.CategoryLinkKey.encode(.{ category_id, link_id });
            const value = codec.encodeU64(link_id);
            try link_by_category.insert(&key, &value);
        }
    }

    var ids = [_]u64{ 1, 2, 3 };
    const page_of_15 = try list_subtree_link_rows(
        link_by_category,
        ids[0..],
        .{ .limit = 15 },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(page_of_15);
    try std.testing.expectEqual(@as(usize, 15), page_of_15.len);
    try std.testing.expectEqual(@as(u64, 101), page_of_15[0].link_id);
    try std.testing.expectEqual(@as(u64, 1), page_of_15[0].category_id);

    const page_after_15 = try list_subtree_link_rows(
        link_by_category,
        ids[0..],
        .{ .offset = 15, .limit = 15 },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(page_after_15);
    try std.testing.expectEqual(@as(usize, 15), page_after_15.len);
    try std.testing.expectEqual(@as(u64, 206), page_after_15[0].link_id);

    const page_of_3 = try list_subtree_link_rows(
        link_by_category,
        ids[0..],
        .{ .limit = 3 },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(page_of_3);
    try std.testing.expectEqual(@as(usize, 3), page_of_3.len);
    try std.testing.expectEqual(@as(u64, 103), page_of_3[2].link_id);
}

// Goal: a walk that began before a write is answered but not cached, so later readers never
// see a tree from before the write. Method: take the generation, invalidate as a category move
// would, then walk with the generation taken first.
test "collect_descendants_cached does not cache a walk that raced an invalidation" {
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(std.testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const categories_by_parent = db.cat_by_parent();
    const key = schema.ParentChildKey.encode(.{ 1, 2 });
    const value = codec.encodeU64(2);
    try categories_by_parent.insert(&key, &value);

    var cache = SubtreeCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    const generation = cache.generation_now();
    cache.invalidate_all();

    const raced = try collect_descendants_cached(
        categories_by_parent,
        1,
        &cache,
        std.testing.allocator,
        generation,
    );
    defer std.testing.allocator.free(raced);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2 }, raced);
    const cached = try cache.get_descendants_copy(1, std.testing.allocator);
    try std.testing.expectEqual(@as(?[]u64, null), cached);

    const fresh = try collect_descendants_cached(
        categories_by_parent,
        1,
        &cache,
        std.testing.allocator,
        cache.generation_now(),
    );
    defer std.testing.allocator.free(fresh);
    try std.testing.expectEqual(@as(u32, 1), cache.descendants.count());
}

// Goal: the cache never holds more than cached_ids_max ids. Method: put five lists of
// descendants_max ids under five roots and expect the cache to have started over on the way.
test "the subtree cache holds at most cached_ids_max ids" {
    const ids = try std.testing.allocator.alloc(u64, descendants_max);
    defer std.testing.allocator.free(ids);
    for (ids, 0..) |*id, index| id.* = index + 1;

    var cache = SubtreeCache.init(std.testing.io, std.testing.allocator);
    defer cache.deinit();
    for (1..6) |root| {
        try cache.put_descendants_copy(root, ids, cache.generation_now());
        try std.testing.expect(cache.ids_cached <= cached_ids_max);
    }
    try std.testing.expect(cache.descendants.count() < 5);
    try std.testing.expect(cache.descendants.contains(5));
}
