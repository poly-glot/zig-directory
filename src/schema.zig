const std = @import("std");
const codec = @import("zigstore").codec;
const FixedString = codec.FixedString;
const Serializable = codec.Serializable;
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

    const Ser = Serializable(Category);
    pub const asBytes = Ser.asBytes;
    pub const asMutableBytes = Ser.asMutableBytes;
    pub const toBytes = Ser.toBytes;
    pub const fromBytes = Ser.fromBytes;
};

comptime {
    if (@sizeOf(Category) == 0) @compileError("Category must be non-zero size");
    if (@sizeOf(Category) != 1288)
        @compileError("Category size mismatch: got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Category)}) ++ ", expected 1288");
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
    _pad1: [7]u8 = .{0} ** 7,
    submitter_id: u64 = 0,
    editor_note: FixedString(1024) = .{},
    tags: FixedString(256) = .{},
    language: FixedString(8) = .{},
    region: FixedString(8) = .{},
    license: FixedString(64) = .{},
    _pad2: [6]u8 = .{0} ** 6,

    const Ser = Serializable(Link);
    pub const asBytes = Ser.asBytes;
    pub const asMutableBytes = Ser.asMutableBytes;
    pub const toBytes = Ser.toBytes;
    pub const fromBytes = Ser.fromBytes;
};

comptime {
    if (@sizeOf(Link) == 0) @compileError("Link must be non-zero size");
    if (@sizeOf(Link) != 1888)
        @compileError("Link size mismatch: got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(Link)}) ++ ", expected 1888");
}

pub const RepairOp = enum(u8) {
    renamed_slug = 1,
    moved_parent = 2,
};

pub const RepairTask = extern struct {
    cat_id: u64 = 0,
    op: RepairOp = .renamed_slug,
    _pad: [7]u8 = [_]u8{0} ** 7,
    created_at: i64 = 0,
    old_slug_prefix: FixedString(2048) = .{},

    const Ser = Serializable(RepairTask);
    pub const asBytes = Ser.asBytes;
    pub const asMutableBytes = Ser.asMutableBytes;
    pub const toBytes = Ser.toBytes;
    pub const fromBytes = Ser.fromBytes;
};

comptime {
    if (@sizeOf(RepairTask) != 2080)
        @compileError("RepairTask size mismatch: got " ++ std.fmt.comptimePrint("{d}", .{@sizeOf(RepairTask)}) ++ ", expected 2080");
}

pub const ParentChildKey = CompositeKey(&.{ "parent_id", "child_id" });
pub const CategoryLinkKey = CompositeKey(&.{ "category_id", "link_id" });
pub const SubmitterLinkKey = CompositeKey(&.{ "submitter_id", "link_id" });

test "ParentChildKey encode / decode" {
    const encoded = ParentChildKey.encode(.{ 10, 20 });
    const decoded = ParentChildKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 10), decoded.parent_id);
    try std.testing.expectEqual(@as(u64, 20), decoded.child_id);
}

test "CategoryLinkKey encode / decode" {
    const encoded = CategoryLinkKey.encode(.{ 5, 99 });
    const decoded = CategoryLinkKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 5), decoded.category_id);
    try std.testing.expectEqual(@as(u64, 99), decoded.link_id);
}

test "Serializable Category asBytes roundtrip" {
    var cat = Category{};
    cat.id = 42;
    cat.parent_id = 7;
    cat.name = FixedString(64).fromSlice("Test Category");

    const bytes = cat.asBytes();
    try std.testing.expectEqual(@as(usize, @sizeOf(Category)), bytes.len);

    const restored = Category.fromBytes(bytes);
    try std.testing.expectEqual(@as(u64, 42), restored.id);
    try std.testing.expectEqual(@as(u64, 7), restored.parent_id);
    try std.testing.expect(restored.name.eql("Test Category"));
}

