//! The entity facts extracted for a link (religions, countries, people and organisations) and
//! their byte encoding. `decode` validates every byte it is handed and answers null to anything
//! malformed, so the facts index only ever holds facts within the `*_max` bounds declared here.

const std = @import("std");
const assert = std.debug.assert;
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

pub const religion_mask: u16 = (1 << @typeInfo(Religion).@"enum".fields.len) - 1;
pub const countries_max: usize = 8;
pub const names_max: usize = 8;
pub const name_len_max: usize = 64;
pub const encoded_len_max: usize = 4 + countries_max * 2 + 2 * (1 + names_max * (1 + name_len_max));
const format_version: u8 = 1;

pub const Names = struct {
    items: [names_max][]const u8 = undefined,
    len: u32 = 0,

    pub fn slice(self: *const Names) []const []const u8 {
        assert(self.len <= names_max);
        return self.items[0..self.len];
    }
};

pub const Facts = struct {
    religions: u16 = 0,
    countries: [countries_max]countries.Code = undefined,
    country_count: u32 = 0,
    people: Names = .{},
    orgs: Names = .{},

    pub fn country_slice(self: *const Facts) []const countries.Code {
        assert(self.country_count <= countries_max);
        return self.countries[0..self.country_count];
    }
};

pub fn decode(bytes: []const u8) ?Facts {
    comptime assert(@sizeOf(countries.Code) == 2);
    var reader: Reader = .{ .bytes = bytes };
    if ((reader.byte() orelse return null) != format_version) return null;

    var facts: Facts = .{ .religions = reader.int(u16) orelse return null };
    if (facts.religions & ~religion_mask != 0) return null;

    facts.country_count = reader.byte() orelse return null;
    if (facts.country_count > countries_max) return null;
    for (facts.countries[0..facts.country_count]) |*code| {
        code.* = (reader.take(2) orelse return null)[0..2].*;
        if (!countries.is_assigned(code.*)) return null;
    }

    if (!reader.names(&facts.people)) return null;
    if (!reader.names(&facts.orgs)) return null;
    assert(reader.at <= bytes.len);
    if (reader.at != bytes.len) return null;
    assert(facts.people.len + facts.orgs.len <= 2 * names_max);
    return facts;
}

const Reader = struct {
    bytes: []const u8,
    at: u32 = 0,

    fn take(self: *Reader, len: u32) ?[]const u8 {
        assert(self.at <= self.bytes.len);
        if (@as(usize, self.at) + len > self.bytes.len) return null;
        const taken = self.bytes[self.at..][0..len];
        self.at += len;
        assert(self.at <= self.bytes.len);
        return taken;
    }

    fn byte(self: *Reader) ?u8 {
        const taken = self.take(1) orelse return null;
        assert(taken.len == 1);
        return taken[0];
    }

    fn int(self: *Reader, comptime T: type) ?T {
        comptime assert(@typeInfo(T) == .int);
        const taken = self.take(@sizeOf(T)) orelse return null;
        assert(taken.len == @sizeOf(T));
        return std.mem.readInt(T, taken[0..@sizeOf(T)], .little);
    }

    fn names(self: *Reader, out: *Names) bool {
        out.len = self.byte() orelse return false;
        if (out.len > names_max) return false;
        for (out.items[0..out.len]) |*name| {
            const len = self.byte() orelse return false;
            if (len == 0) return false;
            if (len > name_len_max) return false;
            name.* = self.take(len) orelse return false;
            assert(name.len == len);
            if (!std.unicode.utf8ValidateSlice(name.*)) return false;
        }
        assert(out.len <= names_max);
        return true;
    }
};

const testing = std.testing;

fn encode(facts: *const Facts, out: *[encoded_len_max]u8) []const u8 {
    assert(facts.country_count <= countries_max);
    assert(facts.people.len <= names_max);
    assert(facts.orgs.len <= names_max);
    var writer: std.Io.Writer = .fixed(out);
    writer.writeByte(format_version) catch unreachable;
    writer.writeInt(u16, facts.religions, .little) catch unreachable;
    writer.writeByte(@intCast(facts.country_count)) catch unreachable;
    for (facts.country_slice()) |code| writer.writeAll(&code) catch unreachable;
    for ([_]*const Names{ &facts.people, &facts.orgs }) |names| {
        writer.writeByte(@intCast(names.len)) catch unreachable;
        for (names.slice()) |name| {
            writer.writeByte(@intCast(name.len)) catch unreachable;
            writer.writeAll(name) catch unreachable;
        }
    }
    assert(writer.end <= encoded_len_max);
    return out[0..writer.end];
}

fn sample_facts() Facts {
    var facts: Facts = .{ .religions = @as(u16, 1) << @intFromEnum(Religion.islam) };
    facts.countries[0] = "PK".*;
    facts.country_count = 1;
    facts.people.items[0] = "Rebbe Nachman";
    facts.people.len = 1;
    facts.orgs.items[0] = "Jamia Farooqia";
    facts.orgs.items[1] = "Café Zürich";
    facts.orgs.len = 2;
    assert(countries.is_assigned(facts.countries[0]));
    assert(facts.religions & ~religion_mask == 0);
    return facts;
}

// Encode a sample with every field populated and check the decoded facts match it.
test "entity facts round-trip through their encoding" {
    const facts = sample_facts();
    var buffer: [encoded_len_max]u8 = undefined;
    const decoded = decode(encode(&facts, &buffer)).?;

    try testing.expectEqual(facts.religions, decoded.religions);
    try testing.expectEqualSlices(u8, "PK", &decoded.countries[0]);
    try testing.expectEqualStrings("Rebbe Nachman", decoded.people.slice()[0]);
    try testing.expectEqualStrings("Café Zürich", decoded.orgs.slice()[1]);
}

// Corrupt one field of a valid encoding at a time: unknown religion bits, an unassigned country,
// a trailing byte, a wrong version, invalid UTF-8 in a name and an empty buffer all decode to
// null.
test "decode refuses every malformed encoding" {
    var buffer: [encoded_len_max]u8 = undefined;
    const good = encode(&sample_facts(), &buffer);

    var bad: [encoded_len_max + 1]u8 = undefined;
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
    bad[0] = format_version + 1;
    try testing.expectEqual(@as(?Facts, null), decode(bad[0..good.len]));

    var facts = sample_facts();
    facts.people.items[0] = "\xff\xfe";
    try testing.expectEqual(@as(?Facts, null), decode(encode(&facts, &buffer)));
    try testing.expectEqual(@as(?Facts, null), decode(&.{}));
}
