//! Vocabulary shared by every operation: the error set they return, the field maxima that the
//! schema records hold without truncation, and the paging and move arguments the protocol
//! handlers pass down. The maxima are the record slot capacities, so a field that passes its
//! length check is stored whole.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");

pub const log = std.log.scoped(.operations);

pub const OperationError = error{
    CategoryNotFound,
    LinkNotFound,
    AlreadyInState,
    ParentNotFound,
    DuplicateUrl,
    DuplicateSlug,
    CircularHierarchy,
    CategoryHasChildren,
    CategoryTooLarge,
    PathTooDeep,
    FieldTooLong,
    DatabaseCorrupted,
};

pub const depth_max: usize = 64;
pub const name_len_max: usize = 64;
pub const slug_len_max: usize = 128;
pub const category_description_len_max: usize = 1024;
pub const url_len_max: usize = 64;
pub const title_len_max: usize = 128;
pub const link_description_len_max: usize = 256;

comptime {
    assert(codec.FixedString(name_len_max) == @FieldType(schema.Category, "name"));
    assert(codec.FixedString(slug_len_max) == @FieldType(schema.Category, "slug"));
    assert(codec.FixedString(category_description_len_max) ==
        @FieldType(schema.Category, "description"));
    assert(codec.FixedString(url_len_max) == @FieldType(schema.Link, "url"));
    assert(codec.FixedString(title_len_max) == @FieldType(schema.Link, "title"));
    assert(codec.FixedString(link_description_len_max) ==
        @FieldType(schema.Link, "description"));
}

pub const Page = struct {
    offset: u32 = 0,
    limit: u32,
    /// A cursor above 0 pages from the id after it and ignores `offset`.
    after_id: u64 = 0,
    status_filter: ?u8 = null,
};

pub const Move = struct { id: u64, new_parent_id: u64 };

pub const CategoryText = struct { name: []const u8, slug: []const u8, description: []const u8 };
pub const LinkText = struct { url: []const u8, title: []const u8, description: []const u8 };
