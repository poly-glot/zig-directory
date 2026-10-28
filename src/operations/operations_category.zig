//! Category writes and reads: create, text update, slug rename, delete and move, each committed
//! as one `ChangeSet` under the write mutex; the child listing and ancestor walks the handlers
//! read with; and the count rebuild that recovery and the verifier use to bring the stored
//! `link_count*` and `child_count*` columns back in line with the indexes.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const shared = @import("operations_shared.zig");
const compute = @import("operations_changeset_compute.zig");
const link_operations = @import("operations_link.zig");
const slug_operations = @import("operations_slug.zig");
const test_support = @import("../test_support.zig");

const OperationError = shared.OperationError;
const name_len_max = shared.name_len_max;
const slug_len_max = shared.slug_len_max;
const category_description_len_max = shared.category_description_len_max;

pub fn create_category(db: *Directory, parent_id: u64, text: shared.CategoryText) !u64 {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    if (text.name.len > name_len_max) return OperationError.FieldTooLong;
    if (text.slug.len > slug_len_max) return OperationError.FieldTooLong;
    if (text.description.len > category_description_len_max) return OperationError.FieldTooLong;

    if (parent_id != 0) {
        const parent = (try get_category(db, parent_id)) orelse
            return OperationError.ParentNotFound;
        assert(parent.id == parent_id);
    }
    try slug_operations.ensure_slug_path_free(
        db,
        .{ .parent_id = parent_id, .own_id = 0 },
        text.slug,
    );

    const id = db.next_category_id.fetchAdd(1, .monotonic);
    assert(id != 0);
    const now = db.now_seconds();

    const category = schema.Category{
        .id = id,
        .parent_id = parent_id,
        .name = codec.FixedString(64).fromSlice(text.name),
        .slug = codec.FixedString(128).fromSlice(text.slug),
        .description = codec.FixedString(1024).fromSlice(text.description),
        .link_count = 0,
        .child_count = 0,
        .sort_order = 0,
        ._pad0 = 0,
        .created_at = now,
        .updated_at = now,
    };
    assert(category.name.slice().len == text.name.len);
    assert(category.slug.slice().len == text.slug.len);
    assert(category.description.slice().len == text.description.len);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_category_insert_change_set(
        db,
        &category,
        arena.allocator(),
    );
    try db.commit(change_set);

    return id;
}

pub fn get_category(db: *Directory, id: u64) !?schema.Category {
    const key = codec.encodeU64(id);
    const memtable_result = db.memtable_categories_by_id().get(&key);
    var tree_buffer: [@sizeOf(schema.Category)]u8 = undefined;
    const value = switch (memtable_result) {
        .found => |found| found,
        .deleted => return null,
        .not_found => (try db.categories_by_id().search(&key, &tree_buffer)) orelse return null,
    };
    if (value.len != @sizeOf(schema.Category)) return OperationError.DatabaseCorrupted;
    const category = std.mem.bytesToValue(schema.Category, value[0..@sizeOf(schema.Category)]);
    assert(category.id == id);
    return category;
}

pub fn update_category(
    db: *Directory,
    id: u64,
    name: ?[]const u8,
    slug: ?[]const u8,
    description: ?[]const u8,
) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    if (name) |new_name| if (new_name.len > name_len_max) return OperationError.FieldTooLong;
    if (slug) |new_slug| if (new_slug.len > slug_len_max) return OperationError.FieldTooLong;
    if (description) |new_description| {
        if (new_description.len > category_description_len_max) return OperationError.FieldTooLong;
    }

    const old_category = (try get_category(db, id)) orelse return OperationError.CategoryNotFound;
    assert(old_category.id == id);

    const slug_changed = if (slug) |new_slug|
        !std.mem.eql(u8, new_slug, old_category.slug.slice())
    else
        false;

    if (!slug_changed) {
        var new_category = old_category;
        if (name) |new_name| new_category.name = codec.FixedString(64).fromSlice(new_name);
        if (description) |new_description| {
            new_category.description = codec.FixedString(1024).fromSlice(new_description);
        }
        new_category.updated_at = db.now_seconds();
        assert(new_category.slug.eql(old_category.slug.slice()));

        var arena = std.heap.ArenaAllocator.init(db.scratch());
        defer arena.deinit();

        const change_set = try compute.compute_category_text_update_change_set(
            &old_category,
            &new_category,
            arena.allocator(),
        );
        try db.commit(change_set);
        return;
    }

    try slug_operations.ensure_slug_path_free(
        db,
        .{ .parent_id = old_category.parent_id, .own_id = id },
        slug.?,
    );

    var new_category = old_category;
    if (name) |new_name| new_category.name = codec.FixedString(64).fromSlice(new_name);
    if (slug) |new_slug| new_category.slug = codec.FixedString(128).fromSlice(new_slug);
    if (description) |new_description| {
        new_category.description = codec.FixedString(1024).fromSlice(new_description);
    }
    new_category.updated_at = db.now_seconds();
    assert(!new_category.slug.eql(old_category.slug.slice()));
    assert(new_category.slug.slice().len == slug.?.len);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_category_rename_change_set(
        db,
        &old_category,
        &new_category,
        arena.allocator(),
    );
    try db.commit(change_set);
}

