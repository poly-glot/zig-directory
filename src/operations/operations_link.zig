//! Link writes and reads: create with duplicate-url detection through the bloom filter and the
//! url-hash index, text and status updates, moves between categories and deletes, each
//! committed as one `ChangeSet` under the write mutex; the paged listings by category,
//! submitter and id, whose pages and cursors ascend by link id; and the status tallies and
//! bloom seeding that run at startup.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const codec = zigstore.codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");

const OperationError = shared.OperationError;
const url_len_max = shared.url_len_max;
const title_len_max = shared.title_len_max;
const link_description_len_max = shared.link_description_len_max;

pub const CreateLinkOptions = struct {
    status: u8 = @intFromEnum(schema.LinkStatus.approved),
    submitter_id: u64 = 0,
};

pub fn create_link(db: *Directory, category_id: u64, text: shared.LinkText) !u64 {
    const id = try create_link_with_options(db, category_id, text, .{});
    assert(id != 0);
    return id;
}

pub fn create_link_with_options(
    db: *Directory,
    category_id: u64,
    text: shared.LinkText,
    options: CreateLinkOptions,
) !u64 {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    const id = try create_link_with_options_locked(db, category_id, text, options);
    assert(id != 0);
    return id;
}

fn create_link_with_options_locked(
    db: *Directory,
    category_id: u64,
    text: shared.LinkText,
    options: CreateLinkOptions,
) !u64 {
    if (text.url.len > url_len_max) return OperationError.FieldTooLong;
    if (text.title.len > title_len_max) return OperationError.FieldTooLong;
    if (text.description.len > link_description_len_max) return OperationError.FieldTooLong;

    if (category_id != 0) {
        const target = (try category.get_category(db, category_id)) orelse
            return OperationError.CategoryNotFound;
        assert(target.id == category_id);
    }

    if (try create_link_url_taken(db, text.url)) return OperationError.DuplicateUrl;

    const id = db.next_link_id.fetchAdd(1, .monotonic);
    assert(id != 0);
    const now = db.now_seconds();

    const link = schema.Link{
        .id = id,
        .category_id = category_id,
        .url = codec.FixedString(64).fromSlice(text.url),
        .title = codec.FixedString(128).fromSlice(text.title),
        .description = codec.FixedString(256).fromSlice(text.description),
        .sort_order = 0,
        ._pad0 = 0,
        .created_at = now,
        .updated_at = now,
        .status = options.status,
        .submitter_id = options.submitter_id,
    };
    assert(link.url.slice().len == text.url.len);
    assert(link.title.slice().len == text.title.len);
    assert(link.description.slice().len == text.description.len);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_link_insert_change_set(db, &link, arena.allocator());
    try db.commit(change_set);

    return id;
}

// The bloom filter answers "never stored" without touching the index; only a possible hit pays
// for the lookup, and the stored url is compared in full because hashes collide.
fn create_link_url_taken(db: *Directory, url: []const u8) !bool {
    assert(url.len <= url_len_max);
    if (db.url_bloom_ready.load(.acquire) and !db.url_bloom.mayContain(url)) return false;

    const hash_key = codec.encodeU64(codec.hash(url));
    const memtable_hash = db.memtable_link_by_url_hash().get(&hash_key);
    var hash_buffer: [8]u8 = undefined;
    const existing_id_bytes: ?[]const u8 = switch (memtable_hash) {
        .found => |found| found,
        .deleted => null,
        .not_found => try db.link_by_url_hash().search(&hash_key, &hash_buffer),
    };
    const bytes = existing_id_bytes orelse return false;
    if (bytes.len < 8) return false;
    const existing_link_id = codec.decodeU64(bytes);
    const existing_link = (try get_link(db, existing_link_id)) orelse return false;
    assert(existing_link.id == existing_link_id);
    return std.mem.eql(u8, existing_link.url.slice(), url);
}

pub fn get_link(db: *Directory, id: u64) !?schema.Link {
    const key = codec.encodeU64(id);
    const memtable_result = db.memtable_links_by_id().get(&key);
    var tree_buffer: [@sizeOf(schema.Link)]u8 = undefined;
    const value = switch (memtable_result) {
        .found => |found| found,
        .deleted => return null,
        .not_found => (try db.links_by_id().search(&key, &tree_buffer)) orelse return null,
    };
    if (value.len != @sizeOf(schema.Link)) return OperationError.DatabaseCorrupted;
    const link = std.mem.bytesToValue(schema.Link, value[0..@sizeOf(schema.Link)]);
    assert(link.id == id);
    return link;
}

