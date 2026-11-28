//! Tests for the per-status subtree link counts of format 10: every write that moves a link in
//! or out of a subtree, or between statuses, keeps each category's approved, pending and
//! (derived) rejected counts exact at the category and at every ancestor; WAL replay, the boot
//! recount of an upgraded format 9 store, and the verifier agree with a brute-force recount.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const zigstore = @import("zigstore");
const codec = zigstore.codec;
const schema = @import("schema.zig");
const directory_module = @import("directory.zig");
const Directory = directory_module.Directory;
const ops = @import("operations/operations.zig");
const binary_protocol = @import("binary_protocol.zig");
const verifier = @import("verifier.zig");
const depth_max = @import("operations/operations_shared.zig").depth_max;

const pending: u8 = @intFromEnum(schema.LinkStatus.pending);
const approved: u8 = @intFromEnum(schema.LinkStatus.approved);
const rejected: u8 = @intFromEnum(schema.LinkStatus.rejected);

const Want = struct { approved: u64 = 0, pending: u64 = 0, rejected: u64 = 0 };

fn expect_counts(db: *Directory, category_id: u64, want: Want) !void {
    assert(category_id != 0);
    const category = (try ops.get_category(db, category_id)) orelse return error.CategoryLost;
    assert(category.id == category_id);
    const got: Want = .{
        .approved = schema.link_count_subtree_with_status(&category, .approved),
        .pending = schema.link_count_subtree_with_status(&category, .pending),
        .rejected = schema.link_count_subtree_with_status(&category, .rejected),
    };
    try testing.expectEqual(want, got);
    const total = want.approved + want.pending + want.rejected;
    try testing.expectEqual(total, category.link_count_subtree);
}

fn expect_chain(db: *Directory, chain: []const u64, want: Want) !void {
    assert(chain.len > 0);
    assert(chain.len <= depth_max);
    for (chain) |category_id| try expect_counts(db, category_id, want);
}

fn add_link(db: *Directory, category_id: u64, url: []const u8, status: u8) !u64 {
    assert(category_id != 0);
    assert(status <= rejected);
    const text: ops.LinkText = .{ .url = url, .title = "t", .description = "" };
    const id = try ops.create_link_with_options(db, category_id, text, .{ .status = status });
    assert(id != 0);
    return id;
}

fn add_category(db: *Directory, parent_id: u64, slug: []const u8) !u64 {
    assert(slug.len > 0);
    const text: ops.CategoryText = .{ .name = slug, .slug = slug, .description = "" };
    const id = try ops.create_category(db, parent_id, text);
    assert(id != 0);
    return id;
}

// Top, with two branches: a/b and c/d.
const Tree = struct { top: u64, a: u64, b: u64, c: u64, d: u64 };

fn build_tree(db: *Directory) !Tree {
    // A recovered empty store already holds the Top that bootstrap creates.
    const top = (try ops.resolve_slug_path(db, "top")) orelse try add_category(db, 0, "top");
    const a = try add_category(db, top, "a");
    const c = try add_category(db, top, "c");
    const tree: Tree = .{
        .top = top,
        .a = a,
        .b = try add_category(db, a, "b"),
        .c = c,
        .d = try add_category(db, c, "d"),
    };
    assert(tree.b != tree.d);
    return tree;
}

// The per-status count of every category's subtree, built by walking every link up its own
// category chain, with no use of the stored counters.
const BruteForce = std.AutoHashMap(u64, Want);

fn brute_force_counts(db: *Directory) !BruteForce {
    var counts = BruteForce.init(testing.allocator);
    errdefer counts.deinit();
    try db.drain_all_memtables();
    defer assert(counts.count() <= db.categories_by_id().entryCount());
    const start_key = codec.encodeU64(0);
    var iterator = try db.links_by_id().rangeScan(&start_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        assert(entry.value.len == @sizeOf(schema.Link));
        const link = std.mem.bytesToValue(schema.Link, entry.value[0..@sizeOf(schema.Link)]);
        var current_id = link.category_id;
        for (0..depth_max) |_| {
            if (current_id == 0) break;
            const category = (try ops.get_category(db, current_id)) orelse break;
            const slot = try counts.getOrPut(current_id);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            switch (link.status) {
                approved => slot.value_ptr.approved += 1,
                pending => slot.value_ptr.pending += 1,
                else => slot.value_ptr.rejected += 1,
            }
            current_id = category.parent_id;
        }
    }
    return counts;
}

