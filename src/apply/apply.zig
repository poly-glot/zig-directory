const std = @import("std");
const codec = @import("zigstore").codec;
const BPlusTree = @import("zigstore").BPlusTree;
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;

const apply_link = @import("apply_link.zig");
const apply_category = @import("apply_category.zig");
const apply_repair = @import("apply_repair.zig");

pub fn apply(db: *Directory, cs: changeset.ChangeSet) !void {
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

fn applyDeltaU64(base: u64, delta: i64) u64 {
    if (delta >= 0) return base +| @as(u64, @intCast(delta));
    return base -| @abs(delta);
}

fn applyDeltaU32(base: u32, delta: i64) u32 {
    const lim: i64 = std.math.maxInt(u32);
    const clamped = std.math.clamp(delta, -lim, lim);
    if (clamped >= 0) return base +| @as(u32, @intCast(clamped));
    return base -| @as(u32, @intCast(@abs(clamped)));
}

pub fn cascadeAncestorCounts(
    db: *Directory,
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
        cat.link_count_subtree = applyDeltaU64(cat.link_count_subtree, upd.link_count_subtree_delta);
        cat.child_count_subtree = applyDeltaU32(cat.child_count_subtree, upd.child_count_subtree_delta);
        cat.updated_at = now;
        if (cat.id == direct_target_id) {
            if (increment) {
                @field(cat, fld) +|= 1;
            } else if (@field(cat, fld) > 0) {
                @field(cat, fld) -= 1;
            }
        }
        const ancestor_key = codec.encodeU64(upd.cat_id);
        try db.mt_categories_by_id().put(&ancestor_key, std.mem.asBytes(&cat));
    }
}

pub fn writeTokens(
    tree: *BPlusTree,
    tokens: []const changeset.Token,
    id: u64,
    comptime mode: enum { insert, delete },
) !void {
    for (tokens) |t| {
        var key_buf: [4096]u8 = undefined;
        const key_len = t.text.len + 8;
        if (key_len > key_buf.len) continue;
        @memcpy(key_buf[0..t.text.len], t.text);
        const id_be = codec.encodeU64(id);
        @memcpy(key_buf[t.text.len..][0..8], &id_be);
        switch (mode) {
            .insert => try tree.insert(key_buf[0..key_len], &.{}),
            .delete => _ = try tree.delete(key_buf[0..key_len]),
        }
    }
}
