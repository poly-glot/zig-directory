//! B+Tree backed by the page cache and free list.
//!
//! Internal-node convention:
//!   slot[i].value = 4-byte LE PageId of the child to follow when search key < slot[i].key
//!   header.right_sibling = rightmost child (followed when search key >= all keys)
//!
//! Leaf nodes are linked via header.right_sibling for range scans.
//!
//! This file holds the BPlusTree struct definition + small file-level
//! types/helpers. The method bodies live in:
//!   * btree_search.zig   — search, findLeaf, findLeafWithPath, findInsertPos
//!   * btree_insert.zig   — insert (+ private split/compact helpers)
//!   * btree_delete.zig   — delete (+ private removeEmptyLeaf)
//!   * btree_repair.zig   — repairFromLeafChain
//!   * btree_helpers.zig  — init, getRootPage, truncate, rangeScan, getMutablePage, freeSubtree

const std = @import("std");
const page = @import("../page.zig");
const page_cache = @import("../page_cache.zig");
const freelist = @import("../freelist.zig");

const PageId = page.PageId;
const INVALID_PAGE = page.INVALID_PAGE;
const SlotEntry = page.SlotEntry;
const Page = page.Page;

/// Maximum tree depth supported by the path stack.
const MAX_DEPTH = 32;

/// Theoretical maximum number of slot entries that fit in a page body.
pub const MAX_ENTRIES_PER_PAGE = page.BODY_SIZE / @sizeOf(page.SlotEntry);

/// Temporary buffer size for split operations: must hold all keys+values
/// from one full page plus the new entry being inserted.
pub const SPLIT_BUF_SIZE = page.PAGE_SIZE * 2;

/// Per-entry range descriptor used during splits.
pub const Range = struct { off: usize, len: u32 };

