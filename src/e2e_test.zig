//! End-to-end tests that drive a real on-disk directory through the public operations: the
//! category and link lifecycle, paging, search, snapshots, crash recovery, and the durable
//! counters. Every test opens its own temporary store so they can run in any order.

const std = @import("std");
const testing = std.testing;

const Directory = @import("directory.zig").Directory;
const ops = @import("operations/operations.zig");
const zigstore = @import("zigstore");
const schema = @import("schema.zig");

// Goal: a fresh store carries the current format and nothing else. Method: open and read stats.
test "E2E: database init creates valid file" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    try testing.expectEqual(@as(u32, 0x444D4F5A), db.store.header.magic);
    try testing.expectEqual(
        @import("directory.zig").schema.format_version,
        db.store.header.format_version,
    );
    try testing.expectEqual(@as(u64, 0), db.store.header.page_count);

    const stats = db.get_stats();
    try testing.expectEqual(@as(u64, 0), stats.category_count);
    try testing.expectEqual(@as(u64, 0), stats.link_count);
}

// Goal: categories round-trip and a child bumps its parent's count. Method: create two, re-read.
test "E2E: create and retrieve categories" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category1_id = try ops.create_category(
        db,
        0,
        .{ .name = "Computers", .slug = "computers", .description = "Computer-related topics" },
    );
    try testing.expect(category1_id > 0);

    const category1 = (try ops.get_category(db, category1_id)).?;
    try testing.expect(category1.name.eql("Computers"));
    try testing.expect(category1.slug.eql("computers"));
    try testing.expect(category1.description.eql("Computer-related topics"));
    try testing.expectEqual(@as(u64, 0), category1.parent_id);

    const category2_id = try ops.create_category(
        db,
        category1_id,
        .{ .name = "Programming", .slug = "programming", .description = "Programming topics" },
    );
    try testing.expect(category2_id > 0);
    try testing.expect(category2_id != category1_id);

    const category2 = (try ops.get_category(db, category2_id)).?;
    try testing.expectEqual(category1_id, category2.parent_id);

    const updated_parent = (try ops.get_category(db, category1_id)).?;
    try testing.expectEqual(@as(u32, 1), updated_parent.child_count);
}

// Goal: links round-trip and count against their category. Method: create two links, re-read.
test "E2E: create and retrieve links" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try ops.create_category(
        db,
        0,
        .{ .name = "Zig", .slug = "zig", .description = "Zig programming" },
    );

    const link1_id = try ops.create_link(
        db,
        category_id,
        .{ .url = "https://ziglang.org", .title = "Zig Language", .description = "Official site" },
    );
    const link2_id = try ops.create_link(
        db,
        category_id,
        .{
            .url = "https://github.com/ziglang/zig",
            .title = "Zig GitHub",
            .description = "Source code",
        },
    );

    try testing.expect(link1_id > 0);
    try testing.expect(link2_id > 0);
    try testing.expect(link1_id != link2_id);

    const link1 = (try ops.get_link(db, link1_id)).?;
    try testing.expect(link1.url.eql("https://ziglang.org"));
    try testing.expect(link1.title.eql("Zig Language"));
    try testing.expectEqual(category_id, link1.category_id);

    const category = (try ops.get_category(db, category_id)).?;
    try testing.expectEqual(@as(u32, 2), category.link_count);
}

// Goal: an update replaces name, slug and description. Method: create, update, re-read.
test "E2E: update category" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try ops.create_category(
        db,
        0,
        .{ .name = "Original", .slug = "original", .description = "Original description" },
    );
    try ops.update_category(db, category_id, "Updated Name", "updated-slug", "New description");

    const category = (try ops.get_category(db, category_id)).?;
    try testing.expect(category.name.eql("Updated Name"));
    try testing.expect(category.slug.eql("updated-slug"));
    try testing.expect(category.description.eql("New description"));
}

// Goal: an update replaces url, title and description. Method: create, update, re-read.
test "E2E: update link" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try ops.create_category(
        db,
        0,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    const link_id = try ops.create_link(
        db,
        category_id,
        .{ .url = "https://old.com", .title = "Old Title", .description = "Old desc" },
    );
    try ops.update_link(db, link_id, "https://new.com", "New Title", "New desc");

    const link = (try ops.get_link(db, link_id)).?;
    try testing.expect(link.url.eql("https://new.com"));
    try testing.expect(link.title.eql("New Title"));
    try testing.expect(link.description.eql("New desc"));
}

