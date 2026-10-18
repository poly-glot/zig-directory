const std = @import("std");
const url_facts = @import("url_facts.zig");

pub const MAX_SITE_LEN: usize = 128;

pub const Site = struct {
    key: []const u8,
    hosted: bool,
};

const PathPlatform = struct {
    host: []const u8,
    leading_segment: ?[]const u8 = null,
    segments: u8,
};

const path_platforms = [_]PathPlatform{
    .{ .host = "members.tripod.com", .segments = 1 },
    .{ .host = "angelfire.com", .segments = 2 },
    .{ .host = "groups.yahoo.com", .leading_segment = "group", .segments = 2 },
    .{ .host = "sites.google.com", .leading_segment = "site", .segments = 2 },
    .{ .host = "freewebs.com", .segments = 1 },
};

const subdomain_platforms = std.StaticStringMap(void).initComptime(.{
    .{"50megs.com"},      .{"8m.com"},        .{"blogspot.com"},    .{"free.fr"},
    .{"freeservers.com"}, .{"homestead.com"}, .{"livejournal.com"}, .{"proboards.com"},
    .{"tripod.com"},      .{"typepad.com"},   .{"webs.com"},        .{"weebly.com"},
    .{"wordpress.com"},
});

pub fn siteOf(host: []const u8, path: []const u8, out: *[MAX_SITE_LEN]u8) Site {
    const bare = url_facts.bareHost(host);

    var leading: [2][]const u8 = .{ "", "" };
    var segment_count: usize = 0;
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segment_count < leading.len) : (segment_count += 1) {
        leading[segment_count] = segments.next() orelse break;
    }

    if (segment_count > 0 and leading[0].len > 1 and leading[0][0] == '~') {
        return .{ .key = joined(out, bare, leading[0..1]), .hosted = true };
    }

    for (path_platforms) |platform| {
        if (!std.mem.eql(u8, bare, platform.host)) continue;
        const identifies_site = segment_count >= platform.segments and
            (platform.leading_segment == null or std.mem.eql(u8, leading[0], platform.leading_segment.?));
        if (!identifies_site) return .{ .key = joined(out, bare, &.{}), .hosted = false };
        return .{ .key = joined(out, bare, leading[0..platform.segments]), .hosted = true };
    }

    const domain = url_facts.registrableDomain(host);
    if (subdomain_platforms.has(domain) and !std.mem.eql(u8, bare, domain)) {
        return .{ .key = joined(out, bare, &.{}), .hosted = true };
    }
    return .{ .key = joined(out, domain, &.{}), .hosted = false };
}

pub fn siteFor(url: []const u8, out: *[MAX_SITE_LEN]u8) Site {
    var host_buf: [url_facts.MAX_HOST_LEN]u8 = undefined;
    const parts = url_facts.split(url, &host_buf);
    return siteOf(parts.host, parts.path, out);
}

fn joined(out: *[MAX_SITE_LEN]u8, host: []const u8, segments: []const []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeAll(host) catch return out[0..w.end];
    for (segments) |segment| {
        w.writeByte('/') catch break;
        w.writeAll(segment) catch break;
    }
    return out[0..w.end];
}

const testing = std.testing;

test "on tripod a subdomain is one site and so is each members.tripod.com path" {
    var out: [MAX_SITE_LEN]u8 = undefined;
    const sub = siteFor("http://samvak.tripod.com/index.html", &out);
    try testing.expectEqualStrings("samvak.tripod.com", sub.key);
    try testing.expect(sub.hosted);

    const member = siteFor("http://www.members.tripod.com/~fuzzy/cats.htm", &out);
    try testing.expectEqualStrings("members.tripod.com/~fuzzy", member.key);
    try testing.expect(member.hosted);

    const plain_member = siteFor("http://members.tripod.com/bobs_page/", &out);
    try testing.expectEqualStrings("members.tripod.com/bobs_page", plain_member.key);
}

test "path platforms take as many leading segments as identify one site" {
    var out: [MAX_SITE_LEN]u8 = undefined;
    try testing.expectEqualStrings("angelfire.com/ca/joe", siteFor("http://www.angelfire.com/ca/joe/page.html", &out).key);
    try testing.expectEqualStrings("groups.yahoo.com/group/catlovers", siteFor("http://groups.yahoo.com/group/catlovers/", &out).key);
    try testing.expectEqualStrings("sites.google.com/site/garden", siteFor("https://sites.google.com/site/garden/home", &out).key);

    const root = siteFor("http://www.angelfire.com/", &out);
    try testing.expectEqualStrings("angelfire.com", root.key);
    try testing.expect(!root.hosted);
}

test "a ~user path is a personal site on any host" {
    var out: [MAX_SITE_LEN]u8 = undefined;
    const site = siteFor("http://www.cs.example.edu/~ada/notes/", &out);
    try testing.expectEqualStrings("cs.example.edu/~ada", site.key);
    try testing.expect(site.hosted);
}

test "everywhere else a site is the registrable domain" {
    var out: [MAX_SITE_LEN]u8 = undefined;
    const site = siteFor("http://news.bbc.co.uk/sport/", &out);
    try testing.expectEqualStrings("bbc.co.uk", site.key);
    try testing.expect(!site.hosted);
    try testing.expectEqualStrings("tripod.com", siteFor("http://www.tripod.com/", &out).key);
}
