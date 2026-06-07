const std = @import("std");
const zigstore = @import("zigstore");
const codec = zigstore.codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");

const OperationError = shared.OperationError;
const MAX_URL_LEN = shared.MAX_URL_LEN;
const MAX_TITLE_LEN = shared.MAX_TITLE_LEN;
const MAX_LINK_DESC_LEN = shared.MAX_LINK_DESC_LEN;

pub const CreateLinkOpts = struct {
    status: u8 = @intFromEnum(schema.LinkStatus.approved),
    submitter_id: u64 = 0,
};

pub fn createLink(
    db: *Directory,
    category_id: u64,
    url: []const u8,
    title: []const u8,
    desc: []const u8,
) !u64 {
    return createLinkWithOpts(db, category_id, url, title, desc, .{});
}

pub fn createLinkWithOpts(
    db: *Directory,
    category_id: u64,
    url: []const u8,
    title: []const u8,
    desc: []const u8,
    opts: CreateLinkOpts,
) !u64 {
    if (url.len > MAX_URL_LEN) return OperationError.FieldTooLong;
    if (title.len > MAX_TITLE_LEN) return OperationError.FieldTooLong;
    if (desc.len > MAX_LINK_DESC_LEN) return OperationError.FieldTooLong;

    if (category_id != 0) {
        if ((try category.getCategory(db, category_id)) == null) return OperationError.CategoryNotFound;
    }

    const url_hash = codec.hash(url);
    const hash_key = codec.encodeU64(url_hash);
    if (db.url_bloom.mayContain(url)) {
        const mt_hash = db.mt_link_by_url_hash().get(&hash_key);
        var hash_buf: [8]u8 = undefined;
        const tree_hash = switch (mt_hash) {
            .found, .deleted => null,
            .not_found => try db.link_by_url_hash().search(&hash_key, &hash_buf),
        };
        const existing_id_bytes: ?[]const u8 = switch (mt_hash) {
            .found => |v| v,
            .deleted => null,
            .not_found => tree_hash,
        };
        if (existing_id_bytes) |bytes| {
            if (bytes.len >= 8) {
                const existing_link_id = codec.decodeU64(bytes);
                if (try getLink(db, existing_link_id)) |existing_link| {
                    if (std.mem.eql(u8, existing_link.url.slice(), url)) {
                        return OperationError.DuplicateUrl;
                    }
                }
            }
        }
    }

    const id = db.next_link_id.fetchAdd(1, .monotonic);
    const now = std.time.timestamp();

    const link = schema.Link{
        .id = id,
        .category_id = category_id,
        .url = codec.FixedString(64).fromSlice(url),
        .title = codec.FixedString(128).fromSlice(title),
        .description = codec.FixedString(256).fromSlice(desc),
        .sort_order = 0,
        ._pad0 = 0,
        .created_at = now,
        .updated_at = now,
        .status = opts.status,
        .submitter_id = opts.submitter_id,
    };

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkInsertChangeSet(db, link, arena.allocator());

    try db.commit(cs);

    return id;
}

pub fn getLink(db: *Directory, id: u64) !?schema.Link {
    const key = codec.encodeU64(id);
    const mt_result = db.mt_links_by_id().get(&key);
    var tree_buf: [@sizeOf(schema.Link)]u8 = undefined;
    const val = switch (mt_result) {
        .found => |v| v,
        .deleted => return null,
        .not_found => (try db.links_by_id().search(&key, &tree_buf)) orelse return null,
    };
    if (val.len != @sizeOf(schema.Link)) return OperationError.DatabaseCorrupted;
    return std.mem.bytesToValue(schema.Link, val[0..@sizeOf(schema.Link)]);
}

pub fn updateLink(
    db: *Directory,
    id: u64,
    url: ?[]const u8,
    title: ?[]const u8,
    desc: ?[]const u8,
) !void {
    if (url) |u| if (u.len > MAX_URL_LEN) return OperationError.FieldTooLong;
    if (title) |t| if (t.len > MAX_TITLE_LEN) return OperationError.FieldTooLong;
    if (desc) |d| if (d.len > MAX_LINK_DESC_LEN) return OperationError.FieldTooLong;

    const old_link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;

    var new_link = old_link;
    if (url) |new_url| new_link.url = codec.FixedString(64).fromSlice(new_url);
    if (title) |t| new_link.title = codec.FixedString(128).fromSlice(t);
    if (desc) |d| new_link.description = codec.FixedString(256).fromSlice(d);
    new_link.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkTextUpdateChangeSet(old_link, new_link, arena.allocator());

    try db.commit(cs);
}

