const std = @import("std");
const types = @import("types.zig");

pub const Op = enum(u8) {
    link_inserted = 1,
    link_deleted = 2,
    link_text_updated = 3,
    link_recategorized = 4,
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
    new_link_count_subtree: u64,
    new_child_count_subtree: u32,
};

pub const SlugPathSwap = struct {
    old_path: []const u8,
    new_path: []const u8,
    cat_id: u64,
};

/// Inline payload of the ChangeSet rename/move effects when the
/// subtree exceeds the threshold and the cleanup is deferred to the
/// repair_worker. `seq == 0` is the sentinel for "no enqueue".
pub const EnqueueOnApply = struct {
    seq: u64 = 0,
    op: types.RepairOp = .renamed_slug,
    old_slug_prefix: []const u8 = &.{},
    created_at: i64 = 0,
};

pub const LinkInsertEffect = struct {
    link: types.Link,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
};

pub const LinkDeleteEffect = struct {
    link: types.Link,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
};

pub const LinkTextUpdateEffect = struct {
    old_link: types.Link,
    new_link: types.Link,
    old_tokens: []const Token,
    new_tokens: []const Token,
    // Counts unchanged on a text edit (category_id is unchanged)
};

pub const LinkRecatEffect = struct {
    link: types.Link, // post-recat (new category_id)
    old_category_id: u64,
    old_chain_updates: []const AncestorUpdate,
    new_chain_updates: []const AncestorUpdate,
};

pub const CategoryInsertEffect = struct {
    cat: types.Category,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
    slug_path: []const u8, // canonical full path
    is_shallowest_for_slug: bool, // controls slug_only insert
};

pub const CategoryDeleteEffect = struct {
    cat: types.Category,
    ancestor_updates: []const AncestorUpdate,
    tokens: []const Token,
    slug_path: []const u8,
};

pub const CategoryTextUpdateEffect = struct {
    old_cat: types.Category,
    new_cat: types.Category,
    old_tokens: []const Token,
    new_tokens: []const Token,
};

pub const CategoryRenameEffect = struct {
    old_cat: types.Category,
    new_cat: types.Category, // updated slug
    old_slug_path: []const u8,
    new_slug_path: []const u8,
    /// Old/new slug-path pairs for every descendant. Empty when
    /// above_threshold (cleanup deferred to repair_worker).
    descendant_swaps: []const SlugPathSwap,
    above_threshold: bool,
    /// Sentinel-encoded: enqueue.seq == 0 means no queue write.
    enqueue: EnqueueOnApply,
};

pub const CategoryMoveEffect = struct {
    cat: types.Category, // post-move state
    old_parent_id: u64,
    new_parent_id: u64,
    old_chain_updates: []const AncestorUpdate,
    new_chain_updates: []const AncestorUpdate,
    old_slug_path: []const u8,
    new_slug_path: []const u8,
    link_subtree_delta: u64, // for logging / verification
    child_subtree_delta: u32,
    /// Old/new slug-path pairs for every descendant. Empty when
    /// above_threshold (cleanup deferred to repair_worker).
    descendant_swaps: []const SlugPathSwap,
    above_threshold: bool,
    /// Sentinel-encoded: enqueue.seq == 0 means no queue write.
    enqueue: EnqueueOnApply,
};

/// Emitted by the background repair_worker. Carries one chunk of
/// descendant slug-path swaps for a queued task. Multiple chunks may
/// be emitted per task, each in its own commit, so per-chunk progress
/// is WAL-durable.
pub const SlugPathRepairChunkEffect = struct {
    task_seq: u64,
    swaps: []const SlugPathSwap,
};

/// Emitted by the worker after the final chunk completes; deletes the
/// queue entry by seq. Sharing a commit with the final chunk effect is
/// an optional optimisation deferred to a follow-up.
pub const RepairTaskCompleteEffect = struct {
    seq: u64,
};

pub const ChangeSet = union(Op) {
    link_inserted: LinkInsertEffect,
    link_deleted: LinkDeleteEffect,
    link_text_updated: LinkTextUpdateEffect,
    link_recategorized: LinkRecatEffect,
    category_inserted: CategoryInsertEffect,
    category_deleted: CategoryDeleteEffect,
    category_text_updated: CategoryTextUpdateEffect,
    category_renamed: CategoryRenameEffect,
    category_moved: CategoryMoveEffect,
    slug_path_repair_chunk: SlugPathRepairChunkEffect,
    slug_path_repair_complete: RepairTaskCompleteEffect,
};

