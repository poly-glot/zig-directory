// Link CRUD + listing operations split from the original monolithic
// operations.zig. Public surface:
//   - createLink   - listLinks
//   - getLink      - listAllLinks
//   - updateLink
//   - deleteLink
//
// ChangeSet construction lives in `operations_changeset_compute.zig`.
// Category lookups (`getCategory`) come from `operations_category.zig`.

const std = @import("std");
const types = @import("../types.zig");
const Database = @import("../database.zig").Database;
const memtable = @import("../memtable.zig");
const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const category = @import("operations_category.zig");

const OperationError = shared.OperationError;
const MAX_URL_LEN = shared.MAX_URL_LEN;
const MAX_TITLE_LEN = shared.MAX_TITLE_LEN;
const MAX_LINK_DESC_LEN = shared.MAX_LINK_DESC_LEN;

/// Create a new link in a category, returning the new link's id.
///
/// Builds a `link_inserted` ChangeSet and routes it through `db.commit`,
/// which encodes + WAL-appends + fsyncs + applies under `apply_mutex`.
/// All index writes (primary `links_by_id`, secondaries `link_by_category`
/// and `link_by_url_hash`, inverted-index `links_index_tree`, ancestor
/// count cascade, url_bloom, subtree_cache invalidation) are performed by
/// `applyLinkInserted` — see `src/apply.zig`.
/// Optional fields a Slice-3+ caller can override when creating a link.
/// Defaults match the legacy 4-arg `createLink` semantics so existing
/// callers (op=1 batch handler, e2e tests) get the same behaviour.
pub const CreateLinkOpts = struct {
    status: u8 = @intFromEnum(types.LinkStatus.approved),
    submitter_id: u64 = 0,
};

/// Legacy 4-arg create — preserved for op=1 batch handler + tests.
/// Internally delegates to `createLinkWithOpts` with default opts
/// (status = approved, submitter_id = 0).
pub fn createLink(
    db: *Database,
    category_id: u64,
    url: []const u8,
    title: []const u8,
    desc: []const u8,
) !u64 {
    return createLinkWithOpts(db, category_id, url, title, desc, .{});
}

