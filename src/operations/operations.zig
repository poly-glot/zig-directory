const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");
const link_mod = @import("operations_link.zig");
const search = @import("operations_search.zig");
const slug_mod = @import("operations_slug.zig");
const vector_mod = @import("operations_vector.zig");

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
pub const computeCategoryCounts = category.computeCategoryCounts;

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
pub const seedUrlBloom = link_mod.seedUrlBloom;
pub const seedUrlBloomInChunks = link_mod.seedUrlBloomInChunks;
pub const SeedPace = link_mod.SeedPace;
pub const StatusCounts = link_mod.StatusCounts;
pub const deleteLink = link_mod.deleteLink;
pub const listLinks = link_mod.listLinks;
pub const listAllLinks = link_mod.listAllLinks;
pub const listLinksBySubmitter = link_mod.listLinksBySubmitter;
pub const LinkPage = link_mod.LinkPage;

pub const searchCategories = search.searchCategories;
pub const searchLinks = search.searchLinks;
pub const searchCategoriesRanked = search.searchCategoriesRanked;
pub const searchLinksRanked = search.searchLinksRanked;
pub const searchLinksHybrid = search.searchLinksHybrid;
pub const HybridLinks = search.HybridLinks;

pub const putLinkVectors = vector_mod.putLinkVectors;
pub const getLinkVector = vector_mod.getLinkVector;
pub const loadVectorIndex = vector_mod.loadVectorIndex;
pub const VectorWrite = vector_mod.VectorWrite;
pub const VectorWriteResult = vector_mod.VectorWriteResult;
pub const MAX_VECTORS_PER_WRITE = vector_mod.MAX_VECTORS_PER_WRITE;

pub const resolveSlugPath = slug_mod.resolveSlugPath;
pub const buildSlugPath = slug_mod.buildSlugPath;
pub const composeOldDescendantPath = slug_mod.composeOldDescendantPath;
