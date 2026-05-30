//! Repair: repairFromLeafChain — rebuild internal-node layer over an
//! existing leaf chain when a partial header reset has stranded the
//! navigation above the leaf level.

const std = @import("std");
const page = @import("../page.zig");
const btree = @import("btree.zig");

const PageId = page.PageId;
const SlotEntry = page.SlotEntry;
const INVALID_PAGE = page.INVALID_PAGE;

const BPlusTree = btree.BPlusTree;
const PathStack = btree.PathStack;
const RepairStats = btree.RepairStats;
const slotsFromConstPage = btree.slotsFromConstPage;
const isLeaf = btree.isLeaf;

/// Rebuild the internal-node layer over an existing leaf chain.
///
/// Used when a database's data pages are intact on disk but the
/// navigation pointers above the leaf level have been lost — for
/// example, after a partial header reset that left only the
/// original empty root-leaf addressable while later inserts
/// continued to chain leaves via right_sibling. In that state
/// `search()` reaches only the original root-leaf even though
/// `rangeScan()` (which follows right_sibling) walks every leaf.
///
/// Detection: root_page is a leaf with right_sibling != INVALID.
/// Repair: walk the leaf chain, collect (first_key, leaf_pid) for
/// every non-empty leaf, then build internal layers bottom-up,
/// allocating fresh pages from the cache. Existing leaves are
/// untouched. The new root id is stored in self.root_page; the
/// caller is responsible for persisting it via flushHeader.
///
/// Idempotent: a no-op if root is already an internal node, the
/// chain has zero or one leaves, or the root has no right sibling.
/// Caller passes an allocator for temporary scratch buffers (key
/// bytes + entry list).
pub fn repairFromLeafChain(self: *BPlusTree, allocator: std.mem.Allocator) !RepairStats {
    self.lock.lock();
    defer self.lock.unlock();

    var stats = RepairStats{
        .repaired = false,
        .leaves_walked = 0,
        .new_internals_allocated = 0,
        .leaf_siblings_fixed = 0,
        .new_root = self.root_page,
    };

    if (self.root_page == INVALID_PAGE) return stats;

    // Cheap early-exit on a structurally healthy tree. The bug this
    // function fixes is "header points at a leaf that's the head of
    // a long right_sibling chain, with no internal nodes." That bug
    // requires the root to BE a leaf. If the root is an internal
    // node OR is a single leaf with no right_sibling, the tree
    // cannot be in the degenerate state and the multi-million-page
    // leaf walk that would otherwise dominate boot is unnecessary.
    //
    // Repair runs synchronously inside recover() and propagates
    // errors out, so a successful boot implies the tree is
    // consistent and the early-exit is safe.
    const root_was_leaf = blk: {
        const pg = try self.cache.getPage(self.root_page);
        const is_leaf = isLeaf(pg);
        const has_sibling = pg.header.right_sibling != INVALID_PAGE;
        self.cache.unpinPage(self.root_page);
        if (!is_leaf) return stats; // root is internal; tree has internal coverage, cannot be degenerate
        if (!has_sibling) return stats; // root is a single leaf with no chain; cannot be degenerate
        break :blk is_leaf;
    };

    // Find the leftmost leaf — descend through any existing
    // internals. findLeaf("") returns the leftmost leaf.
    const leftmost_leaf = try self.findLeaf("");

    // 1. Walk the leaf chain from the leftmost leaf. For every
    //    non-empty leaf, copy its first key into a flat buffer
    //    and record (offset, len, pid).
    const Entry = struct { key_off: u32, key_len: u16, pid: PageId };
    var keys: std.ArrayListUnmanaged(u8) = .{};
    defer keys.deinit(allocator);
    var entries: std.ArrayListUnmanaged(Entry) = .{};
    // ownership of `entries` is transferred to `current` below; do
    // not defer-deinit it here to avoid double-free.

    // Treat right_sibling pointers that fall outside the file or
    // dangle into non-leaf pages (free, internal, garbage) as the
    // end of the chain rather than a hard failure. Real-world
    // databases may carry stale siblings — we want the repair to
    // succeed against whatever leaves we can reach safely.
    const file_page_count = self.cache.page_count;

    var cur = leftmost_leaf;
    while (cur != INVALID_PAGE) {
        if (cur >= file_page_count) {
            std.log.scoped(.btree).warn(
                "repair: stopping leaf walk — sibling pid {d} >= page_count {d}",
                .{ cur, file_page_count },
            );
            break;
        }
        const pg_or = self.cache.getPage(cur);
        const pg = pg_or catch |err| {
            std.log.scoped(.btree).warn(
                "repair: stopping leaf walk — getPage({d}) failed: {}",
                .{ cur, err },
            );
            break;
        };
        if (!isLeaf(pg)) {
            // Stale sibling pointed at a non-leaf (free / internal /
            // overflow). Truncate the chain here rather than abort.
            std.log.scoped(.btree).warn(
                "repair: stopping leaf walk — page {d} is not a leaf (type={d})",
                .{ cur, pg.header.page_type },
            );
            self.cache.unpinPage(cur);
            break;
        }
        stats.leaves_walked += 1;
        if (pg.header.key_count > 0) {
            const slots = slotsFromConstPage(pg);
            const first_key = page.getKeyAt(pg, slots[0]);
            const off: u32 = @intCast(keys.items.len);
            keys.appendSlice(allocator, first_key) catch |e| {
                self.cache.unpinPage(cur);
                entries.deinit(allocator);
                return e;
            };
            entries.append(allocator, .{
                .key_off = off,
                .key_len = @intCast(first_key.len),
                .pid = cur,
            }) catch |e| {
                self.cache.unpinPage(cur);
                entries.deinit(allocator);
                return e;
            };
        }
        const sib = pg.header.right_sibling;
        self.cache.unpinPage(cur);
        cur = sib;
    }

    if (entries.items.len == 0) {
        entries.deinit(allocator);
        return stats;
    }

    // 1.5. Relink the leaf right_sibling chain so it strictly
    // matches the leaves we successfully visited. Without this,
    // rangeScan during normal operation can trip on the same
    // stale sibling that made us truncate above — we'd repair the
    // navigation only to have the leaf chain blow up on the next
    // iter.next(). Last leaf's sibling becomes INVALID_PAGE.
    var fixed_siblings: u64 = 0;
    for (entries.items, 0..) |ent, idx| {
        const next_pid: PageId = if (idx + 1 < entries.items.len)
            entries.items[idx + 1].pid
        else
            INVALID_PAGE;
        const lpg = self.cache.getPageMut(ent.pid) catch |err| {
            std.log.scoped(.btree).warn("repair: relink getPageMut({d}) failed: {}", .{ ent.pid, err });
            continue;
        };
        if (lpg.header.right_sibling != next_pid) {
            lpg.header.right_sibling = next_pid;
            fixed_siblings += 1;
        }
        self.cache.unpinPage(ent.pid);
    }
    if (fixed_siblings > 0) {
        std.log.scoped(.btree).info("repair: relinked {d} leaf siblings", .{fixed_siblings});
        stats.leaf_siblings_fixed = fixed_siblings;
        stats.repaired = true;
    }

    if (entries.items.len == 1) {
        // Single leaf — no internals needed. Root_page can stay as
        // the existing leaf id; we just trimmed its sibling above.
        entries.deinit(allocator);
        return stats;
    }

    // If the root was already an internal, the existing internal
    // layer is fine — we only needed to walk for the sibling
    // integrity pass. Skip rebuilding.
    if (!root_was_leaf) {
        entries.deinit(allocator);
        return stats;
    }

    // 2. Build internal layers bottom-up until one root remains.
    var current: std.ArrayListUnmanaged(Entry) = entries;
    // Don't double-free: explicit deinits handle current's memory.

    while (current.items.len > 1) {
        var next: std.ArrayListUnmanaged(Entry) = .{};
        errdefer next.deinit(allocator);

        var i: usize = 0;
        while (i < current.items.len) {
            const new_id = try self.cache.allocatePage();
            stats.new_internals_allocated += 1;

            const pg = try self.cache.getPageMut(new_id);
            page.initInternal(pg, new_id);

            // First child of this internal is current[i]; its first
            // key is what bubbles up to the parent layer.
            const layer_first_key_off = current.items[i].key_off;
            const layer_first_key_len = current.items[i].key_len;

            var packed_count: usize = 1;
            var last_child_pid = current.items[i].pid;
            var pid_buf: [4]u8 = undefined;

            // Add separators for current[i+1..] until the page is full.
            while (i + packed_count < current.items.len) {
                const ch = current.items[i + packed_count];
                const sep_key = keys.items[ch.key_off..][0..ch.key_len];
                std.mem.writeInt(u32, &pid_buf, last_child_pid, .little);

                const slot_overhead: u32 = @sizeOf(SlotEntry);
                const needed: u32 = slot_overhead + @as(u32, @intCast(sep_key.len)) + 4;
                if (needed > page.freeSpace(pg)) break;

                page.insertEntry(pg, sep_key, &pid_buf, pg.header.key_count) catch break;
                last_child_pid = ch.pid;
                packed_count += 1;
            }

            // Final child of this internal becomes its right_sibling.
            pg.header.right_sibling = last_child_pid;
            self.cache.unpinPage(new_id);

            try next.append(allocator, .{
                .key_off = layer_first_key_off,
                .key_len = layer_first_key_len,
                .pid = new_id,
            });

            i += packed_count;
        }

        current.deinit(allocator);
        current = next;
    }

    // 3. Adopt the new root. Caller must persist via flushHeader.
    const new_root = current.items[0].pid;
    current.deinit(allocator);

    self.root_page = new_root;
    // Invalidate the rightmost-leaf cache — its ancestor path is
    // now stale because we built a brand-new internal layer.
    self.cached_rightmost_leaf = INVALID_PAGE;
    self.cached_rightmost_path = .{};

    stats.repaired = true;
    stats.new_root = new_root;
    return stats;
}

