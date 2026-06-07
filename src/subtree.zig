const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("schema.zig");
const Directory = @import("directory.zig").Directory;

pub const MAX_DESCENDANTS: u32 = 1_000_000;
pub const SubtreeError = error{ SubtreeTooLarge, OutOfMemory };

pub const SubtreeCache = struct {
    descendants: std.AutoHashMap(u64, []u64),
    link_counts: std.AutoHashMap(u64, u64),
    mutex: std.Thread.RwLock,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SubtreeCache {
        return .{
            .descendants = std.AutoHashMap(u64, []u64).init(allocator),
            .link_counts = std.AutoHashMap(u64, u64).init(allocator),
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SubtreeCache) void {
        var it = self.descendants.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.descendants.deinit();
        self.link_counts.deinit();
    }

    pub fn getDescendantsCopy(self: *SubtreeCache, root: u64, allocator: std.mem.Allocator) !?[]u64 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        const hit = self.descendants.get(root) orelse return null;
        return try allocator.dupe(u64, hit);
    }

    pub fn putDescendantsCopy(self: *SubtreeCache, root: u64, ids: []const u64) !void {
        const copy = try self.allocator.dupe(u64, ids);
        errdefer self.allocator.free(copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.descendants.getOrPut(root);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = copy;
    }

    pub fn getLinkCount(self: *SubtreeCache, root: u64) ?u64 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        return self.link_counts.get(root);
    }

    pub fn putLinkCount(self: *SubtreeCache, root: u64, count: u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.link_counts.put(root, count);
    }

    pub fn invalidateAll(self: *SubtreeCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.descendants.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.descendants.clearRetainingCapacity();
        self.link_counts.clearRetainingCapacity();
    }
};

pub fn collectDescendants(
    cat_by_parent: anytype,
    root: u64,
    allocator: std.mem.Allocator,
) ![]u64 {
    var visited = std.AutoHashMap(u64, void).init(allocator);
    defer visited.deinit();
    var queue: std.ArrayListUnmanaged(u64) = .{};
    defer queue.deinit(allocator);
    var result: std.ArrayListUnmanaged(u64) = .{};
    errdefer result.deinit(allocator);

    try visited.put(root, {});
    try queue.append(allocator, root);
    try result.append(allocator, root);

    while (queue.items.len > 0) {
        const cur = queue.pop().?;
        const start_key = schema.ParentChildKey.encode(.{ cur, 0 });
        var iter = try cat_by_parent.rangeScan(&start_key, null);
        while (try iter.next()) |entry| {
            if (entry.key.len < 16) return error.Corrupted;
            if (codec.decodeU64(entry.key[0..8]) != cur) break;
            const child = codec.decodeU64(entry.key[8..16]);
            const gop = try visited.getOrPut(child);
            if (gop.found_existing) continue;
            if (visited.count() > MAX_DESCENDANTS) return SubtreeError.SubtreeTooLarge;
            try queue.append(allocator, child);
            try result.append(allocator, child);
        }
    }

    std.mem.sort(u64, result.items, {}, std.sort.asc(u64));
    return result.toOwnedSlice(allocator);
}

pub const SubtreeLinkPage = struct {
    link_ids: []u64,
    total: u64,
};

pub fn listSubtreeLinkIds(
    link_by_category: anytype,
    descendants: []const u64,
    offset: u32,
    limit: u32,
    allocator: std.mem.Allocator,
) !SubtreeLinkPage {
    var page_ids: std.ArrayListUnmanaged(u64) = .{};
    errdefer page_ids.deinit(allocator);

    var total: u64 = 0;
    var skipped: u64 = 0;
    const offset_u64: u64 = offset;

    for (descendants) |cat_id| {
        const start_key = schema.CategoryLinkKey.encode(.{ cat_id, 0 });
        var iter = try link_by_category.rangeScan(&start_key, null);
        while (try iter.next()) |entry| {
            if (entry.key.len < 16) return error.Corrupted;
            if (codec.decodeU64(entry.key[0..8]) != cat_id) break;
            total += 1;
            if (skipped < offset_u64) {
                skipped += 1;
                continue;
            }
            if (page_ids.items.len >= limit) continue;
            const link_id = codec.decodeU64(entry.key[8..16]);
            try page_ids.append(allocator, link_id);
        }
    }

    return SubtreeLinkPage{
        .link_ids = try page_ids.toOwnedSlice(allocator),
        .total = total,
    };
}

pub fn collectDescendantsCached(
    cat_by_parent: anytype,
    root: u64,
    cache: *SubtreeCache,
    allocator: std.mem.Allocator,
) ![]u64 {
    if (try cache.getDescendantsCopy(root, allocator)) |copy| return copy;
    const fresh = try collectDescendants(cat_by_parent, root, allocator);
    cache.putDescendantsCopy(root, fresh) catch {};
    return fresh;
}

