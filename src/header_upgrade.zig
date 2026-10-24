const std = @import("std");
const zigstore = @import("zigstore");
const directory = @import("directory.zig");

const log = std.log.scoped(.header_upgrade);

const HeaderV5 = zigstore.Engine(directory.schema_v5).Header;
const HeaderV6 = zigstore.Engine(directory.schema_v6).Header;
const HeaderV7 = zigstore.Engine(directory.schema_v7).Header;
const Header = directory.Store.Header;
const PAGE_SIZE = @sizeOf(Header);
const INVALID_PAGE: u64 = std.math.maxInt(u32);
const SIDE_FILE = "store.dat.header-upgrade";
const SIDE_FILE_LEN = PAGE_SIZE + 8;

const steps = .{
    .{ HeaderV5, HeaderV6, directory.schema_v6.format_version },
    .{ HeaderV6, HeaderV7, directory.schema_v7.format_version },
    .{ HeaderV7, Header, directory.schema.format_version },
};

comptime {
    if (@sizeOf(HeaderV5) != PAGE_SIZE or @sizeOf(HeaderV6) != PAGE_SIZE or @sizeOf(HeaderV7) != PAGE_SIZE) @compileError("every header version must fill one page");
}

pub const UpgradeError = error{CheckpointJournalPending};

pub fn upgradeHeader(io: std.Io, data_dir: []const u8) !void {
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

    var page: [PAGE_SIZE]u8 = undefined;
    if (try store.readPositionalAll(io, &page, 0) < PAGE_SIZE) return;
    const found = std.mem.bytesToValue(HeaderV5, &page);
    if (found.magic != directory.schema.magic) return;
    if (found.format_version < directory.schema_v5.format_version or found.format_version >= directory.schema.format_version) return;

    if (try checkpointJournalPending(io, dir)) return UpgradeError.CheckpointJournalPending;

    var version = found.format_version;
    inline for (steps) |step| {
        if (version + 1 == step[2]) {
            page = upgraded(step[0], step[1], step[2], &page);
            version = step[2];
        }
    }

    try writeSideFile(io, dir, data_dir, &page);
    try writePage0(io, store, &page);
    try removeSideFile(io, dir, data_dir);
    log.info("store.dat header upgraded from format {d} to {d}", .{ found.format_version, version });
}

fn upgraded(comptime From: type, comptime To: type, to_version: u32, page: *const [PAGE_SIZE]u8) [PAGE_SIZE]u8 {
    const old = std.mem.bytesToValue(From, page);
    var new = std.mem.zeroes(To);
    inline for (@typeInfo(To).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "_reserved")) continue;
        if (comptime @hasField(From, field.name)) {
            @field(new, field.name) = @field(old, field.name);
        } else if (comptime std.mem.endsWith(u8, field.name, "_root")) {
            @field(new, field.name) = INVALID_PAGE;
        }
    }
    new.format_version = to_version;
    return std.mem.toBytes(new);
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
    try writePage(io, dir, &std.mem.toBytes(v5));
    return v5;
}

fn writePage(io: std.Io, dir: std.Io.Dir, page: *const [PAGE_SIZE]u8) !void {
    const file = try dir.createFile(io, "store.dat", .{});
    defer file.close(io);
    try file.writePositionalAll(io, page, 0);
}

fn readHeader(io: std.Io, dir: std.Io.Dir) !Header {
    const file = try dir.openFile(io, "store.dat", .{});
    defer file.close(io);
    var page0: [PAGE_SIZE]u8 = undefined;
    _ = try file.readPositionalAll(io, &page0, 0);
    return std.mem.bytesToValue(Header, &page0);
}

fn tmpPath(tmp: *std.testing.TmpDir, buf: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(testing.io, buf);
    return buf[0..len];
}

fn expectCarriedOver(v5: HeaderV5, upgraded_header: Header) !void {
    try testing.expectEqual(directory.schema.format_version, upgraded_header.format_version);
    try testing.expectEqual(v5.page_count, upgraded_header.page_count);
    try testing.expectEqual(v5.free_list_head, upgraded_header.free_list_head);
    try testing.expectEqual(v5.seq, upgraded_header.seq);
    try testing.expectEqual(v5.links_by_id_root, upgraded_header.links_by_id_root);
    try testing.expectEqual(v5.links_by_id_count, upgraded_header.links_by_id_count);
    try testing.expectEqual(v5.slug_path_repair_queue_root, upgraded_header.slug_path_repair_queue_root);
    try testing.expectEqual(v5.slug_path_repair_queue_count, upgraded_header.slug_path_repair_queue_count);
    try testing.expectEqual(v5.next_link_id, upgraded_header.next_link_id);
    try testing.expectEqual(v5.links_approved, upgraded_header.links_approved);
    try testing.expectEqual(v5.derived_counts_version, upgraded_header.derived_counts_version);
    try testing.expectEqual(INVALID_PAGE, upgraded_header.link_vectors_root);
    try testing.expectEqual(@as(u64, 0), upgraded_header.link_vectors_count);
    try testing.expectEqual(@as(u64, 0), upgraded_header.embedding_model);
    try testing.expectEqual(INVALID_PAGE, upgraded_header.link_entities_root);
    try testing.expectEqual(@as(u64, 0), upgraded_header.link_entities_count);
    try testing.expectEqual(INVALID_PAGE, upgraded_header.category_vectors_root);
    try testing.expectEqual(@as(u64, 0), upgraded_header.category_vectors_count);
}