/// Every category's stored counters equal the brute-force recount, and the three statuses sum
/// to `link_count_subtree`. Returns how many categories were checked.
fn expect_matches_brute_force(db: *Directory) !u32 {
    var counts = try brute_force_counts(db);
    defer counts.deinit();
    var checked: u32 = 0;
    const start_key = codec.encodeU64(0);
    var iterator = try db.categories_by_id().rangeScan(&start_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        assert(entry.value.len == @sizeOf(schema.Category));
        const category = std.mem.bytesToValue(
            schema.Category,
            entry.value[0..@sizeOf(schema.Category)],
        );
        const want = counts.get(category.id) orelse Want{};
        try testing.expectEqual(want.approved, category.link_count_subtree_approved);
        try testing.expectEqual(want.pending, category.link_count_subtree_pending);
        const derived = schema.link_count_subtree_with_status(&category, .rejected);
        try testing.expectEqual(want.rejected, derived);
        const total = want.approved + want.pending + want.rejected;
        try testing.expectEqual(total, category.link_count_subtree);
        checked += 1;
    }
    assert(checked == db.categories_by_id().entryCount());
    return checked;
}

// Goal: a created link counts under its status at its category and every ancestor, and nowhere
// else. Method: one link of each status into b, then read b, a, top and the other branch.
test "status counts: create_link counts the link under its status up the chain" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);

    _ = try add_link(db, tree.b, "https://p.example", pending);
    try expect_chain(db, &.{ tree.b, tree.a, tree.top }, .{ .pending = 1 });
    _ = try add_link(db, tree.b, "https://a.example", approved);
    _ = try add_link(db, tree.b, "https://r.example", rejected);

    const one_each: Want = .{ .approved = 1, .pending = 1, .rejected = 1 };
    try expect_chain(db, &.{ tree.b, tree.a, tree.top }, one_each);
    try expect_chain(db, &.{ tree.c, tree.d }, .{});
}

// Goal: a deleted link leaves its status's count at its category and every ancestor. Method:
// three links in d, delete the approved one, then the pending one.
test "status counts: delete_link removes the link from its status up the chain" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);

    const kept = try add_link(db, tree.d, "https://p.example", pending);
    const gone = try add_link(db, tree.d, "https://a.example", approved);
    _ = try add_link(db, tree.d, "https://r.example", rejected);

    try ops.delete_link(db, gone);
    try expect_chain(db, &.{ tree.d, tree.c, tree.top }, .{ .pending = 1, .rejected = 1 });
    try ops.delete_link(db, kept);
    try expect_chain(db, &.{ tree.d, tree.c, tree.top }, .{ .rejected = 1 });
    try expect_chain(db, &.{ tree.a, tree.b }, .{});
}

// Goal: a status change moves exactly one unit between two counters at the category and every
// ancestor and leaves the all-status total alone. Method: walk one link pending, approved,
// rejected, pending, checking the chain and the total after each step.
test "status counts: a status change moves one unit and keeps the total" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);
    _ = try add_link(db, tree.b, "https://other.example", approved);
    const id = try add_link(db, tree.b, "https://moving.example", pending);
    const chain = [_]u64{ tree.b, tree.a, tree.top };

    try expect_chain(db, &chain, .{ .approved = 1, .pending = 1 });
    try ops.update_link_status(db, id, approved);
    try expect_chain(db, &chain, .{ .approved = 2 });
    try ops.update_link_status(db, id, rejected);
    try expect_chain(db, &chain, .{ .approved = 1, .rejected = 1 });
    try ops.update_link_status(db, id, pending);
    try expect_chain(db, &chain, .{ .approved = 1, .pending = 1 });
    for (chain) |category_id| {
        const category = (try ops.get_category(db, category_id)).?;
        try testing.expectEqual(@as(u64, 2), category.link_count_subtree);
    }
    try expect_chain(db, &.{ tree.c, tree.d }, .{});
}