const delete_link_pages_max = 1 << 16;
const delete_links_per_page = 64;

pub fn delete_category(db: *Directory, id: u64) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    if ((try get_category(db, id)) == null) return OperationError.CategoryNotFound;

    var children_buffer: [1]schema.Category = undefined;
    const children = try list_children(db, id, .{ .limit = 1 }, &children_buffer);
    assert(children.len <= 1);
    if (children.len > 0) return OperationError.CategoryHasChildren;

    var links_buffer: [delete_links_per_page]schema.Link = undefined;
    for (0..delete_link_pages_max) |_| {
        const page = try link_operations.list_links(
            db,
            id,
            .{ .limit = delete_links_per_page },
            &links_buffer,
        );
        assert(page.items.len <= delete_links_per_page);
        if (page.items.len == 0) break;
        for (page.items) |link| {
            try link_operations.delete_link_locked(db, link.id);
        }
    } else return OperationError.CategoryTooLarge;

    const category = (try get_category(db, id)) orelse return OperationError.CategoryNotFound;
    assert(category.id == id);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_category_delete_change_set(
        db,
        &category,
        arena.allocator(),
    );
    try db.commit(change_set);
}

pub fn move_category(db: *Directory, move: shared.Move) !void {
    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    const old_category = (try get_category(db, move.id)) orelse
        return OperationError.CategoryNotFound;
    assert(old_category.id == move.id);

    if (move.new_parent_id != 0) {
        if ((try get_category(db, move.new_parent_id)) == null) {
            return OperationError.ParentNotFound;
        }
    }

    if (move.new_parent_id != 0) {
        var walk_id = move.new_parent_id;
        var depth: usize = 0;
        while (walk_id != 0) : (depth += 1) {
            if (depth >= shared.depth_max) return OperationError.PathTooDeep;
            if (walk_id == move.id) return OperationError.CircularHierarchy;
            const walk_category = (try get_category(db, walk_id)) orelse break;
            walk_id = walk_category.parent_id;
        }
    }
    assert(move.new_parent_id != move.id);

    if (old_category.parent_id == move.new_parent_id) return;
    try slug_operations.ensure_slug_path_free(
        db,
        .{ .parent_id = move.new_parent_id, .own_id = move.id },
        old_category.slug.slice(),
    );

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const change_set = try compute.compute_category_move_change_set(
        db,
        &old_category,
        move.new_parent_id,
        arena.allocator(),
    );
    try db.commit(change_set);
}

pub fn list_children(
    db: *Directory,
    parent_id: u64,
    page: shared.Page,
    buffer: []schema.Category,
) ![]schema.Category {
    assert(page.after_id == 0);
    assert(page.status_filter == null);
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const start_key = schema.ParentChildKey.encode(.{ parent_id, 0 });
    const end_key = schema.ParentChildKey.encode(.{ parent_id, std.math.maxInt(u64) });

    var count: u32 = 0;
    var skipped: u32 = 0;
    const max = @min(page.limit, @as(u32, @intCast(buffer.len)));

    var iterator = try db.cat_by_parent().rangeScan(&start_key, &end_key);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        if (skipped < page.offset) {
            skipped += 1;
            continue;
        }
        if (count >= max) break;

        if (entry.value.len < 8) return OperationError.DatabaseCorrupted;
        const child_id = codec.decodeU64(entry.value);
        if (try get_category(db, child_id)) |child| {
            buffer[count] = child;
            count += 1;
        }
    }

    assert(count <= max);
    assert(skipped <= page.offset);
    return buffer[0..count];
}

pub fn get_category_path(db: *Directory, id: u64, buffer: []u64) ![]u64 {
    var path_len: usize = 0;
    var current_id = id;

    while (current_id != 0) {
        if (path_len >= buffer.len) return OperationError.PathTooDeep;
        buffer[path_len] = current_id;
        path_len += 1;

        const current = (try get_category(db, current_id)) orelse break;
        current_id = current.parent_id;
    }

    if (path_len > 1) {
        std.mem.reverse(u64, buffer[0..path_len]);
    }

    const path = buffer[0..path_len];
    if (path.len > 0) assert(path[path.len - 1] == id);
    if (path.len > 0) assert(path[0] != 0);
    return path;
}

