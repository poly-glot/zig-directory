//! Insert path: insert, insertIntoLeaf, splitLeaf, insertIntoParent,
//! splitInternal, plus the rightmost fast-path helpers.

const std = @import("std");
const page = @import("../page.zig");
const btree = @import("btree.zig");

const PageId = page.PageId;
const Page = page.Page;
const SlotEntry = page.SlotEntry;
const INVALID_PAGE = page.INVALID_PAGE;

const BPlusTree = btree.BPlusTree;
const PathStack = btree.PathStack;
const BTreeError = btree.BTreeError;
const MAX_ENTRIES_PER_PAGE = btree.MAX_ENTRIES_PER_PAGE;
const SPLIT_BUF_SIZE = btree.SPLIT_BUF_SIZE;
const Range = btree.Range;
const compareKeys = btree.compareKeys;
const slotsFromConstPage = btree.slotsFromConstPage;
const slotsFromPage = btree.slotsFromPage;
const isLeaf = btree.isLeaf;

/// Insert or update a key-value pair.
pub fn insert(self: *BPlusTree, key: []const u8, value: []const u8) !void {
    self.lock.lock();
    defer self.lock.unlock();

    // Fast path: if the key goes to the rightmost leaf, skip traversal.
    // This branch only fires when the key is strictly greater than
    // every existing key in the cached rightmost leaf, so a `true`
    // return is always a new-key insert.
    if (try tryRightmostInsert(self, key, value)) {
        self.entry_count += 1;
        return;
    }

    if (self.root_page == INVALID_PAGE) {
        // Create the very first leaf as root
        const new_id = try self.free_list.allocPage();
        const pg = try self.getMutablePage(new_id);
        page.initLeaf(pg, new_id);
        try page.insertEntry(pg, key, value, 0);
        self.cache.unpinPage(new_id);
        self.root_page = new_id;
        // First leaf is also the rightmost.
        self.cached_rightmost_leaf = new_id;
        self.cached_rightmost_path = .{};
        self.entry_count += 1;
        return;
    }

    var result = try self.findLeafWithPath(key);

    // Check for existing key — update in place
    {
        const leaf_id = result.leaf;
        const pg = try self.getMutablePage(leaf_id);
        const count = pg.header.key_count;
        const slots = slotsFromPage(pg);

        for (0..count) |i| {
            const slot = slots[i];
            const k = page.getKeyAt(pg, slot);
            if (compareKeys(k, key) == .eq) {
                page.removeEntry(pg, @intCast(i));
                const pos = self.findInsertPos(pg, key);
                page.insertEntry(pg, key, value, pos) catch {
                    self.cache.unpinPage(leaf_id);
                    // Overwrite path — entry was already removed
                    // above and is being re-inserted. Do NOT bump
                    // entry_count.
                    try compactAndInsert(self, leaf_id, key, value, &result.path);
                    return;
                };
                self.cache.unpinPage(leaf_id);
                // Overwrite path — count unchanged.
                return;
            }
        }
        self.cache.unpinPage(leaf_id);
    }

    // Key not found — insert new entry
    try insertIntoLeaf(self, result.leaf, key, value, &result.path);
    self.entry_count += 1;
}

/// Try to insert into the cached rightmost leaf. Returns true if
/// the insert succeeded (key >= all existing keys and leaf had room).
/// Returns false to fall through to the normal insert path.
/// Caller must hold self.lock exclusively.
fn tryRightmostInsert(self: *BPlusTree, key: []const u8, value: []const u8) !bool {
    if (self.cached_rightmost_leaf == INVALID_PAGE) return false;

    const leaf_id = self.cached_rightmost_leaf;
    const pg = try self.getMutablePage(leaf_id);

    // Verify it's still a leaf and our key belongs at the rightmost position.
    if (!isLeaf(pg)) {
        self.cache.unpinPage(leaf_id);
        invalidateRightmostCache(self);
        return false;
    }

    const count = pg.header.key_count;
    if (count > 0) {
        const slots = slotsFromConstPage(pg);
        const max_key = page.getKeyAt(pg, slots[count - 1]);
        // Must be strictly greater for append-only (sequential key) path.
        // Equal keys go through normal path for update-in-place logic.
        if (compareKeys(key, max_key) != .gt) {
            self.cache.unpinPage(leaf_id);
            return false;
        }
    }

    // Key goes at the end of this leaf. Try to insert.
    page.insertEntry(pg, key, value, count) catch {
        // Leaf full — need split. Use cached path if available.
        self.cache.unpinPage(leaf_id);
        if (self.cached_rightmost_path.len > 0) {
            var path_copy = self.cached_rightmost_path;
            try splitLeaf(self, leaf_id, key, value, &path_copy);
            return true;
        }
        return false; // fall through to normal path
    };

    self.cache.unpinPage(leaf_id);
    return true;
}