pub fn listSubtreeLinkIdsScan(
    link_by_category: anytype,
    descendants: []const u64,
    offset: u32,
    limit: u32,
    allocator: std.mem.Allocator,
) !SubtreeLinkPage {
    var desc_set = std.AutoHashMap(u64, void).init(allocator);
    defer desc_set.deinit();
    for (descendants) |d| try desc_set.put(d, {});

    var page_ids: std.ArrayListUnmanaged(u64) = .{};
    errdefer page_ids.deinit(allocator);

    var total: u64 = 0;
    var skipped: u64 = 0;
    const offset_u64: u64 = offset;

    const min_key: [16]u8 = .{0} ** 16;
    var iter = try link_by_category.rangeScan(&min_key, null);
    while (try iter.next()) |entry| {
        if (entry.key.len < 16) return error.Corrupted;
        const cat_id = codec.decodeU64(entry.key[0..8]);
        if (!desc_set.contains(cat_id)) continue;

        total += 1;
        if (skipped < offset_u64) {
            skipped += 1;
            continue;
        }
        if (page_ids.items.len >= limit) continue;
        const link_id = codec.decodeU64(entry.key[8..16]);
        try page_ids.append(allocator, link_id);
    }

    return SubtreeLinkPage{
        .link_ids = try page_ids.toOwnedSlice(allocator),
        .total = total,
    };
}

pub fn countSubtreeLinks(
    link_by_category: anytype,
    descendants: []const u64,
    allocator: std.mem.Allocator,
) !u64 {
    var desc_set = std.AutoHashMap(u64, void).init(allocator);
    defer desc_set.deinit();
    for (descendants) |d| try desc_set.put(d, {});

    var total: u64 = 0;
    const min_key: [16]u8 = .{0} ** 16;
    var iter = try link_by_category.rangeScan(&min_key, null);
    while (try iter.next()) |entry| {
        if (entry.key.len < 16) continue;
        const cat_id = codec.decodeU64(entry.key[0..8]);
        if (desc_set.contains(cat_id)) total += 1;
    }
    return total;
}

test "collectDescendants returns inclusive sorted set on a tiny synthetic tree" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(std.testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_by_parent = db.cat_by_parent();
    const edges = [_][2]u64{ .{ 1, 2 }, .{ 1, 3 }, .{ 2, 4 }, .{ 2, 5 } };
    inline for (edges) |edge| {
        const k = schema.ParentChildKey.encode(.{ edge[0], edge[1] });
        const v = codec.encodeU64(edge[1]);
        try cat_by_parent.insert(&k, &v);
    }

    const result = try collectDescendants(cat_by_parent, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 4, 5 }, result);
}

test "collectDescendants tolerates cycles via the visited set" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(std.testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_by_parent = db.cat_by_parent();
    const edges = [_][2]u64{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 3 } };
    inline for (edges) |edge| {
        const k = schema.ParentChildKey.encode(.{ edge[0], edge[1] });
        const v = codec.encodeU64(edge[1]);
        try cat_by_parent.insert(&k, &v);
    }

    const result = try collectDescendants(cat_by_parent, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3 }, result);
}

test "listSubtreeLinkIds: total counts everything; page slice is bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(std.testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const link_by_category = db.link_by_category();
    var cid: u64 = 1;
    while (cid <= 3) : (cid += 1) {
        var lid: u64 = 1;
        while (lid <= 10) : (lid += 1) {
            const link_id = cid * 100 + lid;
            const k = schema.CategoryLinkKey.encode(.{ cid, link_id });
            const v = codec.encodeU64(link_id);
            try link_by_category.insert(&k, &v);
        }
    }

    var ids = [_]u64{ 1, 2, 3 };
    const r1 = try listSubtreeLinkIds(
        link_by_category,
        ids[0..],
        0,
        15,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(r1.link_ids);
    try std.testing.expectEqual(@as(u64, 30), r1.total);
    try std.testing.expectEqual(@as(usize, 15), r1.link_ids.len);
    try std.testing.expectEqual(@as(u64, 101), r1.link_ids[0]);

    const r2 = try listSubtreeLinkIds(
        link_by_category,
        ids[0..],
        15,
        15,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(r2.link_ids);
    try std.testing.expectEqual(@as(u64, 30), r2.total);
    try std.testing.expectEqual(@as(usize, 15), r2.link_ids.len);
    try std.testing.expectEqual(@as(u64, 206), r2.link_ids[0]);
}