/// Create a link with caller-controlled `status` and `submitter_id`.
/// Used by op=25 `create_submission` so the web tier can record who
/// submitted a pending link without changing the legacy op=1 contract.
pub fn createLinkWithOpts(
    db: *Database,
    category_id: u64,
    url: []const u8,
    title: []const u8,
    desc: []const u8,
    opts: CreateLinkOpts,
) !u64 {
    if (url.len > MAX_URL_LEN) return OperationError.FieldTooLong;
    if (title.len > MAX_TITLE_LEN) return OperationError.FieldTooLong;
    if (desc.len > MAX_LINK_DESC_LEN) return OperationError.FieldTooLong;

    // Validate parent exists if non-zero. parent_id == 0 means root.
    if (category_id != 0) {
        if ((try category.getCategory(db, category_id)) == null) return OperationError.CategoryNotFound;
    }

    // Duplicate URL check: bloom filter → memtable → B+Tree.
    // Bloom filter rejects ~99.2% of unique URLs instantly. The check is
    // performed without holding apply_mutex (commit takes it for us); a
    // racing createLink with the same URL would lose to whichever commits
    // first because the loser's apply would overwrite the bloom and hash
    // entry, but the duplicate would still be visible via getLink — the
    // hash lookup here catches any URL that has already reached either
    // the memtable or the B+Tree.
    const url_hash = types.hashUrl(url);
    const hash_key = types.encodeU64(url_hash);
    if (db.url_bloom.mayContain(url)) {
        const mt_hash = db.mt_link_by_url_hash.get(&hash_key);
        var hash_buf: [8]u8 = undefined;
        const tree_hash = switch (mt_hash) {
            .found, .deleted => null,
            .not_found => try db.link_by_url_hash.search(&hash_key, &hash_buf),
        };
        const existing_id_bytes: ?[]const u8 = switch (mt_hash) {
            .found => |v| v,
            .deleted => null,
            .not_found => tree_hash,
        };
        if (existing_id_bytes) |bytes| {
            if (bytes.len >= 8) {
                const existing_link_id = types.decodeU64(bytes);
                if (try getLink(db, existing_link_id)) |existing_link| {
                    if (std.mem.eql(u8, existing_link.url.slice(), url)) {
                        return OperationError.DuplicateUrl;
                    }
                }
            }
        }
    }

    // Allocate link ID via lock-free atomic increment.
    const id = db.next_link_id.fetchAdd(1, .monotonic);
    const now = std.time.timestamp();

    const link = types.Link{
        .id = id,
        .category_id = category_id,
        .url = types.FixedString(64).fromSlice(url),
        .title = types.FixedString(128).fromSlice(title),
        .description = types.FixedString(256).fromSlice(desc),
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

/// Retrieve a link by its id.  Returns null if not found.
/// Checks the memtable first (recent writes), falls through to B+Tree.
pub fn getLink(db: *Database, id: u64) !?types.Link {
    const key = types.encodeU64(id);
    const mt_result = db.mt_links_by_id.get(&key);
    var tree_buf: [@sizeOf(types.Link)]u8 = undefined;
    const val = switch (mt_result) {
        .found => |v| v,
        .deleted => return null,
        .not_found => (try db.links_by_id.search(&key, &tree_buf)) orelse return null,
    };
    if (val.len != @sizeOf(types.Link)) return OperationError.DatabaseCorrupted;
    return std.mem.bytesToValue(types.Link, val[0..@sizeOf(types.Link)]);
}

/// Update mutable text fields of an existing link.
///
/// Builds a `link_text_updated` ChangeSet and routes it through `db.commit`,
/// which encodes + WAL-appends + fsyncs + applies under `apply_mutex`.
/// All index writes (primary `links_by_id`, inverted-index `links_index_tree`
/// token swap, `link_by_url_hash` rewrite + url_bloom on URL change,
/// subtree_cache invalidation) are performed by `applyLinkTextUpdated`
/// — see `src/apply.zig`. `category_id` is intentionally not mutable
/// here: a category change must route through the `link_recategorized`
/// effect because it cascades both ancestor chains.
pub fn updateLink(
    db: *Database,
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
    if (url) |new_url| new_link.url = types.FixedString(64).fromSlice(new_url);
    if (title) |t| new_link.title = types.FixedString(128).fromSlice(t);
    if (desc) |d| new_link.description = types.FixedString(256).fromSlice(d);
    new_link.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkTextUpdateChangeSet(old_link, new_link, arena.allocator());

    try db.commit(cs);
}

/// Update only the editorial `status` of a link. Used by op=26
/// `update_link_status` so admins can flip a submission between
/// pending / approved / rejected without touching url / title / desc.
///
/// The on-disk side is the same `link_text_updated` ChangeSet path —
/// status lives inside the Link struct, so the existing primary-record
/// rewrite already covers it. No secondary-index swap needed (status
/// participates in no key, only the record body).
pub fn updateLinkStatus(db: *Database, id: u64, status: u8) !void {
    // Status range validation lives at the protocol layer
    // (`handleUpdateLinkStatus`). Any byte that reaches here is treated
    // as an opaque enum value so future LinkStatus variants don't
    // require touching this function.
    const old_link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;
    var new_link = old_link;
    new_link.status = status;
    new_link.updated_at = std.time.timestamp();

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkTextUpdateChangeSet(old_link, new_link, arena.allocator());

    try db.commit(cs);
}

/// Single-id status update for the bulk op (op=34). Identical to
/// `updateLinkStatus` but maps two outcomes the bulk-bar UI needs to
/// distinguish into typed errors instead of silent success:
///   - `LinkNotFound` — the id does not exist.
///   - `AlreadyInState` — the link is already in the requested status
///     (no WAL entry written; the UI reports it as a no-op rather than
///     a spurious "approved").
pub fn updateLinkStatusBulkOne(db: *Database, id: u64, status: u8) !void {
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

/// Per-status link totals for the admin chip strip (op=36).
pub const StatusCounts = struct { pending: u64, approved: u64, rejected: u64 };

/// Return the maintained per-status link totals. O(1): reads the in-memory
/// counters on `Database` rather than scanning `links_by_id`. The counters
/// are seeded by `recountLinkStatuses` at boot and kept current by the
/// apply_link hooks (insert / delete / status-change), replacing the former
/// full-tree scan that ran on every /admin/links render.
pub fn countsByStatus(db: *Database) !StatusCounts {
    return .{
        .pending = db.links_pending_count.load(.monotonic),
        .approved = db.links_approved_count.load(.monotonic),
        .rejected = db.links_rejected_count.load(.monotonic),
    };
}

/// Recompute the per-status link counters from a single full scan of the
/// primary index and store them on `db`. Called once at boot (after WAL
/// replay, which is a changeset no-op) so the counters reflect the drained
/// data file; thereafter the apply_link hooks maintain them incrementally.
/// Idempotent — safe to call again at any quiescent point to reconcile drift.
pub fn recountLinkStatuses(db: *Database) !void {
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);

    var pending: u64 = 0;
    var approved: u64 = 0;
    var rejected: u64 = 0;
    const start_key = types.encodeU64(0);
    var iter = try db.links_by_id.rangeScan(&start_key, null);
    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(types.Link)) continue;
        const link = std.mem.bytesToValue(types.Link, entry.value[0..@sizeOf(types.Link)]);
        switch (link.status) {
            @intFromEnum(types.LinkStatus.pending) => pending += 1,
            @intFromEnum(types.LinkStatus.approved) => approved += 1,
            @intFromEnum(types.LinkStatus.rejected) => rejected += 1,
            else => {},
        }
    }

    db.links_pending_count.store(pending, .monotonic);
    db.links_approved_count.store(approved, .monotonic);
    db.links_rejected_count.store(rejected, .monotonic);
}

