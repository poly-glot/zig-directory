//! Misc small methods for BPlusTree: init, getRootPage, truncate, rangeScan,
//! getMutablePage. Aliased back into the BPlusTree struct in btree.zig so
//! callers can keep using `tree.init(...)`, `tree.rangeScan(...)`, etc.

const std = @import("std");
const page = @import("../page.zig");
const page_cache = @import("../page_cache.zig");
const freelist = @import("../freelist.zig");
const btree = @import("btree.zig");

const PageId = page.PageId;
const Page = page.Page;
const SlotEntry = page.SlotEntry;
const INVALID_PAGE = page.INVALID_PAGE;

const BPlusTree = btree.BPlusTree;
const RangeScanIterator = btree.RangeScanIterator;
const compareKeys = btree.compareKeys;
const slotsFromConstPage = btree.slotsFromConstPage;
const isInternal = btree.isInternal;

pub fn init(cache: *page_cache.PageCache, fl: *freelist.FreeList, root_page: PageId) BPlusTree {
    return BPlusTree{
        .cache = cache,
        .free_list = fl,
        .root_page = root_page,
        .lock = .{},
    };
}

pub fn getRootPage(self: *const BPlusTree) PageId {
    return self.root_page;
}

/// Truncate the tree to empty. Frees every page reachable from the
/// current root back to the freelist, then allocates a fresh empty
/// root leaf. Resets `entry_count` and the cached rightmost path.
///
/// Used by the schema migration to drop a derived secondary index
/// (e.g. `cat_by_parent`) before rebuilding it deterministically
/// from the authoritative `categories_by_id` tree.
pub fn truncate(self: *BPlusTree, allocator: std.mem.Allocator) !void {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.root_page != INVALID_PAGE) {
        try freeSubtree(self, allocator, self.root_page);
    }

    const new_root_id = try self.free_list.allocPage();
    const new_root = try self.cache.getPageMut(new_root_id);
    page.initLeaf(new_root, new_root_id);
    self.cache.unpinPage(new_root_id);

    self.root_page = new_root_id;
    self.entry_count = 0;
    self.cached_rightmost_leaf = INVALID_PAGE;
    self.cached_rightmost_path = .{};
}

/// Recursively free `page_id` and every descendant page back to the
/// freelist. For internal nodes, the children are collected from the
/// slot values (4-byte LE PageId) plus `right_sibling` (rightmost
/// child) before the parent itself is unpinned and freed.
pub fn freeSubtree(self: *BPlusTree, allocator: std.mem.Allocator, page_id: PageId) !void {
    if (page_id == INVALID_PAGE) return;

    const pg = try self.cache.getPage(page_id);
    const internal = isInternal(pg);

    var children: std.ArrayList(PageId) = .{};
    defer children.deinit(allocator);

    if (internal) {
        const count = pg.header.key_count;
        const slots = slotsFromConstPage(pg);
        try children.ensureTotalCapacity(allocator, count + 1);
        for (0..count) |i| {
            const v = page.getValueAt(pg, slots[i]);
            children.appendAssumeCapacity(btree.readPageId(v));
        }
        children.appendAssumeCapacity(pg.header.right_sibling);
    }
    self.cache.unpinPage(page_id);

    if (internal) {
        for (children.items) |c| try freeSubtree(self, allocator, c);
    }
    try self.free_list.freePage(page_id);
}

/// Create an iterator for keys in [start_key, end_key).
/// If end_key is null, iterates to the end of the tree.
pub fn rangeScan(self: *BPlusTree, start_key: []const u8, end_key: ?[]const u8) !RangeScanIterator {
    self.lock.lockShared();
    defer self.lock.unlockShared();

    if (self.root_page == INVALID_PAGE) {
        return RangeScanIterator{
            .cache = self.cache,
            .current_page = INVALID_PAGE,
            .current_slot = 0,
            .end_key = end_key,
        };
    }

    const leaf_id = try self.findLeaf(start_key);
    const pg = try self.cache.getPage(leaf_id);

    // Find first slot whose key >= start_key
    var start_slot: u32 = pg.header.key_count; // past-end by default
    const count = pg.header.key_count;
    const slots = slotsFromConstPage(pg);
    for (0..count) |i| {
        const slot = slots[i];
        const k = page.getKeyAt(pg, slot);
        if (compareKeys(k, start_key) != .lt) {
            start_slot = @intCast(i);
            break;
        }
    }

    self.cache.unpinPage(leaf_id);

    return RangeScanIterator{
        .cache = self.cache,
        .current_page = leaf_id,
        .current_slot = start_slot,
        .end_key = end_key,
    };
}

/// Get a mutable Page pointer from the cache.
pub fn getMutablePage(self: *BPlusTree, pid: PageId) !*Page {
    return self.cache.getPageMut(pid);
}