// Goal: moving a link between subtrees takes its status out of the old chain and into the new
// one, and leaves the common ancestor unchanged. Method: a pending link from b to d.
test "status counts: move_link carries the status from the old chain to the new" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);
    const id = try add_link(db, tree.b, "https://p.example", pending);
    _ = try add_link(db, tree.b, "https://r.example", rejected);

    try ops.move_link(db, .{ .id = id, .new_parent_id = tree.d });

    try expect_chain(db, &.{ tree.b, tree.a }, .{ .rejected = 1 });
    try expect_chain(db, &.{ tree.d, tree.c }, .{ .pending = 1 });
    try expect_counts(db, tree.top, .{ .pending = 1, .rejected = 1 });
}

// Goal: moving a category across subtrees moves all three statuses' counts from the old
// ancestors to the new ones and keeps the moved category's own. Method: b holds one link of
// each status and a second approved one; move b from under a to under d.
test "status counts: move_category moves every status between ancestor chains" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);
    _ = try add_link(db, tree.b, "https://a1.example", approved);
    _ = try add_link(db, tree.b, "https://a2.example", approved);
    _ = try add_link(db, tree.b, "https://p.example", pending);
    _ = try add_link(db, tree.b, "https://r.example", rejected);
    _ = try add_link(db, tree.d, "https://d.example", pending);
    const moved: Want = .{ .approved = 2, .pending = 1, .rejected = 1 };
    try expect_counts(db, tree.a, moved);

    try ops.move_category(db, .{ .id = tree.b, .new_parent_id = tree.d });

    try expect_counts(db, tree.b, moved);
    try expect_counts(db, tree.a, .{});
    try expect_chain(db, &.{ tree.d, tree.c }, .{ .approved = 2, .pending = 2, .rejected = 1 });
    try expect_counts(db, tree.top, .{ .approved = 2, .pending = 2, .rejected = 1 });
    try testing.expectEqual(@as(u32, 5), try expect_matches_brute_force(db));
}

// Goal: deleting a category with links takes every status out of its ancestors. Method: b
// holds three links; delete b and read a and top.
test "status counts: delete_category takes its links' statuses out of the ancestors" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);
    _ = try add_link(db, tree.b, "https://a.example", approved);
    _ = try add_link(db, tree.b, "https://p.example", pending);
    _ = try add_link(db, tree.b, "https://r.example", rejected);
    _ = try add_link(db, tree.a, "https://kept.example", pending);

    try ops.delete_category(db, tree.b);

    try expect_chain(db, &.{ tree.a, tree.top }, .{ .pending = 1 });
    try testing.expectEqual(@as(u32, 4), try expect_matches_brute_force(db));
}

fn append_bulk_item(buffer: []u8, start: usize, category_id: u64, url: []const u8) usize {
    assert(url.len <= std.math.maxInt(u16));
    assert(start + 8 + 6 + url.len + 1 <= buffer.len);
    var offset = start;
    std.mem.writeInt(u64, buffer[offset..][0..8], category_id, .little);
    offset += 8;
    std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(url.len), .little);
    offset += 2;
    @memcpy(buffer[offset..][0..url.len], url);
    offset += url.len;
    std.mem.writeInt(u16, buffer[offset..][0..2], 1, .little);
    buffer[offset + 2] = 't';
    std.mem.writeInt(u16, buffer[offset + 3 ..][0..2], 0, .little);
    offset += 5;
    assert(offset > start);
    return offset;
}

