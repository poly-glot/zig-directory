//! The derived-index snapshot `derived.snap`: the facts index, the URL bloom and both vector
//! indexes as they stood at one checkpoint, so a boot restores them in the time it takes to
//! read the file instead of rebuilding them from the store. Measured on the production pod on
//! 2026-10-28, those rebuilds read 21 GB from a block volume capped near 24 MB/s: fifteen
//! minutes with search hanging. The file carries the checkpoint's WAL sequence and is restored
//! only while the superblock still carries that sequence, so the WAL tail recovery replays
//! through `apply` is exactly what the restored indexes are missing. Every section is a
//! consistent cut taken under its index's shared lock; a stale, torn or foreign file is logged
//! and the index in question loads by scanning, as it did before the snapshot existed.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const Directory = @import("directory.zig").Directory;
const Store = @import("directory.zig").Store;

const log = std.log.scoped(.derived_snapshot);

pub const file_name = "derived.snap";
const temporary_file_name = "derived.snap.tmp";
const magic: [8]u8 = "DMOZSNAP".*;
pub const format_version: u32 = 1;

// The file streams through this buffer in both directions; every record is far smaller, so it
// bounds the syscall count without a large frame on the checkpoint worker's stack.
const stream_buffer_bytes: usize = 256 * 1024;

// A restored bloom filter keeps the ten bits per link the seeder sizes it with; below that it
// is rebuilt. The upper bound rejects a corrupt length before it reaches the allocator.
const url_bloom_bits_per_link: u64 = 10;
const url_bloom_bits_min: u64 = 1024;
const url_bloom_bits_max: u64 = 1 << 40;

/// Sections in file order. The link vectors go last: they are the one section bound to the
/// vector model file, so a model change stops the reader after everything else has loaded.
pub const Section = enum(u32) {
    facts = 1,
    url_bloom = 2,
    category_vectors = 3,
    link_vectors = 4,
};

const section_order = [_]Section{ .facts, .url_bloom, .category_vectors, .link_vectors };

const Header = extern struct {
    magic: [8]u8,
    version: u32,
    store_format: u32,
    seq: u64,
    model_hash: u64,
    section_count: u32,
    reserved: [28]u8,
};

const SectionHeader = extern struct {
    kind: u32,
    reserved: u32,
};

comptime {
    assert(@sizeOf(Header) == 64);
    assert(@sizeOf(SectionHeader) == 8);
}

pub const Restored = struct {
    facts: bool = false,
    url_bloom: bool = false,
    category_vectors: bool = false,
    link_vectors: bool = false,

    fn get(self: Restored, section: Section) bool {
        assert(@intFromEnum(section) >= 1);
        assert(@intFromEnum(section) <= section_order.len);
        return switch (section) {
            .facts => self.facts,
            .url_bloom => self.url_bloom,
            .category_vectors => self.category_vectors,
            .link_vectors => self.link_vectors,
        };
    }

    fn set(self: *Restored, section: Section) void {
        assert(!self.get(section));
        switch (section) {
            .facts => self.facts = true,
            .url_bloom => self.url_bloom = true,
            .category_vectors => self.category_vectors = true,
            .link_vectors => self.link_vectors = true,
        }
        assert(self.get(section));
    }

    fn count(self: Restored) u32 {
        comptime assert(section_order.len == @typeInfo(Section).@"enum".fields.len);
        var total: u32 = 0;
        for (section_order) |section| total += @intFromBool(self.get(section));
        assert(total <= section_order.len);
        return total;
    }
};

