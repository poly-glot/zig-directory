const std = @import("std");
const types = @import("types.zig");
const btree = @import("btree/btree.zig");
const page_cache = @import("page_cache.zig");
const freelist = @import("freelist.zig");
const page = @import("page.zig");

// `collectDescendants` lives below — see test for contract.

pub const MAX_DESCENDANTS: u32 = 1_000_000;
pub const SubtreeError = error{ SubtreeTooLarge, OutOfMemory };

/// Process-lifetime cache of subtree-descendant id lists, keyed by
/// the subtree root cat_id. Computing the descendant set for a large
/// subtree (e.g. Regional, ~100k descendants) is the dominant cost
/// of a category browse; caching turns the 2nd-and-later request for
/// the same subtree into a HashMap lookup.
///
/// Invalidation policy: full clear on any write op (createCategory,
/// deleteCategory, moveCategory, createLink, deleteLink, etc.). DMOZ
/// is read-heavy in practice, so this is acceptable. Writers call
/// `invalidateAll()`.
pub const SubtreeCache = struct {
    descendants: std.AutoHashMap(u64, []u64),
    /// Subtree-link-counts cache, also keyed by root cat_id. Populated
    /// alongside descendants when callers compute totals. Same
    /// invalidation policy.
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

    /// Return the cached descendant slice for `root` if present, else null.
    /// The returned slice is owned by the cache; do not free.
    pub fn getDescendants(self: *SubtreeCache, root: u64) ?[]const u64 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        return self.descendants.get(root);
    }

    /// Store an owned descendant slice. The cache takes ownership;
    /// caller must not free or mutate after this call. If the key
    /// is already present, the existing slice is freed and replaced.
    pub fn putDescendants(self: *SubtreeCache, root: u64, ids: []u64) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.descendants.getOrPut(root);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = ids;
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

    /// Drop everything in the cache. Called from write ops in
    /// operations.zig so subsequent reads see fresh state.
    pub fn invalidateAll(self: *SubtreeCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.descendants.iterator();
        while (it.next()) |e| self.allocator.free(e.value_ptr.*);
        self.descendants.clearRetainingCapacity();
        self.link_counts.clearRetainingCapacity();
    }
};