fn bulk_ids_payload(buffer: []u8, prefix: []const u8, ids: []const u64) []const u8 {
    assert(prefix.len + 2 + ids.len * 8 <= buffer.len);
    assert(ids.len <= std.math.maxInt(u16));
    assert(ids.len > 0);
    @memcpy(buffer[0..prefix.len], prefix);
    std.mem.writeInt(u16, buffer[prefix.len..][0..2], @intCast(ids.len), .little);
    for (ids, 0..) |id, index| {
        std.mem.writeInt(u64, buffer[prefix.len + 2 + index * 8 ..][0..8], id, .little);
    }
    return buffer[0 .. prefix.len + 2 + ids.len * 8];
}

// Goal: the bulk ops keep the counts as their single-link forms do. Method: bulk-import three
// approved links into b and d over the wire, bulk-reject two of them, bulk-delete one.
test "status counts: bulk import, bulk status and bulk delete keep the chains exact" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);
    var response: [4096]u8 = undefined;
    var payload: [512]u8 = undefined;

    var offset = append_bulk_item(&payload, 0, tree.b, "https://bulk1.example");
    offset = append_bulk_item(&payload, offset, tree.b, "https://bulk2.example");
    offset = append_bulk_item(&payload, offset, tree.d, "https://bulk3.example");
    const bulk_import = @intFromEnum(binary_protocol.Op.bulk_import);
    _ = binary_protocol.dispatch(db, bulk_import, payload[0..offset], 3, &response);
    try testing.expectEqual(@as(u64, 3), std.mem.readInt(u64, response[10..18], .little));
    const first_id = std.mem.readInt(u64, response[34..42], .little);
    try expect_chain(db, &.{ tree.b, tree.a }, .{ .approved = 2 });
    try expect_counts(db, tree.top, .{ .approved = 3 });

    const status_payload = bulk_ids_payload(&payload, &.{rejected}, &.{ first_id, first_id + 2 });
    const bulk_status = @intFromEnum(binary_protocol.Op.bulk_update_link_status);
    _ = binary_protocol.dispatch(db, bulk_status, status_payload, 0, &response);
    try expect_chain(db, &.{ tree.b, tree.a }, .{ .approved = 1, .rejected = 1 });
    try expect_chain(db, &.{ tree.d, tree.c }, .{ .rejected = 1 });

    const delete_payload = bulk_ids_payload(&payload, &.{}, &.{first_id + 1});
    const bulk_delete = @intFromEnum(binary_protocol.Op.bulk_delete_links);
    _ = binary_protocol.dispatch(db, bulk_delete, delete_payload, 0, &response);
    try expect_chain(db, &.{ tree.b, tree.a }, .{ .rejected = 1 });
    try expect_counts(db, tree.top, .{ .rejected = 2 });
}

fn open_recovered_and_checkpointed(temporary_directory: *std.testing.TmpDir) !*Directory {
    const db = try Directory.open_test_instance(testing.allocator, temporary_directory);
    errdefer db.deinit_test_instance();
    try db.recover();
    // A checkpoint after the first recover stamps the derived counts as current on disk, so
    // the next boot replays the WAL without a recount that would hide a replay bug.
    _ = try db.checkpoint();
    assert(db.derived_counts_checkpointed());
    assert(db.recovered);
    return db;
}

