// Thin re-export shim. The original ~2.1k-LOC operations.zig was split
// into five sibling files under Slice 4 §2.1 of the file-size + test
// density refactor:
//
//   operations_shared.zig             - OperationError, MAX_* constants
//   operations_changeset_compute.zig  - compute*ChangeSet helpers
//   operations_category.zig           - category CRUD + traversal
//   operations_link.zig               - link CRUD + listing
//   operations_search.zig             - tokenised AND search
//   operations_slug.zig               - slug-path resolve / build
//
// `usingnamespace` was removed in Zig 0.15, so the public surface is
// re-exported by name. Existing call sites
// (`@import("operations.zig").createCategory(...)`, etc.) keep working
// without a code change.

const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");
const link_mod = @import("operations_link.zig");
const search = @import("operations_search.zig");
const slug_mod = @import("operations_slug.zig");

pub const OperationError = shared.OperationError;
pub const MAX_URL_LEN = shared.MAX_URL_LEN;

// Category CRUD + traversal
pub const createCategory = category.createCategory;
pub const getCategory = category.getCategory;
pub const updateCategory = category.updateCategory;
pub const deleteCategory = category.deleteCategory;
pub const moveCategory = category.moveCategory;
pub const listChildren = category.listChildren;
pub const getCategoryPath = category.getCategoryPath;
pub const walkAncestors = category.walkAncestors;

// Link CRUD + listing
pub const createLink = link_mod.createLink;
pub const createLinkWithOpts = link_mod.createLinkWithOpts;
pub const CreateLinkOpts = link_mod.CreateLinkOpts;
pub const getLink = link_mod.getLink;
pub const updateLink = link_mod.updateLink;
pub const moveLink = link_mod.moveLink;
pub const updateLinkStatus = link_mod.updateLinkStatus;
pub const updateLinkStatusBulkOne = link_mod.updateLinkStatusBulkOne;
pub const countsByStatus = link_mod.countsByStatus;
pub const recountLinkStatuses = link_mod.recountLinkStatuses;
pub const StatusCounts = link_mod.StatusCounts;
pub const deleteLink = link_mod.deleteLink;
pub const listLinks = link_mod.listLinks;
pub const listAllLinks = link_mod.listAllLinks;
pub const listLinksBySubmitter = link_mod.listLinksBySubmitter;
pub const LinkPage = link_mod.LinkPage;

// Search
pub const searchCategories = search.searchCategories;
pub const searchLinks = search.searchLinks;

// Slug-path
pub const resolveSlugPath = slug_mod.resolveSlugPath;
pub const buildSlugPath = slug_mod.buildSlugPath;
pub const buildCanonicalSlugPath = slug_mod.buildCanonicalSlugPath;