fn invalidateRightmostCache(self: *BPlusTree) void {
    self.cached_rightmost_leaf = INVALID_PAGE;
    self.cached_rightmost_path = .{};
}

/// Update the cached rightmost leaf after a split produces a new right page.
fn updateRightmostCache(self: *BPlusTree, new_right_leaf: PageId, path: *const PathStack) void {
    self.cached_rightmost_leaf = new_right_leaf;
    self.cached_rightmost_path = path.*;
}

/// Insert a key-value into a leaf, splitting if the page is full.
fn insertIntoLeaf(self: *BPlusTree, leaf_id: PageId, key: []const u8, value: []const u8, path: *PathStack) !void {
    const pg = try self.getMutablePage(leaf_id);

    const pos = self.findInsertPos(pg, key);

    page.insertEntry(pg, key, value, pos) catch {
        self.cache.unpinPage(leaf_id);
        try splitLeaf(self, leaf_id, key, value, path);
        return;
    };

    self.cache.unpinPage(leaf_id);
}

/// Split a full leaf and redistribute entries.
fn splitLeaf(self: *BPlusTree, leaf_id: PageId, key: []const u8, value: []const u8, path: *PathStack) !void {
    const pg = try self.getMutablePage(leaf_id);
    errdefer self.cache.unpinPage(leaf_id);

    const count = pg.header.key_count;
    const slots = slotsFromConstPage(pg);

    // Copy all existing entries to temporary buffers (we must own the data
    // before reinitializing the page, since pointers into pg.body will be
    // invalidated).
    const total: usize = @as(usize, count) + 1;
    // Flat buffer for all key/value bytes — 2x page size to handle large
    // values (e.g. Category at 1592 bytes with only 2 entries per page,
    // plus the new entry being inserted).
    const allocator = self.cache.allocator;
    const data_buf = try allocator.alloc(u8, SPLIT_BUF_SIZE);
    defer allocator.free(data_buf);
    const key_ranges = try allocator.alloc(Range, MAX_ENTRIES_PER_PAGE);
    defer allocator.free(key_ranges);
    const val_ranges = try allocator.alloc(Range, MAX_ENTRIES_PER_PAGE);
    defer allocator.free(val_ranges);
    var data_off: usize = 0;

    // Find insert position
    var insert_pos: usize = count;
    for (0..count) |i| {
        const slot = slots[i];
        const k = page.getKeyAt(pg, slot);
        if (compareKeys(key, k) == .lt) {
            insert_pos = i;
            break;
        }
    }

    // Build merged list, copying bytes into data_buf
    for (0..total) |i| {
        if (i == insert_pos) {
            @memcpy(data_buf[data_off..][0..key.len], key);
            key_ranges[i] = .{ .off = data_off, .len = @intCast(key.len) };
            data_off += key.len;
            @memcpy(data_buf[data_off..][0..value.len], value);
            val_ranges[i] = .{ .off = data_off, .len = @intCast(value.len) };
            data_off += value.len;
        } else {
            const src: usize = if (i < insert_pos) i else i - 1;
            const slot = slots[src];
            const k = page.getKeyAt(pg, slot);
            const v = page.getValueAt(pg, slot);
            @memcpy(data_buf[data_off..][0..k.len], k);
            key_ranges[i] = .{ .off = data_off, .len = @intCast(k.len) };
            data_off += k.len;
            @memcpy(data_buf[data_off..][0..v.len], v);
            val_ranges[i] = .{ .off = data_off, .len = @intCast(v.len) };
            data_off += v.len;
        }
    }

    // Pick the split point by BYTES, not by entry count. Variable-length
    // keys (e.g. slug paths) can produce wildly unbalanced halves where a
    // count-based split overflows one side — discovered when the v3 phase-9
    // migration's sorted-insert loop hit NotEnoughSpace from a 50/50 count
    // split that put 7 KB of long-suffix slug paths in the right half.
    //
    // Strategy: walk entries left-to-right summing per-entry cost
    // (slot + key + value); the split point is the first index where the
    // left-side cumulative cost crosses BODY_SIZE / 2.
    const SLOT_COST: usize = @sizeOf(SlotEntry);
    var total_bytes: usize = 0;
    for (0..total) |i| {
        total_bytes += SLOT_COST + key_ranges[i].len + val_ranges[i].len;
    }
    var mid: usize = total / 2;
    var left_bytes: usize = 0;
    for (0..total) |i| {
        const cost = SLOT_COST + key_ranges[i].len + val_ranges[i].len;
        if (left_bytes + cost > total_bytes / 2 and i > 0) {
            mid = i;
            break;
        }
        left_bytes += cost;
    }
    // Guard against pathological cases: if either side would still
    // overflow BODY_SIZE, we have an entry that's individually too big
    // to fit even alone — surface that as Corrupted (caller's bug).
    var left_check: usize = 0;
    for (0..mid) |i| left_check += SLOT_COST + key_ranges[i].len + val_ranges[i].len;
    var right_check: usize = 0;
    for (mid..total) |i| right_check += SLOT_COST + key_ranges[i].len + val_ranges[i].len;
    if (left_check > page.BODY_SIZE or right_check > page.BODY_SIZE) {
        std.debug.print(
            "btree: splitLeaf cannot find a valid split: total={d} mid={d} left_bytes={d} right_bytes={d} BODY_SIZE={d}\n",
            .{ total, mid, left_check, right_check, page.BODY_SIZE },
        );
        self.cache.unpinPage(leaf_id);
        return BTreeError.Corrupted;
    }

    const old_right_sibling = pg.header.right_sibling;

    // Allocate new right leaf
    const right_id = try self.free_list.allocPage();
    if (right_id == leaf_id) {
        std.debug.print("btree.splitLeaf ALIAS: free_list.allocPage returned the same page being split! leaf_id={d} right_id={d}\n", .{ leaf_id, right_id });
        return BTreeError.Corrupted;
    }
    const right_pg = try self.getMutablePage(right_id);
    if (@intFromPtr(right_pg) == @intFromPtr(pg)) {
        std.debug.print("btree.splitLeaf POINTER ALIAS: getMutablePage returned same pointer for different ids leaf_id={d} right_id={d}\n", .{ leaf_id, right_id });
        return BTreeError.Corrupted;
    }
    page.initLeaf(right_pg, right_id);

    // Re-initialize left leaf
    page.initLeaf(pg, leaf_id);
    pg.header.right_sibling = right_id;

    // Left gets [0, mid)
    for (0..mid) |i| {
        const k = data_buf[key_ranges[i].off..][0..key_ranges[i].len];
        const v = data_buf[val_ranges[i].off..][0..val_ranges[i].len];
        page.insertEntry(pg, k, v, @intCast(i)) catch |err| {
            std.debug.print("btree.splitLeaf LEFT fail: i={d} mid={d} total={d} key.len={d} val.len={d} freeSpace={d} left_check={d} right_check={d}\n", .{
                i, mid, total, k.len, v.len, page.freeSpace(pg), left_check, right_check,
            });
            return err;
        };
    }

    // Right gets [mid, total)
    for (mid..total) |i| {
        const k = data_buf[key_ranges[i].off..][0..key_ranges[i].len];
        const v = data_buf[val_ranges[i].off..][0..val_ranges[i].len];
        page.insertEntry(right_pg, k, v, @intCast(i - mid)) catch |err| {
            std.debug.print("btree.splitLeaf RIGHT fail: i={d} mid={d} total={d} key.len={d} val.len={d} freeSpace={d} key_count={d} body_size={d}\n", .{
                i, mid, total, k.len, v.len, page.freeSpace(right_pg), right_pg.header.key_count, page.BODY_SIZE,
            });
            // Show what we THINK the right side should hold vs actual.
            std.debug.print("  expected right total={d}, but used={d}\n", .{ right_check, page.BODY_SIZE - page.freeSpace(right_pg) });
            // Sample a few right-side entries' key_ranges
            const sample_end = @min(mid + 5, total);
            for (mid..sample_end) |j| {
                std.debug.print("  right[{d}]: key.len={d} val.len={d} (range_off={d})\n", .{ j - mid, key_ranges[j].len, val_ranges[j].len, key_ranges[j].off });
            }
            std.debug.print("  ...\n  right[{d}] (last): key.len={d} val.len={d}\n", .{ total - 1 - mid, key_ranges[total - 1].len, val_ranges[total - 1].len });
            return err;
        };
    }

    right_pg.header.right_sibling = old_right_sibling;

    // First key of right page is the median that goes up to the parent
    const median_right_slots = slotsFromConstPage(right_pg);
    const median_key = page.getKeyAt(right_pg, median_right_slots[0]);

    // Copy median key to a local buffer before unpinning
    var median_buf: [256]u8 = undefined;
    if (median_key.len > median_buf.len) return BTreeError.Corrupted;
    const median_len = median_key.len;
    @memcpy(median_buf[0..median_len], median_key);

    self.cache.unpinPage(leaf_id);
    self.cache.unpinPage(right_id);

    // If the new right leaf is the new rightmost (no right sibling),
    // update the cache so subsequent sequential inserts skip traversal.
    if (old_right_sibling == INVALID_PAGE) {
        updateRightmostCache(self, right_id, path);
    }

    try insertIntoParent(self, median_buf[0..median_len], leaf_id, right_id, path);
}