// Goal: WAL replay after a crash reproduces the counters the live applies produced, without
// the boot recount. Method: checkpoint an empty store, then insert, move, re-status and delete
// links and move a category, capture every category's counters, crash, reopen, check that no
// recount is owed, recover, and compare against the capture and a brute-force recount.
test "status counts: WAL replay after a crash reproduces the counters" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var captured: [5]schema.Category = undefined;
    const ids: [5]u64 = blk: {
        const first = try open_recovered_and_checkpointed(&temporary_directory);
        const tree = try build_tree(first);
        const kept = try add_link(first, tree.b, "https://a.example", pending);
        const flipped = try add_link(first, tree.b, "https://p.example", pending);
        const gone = try add_link(first, tree.d, "https://r.example", rejected);
        _ = try add_link(first, tree.d, "https://d.example", approved);
        try ops.update_link_status(first, flipped, approved);
        try ops.move_link(first, .{ .id = kept, .new_parent_id = tree.d });
        try ops.move_category(first, .{ .id = tree.b, .new_parent_id = tree.c });
        try ops.delete_link(first, gone);
        const ids = [5]u64{ tree.top, tree.a, tree.b, tree.c, tree.d };
        for (ids, &captured) |id, *slot| slot.* = (try ops.get_category(first, id)).?;
        first.deinit_crash_test_instance();
        break :blk ids;
    };

    const second = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try testing.expect(second.derived_counts_checkpointed());
    try second.recover();
    for (ids, captured) |id, before| {
        const after = (try ops.get_category(second, id)).?;
        try testing.expectEqual(before.link_count_subtree, after.link_count_subtree);
        const statuses_before = schema.SubtreeStatusCounts.of_subtree(&before);
        try testing.expectEqual(statuses_before, schema.SubtreeStatusCounts.of_subtree(&after));
    }
    try expect_counts(second, ids[0], .{ .approved = 2, .pending = 1 });
    _ = try expect_matches_brute_force(second);
}

fn write_store_as_format_9(temporary_directory: *std.testing.TmpDir) !void {
    const Header = directory_module.Store.Header;
    const file = try temporary_directory.dir.openFile(
        testing.io,
        "store.dat",
        .{ .mode = .read_write },
    );
    defer file.close(testing.io);
    var page: [@sizeOf(Header)]u8 = undefined;
    const read = try file.readPositionalAll(testing.io, &page, 0);
    assert(read == page.len);
    var header = std.mem.bytesToValue(Header, &page);
    assert(header.format_version == directory_module.schema.format_version);
    header.format_version = directory_module.schema_v9.format_version;
    assert(header.derived_counts_version != directory_module.derived_counts_version_stale);
    try file.writePositionalAll(testing.io, &std.mem.toBytes(header), 0);
    try file.sync(testing.io);
}

// A format 9 store held nothing in the two words format 10 counts in.
fn zero_status_counts(db: *Directory) !void {
    try db.drain_all_memtables();
    var ids: [16]u64 = undefined;
    var count: usize = 0;
    {
        const start_key = codec.encodeU64(0);
        var iterator = try db.categories_by_id().rangeScan(&start_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| : (count += 1) {
            assert(count < ids.len);
            ids[count] = codec.decodeU64(entry.key[0..8]);
        }
    }
    assert(count > 0);
    for (ids[0..count]) |id| {
        var category = (try ops.get_category(db, id)).?;
        category.link_count_subtree_approved = 0;
        category.link_count_subtree_pending = 0;
        try db.categories_by_id().insert(&codec.encodeU64(id), std.mem.asBytes(&category));
    }
}

// Goal: a format 9 store opens, is brought to format 10 with exact counters by the boot
// recount, and survives a crash before the recount ran. Method: build a store, zero every
// category's per-status words and stamp page 0 as format 9; open (header upgrade) and crash
// before recover; reopen, expect format 10 with the recount still owed, recover, and compare
// every category against a brute-force recount.
test "status counts: a format 9 store upgrades to exact counters, restartably" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    {
        const first = try open_recovered_and_checkpointed(&temporary_directory);
        defer first.deinit_test_instance();
        const tree = try build_tree(first);
        _ = try add_link(first, tree.b, "https://a.example", approved);
        _ = try add_link(first, tree.b, "https://p.example", pending);
        _ = try add_link(first, tree.d, "https://r.example", rejected);
        _ = try add_link(first, tree.d, "https://a2.example", approved);
        try zero_status_counts(first);
        const zeroed = (try ops.get_category(first, tree.top)).?;
        try testing.expectEqual(@as(u32, 0), zeroed.link_count_subtree_approved);
    }
    try write_store_as_format_9(&temporary_directory);

    {
        const crashed = try Directory.open_test_instance(testing.allocator, &temporary_directory);
        try testing.expectEqual(@as(u32, 10), crashed.store.header.format_version);
        try testing.expect(!crashed.derived_counts_checkpointed());
        crashed.deinit_crash_test_instance();
    }

    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try testing.expect(!db.derived_counts_checkpointed());
    try db.recover();
    try testing.expect(db.derived_counts_checkpointed());
    const top = (try ops.resolve_slug_path(db, "top")).?;
    try expect_counts(db, top, .{ .approved = 2, .pending = 1, .rejected = 1 });
    try testing.expect(try expect_matches_brute_force(db) >= 5);
}

