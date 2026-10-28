//! The ChangeSet is the unit of durability: every mutation is computed first, written to the
//! WAL as one record, then applied. The wire layout is a schema version byte, an Op byte and
//! the effect struct encoded field by field by wire_codec, so decode can route on the tag.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const wire_codec = @import("zigstore").wire_codec;
const schema = @import("schema.zig");
const test_support = @import("test_support.zig");

pub const Op = enum(u8) {
    link_inserted = 1,
    link_deleted = 2,
    link_text_updated = 3,
    link_recategorized = 4,
    link_vectors_put = 5,
    link_entities_put = 6,
    category_vectors_put = 7,
    category_inserted = 10,
    category_deleted = 11,
    category_text_updated = 12,
    category_renamed = 13,
    category_moved = 14,
    slug_path_repair_chunk = 20,
    slug_path_repair_complete = 21,
};

pub const Token = struct {
    text: []const u8,
    field: TokenField,
};

pub const TokenField = enum(u8) { title = 0, url = 1, desc = 2, name = 3, slug = 4 };

pub const AncestorUpdate = struct {
    cat_id: u64,
    link_count_subtree_delta: i64,
    child_count_subtree_delta: i64,
};

pub const SlugPathSwap = struct {
    old_path: []const u8,
    new_path: []const u8,
    cat_id: u64,
};

pub const EnqueueOnApply = struct {
    seq: u64 = 0,
    op: schema.RepairOp = .renamed_slug,
    old_slug_prefix: []const u8 = &.{},
    created_at: i64 = 0,
};

pub const LinkInsertEffect = struct {
    link: schema.Link,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
};

pub const LinkDeleteEffect = struct {
    link: schema.Link,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
};

pub const LinkTextUpdateEffect = struct {
    old_link: schema.Link,
    new_link: schema.Link,
    old_tokens: []const Token,
    new_tokens: []const Token,
};

pub const LinkRecatEffect = struct {
    link: schema.Link,
    old_category_id: u64,
    old_chain_updates: []const AncestorUpdate,
    new_chain_updates: []const AncestorUpdate,
};

pub const LinkEntitiesEntry = struct {
    link_id: u64,
    facts: []const u8,
};
pub const LinkEntitiesPutEffect = struct {
    entries: []const LinkEntitiesEntry,
};
pub const LinkVectorsPutEffect = struct {
    model: u64,
    vectors: []const schema.StoredVector,
};

pub const CategoryVectorsPutEffect = struct {
    model: u64,
    vectors: []const schema.StoredVector,
};

pub const CategoryInsertEffect = struct {
    cat: schema.Category,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
    slug_path: []const u8,
    is_shallowest_for_slug: bool,
};

pub const CategoryDeleteEffect = struct {
    cat: schema.Category,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
    slug_path: []const u8,
};

pub const CategoryTextUpdateEffect = struct {
    old_cat: schema.Category,
    new_cat: schema.Category,
    old_tokens: []const Token,
    new_tokens: []const Token,
};

pub const CategoryRenameEffect = struct {
    old_cat: schema.Category,
    new_cat: schema.Category,
    old_slug_path: []const u8,
    new_slug_path: []const u8,
    descendant_swaps: []const SlugPathSwap,
    above_threshold: bool,
    enqueue: EnqueueOnApply,
};

pub const CategoryMoveEffect = struct {
    cat: schema.Category,
    old_parent_id: u64,
    new_parent_id: u64,
    old_chain_updates: []const AncestorUpdate,
    new_chain_updates: []const AncestorUpdate,
    old_slug_path: []const u8,
    new_slug_path: []const u8,
    link_subtree_delta: u64,
    child_subtree_delta: u32,
    descendant_swaps: []const SlugPathSwap,
    above_threshold: bool,
    enqueue: EnqueueOnApply,
};

pub const SlugPathRepairChunkEffect = struct {
    task_seq: u64,
    swaps: []const SlugPathSwap,
};

pub const RepairTaskCompleteEffect = struct {
    seq: u64,
};

