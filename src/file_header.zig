const std = @import("std");
const page = @import("page.zig");

pub const MAGIC: u32 = 0x444D4F5A;
pub const VERSION: u32 = 5;

const file_header_fields_size: usize =
    10 * @sizeOf(u32) + 2 * @sizeOf(u64) + 5 * @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u32) + 4 * @sizeOf(u32) + 4 * @sizeOf(u64) + @sizeOf(u32) + @sizeOf(u64) + @sizeOf(u64) + @sizeOf(u64) + @sizeOf(u32);
const file_header_reserved_size: usize = page.PAGE_SIZE - file_header_fields_size;

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

    categories_by_id_count: u64 = 0,
    links_by_id_count: u64 = 0,
    cat_by_parent_count: u64 = 0,
    link_by_category_count: u64 = 0,
    link_by_url_hash_count: u64 = 0,

    _legacy_pad_a: u32 = 0,
    _legacy_pad_b: u32 = 0,

    categories_by_slug_path_root: page.PageId = page.INVALID_PAGE,
    categories_by_slug_only_root: page.PageId = page.INVALID_PAGE,
    categories_index_root: page.PageId = page.INVALID_PAGE,
    links_index_root: page.PageId = page.INVALID_PAGE,

    categories_by_slug_path_count: u64 = 0,
    categories_by_slug_only_count: u64 = 0,
    categories_index_count: u64 = 0,
    links_index_count: u64 = 0,

    slug_path_repair_queue_count: u64 = 0,
    next_repair_seq: u64 = 1,
    slug_path_repair_queue_root: page.PageId = page.INVALID_PAGE,

    link_by_submitter_root: page.PageId = page.INVALID_PAGE,
    link_by_submitter_count: u64 = 0,

    _reserved: [file_header_reserved_size]u8 = [_]u8{0} ** file_header_reserved_size,

    pub fn init() FileHeader {
        return FileHeader{};
    }

    pub fn validate(h: *const FileHeader) !void {
        if (h.magic != MAGIC) return error.InvalidMagic;
        if (h.version != VERSION) return error.UnsupportedVersion;
        if (h.page_size != page.PAGE_SIZE) return error.InvalidPageSize;
    }

    pub fn serialize(h: *const FileHeader) [page.PAGE_SIZE]u8 {
        return std.mem.toBytes(h.*);
    }

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