pub fn updateLinkStatus(db: *Directory, id: u64, status: u8) !void {
    const old_link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;
    var new_link = old_link;
    new_link.status = status;
    new_link.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkTextUpdateChangeSet(old_link, new_link, arena.allocator());

    try db.commit(cs);
}

pub fn updateLinkStatusBulkOne(db: *Directory, id: u64, status: u8) !void {
    const old_link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;
    if (old_link.status == status) return OperationError.AlreadyInState;
    var new_link = old_link;
    new_link.status = status;
    new_link.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkTextUpdateChangeSet(old_link, new_link, arena.allocator());

    try db.commit(cs);
}

pub const StatusCounts = struct { pending: u64, approved: u64, rejected: u64 };

pub fn countsByStatus(db: *Directory) !StatusCounts {
    return .{
        .pending = db.links_pending_count.load(.monotonic),
        .approved = db.links_approved_count.load(.monotonic),
        .rejected = db.links_rejected_count.load(.monotonic),
    };
}

pub fn recountLinkStatuses(db: *Directory) !void {
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    const bloom_capacity = @max(db.links_by_id().entry_count *| 2, 1_000_000);
    const reseeded = zigstore.BloomFilter.init(db.allocator, bloom_capacity) catch null;
    if (reseeded) |new_bloom| {
        db.url_bloom.deinit();
        db.url_bloom = new_bloom;
    }

    var pending: u64 = 0;
    var approved: u64 = 0;
    var rejected: u64 = 0;
    const start_key = codec.encodeU64(0);
    var iter = try db.links_by_id().rangeScan(&start_key, null);
    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(schema.Link)) continue;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        db.url_bloom.add(link.url.slice());
        switch (link.status) {
            @intFromEnum(schema.LinkStatus.pending) => pending += 1,
            @intFromEnum(schema.LinkStatus.approved) => approved += 1,
            @intFromEnum(schema.LinkStatus.rejected) => rejected += 1,
            else => {},
        }
    }

    db.links_pending_count.store(pending, .monotonic);
    db.links_approved_count.store(approved, .monotonic);
    db.links_rejected_count.store(rejected, .monotonic);
}

pub fn moveLink(db: *Directory, id: u64, new_category_id: u64) !void {
    const old_link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;

    if (new_category_id == 0) return OperationError.CategoryNotFound;
    if ((try category.getCategory(db, new_category_id)) == null) {
        return OperationError.CategoryNotFound;
    }

    if (old_link.category_id == new_category_id) return;

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkRecatChangeSet(
        db,
        old_link,
        new_category_id,
        arena.allocator(),
    );

    try db.commit(cs);
}

pub fn deleteLink(db: *Directory, id: u64) !void {
    const link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkDeleteChangeSet(db, link, arena.allocator());

    try db.commit(cs);
}

pub const LinkPage = struct { items: []schema.Link, next_after_id: u64 };

pub fn listLinks(
    db: *Directory,
    category_id: u64,
    offset: u32,
    limit: u32,
    buf: []schema.Link,
    status_filter: ?u8,
    after_id: u64,
) !LinkPage {
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());

    const cursor_mode = after_id > 0;
    const seek_id: u64 = if (cursor_mode) after_id +| 1 else 0;
    const start_key = schema.CategoryLinkKey.encode(category_id, seek_id);
    const end_key = schema.CategoryLinkKey.encode(category_id, std.math.maxInt(u64));

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;

    var iter = try db.link_by_category().rangeScan(&start_key, &end_key);
    while (try iter.next()) |entry| {
        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const link_id = codec.decodeU64(entry.value);
        const link = (try getLink(db, link_id)) orelse continue;
        if (status_filter) |s| if (link.status != s) continue;
        if (!cursor_mode and skipped < offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) {
            next_after_id = last_id;
            break;
        }
        buf[count] = link;
        last_id = link.id;
        count += 1;
    }

    return .{ .items = buf[0..count], .next_after_id = next_after_id };
}