pub fn walk_ancestors(
    db: *Directory,
    id: u64,
    buffer: []schema.Category,
) ![]schema.Category {
    var id_buffer: [shared.depth_max + 1]u64 = undefined;
    const path = try get_category_path(db, id, &id_buffer);
    if (path.len > 0) assert(path[path.len - 1] == id);
    const ancestor_ids = path[0..path.len -| 1];
    assert(ancestor_ids.len <= shared.depth_max);
    const count = @min(ancestor_ids.len, buffer.len);
    for (ancestor_ids[0..count], 0..) |ancestor_id, i| {
        buffer[i] = (try get_category(db, ancestor_id)) orelse return buffer[0..i];
    }
    return buffer[0..count];
}

const SubtreeAggregate = struct { link_subtree: u64, child_subtree: u32 };

pub const ExpectedCounts = struct {
    link_count: u32,
    child_count: u32,
    link_count_subtree: u64,
    child_count_subtree: u32,
};

pub const CategoryCounts = struct {
    allocator: std.mem.Allocator,
    direct_links: std.AutoHashMap(u64, u32),
    children_of: std.AutoHashMap(u64, std.ArrayListUnmanaged(u64)),
    subtree: std.AutoHashMap(u64, SubtreeAggregate),

    pub fn deinit(self: *CategoryCounts) void {
        self.direct_links.deinit();
        var children = self.children_of.valueIterator();
        while (children.next()) |list| list.deinit(self.allocator);
        self.children_of.deinit();
        self.subtree.deinit();
    }

    pub fn expected_for(self: *const CategoryCounts, category_id: u64) ExpectedCounts {
        const link_count: u32 = self.direct_links.get(category_id) orelse 0;
        const child_count: u32 = if (self.children_of.get(category_id)) |children|
            @intCast(children.items.len)
        else
            0;
        const aggregate = self.subtree.get(category_id) orelse return .{
            .link_count = link_count,
            .child_count = child_count,
            .link_count_subtree = link_count,
            .child_count_subtree = 0,
        };
        assert(aggregate.link_subtree >= link_count);
        assert(aggregate.child_subtree >= child_count);
        return .{
            .link_count = link_count,
            .child_count = child_count,
            .link_count_subtree = aggregate.link_subtree,
            .child_count_subtree = aggregate.child_subtree,
        };
    }
};

pub fn compute_category_counts(db: *Directory) !CategoryCounts {
    const allocator = db.allocator;

    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());
    try db.drain_one_memtable(db.memtable_link_by_category(), db.link_by_category());

    var counts = CategoryCounts{
        .allocator = allocator,
        .direct_links = std.AutoHashMap(u64, u32).init(allocator),
        .children_of = std.AutoHashMap(u64, std.ArrayListUnmanaged(u64)).init(allocator),
        .subtree = std.AutoHashMap(u64, SubtreeAggregate).init(allocator),
    };
    errdefer counts.deinit();

    var all_ids: std.ArrayListUnmanaged(u64) = .empty;
    defer all_ids.deinit(allocator);

    try compute_category_counts_scan(db, &counts, &all_ids);

    var stack: std.ArrayListUnmanaged(SubtreeFrame) = .empty;
    defer stack.deinit(allocator);
    var on_path = std.AutoHashMap(u64, void).init(allocator);
    defer on_path.deinit();

    for (all_ids.items) |root| {
        if (counts.subtree.contains(root)) continue;
        try compute_category_counts_subtree(&counts, root, &stack, &on_path);
    }
    for (all_ids.items) |id| assert(counts.subtree.contains(id));

    return counts;
}