pub const SCHEMA_VERSION: u8 = 1;

pub const EncodeError = error{
    OutOfMemory,
    StringTooLong,
};

pub const DecodeError = error{
    BufferTooShort,
    UnknownOpTag,
    UnsupportedSchemaVersion,
    InvalidTokenField,
    InvalidLinkSize,
    InvalidCategorySize,
    OutOfMemory,
};

// `union(Op)` already enforces tag/variant name parity at compile time.
// The wire format is driven from struct field layout: the field order in
// each *Effect struct above IS the order of bytes on disk. Re-ordering
// fields breaks WAL replay — guarded by the round-trip tests below.

/// Encode a ChangeSet to a freshly-allocated byte buffer.
/// Format: [1B version][1B op_tag][payload bytes]
/// Caller frees the returned slice.
pub fn encode(allocator: std.mem.Allocator, cs: ChangeSet) ![]u8 {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    try buf.append(allocator, SCHEMA_VERSION);
    try buf.append(allocator, @intFromEnum(std.meta.activeTag(cs)));

    inline for (@typeInfo(ChangeSet).@"union".fields) |uf| {
        if (std.mem.eql(u8, uf.name, @tagName(std.meta.activeTag(cs)))) {
            try encodeStruct(allocator, &buf, @field(cs, uf.name));
        }
    }

    return try buf.toOwnedSlice(allocator);
}

/// Decode a byte buffer to a ChangeSet. The returned ChangeSet's
/// variable-length fields (slices) are allocated from `arena`.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !ChangeSet {
    if (bytes.len < 2) return DecodeError.BufferTooShort;
    if (bytes[0] != SCHEMA_VERSION) return DecodeError.UnsupportedSchemaVersion;
    const tag = std.meta.intToEnum(Op, bytes[1]) catch return DecodeError.UnknownOpTag;

    var cur: usize = 2;
    inline for (@typeInfo(ChangeSet).@"union".fields) |uf| {
        if (@field(Op, uf.name) == tag) {
            const variant = try decodeStruct(arena, uf.type, bytes, &cur);
            return @unionInit(ChangeSet, uf.name, variant);
        }
    }
    unreachable; // tag is a valid Op, so one branch always matches
}

// ── Comptime field codec ──
//
// Wire format per type:
//   integer    → big-endian, fixed width
//   bool       → 1 byte (0 / 1)
//   enum       → 1 byte tag
//   extern T   → @sizeOf(T) raw bytes (POD memcpy)
//   struct T   → fields encoded in declaration order
//   []u8       → [u32 BE len][bytes]
//   []T (T≠u8) → [u32 BE len][T encoded × len]

fn encodeStruct(a: std.mem.Allocator, buf: *std.ArrayList(u8), value: anytype) EncodeError!void {
    inline for (@typeInfo(@TypeOf(value)).@"struct".fields) |f| {
        try encodeField(a, buf, @field(value, f.name));
    }
}

fn encodeField(a: std.mem.Allocator, buf: *std.ArrayList(u8), value: anytype) EncodeError!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => |info| {
            var b: [@divExact(info.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &b, value, .big);
            try buf.appendSlice(a, &b);
        },
        .bool => try buf.append(a, if (value) 1 else 0),
        .@"enum" => try buf.append(a, @intFromEnum(value)),
        .@"struct" => |s| {
            if (s.layout == .@"extern") {
                try buf.appendSlice(a, std.mem.asBytes(&value));
            } else try encodeStruct(a, buf, value);
        },
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            if (value.len > std.math.maxInt(u32)) return EncodeError.StringTooLong;
            try encodeField(a, buf, @as(u32, @intCast(value.len)));
            if (p.child == u8) {
                try buf.appendSlice(a, value);
            } else for (value) |item| try encodeField(a, buf, item);
        },
        else => @compileError("changeset: unsupported field type " ++ @typeName(T)),
    }
}