// Goal: a parent cannot be deleted before its subtree is. Method: refuse, then delete bottom-up.
test "E2E: delete category rejects when it has children" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const parent_id = try ops.create_category(
        db,
        0,
        .{ .name = "Parent", .slug = "parent", .description = "" },
    );
    const child_id = try ops.create_category(
        db,
        parent_id,
        .{ .name = "Child", .slug = "child", .description = "" },
    );
    const parent_link = try ops.create_link(
        db,
        parent_id,
        .{ .url = "https://parent.com", .title = "Parent Link", .description = "" },
    );
    const child_link = try ops.create_link(
        db,
        child_id,
        .{ .url = "https://child.com", .title = "Child Link", .description = "" },
    );

    try testing.expectError(
        ops.OperationError.CategoryHasChildren,
        ops.delete_category(db, parent_id),
    );
    try testing.expect((try ops.get_category(db, parent_id)) != null);
    try testing.expect((try ops.get_category(db, child_id)) != null);

    try ops.delete_link(db, child_link);
    try ops.delete_category(db, child_id);
    try ops.delete_link(db, parent_link);
    try ops.delete_category(db, parent_id);

    try testing.expect((try ops.get_category(db, parent_id)) == null);
    try testing.expect((try ops.get_category(db, child_id)) == null);
    try testing.expect((try ops.get_link(db, parent_link)) == null);
    try testing.expect((try ops.get_link(db, child_link)) == null);
}

// Goal: deleting a link decrements its category's count. Method: create, delete, re-read.
test "E2E: delete link updates category count" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try ops.create_category(
        db,
        0,
        .{ .name = "Test", .slug = "test", .description = "" },
    );
    const link_id = try ops.create_link(
        db,
        category_id,
        .{ .url = "https://example.com", .title = "Example", .description = "" },
    );

    var category = (try ops.get_category(db, category_id)).?;
    try testing.expectEqual(@as(u32, 1), category.link_count);

    try ops.delete_link(db, link_id);

    category = (try ops.get_category(db, category_id)).?;
    try testing.expectEqual(@as(u32, 0), category.link_count);
    try testing.expect((try ops.get_link(db, link_id)) == null);
}

// Goal: a move re-parents and refuses a cycle. Method: move C to the root, then A under C,
// then try to move C under B.
test "E2E: move category with circular hierarchy prevention" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const a = try ops.create_category(db, 0, .{ .name = "A", .slug = "a", .description = "" });
    const b = try ops.create_category(db, a, .{ .name = "B", .slug = "b", .description = "" });
    const c = try ops.create_category(db, b, .{ .name = "C", .slug = "c", .description = "" });

    try ops.move_category(db, .{ .id = c, .new_parent_id = 0 });
    const moved_c = (try ops.get_category(db, c)).?;
    try testing.expectEqual(@as(u64, 0), moved_c.parent_id);

    const updated_b = (try ops.get_category(db, b)).?;
    try testing.expectEqual(@as(u32, 0), updated_b.child_count);

    try ops.move_category(db, .{ .id = a, .new_parent_id = c });
    const result = ops.move_category(db, .{ .id = c, .new_parent_id = b });
    try testing.expectError(ops.OperationError.CircularHierarchy, result);
}

// Goal: child paging is offset based and exact. Method: ten children, three pages of five.
test "E2E: list_children with pagination" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const parent = try ops.create_category(
        db,
        0,
        .{ .name = "Parent", .slug = "parent", .description = "" },
    );
    for (0..10) |i| {
        var name_buffer: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "Child_{d}", .{i}) catch unreachable;
        _ = try ops.create_category(db, parent, .{ .name = name, .slug = name, .description = "" });
    }

    var category_buffer: [64]schema.Category = undefined;
    const page1 = try ops.list_children(db, parent, .{ .limit = 5 }, &category_buffer);
    try testing.expectEqual(@as(usize, 5), page1.len);

    const page2 = try ops.list_children(db, parent, .{ .offset = 5, .limit = 5 }, &category_buffer);
    try testing.expectEqual(@as(usize, 5), page2.len);

    const page3 = try ops.list_children(
        db,
        parent,
        .{ .offset = 10, .limit = 5 },
        &category_buffer,
    );
    try testing.expectEqual(@as(usize, 0), page3.len);
}