/// Every payload byte of a section passes through here, so the trailer's CRC covers exactly
/// the bytes the reader hashes back.
pub const SectionWriter = struct {
    writer: *std.Io.Writer,
    crc: std.hash.crc.Crc32,
    bytes: u64,

    pub fn init(writer: *std.Io.Writer) SectionWriter {
        assert(writer.end <= writer.buffer.len);
        const section = SectionWriter{ .writer = writer, .crc = .init(), .bytes = 0 };
        assert(section.bytes == 0);
        return section;
    }

    pub fn put(self: *SectionWriter, bytes: []const u8) !void {
        const before = self.bytes;
        self.crc.update(bytes);
        try self.writer.writeAll(bytes);
        self.bytes += bytes.len;
        assert(self.bytes == before + bytes.len);
        assert(self.bytes >= before);
    }

    pub fn put_u64(self: *SectionWriter, value: u64) !void {
        var bytes: [8]u8 = undefined;
        comptime assert(bytes.len == @sizeOf(u64));
        std.mem.writeInt(u64, &bytes, value, .little);
        assert(std.mem.readInt(u64, &bytes, .little) == value);
        try self.put(&bytes);
    }

    pub fn put_u32(self: *SectionWriter, value: u32) !void {
        var bytes: [4]u8 = undefined;
        comptime assert(bytes.len == @sizeOf(u32));
        std.mem.writeInt(u32, &bytes, value, .little);
        assert(std.mem.readInt(u32, &bytes, .little) == value);
        try self.put(&bytes);
    }
};

pub const SectionReader = struct {
    reader: *std.Io.Reader,
    crc: std.hash.crc.Crc32,
    bytes: u64,

    pub fn init(reader: *std.Io.Reader) SectionReader {
        assert(reader.seek <= reader.end);
        const section = SectionReader{ .reader = reader, .crc = .init(), .bytes = 0 };
        assert(section.bytes == 0);
        return section;
    }

    pub fn take(self: *SectionReader, out: []u8) !void {
        const before = self.bytes;
        try self.reader.readSliceAll(out);
        self.crc.update(out);
        self.bytes += out.len;
        assert(self.bytes == before + out.len);
        assert(self.bytes >= before);
    }

    pub fn take_u64(self: *SectionReader) !u64 {
        var bytes: [8]u8 = undefined;
        comptime assert(bytes.len == @sizeOf(u64));
        try self.take(&bytes);
        assert(self.bytes >= bytes.len);
        return std.mem.readInt(u64, &bytes, .little);
    }

    pub fn take_u32(self: *SectionReader) !u32 {
        var bytes: [4]u8 = undefined;
        comptime assert(bytes.len == @sizeOf(u32));
        try self.take(&bytes);
        assert(self.bytes >= bytes.len);
        return std.mem.readInt(u32, &bytes, .little);
    }
};

/// Writes the snapshot for every index that is ready, stamped with `seq`, the sequence the
/// checkpoint just made durable. The temporary file is renamed over the old snapshot only once
/// it is complete and synced, so a crash mid-write leaves the previous snapshot in place.
pub fn write(directory: *Directory, seq: u64) !void {
    const io = directory.io;
    const started = std.Io.Clock.awake.now(io);
    var temporary_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const temporary_path = try path_in(
        directory.config.data_dir,
        temporary_file_name,
        &temporary_buffer,
    );
    var final_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const final_path = try path_in(directory.config.data_dir, file_name, &final_buffer);
    assert(temporary_path.len > final_path.len);

    const ready = ready_sections(directory);
    const file = try std.Io.Dir.cwd().createFile(io, temporary_path, .{ .truncate = true });
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary_path) catch {};
    try write_file(directory, file, seq, ready);
    try std.Io.Dir.cwd().rename(temporary_path, std.Io.Dir.cwd(), final_path, io);
    zigstore.snapshot.fsyncDir(directory.config.data_dir);
    assert(ready.count() <= section_order.len);
    log.info(
        "derived snapshot written at seq {d}: facts={} url_bloom={} category_vectors={} " ++
            "link_vectors={} in {d} ms",
        .{
            seq,
            ready.facts,
            ready.url_bloom,
            ready.category_vectors,
            ready.link_vectors,
            started.untilNow(io, .awake).toMilliseconds(),
        },
    );
}