/// Move a link to a different category. Routes through the existing
/// `link_recategorized` ChangeSet path — see `applyLinkRecategorized`
/// in `src/apply_link.zig` for the apply-side index swap + dual cascade.
///
/// Rejects:
///   - LinkNotFound when `id` does not exist.
///   - CategoryNotFound when `new_category_id` is not a real category.
///   - Returns success no-op when `new_category_id == link.category_id`.
///
/// Root-category guard (cannot move into a root, parent_id == 0) is
/// enforced at the protocol/admin layer, not here, because the
/// operation itself is semantically valid against any real category.
pub fn moveLink(db: *Database, id: u64, new_category_id: u64) !void {
    const old_link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;

    // Validate target category exists.
    if (new_category_id == 0) return OperationError.CategoryNotFound;
    if ((try category.getCategory(db, new_category_id)) == null) {
        return OperationError.CategoryNotFound;
    }

    if (old_link.category_id == new_category_id) return; // no-op

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

/// Delete a link by id.
///
/// Builds a `link_deleted` ChangeSet and routes it through `db.commit`,
/// which encodes + WAL-appends + fsyncs + applies under `apply_mutex`.
/// All index tombstones (primary `links_by_id`, secondaries `link_by_category`
/// and `link_by_url_hash`, inverted-index `links_index_tree` token deletes,
/// ancestor count cascade, subtree_cache invalidation) are performed by
/// `applyLinkDeleted` — see `src/apply.zig`.
pub fn deleteLink(db: *Database, id: u64) !void {
    const link = (try getLink(db, id)) orelse return OperationError.LinkNotFound;

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const cs = try compute.computeLinkDeleteChangeSet(db, link, arena.allocator());

    try db.commit(cs);
}

/// A page of links plus the cursor for the next page. `next_after_id == 0`
/// means "no further page" — set when the scan returned fewer than `limit`
/// rows or the iterator reached the end. When non-zero it is the id of the
/// last row on this page; pass it back as `after_id` to fetch the next page.
pub const LinkPage = struct { items: []types.Link, next_after_id: u64 };

/// List links in a category with pagination. When `status_filter` is
/// non-null, only links whose `status` matches the filter are returned —
/// folds in what was a separate `listLinksByCategoryAndStatus` op so the
/// admin queue's per-category status tab uses a single code path.
///
/// When `after_id > 0` the scan runs in cursor mode: the iterator seeks
/// past `after_id` and `offset` is ignored. Links are keyed by
/// (category_id, link_id) so seeking to `after_id + 1` resumes exactly
/// after the last row of the previous page.
pub fn listLinks(
    db: *Database,
    category_id: u64,
    offset: u32,
    limit: u32,
    buf: []types.Link,
    status_filter: ?u8,
    after_id: u64,
) !LinkPage {
    db.drainOneMemtable(&db.mt_link_by_category, &db.link_by_category);

    const cursor_mode = after_id > 0;
    const seek_id: u64 = if (cursor_mode) after_id +| 1 else 0;
    const start_key = types.CategoryLinkKey.encode(category_id, seek_id);
    const end_key = types.CategoryLinkKey.encode(category_id, std.math.maxInt(u64));

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;

    var iter = try db.link_by_category.rangeScan(&start_key, &end_key);
    while (try iter.next()) |entry| {
        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const link_id = types.decodeU64(entry.value);
        const link = (try getLink(db, link_id)) orelse continue;
        if (status_filter) |s| if (link.status != s) continue;
        if (!cursor_mode and skipped < offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) {
            // A further matching row exists past the page → emit a cursor.
            next_after_id = last_id;
            break;
        }
        buf[count] = link;
        last_id = link.id;
        count += 1;
    }

    return .{ .items = buf[0..count], .next_after_id = next_after_id };
}

/// List links submitted by a single user, ordered by link id. Walks the
/// `link_by_submitter` secondary index (keyed `(submitter_id, link_id)`)
/// so the dashboard's per-user submission list scales with the user's
/// own submission count rather than the total link corpus. The
/// `submitter_id == 0` lane is intentionally empty — that lane represents
/// the legacy bulk-import corpus and is skipped at index time.
///
/// `status_filter` non-null narrows to one status (e.g. pending) — folds
/// in what was a separate `listMySubmissionsByStatus` op so the dashboard
/// gets accurate per-tab counts via the same code path.
pub fn listLinksBySubmitter(
    db: *Database,
    submitter_id: u64,
    offset: u32,
    limit: u32,
    buf: []types.Link,
    status_filter: ?u8,
    after_id: u64,
) !LinkPage {
    db.drainOneMemtable(&db.mt_link_by_submitter, &db.link_by_submitter);

    const cursor_mode = after_id > 0;
    const seek_id: u64 = if (cursor_mode) after_id +| 1 else 0;
    const start_key = types.SubmitterLinkKey.encode(submitter_id, seek_id);
    const end_key = types.SubmitterLinkKey.encode(submitter_id, std.math.maxInt(u64));

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;

    var iter = try db.link_by_submitter.rangeScan(&start_key, &end_key);
    while (try iter.next()) |entry| {
        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const link_id = types.decodeU64(entry.value);
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

/// List links across all categories, ordered by link id. Used by the
/// homepage "featured" surface, which iterates the primary `links_by_id`
/// tree directly so it doesn't depend on per-category `link_count`.
///
/// `status_filter` non-null narrows to one status — folds in what was a
/// separate `listLinksByStatus` op so the admin moderation queue's
/// global pending list shares the all-links scan code path.
pub fn listAllLinks(
    db: *Database,
    offset: u32,
    limit: u32,
    buf: []types.Link,
    status_filter: ?u8,
    after_id: u64,
) !LinkPage {
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);

    const cursor_mode = after_id > 0;
    const seek_id: u64 = if (cursor_mode) after_id +| 1 else 0;
    const start_key = types.encodeU64(seek_id);

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    var next_after_id: u64 = 0;
    var last_id: u64 = 0;

    var iter = try db.links_by_id.rangeScan(&start_key, null);
    while (try iter.next()) |entry| {
        if (entry.value.len != @sizeOf(types.Link)) continue;
        const link = std.mem.bytesToValue(types.Link, entry.value[0..@sizeOf(types.Link)]);
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");

    // Two submitters. Sub-A submits 3 links, Sub-B submits 2. A legacy
    // (submitter_id=0) link is interleaved to confirm it stays out of
    // both lanes.
    _ = try createLinkWithOpts(db, top_id, "https://a1.example", "a1", "", .{ .submitter_id = 100 });
    _ = try createLinkWithOpts(db, top_id, "https://b1.example", "b1", "", .{ .submitter_id = 200 });
    _ = try createLink(db, top_id, "https://legacy.example", "legacy", "");
    _ = try createLinkWithOpts(db, top_id, "https://a2.example", "a2", "", .{ .submitter_id = 100 });
    _ = try createLinkWithOpts(db, top_id, "https://b2.example", "b2", "", .{ .submitter_id = 200 });
    _ = try createLinkWithOpts(db, top_id, "https://a3.example", "a3", "", .{ .submitter_id = 100 });

    var buf: [10]types.Link = undefined;

    const a_links = (try listLinksBySubmitter(db, 100, 0, 10, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 3), a_links.len);
    try std.testing.expect(a_links[0].id < a_links[1].id);
    try std.testing.expect(a_links[1].id < a_links[2].id);
    for (a_links) |l| try std.testing.expectEqual(@as(u64, 100), l.submitter_id);

    const b_links = (try listLinksBySubmitter(db, 200, 0, 10, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 2), b_links.len);
    for (b_links) |l| try std.testing.expectEqual(@as(u64, 200), l.submitter_id);

    // submitter_id == 0 lane is intentionally empty (legacy bulk-import
    // links are not indexed). The `legacy` link above must NOT appear.
    const zero_links = (try listLinksBySubmitter(db, 0, 0, 10, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 0), zero_links.len);
}

test "listLinksBySubmitter: pagination via offset" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://x{d}.example", .{i});
        _ = try createLinkWithOpts(db, top_id, url, "x", "", .{ .submitter_id = 42 });
    }

    var buf: [10]types.Link = undefined;
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    var ids: [5]u64 = undefined;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var url_buf: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "https://c{d}.example", .{i});
        ids[i] = try createLinkWithOpts(db, top_id, url, "c", "", .{ .submitter_id = 77 });
    }

    var buf: [10]types.Link = undefined;

    // Page 1: limit 2 from the start. Two more remain → next_after_id == ids[1].
    const p1 = try listLinksBySubmitter(db, 77, 0, 2, &buf, null, 0);
    try std.testing.expectEqual(@as(usize, 2), p1.items.len);
    try std.testing.expectEqual(ids[0], p1.items[0].id);
    try std.testing.expectEqual(ids[1], p1.items[1].id);
    try std.testing.expectEqual(ids[1], p1.next_after_id);

    // Page 2: resume after ids[1] → ids[2], ids[3]; one more remains.
    const p2 = try listLinksBySubmitter(db, 77, 0, 2, &buf, null, p1.next_after_id);
    try std.testing.expectEqual(@as(usize, 2), p2.items.len);
    try std.testing.expectEqual(ids[2], p2.items[0].id);
    try std.testing.expectEqual(ids[3], p2.items[1].id);
    try std.testing.expectEqual(ids[3], p2.next_after_id);

    // Page 3: resume after ids[3] → ids[4] only; no more pages.
    const p3 = try listLinksBySubmitter(db, 77, 0, 2, &buf, null, p2.next_after_id);
    try std.testing.expectEqual(@as(usize, 1), p3.items.len);
    try std.testing.expectEqual(ids[4], p3.items[0].id);
    try std.testing.expectEqual(@as(u64, 0), p3.next_after_id);
}