/// Insert a separator key into the parent, creating a new root if needed.
/// Uses the path stack to find the parent in O(1) instead of a full tree scan.
fn insertIntoParent(self: *BPlusTree, key: []const u8, left_pid: PageId, right_pid: PageId, path: *PathStack) BTreeError!void {
    const parent_id = path.pop() orelse {
        // left_pid is the root — create a new root
        const new_root_id = try self.free_list.allocPage();
        const new_root = try self.getMutablePage(new_root_id);
        errdefer self.cache.unpinPage(new_root_id);
        page.initInternal(new_root, new_root_id);

        var pid_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &pid_buf, left_pid, .little);
        try page.insertEntry(new_root, key, &pid_buf, 0);
        new_root.header.right_sibling = right_pid;

        self.cache.unpinPage(new_root_id);
        self.root_page = new_root_id;
        // Root changed — rebuild the cached rightmost path.
        // The rightmost leaf is still valid; add the new root to its path.
        if (self.cached_rightmost_leaf != INVALID_PAGE) {
            var new_path = PathStack{};
            new_path.push(new_root_id);
            for (0..self.cached_rightmost_path.len) |i| {
                new_path.push(self.cached_rightmost_path.items[i]);
            }
            self.cached_rightmost_path = new_path;
        }
        return;
    };

    // Insert into existing parent
    const parent = try self.getMutablePage(parent_id);
    const pos = self.findInsertPos(parent, key);

    var pid_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &pid_buf, left_pid, .little);

    page.insertEntry(parent, key, &pid_buf, pos) catch {
        self.cache.unpinPage(parent_id);
        try splitInternal(self, parent_id, key, left_pid, right_pid, path);
        return;
    };

    // Fix up the child pointer that follows the newly inserted key
    const parent_slots = slotsFromPage(parent);
    if (pos + 1 < parent.header.key_count) {
        const next_slot = parent_slots[pos + 1];
        std.mem.writeInt(u32, parent.body[next_slot.value_offset..][0..4], right_pid, .little);
    } else {
        parent.header.right_sibling = right_pid;
    }

    self.cache.unpinPage(parent_id);
}

