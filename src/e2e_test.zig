const std = @import("std");
const testing = std.testing;

const Directory = @import("directory.zig").Directory;
const Config = @import("main.zig").Config;
const ops = @import("operations/operations.zig");
const zigstore = @import("zigstore");
const schema = @import("schema.zig");

fn testConfig(dir: []const u8) Config {
    return Config{
        .data_dir = dir,
        .server = .{
            .port = 0,
            .cache_size_mb = 1,
            .thread_count = 1,
            .snapshot_interval_s = 3600,
            .wal_sync_interval_ms = 50,
            .wal_batch_size = 32,
        },
    };
}

fn initTestDb(dir: []const u8) !*Directory {
    return Directory.init(testing.allocator, testConfig(dir));
}

fn cleanupTestDir(dir: []const u8) void {
    std.fs.deleteTreeAbsolute(dir) catch {};
}

test "E2E: database init creates valid file" {
    const dir = "/tmp/e2e_db_init";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    try testing.expectEqual(@as(u32, 0x444D4F5A), db.store.header.magic);
    try testing.expectEqual(@import("directory.zig").schema.format_version, db.store.header.format_version);
    try testing.expectEqual(@as(u64, 0), db.store.header.page_count);

    const stats = db.getStats();
    try testing.expectEqual(@as(u64, 0), stats.category_count);
    try testing.expectEqual(@as(u64, 0), stats.link_count);
}

test "E2E: create and retrieve categories" {
    const dir = "/tmp/e2e_cat_crud";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const cat1_id = try ops.createCategory(db, 0, "Computers", "computers", "Computer-related topics");
    try testing.expect(cat1_id > 0);

    const cat1 = (try ops.getCategory(db, cat1_id)).?;
    try testing.expect(cat1.name.eql("Computers"));
    try testing.expect(cat1.slug.eql("computers"));
    try testing.expect(cat1.description.eql("Computer-related topics"));
    try testing.expectEqual(@as(u64, 0), cat1.parent_id);

    const cat2_id = try ops.createCategory(db, cat1_id, "Programming", "programming", "Programming topics");
    try testing.expect(cat2_id > 0);
    try testing.expect(cat2_id != cat1_id);

    const cat2 = (try ops.getCategory(db, cat2_id)).?;
    try testing.expectEqual(cat1_id, cat2.parent_id);

    const updated_parent = (try ops.getCategory(db, cat1_id)).?;
    try testing.expectEqual(@as(u32, 1), updated_parent.child_count);
}

test "E2E: create and retrieve links" {
    const dir = "/tmp/e2e_link_crud";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const cat_id = try ops.createCategory(db, 0, "Zig", "zig", "Zig programming");

    const link1_id = try ops.createLink(db, cat_id, "https://ziglang.org", "Zig Language", "Official site");
    const link2_id = try ops.createLink(db, cat_id, "https://github.com/ziglang/zig", "Zig GitHub", "Source code");

    try testing.expect(link1_id > 0);
    try testing.expect(link2_id > 0);
    try testing.expect(link1_id != link2_id);

    const link1 = (try ops.getLink(db, link1_id)).?;
    try testing.expect(link1.url.eql("https://ziglang.org"));
    try testing.expect(link1.title.eql("Zig Language"));
    try testing.expectEqual(cat_id, link1.category_id);

    const cat = (try ops.getCategory(db, cat_id)).?;
    try testing.expectEqual(@as(u32, 2), cat.link_count);
}

test "E2E: update category" {
    const dir = "/tmp/e2e_cat_update";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const cat_id = try ops.createCategory(db, 0, "Original", "original", "Original description");
    try ops.updateCategory(db, cat_id, "Updated Name", "updated-slug", "New description");

    const cat = (try ops.getCategory(db, cat_id)).?;
    try testing.expect(cat.name.eql("Updated Name"));
    try testing.expect(cat.slug.eql("updated-slug"));
    try testing.expect(cat.description.eql("New description"));
}

test "E2E: update link" {
    const dir = "/tmp/e2e_link_update";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const cat_id = try ops.createCategory(db, 0, "Test", "test", "");
    const link_id = try ops.createLink(db, cat_id, "https://old.com", "Old Title", "Old desc");
    try ops.updateLink(db, link_id, "https://new.com", "New Title", "New desc");

    const link = (try ops.getLink(db, link_id)).?;
    try testing.expect(link.url.eql("https://new.com"));
    try testing.expect(link.title.eql("New Title"));
    try testing.expect(link.description.eql("New desc"));
}