fn decodeStruct(arena: std.mem.Allocator, comptime T: type, bytes: []const u8, cur: *usize) DecodeError!T {
    var out: T = undefined;
    inline for (@typeInfo(T).@"struct".fields) |f| {
        @field(out, f.name) = try decodeField(arena, f.type, bytes, cur);
    }
    return out;
}

fn decodeField(arena: std.mem.Allocator, comptime T: type, bytes: []const u8, cur: *usize) DecodeError!T {
    switch (@typeInfo(T)) {
        .int => |info| {
            const sz = @divExact(info.bits, 8);
            if (cur.* + sz > bytes.len) return DecodeError.BufferTooShort;
            const v = std.mem.readInt(T, bytes[cur.*..][0..sz], .big);
            cur.* += sz;
            return v;
        },
        .bool => {
            if (cur.* >= bytes.len) return DecodeError.BufferTooShort;
            const v = bytes[cur.*] != 0;
            cur.* += 1;
            return v;
        },
        .@"enum" => {
            if (cur.* >= bytes.len) return DecodeError.BufferTooShort;
            const v = std.meta.intToEnum(T, bytes[cur.*]) catch return DecodeError.InvalidTokenField;
            cur.* += 1;
            return v;
        },
        .@"struct" => |s| {
            if (s.layout == .@"extern") {
                if (cur.* + @sizeOf(T) > bytes.len) return DecodeError.BufferTooShort;
                const v = std.mem.bytesToValue(T, bytes[cur.*..][0..@sizeOf(T)]);
                cur.* += @sizeOf(T);
                return v;
            } else return try decodeStruct(arena, T, bytes, cur);
        },
        .pointer => |p| {
            comptime std.debug.assert(p.size == .slice);
            const n = try decodeField(arena, u32, bytes, cur);
            if (p.child == u8) {
                if (cur.* + n > bytes.len) return DecodeError.BufferTooShort;
                const out = try arena.dupe(u8, bytes[cur.* .. cur.* + n]);
                cur.* += n;
                return out;
            }
            const out = try arena.alloc(p.child, n);
            for (out) |*item| item.* = try decodeField(arena, p.child, bytes, cur);
            return out;
        },
        else => @compileError("changeset: unsupported field type " ++ @typeName(T)),
    }
}

test "ChangeSet variant tags match Op enum" {
    const cs = ChangeSet{ .link_inserted = undefined };
    try std.testing.expectEqual(Op.link_inserted, std.meta.activeTag(cs));
}

test "encode/decode roundtrip — link_inserted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const link = types.Link{
        .id = 42,
        .category_id = 7,
        .url = types.FixedString(64).fromSlice("https://example.com"),
        .title = types.FixedString(128).fromSlice("Example"),
        .description = types.FixedString(256).fromSlice("desc"),
        .sort_order = 0,
        .created_at = 1000,
        .updated_at = 1000,
    };
    const ancestors = try arena_alloc.dupe(AncestorUpdate, &.{
        .{ .cat_id = 7, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = 1, .new_link_count_subtree = 1, .new_child_count_subtree = 1 },
    });
    const tokens = try arena_alloc.dupe(Token, &.{
        .{ .text = try arena_alloc.dupe(u8, "example"), .field = .title },
        .{ .text = try arena_alloc.dupe(u8, "com"), .field = .url },
    });
    const cs = ChangeSet{ .link_inserted = .{
        .link = link,
        .ancestor_updates = ancestors,
        .tokens = tokens,
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);

    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_inserted, std.meta.activeTag(decoded));
    const e = decoded.link_inserted;
    try std.testing.expectEqual(@as(u64, 42), e.link.id);
    try std.testing.expectEqual(@as(usize, 2), e.ancestor_updates.len);
    try std.testing.expectEqual(@as(u64, 7), e.ancestor_updates[0].cat_id);
    try std.testing.expectEqual(@as(usize, 2), e.tokens.len);
    try std.testing.expectEqualStrings("example", e.tokens[0].text);
}

