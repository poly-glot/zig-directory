//! The header upgrade rewrites page 0 of `store.dat` from any older format to the current one
//! before the engine opens it, copying every root and counter by name. The new page goes
//! through a checksummed side file first, so a crash leaves either the old page or a complete
//! new one on disk, never a torn mix of the two.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const directory = @import("directory.zig");

const log = std.log.scoped(.header_upgrade);

const HeaderV5 = zigstore.Engine(directory.schema_v5).Header;
const HeaderV6 = zigstore.Engine(directory.schema_v6).Header;
const HeaderV7 = zigstore.Engine(directory.schema_v7).Header;
const HeaderV8 = zigstore.Engine(directory.schema_v8).Header;
const Header = directory.Store.Header;
const header_page_size = @sizeOf(Header);
const page_invalid: u64 = std.math.maxInt(u32);
const side_file = "store.dat.header-upgrade";
const side_file_len = header_page_size + @sizeOf(u64);

// One step per format bump; `upgrade_header` applies them in order from the version on disk.
const steps = .{
    .{ HeaderV5, HeaderV6, directory.schema_v6.format_version },
    .{ HeaderV6, HeaderV7, directory.schema_v7.format_version },
    .{ HeaderV7, HeaderV8, directory.schema_v8.format_version },
    .{ HeaderV8, Header, directory.schema.format_version },
};

pub const UpgradeError = error{CheckpointJournalPending};

pub fn upgrade_header(io: std.Io, data_dir: []const u8) !void {
    comptime {
        assert(steps.len == directory.schema.format_version - directory.schema_v5.format_version);
        assert(steps[steps.len - 1][2] == directory.schema.format_version);
        for (steps, 0..) |step, index| {
            assert(@sizeOf(step[0]) == header_page_size);
            assert(@sizeOf(step[1]) == header_page_size);
            assert(step[2] == directory.schema_v5.format_version + 1 + index);
            assert(@offsetOf(step[1], "magic") == @offsetOf(HeaderV5, "magic"));
            assert(@offsetOf(step[1], "format_version") == @offsetOf(HeaderV5, "format_version"));
            if (index > 0) assert(step[0] == steps[index - 1][1]);
        }
    }

    var data_directory = std.Io.Dir.openDirAbsolute(io, data_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer data_directory.close(io);

    const store = data_directory.openFile(
        io,
        "store.dat",
        .{ .mode = .read_write },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer store.close(io);

    if (try redo_side_file(io, data_directory, store, data_dir)) return;

    var page: [header_page_size]u8 = undefined;
    if (try store.readPositionalAll(io, &page, 0) < header_page_size) return;
    const found = std.mem.bytesToValue(HeaderV5, &page);
    if (found.magic != directory.schema.magic) return;
    if (found.format_version < directory.schema_v5.format_version) return;
    if (found.format_version >= directory.schema.format_version) return;
    assert(found.format_version >= directory.schema_v5.format_version);
    assert(found.format_version < directory.schema.format_version);

    if (try checkpoint_journal_pending(io, data_directory)) {
        return UpgradeError.CheckpointJournalPending;
    }

    var version = found.format_version;
    inline for (steps) |step| {
        if (version + 1 == step[2]) {
            page = upgraded(step[0], step[1], step[2], &page);
            version = step[2];
        }
    }
    assert(version == directory.schema.format_version);
    assert(version > found.format_version);

    try write_side_file(io, data_directory, data_dir, &page);
    try write_page0(io, store, &page);
    try remove_side_file(io, data_directory, data_dir);
    log.info(
        "store.dat header upgraded from format {d} to {d}",
        .{ found.format_version, version },
    );
}

fn upgraded(
    comptime From: type,
    comptime To: type,
    to_version: u32,
    page: *const [header_page_size]u8,
) [header_page_size]u8 {
    comptime assert(@sizeOf(From) == @sizeOf(To));
    comptime assert(@hasField(To, "_reserved"));
    const old = std.mem.bytesToValue(From, page);
    assert(old.format_version + 1 == to_version);
    var new = std.mem.zeroes(To);
    inline for (@typeInfo(To).@"struct".fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "_reserved")) continue;
        if (comptime @hasField(From, field.name)) {
            comptime assert(field.type == @FieldType(From, field.name));
            comptime assert(@offsetOf(To, field.name) >= @offsetOf(From, field.name));
            @field(new, field.name) = @field(old, field.name);
        } else if (comptime std.mem.endsWith(u8, field.name, "_root")) {
            @field(new, field.name) = page_invalid;
        }
    }
    new.format_version = to_version;
    assert(new.magic == old.magic);
    return std.mem.toBytes(new);
}