test "E2E: delete category rejects when it has children" {
    const dir = "/tmp/e2e_cat_delete";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const parent_id = try ops.createCategory(db, 0, "Parent", "parent", "");
    const child_id = try ops.createCategory(db, parent_id, "Child", "child", "");
    const parent_link = try ops.createLink(db, parent_id, "https://parent.com", "Parent Link", "");
    const child_link = try ops.createLink(db, child_id, "https://child.com", "Child Link", "");

    try testing.expectError(ops.OperationError.CategoryHasChildren, ops.deleteCategory(db, parent_id));
    try testing.expect((try ops.getCategory(db, parent_id)) != null);
    try testing.expect((try ops.getCategory(db, child_id)) != null);

    try ops.deleteLink(db, child_link);
    try ops.deleteCategory(db, child_id);
    try ops.deleteLink(db, parent_link);
    try ops.deleteCategory(db, parent_id);

    try testing.expect((try ops.getCategory(db, parent_id)) == null);
    try testing.expect((try ops.getCategory(db, child_id)) == null);
    try testing.expect((try ops.getLink(db, parent_link)) == null);
    try testing.expect((try ops.getLink(db, child_link)) == null);
}

test "E2E: delete link updates category count" {
    const dir = "/tmp/e2e_link_delete";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const cat_id = try ops.createCategory(db, 0, "Test", "test", "");
    const link_id = try ops.createLink(db, cat_id, "https://example.com", "Example", "");

    var cat = (try ops.getCategory(db, cat_id)).?;
    try testing.expectEqual(@as(u32, 1), cat.link_count);

    try ops.deleteLink(db, link_id);

    cat = (try ops.getCategory(db, cat_id)).?;
    try testing.expectEqual(@as(u32, 0), cat.link_count);
    try testing.expect((try ops.getLink(db, link_id)) == null);
}

test "E2E: move category with circular hierarchy prevention" {
    const dir = "/tmp/e2e_cat_move";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const a = try ops.createCategory(db, 0, "A", "a", "");
    const b = try ops.createCategory(db, a, "B", "b", "");
    const c = try ops.createCategory(db, b, "C", "c", "");

    try ops.moveCategory(db, c, 0);
    const moved_c = (try ops.getCategory(db, c)).?;
    try testing.expectEqual(@as(u64, 0), moved_c.parent_id);

    const updated_b = (try ops.getCategory(db, b)).?;
    try testing.expectEqual(@as(u32, 0), updated_b.child_count);

    try ops.moveCategory(db, a, c);
    const result = ops.moveCategory(db, c, b);
    try testing.expectError(ops.OperationError.CircularHierarchy, result);
}

test "E2E: listChildren with pagination" {
    const dir = "/tmp/e2e_list_children";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const parent = try ops.createCategory(db, 0, "Parent", "parent", "");
    for (0..10) |i| {
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "Child_{d}", .{i}) catch unreachable;
        _ = try ops.createCategory(db, parent, name, name, "");
    }

    var buf: [64]schema.Category = undefined;
    const page1 = try ops.listChildren(db, parent, 0, 5, &buf);
    try testing.expectEqual(@as(usize, 5), page1.len);

    const page2 = try ops.listChildren(db, parent, 5, 5, &buf);
    try testing.expectEqual(@as(usize, 5), page2.len);

    const page3 = try ops.listChildren(db, parent, 10, 5, &buf);
    try testing.expectEqual(@as(usize, 0), page3.len);
}

test "E2E: listLinks with pagination" {
    const dir = "/tmp/e2e_list_links";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const cat = try ops.createCategory(db, 0, "Links", "links", "");
    for (0..8) |i| {
        var url_buf: [64]u8 = undefined;
        var title_buf: [32]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://example.com/{d}", .{i}) catch unreachable;
        const title = std.fmt.bufPrint(&title_buf, "Link {d}", .{i}) catch unreachable;
        _ = try ops.createLink(db, cat, url, title, "");
    }

    var lbuf: [64]schema.Link = undefined;
    const all = (try ops.listLinks(db, cat, 0, 64, &lbuf, null, 0)).items;
    try testing.expectEqual(@as(usize, 8), all.len);

    const partial = (try ops.listLinks(db, cat, 3, 3, &lbuf, null, 0)).items;
    try testing.expectEqual(@as(usize, 3), partial.len);
}

test "E2E: getCategoryPath" {
    const dir = "/tmp/e2e_cat_path";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const a = try ops.createCategory(db, 0, "A", "a", "");
    const b = try ops.createCategory(db, a, "B", "b", "");
    const c = try ops.createCategory(db, b, "C", "c", "");

    var path_buf: [16]u64 = undefined;
    const path_result = try ops.getCategoryPath(db, c, &path_buf);

    try testing.expectEqual(@as(usize, 3), path_result.len);
    try testing.expectEqual(a, path_result[0]);
    try testing.expectEqual(b, path_result[1]);
    try testing.expectEqual(c, path_result[2]);
}