pub const ChangeSet = union(Op) {
    link_inserted: LinkInsertEffect,
    link_deleted: LinkDeleteEffect,
    link_text_updated: LinkTextUpdateEffect,
    link_recategorized: LinkRecatEffect,
    link_vectors_put: LinkVectorsPutEffect,
    link_entities_put: LinkEntitiesPutEffect,
    category_vectors_put: CategoryVectorsPutEffect,
    category_inserted: CategoryInsertEffect,
    category_deleted: CategoryDeleteEffect,
    category_text_updated: CategoryTextUpdateEffect,
    category_renamed: CategoryRenameEffect,
    category_moved: CategoryMoveEffect,
    slug_path_repair_chunk: SlugPathRepairChunkEffect,
    slug_path_repair_complete: RepairTaskCompleteEffect,
};

pub const schema_version: u8 = 1;

pub const changeset_op: u8 = 100;

pub const DecodeError = error{
    BufferTooShort,
    UnknownOpTag,
    UnsupportedSchemaVersion,
    OutOfMemory,
};

pub fn encode(allocator: std.mem.Allocator, change_set: ChangeSet) ![]u8 {
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(allocator);

    try buffer.append(allocator, schema_version);
    try buffer.append(allocator, @intFromEnum(std.meta.activeTag(change_set)));

    switch (change_set) {
        inline else => |effect| try wire_codec.encodeStruct(allocator, &buffer, effect),
    }

    assert(buffer.items.len >= 2);
    assert(buffer.items[0] == schema_version);
    assert(buffer.items[1] == @intFromEnum(std.meta.activeTag(change_set)));
    return try buffer.toOwnedSlice(allocator);
}

pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !ChangeSet {
    if (bytes.len < 2) return DecodeError.BufferTooShort;
    if (bytes[0] != schema_version) return DecodeError.UnsupportedSchemaVersion;
    const tag = std.enums.fromInt(Op, bytes[1]) orelse return DecodeError.UnknownOpTag;

    var cursor: usize = 2;
    switch (tag) {
        inline else => |op| {
            const variant = try wire_codec.decodeStruct(
                arena,
                @FieldType(ChangeSet, @tagName(op)),
                bytes,
                &cursor,
            );
            assert(cursor >= 2);
            assert(cursor <= bytes.len);
            return @unionInit(ChangeSet, @tagName(op), variant);
        },
    }
}

// The union's active tag is the Op byte encode writes, which is what decode routes on.
test "ChangeSet variant tags match Op enum" {
    const change_set = ChangeSet{ .link_inserted = undefined };
    try std.testing.expectEqual(Op.link_inserted, std.meta.activeTag(change_set));
}

// Round-trip a link insert with two ancestors and two tokens through encode and decode.
test "encode/decode roundtrip — link_inserted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link = test_support.link(.{
        .id = 42,
        .category_id = 7,
        .url = "https://example.com",
        .title = "Example",
        .description = "desc",
    });
    const ancestors = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 7, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = 1, .link_count_subtree_delta = 1, .child_count_subtree_delta = 1 },
    });
    const tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "example"), .field = .title },
        .{ .text = try arena_allocator.dupe(u8, "com"), .field = .url },
    });
    const change_set = ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_inserted, std.meta.activeTag(decoded));
    const effect = decoded.link_inserted;
    try std.testing.expectEqual(@as(u64, 42), effect.link.id);
    try std.testing.expectEqual(@as(usize, 2), effect.ancestor_updates.len);
    try std.testing.expectEqual(@as(u64, 7), effect.ancestor_updates[0].cat_id);
    try std.testing.expectEqual(@as(usize, 2), effect.tokens.len);
    try std.testing.expectEqualStrings("example", effect.tokens[0].text);
}

// Round-trip a link delete with one ancestor and one token.
test "encode/decode roundtrip — link_deleted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link = schema.Link{ .id = 99, .category_id = 5 };
    const ancestors = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 5, .link_count_subtree_delta = 0, .child_count_subtree_delta = 0 },
    });
    const tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "gone"), .field = .title },
    });
    const change_set = ChangeSet{ .link_deleted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_deleted, std.meta.activeTag(decoded));
    try std.testing.expectEqual(@as(u64, 99), decoded.link_deleted.link.id);
    try std.testing.expectEqual(@as(usize, 1), decoded.link_deleted.ancestor_updates.len);
    try std.testing.expectEqualStrings("gone", decoded.link_deleted.tokens[0].text);
}