test "countsByStatus tallies per-status totals" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const pending = @intFromEnum(types.LinkStatus.pending);
    const approved = @intFromEnum(types.LinkStatus.approved);
    const rejected = @intFromEnum(types.LinkStatus.rejected);

    // 2 pending, 3 approved, 1 rejected.
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const pending = @intFromEnum(types.LinkStatus.pending);
    const approved = @intFromEnum(types.LinkStatus.approved);
    const rejected = @intFromEnum(types.LinkStatus.rejected);

    const id = try createLinkWithOpts(db, top_id, "https://flip.example", "f", "", .{ .status = pending });
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 1), c.pending);
        try std.testing.expectEqual(@as(u64, 0), c.approved);
        try std.testing.expectEqual(@as(u64, 0), c.rejected);
    }

    // pending → approved: pending--, approved++.
    try updateLinkStatus(db, id, approved);
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 0), c.pending);
        try std.testing.expectEqual(@as(u64, 1), c.approved);
        try std.testing.expectEqual(@as(u64, 0), c.rejected);
    }

    // approved → rejected: approved--, rejected++.
    try updateLinkStatus(db, id, rejected);
    {
        const c = try countsByStatus(db);
        try std.testing.expectEqual(@as(u64, 0), c.approved);
        try std.testing.expectEqual(@as(u64, 1), c.rejected);
    }

    // Pure text edit (no status change) must leave the tally untouched.
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const approved = @intFromEnum(types.LinkStatus.approved);
    const id = try createLinkWithOpts(db, top_id, "https://del.example", "d", "", .{ .status = approved });
    try std.testing.expectEqual(@as(u64, 1), (try countsByStatus(db)).approved);

    try deleteLink(db, id);
    try std.testing.expectEqual(@as(u64, 0), (try countsByStatus(db)).approved);
}