test "E2E: search categories and links" {
    const dir = "/tmp/e2e_search";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    _ = try ops.createCategory(db, 0, "Zig Programming", "zig", "The Zig language");
    _ = try ops.createCategory(db, 0, "Rust Programming", "rust", "The Rust language");
    _ = try ops.createCategory(db, 0, "Science", "science", "Scientific topics");

    const zig_cat = try ops.createCategory(db, 0, "Zig Resources", "zig-res", "");
    _ = try ops.createLink(db, zig_cat, "https://ziglang.org", "Zig Official", "Main Zig site");
    _ = try ops.createLink(db, zig_cat, "https://example.com", "Example Site", "Not about Zig");

    var cat_buf: [64]schema.Category = undefined;
    const cat_results = try ops.searchCategories(db, "Zig", 64, &cat_buf);
    try testing.expect(cat_results.len >= 2);

    var link_buf: [64]schema.Link = undefined;
    const link_results = try ops.searchLinks(db, "Zig", 64, &link_buf);
    try testing.expect(link_results.len >= 1);

    const empty = try ops.searchCategories(db, "xyznonexistent", 64, &cat_buf);
    try testing.expectEqual(@as(usize, 0), empty.len);
}

test "E2E: snapshot create and load meta" {
    const dir = "/tmp/e2e_snapshot";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    std.fs.makeDirAbsolute(dir) catch {};

    var db = try initTestDb(dir);
    defer db.deinit();

    var snap_mgr = zigstore.snapshot.SnapshotManager.init(dir, 3600);
    try snap_mgr.createSnapshot(db.store.snapshotHost(), 42);

    const meta = (try zigstore.snapshot.SnapshotManager.loadSnapshotMeta(dir)).?;
    try testing.expectEqual(@as(u32, 0x534E4150), meta.magic);
    try testing.expectEqual(@as(u64, 42), meta.wal_sequence);

    const seq = try zigstore.snapshot.SnapshotManager.getWalSequence(dir);
    try testing.expectEqual(@as(u64, 42), seq);
}

test "E2E: data persists across database close and reopen" {
    const dir = "/tmp/e2e_persist";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var cat_id: u64 = undefined;
    var link_id: u64 = undefined;

    {
        var db = try initTestDb(dir);
        cat_id = try ops.createCategory(db, 0, "Persistent", "persistent", "This should survive restart");
        link_id = try ops.createLink(db, cat_id, "https://persist.com", "Persist Link", "Persistent link");
        try db.flushHeader();
        try db.store.cache.flushAll();
        db.deinit();
    }

    {
        var db = try initTestDb(dir);
        defer db.deinit();

        const cat = try ops.getCategory(db, cat_id);
        try testing.expect(cat != null);
        try testing.expect(cat.?.name.eql("Persistent"));
        try testing.expect(cat.?.description.eql("This should survive restart"));

        const link = try ops.getLink(db, link_id);
        try testing.expect(link != null);
        try testing.expect(link.?.url.eql("https://persist.com"));
        try testing.expect(link.?.title.eql("Persist Link"));

        try testing.expect(db.next_category_id.load(.monotonic) > cat_id);
        try testing.expect(db.next_link_id.load(.monotonic) > link_id);
    }
}

test "E2E: error handling - create link in nonexistent category" {
    const dir = "/tmp/e2e_error_link_nocat";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const result = ops.createLink(db, 99999, "https://example.com", "Test", "");
    try testing.expectError(ops.OperationError.CategoryNotFound, result);
}

test "E2E: full DMOZ workflow - create hierarchy, browse, search" {
    const dir = "/tmp/e2e_full_workflow";
    cleanupTestDir(dir);
    defer cleanupTestDir(dir);

    var db = try initTestDb(dir);
    defer db.deinit();

    const computers = try ops.createCategory(db, 0, "Computers", "Computers", "Computer topics");
    const programming = try ops.createCategory(db, computers, "Programming", "Programming", "Programming topics");
    const languages = try ops.createCategory(db, programming, "Languages", "Languages", "Programming languages");
    const zig_cat = try ops.createCategory(db, languages, "Zig", "Zig", "The Zig language");
    const science = try ops.createCategory(db, 0, "Science", "Science", "Scientific topics");

    _ = try ops.createLink(db, zig_cat, "https://ziglang.org", "Zig Official", "The official Zig website");
    _ = try ops.createLink(db, zig_cat, "https://github.com/ziglang/zig", "Zig GitHub", "Source repo");
    _ = try ops.createLink(db, science, "https://arxiv.org", "arXiv", "Preprint server");

    var path_buf: [16]u64 = undefined;
    const zig_path = try ops.getCategoryPath(db, zig_cat, &path_buf);
    try testing.expectEqual(@as(usize, 4), zig_path.len);
    try testing.expectEqual(computers, zig_path[0]);
    try testing.expectEqual(zig_cat, zig_path[3]);

    var cat_buf: [64]schema.Category = undefined;
    const roots = try ops.listChildren(db, 0, 0, 64, &cat_buf);
    try testing.expect(roots.len >= 2);

    var link_buf: [64]schema.Link = undefined;
    const zig_links = (try ops.listLinks(db, zig_cat, 0, 64, &link_buf, null, 0)).items;
    try testing.expectEqual(@as(usize, 2), zig_links.len);

    const search_cats = try ops.searchCategories(db, "Zig", 64, &cat_buf);
    try testing.expect(search_cats.len >= 1);

    const stats = db.getStats();
    try testing.expectEqual(@as(u64, 5), stats.category_count);
    try testing.expectEqual(@as(u64, 3), stats.link_count);
}

