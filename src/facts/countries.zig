const std = @import("std");

pub const Code = [2]u8;
pub const none: Code = .{ 0, 0 };

const MAX_NAME_LEN: usize = 128;

const Entry = struct { []const u8, Code };

const entries: []const Entry = blk: {
    @setEvalBranchQuota(200_000);
    var list: []const Entry = &.{};
    var lines = std.mem.tokenizeScalar(u8, @embedFile("countries.tsv"), '\n');
    while (lines.next()) |line| list = list ++ [_]Entry{.{ line[3..], line[0..2].* }};
    break :blk list;
};

const by_name = std.StaticStringMap(Code).initComptime(entries);

const assigned: [26 * 26]bool = blk: {
    var bits: [26 * 26]bool = @splat(false);
    for (entries) |entry| bits[slot(entry[1])] = true;
    break :blk bits;
};

fn slot(code: Code) usize {
    return @as(usize, code[0] - 'A') * 26 + (code[1] - 'A');
}

pub fn isAssigned(code: Code) bool {
    if (!std.ascii.isUpper(code[0]) or !std.ascii.isUpper(code[1])) return false;
    return assigned[slot(code)];
}

pub fn byName(name: []const u8) ?Code {
    var buf: [MAX_NAME_LEN]u8 = undefined;
    if (name.len > buf.len) return null;
    for (name, buf[0..name.len]) |c, *out| out.* = if (c == '_') ' ' else std.ascii.toLower(c);
    return by_name.get(buf[0..name.len]);
}

test "a category name matches an ISO name or a listed alias, never a demonym" {
    try std.testing.expectEqual(@as(?Code, "GB".*), byName("United_Kingdom"));
    try std.testing.expectEqual(@as(?Code, "GB".*), byName("England"));
    try std.testing.expectEqual(@as(?Code, "PK".*), byName("Pakistan"));
    try std.testing.expectEqual(@as(?Code, "KR".*), byName("Korea,_South"));
    try std.testing.expectEqual(@as(?Code, "RU".*), byName("Russia"));
    try std.testing.expectEqual(@as(?Code, null), byName("Pakistani"));
    try std.testing.expectEqual(@as(?Code, null), byName("Music"));
}

test "only ISO 3166 codes are assigned" {
    try std.testing.expect(isAssigned("PK".*));
    try std.testing.expect(isAssigned("GB".*));
    try std.testing.expect(!isAssigned("UK".*));
    try std.testing.expect(!isAssigned("ZZ".*));
    try std.testing.expect(!isAssigned("pk".*));
}
