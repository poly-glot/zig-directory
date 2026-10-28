//! Builds the `ChangeSet` for every write before it reaches the WAL: the record after the
//! change, the ancestor count deltas, the search tokens and the slug paths the apply step swaps.
//! Everything is computed under the write mutex from the store as it is now, so a change set
//! is a complete description that `apply` and WAL replay carry out without looking anything up.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const changeset = @import("../changeset.zig");
const inverted = @import("zigstore").inverted_index;
const category = @import("operations_category.zig");
const slug_operations = @import("operations_slug.zig");
const shared = @import("operations_shared.zig");
const depth_max = shared.depth_max;

// A token needs `MIN_TOKEN_LEN` characters and a separator, so a field of L bytes holds at
// most (L + 1) / (MIN_TOKEN_LEN + 1) tokens; summed over the indexed fields that bounds the
// token list of one record.
const tokens_per_field_divisor = inverted.MIN_TOKEN_LEN + 1;
const category_tokens_max = @divFloor(shared.name_len_max + 1, tokens_per_field_divisor) +
    @divFloor(shared.slug_len_max + 1, tokens_per_field_divisor) +
    @divFloor(shared.category_description_len_max + 1, tokens_per_field_divisor);
const link_tokens_max = @divFloor(shared.title_len_max + 1, tokens_per_field_divisor) +
    @divFloor(shared.url_len_max + 1, tokens_per_field_divisor) +
    @divFloor(shared.link_description_len_max + 1, tokens_per_field_divisor);

const TokenSource = struct { text: []const u8, field: changeset.TokenField };