test "e2e: > threshold rename enqueues task, worker drains, queue empties" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    db.config.rename_inline_threshold = 100;

    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    const parent_id = try ops.createCategory(db, top_id, "P", "old", "");
    var i: u32 = 0;
    while (i < 250) : (i += 1) {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "c{d}", .{i}) catch unreachable;
        _ = try ops.createCategory(db, parent_id, "x", slug, "");
    }
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());

    try ops.updateCategory(db, parent_id, null, "new", null);
    try std.testing.expect(db.slug_path_repair_queue().entry_count > 0);

    try std.testing.expect((try ops.resolveSlugPath(db, "top/old/c1")) == null);

    const repair_worker = @import("repair/repair_worker.zig");
    try repair_worker.tickOnce(db);
    try std.testing.expectEqual(@as(u64, 0), db.slug_path_repair_queue().entry_count);

    var j: u32 = 0;
    while (j < 250) : (j += 1) {
        var old_buf: [64]u8 = undefined;
        var new_buf: [64]u8 = undefined;
        const old = std.fmt.bufPrint(&old_buf, "top/old/c{d}", .{j}) catch unreachable;
        const new = std.fmt.bufPrint(&new_buf, "top/new/c{d}", .{j}) catch unreachable;
        try std.testing.expect((try ops.resolveSlugPath(db, old)) == null);
        try std.testing.expect((try ops.resolveSlugPath(db, new)) != null);
    }
}

test "C1: an acked commit survives an unclean crash via WAL replay" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const link_id = blk: {
        const a = try Directory.openTestInstance(allocator, &tmp);
        const top = try ops.createCategory(a, 0, "Top", "top", "");
        const id = try ops.createLink(a, top, "https://crash.example", "Survivor", "");
        a.deinitCrashTestInstance();
        break :blk id;
    };

    const b = try Directory.openTestInstance(allocator, &tmp);
    defer b.deinitTestInstance();
    try b.recover();

    const link = (try ops.getLink(b, link_id)) orelse return error.AckedCommitLostOnCrash;
    try testing.expectEqualStrings("https://crash.example", link.url.slice());
    try testing.expectEqualStrings("Survivor", link.title.slice());
}

test "C4: a duplicate URL is rejected after a restart (bloom reseeded from disk)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    {
        const a = try Directory.openTestInstance(allocator, &tmp);
        defer a.deinitTestInstance();
        const top = try ops.createCategory(a, 0, "Top", "top", "");
        _ = try ops.createLink(a, top, "https://dup.example", "First", "");
    }

    const b = try Directory.openTestInstance(allocator, &tmp);
    defer b.deinitTestInstance();
    try b.recover();

    const top = (try ops.resolveSlugPath(b, "top")) orelse return error.TopLost;
    const retry = ops.createLink(b, top, "https://dup.example", "Second", "");
    try testing.expectError(error.DuplicateUrl, retry);
}

test "H1: a snapshot persists the page-0 header so data survives a later crash" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const child_id, const link_id = blk: {
        const a = try Directory.openTestInstance(allocator, &tmp);
        const top = try ops.createCategory(a, 0, "Top", "top", "");
        const child = try ops.createCategory(a, top, "Child", "child", "");
        const link = try ops.createLink(a, child, "https://snap.example", "Snap", "");
        a.drainAllMemtables();
        _ = try zigstore.snapshot.forceSnapshot(a.store.snapshotHost());
        a.deinitCrashTestInstance();
        break :blk .{ child, link };
    };

    const b = try Directory.openTestInstance(allocator, &tmp);
    defer b.deinitTestInstance();
    try b.recover();

    const c = (try ops.getCategory(b, child_id)) orelse return error.CategoryLostAfterSnapshot;
    try testing.expectEqualStrings("child", c.slug.slice());
    const l = (try ops.getLink(b, link_id)) orelse return error.LinkLostAfterSnapshot;
    try testing.expectEqualStrings("https://snap.example", l.url.slice());
}