/// Split a full internal node and push the median key up.
fn splitInternal(self: *BPlusTree, node_id: PageId, new_key: []const u8, new_left: PageId, new_right: PageId, path: *PathStack) BTreeError!void {
    const pg = try self.getMutablePage(node_id);
    errdefer self.cache.unpinPage(node_id);

    const count = pg.header.key_count;
    const slots = slotsFromConstPage(pg);

    // Copy key data into a flat buffer to avoid aliasing with page body.
    // Use 2x page size for consistency with splitLeaf.
    const allocator = self.cache.allocator;
    const data_buf = try allocator.alloc(u8, SPLIT_BUF_SIZE);
    defer allocator.free(data_buf);
    const key_ranges = try allocator.alloc(Range, MAX_ENTRIES_PER_PAGE);
    defer allocator.free(key_ranges);
    const child_ptrs = try allocator.alloc(PageId, MAX_ENTRIES_PER_PAGE);
    defer allocator.free(child_ptrs);
    var data_off: usize = 0;
    var rightmost_child: PageId = pg.header.right_sibling;

    // Find insert position for new_key
    var insert_pos: usize = count;
    for (0..count) |i| {
        const slot = slots[i];
        const k = page.getKeyAt(pg, slot);
        if (compareKeys(new_key, k) == .lt) {
            insert_pos = i;
            break;
        }
    }

    // Build merged key+child list, copying key bytes into data_buf
    const total: usize = @as(usize, count) + 1;
    for (0..total) |i| {
        if (i == insert_pos) {
            @memcpy(data_buf[data_off..][0..new_key.len], new_key);
            key_ranges[i] = .{ .off = data_off, .len = @intCast(new_key.len) };
            data_off += new_key.len;
            child_ptrs[i] = new_left;
        } else {
            const src: usize = if (i < insert_pos) i else i - 1;
            const slot = slots[src];
            const k = page.getKeyAt(pg, slot);
            const v = page.getValueAt(pg, slot);
            @memcpy(data_buf[data_off..][0..k.len], k);
            key_ranges[i] = .{ .off = data_off, .len = @intCast(k.len) };
            data_off += k.len;
            child_ptrs[i] = btree.readPageId(v);
        }
    }

    // The child after the newly inserted key should be new_right
    if (insert_pos + 1 < total) {
        child_ptrs[insert_pos + 1] = new_right;
    } else {
        rightmost_child = new_right;
    }

    // Pick mid by BYTES, not entry count — same reason as splitLeaf:
    // variable-length keys can produce unbalanced halves where one side
    // overflows BODY_SIZE if we naively take total/2.
    // Internal-node entries cost: SLOT + key + 4 bytes (child PageId).
    const SLOT_COST_INT: usize = @sizeOf(SlotEntry);
    const VAL_COST_INT: usize = 4;
    var total_bytes: usize = 0;
    for (0..total) |i| {
        total_bytes += SLOT_COST_INT + key_ranges[i].len + VAL_COST_INT;
    }
    var mid: usize = total / 2;
    var left_bytes: usize = 0;
    for (0..total) |i| {
        const cost = SLOT_COST_INT + key_ranges[i].len + VAL_COST_INT;
        if (left_bytes + cost > total_bytes / 2 and i > 0) {
            mid = i;
            break;
        }
        left_bytes += cost;
    }
    // mid must leave at least one entry in each half; clamp.
    if (mid == 0) mid = 1;
    if (mid >= total) mid = total - 1;

    // Save median key
    var median_buf: [256]u8 = undefined;
    const median_len = key_ranges[mid].len;
    if (median_len > median_buf.len) return BTreeError.Corrupted;
    @memcpy(median_buf[0..median_len], data_buf[key_ranges[mid].off..][0..median_len]);

    // Allocate new right internal node
    const right_id = try self.free_list.allocPage();
    const right_pg = try self.getMutablePage(right_id);
    page.initInternal(right_pg, right_id);

    // Re-initialize left node
    page.initInternal(pg, node_id);

    // Left node gets [0, mid)
    for (0..mid) |i| {
        const k = data_buf[key_ranges[i].off..][0..key_ranges[i].len];
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, child_ptrs[i], .little);
        try page.insertEntry(pg, k, &buf, @intCast(i));
    }
    pg.header.right_sibling = child_ptrs[mid];

    // Right node gets [mid+1, total)
    for (mid + 1..total) |i| {
        const k = data_buf[key_ranges[i].off..][0..key_ranges[i].len];
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, child_ptrs[i], .little);
        try page.insertEntry(right_pg, k, &buf, @intCast(i - mid - 1));
    }
    right_pg.header.right_sibling = rightmost_child;

    self.cache.unpinPage(node_id);
    self.cache.unpinPage(right_id);

    // Internal node split invalidates the cached path (ancestor IDs changed).
    invalidateRightmostCache(self);

    // Push median up to parent
    try insertIntoParent(self, median_buf[0..median_len], node_id, right_id, path);
}