/// Compare two byte slices lexicographically.
pub fn compareKeys(a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

/// Cast the body of a const Page to a pointer to its SlotEntry array.
pub inline fn slotsFromConstPage(pg: *const Page) [*]const SlotEntry {
    return @ptrCast(@alignCast(&pg.body));
}

/// Cast the body of a mutable Page to a pointer to its SlotEntry array.
pub inline fn slotsFromPage(pg: *Page) [*]SlotEntry {
    return @ptrCast(@alignCast(&pg.body));
}

/// Return true if the page is a leaf node.
pub inline fn isLeaf(pg: *const Page) bool {
    return pg.header.page_type == @intFromEnum(page.PageType.leaf);
}

/// Return true if the page is an internal node.
pub inline fn isInternal(pg: *const Page) bool {
    return pg.header.page_type == @intFromEnum(page.PageType.internal);
}

/// Read a PageId (4 bytes, little-endian) from a byte slice.
pub fn readPageId(data: []const u8) PageId {
    if (data.len < 4) return INVALID_PAGE;
    return std.mem.readInt(u32, data[0..4], .little);
}

/// Stack of PageIds recording the traversal path from root to leaf.
/// The path contains internal nodes only (not the leaf itself).
pub const PathStack = struct {
    items: [MAX_DEPTH]PageId = undefined,
    len: u8 = 0,

    pub fn push(self: *PathStack, pid: PageId) void {
        if (self.len < MAX_DEPTH) {
            self.items[self.len] = pid;
            self.len += 1;
        }
    }

    pub fn pop(self: *PathStack) ?PageId {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.items[self.len];
    }
};

/// Result of findLeafWithPath: the leaf page id and the traversal path.
pub const LeafWithPath = struct {
    leaf: PageId,
    path: PathStack,
};

pub const BTreeError = error{
    NotEnoughSpace,
    InvalidPosition,
    CacheFull,
    PageNotFound,
    PageLimitExhausted,
    DiskError,
    KeyNotFound,
    KeyTooLarge,
    ValueTooLarge,
    Corrupted,
    OutOfMemory,
};

/// A key-value pair returned by iterators and search.
pub const KV = struct {
    key: []const u8,
    value: []const u8,
};

/// Iterator for range scans over the B+Tree leaf chain.
///
/// Returned KV slices point into internal buffers owned by the iterator and
/// are valid until the next call to `next()`.
pub const RangeScanIterator = struct {
    cache: *page_cache.PageCache,
    current_page: PageId,
    current_slot: u32,
    end_key: ?[]const u8,

    // Owned buffers so callers don't hold dangling pointers into unpinned pages.
    key_buf: [256]u8 = undefined,
    val_buf: [page.PAGE_SIZE]u8 = undefined,
    key_len: u32 = 0,
    val_len: u32 = 0,

    /// Advance to the next matching entry, or return null when done.
    /// The returned slices are valid until the next call to `next()`.
    pub fn next(self: *RangeScanIterator) !?KV {
        // Page 0 is the file header — never a valid leaf. Treat a 0
        // sibling pointer as a chain terminator (alongside INVALID_PAGE)
        // so a corrupted right_sibling left over from earlier migrations
        // doesn't make us load + checksum-validate the header as a Page.
        while (self.current_page != INVALID_PAGE and self.current_page != 0) {
            const pg = try self.cache.getPage(self.current_page);

            if (self.current_slot >= pg.header.key_count) {
                // Move to right sibling leaf
                const sibling = pg.header.right_sibling;
                self.cache.unpinPage(self.current_page);
                self.current_page = sibling;
                self.current_slot = 0;
                continue;
            }

            const slots = slotsFromConstPage(pg);
            const slot = slots[self.current_slot];
            const key = page.getKeyAt(pg, slot);
            const value = page.getValueAt(pg, slot);

            // Check end_key bound
            if (self.end_key) |ek| {
                if (compareKeys(key, ek) != .lt) {
                    self.cache.unpinPage(self.current_page);
                    self.current_page = INVALID_PAGE;
                    return null;
                }
            }

            // Copy key/value into owned buffers BEFORE unpinning the page.
            // After unpin, the page memory may be evicted and reused.
            self.key_len = slot.key_len;
            self.val_len = slot.value_len;
            @memcpy(self.key_buf[0..self.key_len], key);
            @memcpy(self.val_buf[0..self.val_len], value);

            self.current_slot += 1;
            self.cache.unpinPage(self.current_page);

            return KV{
                .key = self.key_buf[0..self.key_len],
                .value = self.val_buf[0..self.val_len],
            };
        }
        return null;
    }
};

/// Per-tree statistics returned by `repairFromLeafChain`.
pub const RepairStats = struct {
    repaired: bool,
    leaves_walked: u64,
    new_internals_allocated: u64,
    leaf_siblings_fixed: u64,
    new_root: PageId,
};

pub const BPlusTree = struct {
    cache: *page_cache.PageCache,
    free_list: *freelist.FreeList,
    root_page: PageId,
    lock: std.Thread.RwLock,

    /// Cached rightmost leaf and its ancestor path. For monotonically
    /// increasing keys, this skips the full root-to-leaf traversal.
    /// Updated after every rightmost split. Protected by self.lock.
    cached_rightmost_leaf: PageId = INVALID_PAGE,
    cached_rightmost_path: PathStack = .{},

    /// Number of (key, value) entries in this tree. Maintained
    /// incrementally — incremented only on a new-key insert, decremented
    /// only when delete actually removes an entry. Persisted via
    /// FileHeader so the count survives restarts.
    entry_count: u64 = 0,

    // These work because Zig defers type resolution of `*BPlusTree` in
    // the imported function signatures until the function is referenced
    // via UFCS, by which time the struct is fully known.

    pub const init = @import("btree_helpers.zig").init;
    pub const getRootPage = @import("btree_helpers.zig").getRootPage;
    pub const truncate = @import("btree_helpers.zig").truncate;
    pub const rangeScan = @import("btree_helpers.zig").rangeScan;
    pub const getMutablePage = @import("btree_helpers.zig").getMutablePage;

    pub const search = @import("btree_search.zig").search;
    pub const findLeaf = @import("btree_search.zig").findLeaf;
    pub const findLeafWithPath = @import("btree_search.zig").findLeafWithPath;
    pub const findInsertPos = @import("btree_search.zig").findInsertPos;

    pub const insert = @import("btree_insert.zig").insert;

    pub const delete = @import("btree_delete.zig").delete;

    pub const repairFromLeafChain = @import("btree_repair.zig").repairFromLeafChain;
};