fn redo_side_file(
    io: std.Io,
    data_directory: std.Io.Dir,
    store: std.Io.File,
    data_dir: []const u8,
) !bool {
    const side = data_directory.openFile(io, side_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    var buffer: [side_file_len]u8 = undefined;
    const bytes_read = side.readPositionalAll(io, &buffer, 0) catch 0;
    side.close(io);

    var complete = false;
    if (bytes_read == side_file_len) {
        const page_hash = std.mem.readInt(u64, buffer[header_page_size..][0..8], .little);
        complete = page_hash == std.hash.Wyhash.hash(0, buffer[0..header_page_size]);
    }
    if (complete) {
        try write_page0(io, store, buffer[0..header_page_size]);
        log.info("store.dat header upgrade redone from {s}", .{side_file});
    } else {
        log.warn("discarded an incomplete {s}; store.dat page 0 was never touched", .{side_file});
    }
    try remove_side_file(io, data_directory, data_dir);
    return complete;
}

fn write_side_file(
    io: std.Io,
    data_directory: std.Io.Dir,
    data_dir: []const u8,
    page: *const [header_page_size]u8,
) !void {
    var buffer: [side_file_len]u8 = undefined;
    @memcpy(buffer[0..header_page_size], page);
    const page_hash = std.hash.Wyhash.hash(0, page);
    std.mem.writeInt(u64, buffer[header_page_size..][0..8], page_hash, .little);
    assert(std.mem.readInt(u64, buffer[header_page_size..][0..8], .little) == page_hash);

    const side = try data_directory.createFile(io, side_file, .{ .truncate = true });
    defer side.close(io);
    try side.writePositionalAll(io, &buffer, 0);
    try side.sync(io);
    zigstore.snapshot.fsyncDir(data_dir);
}

fn write_page0(io: std.Io, store: std.Io.File, page: []const u8) !void {
    assert(page.len == header_page_size);
    try store.writePositionalAll(io, page, 0);
    try store.sync(io);
}

fn remove_side_file(io: std.Io, data_directory: std.Io.Dir, data_dir: []const u8) !void {
    data_directory.deleteFile(io, side_file) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    zigstore.snapshot.fsyncDir(data_dir);
}

fn checkpoint_journal_pending(io: std.Io, data_directory: std.Io.Dir) !bool {
    const journal = data_directory.openFile(
        io,
        "checkpoint.journal",
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer journal.close(io);
    return (try journal.length(io)) > 0;
}

const testing = std.testing;

fn write_v5_store(io: std.Io, data_directory: std.Io.Dir) !HeaderV5 {
    var v5 = std.mem.zeroes(HeaderV5);
    v5.magic = directory.schema_v5.magic;
    v5.format_version = directory.schema_v5.format_version;
    v5.page_size = header_page_size;
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
    assert(v5.free_list_head < v5.page_count);
    assert(v5.links_by_id_root < v5.page_count);
    assert(v5.slug_path_repair_queue_root < v5.page_count);
    try write_page(io, data_directory, &std.mem.toBytes(v5));
    return v5;
}

fn write_page(
    io: std.Io,
    data_directory: std.Io.Dir,
    page: *const [header_page_size]u8,
) !void {
    const file = try data_directory.createFile(io, "store.dat", .{});
    defer file.close(io);
    try file.writePositionalAll(io, page, 0);
}

fn read_header(io: std.Io, data_directory: std.Io.Dir) !Header {
    const file = try data_directory.openFile(io, "store.dat", .{});
    defer file.close(io);
    var page0: [header_page_size]u8 = undefined;
    const bytes_read = try file.readPositionalAll(io, &page0, 0);
    assert(bytes_read == header_page_size);
    return std.mem.bytesToValue(Header, &page0);
}

fn tmp_path(scratch: *std.testing.TmpDir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try scratch.dir.realPath(testing.io, buffer);
    assert(len > 0);
    assert(len <= buffer.len);
    return buffer[0..len];
}

fn expect_carried_over(v5: *const HeaderV5, upgraded_header: *const Header) !void {
    try testing.expectEqual(directory.schema.format_version, upgraded_header.format_version);
    try testing.expectEqual(v5.page_count, upgraded_header.page_count);
    try testing.expectEqual(v5.free_list_head, upgraded_header.free_list_head);
    try testing.expectEqual(v5.seq, upgraded_header.seq);
    try testing.expectEqual(v5.links_by_id_root, upgraded_header.links_by_id_root);
    try testing.expectEqual(v5.links_by_id_count, upgraded_header.links_by_id_count);
    try testing.expectEqual(
        v5.slug_path_repair_queue_root,
        upgraded_header.slug_path_repair_queue_root,
    );
    try testing.expectEqual(
        v5.slug_path_repair_queue_count,
        upgraded_header.slug_path_repair_queue_count,
    );
    try testing.expectEqual(v5.next_link_id, upgraded_header.next_link_id);
    try testing.expectEqual(v5.links_approved, upgraded_header.links_approved);
    try testing.expectEqual(v5.derived_counts_version, upgraded_header.derived_counts_version);
    try testing.expectEqual(page_invalid, upgraded_header.link_vectors_root);
    try testing.expectEqual(@as(u64, 0), upgraded_header.link_vectors_count);
    try testing.expectEqual(@as(u64, 0), upgraded_header.embedding_model);
    try testing.expectEqual(page_invalid, upgraded_header.link_entities_root);
    try testing.expectEqual(@as(u64, 0), upgraded_header.link_entities_count);
    try testing.expectEqual(page_invalid, upgraded_header.category_vectors_root);
    try testing.expectEqual(@as(u64, 0), upgraded_header.category_vectors_count);
}

// Goal: a v5 page 0 walks every step to the current format with its roots and counters copied
// by name. Method: write a v5 header, upgrade, compare every carried field.
test "header upgrade: v5 to current" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    const v5 = try write_v5_store(testing.io, scratch.dir);
    try upgrade_header(testing.io, try tmp_path(&scratch, &path_buffer));

    const header = try read_header(testing.io, scratch.dir);
    try expect_carried_over(&v5, &header);
    try testing.expectError(error.FileNotFound, scratch.dir.access(testing.io, side_file, .{}));
}

// Goal: a v6 page 0 keeps its vector root and model and gains an empty entities index. Method:
// build a v6 header in memory, write it, upgrade, read it back.
test "header upgrade: v6 keeps vectors" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var v5 = std.mem.zeroes(HeaderV5);
    v5.format_version = directory.schema_v5.format_version;
    const v5_page = std.mem.toBytes(v5);
    const v6_page = upgraded(HeaderV5, HeaderV6, directory.schema_v6.format_version, &v5_page);
    var v6 = std.mem.bytesToValue(HeaderV6, &v6_page);
    v6.magic = directory.schema_v6.magic;
    v6.link_vectors_root = 12;
    v6.link_vectors_count = 91_994;
    v6.embedding_model = 0xB6E5;
    v6.next_link_id = 92_001;
    try write_page(testing.io, scratch.dir, &std.mem.toBytes(v6));

    try upgrade_header(testing.io, try tmp_path(&scratch, &path_buffer));

    const header = try read_header(testing.io, scratch.dir);
    try testing.expectEqual(directory.schema.format_version, header.format_version);
    try testing.expectEqual(@as(u64, 12), header.link_vectors_root);
    try testing.expectEqual(@as(u64, 91_994), header.link_vectors_count);
    try testing.expectEqual(@as(u64, 0xB6E5), header.embedding_model);
    try testing.expectEqual(@as(u64, 92_001), header.next_link_id);
    try testing.expectEqual(page_invalid, header.link_entities_root);
    try testing.expectEqual(page_invalid, header.category_vectors_root);
}