// Goal: link paging honours offset and limit. Method: eight links, a full page and a slice.
test "E2E: list_links with pagination" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category = try ops.create_category(
        db,
        0,
        .{ .name = "Links", .slug = "links", .description = "" },
    );
    for (0..8) |i| {
        var url_buffer: [64]u8 = undefined;
        var title_buffer: [32]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buffer, "https://example.com/{d}", .{i}) catch unreachable;
        const title = std.fmt.bufPrint(&title_buffer, "Link {d}", .{i}) catch unreachable;
        _ = try ops.create_link(db, category, .{ .url = url, .title = title, .description = "" });
    }

    var link_buffer: [64]schema.Link = undefined;
    const all = (try ops.list_links(db, category, .{ .limit = 64 }, &link_buffer)).items;
    try testing.expectEqual(@as(usize, 8), all.len);

    const partial = (try ops.list_links(
        db,
        category,
        .{ .offset = 3, .limit = 3 },
        &link_buffer,
    )).items;
    try testing.expectEqual(@as(usize, 3), partial.len);
}

// Goal: the path of a category lists its ancestors root first. Method: a three-deep chain.
test "E2E: get_category_path" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const a = try ops.create_category(db, 0, .{ .name = "A", .slug = "a", .description = "" });
    const b = try ops.create_category(db, a, .{ .name = "B", .slug = "b", .description = "" });
    const c = try ops.create_category(db, b, .{ .name = "C", .slug = "c", .description = "" });

    var path_buffer: [16]u64 = undefined;
    const path_result = try ops.get_category_path(db, c, &path_buffer);

    try testing.expectEqual(@as(usize, 3), path_result.len);
    try testing.expectEqual(a, path_result[0]);
    try testing.expectEqual(b, path_result[1]);
    try testing.expectEqual(c, path_result[2]);
}

// Goal: keyword search finds categories and links and misses nonsense. Method: seed and query.
test "E2E: search categories and links" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    _ = try ops.create_category(
        db,
        0,
        .{ .name = "Zig Programming", .slug = "zig", .description = "The Zig language" },
    );
    _ = try ops.create_category(
        db,
        0,
        .{ .name = "Rust Programming", .slug = "rust", .description = "The Rust language" },
    );
    _ = try ops.create_category(
        db,
        0,
        .{ .name = "Science", .slug = "science", .description = "Scientific topics" },
    );

    const zig_category = try ops.create_category(
        db,
        0,
        .{ .name = "Zig Resources", .slug = "zig-res", .description = "" },
    );
    _ = try ops.create_link(
        db,
        zig_category,
        .{ .url = "https://ziglang.org", .title = "Zig Official", .description = "Main Zig site" },
    );
    _ = try ops.create_link(
        db,
        zig_category,
        .{ .url = "https://example.com", .title = "Example Site", .description = "Not about Zig" },
    );

    var category_buffer: [64]schema.Category = undefined;
    const category_results = try ops.search_categories(db, "Zig", 64, &category_buffer);
    try testing.expect(category_results.len >= 2);

    var link_buffer: [64]schema.Link = undefined;
    const link_results = try ops.search_links(db, "Zig", 64, &link_buffer);
    try testing.expect(link_results.len >= 1);

    const empty = try ops.search_categories(db, "xyznonexistent", 64, &category_buffer);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

// Goal: a snapshot records the WAL sequence it covers. Method: create one, load its meta.
test "E2E: snapshot create and load meta" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const data_dir = db.config.data_dir;
    var snapshot_manager = zigstore.snapshot.SnapshotManager.init(db.io, data_dir, 3600);
    try snapshot_manager.createSnapshot(db.store.snapshotHost());

    const meta = (try zigstore.snapshot.SnapshotManager.loadSnapshotMeta(db.io, data_dir)).?;
    try testing.expectEqual(@as(u32, 0x534E4150), meta.magic);
    try testing.expectEqual(db.store.header.seq, meta.wal_sequence);

    const seq = try zigstore.snapshot.SnapshotManager.getWalSequence(db.io, data_dir);
    try testing.expectEqual(meta.wal_sequence, seq);
}