// Goal: the verifier reports a corrupted per-status counter without touching it, and the
// recount that repairs counts restores it. Method: corrupt a's approved count in the tree,
// run the verifier, recount, run it again.
test "status counts: the verifier detects a corrupted counter and the recount repairs it" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    const tree = try build_tree(db);
    _ = try add_link(db, tree.b, "https://a.example", approved);
    _ = try add_link(db, tree.b, "https://p.example", pending);
    try db.drain_all_memtables();
    var corrupted = (try ops.get_category(db, tree.a)).?;
    corrupted.link_count_subtree_approved = 0;
    corrupted.link_count_subtree_pending = 2;
    try db.categories_by_id().insert(&codec.encodeU64(tree.a), std.mem.asBytes(&corrupted));

    var state = verifier.VerifierState{};
    try verifier.run_once(db, &state);
    const subtree = state.indices[@intFromEnum(verifier.InvariantId.subtree_counts)];
    try testing.expectEqual(@as(u64, 1), subtree.expected - subtree.observed);
    const untouched = (try ops.get_category(db, tree.a)).?;
    try testing.expectEqual(@as(u32, 2), untouched.link_count_subtree_pending);

    try ops.recompute_category_counts(db);
    try expect_counts(db, tree.a, .{ .approved = 1, .pending = 1 });
    var clean = verifier.VerifierState{};
    try verifier.run_once(db, &clean);
    try testing.expect(!clean.any_drift);
}

