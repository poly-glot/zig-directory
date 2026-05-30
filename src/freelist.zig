const std = @import("std");
const page = @import("page.zig");
const page_cache = @import("page_cache.zig");

pub const FreeListError = error{
    DoubleFree,
};

/// Manages free (reusable) pages on disk using a singly-linked free list.
/// Each free page stores the PageId of the next free page in its first 4 bytes.
///
/// Thread safety: All public methods are internally synchronized via a mutex,
/// since multiple B+Trees (with independent locks) share a single FreeList.
pub const FreeList = struct {
    head: page.PageId,
    cache: *page_cache.PageCache,
    mutex: std.Thread.Mutex,

    /// Initialize a FreeList with the given cache and head page id.
    pub fn init(cache: *page_cache.PageCache, head: page.PageId) FreeList {
        return FreeList{
            .head = head,
            .cache = cache,
            .mutex = .{},
        };
    }

    /// Pop a page from the free list. If the list is empty, allocate a
    /// new page by extending the data file.
    ///
    /// Defensive: validates the popped page's `page_type == .free`. If
    /// an entry in the chain has been reallocated as a non-free page
    /// without being unlinked, skip it and keep walking until we find a
    /// valid free page or fall through to file extension.
    pub fn allocPage(self: *FreeList) !page.PageId {
        self.mutex.lock();
        defer self.mutex.unlock();

        const log = std.log.scoped(.freelist);
        var skipped: u32 = 0;

        // Page 0 is the file header — never a valid freelist entry. Treat it
        // as a chain terminator (alongside INVALID_PAGE) so a corrupted next
        // pointer that decodes to 0 doesn't make us try to reuse the header.
        while (self.head != page.INVALID_PAGE and self.head != 0) {
            const pid = self.head;
            const pg_const = try self.cache.getPage(pid);
            const pg: *const page.Page = @ptrCast(@alignCast(pg_const));

            // Advance head to the next pointer regardless of validity, so a
            // corrupted entry is removed from the chain.
            const next_bytes: *const [4]u8 = pg.body[0..4];
            const next = std.mem.readInt(u32, next_bytes, .little);
            const page_type = pg.header.page_type;
            self.cache.unpinPage(pid);
            self.head = next;

            if (page_type == @intFromEnum(page.PageType.free)) {
                if (skipped > 0) {
                    log.warn("allocPage: skipped {d} corrupted freelist entries before finding a valid free page (returned pid={d})", .{ skipped, pid });
                }
                return pid;
            }

            skipped += 1;
            if (skipped == 1) {
                log.warn("allocPage: freelist corruption — pid={d} marked head but page_type={d} (expected .free); skipping", .{ pid, page_type });
            }
            // Cap the scan to avoid runaway loops on cycles.
            if (skipped > 1024) {
                log.warn("allocPage: freelist scan exceeded 1024 corrupted entries; truncating chain and extending file", .{});
                self.head = page.INVALID_PAGE;
                break;
            }
        }

        return try self.cache.allocatePage();
    }

    /// Push a page onto the free list. Writes the current head into the freed
    /// page's first 4 bytes, then sets this page as the new head.
    /// Returns `FreeListError.DoubleFree` if the page is already marked free.
    pub fn freePage(self: *FreeList, pid: page.PageId) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pg_raw = try self.cache.getPageMut(pid);
        const pg: *page.Page = @ptrCast(@alignCast(pg_raw));

        // Guard against double-free: if already marked free, reject.
        if (pg.header.page_type == @intFromEnum(page.PageType.free)) {
            self.cache.unpinPage(pid);
            return FreeListError.DoubleFree;
        }

        // Mark as free page type
        pg.header.page_type = @intFromEnum(page.PageType.free);
        pg.header.key_count = 0;
        pg.header.page_id = pid;

        // Store current head in first 4 bytes of body
        const next_bytes: *[4]u8 = pg.body[0..4];
        std.mem.writeInt(u32, next_bytes, self.head, .little);

        self.cache.unpinPage(pid);
        self.head = pid;
    }

    /// Get the current head of the free list.
    pub fn getHead(self: *FreeList) page.PageId {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.head;
    }
};