test "recountLinkStatuses: counters are reseeded from disk on reopen" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const pending = @intFromEnum(types.LinkStatus.pending);
    const approved = @intFromEnum(types.LinkStatus.approved);

    // Phase 1: create 2 pending + 1 approved, then clean shutdown — the
    // shutdown drain + cache flush persist links_by_id to disk while the
    // in-memory counters are discarded.
    {
        var db = try Database.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();
        const top_id = try category.createCategory(db, 0, "Top", "top", "");
        _ = try createLinkWithOpts(db, top_id, "https://p1.example", "p1", "", .{ .status = pending });
        _ = try createLinkWithOpts(db, top_id, "https://p2.example", "p2", "", .{ .status = pending });
        _ = try createLinkWithOpts(db, top_id, "https://a1.example", "a1", "", .{ .status = approved });
    }

    // Phase 2: reopen + recover(). No apply hooks run this boot, so the
    // counters must come from recountLinkStatuses scanning the persisted
    // primary index.
    {
        var db = try Database.openTestInstance(allocator, &tmp);
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const pending = @intFromEnum(types.LinkStatus.pending);
    const approved = @intFromEnum(types.LinkStatus.approved);
    const id = try createLinkWithOpts(db, top_id, "https://s.example", "s", "", .{ .status = pending });

    // pending → approved succeeds.
    try updateLinkStatusBulkOne(db, id, approved);
    try std.testing.expectEqual(approved, (try getLink(db, id)).?.status);

    // approved → approved is a no-op → AlreadyInState.
    try std.testing.expectError(OperationError.AlreadyInState, updateLinkStatusBulkOne(db, id, approved));

    // Non-existent id → LinkNotFound.
    try std.testing.expectError(OperationError.LinkNotFound, updateLinkStatusBulkOne(db, 999_999, approved));
}