fn compute_category_counts_scan(
    db: *Directory,
    counts: *CategoryCounts,
    all_ids: *std.ArrayListUnmanaged(u64),
) !void {
    assert(all_ids.items.len == 0);
    assert(counts.subtree.count() == 0);
    const allocator = counts.allocator;

    {
        const min_key: [16]u8 = @splat(0);
        var iterator = try db.link_by_category().rangeScan(&min_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.key.len < 8) continue;
            const category_id = codec.decodeU64(entry.key[0..8]);
            const slot = try counts.direct_links.getOrPut(category_id);
            if (!slot.found_existing) slot.value_ptr.* = 0;
            slot.value_ptr.* +|= 1;
        }
    }

    {
        const min_key: [16]u8 = @splat(0);
        var iterator = try db.cat_by_parent().rangeScan(&min_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.key.len < 16) continue;
            const parent = codec.decodeU64(entry.key[0..8]);
            const child = codec.decodeU64(entry.key[8..16]);
            const slot = try counts.children_of.getOrPut(parent);
            if (!slot.found_existing) slot.value_ptr.* = .empty;
            try slot.value_ptr.append(allocator, child);
        }
    }

    {
        const min_key = codec.encodeU64(0);
        var iterator = try db.categories_by_id().rangeScan(&min_key, null);
        defer iterator.deinit();
        while (try iterator.next()) |entry| {
            if (entry.value.len < @sizeOf(schema.Category)) continue;
            const record = std.mem.bytesToValue(
                schema.Category,
                entry.value[0..@sizeOf(schema.Category)],
            );
            try all_ids.append(allocator, record.id);
        }
    }
}

const SubtreeFrame = struct { id: u64, expanded: bool };

// An explicit stack replaces recursion; `on_path` breaks a cycle in corrupt parent data and
// `subtree` skips a node that an earlier root already aggregated.
fn compute_category_counts_subtree(
    counts: *CategoryCounts,
    root: u64,
    stack: *std.ArrayListUnmanaged(SubtreeFrame),
    on_path: *std.AutoHashMap(u64, void),
) !void {
    assert(!counts.subtree.contains(root));
    const allocator = counts.allocator;
    stack.clearRetainingCapacity();
    on_path.clearRetainingCapacity();
    try stack.append(allocator, .{ .id = root, .expanded = false });
    while (stack.items.len > 0) {
        const index = stack.items.len - 1;
        const current = stack.items[index];
        if (!current.expanded) {
            stack.items[index].expanded = true;
            if (counts.subtree.contains(current.id)) {
                _ = stack.pop();
                continue;
            }
            try on_path.put(current.id, {});
            if (counts.children_of.get(current.id)) |children| {
                for (children.items) |child| {
                    if (counts.subtree.contains(child)) continue;
                    if (on_path.contains(child)) continue;
                    try stack.append(allocator, .{ .id = child, .expanded = false });
                }
            }
            continue;
        }
        _ = stack.pop();
        _ = on_path.remove(current.id);
        if (counts.subtree.contains(current.id)) continue;
        const aggregate = compute_category_counts_aggregate(counts, current.id);
        try counts.subtree.put(current.id, aggregate);
    }
    assert(on_path.count() == 0);
    assert(counts.subtree.contains(root));
}

fn compute_category_counts_aggregate(counts: *const CategoryCounts, id: u64) SubtreeAggregate {
    const direct: u64 = counts.direct_links.get(id) orelse 0;
    var links_subtree: u64 = direct;
    var children_subtree: u32 = 0;
    if (counts.children_of.get(id)) |children| {
        for (children.items) |child| {
            const child_aggregate = counts.subtree.get(child) orelse SubtreeAggregate{
                .link_subtree = 0,
                .child_subtree = 0,
            };
            links_subtree +%= child_aggregate.link_subtree;
            children_subtree +|= 1 +| child_aggregate.child_subtree;
        }
        assert(children_subtree >= children.items.len);
    }
    assert(links_subtree >= direct);
    return .{ .link_subtree = links_subtree, .child_subtree = children_subtree };
}

pub fn recompute_category_counts(db: *Directory) !void {
    var counts = try compute_category_counts(db);
    defer counts.deinit();

    const now = db.now_seconds();
    var scanned: u64 = 0;
    var rewritten: u64 = 0;
    const min_key = codec.encodeU64(0);
    var iterator = try db.categories_by_id().rangeScan(&min_key, null);
    defer iterator.deinit();
    while (try iterator.next()) |entry| {
        if (entry.value.len < @sizeOf(schema.Category)) continue;
        scanned += 1;
        var category = std.mem.bytesToValue(
            schema.Category,
            entry.value[0..@sizeOf(schema.Category)],
        );
        const want = counts.expected_for(category.id);
        assert(want.link_count_subtree >= want.link_count);
        const have = ExpectedCounts{
            .link_count = category.link_count,
            .child_count = category.child_count,
            .link_count_subtree = category.link_count_subtree,
            .child_count_subtree = category.child_count_subtree,
        };
        if (std.meta.eql(have, want)) continue;

        category.link_count = want.link_count;
        category.child_count = want.child_count;
        category.link_count_subtree = want.link_count_subtree;
        category.child_count_subtree = want.child_count_subtree;
        category.updated_at = now;
        const id_key = codec.encodeU64(category.id);
        try db.memtable_categories_by_id().put(&id_key, std.mem.asBytes(&category));
        rewritten += 1;
    }
    assert(rewritten <= scanned);

    if (rewritten > 0) {
        std.log.scoped(.recover).info(
            "recompute_category_counts: corrected {d} categor{s}",
            .{ rewritten, if (rewritten == 1) "y" else "ies" },
        );
    }
}