/// Compact a leaf (rebuild it in place) then insert.
/// Uses a flat data buffer (same approach as splitLeaf) so it handles
/// arbitrarily large values (e.g. a 1592-byte Category struct).
fn compactAndInsert(self: *BPlusTree, leaf_id: PageId, key: []const u8, value: []const u8, path: *PathStack) !void {
    const pg = try self.getMutablePage(leaf_id);

    const count = pg.header.key_count;
    const slots = slotsFromConstPage(pg);

    const allocator = self.cache.allocator;
    const data_buf = try allocator.alloc(u8, SPLIT_BUF_SIZE);
    defer allocator.free(data_buf);
    const key_ranges = try allocator.alloc(Range, MAX_ENTRIES_PER_PAGE);
    defer allocator.free(key_ranges);
    const val_ranges = try allocator.alloc(Range, MAX_ENTRIES_PER_PAGE);
    defer allocator.free(val_ranges);
    var data_off: usize = 0;

    for (0..count) |i| {
        const slot = slots[i];
        const k = page.getKeyAt(pg, slot);
        const v = page.getValueAt(pg, slot);
        @memcpy(data_buf[data_off..][0..k.len], k);
        key_ranges[i] = .{ .off = data_off, .len = slot.key_len };
        data_off += k.len;
        @memcpy(data_buf[data_off..][0..v.len], v);
        val_ranges[i] = .{ .off = data_off, .len = slot.value_len };
        data_off += v.len;
    }

    const old_sibling = pg.header.right_sibling;
    page.initLeaf(pg, leaf_id);
    pg.header.right_sibling = old_sibling;

    for (0..count) |i| {
        const k = data_buf[key_ranges[i].off..][0..key_ranges[i].len];
        const v = data_buf[val_ranges[i].off..][0..val_ranges[i].len];
        try page.insertEntry(pg, k, v, @intCast(i));
    }

    const pos = self.findInsertPos(pg, key);
    page.insertEntry(pg, key, value, pos) catch {
        self.cache.unpinPage(leaf_id);
        try splitLeaf(self, leaf_id, key, value, path);
        return;
    };

    self.cache.unpinPage(leaf_id);
}