// Goal: rows and id counters survive a clean close. Method: write, checkpoint, close, reopen.
test "E2E: data persists across database close and reopen" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var category_id: u64 = undefined;
    var link_id: u64 = undefined;

    {
        var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
        category_id = try ops.create_category(
            db,
            0,
            .{
                .name = "Persistent",
                .slug = "persistent",
                .description = "This should survive restart",
            },
        );
        link_id = try ops.create_link(
            db,
            category_id,
            .{
                .url = "https://persist.com",
                .title = "Persist Link",
                .description = "Persistent link",
            },
        );
        _ = try db.checkpoint();
        db.deinit_test_instance();
    }

    {
        var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
        defer db.deinit_test_instance();

        const category = try ops.get_category(db, category_id);
        try testing.expect(category != null);
        try testing.expect(category.?.name.eql("Persistent"));
        try testing.expect(category.?.description.eql("This should survive restart"));

        const link = try ops.get_link(db, link_id);
        try testing.expect(link != null);
        try testing.expect(link.?.url.eql("https://persist.com"));
        try testing.expect(link.?.title.eql("Persist Link"));

        try testing.expect(db.next_category_id.load(.monotonic) > category_id);
        try testing.expect(db.next_link_id.load(.monotonic) > link_id);
    }
}

// Goal: a link needs an existing category. Method: create under an id that was never issued.
test "E2E: error handling - create link in nonexistent category" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const result = ops.create_link(
        db,
        99999,
        .{ .url = "https://example.com", .title = "Test", .description = "" },
    );
    try testing.expectError(ops.OperationError.CategoryNotFound, result);
}

// Goal: the whole browse flow works on one store. Method: build a four-deep tree with links,
// then walk the path, list, search and read the stats.
test "E2E: full DMOZ workflow - create hierarchy, browse, search" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    var db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const computers = try ops.create_category(
        db,
        0,
        .{ .name = "Computers", .slug = "Computers", .description = "Computer topics" },
    );
    const programming = try ops.create_category(
        db,
        computers,
        .{ .name = "Programming", .slug = "Programming", .description = "Programming topics" },
    );
    const languages = try ops.create_category(
        db,
        programming,
        .{ .name = "Languages", .slug = "Languages", .description = "Programming languages" },
    );
    const zig_category = try ops.create_category(
        db,
        languages,
        .{ .name = "Zig", .slug = "Zig", .description = "The Zig language" },
    );
    const science = try ops.create_category(
        db,
        0,
        .{ .name = "Science", .slug = "Science", .description = "Scientific topics" },
    );

    _ = try ops.create_link(
        db,
        zig_category,
        .{
            .url = "https://ziglang.org",
            .title = "Zig Official",
            .description = "The official Zig website",
        },
    );
    _ = try ops.create_link(
        db,
        zig_category,
        .{
            .url = "https://github.com/ziglang/zig",
            .title = "Zig GitHub",
            .description = "Source repo",
        },
    );
    _ = try ops.create_link(
        db,
        science,
        .{ .url = "https://arxiv.org", .title = "arXiv", .description = "Preprint server" },
    );

    var path_buffer: [16]u64 = undefined;
    const zig_path = try ops.get_category_path(db, zig_category, &path_buffer);
    try testing.expectEqual(@as(usize, 4), zig_path.len);
    try testing.expectEqual(computers, zig_path[0]);
    try testing.expectEqual(zig_category, zig_path[3]);

    var category_buffer: [64]schema.Category = undefined;
    const roots = try ops.list_children(db, 0, .{ .limit = 64 }, &category_buffer);
    try testing.expect(roots.len >= 2);

    var link_buffer: [64]schema.Link = undefined;
    const zig_links = (try ops.list_links(db, zig_category, .{ .limit = 64 }, &link_buffer)).items;
    try testing.expectEqual(@as(usize, 2), zig_links.len);

    const search_categories = try ops.search_categories(db, "Zig", 64, &category_buffer);
    try testing.expect(search_categories.len >= 1);

    const stats = db.get_stats();
    try testing.expectEqual(@as(u64, 5), stats.category_count);
    try testing.expectEqual(@as(u64, 3), stats.link_count);
}

