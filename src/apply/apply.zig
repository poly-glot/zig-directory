const std = @import("std");
const types = @import("../types.zig");
const changeset = @import("../changeset.zig");
const Database = @import("../database.zig").Database;

const apply_link = @import("apply_link.zig");
const apply_category = @import("apply_category.zig");
const apply_repair = @import("apply_repair.zig");

pub const ApplyError = error{
    OutOfMemory,
    NotImplemented,
} || @import("../btree/btree.zig").BTreeError;

/// Apply a ChangeSet to the database. Caller must hold db.apply_mutex.
/// Idempotent on retry (all effects use overwrite-on-key or absolute targets).
pub fn apply(db: *Database, cs: changeset.ChangeSet) !void {
    return switch (cs) {
        .link_inserted => |e| apply_link.applyLinkInserted(db, e),
        .link_deleted => |e| apply_link.applyLinkDeleted(db, e),
        .link_text_updated => |e| apply_link.applyLinkTextUpdated(db, e),
        .link_recategorized => |e| apply_link.applyLinkRecategorized(db, e),
        .category_inserted => |e| apply_category.applyCategoryInserted(db, e),
        .category_deleted => |e| apply_category.applyCategoryDeleted(db, e),
        .category_text_updated => |e| apply_category.applyCategoryTextUpdated(db, e),
        .category_renamed => |e| apply_category.applyCategoryRenamed(db, e),
        .category_moved => |e| apply_category.applyCategoryMoved(db, e),
        .slug_path_repair_chunk => |e| apply_repair.applySlugPathRepairChunk(db, e),
        .slug_path_repair_complete => |e| apply_repair.applySlugPathRepairComplete(db, e),
    };
}

pub const DirectField = enum { link_count, child_count };

/// Walk `updates`, write the absolute subtree counts into each ancestor's
/// stored Category, and adjust the immediate parent's direct count by ±1
/// (saturating). Idempotent on retry: subtree counts are absolute, and the
/// direct-count delta is gated on `cat.id == direct_target_id` which only
/// matches once per cascade.
pub fn cascadeAncestorCounts(
    db: *Database,
    updates: []const changeset.AncestorUpdate,
    direct_target_id: u64,
    comptime direct_field: DirectField,
    comptime increment: bool,
) !void {
    const ops = @import("../operations/operations.zig");
    const now = std.time.timestamp();
    const fld = comptime @tagName(direct_field);
    for (updates) |upd| {
        var cat = (try ops.getCategory(db, upd.cat_id)) orelse continue;
        cat.link_count_subtree = upd.new_link_count_subtree;
        cat.child_count_subtree = upd.new_child_count_subtree;
        cat.updated_at = now;
        if (cat.id == direct_target_id) {
            if (increment) {
                @field(cat, fld) +|= 1;
            } else if (@field(cat, fld) > 0) {
                @field(cat, fld) -= 1;
            }
        }
        const ancestor_key = types.encodeU64(upd.cat_id);
        try db.mt_categories_by_id.put(&ancestor_key, std.mem.asBytes(&cat));
    }
}