// Goal: the rebuild overwrites stored counts with what the indexes say. Method: tamper every
// count of the root in the tree, recompute, then read the whole chain back.
test "recompute_category_counts: rebuilds drifted counts from indexes" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    const b_id = try create_category(db, a_id, .{ .name = "B", .slug = "b", .description = "" });
    _ = try link_operations.create_link(
        db,
        b_id,
        .{ .url = "https://x1.example", .title = "X1", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        b_id,
        .{ .url = "https://x2.example", .title = "X2", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        a_id,
        .{ .url = "https://x3.example", .title = "X3", .description = "" },
    );

    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    {
        var tampered = (try get_category(db, top_id)).?;
        tampered.link_count = 99;
        tampered.child_count = 99;
        tampered.link_count_subtree = 99;
        tampered.child_count_subtree = 99;
        const id_key = codec.encodeU64(top_id);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&tampered));
    }
    try std.testing.expectEqual(@as(u64, 99), (try get_category(db, top_id)).?.link_count_subtree);

    try recompute_category_counts(db);

    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.link_count);
    try std.testing.expectEqual(@as(u32, 1), top.child_count);
    try std.testing.expectEqual(@as(u64, 3), top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), top.child_count_subtree);

    const a = (try get_category(db, a_id)).?;
    try std.testing.expectEqual(@as(u32, 1), a.link_count);
    try std.testing.expectEqual(@as(u32, 1), a.child_count);
    try std.testing.expectEqual(@as(u64, 3), a.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);

    const b = (try get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 2), b.link_count);
    try std.testing.expectEqual(@as(u64, 2), b.link_count_subtree);
}

// Goal: inserting a category bumps `child_count_subtree` on every ancestor. Method: a
// three-level chain, then the two ancestors' counts.
test "create_category cascades child_count_subtree up the chain" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    _ = try create_category(db, a_id, .{ .name = "B", .slug = "b", .description = "" });

    const top = (try get_category(db, top_id)).?;
    const a = (try get_category(db, a_id)).?;
    try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), top.child_count_subtree);
}

// Goal: an insert writes the slug-path, slug-only and token indexes in the same change set.
// Method: create a child, then look each index key up directly.
test "create_category: indexing B+Trees populated by category_inserted ChangeSet" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const child_id = try create_category(
        db,
        top_id,
        .{ .name = "Programming", .slug = "programming", .description = "Code stuff" },
    );

    var value_buffer: [64]u8 = undefined;
    const child_id_key = codec.encodeU64(child_id);

    const slug_path_val = (try db.categories_by_slug_path().search(
        "top/programming",
        &value_buffer,
    )).?;
    try std.testing.expectEqualSlices(u8, &child_id_key, slug_path_val);

    const slug_only_val = (try db.categories_by_slug_only().search("programming", &value_buffer)).?;
    try std.testing.expectEqualSlices(u8, &child_id_key, slug_only_val);

    var key_buffer: [128]u8 = undefined;
    const expected_tokens = [_][]const u8{ "programming", "code", "stuff" };
    for (expected_tokens) |token| {
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &child_id_key);
        const found = try db.categories_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found != null);
    }

    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 1), top.child_count_subtree);
}

// Goal: deleting a category takes it out of its ancestors' subtree counts. Method: create and
// delete a child, then the parent's count.
test "delete_category cascades child_count_subtree decrement" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    try delete_category(db, a_id);

    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.child_count_subtree);
}