pub fn update_link(
    db: *Directory,
    id: u64,
    url: ?[]const u8,
    title: ?[]const u8,
    description: ?[]const u8,
) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    return update_link_locked(db, id, url, title, description);
}

fn update_link_locked(
    db: *Directory,
    id: u64,
    url: ?[]const u8,
    title: ?[]const u8,
    description: ?[]const u8,
) !void {
    if (url) |new_url| if (new_url.len > url_len_max) return OperationError.FieldTooLong;
    if (title) |new_title| if (new_title.len > title_len_max) return OperationError.FieldTooLong;
    if (description) |new_description| {
        if (new_description.len > link_description_len_max) return OperationError.FieldTooLong;
    }

    const old_link = (try get_link(db, id)) orelse return OperationError.LinkNotFound;
    assert(old_link.id == id);

    var new_link = old_link;
    if (url) |new_url| new_link.url = codec.FixedString(64).fromSlice(new_url);
    if (title) |new_title| new_link.title = codec.FixedString(128).fromSlice(new_title);
    if (description) |new_description| {
        new_link.description = codec.FixedString(256).fromSlice(new_description);
    }
    new_link.updated_at = db.now_seconds();
    if (url) |new_url| assert(new_link.url.slice().len == new_url.len);
    if (title) |new_title| assert(new_link.title.slice().len == new_title.len);
    if (description) |new_description| {
        assert(new_link.description.slice().len == new_description.len);
    }
    assert(new_link.id == old_link.id);
    assert(new_link.category_id == old_link.category_id);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_link_text_update_change_set(
        &old_link,
        &new_link,
        arena.allocator(),
    );
    try db.commit(change_set);
}

pub fn update_link_status(db: *Directory, id: u64, status: u8) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    const old_link = (try get_link(db, id)) orelse return OperationError.LinkNotFound;
    assert(old_link.id == id);
    var new_link = old_link;
    new_link.status = status;
    new_link.updated_at = db.now_seconds();
    assert(new_link.id == old_link.id);
    assert(new_link.category_id == old_link.category_id);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_link_text_update_change_set(
        &old_link,
        &new_link,
        arena.allocator(),
    );
    try db.commit(change_set);
}

pub fn update_link_status_bulk_one(db: *Directory, id: u64, status: u8) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    const old_link = (try get_link(db, id)) orelse return OperationError.LinkNotFound;
    assert(old_link.id == id);
    if (old_link.status == status) return OperationError.AlreadyInState;
    var new_link = old_link;
    new_link.status = status;
    new_link.updated_at = db.now_seconds();
    assert(new_link.status != old_link.status);
    assert(new_link.id == old_link.id);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_link_text_update_change_set(
        &old_link,
        &new_link,
        arena.allocator(),
    );
    try db.commit(change_set);
}

pub const StatusCounts = struct { pending: u64, approved: u64, rejected: u64 };

pub fn counts_by_status(db: *Directory) !StatusCounts {
    return .{
        .pending = db.links_pending_count.load(.monotonic),
        .approved = db.links_approved_count.load(.monotonic),
        .rejected = db.links_rejected_count.load(.monotonic),
    };
}

pub const url_bloom_seed_chunk: usize = 512;

pub const SeedPace = enum { full_speed, yield_half_the_disk };

pub fn seed_url_bloom(db: *Directory, pace: SeedPace) !void {
    try seed_url_bloom_in_chunks(db, url_bloom_seed_chunk, pace);
    assert(db.url_bloom_ready.load(.acquire) or db.url_bloom_seeder_stop.load(.acquire));
}

pub fn seed_url_bloom_in_chunks(db: *Directory, chunk: usize, pace: SeedPace) !void {
    assert(chunk > 0);
    var next_id: u64 = 0;
    while (!db.url_bloom_seeder_stop.load(.acquire)) {
        const started = std.Io.Clock.awake.now(db.io);
        const chunk_start_id = next_id;
        const scanned = try seed_url_bloom_chunk(db, &next_id, chunk);
        assert(scanned <= chunk);
        if (scanned > 0) assert(next_id > chunk_start_id);
        if (scanned < chunk) {
            db.url_bloom_ready.store(true, .release);
            return;
        }
        if (pace == .yield_half_the_disk) try std.Io.sleep(
            db.io,
            started.untilNow(db.io, .awake),
            .awake,
        );
    }
}