// Goal: a rename above the inline threshold goes through the repair queue and the worker fixes
// every descendant path. Method: 250 children, rename, one tick, resolve old and new paths.
test "e2e: > threshold rename enqueues task, worker drains, queue empties" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    db.config.rename_inline_threshold = 100;

    const top_id = try ops.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const parent_id = try ops.create_category(
        db,
        top_id,
        .{ .name = "P", .slug = "old", .description = "" },
    );
    for (0..250) |i| {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "c{d}", .{i}) catch unreachable;
        _ = try ops.create_category(
            db,
            parent_id,
            .{ .name = "x", .slug = slug, .description = "" },
        );
    }
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());

    try ops.update_category(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entry_count > 0);

    try std.testing.expect((try ops.resolve_slug_path(db, "top/old/c1")) == null);

    const repair_worker = @import("repair/repair_worker.zig");
    try repair_worker.tick_once(db);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);

    for (0..250) |i| {
        var old_buffer: [64]u8 = undefined;
        var new_buffer: [64]u8 = undefined;
        const old = std.fmt.bufPrint(&old_buffer, "top/old/c{d}", .{i}) catch unreachable;
        const new = std.fmt.bufPrint(&new_buffer, "top/new/c{d}", .{i}) catch unreachable;
        try std.testing.expect((try ops.resolve_slug_path(db, old)) == null);
        try std.testing.expect((try ops.resolve_slug_path(db, new)) != null);
    }
}

// Goal: an acknowledged write survives a crash without a checkpoint. Method: write, drop the
// store without checkpointing, reopen, recover, read the row.
test "C1: an acked commit survives an unclean crash via WAL replay" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const link_id = blk: {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        const top = try ops.create_category(
            first,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const id = try ops.create_link(
            first,
            top,
            .{ .url = "https://crash.example", .title = "Survivor", .description = "" },
        );
        first.deinit_crash_test_instance();
        break :blk id;
    };

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try second.recover();

    const link = (try ops.get_link(second, link_id)) orelse return error.AckedCommitLostOnCrash;
    try testing.expectEqualStrings("https://crash.example", link.url.slice());
    try testing.expectEqualStrings("Survivor", link.title.slice());
}

// Goal: duplicate detection does not depend on the bloom filter. Method: reopen, try before
// the bloom is seeded and again after.
test "C4: a duplicate URL is rejected after a restart, before and after the url bloom is seeded" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        defer first.deinit_test_instance();
        const top = try ops.create_category(
            first,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        _ = try ops.create_link(
            first,
            top,
            .{ .url = "https://dup.example", .title = "First", .description = "" },
        );
    }

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try second.recover();

    const top = (try ops.resolve_slug_path(second, "top")) orelse return error.TopLost;
    try testing.expect(!second.url_bloom_ready.load(.acquire));
    try testing.expectError(
        error.DuplicateUrl,
        ops.create_link(
            second,
            top,
            .{ .url = "https://dup.example", .title = "Second", .description = "" },
        ),
    );

    try ops.seed_url_bloom(second, .full_speed);
    try testing.expect(second.url_bloom_ready.load(.acquire));
    try testing.expectError(
        error.DuplicateUrl,
        ops.create_link(
            second,
            top,
            .{ .url = "https://dup.example", .title = "Third", .description = "" },
        ),
    );
}

// Goal: chunked seeding reaches every link. Method: five links, seed two at a time, probe each.
test "paced seeding of the url bloom in chunks covers every link already on disk" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const urls = [_][]const u8{
        "https://a.example",
        "https://b.example",
        "https://c.example",
        "https://d.example",
        "https://e.example",
    };
    {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        defer first.deinit_test_instance();
        const top = try ops.create_category(
            first,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        for (urls) |url| _ = try ops.create_link(
            first,
            top,
            .{ .url = url, .title = "Seeded", .description = "" },
        );
    }

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try second.recover();

    try ops.seed_url_bloom_in_chunks(second, 2, .yield_half_the_disk);
    try testing.expect(second.url_bloom_ready.load(.acquire));
    for (urls) |url| try testing.expect(second.url_bloom.mayContain(url));
}

// Goal: status counts come back from the checkpoint, not a rescan. Method: write statuses,
// reopen with the counts flagged as checkpointed, compare.
test "a checkpointed store restores its status counts on reopen without recounting" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        defer first.deinit_test_instance();
        try first.recover();
        const top = (try ops.resolve_slug_path(first, "top")) orelse return error.TopLost;
        const pending: schema.LinkStatus = .pending;
        const approved = try ops.create_link_with_options(
            first,
            top,
            .{ .url = "https://approved.example", .title = "A", .description = "" },
            .{ .status = @intFromEnum(pending) },
        );
        _ = try ops.create_link_with_options(
            first,
            top,
            .{ .url = "https://pending.example", .title = "P", .description = "" },
            .{ .status = @intFromEnum(pending) },
        );
        try ops.update_link_status(first, approved, @intFromEnum(schema.LinkStatus.approved));
        try testing.expect(first.derived_counts_checkpointed());
    }

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try testing.expect(second.derived_counts_checkpointed());
    try second.recover();

    const counts = try ops.counts_by_status(second);
    try testing.expectEqual(@as(u64, 1), counts.approved);
    try testing.expectEqual(@as(u64, 1), counts.pending);
    try testing.expectEqual(@as(u64, 0), counts.rejected);
}