pub fn listLinksBySubmitter(
    db: *Directory,
    submitter_id: u64,
    offset: u32,
    limit: u32,
    buf: []schema.Link,
    status_filter: ?u8,
    after_id: u64,
) !LinkPage {
    db.drainOneMemtable(db.mt_link_by_submitter(), db.link_by_submitter());

    const cursor_mode = after_id > 0;
    const seek_id: u64 = if (cursor_mode) after_id +| 1 else 0;
    const start_key = schema.SubmitterLinkKey.encode(submitter_id, seek_id);
    const end_key = schema.SubmitterLinkKey.encode(submitter_id, std.math.maxInt(u64));

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;

    var iter = try db.link_by_submitter().rangeScan(&start_key, &end_key);
    while (try iter.next()) |entry| {
        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const link_id = codec.decodeU64(entry.value);
        const link = (try getLink(db, link_id)) orelse continue;
        if (status_filter) |s| if (link.status != s) continue;
        if (!cursor_mode and skipped < offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) {
            next_after_id = last_id;
            break;
        }
        buf[count] = link;
        last_id = link.id;
        count += 1;
    }

    return .{ .items = buf[0..count], .next_after_id = next_after_id };
}

pub fn listAllLinks(
    db: *Directory,
    offset: u32,
    limit: u32,
    buf: []schema.Link,
    status_filter: ?u8,
    after_id: u64,
) !LinkPage {
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    const cursor_mode = after_id > 0;
    const seek_id: u64 = if (cursor_mode) after_id +| 1 else 0;
    const start_key = codec.encodeU64(seek_id);

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;

    var iter = try db.links_by_id().rangeScan(&start_key, null);
    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(schema.Link)) continue;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        if (status_filter) |s| if (link.status != s) continue;
        if (!cursor_mode and skipped < offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) {
            next_after_id = last_id;
            break;
        }
        buf[count] = link;
        last_id = link.id;
        count += 1;
    }

    return .{ .items = buf[0..count], .next_after_id = next_after_id };
}

test "listLinksBySubmitter: returns only the requested user's submissions, ordered by id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");

    _ = try createLinkWithOpts(db, top_id, "https://a1.example", "a1", "", .{ .submitter_id = 100 });
    _ = try createLinkWithOpts(db, top_id, "https://b1.example", "b1", "", .{ .submitter_id = 200 });
    _ = try createLink(db, top_id, "https://legacy.example", "legacy", "");
    _ = try createLinkWithOpts(db, top_id, "https://a2.example", "a2", "", .{ .submitter_id = 100 });
    _ = try createLinkWithOpts(db, top_id, "https://b2.example", "b2", "", .{ .submitter_id = 200 });
    _ = try createLinkWithOpts(db, top_id, "https://a3.example", "a3", "", .{ .submitter_id = 100 });

    var buf: [10]schema.Link = undefined;

    const a_links = (try listLinksBySubmitter(db, 100, 0, 10, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 3), a_links.len);
    try std.testing.expect(a_links[0].id < a_links[1].id);
    try std.testing.expect(a_links[1].id < a_links[2].id);
    for (a_links) |l| try std.testing.expectEqual(@as(u64, 100), l.submitter_id);

    const b_links = (try listLinksBySubmitter(db, 200, 0, 10, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 2), b_links.len);
    for (b_links) |l| try std.testing.expectEqual(@as(u64, 200), l.submitter_id);

    const zero_links = (try listLinksBySubmitter(db, 0, 0, 10, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 0), zero_links.len);
}

test "listLinksBySubmitter: pagination via offset" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://x{d}.example", .{i});
        _ = try createLinkWithOpts(db, top_id, url, "x", "", .{ .submitter_id = 42 });
    }

    var buf: [10]schema.Link = undefined;
    const page1 = (try listLinksBySubmitter(db, 42, 0, 2, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 2), page1.len);
    const first_id = page1[0].id;
    const second_id = page1[1].id;

    const page2 = (try listLinksBySubmitter(db, 42, 2, 2, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 2), page2.len);
    try std.testing.expect(page2[0].id > second_id);
    _ = first_id;
}

test "listLinksBySubmitter: cursor (after_id) resumes past the given id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    var ids: [5]u64 = undefined;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://c{d}.example", .{i});
        ids[i] = try createLinkWithOpts(db, top_id, url, "c", "", .{ .submitter_id = 77 });
    }

    var buf: [10]schema.Link = undefined;

    const p1 = try listLinksBySubmitter(db, 77, 0, 2, &buf, null, 0);
    try std.testing.expectEqual(@as(usize, 2), p1.items.len);
    try std.testing.expectEqual(ids[0], p1.items[0].id);
    try std.testing.expectEqual(ids[1], p1.items[1].id);
    try std.testing.expectEqual(ids[1], p1.next_after_id);

    const p2 = try listLinksBySubmitter(db, 77, 0, 2, &buf, null, p1.next_after_id);
    try std.testing.expectEqual(@as(usize, 2), p2.items.len);
    try std.testing.expectEqual(ids[2], p2.items[0].id);
    try std.testing.expectEqual(ids[3], p2.items[1].id);
    try std.testing.expectEqual(ids[3], p2.next_after_id);

    const p3 = try listLinksBySubmitter(db, 77, 0, 2, &buf, null, p2.next_after_id);
    try std.testing.expectEqual(@as(usize, 1), p3.items.len);
    try std.testing.expectEqual(ids[4], p3.items[0].id);
    try std.testing.expectEqual(@as(u64, 0), p3.next_after_id);
}

