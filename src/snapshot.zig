const std = @import("std");
const file_header = @import("file_header.zig");
const page_cache = @import("page_cache.zig");

pub const SNAP_MAGIC: u32 = 0x534E4150;

pub const SnapshotResult = struct {
    wal_sequence: u64,
    duration_ms: u64,
};

pub fn forceSnapshot(db: anytype) !SnapshotResult {
    if (db.snapshot_in_progress.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) {
        return error.SnapshotInProgress;
    }
    defer db.snapshot_in_progress.store(false, .release);

    const start_ns = std.time.nanoTimestamp();

    const wal_seq: u64 = if (db.store.wal_writer) |*w| w.getSequence() else 0;

    var mgr = SnapshotManager.init(db.config.data_dir, 0);
    try mgr.createSnapshot(db, wal_seq);

    const end_ns = std.time.nanoTimestamp();
    const duration_ms: u64 = @intCast(@divTrunc(end_ns - start_ns, std.time.ns_per_ms));
    return .{ .wal_sequence = wal_seq, .duration_ms = duration_ms };
}

pub const SnapshotHeader = extern struct {
    magic: u32 = SNAP_MAGIC,
    version: u32 = 1,
    wal_sequence: u64,
    timestamp: i64,
    page_count: u32,
    _reserved: [36]u8 = [_]u8{0} ** 36,
};

comptime {
    if (@sizeOf(SnapshotHeader) != 64) @compileError("SnapshotHeader size mismatch");
}

const SNAP_HEADER_SIZE: usize = @sizeOf(SnapshotHeader);

pub const SnapshotManager = struct {
    data_dir: []const u8,
    interval_s: u32,
    last_snapshot_time: i64,

    pub fn init(data_dir: []const u8, interval_s: u32) SnapshotManager {
        return SnapshotManager{
            .data_dir = data_dir,
            .interval_s = interval_s,
            .last_snapshot_time = 0,
        };
    }

    pub fn shouldSnapshot(self: *const SnapshotManager) bool {
        const now = std.time.timestamp();
        return (now - self.last_snapshot_time) >= @as(i64, self.interval_s);
    }

    pub fn createSnapshot(
        self: *SnapshotManager,
        db: anytype,
        wal_sequence: u64,
    ) !void {
        {
            db.apply_mutex.lock();
            defer db.apply_mutex.unlock();
            db.store.mt_drain_mutex.lock();
            defer db.store.mt_drain_mutex.unlock();

            try db.store.cache.flushAll();
            try db.flushHeader();
        }

        const now = std.time.timestamp();

        const snap_header = SnapshotHeader{
            .wal_sequence = wal_sequence,
            .timestamp = now,
            .page_count = @intCast(db.store.header.page_count),
        };

        const tmp_path = try std.fs.path.join(std.heap.page_allocator, &.{ self.data_dir, "snapshot.meta.tmp" });
        defer std.heap.page_allocator.free(tmp_path);

        const final_path = try std.fs.path.join(std.heap.page_allocator, &.{ self.data_dir, "snapshot.meta" });
        defer std.heap.page_allocator.free(final_path);

        {
            const tmp_file = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
            defer tmp_file.close();

            const header_bytes: *const [SNAP_HEADER_SIZE]u8 = @ptrCast(&snap_header);
            try tmp_file.writeAll(header_bytes);
            try tmp_file.sync();
        }

        try std.fs.cwd().rename(tmp_path, final_path);

        fsyncDir(self.data_dir);

        self.last_snapshot_time = now;
    }

    fn fsyncDir(path: []const u8) void {
        const log = std.log.scoped(.snapshot);
        const flags: std.posix.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true };
        const fd = std.posix.open(path, flags, 0) catch |err| {
            log.warn("snapshot: dir open failed for fsync: {}", .{err});
            return;
        };
        defer std.posix.close(fd);
        std.posix.fsync(fd) catch |err| {
            log.warn("snapshot: dir fsync failed: {}", .{err});
        };
    }

    pub fn loadSnapshotMeta(data_dir: []const u8) !?SnapshotHeader {
        const path = try std.fs.path.join(std.heap.page_allocator, &.{ data_dir, "snapshot.meta" });
        defer std.heap.page_allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close();

        var buf: [SNAP_HEADER_SIZE]u8 = undefined;
        const n = try file.readAll(&buf);
        if (n < SNAP_HEADER_SIZE) return null;

        const snap: *const SnapshotHeader = @ptrCast(@alignCast(&buf));

        if (snap.magic != SNAP_MAGIC) return error.InvalidSnapshotMagic;

        return snap.*;
    }

    pub fn getWalSequence(data_dir: []const u8) !u64 {
        const snap = try loadSnapshotMeta(data_dir);
        if (snap) |s| {
            return s.wal_sequence;
        }
        return 0;
    }
};

test "snapshot header size" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SnapshotHeader));
}

test "loadSnapshotMeta returns null for missing file" {
    const result = try SnapshotManager.loadSnapshotMeta("/tmp/snapshot_test_nonexistent_12345");
    try std.testing.expect(result == null);
}

test "create and load snapshot meta roundtrip" {
    const tmp_dir = "/tmp/snapshot_test_roundtrip";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const snap_header = SnapshotHeader{
        .magic = 0x534E4150,
        .version = 1,
        .wal_sequence = 42,
        .timestamp = 1700000000,
        .page_count = 100,
    };

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir, "snapshot.meta" });
    defer std.testing.allocator.free(path);

    {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const header_bytes: *const [SNAP_HEADER_SIZE]u8 = @ptrCast(&snap_header);
        try file.writeAll(header_bytes);
    }

    const loaded = (try SnapshotManager.loadSnapshotMeta(tmp_dir)).?;
    try std.testing.expectEqual(@as(u32, 0x534E4150), loaded.magic);
    try std.testing.expectEqual(@as(u32, 1), loaded.version);
    try std.testing.expectEqual(@as(u64, 42), loaded.wal_sequence);
    try std.testing.expectEqual(@as(i64, 1700000000), loaded.timestamp);
    try std.testing.expectEqual(@as(u32, 100), loaded.page_count);
}

test "getWalSequence returns 0 when no snapshot exists" {
    const seq = try SnapshotManager.getWalSequence("/tmp/snapshot_test_nonexistent_67890");
    try std.testing.expectEqual(@as(u64, 0), seq);
}

test "getWalSequence returns stored sequence" {
    const tmp_dir = "/tmp/snapshot_test_getseq";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    std.fs.makeDirAbsolute(tmp_dir) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const snap_header = SnapshotHeader{
        .wal_sequence = 99,
        .timestamp = 1700000000,
        .page_count = 50,
    };

    const path = try std.fs.path.join(std.testing.allocator, &.{ tmp_dir, "snapshot.meta" });
    defer std.testing.allocator.free(path);

    {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const header_bytes: *const [SNAP_HEADER_SIZE]u8 = @ptrCast(&snap_header);
        try file.writeAll(header_bytes);
    }

    const seq = try SnapshotManager.getWalSequence(tmp_dir);
    try std.testing.expectEqual(@as(u64, 99), seq);
}

test "shouldSnapshot respects interval" {
    var mgr = SnapshotManager.init("/tmp", 300);

    try std.testing.expect(mgr.shouldSnapshot());

    mgr.last_snapshot_time = std.time.timestamp();
    try std.testing.expect(!mgr.shouldSnapshot());
}
