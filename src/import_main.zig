const std = @import("std");
const zigstore = @import("zigstore");
const Directory = @import("directory.zig").Directory;
const operations = @import("operations/operations.zig");
const Config = @import("main.zig").Config;

const log = std.log.scoped(.dmoz_import);

const ROOT_NAME = "Top";
const ROOT_SLUG = "top";

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn dirIsEmpty(io: std.Io, path: []const u8) !bool {
    const d = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return err,
    };
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |_| return false;
    return true;
}

fn readField(parts: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    return parts.next() orelse "";
}

fn readFileAll(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try file.readPositionalAll(io, buf, 0);
    if (n != stat.size) return error.UnexpectedEof;
    return buf;
}

fn importCategories(
    db: *Directory,
    allocator: std.mem.Allocator,
    path_to_id: *std.StringHashMap(u64),
    tsv_path: []const u8,
) !u64 {
    const top_id = try operations.createCategory(db, 0, ROOT_NAME, ROOT_SLUG, "");
    try path_to_id.put(try allocator.dupe(u8, "Top"), top_id);
    log.info("Created root category Top (id={d})", .{top_id});

    const data = try readFileAll(db.io, allocator, tsv_path);
    defer allocator.free(data);

    var n_created: u64 = 0;
    var n_skipped: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var it = std.mem.splitScalar(u8, line, '\t');
        const path = readField(&it);
        const parent_path = readField(&it);
        const name = readField(&it);
        const slug = readField(&it);

        if (path.len == 0 or name.len == 0 or slug.len == 0) {
            n_skipped += 1;
            continue;
        }

        var parent_id: u64 = 0;
        if (parent_path.len != 0) {
            if (path_to_id.get(parent_path)) |id| {
                parent_id = id;
            } else {
                n_skipped += 1;
                continue;
            }
        }

        const id = operations.createCategory(db, parent_id, name, slug, "") catch |err| {
            log.warn("createCategory failed for {s}: {}", .{ path, err });
            n_skipped += 1;
            continue;
        };
        const owned = try allocator.dupe(u8, path);
        try path_to_id.put(owned, id);
        n_created += 1;
        if (n_created % 5000 == 0) log.info("  created {d} categories", .{n_created});
    }
    log.info("Categories: created={d} skipped={d}", .{ n_created, n_skipped });
    return n_created;
}

fn importLinks(
    db: *Directory,
    allocator: std.mem.Allocator,
    path_to_id: *std.StringHashMap(u64),
    tsv_path: []const u8,
) !u64 {
    const data = try readFileAll(db.io, allocator, tsv_path);
    defer allocator.free(data);

    var n_created: u64 = 0;
    var n_skipped: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        var it = std.mem.splitScalar(u8, line, '\t');
        const topic = readField(&it);
        const url = readField(&it);
        const title = readField(&it);
        const desc = readField(&it);

        if (topic.len == 0 or url.len == 0) {
            n_skipped += 1;
            continue;
        }

        const cat_id = path_to_id.get(topic) orelse {
            n_skipped += 1;
            continue;
        };

        _ = operations.createLink(db, cat_id, url, title, desc) catch |err| switch (err) {
            error.DuplicateUrl => {
                n_skipped += 1;
                continue;
            },
            else => {
                log.warn("createLink failed for {s}: {}", .{ url, err });
                n_skipped += 1;
                continue;
            },
        };
        n_created += 1;
        if (n_created % 5000 == 0) {
            const snap = zigstore.snapshot.forceSnapshot(db.store.snapshotHost()) catch |e| blk: {
                log.warn("forceSnapshot failed: {}", .{e});
                break :blk zigstore.SnapshotResult{ .wal_sequence = 0, .duration_ms = 0 };
            };
            log.info("  inserted {d} links (checkpoint wal_seq={d} dur={d}ms)", .{ n_created, snap.wal_sequence, snap.duration_ms });
        }
    }
    log.info("Links: created={d} skipped={d}", .{ n_created, n_skipped });
    return n_created;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const usage = "usage: dmoz_import <data_dir> <cats.tsv> <links.tsv>";
    const data_dir = args.next() orelse fail(usage, .{});
    const cats_path = args.next() orelse fail(usage, .{});
    const links_path = args.next() orelse fail(usage, .{});

    const cwd = std.Io.Dir.cwd();
    const abs_data_dir = cwd.realPathFileAlloc(io, data_dir, allocator) catch |err| switch (err) {
        error.FileNotFound => blk: {
            cwd.createDir(io, data_dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :blk try cwd.realPathFileAlloc(io, data_dir, allocator);
        },
        else => return err,
    };
    defer allocator.free(abs_data_dir);

    if (!try dirIsEmpty(io, abs_data_dir)) {
        fail("data dir {s} is not empty — refusing to import into an existing database", .{abs_data_dir});
    }

    const config = Config{
        .data_dir = abs_data_dir,
        .server = .{
            .cache_size_mb = 64,
            .thread_count = 1,
            .wal_batch_size = 1024,
            .snapshot_interval_s = 3600,
        },
    };

    const db = try Directory.init(io, allocator, config);
    defer db.deinit();
    try db.recover();
    try operations.seedUrlBloom(db);

    var path_to_id = std.StringHashMap(u64).init(allocator);
    defer {
        var it = path_to_id.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        path_to_id.deinit();
    }

    const t0 = db.nowMillis();
    const n_cats = try importCategories(db, allocator, &path_to_id, cats_path);
    const t1 = db.nowMillis();
    const n_links = try importLinks(db, allocator, &path_to_id, links_path);
    const t2 = db.nowMillis();

    log.info("DONE: {d} categories in {d}ms, {d} links in {d}ms", .{ n_cats, t1 - t0, n_links, t2 - t1 });
}