// Goal: a v7 page 0 keeps its entities root and gains an empty category vectors index. Method:
// build a v7 header through the v5 and v6 steps, write it, upgrade, read it back.
test "header upgrade: v7 keeps entities" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var v5 = std.mem.zeroes(HeaderV5);
    v5.format_version = directory.schema_v5.format_version;
    const v5_page = std.mem.toBytes(v5);
    const v6_page = upgraded(HeaderV5, HeaderV6, directory.schema_v6.format_version, &v5_page);
    const v7_page = upgraded(HeaderV6, HeaderV7, directory.schema_v7.format_version, &v6_page);
    var v7 = std.mem.bytesToValue(HeaderV7, &v7_page);
    v7.magic = directory.schema_v7.magic;
    v7.link_vectors_root = 12;
    v7.link_entities_root = 13;
    v7.link_entities_count = 91_995;
    v7.embedding_model = 0xB6E5;
    try write_page(testing.io, scratch.dir, &std.mem.toBytes(v7));

    try upgrade_header(testing.io, try tmp_path(&scratch, &path_buffer));

    const header = try read_header(testing.io, scratch.dir);
    try testing.expectEqual(directory.schema.format_version, header.format_version);
    try testing.expectEqual(@as(u64, 12), header.link_vectors_root);
    try testing.expectEqual(@as(u64, 13), header.link_entities_root);
    try testing.expectEqual(@as(u64, 91_995), header.link_entities_count);
    try testing.expectEqual(@as(u64, 0xB6E5), header.embedding_model);
    try testing.expectEqual(page_invalid, header.category_vectors_root);
    try testing.expectEqual(@as(u64, 0), header.category_vectors_count);
}

