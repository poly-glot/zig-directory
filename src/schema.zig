//! On-disk record layouts. Every record is an extern struct whose size, alignment and key
//! field offsets are pinned at compile time, because the store copies records straight from
//! the page cache to the wire; changing one is a store-format change.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const FixedString = codec.FixedString;
const CompositeKey = codec.CompositeKey;

pub const Category = extern struct {
    id: u64 = 0,
    parent_id: u64 = 0,
    name: FixedString(64) = .{},
    slug: FixedString(128) = .{},
    description: FixedString(1024) = .{},
    link_count: u32 = 0,
    child_count: u32 = 0,
    sort_order: u32 = 0,
    _pad0: u32 = 0,
    created_at: i64 = 0,
    updated_at: i64 = 0,

    link_count_subtree: u64 = 0,

    child_count_subtree: u32 = 0,

    flags: u32 = 0,
};

comptime {
    if (@sizeOf(Category) == 0) @compileError("Category must be non-zero size");
    if (@sizeOf(Category) != 1288)
        @compileError("Category size mismatch: got " ++ std.fmt.comptimePrint(
            "{d}",
            .{@sizeOf(Category)},
        ) ++ ", expected 1288");
    assert(@alignOf(Category) == 8);
    assert(@offsetOf(Category, "id") == 0);
    assert(@offsetOf(Category, "parent_id") == 8);
}

pub const LinkStatus = enum(u8) {
    pending = 0,
    approved = 1,
    rejected = 2,
    _,
};

pub const Link = extern struct {
    id: u64 = 0,
    category_id: u64 = 0,
    url: FixedString(64) = .{},
    title: FixedString(128) = .{},
    description: FixedString(256) = .{},
    sort_order: u32 = 0,
    _pad0: u32 = 0,
    created_at: i64 = 0,
    updated_at: i64 = 0,
    status: u8 = @intFromEnum(LinkStatus.approved),
    _pad1: [7]u8 = @splat(0),
    submitter_id: u64 = 0,
    editor_note: FixedString(1024) = .{},
    tags: FixedString(256) = .{},
    language: FixedString(8) = .{},
    region: FixedString(8) = .{},
    license: FixedString(64) = .{},
    _pad2: [6]u8 = @splat(0),
};

comptime {
    if (@sizeOf(Link) == 0) @compileError("Link must be non-zero size");
    if (@sizeOf(Link) != 1888)
        @compileError("Link size mismatch: got " ++ std.fmt.comptimePrint(
            "{d}",
            .{@sizeOf(Link)},
        ) ++ ", expected 1888");
    assert(@alignOf(Link) == 8);
    assert(@offsetOf(Link, "id") == 0);
    assert(@offsetOf(Link, "category_id") == 8);
    assert(@offsetOf(Link, "status") == 496);
    assert(@offsetOf(Link, "submitter_id") == 504);
}

pub const RepairOp = enum(u8) {
    renamed_slug = 1,
    moved_parent = 2,
};

pub const RepairTask = extern struct {
    cat_id: u64 = 0,
    op: RepairOp = .renamed_slug,
    _pad: [7]u8 = @splat(0),
    created_at: i64 = 0,
    old_slug_prefix: FixedString(2048) = .{},
};

comptime {
    if (@sizeOf(RepairTask) != 2080)
        @compileError("RepairTask size mismatch: got " ++ std.fmt.comptimePrint(
            "{d}",
            .{@sizeOf(RepairTask)},
        ) ++ ", expected 2080");
    assert(@alignOf(RepairTask) == 8);
    assert(@offsetOf(RepairTask, "old_slug_prefix") == 24);
}

pub const embedding_dimensions: usize = 384;

pub const StoredVector = extern struct {
    id: u64 = 0,
    scale: f32 = 0,
    values: [embedding_dimensions]i8 = @splat(0),
    _pad: [4]u8 = @splat(0),
};

pub const pq_subquantizers: usize = 96;

