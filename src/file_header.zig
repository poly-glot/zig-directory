const std = @import("std");
const page = @import("page.zig");

pub const MAGIC: u32 = 0x444D4F5A; // "DMOZ"
/// On-disk header version that newly-written headers carry.
pub const VERSION: u32 = 5;

/// Comptime-computed reserved padding so FileHeader fills exactly one page.
/// The comptime assertion at the bottom of the file catches any mismatch.
const file_header_fields_size: usize =
    10 * @sizeOf(u32) + 2 * @sizeOf(u64) + 5 * @sizeOf(u64) + @sizeOf(u32) // _legacy_pad_a (was schema_version)
    + @sizeOf(u32) // _legacy_pad_b (was migration_phase)
    + 4 * @sizeOf(u32) + 4 * @sizeOf(u64) + @sizeOf(u32) // slug_path_repair_queue_root
    + @sizeOf(u64) // slug_path_repair_queue_count
    + @sizeOf(u64) // next_repair_seq
    + @sizeOf(u64) // link_by_submitter_count
    + @sizeOf(u32); // link_by_submitter_root
const file_header_reserved_size: usize = page.PAGE_SIZE - file_header_fields_size;

/// On-disk file header stored in page 0 of the data file.
pub const FileHeader = extern struct {
    magic: u32 = MAGIC,
    version: u32 = VERSION,
    page_size: u32 = page.PAGE_SIZE,
    page_count: u32 = 1,
    free_list_head: page.PageId = page.INVALID_PAGE,
    category_root: page.PageId = page.INVALID_PAGE,
    link_root: page.PageId = page.INVALID_PAGE,
    cat_by_parent_root: page.PageId = page.INVALID_PAGE,
    link_by_category_root: page.PageId = page.INVALID_PAGE,
    link_by_url_hash_root: page.PageId = page.INVALID_PAGE,
    next_category_id: u64 = 1,
    next_link_id: u64 = 1,

    // Per-B+Tree entry counts — kept in sync via flushHeader. The
    // count is the authoritative source on reopen; fresh databases
    // initialise it to zero and increment incrementally on each commit.
    categories_by_id_count: u64 = 0,
    links_by_id_count: u64 = 0,
    cat_by_parent_count: u64 = 0,
    link_by_category_count: u64 = 0,
    link_by_url_hash_count: u64 = 0,

    // Inert padding preserving the on-disk byte offsets of every field
    // below. These slots held `schema_version` and `migration_phase` in
    // the migration-runner era. Removing the fields without keeping the
    // bytes would shift every subsequent root/count, mis-interpreting
    // existing data files. DO NOT REMOVE.
    _legacy_pad_a: u32 = 0,
    _legacy_pad_b: u32 = 0,

    // Roots for the four indexing B+Trees. Paired *_count fields live
    // below to keep u64 alignment clean.
    categories_by_slug_path_root: page.PageId = page.INVALID_PAGE,
    categories_by_slug_only_root: page.PageId = page.INVALID_PAGE,
    categories_index_root: page.PageId = page.INVALID_PAGE,
    links_index_root: page.PageId = page.INVALID_PAGE,

    // Entry counts for the four indexing B+Trees above.
    categories_by_slug_path_count: u64 = 0,
    categories_by_slug_only_count: u64 = 0,
    categories_index_count: u64 = 0,
    links_index_count: u64 = 0,

    // Slug-path repair queue fields — DO NOT REORDER.
    // Field order is load-bearing: the two u64 counters MUST precede the
    // u32 root pointer. The two u32 root pointers below are paired so
    // their combined 8 bytes match the alignment that the following
    // `link_by_submitter_count: u64` requires — without the pairing,
    // extern-struct rules would insert a 4-byte padding hole between them
    // and break the comptime `@sizeOf(FileHeader) == page.PAGE_SIZE`
    // assertion at the bottom of this file. The repair queue itself is
    // drained by repair_worker.
    slug_path_repair_queue_count: u64 = 0,
    next_repair_seq: u64 = 1,
    slug_path_repair_queue_root: page.PageId = page.INVALID_PAGE,

    // link_by_submitter index — keyed by (submitter_id, link_id). Used
    // by op=27 list_links_by_submitter so the dashboard's per-user listing
    // doesn't scan all of links_by_id. DO NOT REORDER.
    link_by_submitter_root: page.PageId = page.INVALID_PAGE,
    link_by_submitter_count: u64 = 0,

    /// Padding to fill the remainder of the page. Size is computed at comptime
    /// so that adding/removing fields before this point is automatically handled.
    _reserved: [file_header_reserved_size]u8 = [_]u8{0} ** file_header_reserved_size,

    /// Returns a default-initialized FileHeader.
    pub fn init() FileHeader {
        return FileHeader{};
    }

    /// Validate the header: check magic, version, and page size.
    pub fn validate(h: *const FileHeader) !void {
        if (h.magic != MAGIC) return error.InvalidMagic;
        if (h.version != VERSION) return error.UnsupportedVersion;
        if (h.page_size != page.PAGE_SIZE) return error.InvalidPageSize;
    }

    /// Serialize the FileHeader into a page-sized byte array.
    pub fn serialize(h: *const FileHeader) [page.PAGE_SIZE]u8 {
        return std.mem.toBytes(h.*);
    }

    /// Deserialize a page-sized byte array into a FileHeader.
    pub fn deserialize(bytes: *const [page.PAGE_SIZE]u8) FileHeader {
        return std.mem.bytesToValue(FileHeader, bytes);
    }
};

comptime {
    if (@sizeOf(FileHeader) != page.PAGE_SIZE)
        @compileError("FileHeader must be PAGE_SIZE bytes");
}

test "init serialize deserialize roundtrip" {
    const h = FileHeader.init();
    const bytes = h.serialize();
    const h2 = FileHeader.deserialize(&bytes);

    try std.testing.expectEqual(MAGIC, h2.magic);
    try std.testing.expectEqual(VERSION, h2.version);
    try std.testing.expectEqual(page.PAGE_SIZE, h2.page_size);
    try std.testing.expectEqual(page.INVALID_PAGE, h2.category_root);
    try std.testing.expectEqual(page.INVALID_PAGE, h2.link_root);
    try std.testing.expectEqual(page.INVALID_PAGE, h2.free_list_head);
    try std.testing.expectEqual(@as(u64, 1), h2.next_category_id);
    try std.testing.expectEqual(@as(u64, 1), h2.next_link_id);
}

test "validate catches bad magic" {
    var h = FileHeader.init();
    try h.validate();

    h.magic = 0xDEADBEEF;
    try std.testing.expectError(error.InvalidMagic, h.validate());
}

test "validate catches bad version" {
    var h = FileHeader.init();
    h.version = 99;
    try std.testing.expectError(error.UnsupportedVersion, h.validate());
}

test "validate catches bad page size" {
    var h = FileHeader.init();
    h.page_size = 8192;
    try std.testing.expectError(error.InvalidPageSize, h.validate());
}

test "FileHeader carries the slug_path_repair_queue_root field" {
    const h = FileHeader.init();
    try std.testing.expectEqual(page.INVALID_PAGE, h.slug_path_repair_queue_root);
    try std.testing.expectEqual(@as(u64, 0), h.slug_path_repair_queue_count);
    try std.testing.expectEqual(@as(u64, 1), h.next_repair_seq);
}

test "FileHeader carries the link_by_submitter_root field" {
    const h = FileHeader.init();
    try std.testing.expectEqual(page.INVALID_PAGE, h.link_by_submitter_root);
    try std.testing.expectEqual(@as(u64, 0), h.link_by_submitter_count);
}