test "countsByStatus tallies per-status totals" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const rejected = @intFromEnum(schema.LinkStatus.rejected);

    _ = try createLinkWithOpts(db, top_id, "https://p1.example", "p1", "", .{ .status = pending });
    _ = try createLinkWithOpts(db, top_id, "https://p2.example", "p2", "", .{ .status = pending });
    _ = try createLinkWithOpts(db, top_id, "https://a1.example", "a1", "", .{ .status = approved });
    _ = try createLinkWithOpts(db, top_id, "https://a2.example", "a2", "", .{ .status = approved });
    _ = try createLinkWithOpts(db, top_id, "https://a3.example", "a3", "", .{ .status = approved });
    _ = try createLinkWithOpts(db, top_id, "https://r1.example", "r1", "", .{ .status = rejected });

    const counts = try countsByStatus(db);
    try std.testing.expectEqual(@as(u64, 2), counts.pending);
    try std.testing.expectEqual(@as(u64, 3), counts.approved);
    try std.testing.expectEqual(@as(u64, 1), counts.rejected);
}

test "countsByStatus: status change moves the tally; text edit does not" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const rejected = @intFromEnum(schema.LinkStatus.rejected);

    const id = try createLinkWithOpts(db, top_id, "https://flip.example", "f", "", .{ .status = pending });
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 1), c.pending);
        try std.testing.expectEqual(@as(u64, 0), c.approved);
        try std.testing.expectEqual(@as(u64, 0), c.rejected);
    }

    try updateLinkStatus(db, id, approved);
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 0), c.pending);
        try std.testing.expectEqual(@as(u64, 1), c.approved);
        try std.testing.expectEqual(@as(u64, 0), c.rejected);
    }

    try updateLinkStatus(db, id, rejected);
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 0), c.approved);
        try std.testing.expectEqual(@as(u64, 1), c.rejected);
    }

    try updateLink(db, id, null, "renamed", null);
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 0), c.approved);
        try std.testing.expectEqual(@as(u64, 1), c.rejected);
        try std.testing.expectEqual(@as(u64, 0), c.pending);
    }
}

test "countsByStatus: deleteLink decrements the tally" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const id = try createLinkWithOpts(db, top_id, "https://del.example", "d", "", .{ .status = approved });
    try std.testing.expectEqual(@as(u64, 1), (try countsByStatus(db)).approved);

    try deleteLink(db, id);
    try std.testing.expectEqual(@as(u64, 0), (try countsByStatus(db)).approved);
}

test "recountLinkStatuses: counters are reseeded from disk on reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);

    {
        var db = try Directory.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        const top_id = try category.createCategory(db, 0, "Top", "top", "");
        _ = try createLinkWithOpts(db, top_id, "https://p1.example", "p1", "", .{ .status = pending });
        _ = try createLinkWithOpts(db, top_id, "https://p2.example", "p2", "", .{ .status = pending });
        _ = try createLinkWithOpts(db, top_id, "https://a1.example", "a1", "", .{ .status = approved });
    }

    {
        var db = try Directory.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        try db.recover();
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 2), c.pending);
        try std.testing.expectEqual(@as(u64, 1), c.approved);
        try std.testing.expectEqual(@as(u64, 0), c.rejected);
    }
}

test "updateLinkStatusBulkOne maps no-op to AlreadyInState and missing to LinkNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const id = try createLinkWithOpts(db, top_id, "https://s.example", "s", "", .{ .status = pending });

    try updateLinkStatusBulkOne(db, id, approved);
    try std.testing.expectEqual(approved, (try getLink(db, id)).?.status);

    try std.testing.expectError(OperationError.AlreadyInState, updateLinkStatusBulkOne(db, id, approved));

    try std.testing.expectError(OperationError.LinkNotFound, updateLinkStatusBulkOne(db, 999_999, approved));
}

