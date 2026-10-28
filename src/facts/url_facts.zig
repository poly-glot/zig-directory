//! Takes a stored URL apart into the host facts the directory reasons about: the bare host, the
//! registrable domain and the ccTLD country. A host is at most `host_len_max` bytes and carries
//! neither credentials nor a port.

const std = @import("std");
const assert = std.debug.assert;
const countries = @import("countries.zig");

pub const host_len_max: usize = 64;

pub const Url = struct {
    host: []const u8,
    path: []const u8,
};

const public_second_levels = std.StaticStringMap(void).initComptime(.{
    .{"ac"},  .{"asn"},  .{"biz"},    .{"co"},  .{"com"},  .{"edu"}, .{"gen"}, .{"go"},
    .{"gob"}, .{"gouv"}, .{"gov"},    .{"id"},  .{"info"}, .{"k12"}, .{"lg"},  .{"ltd"},
    .{"me"},  .{"mil"},  .{"ne"},     .{"net"}, .{"nhs"},  .{"nic"}, .{"nom"}, .{"or"},
    .{"org"}, .{"plc"},  .{"police"}, .{"res"}, .{"sch"},  .{"tm"},
});

const vanity_cctlds = std.StaticStringMap(void).initComptime(.{
    .{"ac"}, .{"ag"}, .{"ai"}, .{"am"}, .{"cc"}, .{"co"}, .{"eu"}, .{"fm"},
    .{"gg"}, .{"io"}, .{"la"}, .{"ly"}, .{"md"}, .{"me"}, .{"ms"}, .{"nu"},
    .{"sh"}, .{"su"}, .{"tk"}, .{"to"}, .{"tv"}, .{"vc"}, .{"ws"},
});

