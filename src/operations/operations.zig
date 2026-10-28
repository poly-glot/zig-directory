//! Public face of the operations layer: `directory.zig`, the protocol handlers and the
//! background workers import this file alone, so the split into per-area modules stays
//! private to `src/operations/`.

const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");
const link_operations = @import("operations_link.zig");
const search = @import("operations_search.zig");
const slug_operations = @import("operations_slug.zig");
const vector_operations = @import("operations_vector.zig");
const facts_operations = @import("operations_facts.zig");

pub const OperationError = shared.OperationError;
pub const url_len_max = shared.url_len_max;
pub const Page = shared.Page;
pub const Move = shared.Move;
pub const CategoryText = shared.CategoryText;
pub const LinkText = shared.LinkText;

pub const create_category = category.create_category;
pub const get_category = category.get_category;
pub const update_category = category.update_category;
pub const delete_category = category.delete_category;
pub const move_category = category.move_category;
pub const list_children = category.list_children;
pub const get_category_path = category.get_category_path;
pub const walk_ancestors = category.walk_ancestors;
pub const recompute_category_counts = category.recompute_category_counts;
pub const compute_category_counts = category.compute_category_counts;

pub const create_link = link_operations.create_link;
pub const create_link_with_options = link_operations.create_link_with_options;
pub const CreateLinkOptions = link_operations.CreateLinkOptions;
pub const get_link = link_operations.get_link;
pub const update_link = link_operations.update_link;
pub const move_link = link_operations.move_link;
pub const update_link_status = link_operations.update_link_status;
pub const update_link_status_bulk_one = link_operations.update_link_status_bulk_one;
pub const counts_by_status = link_operations.counts_by_status;
pub const recount_link_statuses = link_operations.recount_link_statuses;
pub const seed_url_bloom = link_operations.seed_url_bloom;
pub const seed_url_bloom_in_chunks = link_operations.seed_url_bloom_in_chunks;
pub const SeedPace = link_operations.SeedPace;
pub const StatusCounts = link_operations.StatusCounts;
pub const delete_link = link_operations.delete_link;
pub const list_links = link_operations.list_links;
pub const list_all_links = link_operations.list_all_links;
pub const list_links_by_submitter = link_operations.list_links_by_submitter;
pub const LinkPage = link_operations.LinkPage;

pub const search_categories = search.search_categories;
pub const search_links = search.search_links;
pub const search_categories_ranked = search.search_categories_ranked;
pub const search_links_ranked = search.search_links_ranked;
pub const search_links_hybrid = search.search_links_hybrid;
pub const search_categories_hybrid = search.search_categories_hybrid;
pub const HybridLinks = search.HybridLinks;
pub const RowSite = search.RowSite;

pub const put_link_vectors = vector_operations.put_link_vectors;
pub const get_link_vector = vector_operations.get_link_vector;
pub const load_vector_index = vector_operations.load_vector_index;
pub const load_category_vector_index = vector_operations.load_category_vector_index;
pub const put_category_vectors = vector_operations.put_category_vectors;
pub const load_facts_index = facts_operations.load_facts_index;
pub const query_links = facts_operations.query_links;
pub const match_names = facts_operations.match_names;
pub const NameMatch = facts_operations.NameMatch;
pub const name_matches_max = facts_operations.name_matches_max;
pub const LinkQuery = facts_operations.LinkQuery;
pub const LinkQueryResult = facts_operations.LinkQueryResult;
pub const WordsMatch = facts_operations.WordsMatch;
pub const put_link_entities = facts_operations.put_link_entities;
pub const EntityWrite = facts_operations.EntityWrite;
pub const EntityWriteResult = facts_operations.EntityWriteResult;
pub const entity_writes_max = facts_operations.entity_writes_max;
pub const VectorWrite = vector_operations.VectorWrite;
pub const CategoryVectorWrite = vector_operations.CategoryVectorWrite;
pub const VectorWriteResult = vector_operations.VectorWriteResult;
pub const vectors_per_write_max = vector_operations.vectors_per_write_max;

pub const resolve_slug_path = slug_operations.resolve_slug_path;
pub const build_slug_path = slug_operations.build_slug_path;
pub const compose_old_descendant_path = slug_operations.compose_old_descendant_path;
