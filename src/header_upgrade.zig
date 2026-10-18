const std = @import("std");
const zigstore = @import("zigstore");
const directory = @import("directory.zig");

const log = std.log.scoped(.header_upgrade);

const HeaderV5 = zigstore.Engine(directory.schema_v5).Header;
const HeaderV6 = directory.Store.Header;
const PAGE_SIZE = @sizeOf(HeaderV6);
const INVALID_PAGE: u64 = std.math.maxInt(u32);
const SIDE_FILE = "store.dat.v6-header";
const SIDE_FILE_LEN = PAGE_SIZE + 8;

comptime {
    if (@sizeOf(HeaderV5) != PAGE_SIZE) @compileError("v5 and v6 headers must both fill one page");
}

pub const UpgradeError = error{CheckpointJournalPending};

pub fn upgradeToV6(io: std.Io, data_dir: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, data_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    const store = dir.openFile(io, "store.dat", .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer store.close(io);

    if (try redoSideFile(io, dir, store, data_dir)) return;

    var page0: [PAGE_SIZE]u8 = undefined;
    if (try store.readPositionalAll(io, &page0, 0) < PAGE_SIZE) return;
    const v5 = std.mem.bytesToValue(HeaderV5, &page0);
    if (v5.magic != directory.schema_v5.magic or v5.format_version != directory.schema_v5.format_version) return;

    if (try checkpointJournalPending(io, dir)) return UpgradeError.CheckpointJournalPending;

    const v6_bytes = std.mem.toBytes(upgradedHeader(v5));
    try writeSideFile(io, dir, data_dir, &v6_bytes);
    try writePage0(io, store, &v6_bytes);
    try removeSideFile(io, dir, data_dir);
    log.info("store.dat header upgraded from format 5 to 6", .{});
}

fn upgradedHeader(v5: HeaderV5) HeaderV6 {
    var v6 = std.mem.zeroes(HeaderV6);
    inline for (@typeInfo(HeaderV5).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "_reserved")) continue;
        @field(v6, field.name) = @field(v5, field.name);
    }
    v6.format_version = directory.schema.format_version;
    v6.link_vectors_root = INVALID_PAGE;
    v6.link_vectors_count = 0;
    v6.embedding_model = 0;
    return v6;
}

fn redoSideFile(io: std.Io, dir: std.Io.Dir, store: std.Io.File, data_dir: []const u8) !bool {
    const side = dir.openFile(io, SIDE_FILE, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    var buf: [SIDE_FILE_LEN]u8 = undefined;
    const n = side.readPositionalAll(io, &buf, 0) catch 0;
    side.close(io);

    const complete = n == SIDE_FILE_LEN and
        std.mem.readInt(u64, buf[PAGE_SIZE..][0..8], .little) == std.hash.Wyhash.hash(0, buf[0..PAGE_SIZE]);
    if (complete) {
        try writePage0(io, store, buf[0..PAGE_SIZE]);
        log.info("store.dat header upgrade redone from {s}", .{SIDE_FILE});
    } else {
        log.warn("discarded an incomplete {s}; store.dat page 0 was never touched", .{SIDE_FILE});
    }
    try removeSideFile(io, dir, data_dir);
    return complete;
}

fn writeSideFile(io: std.Io, dir: std.Io.Dir, data_dir: []const u8, page: *const [PAGE_SIZE]u8) !void {
    var buf: [SIDE_FILE_LEN]u8 = undefined;
    @memcpy(buf[0..PAGE_SIZE], page);
    std.mem.writeInt(u64, buf[PAGE_SIZE..][0..8], std.hash.Wyhash.hash(0, page), .little);

    const side = try dir.createFile(io, SIDE_FILE, .{ .truncate = true });
    defer side.close(io);
    try side.writePositionalAll(io, &buf, 0);
    try side.sync(io);
    zigstore.snapshot.fsyncDir(data_dir);
}

fn writePage0(io: std.Io, store: std.Io.File, page: []const u8) !void {
    try store.writePositionalAll(io, page, 0);
    try store.sync(io);
}

fn removeSideFile(io: std.Io, dir: std.Io.Dir, data_dir: []const u8) !void {
    dir.deleteFile(io, SIDE_FILE) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    zigstore.snapshot.fsyncDir(data_dir);
}

fn checkpointJournalPending(io: std.Io, dir: std.Io.Dir) !bool {
    const journal = dir.openFile(io, "checkpoint.journal", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer journal.close(io);
    return (try journal.length(io)) > 0;
}

const testing = std.testing;

fn writeV5Store(io: std.Io, dir: std.Io.Dir) !HeaderV5 {
    var v5 = std.mem.zeroes(HeaderV5);
    v5.magic = directory.schema_v5.magic;
    v5.format_version = directory.schema_v5.format_version;
    v5.page_size = PAGE_SIZE;
    v5.page_count = 9;
    v5.free_list_head = 4;
    v5.seq = 77;
    v5.links_by_id_root = 3;
    v5.links_by_id_count = 91_995;
    v5.slug_path_repair_queue_root = 8;
    v5.slug_path_repair_queue_count = 2;
    v5.next_link_id = 92_001;
    v5.links_approved = 91_000;
    v5.derived_counts_version = 1;

    const file = try dir.createFile(io, "store.dat", .{});
    defer file.close(io);
    try file.writePositionalAll(io, &std.mem.toBytes(v5), 0);
    return v5;
}

fn readHeaderV6(io: std.Io, dir: std.Io.Dir) !HeaderV6 {
    const file = try dir.openFile(io, "store.dat", .{});
    defer file.close(io);
    var page0: [PAGE_SIZE]u8 = undefined;
    _ = try file.readPositionalAll(io, &page0, 0);
    return std.mem.bytesToValue(HeaderV6, &page0);
}

fn tmpPath(tmp: *std.testing.TmpDir, buf: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    return buf[0..len];
}

fn expectCarriedOver(v5: HeaderV5, v6: HeaderV6) !void {
    try testing.expectEqual(directory.schema.format_version, v6.format_version);
    try testing.expectEqual(v5.page_count, v6.page_count);
    try testing.expectEqual(v5.free_list_head, v6.free_list_head);
    try testing.expectEqual(v5.seq, v6.seq);
    try testing.expectEqual(v5.links_by_id_root, v6.links_by_id_root);
    try testing.expectEqual(v5.links_by_id_count, v6.links_by_id_count);
    try testing.expectEqual(v5.slug_path_repair_queue_root, v6.slug_path_repair_queue_root);
    try testing.expectEqual(v5.slug_path_repair_queue_count, v6.slug_path_repair_queue_count);
    try testing.expectEqual(v5.next_link_id, v6.next_link_id);
    try testing.expectEqual(v5.links_approved, v6.links_approved);
    try testing.expectEqual(v5.derived_counts_version, v6.derived_counts_version);
    try testing.expectEqual(INVALID_PAGE, v6.link_vectors_root);
    try testing.expectEqual(@as(u64, 0), v6.link_vectors_count);
    try testing.expectEqual(@as(u64, 0), v6.embedding_model);
}

test "header upgrade: a v5 page 0 becomes v6 with every root and counter copied by name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const v5 = try writeV5Store(testing.io, tmp.dir);
    try upgradeToV6(testing.io, try tmpPath(&tmp, &path_buf));

    try expectCarriedOver(v5, try readHeaderV6(testing.io, tmp.dir));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, SIDE_FILE, .{}));
}