// Goal: a delete removes the slug-path, slug-only and token index entries together. Method:
// look each key up before and after the delete.
test "delete_category: indexing B+Trees tombstoned by category_deleted ChangeSet" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const child_id = try create_category(
        db,
        top_id,
        .{ .name = "Programming", .slug = "programming", .description = "Code stuff" },
    );

    var value_buffer: [64]u8 = undefined;
    const child_id_key = codec.encodeU64(child_id);

    try std.testing.expect((try db.categories_by_slug_path().search(
        "top/programming",
        &value_buffer,
    )) != null);
    try std.testing.expect((try db.categories_by_slug_only().search(
        "programming",
        &value_buffer,
    )) != null);

    try delete_category(db, child_id);

    try std.testing.expect((try db.categories_by_slug_path().search(
        "top/programming",
        &value_buffer,
    )) == null);

    try std.testing.expect((try db.categories_by_slug_only().search(
        "programming",
        &value_buffer,
    )) == null);

    var key_buffer: [128]u8 = undefined;
    const expected_tokens = [_][]const u8{ "programming", "code", "stuff" };
    for (expected_tokens) |token| {
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &child_id_key);
        try std.testing.expect((try db.categories_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        )) == null);
    }

    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 0), top.child_count_subtree);
}

// Goal: a text update removes the old name and description tokens and indexes the new ones
// while the slug token stays. Method: rename and redescribe, then probe each token key.
test "update_category (text): name/desc tokens swapped in categories_index_tree" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const child_id = try create_category(
        db,
        top_id,
        .{ .name = "Programming", .slug = "programming", .description = "Code stuff" },
    );

    var value_buffer: [64]u8 = undefined;
    var key_buffer: [128]u8 = undefined;
    const child_id_key = codec.encodeU64(child_id);

    {
        const tokens = [_][]const u8{ "code", "stuff" };
        for (tokens) |token| {
            @memcpy(key_buffer[0..token.len], token);
            @memcpy(key_buffer[token.len..][0..8], &child_id_key);
            const found = try db.categories_index_tree().search(
                key_buffer[0 .. token.len + 8],
                &value_buffer,
            );
            try std.testing.expect(found != null);
        }
    }

    try update_category(db, child_id, "Hacking", "programming", "Network tricks");

    {
        const tokens = [_][]const u8{ "code", "stuff" };
        for (tokens) |token| {
            @memcpy(key_buffer[0..token.len], token);
            @memcpy(key_buffer[token.len..][0..8], &child_id_key);
            const found = try db.categories_index_tree().search(
                key_buffer[0 .. token.len + 8],
                &value_buffer,
            );
            try std.testing.expect(found == null);
        }
    }

    {
        const tokens = [_][]const u8{ "hacking", "network", "tricks" };
        for (tokens) |token| {
            @memcpy(key_buffer[0..token.len], token);
            @memcpy(key_buffer[token.len..][0..8], &child_id_key);
            const found = try db.categories_index_tree().search(
                key_buffer[0 .. token.len + 8],
                &value_buffer,
            );
            try std.testing.expect(found != null);
        }
    }

    {
        const token = "programming";
        @memcpy(key_buffer[0..token.len], token);
        @memcpy(key_buffer[token.len..][0..8], &child_id_key);
        const found = try db.categories_index_tree().search(
            key_buffer[0 .. token.len + 8],
            &value_buffer,
        );
        try std.testing.expect(found != null);
    }

    const category = (try get_category(db, child_id)).?;
    try std.testing.expect(category.name.eql("Hacking"));
    try std.testing.expect(category.slug.eql("programming"));
    try std.testing.expect(category.description.eql("Network tricks"));
}

// Goal: a slug rename moves the category and its descendants to the new path in both slug
// indexes. Method: rename a category with a child, then look the old and new paths up.
test "update_category (slug rename): slug-path B+Trees swapped + descendants rebuilt" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const category_id = try create_category(
        db,
        top_id,
        .{ .name = "Cat", .slug = "old", .description = "" },
    );
    const child_id = try create_category(
        db,
        category_id,
        .{ .name = "Child", .slug = "leaf", .description = "" },
    );

    var value_buffer: [64]u8 = undefined;
    const category_id_key = codec.encodeU64(category_id);
    const child_id_key = codec.encodeU64(child_id);

    try std.testing.expectEqualSlices(
        u8,
        &category_id_key,
        (try db.categories_by_slug_path().search("top/old", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &child_id_key,
        (try db.categories_by_slug_path().search("top/old/leaf", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &category_id_key,
        (try db.categories_by_slug_only().search("old", &value_buffer)).?,
    );

    try update_category(db, category_id, null, "new", null);

    try std.testing.expect((try db.categories_by_slug_path().search(
        "top/old",
        &value_buffer,
    )) == null);
    try std.testing.expectEqualSlices(
        u8,
        &category_id_key,
        (try db.categories_by_slug_path().search("top/new", &value_buffer)).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        &child_id_key,
        (try db.categories_by_slug_path().search("top/new/leaf", &value_buffer)).?,
    );

    try std.testing.expect((try db.categories_by_slug_only().search("old", &value_buffer)) == null);
    try std.testing.expectEqualSlices(
        u8,
        &category_id_key,
        (try db.categories_by_slug_only().search("new", &value_buffer)).?,
    );

    const got = (try get_category(db, category_id)).?;
    try std.testing.expect(got.slug.eql("new"));
}

// Goal: every ancestor, not only the parent, counts a new descendant. Method: a four-level
// chain, then the counts of the three ancestors.
test "deep chain: create_category cascades to all ancestors" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    const b_id = try create_category(db, a_id, .{ .name = "B", .slug = "b", .description = "" });
    _ = try create_category(db, b_id, .{ .name = "C", .slug = "c", .description = "" });

    const top = (try get_category(db, top_id)).?;
    const a = (try get_category(db, a_id)).?;
    const b = (try get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 1), b.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 2), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 3), top.child_count_subtree);
}