// Round-trip old and new link records with their token lists.
test "encode/decode roundtrip — link_text_updated" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const old_link = schema.Link{ .id = 11, .title = codec.FixedString(128).fromSlice("Old") };
    const new_link = schema.Link{ .id = 11, .title = codec.FixedString(128).fromSlice("New") };
    const old_tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "old"), .field = .title },
    });
    const new_tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "new"), .field = .title },
    });
    const change_set = ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_text_updated, std.meta.activeTag(decoded));
    const effect = decoded.link_text_updated;
    try std.testing.expectEqual(@as(u64, 11), effect.old_link.id);
    try std.testing.expectEqualStrings("Old", effect.old_link.title.slice());
    try std.testing.expectEqualStrings("New", effect.new_link.title.slice());
    try std.testing.expectEqualStrings("old", effect.old_tokens[0].text);
    try std.testing.expectEqualStrings("new", effect.new_tokens[0].text);
}

// Round-trip a recategorize carrying both ancestor chains.
test "encode/decode roundtrip — link_recategorized" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const link = schema.Link{ .id = 7, .category_id = 22 };
    const old_chain = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 5, .link_count_subtree_delta = 3, .child_count_subtree_delta = 1 },
    });
    const new_chain = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 22, .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        .{ .cat_id = 1, .link_count_subtree_delta = 5, .child_count_subtree_delta = 2 },
    });
    const change_set = ChangeSet{ .link_recategorized = .{
        .link = link,
        .old_category_id = 5,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_recategorized, std.meta.activeTag(decoded));
    const effect = decoded.link_recategorized;
    try std.testing.expectEqual(@as(u64, 22), effect.link.category_id);
    try std.testing.expectEqual(@as(u64, 5), effect.old_category_id);
    try std.testing.expectEqual(@as(usize, 1), effect.old_chain_updates.len);
    try std.testing.expectEqual(@as(usize, 2), effect.new_chain_updates.len);
}

// Round-trip opaque entity fact bytes for two links.
test "encode/decode roundtrip — link_entities_put" {
    const allocator = std.testing.allocator;
    const change_set = ChangeSet{ .link_entities_put = .{ .entries = &.{
        .{ .link_id = 7, .facts = "\x01\x01\x00\x01PK\x00\x00" },
        .{ .link_id = 9, .facts = "\x01\x00\x00\x00\x00\x00" },
    } } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), encoded);

    try std.testing.expectEqual(Op.link_entities_put, std.meta.activeTag(decoded));
    const effect = decoded.link_entities_put;
    try std.testing.expectEqual(@as(usize, 2), effect.entries.len);
    try std.testing.expectEqual(@as(u64, 9), effect.entries[1].link_id);
    try std.testing.expectEqualSlices(u8, "\x01\x01\x00\x01PK\x00\x00", effect.entries[0].facts);
}

// Round-trip an int8 vector, checking the first and last lanes and the scale.
test "encode/decode roundtrip — link_vectors_put" {
    const allocator = std.testing.allocator;
    var vector = schema.StoredVector{ .id = 12, .scale = 0.25 };
    vector.values[0] = -127;
    vector.values[383] = 64;
    const change_set = ChangeSet{ .link_vectors_put = .{ .model = 0xB6E5, .vectors = &.{vector} } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), encoded);

    try std.testing.expectEqual(Op.link_vectors_put, std.meta.activeTag(decoded));
    const effect = decoded.link_vectors_put;
    try std.testing.expectEqual(@as(u64, 0xB6E5), effect.model);
    try std.testing.expectEqual(@as(usize, 1), effect.vectors.len);
    try std.testing.expectEqual(@as(u64, 12), effect.vectors[0].id);
    try std.testing.expectEqual(@as(f32, 0.25), effect.vectors[0].scale);
    try std.testing.expectEqual(@as(i8, -127), effect.vectors[0].values[0]);
    try std.testing.expectEqual(@as(i8, 64), effect.vectors[0].values[383]);
}

