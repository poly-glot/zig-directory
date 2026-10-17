const std = @import("std");
const zigstore = @import("zigstore");
const codec = zigstore.codec;
const schema = @import("schema.zig");

pub const CategoryFields = struct {
    id: u64,
    parent_id: u64,
    name: []const u8,
    slug: []const u8,
    description: []const u8 = "",
    child_count: u32 = 0,
    updated_at: i64 = 1000,
};

pub fn category(f: CategoryFields) schema.Category {
    return .{
        .id = f.id,
        .parent_id = f.parent_id,
        .name = codec.FixedString(64).fromSlice(f.name),
        .slug = codec.FixedString(128).fromSlice(f.slug),
        .description = codec.FixedString(1024).fromSlice(f.description),
        .child_count = f.child_count,
        .created_at = 1000,
        .updated_at = f.updated_at,
    };
}

pub const LinkFields = struct {
    id: u64,
    category_id: u64,
    url: []const u8,
    title: []const u8,
    description: []const u8,
    updated_at: i64 = 1000,
};

pub fn link(f: LinkFields) schema.Link {
    return .{
        .id = f.id,
        .category_id = f.category_id,
        .url = codec.FixedString(64).fromSlice(f.url),
        .title = codec.FixedString(128).fromSlice(f.title),
        .description = codec.FixedString(256).fromSlice(f.description),
        .created_at = 1000,
        .updated_at = f.updated_at,
    };
}

pub fn isPresent(mt: *zigstore.MemTable, tree: *zigstore.BPlusTree, key: []const u8) !bool {
    var v_buf: [64]u8 = undefined;
    return switch (mt.get(key)) {
        .found => true,
        .deleted => false,
        .not_found => (try tree.search(key, &v_buf)) != null,
    };
}

pub fn tokenKey(buf: *[32]u8, text: []const u8, id: u64) []const u8 {
    @memcpy(buf[0..text.len], text);
    const id_be = codec.encodeU64(id);
    @memcpy(buf[text.len..][0..8], &id_be);
    return buf[0 .. text.len + 8];
}