/// Compute the inclusive descendant set of `root` via BFS over `cat_by_parent`.
/// Returns a sorted, deduplicated list of category ids that includes `root`.
/// Caller owns the returned slice (allocated by `allocator`). Cycles in the
/// underlying data are tolerated via the visited set; a depth limit isn't
/// needed because `MAX_DESCENDANTS` bounds total work.
pub fn collectDescendants(
    cat_by_parent: *btree.BPlusTree,
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
        // Order isn't observable — we sort the result at the end.
        // pop() is O(1); orderedRemove(0) was O(n) and quadratic on
        // wide trees like Top's 221k descendants.
        const cur = queue.pop().?;
        const start_key = types.ParentChildKey.encode(cur, 0);
        const end_key = types.ParentChildKey.encode(cur, std.math.maxInt(u64));
        var iter = try cat_by_parent.rangeScan(&start_key, &end_key);
        while (try iter.next()) |entry| {
            // ParentChildKey is (parent u64 BE, child u64 BE) — child is the
            // trailing 8 bytes of the 16-byte key. Decoding from the key
            // avoids depending on what cat_by_parent chose to store as value.
            if (entry.key.len < 16) return error.Corrupted;
            const child = types.decodeU64(entry.key[8..16]);
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
    /// Link ids for the requested page slice, in (cat_id, link_id) ascending order.
    link_ids: []u64,
    /// Total number of link entries across the entire subtree (independent of offset/limit).
    total: u64,
};

/// Iterate `link_by_category` over every cat in `descendants` (must be ascending).
/// Returns the link ids on the page slice plus the total count across the whole subtree.
/// Caller owns `link_ids` (allocated via `allocator`).
pub fn listSubtreeLinkIds(
    link_by_category: *btree.BPlusTree,
    descendants: []const u64,
    offset: u32,
    limit: u32,
    allocator: std.mem.Allocator,
) !SubtreeLinkPage {
    var page_ids: std.ArrayListUnmanaged(u64) = .{};
    errdefer page_ids.deinit(allocator);

    var total: u64 = 0;
    // u64 to match `total` width — defensive against u32 wrap if a caller
    // ever passes an offset near 2^32. Wire-layer validation should also
    // bound this, but mixing widths here keeps the inner loop safe.
    var skipped: u64 = 0;
    const offset_u64: u64 = offset;

    for (descendants) |cat_id| {
        const start_key = types.CategoryLinkKey.encode(cat_id, 0);
        const end_key = types.CategoryLinkKey.encode(cat_id, std.math.maxInt(u64));
        var iter = try link_by_category.rangeScan(&start_key, &end_key);
        while (try iter.next()) |entry| {
            total += 1;
            if (skipped < offset_u64) {
                skipped += 1;
                continue;
            }
            if (page_ids.items.len >= limit) continue;
            // CategoryLinkKey is (cat u64 BE, link u64 BE) — link is the
            // trailing 8 bytes of the 16-byte key. Decoding from the key
            // avoids depending on what link_by_category chose to store as value.
            if (entry.key.len < 16) return error.Corrupted;
            const link_id = types.decodeU64(entry.key[8..16]);
            try page_ids.append(allocator, link_id);
        }
    }

    return SubtreeLinkPage{
        .link_ids = try page_ids.toOwnedSlice(allocator),
        .total = total,
    };
}

/// Cached version of `collectDescendants`. Returns a slice owned by the
/// cache (do NOT free). On miss, computes and stores. Thread-safe via the
/// cache's RwLock.
pub fn collectDescendantsCached(
    cat_by_parent: *btree.BPlusTree,
    root: u64,
    cache: *SubtreeCache,
    allocator: std.mem.Allocator,
) ![]const u64 {
    if (cache.getDescendants(root)) |hit| return hit;
    const fresh = try collectDescendants(cat_by_parent, root, allocator);
    try cache.putDescendants(root, fresh);
    return fresh;
}

/// Walk link_by_category sequentially from key=0, checking each entry's
/// cat_id against the descendant set. Replaces the N-rangescans pattern
/// when the subtree is large — each rangescan setup is ~20 page reads,
/// so 100k rangescans dominate; one walk + O(1) HashMap lookup is far
/// cheaper.
///
/// Returns (page_slice, total). Page slice is allocator-owned; caller frees.
pub fn listSubtreeLinkIdsScan(
    link_by_category: *btree.BPlusTree,
    descendants: []const u64,
    offset: u32,
    limit: u32,
    allocator: std.mem.Allocator,
) !SubtreeLinkPage {
    // Build a hash set of descendant ids for O(1) membership test.
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
        const cat_id = std.mem.readInt(u64, entry.key[0..8], .big);
        if (!desc_set.contains(cat_id)) continue;

        total += 1;
        if (skipped < offset_u64) {
            skipped += 1;
            continue;
        }
        if (page_ids.items.len >= limit) continue;
        const link_id = std.mem.readInt(u64, entry.key[8..16], .big);
        try page_ids.append(allocator, link_id);
    }

    return SubtreeLinkPage{
        .link_ids = try page_ids.toOwnedSlice(allocator),
        .total = total,
    };
}

/// Count subtree links for `descendants` via a single sequential scan.
/// Returns the total. Useful when only the count is needed (e.g. browse_path).
pub fn countSubtreeLinks(
    link_by_category: *btree.BPlusTree,
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
        const cat_id = std.mem.readInt(u64, entry.key[0..8], .big);
        if (desc_set.contains(cat_id)) total += 1;
    }
    return total;
}

