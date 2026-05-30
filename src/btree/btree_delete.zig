//! Delete path: delete, removeEmptyLeaf.

const std = @import("std");
const page = @import("../page.zig");
const btree = @import("btree.zig");

const PageId = page.PageId;
const INVALID_PAGE = page.INVALID_PAGE;

const BPlusTree = btree.BPlusTree;
const PathStack = btree.PathStack;
const compareKeys = btree.compareKeys;
const slotsFromConstPage = btree.slotsFromConstPage;
const slotsFromPage = btree.slotsFromPage;

/// Delete a key. Returns true if found and removed.
pub fn delete(self: *BPlusTree, key: []const u8) !bool {
    self.lock.lock();
    defer self.lock.unlock();

    if (self.root_page == INVALID_PAGE) return false;

    var result = try self.findLeafWithPath(key);
    const leaf_id = result.leaf;
    const pg = try self.getMutablePage(leaf_id);

    const count = pg.header.key_count;
    const slots = slotsFromConstPage(pg);

    for (0..count) |i| {
        const slot = slots[i];
        const k = page.getKeyAt(pg, slot);
        const ord = compareKeys(k, key);
        if (ord == .eq) {
            page.removeEntry(pg, @intCast(i));

            // If the leaf is now empty and not the root, unlink it
            if (pg.header.key_count == 0 and leaf_id != self.root_page) {
                self.cache.unpinPage(leaf_id);
                try removeEmptyLeaf(self, leaf_id, &result.path);
            } else {
                self.cache.unpinPage(leaf_id);
            }
            // Decrement only on a confirmed removal. Saturating
            // sub guards against bootstrap races where the count
            // is still 0 from the on-disk header.
            self.entry_count -|= 1;
            return true;
        }
        if (ord == .gt) break;
    }

    self.cache.unpinPage(leaf_id);
    return false;
}

/// Remove an empty leaf from the tree by unlinking it from its parent
/// and updating sibling pointers. The empty page is returned to the free list.
///
/// Internal node child layout (from findLeaf logic):
///   slot[0].value  handles keys < slot[0].key
///   slot[1].value  handles keys in [slot[0].key, slot[1].key)
///   ...
///   slot[n-1].value handles keys in [slot[n-2].key, slot[n-1].key)
///   right_sibling   handles keys >= slot[n-1].key
///
/// Only performs leaf-level removal. Does not cascade to internal nodes.
/// If removing the leaf would leave the parent with no valid children,
/// the removal is skipped to preserve tree invariants.
fn removeEmptyLeaf(self: *BPlusTree, leaf_id: PageId, path: *PathStack) !void {
    const parent_id = path.pop() orelse return; // root leaf, nothing to do

    const parent = try self.getMutablePage(parent_id);
    defer self.cache.unpinPage(parent_id);

    const count = parent.header.key_count;
    const slots = slotsFromPage(parent);

    // Read the empty leaf's right_sibling so we can patch the sibling chain.
    const leaf_pg = try self.cache.getPage(leaf_id);
    const leaf_right_sibling = leaf_pg.header.right_sibling;
    self.cache.unpinPage(leaf_id);

    // Find leaf_id among the parent's child pointers.
    var child_pos: ?usize = null;
    for (0..count) |i| {
        const v = page.getValueAt(parent, slots[i]);
        if (btree.readPageId(v) == leaf_id) {
            child_pos = i;
            break;
        }
    }

    if (child_pos) |pos| {
        // leaf_id == slot[pos].value

        // After removing slot[pos], the parent will have count-1 keys.
        // If count == 1 and right_sibling == INVALID_PAGE, the parent
        // would have no valid children. Skip removal in that case.
        if (count == 1 and parent.header.right_sibling == INVALID_PAGE) return;

        // Update the left sibling's right_sibling pointer to skip the empty leaf.
        if (pos > 0) {
            const left_sib_id = btree.readPageId(page.getValueAt(parent, slots[pos - 1]));
            const left_sib = try self.getMutablePage(left_sib_id);
            left_sib.header.right_sibling = leaf_right_sibling;
            self.cache.unpinPage(left_sib_id);
        }

        // Remove slot[pos]. After removal, old slot[pos+1] shifts to slot[pos]
        // and its .value naturally absorbs the removed leaf's key range.
        page.removeEntry(parent, @intCast(pos));
    } else if (parent.header.right_sibling == leaf_id) {
        // The empty leaf is the rightmost child.
        if (count > 0) {
            // The left sibling is slot[count-1].value.
            const left_sib_id = btree.readPageId(page.getValueAt(parent, slots[count - 1]));
            const left_sib = try self.getMutablePage(left_sib_id);
            left_sib.header.right_sibling = leaf_right_sibling;
            self.cache.unpinPage(left_sib_id);

            // Promote left sibling to rightmost child, remove its separator.
            parent.header.right_sibling = left_sib_id;
            page.removeEntry(parent, @intCast(count - 1));
        } else {
            // Parent has no keys and only child is the empty leaf.
            // Cannot remove without cascading to grandparent. Skip.
            return;
        }
    } else {
        // leaf_id not found in parent — tree may be inconsistent, skip removal.
        return;
    }

    // Free the empty leaf page.
    try self.free_list.freePage(leaf_id);
}

const page_cache = @import("../page_cache.zig");
const freelist = @import("../freelist.zig");

fn createTempFile(name: []const u8) !std.fs.File {
    return std.fs.cwd().createFile(name, .{
        .read = true,
        .truncate = true,
    });
}

test "delete" {
    const path = "/tmp/test_btree_delete.db";
    const file = try createTempFile(path);
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 64);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, INVALID_PAGE);

    var tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);

    try tree.insert("alpha", "1");
    try tree.insert("beta", "2");
    try tree.insert("gamma", "3");

    const deleted = try tree.delete("beta");
    try std.testing.expect(deleted);

    var sb: [page.PAGE_SIZE]u8 = undefined;
    const v = try tree.search("beta", &sb);
    try std.testing.expect(v == null);

    // Others still present
    try std.testing.expect((try tree.search("alpha", &sb)) != null);
    try std.testing.expect((try tree.search("gamma", &sb)) != null);

    // Deleting non-existent key returns false
    const d2 = try tree.delete("nonexistent");
    try std.testing.expect(!d2);
}

test "entry_count tracks insert/delete/duplicate" {
    const path = "/tmp/test_btree_entry_count.db";
    const file = try createTempFile(path);
    defer file.close();
    defer std.fs.cwd().deleteFile(path) catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 64);
    defer cache.deinit();
    var fl = freelist.FreeList.init(&cache, INVALID_PAGE);

    var tree = BPlusTree.init(&cache, &fl, INVALID_PAGE);

    try std.testing.expectEqual(@as(u64, 0), tree.entry_count);

    var k1: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 1 };
    var v: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 42 };
    try tree.insert(&k1, &v);
    try std.testing.expectEqual(@as(u64, 1), tree.entry_count);

    try tree.insert(&k1, &v); // duplicate — overwrite, count unchanged
    try std.testing.expectEqual(@as(u64, 1), tree.entry_count);

    var k2: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 2 };
    try tree.insert(&k2, &v);
    try std.testing.expectEqual(@as(u64, 2), tree.entry_count);

    _ = try tree.delete(&k1);
    try std.testing.expectEqual(@as(u64, 1), tree.entry_count);

    _ = try tree.delete(&k1); // missing — count unchanged
    try std.testing.expectEqual(@as(u64, 1), tree.entry_count);
}