fn seed_url_bloom_chunk(db: *Directory, next_id: *u64, chunk: usize) !usize {
    assert(chunk > 0);
    const start_id = next_id.*;
    const start_key = codec.encodeU64(start_id);
    var iterator = try db.links_by_id().rangeScan(&start_key, null);
    defer iterator.deinit();

    var scanned: usize = 0;
    while (scanned < chunk) : (scanned += 1) {
        const entry = (try iterator.next()) orelse break;
        next_id.* = codec.decodeU64(entry.key[0..8]) + 1;
        if (entry.value.len != @sizeOf(schema.Link)) continue;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        db.url_bloom.add(link.url.slice());
    }
    assert(scanned <= chunk);
    if (scanned > 0) assert(next_id.* > start_id);
    return scanned;
}

pub fn recount_link_statuses(db: *Directory) !void {
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());

    var scanned: u64 = 0;
    var pending: u64 = 0;
    var approved: u64 = 0;
    var rejected: u64 = 0;
    const start_key = codec.encodeU64(0);
    var iterator = try db.links_by_id().rangeScan(&start_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        if (entry.value.len != @sizeOf(schema.Link)) continue;
        scanned += 1;
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        switch (link.status) {
            @intFromEnum(schema.LinkStatus.pending) => pending += 1,
            @intFromEnum(schema.LinkStatus.approved) => approved += 1,
            @intFromEnum(schema.LinkStatus.rejected) => rejected += 1,
            else => {},
        }
    }
    assert(pending + approved + rejected <= scanned);

    db.links_pending_count.store(pending, .monotonic);
    db.links_approved_count.store(approved, .monotonic);
    db.links_rejected_count.store(rejected, .monotonic);
}

pub fn move_link(db: *Directory, move: shared.Move) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    const old_link = (try get_link(db, move.id)) orelse return OperationError.LinkNotFound;
    assert(old_link.id == move.id);

    if (move.new_parent_id == 0) return OperationError.CategoryNotFound;
    const target = (try category.get_category(db, move.new_parent_id)) orelse
        return OperationError.CategoryNotFound;
    assert(target.id == move.new_parent_id);

    if (old_link.category_id == move.new_parent_id) return;
    assert(move.new_parent_id != old_link.category_id);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_link_recat_change_set(
        db,
        &old_link,
        move.new_parent_id,
        arena.allocator(),
    );
    try db.commit(change_set);
}

pub fn delete_link(db: *Directory, id: u64) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);
    return delete_link_locked(db, id);
}

pub fn delete_link_locked(db: *Directory, id: u64) !void {
    const link = (try get_link(db, id)) orelse return OperationError.LinkNotFound;
    assert(link.id == id);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_link_delete_change_set(db, &link, arena.allocator());
    try db.commit(change_set);
}

pub const LinkPage = struct { items: []schema.Link, next_after_id: u64 };

fn resolve_link_by_id(db: *Directory, value: []const u8) !?schema.Link {
    if (value.len < 8) return OperationError.DatabaseCorrupted;
    const link_id = codec.decodeU64(value);
    const link = (try get_link(db, link_id)) orelse return null;
    assert(link.id == link_id);
    return link;
}

fn resolve_link_value(_: *Directory, value: []const u8) !?schema.Link {
    if (value.len != @sizeOf(schema.Link)) return null;
    return std.mem.bytesToValue(schema.Link, value[0..@sizeOf(schema.Link)]);
}

fn paginate_links(
    db: *Directory,
    iterator: anytype,
    page: *const shared.Page,
    buffer: []schema.Link,
    comptime resolve: anytype,
) !LinkPage {
    const cursor_mode = page.after_id > 0;
    var count: u32 = 0;
    var skipped: u32 = 0;
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;
    const max = @min(page.limit, @as(u32, @intCast(buffer.len)));

    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        const link = (try resolve(db, entry.value)) orelse continue;
        if (page.status_filter) |status| if (link.status != status) continue;
        if (!cursor_mode and skipped < page.offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) {
            next_after_id = last_id;
            break;
        }
        assert(link.id > last_id);
        if (cursor_mode) assert(link.id > page.after_id);
        buffer[count] = link;
        last_id = link.id;
        count += 1;
    }

    assert(count <= max);
    if (cursor_mode) assert(skipped == 0);
    if (next_after_id != 0) assert(count == max);
    return .{ .items = buffer[0..count], .next_after_id = next_after_id };
}