pub const LinkVector = extern struct {
    vector: StoredVector = .{},
    model_hash: u64 = 0,
    cell: u16 = 0,
    _pad: [6]u8 = @splat(0),
    codes: [pq_subquantizers]u8 = @splat(0),
};

comptime {
    if (@sizeOf(StoredVector) != 400)
        @compileError("StoredVector size mismatch: got " ++ std.fmt.comptimePrint(
            "{d}",
            .{@sizeOf(StoredVector)},
        ) ++ ", expected 400");
    if (@sizeOf(LinkVector) != 512)
        @compileError("LinkVector size mismatch: got " ++ std.fmt.comptimePrint(
            "{d}",
            .{@sizeOf(LinkVector)},
        ) ++ ", expected 512");
    assert(@sizeOf(StoredVector) == 16 + embedding_dimensions);
    assert(@offsetOf(StoredVector, "values") == 12);
    assert(@offsetOf(LinkVector, "model_hash") == @sizeOf(StoredVector));
    assert(@offsetOf(LinkVector, "codes") == 416);
}

pub fn stored_vector_prefix(bytes: []const u8) ?StoredVector {
    // A LinkVector starts with its StoredVector, which is what lets one reader serve both.
    comptime assert(@offsetOf(LinkVector, "vector") == 0);
    if (bytes.len == @sizeOf(StoredVector)) {
        return std.mem.bytesToValue(StoredVector, bytes[0..@sizeOf(StoredVector)]);
    }
    if (bytes.len == @sizeOf(LinkVector)) {
        return std.mem.bytesToValue(StoredVector, bytes[0..@sizeOf(StoredVector)]);
    }
    return null;
}

pub fn link_text_fingerprint(link: *const Link) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(link.title.slice());
    hasher.update(&.{0});
    hasher.update(link.description.slice());
    return hasher.final();
}

pub fn embedded_text_changed(old: *const Link, new: *const Link) bool {
    assert(old.id == new.id);
    return link_text_fingerprint(old) != link_text_fingerprint(new);
}

pub const ParentChildKey = CompositeKey(&.{ "parent_id", "child_id" });
pub const CategoryLinkKey = CompositeKey(&.{ "category_id", "link_id" });
pub const SubmitterLinkKey = CompositeKey(&.{ "submitter_id", "link_id" });

// A composite key decodes back to the two ids it was built from.
test "ParentChildKey encode / decode" {
    const encoded = ParentChildKey.encode(.{ 10, 20 });
    const decoded = ParentChildKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 10), decoded.parent_id);
    try std.testing.expectEqual(@as(u64, 20), decoded.child_id);
}

// The link-under-category key decodes back to the category and link ids.
test "CategoryLinkKey encode / decode" {
    const encoded = CategoryLinkKey.encode(.{ 5, 99 });
    const decoded = CategoryLinkKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 5), decoded.category_id);
    try std.testing.expectEqual(@as(u64, 99), decoded.link_id);
}

// A zero Link is approved, unsubmitted and zero-padded; readers of old records rely on it.
test "Link defaults: status=approved, submitter_id=0, padding=zero" {
    const link = Link{};
    try std.testing.expectEqual(@as(u8, @intFromEnum(LinkStatus.approved)), link.status);
    try std.testing.expectEqual(@as(u64, 0), link.submitter_id);
    for (link._pad1) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    for (link._pad2) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

// The status byte values are part of the wire format and must not drift.
test "LinkStatus enum values: pending=0, approved=1, rejected=2" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(LinkStatus.pending));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(LinkStatus.approved));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(LinkStatus.rejected));
}

// Status and submitter survive a copy through raw bytes.
test "Link round-trip preserves status + submitter_id" {
    var link = Link{};
    link.id = 42;
    link.status = @intFromEnum(LinkStatus.pending);
    link.submitter_id = 314;

    const bytes = std.mem.toBytes(link);
    const restored = std.mem.bytesToValue(Link, &bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(LinkStatus.pending)), restored.status);
    try std.testing.expectEqual(@as(u64, 314), restored.submitter_id);
}