// Round-trip a category vector under the same wire shape as link vectors.
test "encode/decode roundtrip — category_vectors_put" {
    var vector = schema.StoredVector{ .id = 3_000, .scale = 0.5 };
    vector.values[7] = 101;
    const change_set = ChangeSet{ .category_vectors_put = .{
        .model = 0xB6E5,
        .vectors = &.{vector},
    } };

    const bytes = try encode(std.testing.allocator, change_set);
    defer std.testing.allocator.free(bytes);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const decoded = try decode(arena.allocator(), bytes);

    try std.testing.expectEqual(Op.category_vectors_put, std.meta.activeTag(decoded));
    const effect = decoded.category_vectors_put;
    try std.testing.expectEqual(@as(u64, 0xB6E5), effect.model);
    try std.testing.expectEqual(@as(usize, 1), effect.vectors.len);
    try std.testing.expectEqual(@as(u64, 3_000), effect.vectors[0].id);
    try std.testing.expectEqual(@as(f32, 0.5), effect.vectors[0].scale);
    try std.testing.expectEqual(@as(i8, 101), effect.vectors[0].values[7]);
}

// Round-trip a category insert with its slug path and shallowest flag.
test "encode/decode roundtrip — category_inserted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const category = schema.Category{
        .id = 50,
        .parent_id = 1,
        .name = codec.FixedString(64).fromSlice("Books"),
        .slug = codec.FixedString(128).fromSlice("books"),
    };
    const ancestors = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 1, .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
    });
    const tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "books"), .field = .slug },
    });
    const change_set = ChangeSet{ .category_inserted = .{
        .cat = category,
        .ancestor_updates = ancestors,
        .tokens = tokens,
        .slug_path = try arena_allocator.dupe(u8, "/books"),
        .is_shallowest_for_slug = true,
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_inserted, std.meta.activeTag(decoded));
    const effect = decoded.category_inserted;
    try std.testing.expectEqual(@as(u64, 50), effect.cat.id);
    try std.testing.expectEqualStrings("/books", effect.slug_path);
    try std.testing.expectEqual(true, effect.is_shallowest_for_slug);
    try std.testing.expectEqualStrings("books", effect.tokens[0].text);
}

// Round-trip a category delete with its slug path and token list.
test "encode/decode roundtrip — category_deleted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const category = schema.Category{ .id = 60, .parent_id = 1 };
    const ancestors = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 1, .link_count_subtree_delta = 0, .child_count_subtree_delta = 0 },
    });
    const tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "old"), .field = .name },
    });
    const change_set = ChangeSet{ .category_deleted = .{
        .cat = category,
        .ancestor_updates = ancestors,
        .tokens = tokens,
        .slug_path = try arena_allocator.dupe(u8, "/old"),
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_deleted, std.meta.activeTag(decoded));
    const effect = decoded.category_deleted;
    try std.testing.expectEqual(@as(u64, 60), effect.cat.id);
    try std.testing.expectEqualStrings("/old", effect.slug_path);
    try std.testing.expectEqual(@as(usize, 1), effect.tokens.len);
}

// Round-trip old and new category records with description tokens.
test "encode/decode roundtrip — category_text_updated" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const old_cat = schema.Category{
        .id = 70,
        .description = codec.FixedString(1024).fromSlice("Old desc"),
    };
    const new_cat = schema.Category{
        .id = 70,
        .description = codec.FixedString(1024).fromSlice("New desc"),
    };
    const old_tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "old"), .field = .desc },
    });
    const new_tokens = try arena_allocator.dupe(Token, &.{
        .{ .text = try arena_allocator.dupe(u8, "new"), .field = .desc },
    });
    const change_set = ChangeSet{ .category_text_updated = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_text_updated, std.meta.activeTag(decoded));
    const effect = decoded.category_text_updated;
    try std.testing.expectEqualStrings("Old desc", effect.old_cat.description.slice());
    try std.testing.expectEqualStrings("New desc", effect.new_cat.description.slice());
    try std.testing.expectEqualStrings("new", effect.new_tokens[0].text);
}