test "encode/decode roundtrip — link_deleted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const link = types.Link{ .id = 99, .category_id = 5 };
    const ancestors = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 5, .new_link_count_subtree = 0, .new_child_count_subtree = 0 },
    });
    const tokens = try a.dupe(Token, &.{
        .{ .text = try a.dupe(u8, "gone"), .field = .title },
    });
    const cs = ChangeSet{ .link_deleted = .{ .link = link, .ancestor_updates = ancestors, .tokens = tokens } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_deleted, std.meta.activeTag(decoded));
    try std.testing.expectEqual(@as(u64, 99), decoded.link_deleted.link.id);
    try std.testing.expectEqual(@as(usize, 1), decoded.link_deleted.ancestor_updates.len);
    try std.testing.expectEqualStrings("gone", decoded.link_deleted.tokens[0].text);
}

test "encode/decode roundtrip — link_text_updated" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old_link = types.Link{ .id = 11, .title = types.FixedString(128).fromSlice("Old") };
    const new_link = types.Link{ .id = 11, .title = types.FixedString(128).fromSlice("New") };
    const old_tokens = try a.dupe(Token, &.{.{ .text = try a.dupe(u8, "old"), .field = .title }});
    const new_tokens = try a.dupe(Token, &.{.{ .text = try a.dupe(u8, "new"), .field = .title }});
    const cs = ChangeSet{ .link_text_updated = .{
        .old_link = old_link,
        .new_link = new_link,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_text_updated, std.meta.activeTag(decoded));
    const e = decoded.link_text_updated;
    try std.testing.expectEqual(@as(u64, 11), e.old_link.id);
    try std.testing.expectEqualStrings("Old", e.old_link.title.slice());
    try std.testing.expectEqualStrings("New", e.new_link.title.slice());
    try std.testing.expectEqualStrings("old", e.old_tokens[0].text);
    try std.testing.expectEqualStrings("new", e.new_tokens[0].text);
}

test "encode/decode roundtrip — link_recategorized" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const link = types.Link{ .id = 7, .category_id = 22 };
    const old_chain = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 5, .new_link_count_subtree = 3, .new_child_count_subtree = 1 },
    });
    const new_chain = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 22, .new_link_count_subtree = 1, .new_child_count_subtree = 0 },
        .{ .cat_id = 1, .new_link_count_subtree = 5, .new_child_count_subtree = 2 },
    });
    const cs = ChangeSet{ .link_recategorized = .{
        .link = link,
        .old_category_id = 5,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.link_recategorized, std.meta.activeTag(decoded));
    const e = decoded.link_recategorized;
    try std.testing.expectEqual(@as(u64, 22), e.link.category_id);
    try std.testing.expectEqual(@as(u64, 5), e.old_category_id);
    try std.testing.expectEqual(@as(usize, 1), e.old_chain_updates.len);
    try std.testing.expectEqual(@as(usize, 2), e.new_chain_updates.len);
}

test "encode/decode roundtrip — category_inserted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cat = types.Category{
        .id = 50,
        .parent_id = 1,
        .name = types.FixedString(64).fromSlice("Books"),
        .slug = types.FixedString(128).fromSlice("books"),
    };
    const ancestors = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 1, .new_link_count_subtree = 0, .new_child_count_subtree = 1 },
    });
    const tokens = try a.dupe(Token, &.{.{ .text = try a.dupe(u8, "books"), .field = .slug }});
    const cs = ChangeSet{ .category_inserted = .{
        .cat = cat,
        .ancestor_updates = ancestors,
        .tokens = tokens,
        .slug_path = try a.dupe(u8, "/books"),
        .is_shallowest_for_slug = true,
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_inserted, std.meta.activeTag(decoded));
    const e = decoded.category_inserted;
    try std.testing.expectEqual(@as(u64, 50), e.cat.id);
    try std.testing.expectEqualStrings("/books", e.slug_path);
    try std.testing.expectEqual(true, e.is_shallowest_for_slug);
    try std.testing.expectEqualStrings("books", e.tokens[0].text);
}

test "encode/decode roundtrip — category_deleted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cat = types.Category{ .id = 60, .parent_id = 1 };
    const ancestors = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 1, .new_link_count_subtree = 0, .new_child_count_subtree = 0 },
    });
    const tokens = try a.dupe(Token, &.{.{ .text = try a.dupe(u8, "old"), .field = .name }});
    const cs = ChangeSet{ .category_deleted = .{
        .cat = cat,
        .ancestor_updates = ancestors,
        .tokens = tokens,
        .slug_path = try a.dupe(u8, "/old"),
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_deleted, std.meta.activeTag(decoded));
    const e = decoded.category_deleted;
    try std.testing.expectEqual(@as(u64, 60), e.cat.id);
    try std.testing.expectEqualStrings("/old", e.slug_path);
    try std.testing.expectEqual(@as(usize, 1), e.tokens.len);
}