// The fields added in format v6 default to empty strings.
test "Link v6 fields default to empty FixedString" {
    const link = Link{};
    try std.testing.expectEqual(@as(u16, 0), link.editor_note.len);
    try std.testing.expectEqual(@as(u16, 0), link.tags.len);
    try std.testing.expectEqual(@as(u16, 0), link.language.len);
    try std.testing.expectEqual(@as(u16, 0), link.region.len);
    try std.testing.expectEqual(@as(u16, 0), link.license.len);
}

// The v6 fields survive a copy through raw bytes.
test "Link v6 round-trip preserves all new fields" {
    var link = Link{};
    link.id = 99;
    link.editor_note = FixedString(1024).fromSlice(
        "Indexed by M. Vargas on 2026-05-09; archive flagged.",
    );
    link.tags = FixedString(256).fromSlice("public-domain,archive,long-form");
    link.language = FixedString(8).fromSlice("en-US");
    link.region = FixedString(8).fromSlice("US");
    link.license = FixedString(64).fromSlice("CC BY-NC 4.0");

    const bytes = std.mem.toBytes(link);
    const restored = std.mem.bytesToValue(Link, &bytes);
    try std.testing.expect(restored.editor_note.eql(
        "Indexed by M. Vargas on 2026-05-09; archive flagged.",
    ));
    try std.testing.expect(restored.tags.eql("public-domain,archive,long-form"));
    try std.testing.expect(restored.language.eql("en-US"));
    try std.testing.expect(restored.region.eql("US"));
    try std.testing.expect(restored.license.eql("CC BY-NC 4.0"));
}

// The queue record's size is pinned because the worker reads it back by size.
test "RepairTask: extern layout is exactly 2080 bytes" {
    try std.testing.expectEqual(@as(usize, 2080), @sizeOf(RepairTask));
}

// A repair task survives a copy through raw bytes.
test "RepairTask: round-trip via std.mem bytesToValue" {
    const task = RepairTask{
        .cat_id = 42,
        .op = .renamed_slug,
        .created_at = 1714838400000,
        .old_slug_prefix = FixedString(2048).fromSlice("top/old"),
    };
    const bytes = std.mem.asBytes(&task);
    try std.testing.expectEqual(@as(usize, 2080), bytes.len);
    const decoded = std.mem.bytesToValue(RepairTask, bytes[0..2080]);
    try std.testing.expectEqual(@as(u64, 42), decoded.cat_id);
    try std.testing.expectEqual(RepairOp.renamed_slug, decoded.op);
    try std.testing.expectEqualStrings("top/old", decoded.old_slug_prefix.slice());
}

// The fingerprint hashes the title, a zero separator, then the description, so "ab"+"c" and
// "a"+"bc" cannot collide by construction.
test "link_text_fingerprint is FNV-1a 64 over title, a zero byte, then description" {
    var link = Link{};
    link.title = FixedString(128).fromSlice("ab");
    link.description = FixedString(256).fromSlice("c");
    try std.testing.expectEqual(std.hash.Fnv1a_64.hash("ab\x00c"), link_text_fingerprint(&link));
}

// Only the embedded fields count as a text change: flip status and url (no change), then the
// title and the description (each a change).
test "embedded_text_changed ignores status and url, sees title and description" {
    var old = Link{};
    old.title = FixedString(128).fromSlice("Bonsai");
    old.description = FixedString(256).fromSlice("Trees");

    var status_flip = old;
    status_flip.status = @intFromEnum(LinkStatus.rejected);
    status_flip.url = FixedString(64).fromSlice("https://moved.example");
    try std.testing.expect(!embedded_text_changed(&old, &status_flip));

    var retitled = old;
    retitled.title = FixedString(128).fromSlice("Bonsai Club");
    try std.testing.expect(embedded_text_changed(&old, &retitled));

    var redescribed = old;
    redescribed.description = FixedString(256).fromSlice("Small trees");
    try std.testing.expect(embedded_text_changed(&old, &redescribed));
}