test "header upgrade: running it again on a v6 store changes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    const v5 = try writeV5Store(testing.io, tmp.dir);
    try upgradeToV6(testing.io, path);
    try upgradeToV6(testing.io, path);

    try expectCarriedOver(v5, try readHeaderV6(testing.io, tmp.dir));
}

test "header upgrade: a complete side file left by a crash is redone over a torn page 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    const v5 = try writeV5Store(testing.io, tmp.dir);
    const v6_bytes = std.mem.toBytes(upgradedHeader(v5));
    try writeSideFile(testing.io, tmp.dir, path, &v6_bytes);
    {
        const file = try tmp.dir.openFile(testing.io, "store.dat", .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, v6_bytes[0 .. PAGE_SIZE / 2], 0);
    }

    try upgradeToV6(testing.io, path);

    try expectCarriedOver(v5, try readHeaderV6(testing.io, tmp.dir));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, SIDE_FILE, .{}));
}

test "header upgrade: a truncated side file is discarded and the upgrade runs from page 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    const v5 = try writeV5Store(testing.io, tmp.dir);
    {
        const side = try tmp.dir.createFile(testing.io, SIDE_FILE, .{});
        defer side.close(testing.io);
        try side.writePositionalAll(testing.io, &@as([100]u8, @splat(0xAB)), 0);
    }

    try upgradeToV6(testing.io, path);

    try expectCarriedOver(v5, try readHeaderV6(testing.io, tmp.dir));
}

test "header upgrade: refuses while a checkpoint journal could still redo a v5 page 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    _ = try writeV5Store(testing.io, tmp.dir);
    {
        const journal = try tmp.dir.createFile(testing.io, "checkpoint.journal", .{});
        defer journal.close(testing.io);
        try journal.writePositionalAll(testing.io, "pending", 0);
    }

    try testing.expectError(UpgradeError.CheckpointJournalPending, upgradeToV6(testing.io, path));
    const still_v5 = try readHeaderV6(testing.io, tmp.dir);
    try testing.expectEqual(directory.schema_v5.format_version, still_v5.format_version);
}

test "header upgrade: an upgraded v5 store opens and serves its data" {
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    const link_id = blk: {
        const V5Store = zigstore.Engine(directory.schema_v5);
        const store = try V5Store.init(testing.io, allocator, .{ .data_dir = path, .cache_size_mb = 16 });
        defer store.deinit();
        const key = zigstore.codec.encodeU64(5);
        try store.tree("links_by_id").insert(&key, "kept across the upgrade");
        store.counter("next_link_id").* = 6;
        break :blk @as(u64, 5);
    };

    const db = try directory.Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var value_buf: [64]u8 = undefined;
    const key = zigstore.codec.encodeU64(link_id);
    const value = (try db.links_by_id().search(&key, &value_buf)) orelse return error.LinkLostInUpgrade;
    try testing.expectEqualStrings("kept across the upgrade", value);
    try testing.expectEqual(@as(u64, 6), db.store.counter("next_link_id").*);
    try testing.expectEqual(@as(u64, 0), db.link_vectors().entryCount());
}