fn createTempFile() !std.fs.File {
    return std.fs.cwd().createFile("/tmp/test_freelist.db", .{
        .read = true,
        .truncate = true,
    });
}

test "alloc free roundtrip" {
    const file = try createTempFile();
    defer file.close();
    defer std.fs.cwd().deleteFile("/tmp/test_freelist.db") catch {};

    // Pre-extend the file so page_count starts at 1 (mirrors production where
    // page 0 is the FileHeader and is never a valid freelist entry).
    try file.setEndPos(page.PAGE_SIZE);

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, 16);
    defer cache.deinit();

    var fl = FreeList.init(&cache, page.INVALID_PAGE);

    // Allocate 3 pages (from file since free list is empty)
    const p1 = try fl.allocPage();
    const p2 = try fl.allocPage();
    const p3 = try fl.allocPage();

    // Initialize them so they have valid data
    {
        const pg1 = try cache.getPageMut(p1);
        page.initLeaf(@ptrCast(@alignCast(pg1)), p1);
        cache.unpinPage(p1);
    }
    {
        const pg2 = try cache.getPageMut(p2);
        page.initLeaf(@ptrCast(@alignCast(pg2)), p2);
        cache.unpinPage(p2);
    }
    {
        const pg3 = try cache.getPageMut(p3);
        page.initLeaf(@ptrCast(@alignCast(pg3)), p3);
        cache.unpinPage(p3);
    }

    // Free them
    try fl.freePage(p3);
    try fl.freePage(p2);
    try fl.freePage(p1);

    // Free list is now: p1 -> p2 -> p3 -> INVALID
    try std.testing.expectEqual(p1, fl.getHead());

    // Re-allocate - should come from free list in LIFO order
    const r1 = try fl.allocPage();
    const r2 = try fl.allocPage();
    const r3 = try fl.allocPage();

    try std.testing.expectEqual(p1, r1);
    try std.testing.expectEqual(p2, r2);
    try std.testing.expectEqual(p3, r3);

    // Free list should be empty now
    try std.testing.expectEqual(page.INVALID_PAGE, fl.getHead());

    // Next alloc should extend file
    const p4 = try fl.allocPage();
    try std.testing.expect(p4 >= 3);
}

test "double free detection" {
    const file = try createTempFile();
    defer file.close();
    defer std.fs.cwd().deleteFile("/tmp/test_freelist.db") catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, page_cache.NUM_SHARDS * 4);
    defer cache.deinit();

    var fl = FreeList.init(&cache, page.INVALID_PAGE);

    const p1 = try fl.allocPage();
    {
        const pg = try cache.getPageMut(p1);
        page.initLeaf(@ptrCast(@alignCast(pg)), p1);
        cache.unpinPage(p1);
    }

    try fl.freePage(p1);
    // Second free should fail with DoubleFree.
    try std.testing.expectError(FreeListError.DoubleFree, fl.freePage(p1));
}

test "freelist getHead with mutex" {
    const file = try createTempFile();
    defer file.close();
    defer std.fs.cwd().deleteFile("/tmp/test_freelist.db") catch {};

    var cache = try page_cache.PageCache.init(std.testing.allocator, file, page_cache.NUM_SHARDS * 4);
    defer cache.deinit();

    var fl = FreeList.init(&cache, page.INVALID_PAGE);
    try std.testing.expectEqual(page.INVALID_PAGE, fl.getHead());

    const p1 = try fl.allocPage();
    {
        const pg = try cache.getPageMut(p1);
        page.initLeaf(@ptrCast(@alignCast(pg)), p1);
        cache.unpinPage(p1);
    }
    try fl.freePage(p1);
    try std.testing.expectEqual(p1, fl.getHead());
}
