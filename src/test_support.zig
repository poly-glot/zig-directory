//! Fixtures for tests that write schema rows straight into trees and memtables: builders for a
//! category and a link, a presence probe that honours tombstones, and a token-index key packer.
//! Every builder refuses a field that would be silently truncated by the fixed-width codec.

const std = @import("std");
const assert = std.debug.assert;
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

pub fn category(fields: CategoryFields) schema.Category {
    assert(fields.name.len <= 64);
    assert(fields.slug.len <= 128);
    assert(fields.description.len <= 1024);
    return .{
        .id = fields.id,
        .parent_id = fields.parent_id,
        .name = codec.FixedString(64).fromSlice(fields.name),
        .slug = codec.FixedString(128).fromSlice(fields.slug),
        .description = codec.FixedString(1024).fromSlice(fields.description),
        .child_count = fields.child_count,
        .created_at = 1000,
        .updated_at = fields.updated_at,
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

pub fn link(fields: LinkFields) schema.Link {
    assert(fields.url.len <= 64);
    assert(fields.title.len <= 128);
    assert(fields.description.len <= 256);
    return .{
        .id = fields.id,
        .category_id = fields.category_id,
        .url = codec.FixedString(64).fromSlice(fields.url),
        .title = codec.FixedString(128).fromSlice(fields.title),
        .description = codec.FixedString(256).fromSlice(fields.description),
        .created_at = 1000,
        .updated_at = fields.updated_at,
    };
}

pub fn is_present(
    memtable: *zigstore.MemTable,
    tree: *zigstore.BPlusTree,
    key: []const u8,
) !bool {
    assert(key.len > 0);
    var value_buffer: [64]u8 = undefined;
    return switch (memtable.get(key)) {
        .found => true,
        .deleted => false,
        .not_found => (try tree.search(key, &value_buffer)) != null,
    };
}

pub fn token_key(buffer: *[32]u8, text: []const u8, id: u64) []const u8 {
    assert(text.len + @sizeOf(u64) <= buffer.len);
    @memcpy(buffer[0..text.len], text);
    const id_big_endian = codec.encodeU64(id);
    @memcpy(buffer[text.len..][0..8], &id_big_endian);
    return buffer[0 .. text.len + 8];
}