const RandomWriter = struct {
    db: *Directory,
    random: std.Random,
    categories: std.ArrayListUnmanaged(u64) = .empty,
    links: std.ArrayListUnmanaged(u64) = .empty,
    url_counter: u32 = 0,
    slug_counter: u32 = 0,

    fn pick(writer: *RandomWriter, items: []const u64) ?u64 {
        if (items.len == 0) return null;
        const index = writer.random.uintLessThan(usize, items.len);
        assert(index < items.len);
        assert(items[index] != 0);
        return items[index];
    }

    fn status(writer: *RandomWriter) u8 {
        const value = writer.random.uintLessThan(u8, 3);
        assert(value <= rejected);
        return value;
    }

    fn step(writer: *RandomWriter) !void {
        assert(writer.categories.items.len > 0);
        assert(writer.links.items.len <= writer.url_counter);
        const category = writer.pick(writer.categories.items).?;
        switch (writer.random.uintLessThan(u8, 8)) {
            0, 1 => try writer.create_link(category),
            2 => if (writer.pick(writer.links.items)) |id| {
                try ops.update_link_status(writer.db, id, writer.status());
            },
            3 => if (writer.pick(writer.links.items)) |id| {
                try ops.move_link(writer.db, .{ .id = id, .new_parent_id = category });
            },
            4 => try writer.delete_link(),
            5 => try writer.move_category(category),
            6 => try writer.create_category(category),
            else => try writer.delete_category(),
        }
    }

    fn create_link(writer: *RandomWriter, category: u64) !void {
        var url_buffer: [48]u8 = undefined;
        writer.url_counter += 1;
        const url = try std.fmt.bufPrint(&url_buffer, "https://r{d}.example", .{
            writer.url_counter,
        });
        const id = try add_link(writer.db, category, url, writer.status());
        try writer.links.append(testing.allocator, id);
        assert(writer.links.items.len <= writer.url_counter);
    }

    fn delete_link(writer: *RandomWriter) !void {
        if (writer.links.items.len == 0) return;
        const index = writer.random.uintLessThan(usize, writer.links.items.len);
        const id = writer.links.swapRemove(index);
        assert(id != 0);
        try ops.delete_link(writer.db, id);
        assert(index <= writer.links.items.len);
    }

    fn create_category(writer: *RandomWriter, parent: u64) !void {
        if (writer.categories.items.len >= 24) return;
        var slug_buffer: [16]u8 = undefined;
        writer.slug_counter += 1;
        const slug = try std.fmt.bufPrint(&slug_buffer, "c{d}", .{writer.slug_counter});
        const id = try add_category(writer.db, parent, slug);
        try writer.categories.append(testing.allocator, id);
        assert(writer.categories.items.len <= 24);
    }

    fn delete_category(writer: *RandomWriter) !void {
        if (writer.categories.items.len < 2) return;
        const index = 1 + writer.random.uintLessThan(usize, writer.categories.items.len - 1);
        assert(index < writer.categories.items.len);
        ops.delete_category(writer.db, writer.categories.items[index]) catch |err| switch (err) {
            error.CategoryHasChildren => return,
            else => return err,
        };
        _ = writer.categories.swapRemove(index);
        // The delete took the category's links with it.
        var link_index = writer.links.items.len;
        while (link_index > 0) {
            link_index -= 1;
            const id = writer.links.items[link_index];
            if ((try ops.get_link(writer.db, id)) == null) _ = writer.links.swapRemove(link_index);
        }
        assert(writer.categories.items.len >= 1);
    }

    fn move_category(writer: *RandomWriter, new_parent: u64) !void {
        const moved = writer.pick(writer.categories.items[1..]) orelse return;
        assert(moved != writer.categories.items[0]);
        assert(new_parent != 0);
        ops.move_category(writer.db, .{ .id = moved, .new_parent_id = new_parent }) catch |err| {
            switch (err) {
                // A move under its own subtree, or one that would collide a slug, is refused.
                error.CircularHierarchy, error.DuplicateSlug, error.PathTooDeep => return,
                else => return err,
            }
        };
    }
};

// Goal: after a long random run of every kind of write, every category's per-status counts sum
// to its subtree total and equal a brute-force recount, and they still do after a crash and
// WAL replay. Method: a fixed seed drives 600 writes over a growing tree of up to 24
// categories, checked every 100 writes; then crash, reopen without a recount, recover, check.
test "status counts: a random write sequence keeps every counter exact, before and after replay" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var prng = std.Random.DefaultPrng.init(0x5747_5553);
    {
        const db = try open_recovered_and_checkpointed(&temporary_directory);
        var writer: RandomWriter = .{ .db = db, .random = prng.random() };
        defer writer.categories.deinit(testing.allocator);
        defer writer.links.deinit(testing.allocator);
        try writer.categories.append(testing.allocator, (try ops.resolve_slug_path(db, "top")).?);
        for (0..600) |index| {
            try writer.step();
            if (index % 100 == 99) _ = try expect_matches_brute_force(db);
        }
        try testing.expect(writer.links.items.len > 10);
        try testing.expect(writer.categories.items.len > 10);
        db.deinit_crash_test_instance();
    }

    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try testing.expect(db.derived_counts_checkpointed());
    try db.recover();
    try testing.expect(try expect_matches_brute_force(db) > 10);
}

// Goal: the derived rejected count never wraps when stored counters exceed the total, as a
// drifted store could hold. Method: a record with approved + pending above its total.
test "status counts: rejected reads as none when the stored counters exceed the total" {
    const category: schema.Category = .{
        .link_count_subtree = 3,
        .link_count_subtree_approved = 2,
        .link_count_subtree_pending = 2,
    };
    const with_status = schema.link_count_subtree_with_status;
    try testing.expectEqual(@as(u64, 0), with_status(&category, .rejected));
    try testing.expectEqual(@as(u64, 2), with_status(&category, .pending));
}