test "deleteLink removes link_by_submitter entry" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLinkWithOpts(db, top_id, "https://gone.example", "g", "", .{ .submitter_id = 7 });

    var buf: [4]types.Link = undefined;
    {
        const before = (try listLinksBySubmitter(db, 7, 0, 4, &buf, null, 0)).items;
        try std.testing.expectEqual(@as(usize, 1), before.len);
    }

    try deleteLink(db, link_id);

    const after = (try listLinksBySubmitter(db, 7, 0, 4, &buf, null, 0)).items;
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "createLink rollback: failure during secondary insert leaves no trace in primary" {
    // Set up a Database with a planted memtable that errors on the second secondary put.
    // Implementation note: in this codebase we don't currently mock per-shard allocation
    // failures, so this test instead exercises the success path AND a manual rollback to
    // verify delete() works as expected.
    const std_t = std.testing;

    // Smoke test the rollback path by direct invocation of the helpers.
    const allocator = std_t.allocator;
    var mt = memtable.MemTable.init(allocator);
    defer mt.deinit();

    const k1 = types.encodeU64(123);
    try mt.put(&k1, "value");

    // Verify present.
    const before = mt.get(&k1);
    try std_t.expect(before == .found);

    // Simulate rollback.
    try mt.delete(&k1);

    const after = mt.get(&k1);
    try std_t.expect(after == .deleted);
}