// Goal: a v8 page 0 keeps every root and counter, because format 9 only widens link vector
// records. Method: write a v8 header with every vector field set, upgrade, read it back.
test "header upgrade: v8 keeps everything" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;

    var v8 = std.mem.zeroes(HeaderV8);
    v8.magic = directory.schema_v8.magic;
    v8.format_version = directory.schema_v8.format_version;
    v8.link_vectors_root = 12;
    v8.link_vectors_count = 91_994;
    v8.category_vectors_root = 14;
    v8.category_vectors_count = 59_219;
    v8.embedding_model = 0xB6E5;
    try write_page(testing.io, scratch.dir, &std.mem.toBytes(v8));

    try upgrade_header(testing.io, try tmp_path(&scratch, &path_buffer));

    const header = try read_header(testing.io, scratch.dir);
    try testing.expectEqual(directory.schema.format_version, header.format_version);
    try testing.expectEqual(@as(u64, 12), header.link_vectors_root);
    try testing.expectEqual(@as(u64, 91_994), header.link_vectors_count);
    try testing.expectEqual(@as(u64, 14), header.category_vectors_root);
    try testing.expectEqual(@as(u64, 59_219), header.category_vectors_count);
    try testing.expectEqual(@as(u64, 0xB6E5), header.embedding_model);
}

// Goal: the upgrade is idempotent. Method: upgrade a v5 store twice and compare the result once.
test "header upgrade: running it again on a current store changes nothing" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmp_path(&scratch, &path_buffer);

    const v5 = try write_v5_store(testing.io, scratch.dir);
    try upgrade_header(testing.io, path);
    try upgrade_header(testing.io, path);

    const header = try read_header(testing.io, scratch.dir);
    try expect_carried_over(&v5, &header);
}