test "encode/decode roundtrip — category_text_updated" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old_cat = types.Category{ .id = 70, .description = types.FixedString(1024).fromSlice("Old desc") };
    const new_cat = types.Category{ .id = 70, .description = types.FixedString(1024).fromSlice("New desc") };
    const old_tokens = try a.dupe(Token, &.{.{ .text = try a.dupe(u8, "old"), .field = .desc }});
    const new_tokens = try a.dupe(Token, &.{.{ .text = try a.dupe(u8, "new"), .field = .desc }});
    const cs = ChangeSet{ .category_text_updated = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_tokens = old_tokens,
        .new_tokens = new_tokens,
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_text_updated, std.meta.activeTag(decoded));
    const e = decoded.category_text_updated;
    try std.testing.expectEqualStrings("Old desc", e.old_cat.description.slice());
    try std.testing.expectEqualStrings("New desc", e.new_cat.description.slice());
    try std.testing.expectEqualStrings("new", e.new_tokens[0].text);
}

test "encode/decode roundtrip — category_renamed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old_cat = types.Category{ .id = 80, .slug = types.FixedString(128).fromSlice("old") };
    const new_cat = types.Category{ .id = 80, .slug = types.FixedString(128).fromSlice("new") };
    const cs = ChangeSet{ .category_renamed = .{
        .old_cat = old_cat,
        .new_cat = new_cat,
        .old_slug_path = try a.dupe(u8, "/parent/old"),
        .new_slug_path = try a.dupe(u8, "/parent/new"),
        .descendant_swaps = &.{},
        .above_threshold = false,
        .enqueue = .{},
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_renamed, std.meta.activeTag(decoded));
    const e = decoded.category_renamed;
    try std.testing.expectEqualStrings("old", e.old_cat.slug.slice());
    try std.testing.expectEqualStrings("new", e.new_cat.slug.slice());
    try std.testing.expectEqualStrings("/parent/old", e.old_slug_path);
    try std.testing.expectEqualStrings("/parent/new", e.new_slug_path);
}

test "encode/decode roundtrip — category_moved" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cat = types.Category{ .id = 90, .parent_id = 200 };
    const old_chain = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 100, .new_link_count_subtree = 4, .new_child_count_subtree = 2 },
    });
    const new_chain = try a.dupe(AncestorUpdate, &.{
        .{ .cat_id = 200, .new_link_count_subtree = 7, .new_child_count_subtree = 3 },
        .{ .cat_id = 1, .new_link_count_subtree = 11, .new_child_count_subtree = 5 },
    });
    const cs = ChangeSet{ .category_moved = .{
        .cat = cat,
        .old_parent_id = 100,
        .new_parent_id = 200,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
        .old_slug_path = try a.dupe(u8, "/a/x"),
        .new_slug_path = try a.dupe(u8, "/b/x"),
        .link_subtree_delta = 3,
        .child_subtree_delta = 1,
        .descendant_swaps = &.{},
        .above_threshold = false,
        .enqueue = .{},
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);

    try std.testing.expectEqual(Op.category_moved, std.meta.activeTag(decoded));
    const e = decoded.category_moved;
    try std.testing.expectEqual(@as(u64, 100), e.old_parent_id);
    try std.testing.expectEqual(@as(u64, 200), e.new_parent_id);
    try std.testing.expectEqual(@as(usize, 2), e.new_chain_updates.len);
    try std.testing.expectEqualStrings("/a/x", e.old_slug_path);
    try std.testing.expectEqualStrings("/b/x", e.new_slug_path);
    try std.testing.expectEqual(@as(u64, 3), e.link_subtree_delta);
    try std.testing.expectEqual(@as(u32, 1), e.child_subtree_delta);
}