// Round-trip a rename with no descendant swaps and no enqueue.
test "encode/decode roundtrip — category_renamed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const old_cat = schema.Category{ .id = 80, .slug = codec.FixedString(128).fromSlice("old") };
    const new_cat = schema.Category{ .id = 80, .slug = codec.FixedString(128).fromSlice("new") };
    const change_set = ChangeSet{ .category_renamed = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_slug_path = try arena_allocator.dupe(u8, "/parent/old"),
        .new_slug_path = try arena_allocator.dupe(u8, "/parent/new"),
        .descendant_swaps = &.{},
        .above_threshold = false,
        .enqueue = .{},
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_renamed, std.meta.activeTag(decoded));
    const effect = decoded.category_renamed;
    try std.testing.expectEqualStrings("old", effect.old_cat.slug.slice());
    try std.testing.expectEqualStrings("new", effect.new_cat.slug.slice());
    try std.testing.expectEqualStrings("/parent/old", effect.old_slug_path);
    try std.testing.expectEqualStrings("/parent/new", effect.new_slug_path);
}

// Round-trip a move with both ancestor chains and subtree deltas.
test "encode/decode roundtrip — category_moved" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const category = schema.Category{ .id = 90, .parent_id = 200 };
    const old_chain = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 100, .link_count_subtree_delta = 4, .child_count_subtree_delta = 2 },
    });
    const new_chain = try arena_allocator.dupe(AncestorUpdate, &.{
        .{ .cat_id = 200, .link_count_subtree_delta = 7, .child_count_subtree_delta = 3 },
        .{ .cat_id = 1, .link_count_subtree_delta = 11, .child_count_subtree_delta = 5 },
    });
    const change_set = ChangeSet{ .category_moved = .{
        .cat = category,
        .old_parent_id = 100,
        .new_parent_id = 200,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
        .old_slug_path = try arena_allocator.dupe(u8, "/a/x"),
        .new_slug_path = try arena_allocator.dupe(u8, "/b/x"),
        .link_subtree_delta = 3,
        .child_subtree_delta = 1,
        .descendant_swaps = &.{},
        .above_threshold = false,
        .enqueue = .{},
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_moved, std.meta.activeTag(decoded));
    const effect = decoded.category_moved;
    try std.testing.expectEqual(@as(u64, 100), effect.old_parent_id);
    try std.testing.expectEqual(@as(u64, 200), effect.new_parent_id);
    try std.testing.expectEqual(@as(usize, 2), effect.new_chain_updates.len);
    try std.testing.expectEqualStrings("/a/x", effect.old_slug_path);
    try std.testing.expectEqualStrings("/b/x", effect.new_slug_path);
    try std.testing.expectEqual(@as(u64, 3), effect.link_subtree_delta);
    try std.testing.expectEqual(@as(u32, 1), effect.child_subtree_delta);
}

// Round-trip a rename whose descendant swaps were computed inline.
test "encode/decode roundtrip — category_renamed with descendant_swaps" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const swaps = try arena_allocator.dupe(SlugPathSwap, &.{
        .{
            .old_path = try arena_allocator.dupe(u8, "top/old/a"),
            .new_path = try arena_allocator.dupe(u8, "top/new/a"),
            .cat_id = 100,
        },
        .{
            .old_path = try arena_allocator.dupe(u8, "top/old/b"),
            .new_path = try arena_allocator.dupe(u8, "top/new/b"),
            .cat_id = 101,
        },
    });
    const change_set = ChangeSet{ .category_renamed = .{
        .old_cat = .{},
        .new_cat = .{},
        .old_slug_path = try arena_allocator.dupe(u8, "top/old"),
        .new_slug_path = try arena_allocator.dupe(u8, "top/new"),
        .descendant_swaps = swaps,
        .above_threshold = false,
        .enqueue = .{ .seq = 0, .op = .renamed_slug, .old_slug_prefix = &.{}, .created_at = 0 },
    } };

    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    try std.testing.expectEqual(Op.category_renamed, std.meta.activeTag(decoded));
    const effect = decoded.category_renamed;
    try std.testing.expectEqual(@as(usize, 2), effect.descendant_swaps.len);
    try std.testing.expectEqualStrings("top/old/a", effect.descendant_swaps[0].old_path);
    try std.testing.expectEqualStrings("top/new/a", effect.descendant_swaps[0].new_path);
    try std.testing.expectEqual(@as(u64, 100), effect.descendant_swaps[0].cat_id);
    try std.testing.expect(!effect.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), effect.enqueue.seq);
}