// Goal: a store from before derived counts were checkpointed is recounted once. Method: clear
// the version flag and a count, reopen, recover, read the recount.
test "a store without checkpointed derived counts is recounted once on boot" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        defer first.deinit_test_instance();
        try first.recover();
        const top = (try ops.resolve_slug_path(first, "top")) orelse return error.TopLost;
        _ = try ops.create_link_with_options(
            first,
            top,
            .{ .url = "https://legacy.example", .title = "L", .description = "" },
            .{ .status = @intFromEnum(schema.LinkStatus.pending) },
        );
        first.store.counter("derived_counts_version").* = 0;
        first.links_pending_count.store(0, .monotonic);
    }

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try testing.expect(!second.derived_counts_checkpointed());
    try second.recover();

    try testing.expect(second.derived_counts_checkpointed());
    try testing.expectEqual(@as(u64, 1), (try ops.counts_by_status(second)).pending);
}

// Goal: a snapshot makes page 0 durable. Method: snapshot, crash without checkpoint, reopen.
test "H1: a snapshot persists the page-0 header so data survives a later crash" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const child_id, const link_id = blk: {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        const top = try ops.create_category(
            first,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const child = try ops.create_category(
            first,
            top,
            .{ .name = "Child", .slug = "child", .description = "" },
        );
        const link = try ops.create_link(
            first,
            child,
            .{ .url = "https://snap.example", .title = "Snap", .description = "" },
        );
        try first.drain_all_memtables();
        _ = try zigstore.snapshot.forceSnapshot(first.store.snapshotHost());
        first.deinit_crash_test_instance();
        break :blk .{ child, link };
    };

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try second.recover();

    const category = (try ops.get_category(second, child_id)) orelse
        return error.CategoryLostAfterSnapshot;
    try testing.expectEqualStrings("child", category.slug.slice());
    const link = (try ops.get_link(second, link_id)) orelse return error.LinkLostAfterSnapshot;
    try testing.expectEqualStrings("https://snap.example", link.url.slice());
}

// Goal: replay raises the link id counter past every replayed id. Method: crash, recover,
// create another link and compare ids.
test "crash recovery never reissues a link id that a replayed WAL entry already used" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const first_id = blk: {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        const top = try ops.create_category(
            first,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const id = try ops.create_link(
            first,
            top,
            .{ .url = "https://first.example", .title = "First", .description = "" },
        );
        first.deinit_crash_test_instance();
        break :blk id;
    };

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try second.recover();

    const top = (try ops.resolve_slug_path(second, "top")) orelse return error.TopLost;
    const second_id = try ops.create_link(
        second,
        top,
        .{ .url = "https://second.example", .title = "Second", .description = "" },
    );
    try testing.expect(second_id != first_id);

    const link = (try ops.get_link(second, first_id)) orelse return error.ReplayedLinkOverwritten;
    try testing.expectEqualStrings("https://first.example", link.url.slice());
}

// Goal: replay raises the category id counter past every replayed id. Method: crash, recover,
// create another category and compare ids.
test "crash recovery never reissues a category id that a replayed WAL entry already used" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const arts_id = blk: {
        const first = try Directory.open_test_instance(allocator, &temporary_directory);
        const top = try ops.create_category(
            first,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const id = try ops.create_category(
            first,
            top,
            .{ .name = "Arts", .slug = "arts", .description = "" },
        );
        first.deinit_crash_test_instance();
        break :blk id;
    };

    const second = try Directory.open_test_instance(allocator, &temporary_directory);
    defer second.deinit_test_instance();
    try second.recover();

    const top = (try ops.resolve_slug_path(second, "top")) orelse return error.TopLost;
    const music_id = try ops.create_category(
        second,
        top,
        .{ .name = "Music", .slug = "music", .description = "" },
    );
    try testing.expect(music_id != arts_id);

    const arts = (try ops.get_category(second, arts_id)) orelse
        return error.ReplayedCategoryOverwritten;
    try testing.expectEqualStrings("arts", arts.slug.slice());
}
