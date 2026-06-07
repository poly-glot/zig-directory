const std = @import("std");

pub const log = std.log.scoped(.operations);

pub const OperationError = error{
    CategoryNotFound,
    LinkNotFound,
    AlreadyInState,
    ParentNotFound,
    DuplicateUrl,
    CircularHierarchy,
    CategoryHasChildren,
    InvalidSlug,
    BufferTooSmall,
    PathTooDeep,
    FieldTooLong,
    DatabaseCorrupted,
};

pub const MAX_NAME_LEN: usize = 64;
pub const MAX_SLUG_LEN: usize = 128;
pub const MAX_CATEGORY_DESC_LEN: usize = 1024;
pub const MAX_URL_LEN: usize = 64;
pub const MAX_TITLE_LEN: usize = 128;
pub const MAX_LINK_DESC_LEN: usize = 256;
