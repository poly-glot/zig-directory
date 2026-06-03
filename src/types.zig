const std = @import("std");

pub fn Serializable(comptime T: type) type {
    comptime {
        const info = @typeInfo(T);
        if (info != .@"struct" or info.@"struct".layout != .@"extern")
            @compileError("Serializable requires an extern struct, got " ++ @typeName(T));
    }

    return struct {
        pub fn asBytes(ptr: *const T) []const u8 {
            return std.mem.asBytes(ptr);
        }

        pub fn asMutableBytes(ptr: *T) []u8 {
            return std.mem.asBytes(ptr);
        }

        pub fn toBytes(ptr: *const T) [@sizeOf(T)]u8 {
            return std.mem.toBytes(ptr.*);
        }

        pub fn fromBytes(bytes: []const u8) T {
            return std.mem.bytesToValue(T, bytes[0..@sizeOf(T)]);
        }
    };
}

pub fn FixedString(comptime N: usize) type {
    comptime {
        if (N % 2 != 0) @compileError("FixedString capacity N must be even for alignment");
    }

    return extern struct {
        data: [N]u8 = [_]u8{0} ** N,
        len: u16 = 0,

        const Self = @This();

        pub fn fromSlice(s: []const u8) Self {
            var fs = Self{};
            const copy_len = @min(s.len, N);
            @memcpy(fs.data[0..copy_len], s[0..copy_len]);
            fs.len = @intCast(copy_len);
            return fs;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.data[0..@min(self.len, N)];
        }

        pub fn eql(self: *const Self, other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }

        pub fn format(self: *const Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.writeAll(self.slice());
        }

        comptime {
            if (@sizeOf(Self) != N + 2) @compileError("FixedString size mismatch");
        }
    };
}

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

pub fn CompositeKey(comptime fields: []const [:0]const u8) type {
    comptime {
        if (fields.len == 0) @compileError("CompositeKey requires at least one field");
    }

    const num_fields = fields.len;
    const key_size = num_fields * 8;

    const struct_fields = comptime blk: {
        var sf: [num_fields]std.builtin.Type.StructField = undefined;
        for (fields, 0..) |name, i| {
            sf[i] = .{
                .name = name,
                .type = u64,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = @alignOf(u64),
            };
        }
        break :blk sf;
    };

    const GeneratedStruct = @Type(.{ .@"struct" = .{
        .layout = .@"extern",
        .fields = &struct_fields,
        .decls = &.{},
        .is_tuple = false,
    } });

    return struct {
        pub const KeyStruct = GeneratedStruct;

        pub const encoded_size = key_size;

        pub fn encode(values: [num_fields]u64) [key_size]u8 {
            var buf: [key_size]u8 = undefined;
            inline for (0..num_fields) |i| {
                buf[i * 8 ..][0..8].* = std.mem.toBytes(
                    std.mem.nativeTo(u64, values[i], .big),
                );
            }
            return buf;
        }

        pub fn decode(bytes: []const u8) GeneratedStruct {
            var result: GeneratedStruct = undefined;
            inline for (fields, 0..) |name, i| {
                @field(result, name) = std.mem.toNative(
                    u64,
                    std.mem.bytesToValue(u64, bytes[i * 8 ..][0..8]),
                    .big,
                );
            }
            return result;
        }
    };
}

const ParentChildComposite = CompositeKey(&.{ "parent_id", "child_id" });
const CategoryLinkComposite = CompositeKey(&.{ "category_id", "link_id" });
const SubmitterLinkComposite = CompositeKey(&.{ "submitter_id", "link_id" });

pub const ParentChildKey = extern struct {
    parent_id: u64,
    child_id: u64,

    pub fn encode(parent_id: u64, child_id: u64) [16]u8 {
        return ParentChildComposite.encode(.{ parent_id, child_id });
    }

    pub fn decode(bytes: []const u8) ParentChildKey {
        const raw = ParentChildComposite.decode(bytes);
        return .{ .parent_id = raw.parent_id, .child_id = raw.child_id };
    }
};

pub const CategoryLinkKey = extern struct {
    category_id: u64,
    link_id: u64,

    pub fn encode(category_id: u64, link_id: u64) [16]u8 {
        return CategoryLinkComposite.encode(.{ category_id, link_id });
    }

    pub fn decode(bytes: []const u8) CategoryLinkKey {
        const raw = CategoryLinkComposite.decode(bytes);
        return .{ .category_id = raw.category_id, .link_id = raw.link_id };
    }
};