fn ready_sections(directory: *Directory) Restored {
    assert(directory.config.data_dir.len > 0);
    const ready = Restored{
        .facts = directory.facts.ready.load(.acquire),
        .url_bloom = directory.url_bloom_ready.load(.acquire),
        .category_vectors = directory.category_vector_index.ready.load(.acquire),
        .link_vectors = directory.link_vector_index.ready.load(.acquire),
    };
    assert(ready.count() <= section_order.len);
    return ready;
}

fn write_file(directory: *Directory, file: std.Io.File, seq: u64, ready: Restored) !void {
    const io = directory.io;
    defer file.close(io);
    var buffer: [stream_buffer_bytes]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;

    const header = Header{
        .magic = magic,
        .version = format_version,
        .store_format = Store.schema_def.format_version,
        .seq = seq,
        .model_hash = directory.link_vector_index.codebooks.hash,
        .section_count = ready.count(),
        .reserved = @splat(0),
    };
    assert(header.section_count <= section_order.len);
    try writer.writeAll(std.mem.asBytes(&header));

    var written: u32 = 0;
    for (section_order) |section| {
        if (!ready.get(section)) continue;
        try write_section(directory, writer, section);
        written += 1;
        // The index released its lock with the section; draining the page cache here keeps
        // the next section's locked write from waiting on the disk.
        try writer.flush();
        try file.sync(io);
    }
    assert(written == header.section_count);
    assert(written <= section_order.len);
    try writer.flush();
    try file.sync(io);
}

fn write_section(directory: *Directory, writer: *std.Io.Writer, section: Section) !void {
    const header = SectionHeader{ .kind = @intFromEnum(section), .reserved = 0 };
    assert(header.kind >= 1);
    try writer.writeAll(std.mem.asBytes(&header));

    var payload = SectionWriter.init(writer);
    switch (section) {
        .facts => try directory.facts.snapshot_write(directory.io, &payload),
        .url_bloom => try write_url_bloom(&directory.url_bloom, &payload),
        .category_vectors => try directory.category_vector_index.snapshot_write(
            directory.io,
            &payload,
        ),
        .link_vectors => try directory.link_vector_index.snapshot_write(directory.io, &payload),
    }
    assert(payload.bytes > 0);

    var trailer: [4]u8 = undefined;
    std.mem.writeInt(u32, &trailer, payload.crc.final(), .little);
    try writer.writeAll(&trailer);
}

fn write_url_bloom(bloom: *const zigstore.BloomFilter, payload: *SectionWriter) !void {
    assert(bloom.num_bits % 64 == 0);
    assert(bloom.bits.len * 64 == bloom.num_bits);
    try payload.put_u64(bloom.num_bits);
    try payload.put(std.mem.sliceAsBytes(bloom.bits));
}

/// Restores every section the file carries, in order, and reports which indexes it filled.
/// Nothing here fails the boot: the caller scans the store for whatever was not restored.
pub fn restore(directory: *Directory) Restored {
    const io = directory.io;
    const started = std.Io.Clock.awake.now(io);
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_in(directory.config.data_dir, file_name, &path_buffer) catch return .{};
    assert(path.len > directory.config.data_dir.len);
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            log.info("no derived snapshot: every index loads by scanning the store", .{});
        } else {
            log.warn("derived snapshot unreadable: {} — every index loads by scanning", .{err});
        }
        return .{};
    };
    defer file.close(io);

    var restored: Restored = .{};
    read_file(directory, file, &restored) catch |err| {
        log.warn(
            "derived snapshot stopped: {} — the remaining indexes load by scanning",
            .{err},
        );
    };
    assert(restored.count() <= section_order.len);
    log.info(
        "derived snapshot restored at seq {d}: facts={} url_bloom={} category_vectors={} " ++
            "link_vectors={} in {d} ms",
        .{
            directory.store.header.seq,
            restored.facts,
            restored.url_bloom,
            restored.category_vectors,
            restored.link_vectors,
            started.untilNow(io, .awake).toMilliseconds(),
        },
    );
    return restored;
}