// Goal: a move subtracts the subtree from the old chain and adds it to the new one. Method:
// move a category holding a link between two siblings, then both chains and the root.
test "move_category cascades counts in both old and new chains" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    const b_id = try create_category(db, a_id, .{ .name = "B", .slug = "b", .description = "" });
    _ = try link_operations.create_link(
        db,
        b_id,
        .{ .url = "https://x.example", .title = "x", .description = "" },
    );
    const c_id = try create_category(db, top_id, .{ .name = "C", .slug = "c", .description = "" });

    {
        const a = (try get_category(db, a_id)).?;
        try std.testing.expectEqual(@as(u64, 1), a.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
        const c = (try get_category(db, c_id)).?;
        try std.testing.expectEqual(@as(u64, 0), c.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 0), c.child_count_subtree);
    }

    try move_category(db, .{ .id = b_id, .new_parent_id = c_id });

    const a = (try get_category(db, a_id)).?;
    try std.testing.expectEqual(@as(u64, 0), a.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 0), a.child_count_subtree);
    const c = (try get_category(db, c_id)).?;
    try std.testing.expectEqual(@as(u64, 1), c.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), c.child_count_subtree);
    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
}

// Goal: a move carries the whole subtree's link and child counts. Method: move a category
// with a grandchild and two links, then the new parent's and the root's counts.
test "move_category carrying multiple descendants" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const x_id = try create_category(db, top_id, .{ .name = "X", .slug = "x", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    const a1_id = try create_category(db, a_id, .{ .name = "A1", .slug = "a1", .description = "" });
    _ = try create_category(db, a1_id, .{ .name = "A2", .slug = "a2", .description = "" });
    _ = try link_operations.create_link(
        db,
        a1_id,
        .{ .url = "https://1.example", .title = "1", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        a_id,
        .{ .url = "https://2.example", .title = "2", .description = "" },
    );

    {
        const a = (try get_category(db, a_id)).?;
        try std.testing.expectEqual(@as(u64, 2), a.link_count_subtree);
        try std.testing.expectEqual(@as(u32, 2), a.child_count_subtree);
    }

    try move_category(db, .{ .id = a_id, .new_parent_id = x_id });

    const x = (try get_category(db, x_id)).?;
    try std.testing.expectEqual(@as(u64, 2), x.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 3), x.child_count_subtree);
    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u64, 2), top.link_count_subtree);
    try std.testing.expectEqual(@as(u32, 4), top.child_count_subtree);
}

// Goal: moving a category to the parent it already has changes no count. Method: compare the
// root's subtree count before and after.
test "move_category same parent is no-op for counts" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    _ = try link_operations.create_link(
        db,
        a_id,
        .{ .url = "https://x.example", .title = "x", .description = "" },
    );

    const before = (try get_category(db, top_id)).?.link_count_subtree;
    try move_category(db, .{ .id = a_id, .new_parent_id = top_id });
    const after = (try get_category(db, top_id)).?.link_count_subtree;
    try std.testing.expectEqual(before, after);
}