test "encode/decode roundtrip — category_renamed with descendant_swaps" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const swaps = try aa.dupe(SlugPathSwap, &.{
        .{ .old_path = try aa.dupe(u8, "top/old/a"), .new_path = try aa.dupe(u8, "top/new/a"), .cat_id = 100 },
        .{ .old_path = try aa.dupe(u8, "top/old/b"), .new_path = try aa.dupe(u8, "top/new/b"), .cat_id = 101 },
    });
    const cs = ChangeSet{ .category_renamed = .{
        .old_cat = .{},
        .new_cat = .{},
        .old_slug_path = try aa.dupe(u8, "top/old"),
        .new_slug_path = try aa.dupe(u8, "top/new"),
        .descendant_swaps = swaps,
        .above_threshold = false,
        .enqueue = .{ .seq = 0, .op = .renamed_slug, .old_slug_prefix = &.{}, .created_at = 0 },
    } };

    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    try std.testing.expectEqual(Op.category_renamed, std.meta.activeTag(decoded));
    const e = decoded.category_renamed;
    try std.testing.expectEqual(@as(usize, 2), e.descendant_swaps.len);
    try std.testing.expectEqualStrings("top/old/a", e.descendant_swaps[0].old_path);
    try std.testing.expectEqualStrings("top/new/a", e.descendant_swaps[0].new_path);
    try std.testing.expectEqual(@as(u64, 100), e.descendant_swaps[0].cat_id);
    try std.testing.expect(!e.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), e.enqueue.seq);
}

test "encode/decode roundtrip — category_renamed with enqueue (above_threshold)" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const cs = ChangeSet{ .category_renamed = .{
        .old_cat = .{},
        .new_cat = .{},
        .old_slug_path = try aa.dupe(u8, "top/regional"),
        .new_slug_path = try aa.dupe(u8, "top/worldwide"),
        .descendant_swaps = &.{},
        .above_threshold = true,
        .enqueue = .{
            .seq = 42,
            .op = .renamed_slug,
            .old_slug_prefix = try aa.dupe(u8, "top/regional"),
            .created_at = 1714838400000,
        },
    } };
    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    const e = decoded.category_renamed;
    try std.testing.expect(e.above_threshold);
    try std.testing.expectEqual(@as(u64, 42), e.enqueue.seq);
    try std.testing.expectEqual(@as(usize, 0), e.descendant_swaps.len);
    try std.testing.expectEqualStrings("top/regional", e.enqueue.old_slug_prefix);
}

test "encode/decode roundtrip — slug_path_repair_chunk" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const swaps = try aa.dupe(SlugPathSwap, &.{
        .{ .old_path = try aa.dupe(u8, "old/a"), .new_path = try aa.dupe(u8, "new/a"), .cat_id = 1 },
        .{ .old_path = try aa.dupe(u8, "old/b"), .new_path = try aa.dupe(u8, "new/b"), .cat_id = 2 },
    });
    const cs = ChangeSet{ .slug_path_repair_chunk = .{
        .task_seq = 7,
        .swaps = swaps,
    } };
    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    try std.testing.expectEqual(Op.slug_path_repair_chunk, std.meta.activeTag(decoded));
    const e = decoded.slug_path_repair_chunk;
    try std.testing.expectEqual(@as(u64, 7), e.task_seq);
    try std.testing.expectEqual(@as(usize, 2), e.swaps.len);
    try std.testing.expectEqualStrings("old/a", e.swaps[0].old_path);
    try std.testing.expectEqualStrings("new/a", e.swaps[0].new_path);
    try std.testing.expectEqual(@as(u64, 1), e.swaps[0].cat_id);
}

test "encode/decode roundtrip — slug_path_repair_complete" {
    const allocator = std.testing.allocator;
    const cs = ChangeSet{ .slug_path_repair_complete = .{ .seq = 99 } };
    const encoded = try encode(allocator, cs);
    defer allocator.free(encoded);
    var arena2 = std.heap.ArenaAllocator.init(allocator);
    defer arena2.deinit();
    const decoded = try decode(arena2.allocator(), encoded);
    try std.testing.expectEqual(Op.slug_path_repair_complete, std.meta.activeTag(decoded));
    try std.testing.expectEqual(@as(u64, 99), decoded.slug_path_repair_complete.seq);
}