fn read_file(directory: *Directory, file: std.Io.File, restored: *Restored) !void {
    assert(restored.count() == 0);
    var buffer: [stream_buffer_bytes]u8 = undefined;
    var file_reader = file.reader(directory.io, &buffer);
    const reader = &file_reader.interface;

    var header: Header = undefined;
    try reader.readSliceAll(std.mem.asBytes(&header));
    try check_header(&header, .{
        .seq = directory.store.header.seq,
        .store_format = Store.schema_def.format_version,
    });
    assert(header.section_count <= section_order.len);

    for (0..header.section_count) |_| {
        const outcome = try read_section(directory, reader, header.model_hash);
        if (outcome.restored) restored.set(outcome.section);
    }
}

const HeaderExpectation = struct { seq: u64, store_format: u32 };

fn check_header(header: *const Header, expected: HeaderExpectation) !void {
    if (!std.mem.eql(u8, &header.magic, &magic)) return error.SnapshotForeign;
    if (header.version != format_version) return error.SnapshotForeign;
    if (header.store_format != expected.store_format) return error.SnapshotForeign;
    if (header.seq != expected.seq) return error.SnapshotStale;
    if (header.section_count > section_order.len) return error.SnapshotCorrupt;
    assert(header.version == format_version);
    assert(header.seq == expected.seq);
}

const SectionOutcome = struct { section: Section, restored: bool };

fn read_section(directory: *Directory, reader: *std.Io.Reader, model_hash: u64) !SectionOutcome {
    var header: SectionHeader = undefined;
    try reader.readSliceAll(std.mem.asBytes(&header));
    const section = std.enums.fromInt(Section, header.kind) orelse return error.SnapshotCorrupt;
    assert(@intFromEnum(section) == header.kind);
    if (section == .link_vectors) {
        if (model_hash != directory.link_vector_index.codebooks.hash) {
            return error.SnapshotModelChanged;
        }
    }

    var payload = SectionReader.init(reader);
    const restored = restore_section(directory, section, &payload) catch |err| {
        discard_section(directory, section);
        return err;
    };
    assert(payload.bytes > 0);

    var trailer: [4]u8 = undefined;
    try reader.readSliceAll(&trailer);
    if (std.mem.readInt(u32, &trailer, .little) != payload.crc.final()) {
        discard_section(directory, section);
        return error.SnapshotCorrupt;
    }
    return .{ .section = section, .restored = restored };
}

fn restore_section(directory: *Directory, section: Section, payload: *SectionReader) !bool {
    const allocator = directory.allocator;
    assert(payload.bytes == 0);
    switch (section) {
        .facts => try directory.facts.snapshot_restore(allocator, payload),
        .url_bloom => return restore_url_bloom(directory, payload),
        .category_vectors => try directory.category_vector_index.snapshot_restore(
            allocator,
            payload,
        ),
        .link_vectors => try directory.link_vector_index.snapshot_restore(allocator, payload),
    }
    assert(payload.bytes > 0);
    return true;
}

fn discard_section(directory: *Directory, section: Section) void {
    const allocator = directory.allocator;
    switch (section) {
        .facts => directory.facts.snapshot_discard(allocator),
        .url_bloom => {},
        .category_vectors => directory.category_vector_index.snapshot_discard(allocator),
        .link_vectors => directory.link_vector_index.snapshot_discard(allocator),
    }
    assert(!directory.facts.ready.load(.acquire));
    assert(!directory.link_vector_index.ready.load(.acquire));
}