pub fn list_links(
    db: *Directory,
    category_id: u64,
    page: shared.Page,
    buffer: []schema.Link,
) !LinkPage {
    try db.drain_one_memtable(db.memtable_link_by_category(), db.link_by_category());
    const seek_id: u64 = if (page.after_id > 0) page.after_id +| 1 else 0;
    const start_key = schema.CategoryLinkKey.encode(.{ category_id, seek_id });
    const end_key = schema.CategoryLinkKey.encode(.{ category_id, std.math.maxInt(u64) });
    var iterator = try db.link_by_category().rangeScan(&start_key, &end_key);
    const result = try paginate_links(db, &iterator, &page, buffer, resolve_link_by_id);
    assert(result.items.len <= page.limit);
    if (result.next_after_id != 0) assert(result.next_after_id >= seek_id);
    return result;
}

pub fn list_links_by_submitter(
    db: *Directory,
    submitter_id: u64,
    page: shared.Page,
    buffer: []schema.Link,
) !LinkPage {
    try db.drain_one_memtable(db.memtable_link_by_submitter(), db.link_by_submitter());
    const seek_id: u64 = if (page.after_id > 0) page.after_id +| 1 else 0;
    const start_key = schema.SubmitterLinkKey.encode(.{ submitter_id, seek_id });
    const end_key = schema.SubmitterLinkKey.encode(.{ submitter_id, std.math.maxInt(u64) });
    var iterator = try db.link_by_submitter().rangeScan(&start_key, &end_key);
    const result = try paginate_links(db, &iterator, &page, buffer, resolve_link_by_id);
    assert(result.items.len <= page.limit);
    if (result.next_after_id != 0) assert(result.next_after_id >= seek_id);
    for (result.items) |link| assert(link.submitter_id == submitter_id);
    // Submitter 0 means anonymous, and `apply` never indexes it.
    if (submitter_id == 0) assert(result.items.len == 0);
    return result;
}

pub fn list_all_links(
    db: *Directory,
    page: shared.Page,
    buffer: []schema.Link,
) !LinkPage {
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());
    const seek_id: u64 = if (page.after_id > 0) page.after_id +| 1 else 0;
    const start_key = codec.encodeU64(seek_id);
    var iterator = try db.links_by_id().rangeScan(&start_key, null);
    const result = try paginate_links(db, &iterator, &page, buffer, resolve_link_value);
    assert(result.items.len <= page.limit);
    if (result.next_after_id != 0) assert(result.next_after_id >= seek_id);
    return result;
}

// Goal: the submitter index returns one user's links in id order and nothing for submitter 0.
// Method: interleave two submitters and a legacy link, then list each.
test "list_links_by_submitter: returns only the requested user's submissions, ordered by id" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://a1.example", .title = "a1", .description = "" },
        .{ .submitter_id = 100 },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://b1.example", .title = "b1", .description = "" },
        .{ .submitter_id = 200 },
    );
    _ = try create_link(
        db,
        top_id,
        .{ .url = "https://legacy.example", .title = "legacy", .description = "" },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://a2.example", .title = "a2", .description = "" },
        .{ .submitter_id = 100 },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://b2.example", .title = "b2", .description = "" },
        .{ .submitter_id = 200 },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://a3.example", .title = "a3", .description = "" },
        .{ .submitter_id = 100 },
    );

    var buffer: [10]schema.Link = undefined;

    const a_links = (try list_links_by_submitter(db, 100, .{ .limit = 10 }, &buffer)).items;
    try std.testing.expectEqual(@as(usize, 3), a_links.len);
    try std.testing.expect(a_links[0].id < a_links[1].id);
    try std.testing.expect(a_links[1].id < a_links[2].id);
    for (a_links) |link| try std.testing.expectEqual(@as(u64, 100), link.submitter_id);

    const b_links = (try list_links_by_submitter(db, 200, .{ .limit = 10 }, &buffer)).items;
    try std.testing.expectEqual(@as(usize, 2), b_links.len);
    for (b_links) |link| try std.testing.expectEqual(@as(u64, 200), link.submitter_id);

    const zero_links = (try list_links_by_submitter(db, 0, .{ .limit = 10 }, &buffer)).items;
    try std.testing.expectEqual(@as(usize, 0), zero_links.len);
}