pub const SubmitterLinkKey = extern struct {
    submitter_id: u64,
    link_id: u64,

    pub fn encode(submitter_id: u64, link_id: u64) [16]u8 {
        return SubmitterLinkComposite.encode(.{ submitter_id, link_id });
    }

    pub fn decode(bytes: []const u8) SubmitterLinkKey {
        const raw = SubmitterLinkComposite.decode(bytes);
        return .{ .submitter_id = raw.submitter_id, .link_id = raw.link_id };
    }
};

pub fn encodeU64(val: u64) [8]u8 {
    return std.mem.toBytes(std.mem.nativeTo(u64, val, .big));
}

pub fn decodeU64(bytes: []const u8) u64 {
    return std.mem.toNative(u64, std.mem.bytesToValue(u64, bytes[0..8]), .big);
}

pub fn hashUrl(url: []const u8) u64 {
    return std.hash.Wyhash.hash(0, url);
}

test "FixedString fromSlice / slice roundtrip" {
    const fs = FixedString(256).fromSlice("hello world");
    try std.testing.expectEqualSlices(u8, "hello world", fs.slice());
    try std.testing.expectEqual(@as(u16, 11), fs.len);
}

test "FixedString truncation" {
    const fs = FixedString(4).fromSlice("abcdefgh");
    try std.testing.expectEqualSlices(u8, "abcd", fs.slice());
    try std.testing.expectEqual(@as(u16, 4), fs.len);
}

test "FixedString eql" {
    const fs = FixedString(64).fromSlice("test");
    try std.testing.expect(fs.eql("test"));
    try std.testing.expect(!fs.eql("other"));
}

test "FixedString default is empty" {
    const fs = FixedString(256){};
    try std.testing.expectEqual(@as(u16, 0), fs.len);
    try std.testing.expectEqualSlices(u8, "", fs.slice());
}

test "encodeU64 / decodeU64 roundtrip" {
    const values = [_]u64{ 0, 1, 42, 0xDEADBEEF, std.math.maxInt(u64) };
    for (values) |v| {
        const encoded = encodeU64(v);
        const decoded = decodeU64(&encoded);
        try std.testing.expectEqual(v, decoded);
    }
}

test "encodeU64 big-endian ordering" {
    const a = encodeU64(100);
    const b = encodeU64(200);
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);
}

test "ParentChildKey encode / decode" {
    const encoded = ParentChildKey.encode(10, 20);
    const decoded = ParentChildKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 10), decoded.parent_id);
    try std.testing.expectEqual(@as(u64, 20), decoded.child_id);
}

test "CategoryLinkKey encode / decode" {
    const encoded = CategoryLinkKey.encode(5, 99);
    const decoded = CategoryLinkKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 5), decoded.category_id);
    try std.testing.expectEqual(@as(u64, 99), decoded.link_id);
}

test "hashUrl deterministic" {
    const h1 = hashUrl("https://example.com");
    const h2 = hashUrl("https://example.com");
    try std.testing.expectEqual(h1, h2);

    const h3 = hashUrl("https://other.com");
    try std.testing.expect(h1 != h3);
}

test "hashUrl different inputs produce different hashes" {
    const h1 = hashUrl("https://a.com");
    const h2 = hashUrl("https://b.com");
    try std.testing.expect(h1 != h2);
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

test "CompositeKey generic encode/decode" {
    const TripleKey = CompositeKey(&.{ "a", "b", "c" });

    const encoded = TripleKey.encode(.{ 1, 2, 3 });
    try std.testing.expectEqual(@as(usize, 24), encoded.len);

    const decoded = TripleKey.decode(&encoded);
    try std.testing.expectEqual(@as(u64, 1), decoded.a);
    try std.testing.expectEqual(@as(u64, 2), decoded.b);
    try std.testing.expectEqual(@as(u64, 3), decoded.c);
}

test "CompositeKey preserves sort order" {
    const Pair = CompositeKey(&.{ "x", "y" });

    const a = Pair.encode(.{ 1, 999 });
    const b = Pair.encode(.{ 2, 0 });
    try std.testing.expect(std.mem.order(u8, &a, &b) == .lt);

    const c = Pair.encode(.{ 5, 10 });
    const d = Pair.encode(.{ 5, 20 });
    try std.testing.expect(std.mem.order(u8, &c, &d) == .lt);
}

test "CompositeKey produces identical bytes to ParentChildKey" {
    const via_wrapper = ParentChildKey.encode(42, 99);
    const via_generic = ParentChildComposite.encode(.{ 42, 99 });
    try std.testing.expectEqualSlices(u8, &via_wrapper, &via_generic);
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