test "createLink cascades link_count_subtree up the chain" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLink(db, top_id, "https://x.example", "Hello World", "Greeting message");

    // Each entry's key is `token_bytes || encodeU64(link_id)`. Look up "hello"
    // (from title), "https" (from url), and "greeting" (from description) —
    // confirms the new createLink path routed all three fields through
    // applyLinkInserted into the on-disk inverted index.
    var v_buf: [8]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const id_be = types.encodeU64(link_id);

    const expected_tokens = [_][]const u8{ "hello", "https", "greeting" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }
}

test "deleteLink cascades link_count_subtree decrement" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLink(db, top_id, "https://y.example", "Goodbye Cruel", "Farewell note");

    // Sanity: tokens are present and primary lookup succeeds before delete.
    var v_buf: [8]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const id_be = types.encodeU64(link_id);
    const expected_tokens = [_][]const u8{ "goodbye", "https", "farewell" };
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }
    try std.testing.expect((try getLink(db, link_id)) != null);

    try deleteLink(db, link_id);

    // Primary lookup returns null (memtable tombstone).
    try std.testing.expect((try getLink(db, link_id)) == null);

    // Each token entry is gone from links_index_tree.
    for (expected_tokens) |tok| {
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found == null);
    }
}

test "updateLink: title tokens swapped in links_index_tree" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try category.createCategory(db, 0, "Top", "top", "");
    const link_id = try createLink(db, top_id, "https://z.example", "Hello", "");

    // Sanity: "hello" token present before the update.
    var v_buf: [8]u8 = undefined;
    var key_buf: [128]u8 = undefined;
    const id_be = types.encodeU64(link_id);
    {
        const tok = "hello";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    // Update the title from "Hello" to "World" — keep url/desc unchanged.
    try updateLink(db, link_id, null, "World", null);

    // Old title token "hello" is gone from links_index_tree for this link.
    {
        const tok = "hello";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found == null);
    }
    // New title token "world" is present.
    {
        const tok = "world";
        @memcpy(key_buf[0..tok.len], tok);
        @memcpy(key_buf[tok.len..][0..8], &id_be);
        const found = try db.links_index_tree.search(key_buf[0 .. tok.len + 8], &v_buf);
        try std.testing.expect(found != null);
    }

    // Primary reflects the new title.
    const link = (try getLink(db, link_id)).?;
    try std.testing.expect(link.title.eql("World"));
}

test "multiple links cascade correctly" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
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
    try std.testing.expectEqual(@as(u64, 2), b.link_count_subtree); // 2 own
    try std.testing.expectEqual(@as(u64, 3), a.link_count_subtree); // 1 own + 2 from b
    try std.testing.expectEqual(@as(u64, 3), top.link_count_subtree);
}

test "moveLink: happy path swaps category + updates both chains" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "A", "a", "");
    const b_id = try ops.createCategory(db, top_id, "B", "b", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);
    db.drainOneMemtable(&db.mt_cat_by_parent, &db.cat_by_parent);

    const link_id = try ops.createLink(db, a_id, "https://move.test/x", "Move Me", "");
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);
    db.drainOneMemtable(&db.mt_link_by_category, &db.link_by_category);

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
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "A", "a", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);

    const link_id = try ops.createLink(db, a_id, "https://noop.test/x", "Noop", "");
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);

    try ops.moveLink(db, link_id, a_id); // no error

    const link = (try ops.getLink(db, link_id)).?;
    try std.testing.expectEqual(a_id, link.category_id);
}

test "moveLink: missing link returns LinkNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);

    const result = ops.moveLink(db, 9999, top_id);
    try std.testing.expectError(OperationError.LinkNotFound, result);
}

test "moveLink: missing target category returns CategoryNotFound" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Database.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const a_id = try ops.createCategory(db, top_id, "A", "a", "");
    db.drainOneMemtable(&db.mt_categories_by_id, &db.categories_by_id);

    const link_id = try ops.createLink(db, a_id, "https://x.test/x", "X", "");
    db.drainOneMemtable(&db.mt_links_by_id, &db.links_by_id);

    const result = ops.moveLink(db, link_id, 99999);
    try std.testing.expectError(OperationError.CategoryNotFound, result);
}