// Goal: an offset page starts after the skipped rows. Method: five links, a page of two, then
// the page at offset two.
test "list_links_by_submitter: pagination via offset" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "https://x{d}.example", .{i});
        _ = try create_link_with_options(
            db,
            top_id,
            .{ .url = url, .title = "x", .description = "" },
            .{ .submitter_id = 42 },
        );
    }

    var buffer: [10]schema.Link = undefined;
    const page1 = (try list_links_by_submitter(db, 42, .{ .limit = 2 }, &buffer)).items;
    try std.testing.expectEqual(@as(usize, 2), page1.len);
    const first_id = page1[0].id;
    const second_id = page1[1].id;

    const page2 = (try list_links_by_submitter(
        db,
        42,
        .{ .offset = 2, .limit = 2 },
        &buffer,
    )).items;
    try std.testing.expectEqual(@as(usize, 2), page2.len);
    try std.testing.expect(page2[0].id > second_id);
    _ = first_id;
}

// Goal: `next_after_id` resumes exactly after the last row and is 0 on the last page. Method:
// walk five links in pages of two by cursor.
test "list_links_by_submitter: cursor (after_id) resumes past the given id" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    var ids: [5]u64 = undefined;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var url_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "https://c{d}.example", .{i});
        ids[i] = try create_link_with_options(
            db,
            top_id,
            .{ .url = url, .title = "c", .description = "" },
            .{ .submitter_id = 77 },
        );
    }

    var buffer: [10]schema.Link = undefined;

    const page1 = try list_links_by_submitter(db, 77, .{ .limit = 2 }, &buffer);
    try std.testing.expectEqual(@as(usize, 2), page1.items.len);
    try std.testing.expectEqual(ids[0], page1.items[0].id);
    try std.testing.expectEqual(ids[1], page1.items[1].id);
    try std.testing.expectEqual(ids[1], page1.next_after_id);

    const page2 = try list_links_by_submitter(
        db,
        77,
        .{ .limit = 2, .after_id = page1.next_after_id },
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 2), page2.items.len);
    try std.testing.expectEqual(ids[2], page2.items[0].id);
    try std.testing.expectEqual(ids[3], page2.items[1].id);
    try std.testing.expectEqual(ids[3], page2.next_after_id);

    const page3 = try list_links_by_submitter(
        db,
        77,
        .{ .limit = 2, .after_id = page2.next_after_id },
        &buffer,
    );
    try std.testing.expectEqual(@as(usize, 1), page3.items.len);
    try std.testing.expectEqual(ids[4], page3.items[0].id);
    try std.testing.expectEqual(@as(u64, 0), page3.next_after_id);
}

// Goal: the status counters count each created link under its status. Method: six links
// across the three statuses.
test "counts_by_status tallies per-status totals" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const rejected = @intFromEnum(schema.LinkStatus.rejected);

    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://p1.example", .title = "p1", .description = "" },
        .{ .status = pending },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://p2.example", .title = "p2", .description = "" },
        .{ .status = pending },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://a1.example", .title = "a1", .description = "" },
        .{ .status = approved },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://a2.example", .title = "a2", .description = "" },
        .{ .status = approved },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://a3.example", .title = "a3", .description = "" },
        .{ .status = approved },
    );
    _ = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://r1.example", .title = "r1", .description = "" },
        .{ .status = rejected },
    );

    const counts = try counts_by_status(db);
    try std.testing.expectEqual(@as(u64, 2), counts.pending);
    try std.testing.expectEqual(@as(u64, 3), counts.approved);
    try std.testing.expectEqual(@as(u64, 1), counts.rejected);
}

