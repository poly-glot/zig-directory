// Shared error set + max-length constants used across the
// operations_* split files. Lives here so each file can import the
// names without forming an import cycle through `operations.zig`.

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
    SlugConflict,
    BufferTooSmall,
    PathTooDeep,
    FieldTooLong,
    IoError,
    DatabaseCorrupted,
};

// Maximum field byte lengths — derived from the FixedString capacities
// used in `types.Category` / `types.Link`. Inputs longer than these are
// rejected at the operations boundary so the FixedString never silently
// truncates (which would otherwise break duplicate-URL detection: the
// hash is computed over the full input, but the stored slice is the
// truncated form, so the byte-equality guard misses the duplicate).
pub const MAX_NAME_LEN: usize = 64;
pub const MAX_SLUG_LEN: usize = 128;
pub const MAX_CATEGORY_DESC_LEN: usize = 1024;
pub const MAX_URL_LEN: usize = 64;
pub const MAX_TITLE_LEN: usize = 128;
pub const MAX_LINK_DESC_LEN: usize = 256;