test "header upgrade: a v5 page 0 walks every step to the current format, roots and counters copied by name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const v5 = try writeV5Store(testing.io, tmp.dir);
    try upgradeHeader(testing.io, try tmpPath(&tmp, &path_buf));

    try expectCarriedOver(v5, try readHeader(testing.io, tmp.dir));
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, SIDE_FILE, .{}));
}

test "header upgrade: a v6 page 0 keeps its vector root and model and gains an empty entities index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const v5_page = std.mem.toBytes(std.mem.zeroes(HeaderV5));
    const v6_page = upgraded(HeaderV5, HeaderV6, directory.schema_v6.format_version, &v5_page);
    var v6 = std.mem.bytesToValue(HeaderV6, &v6_page);
    v6.magic = directory.schema_v6.magic;
    v6.link_vectors_root = 12;
    v6.link_vectors_count = 91_994;
    v6.embedding_model = 0xB6E5;
    v6.next_link_id = 92_001;
    try writePage(testing.io, tmp.dir, &std.mem.toBytes(v6));

    try upgradeHeader(testing.io, try tmpPath(&tmp, &path_buf));

    const header = try readHeader(testing.io, tmp.dir);
    try testing.expectEqual(directory.schema.format_version, header.format_version);
    try testing.expectEqual(@as(u64, 12), header.link_vectors_root);
    try testing.expectEqual(@as(u64, 91_994), header.link_vectors_count);
    try testing.expectEqual(@as(u64, 0xB6E5), header.embedding_model);
    try testing.expectEqual(@as(u64, 92_001), header.next_link_id);
    try testing.expectEqual(INVALID_PAGE, header.link_entities_root);
    try testing.expectEqual(INVALID_PAGE, header.category_vectors_root);
}

test "header upgrade: a v7 page 0 keeps its entities root and gains an empty category vectors index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const v5_page = std.mem.toBytes(std.mem.zeroes(HeaderV5));
    const v6_page = upgraded(HeaderV5, HeaderV6, directory.schema_v6.format_version, &v5_page);
    const v7_page = upgraded(HeaderV6, HeaderV7, directory.schema_v7.format_version, &v6_page);
    var v7 = std.mem.bytesToValue(HeaderV7, &v7_page);
    v7.magic = directory.schema_v7.magic;
    v7.link_vectors_root = 12;
    v7.link_entities_root = 13;
    v7.link_entities_count = 91_995;
    v7.embedding_model = 0xB6E5;
    try writePage(testing.io, tmp.dir, &std.mem.toBytes(v7));

    try upgradeHeader(testing.io, try tmpPath(&tmp, &path_buf));

    const header = try readHeader(testing.io, tmp.dir);
    try testing.expectEqual(directory.schema.format_version, header.format_version);
    try testing.expectEqual(@as(u64, 12), header.link_vectors_root);
    try testing.expectEqual(@as(u64, 13), header.link_entities_root);
    try testing.expectEqual(@as(u64, 91_995), header.link_entities_count);
    try testing.expectEqual(@as(u64, 0xB6E5), header.embedding_model);
    try testing.expectEqual(INVALID_PAGE, header.category_vectors_root);
    try testing.expectEqual(@as(u64, 0), header.category_vectors_count);
}

test "header upgrade: running it again on a current store changes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    const v5 = try writeV5Store(testing.io, tmp.dir);
    try upgradeHeader(testing.io, path);
    try upgradeHeader(testing.io, path);

    try expectCarriedOver(v5, try readHeader(testing.io, tmp.dir));
}

test "header upgrade: a complete side file left by a crash is redone over a torn page 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmpPath(&tmp, &path_buf);

    const v5 = try writeV5Store(testing.io, tmp.dir);
    const v5_page = std.mem.toBytes(v5);
    const v6_page = upgraded(HeaderV5, HeaderV6, directory.schema_v6.format_version, &v5_page);
    const v7_page = upgraded(HeaderV6, HeaderV7, directory.schema_v7.format_version, &v6_page);
    const current_page = upgraded(HeaderV7, Header, directory.schema.format_version, &v7_page);
    try writeSideFile(testing.io, tmp.dir, path, &current_page);
    {
        const file = try tmp.dir.openFile(testing.io, "store.dat", .{ .mode = .read_write });
        defer file.close(testing.io);
        try file.writePositionalAll(testing.io, current_page[0 .. PAGE_SIZE / 2], 0);
    }

    try upgradeHeader(testing.io, path);

    try expectCarriedOver(v5, try readHeader(testing.io, tmp.dir));
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

    try upgradeHeader(testing.io, path);

    try expectCarriedOver(v5, try readHeader(testing.io, tmp.dir));
}

test "header upgrade: refuses while a checkpoint journal could still redo an old page 0" {
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

    try testing.expectError(UpgradeError.CheckpointJournalPending, upgradeHeader(testing.io, path));
    try testing.expectEqual(directory.schema_v5.format_version, (try readHeader(testing.io, tmp.dir)).format_version);
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
    try testing.expectEqual(@as(u64, 0), db.link_entities().entryCount());
}
