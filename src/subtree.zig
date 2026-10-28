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

pub const SubtreeCache = struct {
    descendants: std.AutoHashMap(u64, []u64),
    link_counts: std.AutoHashMap(u64, u64),
    mutex: std.Io.RwLock,
    io: std.Io,
    allocator: std.mem.Allocator,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) SubtreeCache {
        return .{
            .descendants = std.AutoHashMap(u64, []u64).init(allocator),
            .link_counts = std.AutoHashMap(u64, u64).init(allocator),
            .mutex = .init,
            .io = io,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubtreeCache) void {
        self.free_descendant_lists();
        self.descendants.deinit();
        self.link_counts.deinit();
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

    pub fn put_descendants_copy(self: *SubtreeCache, root: u64, ids: []const u64) !void {
        assert(ids.len >= 1);
        assert(ids.len <= descendants_max);

        const copy = try self.allocator.dupe(u64, ids);
        errdefer self.allocator.free(copy);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const slot = try self.descendants.getOrPut(root);
        if (slot.found_existing) self.allocator.free(slot.value_ptr.*);
        slot.value_ptr.* = copy;
    }

    pub fn get_link_count(self: *SubtreeCache, root: u64) ?u64 {
        self.mutex.lockSharedUncancelable(self.io);
        defer self.mutex.unlockShared(self.io);
        return self.link_counts.get(root);
    }

    pub fn put_link_count(self: *SubtreeCache, options: struct { root: u64, count: u64 }) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.link_counts.put(options.root, options.count);
    }

    pub fn invalidate_all(self: *SubtreeCache) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.free_descendant_lists();
        self.descendants.clearRetainingCapacity();
        self.link_counts.clearRetainingCapacity();
        assert(self.descendants.count() == 0);
        assert(self.link_counts.count() == 0);
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

pub const SubtreeLinkPage = struct {
    link_ids: []u64,
    total: u64,
};

pub fn list_subtree_link_ids(
    link_by_category: anytype,
    descendants: []const u64,
    page: Page,
    allocator: std.mem.Allocator,
) ![]u64 {
    assert(page.after_id == 0);
    assert(page.status_filter == null);
    assert(descendants.len <= descendants_max);
    var page_ids: std.ArrayListUnmanaged(u64) = .empty;
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
            try page_ids.append(allocator, link_id);
            if (page_ids.items.len >= page.limit) break;
        }
    }

    assert(skipped <= offset_u64);
    assert(page_ids.items.len <= page.limit);
    return page_ids.toOwnedSlice(allocator);
}

pub fn collect_descendants_cached(
    categories_by_parent: anytype,
    root: u64,
    cache: *SubtreeCache,
    allocator: std.mem.Allocator,
) ![]u64 {
    if (try cache.get_descendants_copy(root, allocator)) |copy| return copy;
    const fresh = try collect_descendants(categories_by_parent, root, allocator);
    assert(fresh.len >= 1);
    assert(fresh.len <= descendants_max);
    cache.put_descendants_copy(root, fresh) catch |err| {
        log.warn("descendants of {d} not cached: {}", .{ root, err });
    };
    return fresh;
}

pub fn list_subtree_link_ids_scan(
    link_by_category: anytype,
    descendants: []const u64,
    page: Page,
    allocator: std.mem.Allocator,
) !SubtreeLinkPage {
    assert(page.after_id == 0);
    assert(page.status_filter == null);
    var descendant_set = std.AutoHashMap(u64, void).init(allocator);
    defer descendant_set.deinit();
    for (descendants) |descendant| try descendant_set.put(descendant, {});
    assert(descendant_set.count() == descendants.len);

    var page_ids: std.ArrayListUnmanaged(u64) = .empty;
    errdefer page_ids.deinit(allocator);

    var total: u64 = 0;
    var skipped: u64 = 0;
    const offset_u64: u64 = page.offset;

    const min_key: [16]u8 = @splat(0);
    var iterator = try link_by_category.rangeScan(&min_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        if (entry.key.len < 16) return error.Corrupted;
        const category_id = codec.decodeU64(entry.key[0..8]);
        if (!descendant_set.contains(category_id)) continue;

        total += 1;
        if (skipped < offset_u64) {
            skipped += 1;
            continue;
        }
        if (page_ids.items.len >= page.limit) continue;
        const link_id = codec.decodeU64(entry.key[8..16]);
        try page_ids.append(allocator, link_id);
    }

    assert(skipped <= offset_u64);
    assert(page_ids.items.len <= page.limit);
    assert(total >= skipped + page_ids.items.len);
    return SubtreeLinkPage{
        .link_ids = try page_ids.toOwnedSlice(allocator),
        .total = total,
    };
}

pub fn count_subtree_links(
    link_by_category: anytype,
    descendants: []const u64,
    allocator: std.mem.Allocator,
) !u64 {
    var descendant_set = std.AutoHashMap(u64, void).init(allocator);
    defer descendant_set.deinit();
    for (descendants) |descendant| try descendant_set.put(descendant, {});
    assert(descendant_set.count() == descendants.len);

    var total: u64 = 0;
    const min_key: [16]u8 = @splat(0);
    var iterator = try link_by_category.rangeScan(&min_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        if (entry.key.len < 16) continue;
        const category_id = codec.decodeU64(entry.key[0..8]);
        if (descendant_set.contains(category_id)) total += 1;
    }
    return total;
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
test "list_subtree_link_ids: total counts everything; page slice is bounded" {
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
    const page_of_15 = try list_subtree_link_ids(
        link_by_category,
        ids[0..],
        .{ .limit = 15 },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(page_of_15);
    try std.testing.expectEqual(@as(usize, 15), page_of_15.len);
    try std.testing.expectEqual(@as(u64, 101), page_of_15[0]);

    const page_after_15 = try list_subtree_link_ids(
        link_by_category,
        ids[0..],
        .{ .offset = 15, .limit = 15 },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(page_after_15);
    try std.testing.expectEqual(@as(usize, 15), page_after_15.len);
    try std.testing.expectEqual(@as(u64, 206), page_after_15[0]);

    const page_of_3 = try list_subtree_link_ids(
        link_by_category,
        ids[0..],
        .{ .limit = 3 },
        std.testing.allocator,
    );
    defer std.testing.allocator.free(page_of_3);
    try std.testing.expectEqual(@as(usize, 3), page_of_3.len);
    try std.testing.expectEqual(@as(u64, 103), page_of_3[2]);
}
