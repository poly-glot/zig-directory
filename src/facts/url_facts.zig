const std = @import("std");
const countries = @import("countries.zig");

pub const MAX_HOST_LEN: usize = 64;

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

pub fn split(url: []const u8, host_buf: *[MAX_HOST_LEN]u8) Url {
    const after_scheme = if (std.mem.find(u8, url, "://")) |at| url[at + 3 ..] else url;
    const host_end = std.mem.findAny(u8, after_scheme, "/?#") orelse after_scheme.len;

    var authority = after_scheme[0..host_end];
    if (std.mem.findScalarLast(u8, authority, '@')) |at| authority = authority[at + 1 ..];
    if (std.mem.findScalar(u8, authority, ':')) |colon| authority = authority[0..colon];
    authority = std.mem.trimEnd(u8, authority, ".");

    const rest = after_scheme[host_end..];
    const path_end = std.mem.findAny(u8, rest, "?#") orelse rest.len;
    return .{
        .host = std.ascii.lowerString(host_buf, authority[0..@min(authority.len, MAX_HOST_LEN)]),
        .path = rest[0..path_end],
    };
}

pub fn bareHost(host: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, host, "www.")) host[4..] else host;
}

pub fn registrableDomain(host: []const u8) []const u8 {
    const last_dot = std.mem.findScalarLast(u8, host, '.') orelse return host;
    const second_dot = std.mem.findScalarLast(u8, host[0..last_dot], '.') orelse return host;

    const tld = host[last_dot + 1 ..];
    const second_level = host[second_dot + 1 .. last_dot];
    if (tld.len != 2 or !public_second_levels.has(second_level)) return host[second_dot + 1 ..];

    const third_dot = std.mem.findScalarLast(u8, host[0..second_dot], '.') orelse return host;
    return host[third_dot + 1 ..];
}

pub fn hasSuffix(host: []const u8, suffix: []const u8) bool {
    if (std.mem.eql(u8, host, suffix)) return true;
    return host.len > suffix.len and
        std.mem.endsWith(u8, host, suffix) and
        host[host.len - suffix.len - 1] == '.';
}

pub fn cctldCountry(host: []const u8) ?countries.Code {
    const last_dot = std.mem.findScalarLast(u8, host, '.') orelse return null;
    const tld = host[last_dot + 1 ..];
    if (tld.len != 2 or vanity_cctlds.has(tld)) return null;
    if (std.mem.eql(u8, tld, "uk")) return "GB".*;

    const code: countries.Code = .{ std.ascii.toUpper(tld[0]), std.ascii.toUpper(tld[1]) };
    return if (countries.isAssigned(code)) code else null;
}

const testing = std.testing;

fn hostOf(url: []const u8) []const u8 {
    const S = struct {
        var buf: [MAX_HOST_LEN]u8 = undefined;
    };
    return split(url, &S.buf).host;
}

test "split lowercases the host and drops scheme, credentials, port, query and fragment" {
    var buf: [MAX_HOST_LEN]u8 = undefined;
    const url = split("HTTP://user:pw@Members.Tripod.COM:8080/~Bob/index.html?x=1#top", &buf);
    try testing.expectEqualStrings("members.tripod.com", url.host);
    try testing.expectEqualStrings("/~Bob/index.html", url.path);

    try testing.expectEqualStrings("example.org", split("example.org.", &buf).host);
    try testing.expectEqualStrings("", split("https://bbc.co.uk", &buf).path);
}

test "the registrable domain keeps a third label only under a public second level of a ccTLD" {
    try testing.expectEqualStrings("tripod.com", registrableDomain("samvak.tripod.com"));
    try testing.expectEqualStrings("bbc.co.uk", registrableDomain("news.bbc.co.uk"));
    try testing.expectEqualStrings("storyofpakistan.com", registrableDomain("www.storyofpakistan.com"));
    try testing.expectEqualStrings("example.co.jp", registrableDomain("www.example.co.jp"));
    try testing.expectEqualStrings("co.uk", registrableDomain("co.uk"));
    try testing.expectEqualStrings("localhost", registrableDomain("localhost"));
}

test "a domain suffix matches on label boundaries only" {
    try testing.expect(hasSuffix("tripod.com", "tripod.com"));
    try testing.expect(hasSuffix("samvak.tripod.com", "tripod.com"));
    try testing.expect(hasSuffix("www.example.com.pk", "pk"));
    try testing.expect(!hasSuffix("nottripod.com", "tripod.com"));
    try testing.expect(!hasSuffix("tripod.com.au", "tripod.com"));
}

test "a ccTLD names its country unless it is sold as a vanity domain" {
    try testing.expectEqual(@as(?countries.Code, "PK".*), cctldCountry(hostOf("http://www.uet.edu.pk/")));
    try testing.expectEqual(@as(?countries.Code, "GB".*), cctldCountry(hostOf("bbc.co.uk")));
    try testing.expectEqual(@as(?countries.Code, "JP".*), cctldCountry(hostOf("example.jp")));
    try testing.expectEqual(@as(?countries.Code, null), cctldCountry(hostOf("startup.io")));
    try testing.expectEqual(@as(?countries.Code, null), cctldCountry(hostOf("show.tv")));
    try testing.expectEqual(@as(?countries.Code, null), cctldCountry(hostOf("example.com")));
    try testing.expectEqual(@as(?countries.Code, null), cctldCountry(hostOf("localhost")));
}