/// The live filter was sized in `Directory.init` for the links on disk; the stored one replaces
/// it only while it still holds the bits per link it was seeded with. A smaller one is read to
/// the end, so the stream stays aligned, and then left to the seeder.
fn restore_url_bloom(directory: *Directory, payload: *SectionReader) !bool {
    const num_bits = try payload.take_u64();
    if (num_bits % 64 != 0) return error.SnapshotCorrupt;
    if (num_bits < url_bloom_bits_min) return error.SnapshotCorrupt;
    if (num_bits > url_bloom_bits_max) return error.SnapshotCorrupt;
    const words: usize = @intCast(@divExact(num_bits, 64));
    assert(words > 0);

    const bits = try directory.allocator.alloc(std.atomic.Value(u64), words);
    errdefer directory.allocator.free(bits);

    try payload.take(std.mem.sliceAsBytes(bits));
    const link_count = directory.store.tree("links_by_id").entryCount();
    if (num_bits < link_count *| url_bloom_bits_per_link) {
        directory.allocator.free(bits);
        return false;
    }
    directory.url_bloom.deinit();
    directory.url_bloom = .{
        .bits = bits,
        .num_bits = num_bits,
        .allocator = directory.allocator,
    };
    assert(directory.url_bloom.bits.len == words);
    assert(directory.url_bloom.num_bits == num_bits);
    return true;
}

fn path_in(
    data_dir: []const u8,
    name: []const u8,
    buffer: *[std.Io.Dir.max_path_bytes]u8,
) ![]const u8 {
    assert(data_dir.len > 0);
    assert(name.len > 0);
    return std.fmt.bufPrint(buffer, "{s}/{s}", .{ data_dir, name });
}

const testing = std.testing;

// Goal: the reader hashes exactly the bytes the writer hashed, and a flipped byte is caught.
// Method: write three values into a buffer, read them back twice, once intact and once damaged.
test "section writer and reader agree on bytes and crc, and a flipped byte is caught" {
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    var payload = SectionWriter.init(&writer);
    try payload.put_u64(42);
    try payload.put_u32(7);
    try payload.put("abc");
    const crc = payload.crc.final();
    const written = buffer[0..writer.end];
    try testing.expectEqual(@as(usize, 15), written.len);

    var reader = std.Io.Reader.fixed(written);
    var incoming = SectionReader.init(&reader);
    try testing.expectEqual(@as(u64, 42), try incoming.take_u64());
    try testing.expectEqual(@as(u32, 7), try incoming.take_u32());
    var text: [3]u8 = undefined;
    try incoming.take(&text);
    try testing.expectEqualStrings("abc", &text);
    try testing.expectEqual(crc, incoming.crc.final());
    try testing.expectEqual(payload.bytes, incoming.bytes);

    written[9] ^= 0x01;
    var damaged_reader = std.Io.Reader.fixed(written);
    var damaged = SectionReader.init(&damaged_reader);
    _ = try damaged.take_u64();
    _ = try damaged.take_u32();
    try damaged.take(&text);
    try testing.expect(crc != damaged.crc.final());
}

// Goal: only a header from this binary, this store format and this checkpoint is accepted.
// Method: start from a valid header and break one field at a time.
test "check_header accepts the current header and rejects each foreign or stale field" {
    const valid = Header{
        .magic = magic,
        .version = format_version,
        .store_format = Store.schema_def.format_version,
        .seq = 77,
        .model_hash = 1,
        .section_count = 4,
        .reserved = @splat(0),
    };
    const expected: HeaderExpectation = .{
        .seq = 77,
        .store_format = Store.schema_def.format_version,
    };
    try check_header(&valid, expected);

    var foreign = valid;
    foreign.magic[0] = 'X';
    try testing.expectError(error.SnapshotForeign, check_header(&foreign, expected));

    var newer = valid;
    newer.version = format_version + 1;
    try testing.expectError(error.SnapshotForeign, check_header(&newer, expected));

    var other_store = valid;
    other_store.store_format = Store.schema_def.format_version + 1;
    try testing.expectError(error.SnapshotForeign, check_header(&other_store, expected));

    var stale = valid;
    stale.seq = 76;
    try testing.expectError(error.SnapshotStale, check_header(&stale, expected));

    var overfull = valid;
    overfull.section_count = 5;
    try testing.expectError(error.SnapshotCorrupt, check_header(&overfull, expected));
}
