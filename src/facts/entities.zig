const std = @import("std");
const countries = @import("countries.zig");

pub const Religion = enum(u4) {
    islam,
    christianity,
    judaism,
    hinduism,
    buddhism,
    sikhism,
    taoism,
    jainism,
    bahai,
    shinto,
    paganism,
};

pub const RELIGION_MASK: u16 = (1 << @typeInfo(Religion).@"enum".fields.len) - 1;
pub const MAX_COUNTRIES: usize = 8;
pub const MAX_NAMES: usize = 8;
pub const MAX_NAME_LEN: usize = 64;
pub const MAX_ENCODED_LEN: usize = 4 + MAX_COUNTRIES * 2 + 2 * (1 + MAX_NAMES * (1 + MAX_NAME_LEN));
const FORMAT_VERSION: u8 = 1;

pub const Names = struct {
    items: [MAX_NAMES][]const u8 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Names) []const []const u8 {
        return self.items[0..self.len];
    }
};

pub const Facts = struct {
    religions: u16 = 0,
    countries: [MAX_COUNTRIES]countries.Code = undefined,
    country_count: usize = 0,
    people: Names = .{},
    orgs: Names = .{},

    pub fn countrySlice(self: *const Facts) []const countries.Code {
        return self.countries[0..self.country_count];
    }
};

pub fn decode(bytes: []const u8) ?Facts {
    var reader: Reader = .{ .bytes = bytes };
    if ((reader.byte() orelse return null) != FORMAT_VERSION) return null;

    var facts: Facts = .{ .religions = reader.int(u16) orelse return null };
    if (facts.religions & ~RELIGION_MASK != 0) return null;

    facts.country_count = reader.byte() orelse return null;
    if (facts.country_count > MAX_COUNTRIES) return null;
    for (facts.countries[0..facts.country_count]) |*code| {
        code.* = (reader.take(2) orelse return null)[0..2].*;
        if (!countries.isAssigned(code.*)) return null;
    }

    if (!reader.names(&facts.people)) return null;
    if (!reader.names(&facts.orgs)) return null;
    if (reader.at != bytes.len) return null;
    return facts;
}

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Reader, n: usize) ?[]const u8 {
        if (self.at + n > self.bytes.len) return null;
        defer self.at += n;
        return self.bytes[self.at..][0..n];
    }

    fn byte(self: *Reader) ?u8 {
        return (self.take(1) orelse return null)[0];
    }

    fn int(self: *Reader, comptime T: type) ?T {
        return std.mem.readInt(T, (self.take(@sizeOf(T)) orelse return null)[0..@sizeOf(T)], .little);
    }

    fn names(self: *Reader, out: *Names) bool {
        out.len = self.byte() orelse return false;
        if (out.len > MAX_NAMES) return false;
        for (out.items[0..out.len]) |*name| {
            const len = self.byte() orelse return false;
            if (len == 0 or len > MAX_NAME_LEN) return false;
            name.* = self.take(len) orelse return false;
            if (!std.unicode.utf8ValidateSlice(name.*)) return false;
        }
        return true;
    }
};

const testing = std.testing;

fn encode(facts: *const Facts, out: *[MAX_ENCODED_LEN]u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeByte(FORMAT_VERSION) catch unreachable;
    w.writeInt(u16, facts.religions, .little) catch unreachable;
    w.writeByte(@intCast(facts.country_count)) catch unreachable;
    for (facts.countrySlice()) |code| w.writeAll(&code) catch unreachable;
    for ([_]*const Names{ &facts.people, &facts.orgs }) |names| {
        w.writeByte(@intCast(names.len)) catch unreachable;
        for (names.slice()) |name| {
            w.writeByte(@intCast(name.len)) catch unreachable;
            w.writeAll(name) catch unreachable;
        }
    }
    return out[0..w.end];
}

fn sampleFacts() Facts {
    var facts: Facts = .{ .religions = @as(u16, 1) << @intFromEnum(Religion.islam) };
    facts.countries[0] = "PK".*;
    facts.country_count = 1;
    facts.people.items[0] = "Rebbe Nachman";
    facts.people.len = 1;
    facts.orgs.items[0] = "Jamia Farooqia";
    facts.orgs.items[1] = "Café Zürich";
    facts.orgs.len = 2;
    return facts;
}

test "entity facts round-trip through their encoding" {
    const facts = sampleFacts();
    var buf: [MAX_ENCODED_LEN]u8 = undefined;
    const decoded = decode(encode(&facts, &buf)).?;

    try testing.expectEqual(facts.religions, decoded.religions);
    try testing.expectEqualSlices(u8, "PK", &decoded.countries[0]);
    try testing.expectEqualStrings("Rebbe Nachman", decoded.people.slice()[0]);
    try testing.expectEqualStrings("Café Zürich", decoded.orgs.slice()[1]);
}

test "decode refuses unknown religions, unassigned countries, empty or oversized names, bad UTF-8 and trailing bytes" {
    var buf: [MAX_ENCODED_LEN]u8 = undefined;
    const good = encode(&sampleFacts(), &buf);

    var bad: [MAX_ENCODED_LEN + 1]u8 = undefined;
    @memcpy(bad[0..good.len], good);

    bad[1] = 0xFF;
    bad[2] = 0xFF;
    try testing.expectEqual(@as(?Facts, null), decode(bad[0..good.len]));

    @memcpy(bad[0..good.len], good);
    bad[4] = 'Z';
    bad[5] = 'Z';
    try testing.expectEqual(@as(?Facts, null), decode(bad[0..good.len]));

    @memcpy(bad[0..good.len], good);
    bad[good.len] = 0;
    try testing.expectEqual(@as(?Facts, null), decode(bad[0 .. good.len + 1]));

    @memcpy(bad[0..good.len], good);
    bad[0] = FORMAT_VERSION + 1;
    try testing.expectEqual(@as(?Facts, null), decode(bad[0..good.len]));

    var facts = sampleFacts();
    facts.people.items[0] = "\xff\xfe";
    try testing.expectEqual(@as(?Facts, null), decode(encode(&facts, &buf)));
    try testing.expectEqual(@as(?Facts, null), decode(&.{}));
}