const page_cache = @import("../page_cache.zig");
const freelist = @import("../freelist.zig");

fn createTempFile(name: []const u8) !std.fs.File {
    return std.fs.cwd().createFile(name, .{
        .read = true,
        .truncate = true,
    });
}

test "sequential inserts cause splits" {
    const path = "/tmp/test_btree_splits.db";
    const file = try createTempFile(path);
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 64);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, INVALID_PAGE);

    var tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);

    // Insert enough entries to force multiple leaf splits
    var buf: [32]u8 = undefined;
    const count: usize = 200;
    for (0..count) |i| {
        const key_slice = std.fmt.bufPrint(&buf, "key_{d:0>6}", .{i}) catch unreachable;
        try tree.insert(key_slice, "value");
    }

    // Verify all keys are found
    var sb: [page.PAGE_SIZE]u8 = undefined;
    for (0..count) |i| {
        const key_slice = std.fmt.bufPrint(&buf, "key_{d:0>6}", .{i}) catch unreachable;
        const v = try tree.search(key_slice, &sb);
        try std.testing.expect(v != null);
        try std.testing.expectEqualSlices(u8, "value", v.?);
    }
}

test "stress: phase-9 shape — iter one tree while inserting into another (shared cache)" {
    // Closer reproducer of phase 9 v2→v3 migration: walk every entry of an
    // existing tree (categories_by_id) and, per row, build a variable-length
    // slug-path key and insert it into a freshly-rooted second tree
    // (categories_by_slug_path). Both trees share the same page cache.
    //
    // On the live 13 GB DB this stalls at ~100 k inserts because of B+Tree
    // page corruption that segfaults in compareKeys. We try to repro that
    // corruption synthetically here.
    const path = "/tmp/test_btree_stress_phase9.db";
    const file = try createTempFile(path);
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 1024);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, INVALID_PAGE);

    var existing_tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);
    var slug_tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);

    const N: u32 = 150_000;

    // Phase A: pre-populate `existing_tree` with 8-byte u64 keys (mimics
    // categories_by_id keyed by cat_id).
    {
        var key_buf: [8]u8 = undefined;
        var val_buf: [16]u8 = undefined;
        for (&val_buf) |*b| b.* = 'x';
        var i: u32 = 0;
        while (i < N) : (i += 1) {
            std.mem.writeInt(u64, &key_buf, i + 1, .big);
            try existing_tree.insert(&key_buf, &val_buf);
        }
    }

    // Phase B: iterate `existing_tree` and, per row, insert a variable-length
    // slug-path key into `slug_tree`.
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = prng.random();
    var key_buf: [256]u8 = undefined;
    var val_buf: [8]u8 = undefined;

    const min_key = std.mem.toBytes(@as(u64, 0));
    var iter = try existing_tree.rangeScan(&min_key, null);
    var i: u32 = 0;
    while (try iter.next()) |entry| {
        _ = entry;
        const depth = 1 + r.intRangeLessThan(u32, 0, 4);
        var pos: usize = 0;
        @memcpy(key_buf[pos..][0..3], "top");
        pos += 3;
        var d: u32 = 0;
        while (d < depth) : (d += 1) {
            key_buf[pos] = '/';
            pos += 1;
            const seg_len = 3 + r.intRangeLessThan(u32, 0, 10);
            var s: u32 = 0;
            while (s < seg_len) : (s += 1) {
                key_buf[pos] = 'a' + @as(u8, @intCast(r.intRangeLessThan(u32, 0, 26)));
                pos += 1;
            }
        }
        const suffix = std.fmt.bufPrint(key_buf[pos..], "_{d}", .{i}) catch unreachable;
        pos += suffix.len;

        std.mem.writeInt(u64, &val_buf, i, .big);
        try slug_tree.insert(key_buf[0..pos], &val_buf);
        i += 1;
    }

    try std.testing.expect(slug_tree.entry_count == N);
}