test "deleteLink removes link_by_submitter entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLinkWithOpts(db, top_id, "https://gone.example", "g", "", .{ .submitter_id = 7 });

    var buf: [4]schema.Link = undefined;
    {
        const before = (try listLinksBySubmitter(db, 7, 0, 4, &buf, null, 0)).items;
        try std.testing.expectEqual(@as(usize, 1), before.len);
    }

    try deleteLink(db, link_id);

    const after = (try listLinksBySubmitter(db, 7, 0, 4, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "createLink rollback: failure during secondary insert leaves no trace in primary" {
    const std_t = std.testing;

    const allocator = std_t.allocator;
    var mt = zigstore.MemTable.init(allocator);
    defer mt.deinit();

    const k1 = codec.encodeU64(123);
    try mt.put(&k1, "value");

    const before = mt.get(&k1);
    try std_t.expect(before == .found);

    try mt.delete(&k1);

    const after = mt.get(&k1);
    try std_t.expect(after == .deleted);
}

test "createLink cascades link_count_subtree up the chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const b_id = try category.createCategory(db, a_id, "B", "b", "");

    _ = try createLink(db, b_id, "https://x.example", "x", "");

    const top = (try category.getCategory(db, top_id)).?;
    const a = (try category.getCategory(db, a_id)).?;
    const b = (try category.getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u64, 1), b.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
}

test "createLink: links_index_tree has token entries" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLink(db, top_id, "https://x.example", "Hello World", "Greeting message");

    var v_buf: [8]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const id_be = codec.encodeU64(link_id);

    const expected_tokens = [_][]const u8{ "hello", "https", "greeting" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }
}

test "deleteLink cascades link_count_subtree decrement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const link_id = try createLink(db, a_id, "https://x.example", "x", "");

    try deleteLink(db, link_id);

    const top = (try category.getCategory(db, top_id)).?;
    const a = (try category.getCategory(db, a_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 0), top.link_count_subtree);
}

test "deleteLink: tokens are removed from links_index_tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLink(db, top_id, "https://y.example", "Goodbye Cruel", "Farewell note");

    var v_buf: [8]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const id_be = codec.encodeU64(link_id);
    const expected_tokens = [_][]const u8{ "goodbye", "https", "farewell" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }
    try std.testing.expect((try getLink(db, link_id)) != null);

    try deleteLink(db, link_id);

    try std.testing.expect((try getLink(db, link_id)) == null);

    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found == null);
    }
}

test "updateLink: title tokens swapped in links_index_tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLink(db, top_id, "https://z.example", "Hello", "");

    var v_buf: [8]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const id_be = codec.encodeU64(link_id);
    {
        const tok = "hello";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    try updateLink(db, link_id, null, "World", null);

    {
        const tok = "hello";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found == null);
    }
    {
        const tok = "world";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree().search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    const link = (try getLink(db, link_id)).?;
    try std.testing.expect(link.title.eql("World"));
}

test "multiple links cascade correctly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const a_id = try category.createCategory(db, top_id, "A", "a", "");
    const b_id = try category.createCategory(db, a_id, "B", "b", "");

    _ = try createLink(db, a_id, "https://1.example", "1", "");
    _ = try createLink(db, b_id, "https://2.example", "2", "");
    _ = try createLink(db, b_id, "https://3.example", "3", "");

    const top = (try category.getCategory(db, top_id)).?;
    const a = (try category.getCategory(db, a_id)).?;
    const b = (try category.getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u64, 2), b.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 3), a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 3), top.link_count_subtree);
}

test "moveLink: happy path swaps category + updates both chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "A", "a", "");
    const b_id = try ops.createCategory(db, top_id, "B", "b", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    const link_id = try ops.createLink(db, a_id, "https://move.test/x", "Move Me", "");
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());

    try ops.moveLink(db, link_id, b_id);

    const moved = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(b_id, moved.category_id);

    const a_after = (try ops.getCategory(db, a_id)).?;
    const b_after = (try ops.getCategory(db, b_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a_after.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), b_after.link_count_subtree);
    const top_after = (try ops.getCategory(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), top_after.link_count_subtree);
}

test "moveLink: same category is a no-op success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "A", "a", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());

    const link_id = try ops.createLink(db, a_id, "https://noop.test/x", "Noop", "");
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    try ops.moveLink(db, link_id, a_id);

    const link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(a_id, link.category_id);
}

test "moveLink: missing link returns LinkNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());

    const result = ops.moveLink(db, 9999, top_id);
    try std.testing.expectError(OperationError.LinkNotFound, result);
}

test "moveLink: missing target category returns CategoryNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "A", "a", "");
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());

    const link_id = try ops.createLink(db, a_id, "https://x.test/x", "X", "");
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    const result = ops.moveLink(db, link_id, 99999);
    try std.testing.expectError(OperationError.CategoryNotFound, result);
}
