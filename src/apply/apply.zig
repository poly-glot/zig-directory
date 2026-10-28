//! Applies a committed ChangeSet to the store: trees, memtables and the in-memory indexes.
//! Every entry point runs after the WAL append, so a failure here is a programmer error or
//! corruption, never a client error, and the caller aborts so recovery replays the record.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const inverted_index = @import("zigstore").inverted_index;
const BPlusTree = @import("zigstore").BPlusTree;
const changeset = @import("../changeset.zig");
const Directory = @import("../directory.zig").Directory;
const operations = @import("../operations/operations.zig");
const depth_max = @import("../operations/operations_shared.zig").depth_max;

const apply_link = @import("apply_link.zig");
const apply_category = @import("apply_category.zig");
const apply_repair = @import("apply_repair.zig");

pub fn apply(db: *Directory, change_set: *const changeset.ChangeSet) !void {
    try apply_to_trees(db, change_set);
    try db.facts.observe(db.io, db.allocator, change_set);
}

fn apply_to_trees(db: *Directory, change_set: *const changeset.ChangeSet) !void {
    return switch (change_set.*) {
        .link_inserted => |*effect| apply_link.apply_link_inserted(db, effect),
        .link_deleted => |*effect| apply_link.apply_link_deleted(db, effect),
        .link_text_updated => |*effect| apply_link.apply_link_text_updated(db, effect),
        .link_recategorized => |*effect| apply_link.apply_link_recategorized(db, effect),
        .link_vectors_put => |*effect| apply_link.apply_link_vectors_put(db, effect),
        .link_entities_put => |effect| apply_link.apply_link_entities_put(db, effect),
        .category_vectors_put => |*effect| apply_category.apply_category_vectors_put(db, effect),
        .category_inserted => |*effect| apply_category.apply_category_inserted(db, effect),
        .category_deleted => |*effect| apply_category.apply_category_deleted(db, effect),
        .category_text_updated => |*effect| apply_category.apply_category_text_updated(db, effect),
        .category_renamed => |*effect| apply_category.apply_category_renamed(db, effect),
        .category_moved => |*effect| apply_category.apply_category_moved(db, effect),
        .slug_path_repair_chunk => |*effect| apply_repair.apply_slug_path_repair_chunk(db, effect),
        .slug_path_repair_complete => |effect| apply_repair.apply_slug_path_repair_complete(
            db,
            effect,
        ),
    };
}

pub const DirectField = enum { link_count, child_count };

fn apply_delta_u64(base: u64, delta: i64) u64 {
    if (delta >= 0) {
        const result = base +| @as(u64, @intCast(delta));
        assert(result >= base);
        return result;
    }
    const result = base -| @abs(delta);
    assert(result <= base);
    return result;
}

fn apply_delta_u32(base: u32, delta: i64) u32 {
    const limit: i64 = std.math.maxInt(u32);
    const clamped = std.math.clamp(delta, -limit, limit);
    assert(clamped >= -limit);
    assert(clamped <= limit);
    if (clamped >= 0) {
        const result = base +| @as(u32, @intCast(clamped));
        assert(result >= base);
        return result;
    }
    const result = base -| @as(u32, @intCast(@abs(clamped)));
    assert(result <= base);
    return result;
}

pub fn cascade_ancestor_counts(
    db: *Directory,
    updates: []const changeset.AncestorUpdate,
    direct_target_id: u64,
    comptime direct_field: DirectField,
    comptime increment: bool,
) !void {
    assert(updates.len <= depth_max);
    if (direct_target_id == 0) assert(updates.len == 0);

    const now = db.now_seconds();
    const field_name = comptime @tagName(direct_field);
    for (updates) |update| {
        assert(update.cat_id != 0);
        var category = (try operations.get_category(db, update.cat_id)) orelse continue;
        category.link_count_subtree = apply_delta_u64(
            category.link_count_subtree,
            update.link_count_subtree_delta,
        );
        category.child_count_subtree = apply_delta_u32(
            category.child_count_subtree,
            update.child_count_subtree_delta,
        );
        category.updated_at = now;
        if (category.id == direct_target_id) {
            if (increment) {
                @field(category, field_name) +|= 1;
            } else if (@field(category, field_name) > 0) {
                @field(category, field_name) -= 1;
            }
        }
        const ancestor_key = codec.encodeU64(update.cat_id);
        try db.memtable_categories_by_id().put(&ancestor_key, std.mem.asBytes(&category));
        assert(db.memtable_categories_by_id().get(&ancestor_key) != .deleted);
    }
}

// A token key is the token text followed by the big-endian id, so one buffer sized by the
// tokenizer's maximum covers every key without a heap allocation on the write path.
const token_key_len_max: usize = inverted_index.MAX_TOKEN_LEN + 8;

pub fn write_tokens(
    tree: *BPlusTree,
    tokens: []const changeset.Token,
    id: u64,
    comptime mode: enum { insert, delete },
) !void {
    assert(id != 0);
    for (tokens) |token| {
        assert(token.text.len > 0);
        assert(token.text.len <= inverted_index.MAX_TOKEN_LEN);
        var key_buffer: [token_key_len_max]u8 = undefined;
        const key_len = token.text.len + 8;
        @memcpy(key_buffer[0..token.text.len], token.text);
        const id_be = codec.encodeU64(id);
        @memcpy(key_buffer[token.text.len..][0..8], &id_be);
        switch (mode) {
            .insert => try tree.insert(key_buffer[0..key_len], &.{}),
            .delete => _ = try tree.delete(key_buffer[0..key_len]),
        }
    }
}