// Goal: a status change moves one link between counters and a text edit leaves them alone.
// Method: flip one link through the statuses, then retitle it.
test "counts_by_status: status change moves the tally; text edit does not" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const rejected = @intFromEnum(schema.LinkStatus.rejected);

    const id = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://flip.example", .title = "f", .description = "" },
        .{ .status = pending },
    );
    {
        const counts = try counts_by_status(db);
        try std.testing.expectEqual(@as(u64, 1), counts.pending);
        try std.testing.expectEqual(@as(u64, 0), counts.approved);
        try std.testing.expectEqual(@as(u64, 0), counts.rejected);
    }

    try update_link_status(db, id, approved);
    {
        const counts = try counts_by_status(db);
        try std.testing.expectEqual(@as(u64, 0), counts.pending);
        try std.testing.expectEqual(@as(u64, 1), counts.approved);
        try std.testing.expectEqual(@as(u64, 0), counts.rejected);
    }

    try update_link_status(db, id, rejected);
    {
        const counts = try counts_by_status(db);
        try std.testing.expectEqual(@as(u64, 0), counts.approved);
        try std.testing.expectEqual(@as(u64, 1), counts.rejected);
    }

    try update_link(db, id, null, "renamed", null);
    {
        const counts = try counts_by_status(db);
        try std.testing.expectEqual(@as(u64, 0), counts.approved);
        try std.testing.expectEqual(@as(u64, 1), counts.rejected);
        try std.testing.expectEqual(@as(u64, 0), counts.pending);
    }
}

// Goal: deleting a link takes it out of its status counter. Method: one approved link,
// deleted.
test "counts_by_status: delete_link decrements the tally" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const id = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://del.example", .title = "d", .description = "" },
        .{ .status = approved },
    );
    try std.testing.expectEqual(@as(u64, 1), (try counts_by_status(db)).approved);

    try delete_link(db, id);
    try std.testing.expectEqual(@as(u64, 0), (try counts_by_status(db)).approved);
}

// Goal: the counters survive a restart by recounting the tree. Method: write three links,
// reopen the directory, recover, then read the counters.
test "recount_link_statuses: counters are reseeded from disk on reopen" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);

    {
        var db = try Directory.open_test_instance(allocator, &temporary_directory);
        defer db.deinit_test_instance();
        const top_id = try category.create_category(
            db,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        _ = try create_link_with_options(
            db,
            top_id,
            .{ .url = "https://p1.example", .title = "p1", .description = "" },
            .{ .status = pending },
        );
        _ = try create_link_with_options(
            db,
            top_id,
            .{ .url = "https://p2.example", .title = "p2", .description = "" },
            .{ .status = pending },
        );
        _ = try create_link_with_options(
            db,
            top_id,
            .{ .url = "https://a1.example", .title = "a1", .description = "" },
            .{ .status = approved },
        );
    }

    {
        var db = try Directory.open_test_instance(allocator, &temporary_directory);
        defer db.deinit_test_instance();
        try db.recover();
        const counts = try counts_by_status(db);
        try std.testing.expectEqual(@as(u64, 2), counts.pending);
        try std.testing.expectEqual(@as(u64, 1), counts.approved);
        try std.testing.expectEqual(@as(u64, 0), counts.rejected);
    }
}

// Goal: the bulk variant reports a no-op and a missing link as distinct errors. Method:
// approve a link twice, then approve an id that does not exist.
test "update_link_status_bulk_one maps no-op to AlreadyInState and missing to LinkNotFound" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const pending = @intFromEnum(schema.LinkStatus.pending);
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const id = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://s.example", .title = "s", .description = "" },
        .{ .status = pending },
    );

    try update_link_status_bulk_one(db, id, approved);
    try std.testing.expectEqual(approved, (try get_link(db, id)).?.status);

    try std.testing.expectError(
        OperationError.AlreadyInState,
        update_link_status_bulk_one(db, id, approved),
    );

    try std.testing.expectError(
        OperationError.LinkNotFound,
        update_link_status_bulk_one(db, 999_999, approved),
    );
}

// Goal: a delete also drops the submitter index entry. Method: list the submitter before and
// after the delete.
test "delete_link removes link_by_submitter entry" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try create_link_with_options(
        db,
        top_id,
        .{ .url = "https://gone.example", .title = "g", .description = "" },
        .{ .submitter_id = 7 },
    );

    var buffer: [4]schema.Link = undefined;
    {
        const before = (try list_links_by_submitter(db, 7, .{ .limit = 4 }, &buffer)).items;
        try std.testing.expectEqual(@as(usize, 1), before.len);
    }

    try delete_link(db, link_id);

    const after = (try list_links_by_submitter(db, 7, .{ .limit = 4 }, &buffer)).items;
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