fn tokenize(sources: []const TokenSource, allocator: std.mem.Allocator) ![]changeset.Token {
    assert(sources.len > 0);
    var out: std.ArrayList(changeset.Token) = .empty;
    var token_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    for (sources) |source| {
        var iterator = inverted.TokenIterator.init(source.text);
        while (iterator.next(&token_buffer)) |token| {
            assert(token.len >= inverted.MIN_TOKEN_LEN);
            assert(token.len <= inverted.MAX_TOKEN_LEN);
            try out.append(allocator, .{
                .text = try allocator.dupe(u8, token),
                .field = source.field,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn category_tokens(
    record: *const schema.Category,
    allocator: std.mem.Allocator,
) ![]changeset.Token {
    const tokens = try tokenize(&.{
        .{ .text = record.name.slice(), .field = .name },
        .{ .text = record.slug.slice(), .field = .slug },
        .{ .text = record.description.slice(), .field = .desc },
    }, allocator);
    assert(tokens.len <= category_tokens_max);
    return tokens;
}

pub fn link_tokens(link: *const schema.Link, allocator: std.mem.Allocator) ![]changeset.Token {
    const tokens = try tokenize(&.{
        .{ .text = link.title.slice(), .field = .title },
        .{ .text = link.url.slice(), .field = .url },
        .{ .text = link.description.slice(), .field = .desc },
    }, allocator);
    assert(tokens.len <= link_tokens_max);
    return tokens;
}

fn collect_ancestor_updates(
    db: *Directory,
    start_id: u64,
    options: struct { link_count_subtree_delta: i64, child_count_subtree_delta: i64 },
    allocator: std.mem.Allocator,
) ![]changeset.AncestorUpdate {
    var updates: std.ArrayList(changeset.AncestorUpdate) = .empty;
    var current_id = start_id;
    var depth: usize = 0;
    while (current_id != 0 and depth < depth_max) : (depth += 1) {
        const ancestor = (try category.get_category(db, current_id)) orelse break;
        try updates.append(allocator, .{
            .cat_id = current_id,
            .link_count_subtree_delta = options.link_count_subtree_delta,
            .child_count_subtree_delta = options.child_count_subtree_delta,
        });
        current_id = ancestor.parent_id;
    }
    assert(updates.items.len <= depth_max);
    if (updates.items.len > 0) assert(updates.items[0].cat_id == start_id);
    return updates.toOwnedSlice(allocator);
}

fn own_slug_path(
    db: *Directory,
    record: *const schema.Category,
    allocator: std.mem.Allocator,
) ![]const u8 {
    assert(record.id != 0);
    var path_buffer: [2048]u8 = undefined;
    const path = (try slug_operations.build_slug_path(db, record.id, &path_buffer)) orelse
        record.slug.slice();
    assert(std.mem.endsWith(u8, path, record.slug.slice()));
    return allocator.dupe(u8, path);
}

fn child_slug_path(
    db: *Directory,
    parent_id: u64,
    slug: []const u8,
    allocator: std.mem.Allocator,
) ![]const u8 {
    assert(slug.len <= shared.slug_len_max);
    var path_buffer: [2048]u8 = undefined;
    const path = (try slug_operations.compose_child_slug_path(
        db,
        parent_id,
        slug,
        &path_buffer,
    )) orelse
        slug;
    assert(std.mem.endsWith(u8, path, slug));
    return allocator.dupe(u8, path);
}

pub fn compute_category_insert_change_set(
    db: *Directory,
    inserted: *const schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(inserted.id != 0);
    const ancestor_updates = try collect_ancestor_updates(
        db,
        inserted.parent_id,
        .{ .link_count_subtree_delta = 0, .child_count_subtree_delta = 1 },
        allocator,
    );
    if (inserted.parent_id != 0) assert(ancestor_updates.len > 0);
    const tokens = try category_tokens(inserted, allocator);

    const slug = inserted.slug.slice();
    const slug_path = try child_slug_path(db, inserted.parent_id, slug, allocator);
    assert(std.mem.endsWith(u8, slug_path, slug));

    // The slug-only index points a bare slug at its shallowest category, so a deeper namesake
    // must leave the existing entry alone.
    const new_depth = std.mem.count(u8, slug_path, "/");
    var existing_id_buffer: [16]u8 = undefined;
    const is_shallowest_for_slug: bool = blk: {
        const existing = (try db.categories_by_slug_only().search(
            slug,
            &existing_id_buffer,
        )) orelse {
            break :blk true;
        };
        if (existing.len != 8) break :blk true;
        const existing_id = codec.decodeU64(existing);
        var existing_path_buffer: [2048]u8 = undefined;
        const existing_path = (try slug_operations.build_slug_path(
            db,
            existing_id,
            &existing_path_buffer,
        )) orelse {
            break :blk true;
        };
        const existing_depth = std.mem.count(u8, existing_path, "/");
        break :blk new_depth < existing_depth;
    };

    return changeset.ChangeSet{ .category_inserted = .{
        .cat = inserted.*,
        .ancestor_updates = ancestor_updates,
        .tokens = tokens,
        .slug_path = slug_path,
        .is_shallowest_for_slug = is_shallowest_for_slug,
    } };
}

pub fn compute_category_text_update_change_set(
    old_category: *const schema.Category,
    new_category: *const schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(new_category.id == old_category.id);
    assert(new_category.parent_id == old_category.parent_id);
    assert(new_category.slug.eql(old_category.slug.slice()));
    return changeset.ChangeSet{ .category_text_updated = .{
        .old_cat = old_category.*,
        .new_cat = new_category.*,
        .old_tokens = try category_tokens(old_category, allocator),
        .new_tokens = try category_tokens(new_category, allocator),
    } };
}

const DescendantSwaps = struct {
    swaps: []changeset.SlugPathSwap,
    above_threshold: bool,
    enqueue: changeset.EnqueueOnApply,
};

const descendant_children_per_page: u32 = 256;

// Below `rename_inline_threshold` descendants the path swaps ride in the change set; above it
// the apply step enqueues a repair task and the worker rewrites the subtree in chunks. A child
// whose path cannot be composed is left out together with its own descendants.
fn collect_descendant_swaps(
    db: *Directory,
    root_id: u64,
    old_path: []const u8,
    new_path: []const u8,
    op: schema.RepairOp,
    allocator: std.mem.Allocator,
) !DescendantSwaps {
    const threshold = db.config.rename_inline_threshold;
    var swaps: std.ArrayList(changeset.SlugPathSwap) = .empty;
    var above_threshold = false;
    var descendant_count: u32 = 0;

    var stack: std.ArrayList(u64) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, root_id);

    const children_buffer = try allocator.alloc(schema.Category, descendant_children_per_page);
    const pages_max = @divFloor(threshold, descendant_children_per_page) + 2;
    var popped: u32 = 0;
    walk: while (stack.pop()) |current_id| {
        popped += 1;
        assert(popped <= threshold +| 2);
        var offset: u32 = 0;
        for (0..pages_max) |_| {
            const children = try category.list_children(
                db,
                current_id,
                .{ .offset = offset, .limit = descendant_children_per_page },
                children_buffer,
            );
            assert(children.len <= descendant_children_per_page);
            if (children.len == 0) break;
            for (children) |child| {
                descendant_count += 1;
                if (descendant_count > threshold) {
                    above_threshold = true;
                    break :walk;
                }
                const swapped = try collect_descendant_swaps_child(
                    db,
                    .{ .root_id = root_id, .child_id = child.id },
                    old_path,
                    new_path,
                    &swaps,
                    allocator,
                );
                if (swapped) try stack.append(allocator, child.id);
            }
            offset += @intCast(children.len);
            if (children.len < descendant_children_per_page) break;
        }
    }
    assert(swaps.items.len <= descendant_count);

    var enqueue: changeset.EnqueueOnApply = .{};
    if (above_threshold) {
        swaps.clearAndFree(allocator);
        enqueue = .{
            .seq = db.next_repair_seq.fetchAdd(1, .monotonic),
            .op = op,
            .old_slug_prefix = try allocator.dupe(u8, old_path),
            .created_at = db.now_millis(),
        };
        assert(enqueue.seq != 0);
    }
    if (above_threshold) assert(swaps.items.len == 0);

    return .{
        .swaps = try swaps.toOwnedSlice(allocator),
        .above_threshold = above_threshold,
        .enqueue = enqueue,
    };
}

fn collect_descendant_swaps_child(
    db: *Directory,
    ids: struct { root_id: u64, child_id: u64 },
    old_path: []const u8,
    new_path: []const u8,
    swaps: *std.ArrayList(changeset.SlugPathSwap),
    allocator: std.mem.Allocator,
) !bool {
    assert(ids.child_id != 0);
    var old_buffer: [2048]u8 = undefined;
    const descendant_old_path = slug_operations.compose_old_descendant_path(
        db,
        old_path,
        .{ .root_id = ids.root_id, .descendant_id = ids.child_id },
        &old_buffer,
    ) catch return false;
    var new_buffer: [2048]u8 = undefined;
    const descendant_new_path = slug_operations.compose_old_descendant_path(
        db,
        new_path,
        .{ .root_id = ids.root_id, .descendant_id = ids.child_id },
        &new_buffer,
    ) catch return false;
    assert(std.mem.startsWith(u8, descendant_old_path, old_path));
    assert(std.mem.startsWith(u8, descendant_new_path, new_path));
    try swaps.append(allocator, .{
        .old_path = try allocator.dupe(u8, descendant_old_path),
        .new_path = try allocator.dupe(u8, descendant_new_path),
        .cat_id = ids.child_id,
    });
    return true;
}

pub fn compute_category_rename_change_set(
    db: *Directory,
    old_category: *const schema.Category,
    new_category: *const schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(new_category.id == old_category.id);
    assert(new_category.parent_id == old_category.parent_id);
    assert(!new_category.slug.eql(old_category.slug.slice()));
    const old_path = try own_slug_path(db, old_category, allocator);
    const new_path = try child_slug_path(
        db,
        new_category.parent_id,
        new_category.slug.slice(),
        allocator,
    );

    const descendants = try collect_descendant_swaps(
        db,
        new_category.id,
        old_path,
        new_path,
        .renamed_slug,
        allocator,
    );

    return changeset.ChangeSet{ .category_renamed = .{
        .old_cat = old_category.*,
        .new_cat = new_category.*,
        .old_slug_path = old_path,
        .new_slug_path = new_path,
        .descendant_swaps = descendants.swaps,
        .above_threshold = descendants.above_threshold,
        .enqueue = descendants.enqueue,
    } };
}

pub fn compute_category_delete_change_set(
    db: *Directory,
    deleted: *const schema.Category,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(deleted.id != 0);
    const link_delta: i64 = @intCast(deleted.link_count_subtree);
    const ancestor_updates = try collect_ancestor_updates(
        db,
        deleted.parent_id,
        .{ .link_count_subtree_delta = -link_delta, .child_count_subtree_delta = -1 },
        allocator,
    );
    for (ancestor_updates) |update| assert(update.link_count_subtree_delta <= 0);
    return changeset.ChangeSet{ .category_deleted = .{
        .cat = deleted.*,
        .ancestor_updates = ancestor_updates,
        .tokens = try category_tokens(deleted, allocator),
        .slug_path = try own_slug_path(db, deleted, allocator),
    } };
}

pub fn compute_category_move_change_set(
    db: *Directory,
    before: *const schema.Category,
    new_parent_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(new_parent_id != before.id);
    assert(new_parent_id != before.parent_id);
    const old_parent_id = before.parent_id;

    var after = before.*;
    after.parent_id = new_parent_id;
    after.updated_at = db.now_seconds();

    const link_subtree_delta: u64 = before.link_count_subtree;
    const child_subtree_delta: u32 = before.child_count_subtree + 1;
    const link_delta: i64 = @intCast(link_subtree_delta);
    const child_delta: i64 = @intCast(child_subtree_delta);

    const old_chain = try collect_ancestor_updates(
        db,
        old_parent_id,
        .{ .link_count_subtree_delta = -link_delta, .child_count_subtree_delta = -child_delta },
        allocator,
    );
    const new_chain = try collect_ancestor_updates(
        db,
        new_parent_id,
        .{ .link_count_subtree_delta = link_delta, .child_count_subtree_delta = child_delta },
        allocator,
    );
    // The caller refused a cycle, so the moved category never counts itself as an ancestor.
    for (new_chain) |update| assert(update.cat_id != before.id);
    for (new_chain) |update| assert(update.child_count_subtree_delta > 0);

    const old_slug_path = try own_slug_path(db, before, allocator);
    const new_slug_path = try child_slug_path(db, new_parent_id, before.slug.slice(), allocator);

    const descendants = try collect_descendant_swaps(
        db,
        before.id,
        old_slug_path,
        new_slug_path,
        .moved_parent,
        allocator,
    );

    return changeset.ChangeSet{ .category_moved = .{
        .cat = after,
        .old_parent_id = old_parent_id,
        .new_parent_id = new_parent_id,
        .old_chain_updates = old_chain,
        .new_chain_updates = new_chain,
        .old_slug_path = old_slug_path,
        .new_slug_path = new_slug_path,
        .link_subtree_delta = link_subtree_delta,
        .child_subtree_delta = child_subtree_delta,
        .descendant_swaps = descendants.swaps,
        .above_threshold = descendants.above_threshold,
        .enqueue = descendants.enqueue,
    } };
}

pub fn compute_link_insert_change_set(
    db: *Directory,
    link: *const schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(link.id != 0);
    const ancestor_updates = try collect_ancestor_updates(
        db,
        link.category_id,
        .{ .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        allocator,
    );
    if (link.category_id != 0) assert(ancestor_updates.len > 0);
    return changeset.ChangeSet{ .link_inserted = .{
        .link = link.*,
        .ancestor_updates = ancestor_updates,
        .tokens = try link_tokens(link, allocator),
    } };
}

pub fn compute_link_text_update_change_set(
    old_link: *const schema.Link,
    new_link: *const schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(new_link.id == old_link.id);
    assert(new_link.category_id == old_link.category_id);
    return changeset.ChangeSet{ .link_text_updated = .{
        .old_link = old_link.*,
        .new_link = new_link.*,
        .old_tokens = try link_tokens(old_link, allocator),
        .new_tokens = try link_tokens(new_link, allocator),
    } };
}

pub fn compute_link_delete_change_set(
    db: *Directory,
    link: *const schema.Link,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(link.id != 0);
    const ancestor_updates = try collect_ancestor_updates(
        db,
        link.category_id,
        .{ .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
        allocator,
    );
    assert(ancestor_updates.len <= depth_max);
    return changeset.ChangeSet{ .link_deleted = .{
        .link = link.*,
        .ancestor_updates = ancestor_updates,
        .tokens = try link_tokens(link, allocator),
    } };
}

pub fn compute_link_recat_change_set(
    db: *Directory,
    link: *const schema.Link,
    new_category_id: u64,
    allocator: std.mem.Allocator,
) !changeset.ChangeSet {
    assert(new_category_id != 0);
    assert(new_category_id != link.category_id);
    const old_category_id = link.category_id;

    var link_post_move = link.*;
    link_post_move.category_id = new_category_id;
    link_post_move.updated_at = db.now_seconds();

    const new_chain_updates = try collect_ancestor_updates(
        db,
        new_category_id,
        .{ .link_count_subtree_delta = 1, .child_count_subtree_delta = 0 },
        allocator,
    );
    assert(new_chain_updates.len > 0);

    return changeset.ChangeSet{ .link_recategorized = .{
        .link = link_post_move,
        .old_category_id = old_category_id,
        .old_chain_updates = try collect_ancestor_updates(
            db,
            old_category_id,
            .{ .link_count_subtree_delta = -1, .child_count_subtree_delta = 0 },
            allocator,
        ),
        .new_chain_updates = new_chain_updates,
    } };
}

// Goal: a rename with few descendants carries their path swaps inline and enqueues nothing.
// Method: two children under the renamed category, then the change set's swap list.
test "compute_category_rename_change_set: <= threshold populates descendant_swaps" {
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
    const parent_id = try category.create_category(
        db,
        top_id,
        .{ .name = "Parent", .slug = "old", .description = "" },
    );
    _ = try category.create_category(
        db,
        parent_id,
        .{ .name = "C1", .slug = "c1", .description = "" },
    );
    _ = try category.create_category(
        db,
        parent_id,
        .{ .name = "C2", .slug = "c2", .description = "" },
    );
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const old_category = (try category.get_category(db, parent_id)).?;
    var new_category = old_category;
    new_category.slug = codec.FixedString(128).fromSlice("new");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const change_set = try compute_category_rename_change_set(
        db,
        &old_category,
        &new_category,
        arena.allocator(),
    );
    const effect = change_set.category_renamed;
    try std.testing.expectEqual(@as(usize, 2), effect.descendant_swaps.len);
    try std.testing.expect(!effect.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), effect.enqueue.seq);
}

// Goal: a rename with more descendants than the inline threshold carries no swaps and enqueues
// a repair task for the old prefix. Method: threshold 5, seven children, then the effect.
test "compute_category_rename_change_set: > threshold sets above_threshold + populates enqueue" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 5;

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent_id = try category.create_category(
        db,
        top_id,
        .{ .name = "Parent", .slug = "old", .description = "" },
    );
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "c{d}", .{i}) catch unreachable;
        _ = try category.create_category(
            db,
            parent_id,
            .{ .name = "x", .slug = slug, .description = "" },
        );
    }
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const old_category = (try category.get_category(db, parent_id)).?;
    var new_category = old_category;
    new_category.slug = codec.FixedString(128).fromSlice("new");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const change_set = try compute_category_rename_change_set(
        db,
        &old_category,
        &new_category,
        arena.allocator(),
    );
    const effect = change_set.category_renamed;
    try std.testing.expect(effect.above_threshold);
    try std.testing.expectEqual(@as(usize, 0), effect.descendant_swaps.len);
    try std.testing.expect(effect.enqueue.seq != 0);
    try std.testing.expectEqualStrings("top/old", effect.enqueue.old_slug_prefix);
}

// Goal: the descendant walk stops at `depth_max` levels without failing the rename. Method: a
// chain of 70 attempted levels, of which creation refuses all past 64, then the swaps.
test "compute_category_rename_change_set: descendant walk silently caps at depth 64" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 100;

    const top_id = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    var deepest_id = top_id;
    var built: u32 = 0;
    var i: u32 = 1;
    while (i <= 70) : (i += 1) {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "c{d}", .{i}) catch unreachable;
        const child_id = category.create_category(
            db,
            deepest_id,
            .{ .name = "x", .slug = slug, .description = "" },
        ) catch break;
        deepest_id = child_id;
        built += 1;
    }
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    try std.testing.expectEqual(@as(u32, 64), built);

    const old_top = (try category.get_category(db, top_id)).?;
    var new_top = old_top;
    new_top.slug = codec.FixedString(128).fromSlice("topnew");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const change_set = try compute_category_rename_change_set(
        db,
        &old_top,
        &new_top,
        arena.allocator(),
    );
    const effect = change_set.category_renamed;

    try std.testing.expect(!effect.above_threshold);
    try std.testing.expectEqual(@as(u64, 0), effect.enqueue.seq);

    try std.testing.expectEqual(@as(usize, built), effect.descendant_swaps.len);

    var deepest_swap_found = false;
    for (effect.descendant_swaps) |swap| {
        if (swap.cat_id == deepest_id) {
            deepest_swap_found = true;
            try std.testing.expect(std.mem.startsWith(u8, swap.old_path, "top/"));
            try std.testing.expect(std.mem.startsWith(u8, swap.new_path, "topnew/"));
        }
    }
    try std.testing.expect(deepest_swap_found);
}