// Round-trip a rename above the inline threshold: no swaps, a populated enqueue.
test "encode/decode roundtrip — category_renamed with enqueue (above_threshold)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const change_set = ChangeSet{ .category_renamed = .{
        .old_cat = .{},
        .new_cat = .{},
        .old_slug_path = try arena_allocator.dupe(u8, "top/regional"),
        .new_slug_path = try arena_allocator.dupe(u8, "top/worldwide"),
        .descendant_swaps = &.{},
        .above_threshold = true,
        .enqueue = .{
            .seq = 42,
            .op = .renamed_slug,
            .old_slug_prefix = try arena_allocator.dupe(u8, "top/regional"),
            .created_at = 1714838400000,
        },
    } };
    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    const effect = decoded.category_renamed;
    try std.testing.expect(effect.above_threshold);
    try std.testing.expectEqual(@as(u64, 42), effect.enqueue.seq);
    try std.testing.expectEqual(@as(usize, 0), effect.descendant_swaps.len);
    try std.testing.expectEqualStrings("top/regional", effect.enqueue.old_slug_prefix);
}

// Round-trip a repair chunk of two swaps.
test "encode/decode roundtrip — slug_path_repair_chunk" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const swaps = try arena_allocator.dupe(SlugPathSwap, &.{
        .{
            .old_path = try arena_allocator.dupe(u8, "old/a"),
            .new_path = try arena_allocator.dupe(u8, "new/a"),
            .cat_id = 1,
        },
        .{
            .old_path = try arena_allocator.dupe(u8, "old/b"),
            .new_path = try arena_allocator.dupe(u8, "new/b"),
            .cat_id = 2,
        },
    });
    const change_set = ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = 7,
        .swaps = swaps,
    } };
    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    try std.testing.expectEqual(Op.slug_path_repair_chunk, std.meta.activeTag(decoded));
    const effect = decoded.slug_path_repair_chunk;
    try std.testing.expectEqual(@as(u64, 7), effect.task_seq);
    try std.testing.expectEqual(@as(usize, 2), effect.swaps.len);
    try std.testing.expectEqualStrings("old/a", effect.swaps[0].old_path);
    try std.testing.expectEqualStrings("new/a", effect.swaps[0].new_path);
    try std.testing.expectEqual(@as(u64, 1), effect.swaps[0].cat_id);
}

// Round-trip the one-field completion record.
test "encode/decode roundtrip — slug_path_repair_complete" {
    const allocator = std.testing.allocator;
    const change_set = ChangeSet{ .slug_path_repair_complete = .{ .seq = 99 } };
    const encoded = try encode(allocator, change_set);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    try std.testing.expectEqual(Op.slug_path_repair_complete, std.meta.activeTag(decoded));
    try std.testing.expectEqual(@as(u64, 99), decoded.slug_path_repair_complete.seq);
}

fn fuzz_decode_one(_: void, smith: *std.testing.Smith) anyerror!void {
    var input: [4096]u8 = undefined;
    const len = smith.slice(&input);
    assert(len <= input.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    _ = decode(arena.allocator(), input[0..len]) catch {};
}

// Decode must reject or accept arbitrary bytes without crashing or leaking.
test "fuzz: changeset.decode tolerates arbitrary bytes" {
    try std.testing.fuzz({}, fuzz_decode_one, .{
        .corpus = &.{
            &.{},
            &.{schema_version},
            &.{ schema_version, @intFromEnum(Op.link_inserted) },
            &.{ schema_version, @intFromEnum(Op.category_renamed) },
            &.{ schema_version, @intFromEnum(Op.category_renamed), 0xFF, 0xFF, 0xFF, 0xFF },
        },
    });
}