test "Serializable Link toBytes / fromBytes roundtrip" {
    var link = Link{};
    link.id = 100;
    link.category_id = 5;
    link.url = FixedString(64).fromSlice("https://example.com");
    link.title = FixedString(128).fromSlice("Example");

    const bytes = link.toBytes();
    try std.testing.expectEqual(@as(usize, @sizeOf(Link)), bytes.len);

    const restored = Link.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u64, 100), restored.id);
    try std.testing.expectEqual(@as(u64, 5), restored.category_id);
    try std.testing.expect(restored.url.eql("https://example.com"));
    try std.testing.expect(restored.title.eql("Example"));
}

test "Link defaults: status=approved, submitter_id=0, padding=zero" {
    const link = Link{};
    try std.testing.expectEqual(@as(u8, @intFromEnum(LinkStatus.approved)), link.status);
    try std.testing.expectEqual(@as(u64, 0), link.submitter_id);
    for (link._pad1) |b| try std.testing.expectEqual(@as(u8, 0), b);
    for (link._pad2) |b| try std.testing.expectEqual(@as(u8, 0), b);
}

test "LinkStatus enum values: pending=0, approved=1, rejected=2" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(LinkStatus.pending));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(LinkStatus.approved));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(LinkStatus.rejected));
}

test "Link round-trip preserves status + submitter_id" {
    var link = Link{};
    link.id = 42;
    link.status = @intFromEnum(LinkStatus.pending);
    link.submitter_id = 314;

    const bytes = link.toBytes();
    const restored = Link.fromBytes(&bytes);
    try std.testing.expectEqual(@as(u8, @intFromEnum(LinkStatus.pending)), restored.status);
    try std.testing.expectEqual(@as(u64, 314), restored.submitter_id);
}

test "Link v6 fields default to empty FixedString" {
    const link = Link{};
    try std.testing.expectEqual(@as(u16, 0), link.editor_note.len);
    try std.testing.expectEqual(@as(u16, 0), link.tags.len);
    try std.testing.expectEqual(@as(u16, 0), link.language.len);
    try std.testing.expectEqual(@as(u16, 0), link.region.len);
    try std.testing.expectEqual(@as(u16, 0), link.license.len);
}

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

    const bytes = link.toBytes();
    const restored = Link.fromBytes(&bytes);
    try std.testing.expect(restored.editor_note.eql(
        "Indexed by M. Vargas on 2026-05-09; archive flagged.",
    ));
    try std.testing.expect(restored.tags.eql("public-domain,archive,long-form"));
    try std.testing.expect(restored.language.eql("en-US"));
    try std.testing.expect(restored.region.eql("US"));
    try std.testing.expect(restored.license.eql("CC BY-NC 4.0"));
}

test "Serializable asBytes matches std.mem.asBytes" {
    var cat = Category{};
    cat.id = 123;
    const via_mixin = cat.asBytes();
    const via_std = std.mem.asBytes(&cat);
    try std.testing.expectEqualSlices(u8, via_std, via_mixin);
}

test "RepairTask: extern layout is exactly 2080 bytes" {
    try std.testing.expectEqual(@as(usize, 2080), @sizeOf(RepairTask));
}

test "RepairTask: round-trip via std.mem bytesToValue" {
    var t = RepairTask{
        .cat_id = 42,
        .op = .renamed_slug,
        .created_at = 1714838400000,
        .old_slug_prefix = FixedString(2048).fromSlice("top/old"),
    };
    const bytes = std.mem.asBytes(&t);
    try std.testing.expectEqual(@as(usize, 2080), bytes.len);
    const decoded = std.mem.bytesToValue(RepairTask, bytes[0..2080]);
    try std.testing.expectEqual(@as(u64, 42), decoded.cat_id);
    try std.testing.expectEqual(RepairOp.renamed_slug, decoded.op);
    try std.testing.expectEqualStrings("top/old", decoded.old_slug_prefix.slice());
}