const page_cache = @import("../page_cache.zig");
const freelist = @import("../freelist.zig");

fn createTempFile(name: []const u8) !std.fs.File {
    return std.fs.cwd().createFile(name, .{
        .read = true,
        .truncate = true,
    });
}

test "repairFromLeafChain rebuilds navigation over an artificially broken tree" {
    const path = "/tmp/test_btree_repair.db";
    const file = try createTempFile(path);
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 256);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, INVALID_PAGE);

    var tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);

    // Insert enough keys to force at least one split — gives us a real
    // tree with internals. Each value is large to bound entries-per-leaf.
    const N: u32 = 600;
    var key_buf: [4]u8 = undefined;
    var val_buf: [400]u8 = undefined;
    for (&val_buf) |*b| b.* = 'x';
    var k: u32 = 0;
    while (k < N) : (k += 1) {
        std.mem.writeInt(u32, &key_buf, k, .big);
        try tree.insert(&key_buf, &val_buf);
    }

    // Sanity: a mid-range key is reachable via search (proves the tree
    // really did split and gain internals).
    {
        var sb: [page.PAGE_SIZE]u8 = undefined;
        std.mem.writeInt(u32, &key_buf, N / 2, .big);
        const found = try tree.search(&key_buf, &sb);
        try std.testing.expect(found != null);
    }

    // Find the leftmost leaf — that's where rangeScan starts.
    const leftmost_leaf = try tree.findLeaf("");

    // Simulate the corruption: pretend the navigation above the leaf
    // level was lost and root_page was reset to the leftmost leaf.
    tree.root_page = leftmost_leaf;
    tree.cached_rightmost_leaf = INVALID_PAGE;
    tree.cached_rightmost_path = .{};

    // Now mid-range keys are NOT reachable via search (root is just a
    // leaf and the key isn't on it).
    {
        var sb: [page.PAGE_SIZE]u8 = undefined;
        std.mem.writeInt(u32, &key_buf, N - 1, .big);
        const before_repair = try tree.search(&key_buf, &sb);
        try std.testing.expect(before_repair == null);
    }

    const stats = try tree.repairFromLeafChain(std.testing.allocator);
    try std.testing.expect(stats.repaired);
    try std.testing.expect(stats.leaves_walked > 1);

    // After repair, every key should be reachable via search again.
    var k2: u32 = 0;
    while (k2 < N) : (k2 += 1) {
        var sb: [page.PAGE_SIZE]u8 = undefined;
        std.mem.writeInt(u32, &key_buf, k2, .big);
        const v = try tree.search(&key_buf, &sb);
        try std.testing.expect(v != null);
    }

    // Idempotent: running it again on a healthy tree is a no-op.
    const stats2 = try tree.repairFromLeafChain(std.testing.allocator);
    try std.testing.expect(!stats2.repaired);
}
