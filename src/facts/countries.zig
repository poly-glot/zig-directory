//! ISO 3166 country codes: the table a category name or a ccTLD resolves to. The embedded TSV is
//! checked at compile time, so every code this module hands out is an assigned two-letter code.

const std = @import("std");
const assert = std.debug.assert;

pub const Code = [2]u8;
pub const none: Code = .{ 0, 0 };

const name_len_max: usize = 128;
const slot_count: usize = 26 * 26;

const Entry = struct { []const u8, Code };

const entries: []const Entry = parsed: {
    @setEvalBranchQuota(200_000);
    var list: []const Entry = &.{};
    var lines = std.mem.tokenizeScalar(u8, @embedFile("countries.tsv"), '\n');
    while (lines.next()) |line| {
        assert(line.len > 3);
        assert(line[2] == '\t');
        for (line[3..]) |byte| assert(!std.ascii.isUpper(byte));
        list = list ++ [_]Entry{.{ line[3..], line[0..2].* }};
    }
    break :parsed list;
};

const codes_by_name = std.StaticStringMap(Code).initComptime(entries);

const assigned: [slot_count]bool = flags: {
    @setEvalBranchQuota(10_000);
    var bits: [slot_count]bool = @splat(false);
    for (entries) |entry| bits[slot(entry[1])] = true;
    break :flags bits;
};

fn slot(code: Code) usize {
    assert(std.ascii.isUpper(code[0]));
    assert(std.ascii.isUpper(code[1]));
    const index = @as(usize, code[0] - 'A') * 26 + (code[1] - 'A');
    assert(index < slot_count);
    return index;
}

pub fn is_assigned(code: Code) bool {
    if (!std.ascii.isUpper(code[0])) return false;
    if (!std.ascii.isUpper(code[1])) return false;
    return assigned[slot(code)];
}

pub fn by_name(name: []const u8) ?Code {
    var folded: [name_len_max]u8 = undefined;
    if (name.len > folded.len) return null;
    for (name, folded[0..name.len]) |byte, *out| {
        out.* = if (byte == '_') ' ' else std.ascii.toLower(byte);
    }
    const code = codes_by_name.get(folded[0..name.len]) orelse return null;
    assert(is_assigned(code));
    return code;
}

// A category name resolves through the ISO names and the listed aliases only: a demonym or a
// topic word gives null.
test "by_name matches an ISO name or a listed alias, never a demonym" {
    try std.testing.expectEqual(@as(?Code, "GB".*), by_name("United_Kingdom"));
    try std.testing.expectEqual(@as(?Code, "GB".*), by_name("England"));
    try std.testing.expectEqual(@as(?Code, "PK".*), by_name("Pakistan"));
    try std.testing.expectEqual(@as(?Code, "KR".*), by_name("Korea,_South"));
    try std.testing.expectEqual(@as(?Code, "RU".*), by_name("Russia"));
    try std.testing.expectEqual(@as(?Code, null), by_name("Pakistani"));
    try std.testing.expectEqual(@as(?Code, null), by_name("Music"));
}

// Only codes from the table are assigned; a reserved code, an unused pair or lowercase is not.
test "only ISO 3166 codes are assigned" {
    try std.testing.expect(is_assigned("PK".*));
    try std.testing.expect(is_assigned("GB".*));
    try std.testing.expect(!is_assigned("UK".*));
    try std.testing.expect(!is_assigned("ZZ".*));
    try std.testing.expect(!is_assigned("pk".*));
}