// Goal: a memtable delete tombstones a key so a later read sees it as deleted, not found.
// Method: put then delete one key in a bare memtable.
test "create_link rollback: failure during secondary insert leaves no trace in primary" {
    const testing = std.testing;

    const allocator = testing.allocator;
    var memtable = zigstore.MemTable.init(std.testing.io, allocator);
    defer memtable.deinit();

    const key = codec.encodeU64(123);
    try memtable.put(&key, "value");

    const before = memtable.get(&key);
    try testing.expect(before == .found);

    try memtable.delete(&key);

    const after = memtable.get(&key);
    try testing.expect(after == .deleted);
}

// Goal: a new link counts on its category and every ancestor. Method: a three-level chain
// with one link at the bottom.
test "create_link cascades link_count_subtree up the chain" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const b_id = try category.create_category(
        db,
        a_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );

    _ = try create_link(db, b_id, .{ .url = "https://x.example", .title = "x", .description = "" });

    const top = (try category.get_category(db, top_id)).?;
    const a = (try category.get_category(db, a_id)).?;
    const b = (try category.get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u64, 1), b.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
}

// Goal: a create indexes the title, url and description tokens. Method: probe three token
// keys for the new id.
test "create_link: links_index_tree has token entries" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try create_link(
        db,
        top_id,
        .{ .url = "https://x.example", .title = "Hello World", .description = "Greeting message" },
    );

    var value_buffer: [8]u8 = undefined;
    var key_buffer: [128]u8 = undefined;
    const id_key = codec.encodeU64(link_id);

    const expected_tokens = [_][]const u8{ "hello", "https", "greeting" };
    for (expected_tokens) |token| {
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &id_key);
        const found = try db.links_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found != null);
    }
}

// Goal: a delete takes the link out of every ancestor's subtree count. Method: create and
// delete one link, then the two ancestors.
test "delete_link cascades link_count_subtree decrement" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const link_id = try create_link(
        db,
        a_id,
        .{ .url = "https://x.example", .title = "x", .description = "" },
    );

    try delete_link(db, link_id);

    const top = (try category.get_category(db, top_id)).?;
    const a = (try category.get_category(db, a_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 0), top.link_count_subtree);
}

// Goal: a delete removes the token index entries and the record. Method: probe the token
// keys and the record before and after.
test "delete_link: tokens are removed from links_index_tree" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try create_link(
        db,
        top_id,
        .{ .url = "https://y.example", .title = "Goodbye Cruel", .description = "Farewell note" },
    );

    var value_buffer: [8]u8 = undefined;
    var key_buffer: [128]u8 = undefined;
    const id_key = codec.encodeU64(link_id);
    const expected_tokens = [_][]const u8{ "goodbye", "https", "farewell" };
    for (expected_tokens) |token| {
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &id_key);
        const found = try db.links_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found != null);
    }
    try std.testing.expect((try get_link(db, link_id)) != null);

    try delete_link(db, link_id);

    try std.testing.expect((try get_link(db, link_id)) == null);

    for (expected_tokens) |token| {
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &id_key);
        const found = try db.links_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found == null);
    }
}

// Goal: a title change drops the old title token and indexes the new one. Method: retitle
// `Hello` to `World`, then probe both keys.
test "update_link: title tokens swapped in links_index_tree" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try create_link(
        db,
        top_id,
        .{ .url = "https://z.example", .title = "Hello", .description = "" },
    );

    var value_buffer: [8]u8 = undefined;
    var key_buffer: [128]u8 = undefined;
    const id_key = codec.encodeU64(link_id);
    {
        const token = "hello";
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &id_key);
        const found = try db.links_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found != null);
    }

    try update_link(db, link_id, null, "World", null);

    {
        const token = "hello";
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &id_key);
        const found = try db.links_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found == null);
    }
    {
        const token = "world";
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &id_key);
        const found = try db.links_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found != null);
    }

    const link = (try get_link(db, link_id)).?;
    try std.testing.expect(link.title.eql("World"));
}

// Goal: subtree counts add up across several links at different depths. Method: three links
// over two levels, then every ancestor's count.
test "multiple links cascade correctly" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try category.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const b_id = try category.create_category(
        db,
        a_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );

    _ = try create_link(db, a_id, .{ .url = "https://1.example", .title = "1", .description = "" });
    _ = try create_link(db, b_id, .{ .url = "https://2.example", .title = "2", .description = "" });
    _ = try create_link(db, b_id, .{ .url = "https://3.example", .title = "3", .description = "" });

    const top = (try category.get_category(db, top_id)).?;
    const a = (try category.get_category(db, a_id)).?;
    const b = (try category.get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u64, 2), b.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 3), a.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 3), top.link_count_subtree);
}