// Goal: a move swaps the parent-child index entry and the slug path. Method: move a child
// between siblings, then probe the old and new keys in both indexes.
test "move_category: cat_by_parent + slug-path B+Trees swapped" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a_id = try create_category(db, top_id, .{ .name = "A", .slug = "a", .description = "" });
    const b_id = try create_category(db, top_id, .{ .name = "B", .slug = "b", .description = "" });
    const c_id = try create_category(db, a_id, .{ .name = "C", .slug = "c", .description = "" });

    {
        const a = (try get_category(db, a_id)).?;
        const b = (try get_category(db, b_id)).?;
        try std.testing.expectEqual(@as(u32, 1), a.child_count_subtree);
        try std.testing.expectEqual(@as(u32, 0), b.child_count_subtree);
    }

    try move_category(db, .{ .id = c_id, .new_parent_id = b_id });

    var value_buffer: [64]u8 = undefined;
    {
        const old_parent_child_key = schema.ParentChildKey.encode(.{ a_id, c_id });
        const old_present = try test_support.is_present(
            db.memtable_cat_by_parent(),
            db.cat_by_parent(),
            &old_parent_child_key,
        );
        try std.testing.expect(!old_present);

        const new_parent_child_key = schema.ParentChildKey.encode(.{ b_id, c_id });
        const new_present = try test_support.is_present(
            db.memtable_cat_by_parent(),
            db.cat_by_parent(),
            &new_parent_child_key,
        );
        try std.testing.expect(new_present);
    }

    const c_id_key = codec.encodeU64(c_id);
    try std.testing.expectEqualSlices(
        u8,
        &c_id_key,
        (try db.categories_by_slug_path().search("top/b/c", &value_buffer)).?,
    );
    try std.testing.expect((try db.categories_by_slug_path().search(
        "top/a/c",
        &value_buffer,
    )) == null);

    const a = (try get_category(db, a_id)).?;
    const b = (try get_category(db, b_id)).?;
    try std.testing.expectEqual(@as(u32, 0), a.child_count_subtree);
    try std.testing.expectEqual(@as(u32, 1), b.child_count_subtree);
    const top = (try get_category(db, top_id)).?;
    try std.testing.expectEqual(@as(u32, 3), top.child_count_subtree);
}

// Goal: a second child with the same slug under one parent is refused. Method: create the
// same slug twice under `top`.
test "two siblings cannot share a slug" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    _ = try create_category(db, top, .{ .name = "Arts", .slug = "arts", .description = "" });
    try std.testing.expectError(
        OperationError.DuplicateSlug,
        create_category(db, top, .{ .name = "Arts Again", .slug = "arts", .description = "" }),
    );
}

// Goal: slug uniqueness is per parent, not global. Method: the same slug under two siblings.
test "the same slug is allowed under different parents" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a = try create_category(db, top, .{ .name = "A", .slug = "a", .description = "" });
    const b = try create_category(db, top, .{ .name = "B", .slug = "b", .description = "" });
    _ = try create_category(db, a, .{ .name = "News", .slug = "news", .description = "" });
    _ = try create_category(db, b, .{ .name = "News", .slug = "news", .description = "" });
}

// Goal: a rename cannot take a sibling's slug, while keeping the own slug is fine. Method:
// rename onto a taken slug, then onto the current one.
test "renaming onto a sibling's slug is refused" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    _ = try create_category(db, top, .{ .name = "Arts", .slug = "arts", .description = "" });
    const music = try create_category(
        db,
        top,
        .{ .name = "Music", .slug = "music", .description = "" },
    );
    try std.testing.expectError(
        OperationError.DuplicateSlug,
        update_category(db, music, null, "arts", null),
    );
    try update_category(db, music, "Music!", "music", null);
}

// Goal: a move cannot land next to a namesake. Method: two `news` categories under different
// parents, then move one under the other's parent.
test "moving a category under a parent that already has its slug is refused" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const a = try create_category(db, top, .{ .name = "A", .slug = "a", .description = "" });
    const b = try create_category(db, top, .{ .name = "B", .slug = "b", .description = "" });
    _ = try create_category(db, a, .{ .name = "News", .slug = "news", .description = "" });
    const b_news = try create_category(
        db,
        b,
        .{ .name = "News", .slug = "news", .description = "" },
    );
    try std.testing.expectError(
        OperationError.DuplicateSlug,
        move_category(db, .{ .id = b_news, .new_parent_id = a }),
    );
}

// Goal: a move that would exceed `depth_max` fails with `PathTooDeep` instead of walking an
// unbounded chain. Method: build a chain of `depth_max` levels, then move under its end.
test "move_category refuses a new parent whose chain is already depth_max deep" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });
    const mover_id = try create_category(
        db,
        top_id,
        .{ .name = "Mover", .slug = "mover", .description = "" },
    );

    var deepest_id = top_id;
    var i: usize = 1;
    while (i <= shared.depth_max) : (i += 1) {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "d{d}", .{i}) catch unreachable;
        deepest_id = try create_category(
            db,
            deepest_id,
            .{ .name = "d", .slug = slug, .description = "" },
        );
    }

    try std.testing.expectError(
        OperationError.PathTooDeep,
        move_category(db, .{ .id = mover_id, .new_parent_id = deepest_id }),
    );
}
