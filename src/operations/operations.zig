const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");
const link_mod = @import("operations_link.zig");
const search = @import("operations_search.zig");
const slug_mod = @import("operations_slug.zig");

pub const OperationError = shared.OperationError;
pub const MAX_URL_LEN = shared.MAX_URL_LEN;

pub const createCategory = category.createCategory;
pub const getCategory = category.getCategory;
pub const updateCategory = category.updateCategory;
pub const deleteCategory = category.deleteCategory;
pub const moveCategory = category.moveCategory;
pub const listChildren = category.listChildren;
pub const getCategoryPath = category.getCategoryPath;
pub const walkAncestors = category.walkAncestors;
pub const recomputeCategoryCounts = category.recomputeCategoryCounts;

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

pub const searchCategories = search.searchCategories;
pub const searchLinks = search.searchLinks;

pub const resolveSlugPath = slug_mod.resolveSlugPath;
pub const buildCanonicalSlugPath = slug_mod.buildCanonicalSlugPath;
pub const composeOldDescendantPath = slug_mod.composeOldDescendantPath;