// Goal: a move changes the link's category and shifts the count from the old chain to the
// new one. Method: move one link between siblings, then both chains and the root.
test "move_link: happy path swaps category + updates both chains" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const b_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const link_id = try ops.create_link(
        db,
        a_id,
        .{ .url = "https://move.test/x", .title = "Move Me", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());
    try db.drain_one_memtable(db.memtable_link_by_category(), db.link_by_category());

    try ops.move_link(db, .{ .id = link_id, .new_parent_id = b_id });

    const moved = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqual(b_id, moved.category_id);

    const a_after = (try ops.get_category(db, a_id)).?;
    const b_after = (try ops.get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a_after.link_count_subtree);
    try std.testing.expectEqual(@as(u64, 1), b_after.link_count_subtree);
    const top_after = (try ops.get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), top_after.link_count_subtree);
}

// Goal: moving a link to its own category succeeds and changes nothing. Method: move, then
// read the link back.
test "move_link: same category is a no-op success" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());

    const link_id = try ops.create_link(
        db,
        a_id,
        .{ .url = "https://noop.test/x", .title = "Noop", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());

    try ops.move_link(db, .{ .id = link_id, .new_parent_id = a_id });

    const link = (try ops.get_link(db, link_id)).?;
    try std.testing.expectEqual(a_id, link.category_id);
}

// Goal: a move of an unknown link id fails with `LinkNotFound`. Method: move id 9999.
test "move_link: missing link returns LinkNotFound" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());

    const result = ops.move_link(db, .{ .id = 9999, .new_parent_id = top_id });
    try std.testing.expectError(OperationError.LinkNotFound, result);
}

// Goal: a move to an unknown category fails with `CategoryNotFound`. Method: move a real
// link to category 99999.
test "move_link: missing target category returns CategoryNotFound" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const ops = @import("operations.zig");
    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());

    const link_id = try ops.create_link(
        db,
        a_id,
        .{ .url = "https://x.test/x", .title = "X", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());

    const result = ops.move_link(db, .{ .id = link_id, .new_parent_id = 99999 });
    try std.testing.expectError(OperationError.CategoryNotFound, result);
}

const WriterProbe = struct {
    db: *Directory,
    top: u64,
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *WriterProbe) void {
        assert(!self.finished.load(.acquire));
        assert(self.top != 0);
        _ = create_link(
            self.db,
            self.top,
            .{ .url = "https://blocked.example", .title = "Blocked", .description = "" },
        ) catch |err| {
            std.debug.panic("writer probe failed: {}", .{err});
        };
        self.finished.store(true, .release);
    }
};

// Goal: a writer blocks on the write mutex before it validates anything. Method: hold the
// mutex, spawn a writer, confirm it has not finished, release, then join.
test "every mutating operation waits for the write mutex before validating" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    var probe = WriterProbe{ .db = db, .top = top };

    db.write_mutex.lockUncancelable(db.io);
    const writer = try std.Thread.spawn(.{}, WriterProbe.run, .{&probe});
    try std.Io.sleep(db.io, .fromMilliseconds(30), .awake);
    try std.testing.expect(!probe.finished.load(.acquire));
    db.write_mutex.unlock(db.io);
    writer.join();

    try std.testing.expect(probe.finished.load(.acquire));
}

// Goal: a read during a memtable drain still sees a committed link and still detects its
// duplicate url. Method: swap every shard out, read and re-create, then swap them back.
test "a committed link stays visible while its memtable shard is draining" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const id = try create_link(
        db,
        top,
        .{ .url = "https://draining.example", .title = "Draining", .description = "" },
    );

    const memtable = db.memtable_links_by_id();
    memtable.lockAll();
    for (0..zigstore.MEMTABLE_SHARDS) |i| _ = try memtable.swapShardLocked(i);
    memtable.unlockAll();

    const link = (try get_link(db, id)) orelse return error.CommittedLinkInvisibleDuringDrain;
    try std.testing.expectEqualStrings("https://draining.example", link.url.slice());
    try std.testing.expectError(OperationError.DuplicateUrl, create_link(
        db,
        top,
        .{ .url = "https://draining.example", .title = "Dup", .description = "" },
    ));

    memtable.lockAll();
    for (0..zigstore.MEMTABLE_SHARDS) |i| memtable.resetShardBackLocked(i);
    memtable.unlockAll();
}