pub fn split(url: []const u8, host_buffer: *[host_len_max]u8) Url {
    const after_scheme = if (std.mem.find(u8, url, "://")) |at| url[at + 3 ..] else url;
    const host_end = std.mem.findAny(u8, after_scheme, "/?#") orelse after_scheme.len;

    var authority = after_scheme[0..host_end];
    if (std.mem.findScalarLast(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (std.mem.findScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
    authority = std.mem.trimEnd(u8, authority, ".");
    assert(std.mem.findScalar(u8, authority, '@') == null);
    assert(std.mem.findScalar(u8, authority, ':') == null);

    const rest = after_scheme[host_end..];
    const path_end = std.mem.findAny(u8, rest, "?#") orelse rest.len;
    const host_len = @min(authority.len, host_len_max);
    const parts: Url = .{
        .host = std.ascii.lowerString(host_buffer, authority[0..host_len]),
        .path = rest[0..path_end],
    };
    assert(parts.host.len <= host_len_max);
    assert(std.mem.findAny(u8, parts.path, "?#") == null);
    return parts;
}

pub fn bare_host(host: []const u8) []const u8 {
    const bare = if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
    assert(bare.len <= host.len);
    const stripped = host.len - bare.len;
    if (stripped != 0) assert(stripped == 4);
    return bare;
}

pub fn registrable_domain(host: []const u8) []const u8 {
    const domain = cut: {
        const last_dot = std.mem.findScalarLast(u8, host, '.') orelse break :cut host;
        const second_dot = std.mem.findScalarLast(u8, host[0..last_dot], '.') orelse
            break :cut host;

        const tld = host[last_dot + 1 ..];
        const second_level = host[second_dot + 1 .. last_dot];
        if (tld.len != 2) break :cut host[second_dot + 1 ..];
        if (!public_second_levels.has(second_level)) break :cut host[second_dot + 1 ..];

        const third_dot = std.mem.findScalarLast(u8, host[0..second_dot], '.') orelse
            break :cut host;
        break :cut host[third_dot + 1 ..];
    };
    assert(std.mem.endsWith(u8, host, domain));
    if (domain.len < host.len) assert(host[host.len - domain.len - 1] == '.');
    return domain;
}

pub fn has_suffix(host: []const u8, suffix: []const u8) bool {
    assert(suffix.len > 0);
    if (std.mem.eql(u8, host, suffix)) return true;
    if (host.len <= suffix.len) return false;
    if (!std.mem.endsWith(u8, host, suffix)) return false;
    return host[host.len - suffix.len - 1] == '.';
}

pub fn cctld_country(host: []const u8) ?countries.Code {
    comptime assert(@sizeOf(countries.Code) == 2);
    comptime assert(countries.is_assigned("GB".*));
    const last_dot = std.mem.findScalarLast(u8, host, '.') orelse return null;
    const tld = host[last_dot + 1 ..];
    if (tld.len != 2) return null;
    if (vanity_cctlds.has(tld)) return null;
    if (std.mem.eql(u8, tld, "uk")) return "GB".*;

    const code: countries.Code = .{ std.ascii.toUpper(tld[0]), std.ascii.toUpper(tld[1]) };
    if (!countries.is_assigned(code)) return null;
    return code;
}

const testing = std.testing;

// Split a URL with every optional part present and check only the lowercased host and the bare
// path survive; a trailing dot and a missing path are handled too.
test "split lowercases the host and drops scheme, credentials, port, query and fragment" {
    var buffer: [host_len_max]u8 = undefined;
    const url = split("HTTP://user:pw@Members.Tripod.COM:8080/~Bob/index.html?x=1#top", &buffer);
    try testing.expectEqualStrings("members.tripod.com", url.host);
    try testing.expectEqualStrings("/~Bob/index.html", url.path);

    try testing.expectEqualStrings("example.org", split("example.org.", &buffer).host);
    try testing.expectEqualStrings("", split("https://bbc.co.uk", &buffer).path);
}

// The registrable domain is the last two labels, or three under a public second level of a
// two-letter ccTLD; a bare second level and a single label come back unchanged.
test "the registrable domain keeps a third label only under a public ccTLD second level" {
    try testing.expectEqualStrings("tripod.com", registrable_domain("samvak.tripod.com"));
    try testing.expectEqualStrings("bbc.co.uk", registrable_domain("news.bbc.co.uk"));
    try testing.expectEqualStrings(
        "storyofpakistan.com",
        registrable_domain("www.storyofpakistan.com"),
    );
    try testing.expectEqualStrings("example.co.jp", registrable_domain("www.example.co.jp"));
    try testing.expectEqualStrings("co.uk", registrable_domain("co.uk"));
    try testing.expectEqualStrings("localhost", registrable_domain("localhost"));
}

// A suffix matches the whole host or a label-aligned tail, never a partial label.
test "a domain suffix matches on label boundaries only" {
    try testing.expect(has_suffix("tripod.com", "tripod.com"));
    try testing.expect(has_suffix("samvak.tripod.com", "tripod.com"));
    try testing.expect(has_suffix("www.example.com.pk", "pk"));
    try testing.expect(!has_suffix("nottripod.com", "tripod.com"));
    try testing.expect(!has_suffix("tripod.com.au", "tripod.com"));
}

// A real ccTLD names its country and .uk maps to GB; a vanity ccTLD, a generic TLD and a host
// without a dot give null.
test "a ccTLD names its country unless it is sold as a vanity domain" {
    try testing.expectEqual(@as(?countries.Code, "PK".*), cctld_country("www.uet.edu.pk"));
    try testing.expectEqual(@as(?countries.Code, "GB".*), cctld_country("bbc.co.uk"));
    try testing.expectEqual(@as(?countries.Code, "JP".*), cctld_country("example.jp"));
    try testing.expectEqual(@as(?countries.Code, null), cctld_country("startup.io"));
    try testing.expectEqual(@as(?countries.Code, null), cctld_country("show.tv"));
    try testing.expectEqual(@as(?countries.Code, null), cctld_country("example.com"));
    try testing.expectEqual(@as(?countries.Code, null), cctld_country("localhost"));
}
