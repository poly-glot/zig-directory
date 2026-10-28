//! Resolves a URL to the site it belongs to: a hosting platform's subdomain or user path, a
//! `~user` path on any host, or otherwise the registrable domain. A site key is at most
//! `site_len_max` bytes, so a host always fits and only path segments can be cut short.

const std = @import("std");
const assert = std.debug.assert;
const url_facts = @import("url_facts.zig");

pub const site_len_max: usize = 128;

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

pub fn site_of(host: []const u8, path: []const u8, out: *[site_len_max]u8) Site {
    assert(host.len <= url_facts.host_len_max);
    const bare = url_facts.bare_host(host);

    var leading: [2][]const u8 = .{ "", "" };
    var segment_count: usize = 0;
    var segments = std.mem.tokenizeScalar(u8, path, '/');
    while (segment_count < leading.len) : (segment_count += 1) {
        leading[segment_count] = segments.next() orelse break;
    }
    assert(segment_count <= leading.len);

    const first = leading[0];
    if (first.len > 1) {
        if (first[0] == '~') return .{ .key = joined(out, bare, leading[0..1]), .hosted = true };
    }

    for (path_platforms) |platform| {
        if (!std.mem.eql(u8, bare, platform.host)) continue;
        var identifies_site = segment_count >= platform.segments;
        if (platform.leading_segment) |required| {
            if (!std.mem.eql(u8, first, required)) identifies_site = false;
        }
        if (!identifies_site) return .{ .key = joined(out, bare, &.{}), .hosted = false };
        return .{ .key = joined(out, bare, leading[0..platform.segments]), .hosted = true };
    }

    const domain = url_facts.registrable_domain(host);
    if (subdomain_platforms.has(domain)) {
        if (!std.mem.eql(u8, bare, domain)) {
            return .{ .key = joined(out, bare, &.{}), .hosted = true };
        }
    }
    return .{ .key = joined(out, domain, &.{}), .hosted = false };
}

pub fn site_for(url: []const u8, out: *[site_len_max]u8) Site {
    var host_buffer: [url_facts.host_len_max]u8 = undefined;
    const parts = url_facts.split(url, &host_buffer);
    assert(parts.host.len <= url_facts.host_len_max);
    return site_of(parts.host, parts.path, out);
}

fn joined(out: *[site_len_max]u8, host: []const u8, segments: []const []const u8) []const u8 {
    comptime assert(site_len_max >= url_facts.host_len_max);
    assert(host.len <= url_facts.host_len_max);
    assert(segments.len <= 2);
    var writer: std.Io.Writer = .fixed(out);
    writer.writeAll(host) catch unreachable;
    for (segments) |segment| {
        writer.writeByte('/') catch break;
        writer.writeAll(segment) catch break;
    }
    assert(writer.end <= site_len_max);
    return out[0..writer.end];
}

const testing = std.testing;

// On tripod a subdomain is one site, while each members.tripod.com path is a site of its own,
// with or without the tilde.
test "on tripod a subdomain is one site and so is each members.tripod.com path" {
    var out: [site_len_max]u8 = undefined;
    const subdomain = site_for("http://samvak.tripod.com/index.html", &out);
    try testing.expectEqualStrings("samvak.tripod.com", subdomain.key);
    try testing.expect(subdomain.hosted);

    const member = site_for("http://www.members.tripod.com/~fuzzy/cats.htm", &out);
    try testing.expectEqualStrings("members.tripod.com/~fuzzy", member.key);
    try testing.expect(member.hosted);

    const plain_member = site_for("http://members.tripod.com/bobs_page/", &out);
    try testing.expectEqualStrings("members.tripod.com/bobs_page", plain_member.key);
}

// Each path platform keeps exactly the segments that name one site; the platform root itself is
// not a hosted site.
test "path platforms take as many leading segments as identify one site" {
    var out: [site_len_max]u8 = undefined;
    try testing.expectEqualStrings(
        "angelfire.com/ca/joe",
        site_for("http://www.angelfire.com/ca/joe/page.html", &out).key,
    );
    try testing.expectEqualStrings(
        "groups.yahoo.com/group/catlovers",
        site_for("http://groups.yahoo.com/group/catlovers/", &out).key,
    );
    try testing.expectEqualStrings(
        "sites.google.com/site/garden",
        site_for("https://sites.google.com/site/garden/home", &out).key,
    );

    const root = site_for("http://www.angelfire.com/", &out);
    try testing.expectEqualStrings("angelfire.com", root.key);
    try testing.expect(!root.hosted);
}

// A tilde path is a personal site whatever the host.
test "a ~user path is a personal site on any host" {
    var out: [site_len_max]u8 = undefined;
    const site = site_for("http://www.cs.example.edu/~ada/notes/", &out);
    try testing.expectEqualStrings("cs.example.edu/~ada", site.key);
    try testing.expect(site.hosted);
}

// Without a platform rule the site is the registrable domain, and a platform's own front page
// is that domain rather than a hosted site.
test "everywhere else a site is the registrable domain" {
    var out: [site_len_max]u8 = undefined;
    const site = site_for("http://news.bbc.co.uk/sport/", &out);
    try testing.expectEqualStrings("bbc.co.uk", site.key);
    try testing.expect(!site.hosted);
    try testing.expectEqualStrings("tripod.com", site_for("http://www.tripod.com/", &out).key);
}