// Goal: a move with few descendants carries their path swaps inline. Method: a category with
// two children moved under a sibling, then the swap list.
test "compute_category_move_change_set: <= threshold populates descendant_swaps" {
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
        top_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );
    _ = try category.create_category(db, a_id, .{ .name = "X", .slug = "x", .description = "" });
    _ = try category.create_category(db, a_id, .{ .name = "Y", .slug = "y", .description = "" });
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const category_a = (try category.get_category(db, a_id)).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const change_set = try compute_category_move_change_set(
        db,
        &category_a,
        b_id,
        arena.allocator(),
    );
    const effect = change_set.category_moved;
    try std.testing.expectEqual(@as(usize, 2), effect.descendant_swaps.len);
    try std.testing.expect(!effect.above_threshold);
}

// Goal: a move with more descendants than the inline threshold enqueues a `moved_parent`
// repair task for the old prefix instead of inline swaps. Method: threshold 3, five children.
test "compute_category_move_change_set: > threshold sets above_threshold + populates enqueue" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 3;

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
        top_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "x{d}", .{i}) catch unreachable;
        _ = try category.create_category(
            db,
            a_id,
            .{ .name = "x", .slug = slug, .description = "" },
        );
    }
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    const category_a = (try category.get_category(db, a_id)).?;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const change_set = try compute_category_move_change_set(
        db,
        &category_a,
        b_id,
        arena.allocator(),
    );
    const effect = change_set.category_moved;
    try std.testing.expect(effect.above_threshold);
    try std.testing.expectEqual(@as(usize, 0), effect.descendant_swaps.len);
    try std.testing.expect(effect.enqueue.seq != 0);
    try std.testing.expectEqualStrings("top/a", effect.enqueue.old_slug_prefix);
    try std.testing.expectEqual(schema.RepairOp.moved_parent, effect.enqueue.op);
}
