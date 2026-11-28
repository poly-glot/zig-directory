//! Applies a committed ChangeSet to the store: trees, memtables and the in-memory indexes.
//! Every entry point runs after the WAL append, so a failure here is a programmer error or
//! corruption, never a client error, and the caller aborts so recovery replays the record.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const codec = zigstore.codec;
const inverted_index = zigstore.inverted_index;
const BPlusTree = zigstore.BPlusTree;
const schema = @import("../schema.zig");
const entities = @import("../facts/entities.zig");
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

/// Applies one chain of ancestor deltas. `moved` is what the change adds to (when `increment`)
/// or takes from every visited ancestor's per-status counters: the change's link for a link
/// write, the moved or deleted category's own counters for a subtree write. The same direction
/// governs the direct count, so one flag says which way the whole change goes.
pub fn cascade_ancestor_counts(
    db: *Directory,
    updates: []const changeset.AncestorUpdate,
    direct_target_id: u64,
    comptime direct_field: DirectField,
    comptime increment: bool,
    moved: schema.SubtreeStatusCounts,
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
        shift_status_counts(&category, moved, increment);
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

fn shift_status_counts(
    category: *schema.Category,
    moved: schema.SubtreeStatusCounts,
    increment: bool,
) void {
    const before = schema.SubtreeStatusCounts.of_subtree(category);
    if (increment) {
        category.link_count_subtree_approved +|= moved.approved;
        category.link_count_subtree_pending +|= moved.pending;
        assert(category.link_count_subtree_approved >= before.approved);
    } else {
        category.link_count_subtree_approved -|= moved.approved;
        category.link_count_subtree_pending -|= moved.pending;
        assert(category.link_count_subtree_approved <= before.approved);
    }
}

/// A status change leaves every count but the per-status ones alone, so its change set carries
/// no ancestor chain: the chain is walked here, from the link's category up, the way
/// `collect_ancestor_updates` walks it on the commit path. Replay walks the same chain because
/// it applies entries in commit order over the tree they were committed against; a replay over
/// pages a pressure flush wrote ahead is recounted on boot (`Directory.recover`).
pub fn cascade_status_change(
    db: *Directory,
    category_id: u64,
    change: struct { removed: schema.SubtreeStatusCounts, added: schema.SubtreeStatusCounts },
) !void {
    assert(change.removed.approved + change.removed.pending <= 1);
    assert(change.added.approved + change.added.pending <= 1);
    const now = db.now_seconds();
    var current_id = category_id;
    for (0..depth_max) |_| {
        if (current_id == 0) break;
        var category = (try operations.get_category(db, current_id)) orelse break;
        assert(category.id == current_id);
        shift_status_counts(&category, change.removed, false);
        shift_status_counts(&category, change.added, true);
        category.updated_at = now;
        const key = codec.encodeU64(current_id);
        try db.memtable_categories_by_id().put(&key, std.mem.asBytes(&category));
        current_id = category.parent_id;
    }
}

// A token key is the token text followed by the big-endian id, so one buffer sized by the
// tokenizer's maximum covers every key without a heap allocation on the write path.
const token_key_len_max: usize = inverted_index.MAX_TOKEN_LEN + 8;

// The engine refuses an over-long key or value only here, after the WAL append, where the
// refusal fails every replay too. Every key and value apply writes but the slug path has its
// length fixed by a record type or capped by the tokenizer, so it fits by construction; the
// slug path is checked on the commit path by `changeset.ensure_keys_fit`.
comptime {
    assert(token_key_len_max <= zigstore.MAX_KEY_LEN);
    assert(@FieldType(schema.Category, "slug").capacity <= zigstore.MAX_KEY_LEN);
    assert(@sizeOf(schema.Category) <= zigstore.MAX_VALUE_LEN);
    assert(@sizeOf(schema.Link) <= zigstore.MAX_VALUE_LEN);
    assert(@sizeOf(schema.RepairTask) <= zigstore.MAX_VALUE_LEN);
    assert(@sizeOf(schema.LinkVector) <= zigstore.MAX_VALUE_LEN);
    assert(@sizeOf(schema.StoredVector) <= zigstore.MAX_VALUE_LEN);
    assert(entities.encoded_len_max <= zigstore.MAX_VALUE_LEN);
}

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