test "collectDescendants returns inclusive sorted set on a tiny synthetic tree" {
    // Minimal cat_by_parent fixture without going through Database.
    // Tree:
    //   1
    //   ├── 2
    //   │   ├── 4
    //   │   └── 5
    //   └── 3
    const path = "/tmp/test_subtree_basic.db";
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 64);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, page.INVALID_PAGE);
    var cat_by_parent = btree.BPlusTree.init(&cache, &fl, page.INVALID_PAGE);

    // Insert (parent, child) → child for every edge.
    const edges = [_][2]u64{ .{ 1, 2 }, .{ 1, 3 }, .{ 2, 4 }, .{ 2, 5 } };
    inline for (edges) |edge| {
        const k = types.ParentChildKey.encode(edge[0], edge[1]);
        const v = types.encodeU64(edge[1]);
        try cat_by_parent.insert(&k, &v);
    }

    const result = try collectDescendants(&cat_by_parent, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);

    // Inclusive of root, sorted.
    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 4, 5 }, result);
}

test "collectDescendants tolerates cycles via the visited set" {
    const path = "/tmp/test_subtree_cycle.db";
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 64);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, page.INVALID_PAGE);
    var cat_by_parent = btree.BPlusTree.init(&cache, &fl, page.INVALID_PAGE);

    // Edges: self-loop + back-edge to root + ordinary descendant.
    //   1 -> 1   (self-loop)
    //   1 -> 2
    //   2 -> 1   (back-edge to root, which IS visited but already popped)
    //   2 -> 3
    // Without the visited set, this would loop forever between 1 and 2.
    const edges = [_][2]u64{ .{ 1, 1 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 3 } };
    inline for (edges) |edge| {
        const k = types.ParentChildKey.encode(edge[0], edge[1]);
        const v = types.encodeU64(edge[1]);
        try cat_by_parent.insert(&k, &v);
    }

    const result = try collectDescendants(&cat_by_parent, 1, std.testing.allocator);
    defer std.testing.allocator.free(result);

    // Inclusive of root, deduped, sorted.
    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3 }, result);
}

test "listSubtreeLinkIds: total counts everything; page slice is bounded" {
    const path = "/tmp/test_subtree_links.db";
    const file = try std.fs.cwd().createFile(path, .{ .read = true, .truncate = true });
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 64);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, page.INVALID_PAGE);

    // Build link_by_category with 30 links across 3 cats: cat 1 has 10, cat 2 has 10, cat 3 has 10.
    var link_by_category = btree.BPlusTree.init(&cache, &fl, page.INVALID_PAGE);
    var cid: u64 = 1;
    while (cid <= 3) : (cid += 1) {
        var lid: u64 = 1;
        while (lid <= 10) : (lid += 1) {
            const link_id = cid * 100 + lid;
            const k = types.CategoryLinkKey.encode(cid, link_id);
            const v = types.encodeU64(link_id);
            try link_by_category.insert(&k, &v);
        }
    }

    var ids = [_]u64{ 1, 2, 3 };
    const r1 = try listSubtreeLinkIds(
        &link_by_category,
        ids[0..],
        0,
        15,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(r1.link_ids);
    try std.testing.expectEqual(@as(u64, 30), r1.total);
    try std.testing.expectEqual(@as(usize, 15), r1.link_ids.len);
    try std.testing.expectEqual(@as(u64, 101), r1.link_ids[0]);

    // Page 2 (offset 15) returns the rest.
    const r2 = try listSubtreeLinkIds(
        &link_by_category,
        ids[0..],
        15,
        15,
        std.testing.allocator,
    );
    defer std.testing.allocator.free(r2.link_ids);
    try std.testing.expectEqual(@as(u64, 30), r2.total);
    try std.testing.expectEqual(@as(usize, 15), r2.link_ids.len);
    // No overlap with page 1 — first id on page 2 is the 16th overall (cat 2's 6th link = 206).
    try std.testing.expectEqual(@as(u64, 206), r2.link_ids[0]);
}