// Goal: a complete side file wins over a torn page 0. Method: write the side file, half-write
// page 0, upgrade, compare every carried field.
test "header upgrade: a complete side file left by a crash is redone over a torn page 0" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmp_path(&scratch, &path_buffer);

    const v5 = try write_v5_store(testing.io, scratch.dir);
    const v5_page = std.mem.toBytes(v5);
    const v6_page = upgraded(HeaderV5, HeaderV6, directory.schema_v6.format_version, &v5_page);
    const v7_page = upgraded(HeaderV6, HeaderV7, directory.schema_v7.format_version, &v6_page);
    const v8_page = upgraded(HeaderV7, HeaderV8, directory.schema_v8.format_version, &v7_page);
    const current_page = upgraded(HeaderV8, Header, directory.schema.format_version, &v8_page);
    try write_side_file(testing.io, scratch.dir, path, &current_page);
    {
        const file = try scratch.dir.openFile(testing.io, "store.dat", .{ .mode = .read_write });
        defer file.close(testing.io);
        const half_page = current_page[0..@divExact(header_page_size, 2)];
        try file.writePositionalAll(testing.io, half_page, 0);
    }

    try upgrade_header(testing.io, path);

    const header = try read_header(testing.io, scratch.dir);
    try expect_carried_over(&v5, &header);
    try testing.expectError(error.FileNotFound, scratch.dir.access(testing.io, side_file, .{}));
}

// Goal: a short side file is ignored. Method: leave 100 junk bytes as the side file, upgrade.
test "header upgrade: a truncated side file is discarded and the upgrade runs from page 0" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmp_path(&scratch, &path_buffer);

    const v5 = try write_v5_store(testing.io, scratch.dir);
    {
        const side = try scratch.dir.createFile(testing.io, side_file, .{});
        defer side.close(testing.io);
        try side.writePositionalAll(testing.io, &@as([100]u8, @splat(0xAB)), 0);
    }

    try upgrade_header(testing.io, path);

    const header = try read_header(testing.io, scratch.dir);
    try expect_carried_over(&v5, &header);
}

// Goal: a pending checkpoint journal blocks the upgrade. Method: write a journal, expect the
// error and an untouched v5 page 0.
test "header upgrade: refuses while a checkpoint journal could still redo an old page 0" {
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmp_path(&scratch, &path_buffer);

    _ = try write_v5_store(testing.io, scratch.dir);
    {
        const journal = try scratch.dir.createFile(testing.io, "checkpoint.journal", .{});
        defer journal.close(testing.io);
        try journal.writePositionalAll(testing.io, "pending", 0);
    }

    try testing.expectError(
        UpgradeError.CheckpointJournalPending,
        upgrade_header(testing.io, path),
    );
    try testing.expectEqual(
        directory.schema_v5.format_version,
        (try read_header(testing.io, scratch.dir)).format_version,
    );
}

// Goal: an upgraded store is a working store. Method: write a row through a v5 engine, open it
// through the directory, read the row and the counter back.
test "header upgrade: an upgraded v5 store opens and serves its data" {
    const allocator = testing.allocator;
    var scratch = testing.tmpDir(.{});
    defer scratch.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try tmp_path(&scratch, &path_buffer);

    const link_id = blk: {
        const V5Store = zigstore.Engine(directory.schema_v5);
        const store = try V5Store.init(
            testing.io,
            allocator,
            .{ .data_dir = path, .cache_size_mb = 16 },
        );
        defer store.deinit();
        const key = zigstore.codec.encodeU64(5);
        try store.tree("links_by_id").insert(&key, "kept across the upgrade");
        store.counter("next_link_id").* = 6;
        break :blk @as(u64, 5);
    };

    const db = try directory.Directory.open_test_instance(allocator, &scratch);
    defer db.deinit_test_instance();

    var value_buffer: [64]u8 = undefined;
    const key = zigstore.codec.encodeU64(link_id);
    const value = (try db.links_by_id().search(
        &key,
        &value_buffer,
    )) orelse return error.LinkLostInUpgrade;
    try testing.expectEqualStrings("kept across the upgrade", value);
    try testing.expectEqual(@as(u64, 6), db.store.counter("next_link_id").*);
    try testing.expectEqual(@as(u64, 0), db.link_vectors().entryCount());
    try testing.expectEqual(@as(u64, 0), db.link_entities().entryCount());
}