test "stress: 150k inserts of variable-length slug-path-shaped keys" {
    // Reproducer for the phase-9 corruption observed on the 13 GB live DB.
    // Phase 9 inserts variable-length slug paths into a fresh B+Tree under a
    // 256 MB page cache. At ~100 k inserts, traversal segfaults inside
    // compareKeys because a slot's key_offset/key_len got corrupted —
    // cache pressure forces heavy eviction during the build.
    //
    // Here we recreate the same shape: cache size 64 pages (1 MB) so eviction
    // kicks in early; keys 5-50 bytes with shared prefixes mimicking
    // top/cat/sub/leaf paths; 150 k inserts in pseudo-random order; periodic
    // search probes to detect lost entries.
    const path = "/tmp/test_btree_stress_slug.db";
    const file = try createTempFile(path);
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    // 1024 pages × 16 KB = 16 MB cache. Smaller than live (256 MB) but enough
    // to absorb the working set without false CacheFull. The bug we hunt is
    // logical corruption from cache eviction, not pin-exhaustion.
    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 1024);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, INVALID_PAGE);
    var tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);

    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const r = prng.random();
    const N: u32 = 150_000;

    var key_buf: [256]u8 = undefined;
    var val_buf: [8]u8 = undefined;

    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const depth = 1 + r.intRangeLessThan(u32, 0, 4);
        var pos: usize = 0;
        @memcpy(key_buf[pos..][0..3], "top");
        pos += 3;
        var d: u32 = 0;
        while (d < depth) : (d += 1) {
            key_buf[pos] = '/';
            pos += 1;
            const seg_len = 3 + r.intRangeLessThan(u32, 0, 10);
            var s: u32 = 0;
            while (s < seg_len) : (s += 1) {
                key_buf[pos] = 'a' + @as(u8, @intCast(r.intRangeLessThan(u32, 0, 26)));
                pos += 1;
            }
        }
        const suffix = std.fmt.bufPrint(key_buf[pos..], "_{d}", .{i}) catch unreachable;
        pos += suffix.len;

        std.mem.writeInt(u64, &val_buf, i, .big);
        try tree.insert(key_buf[0..pos], &val_buf);
    }

    try std.testing.expect(tree.entry_count == N);
}
