const std = @import("std");
const zigstore = @import("zigstore");
const Directory = @import("directory.zig").Directory;
const operations = @import("operations/operations.zig");
const schema = @import("schema.zig");
const vector_model = @import("vector_model.zig");
const Config = @import("main.zig").Config;

const log = std.log.scoped(.dmoz_import);

const ROOT_NAME = "Top";
const ROOT_SLUG = "top";

const VECTORS_MAGIC: u32 = 0x52564D44;
const VECTORS_VERSION: u32 = 1;
const VECTORS_HEADER_BYTES: usize = 24;
const VECTOR_ROW_BYTES: usize = 4 + schema.EMBEDDING_DIMS;
const VECTOR_BATCH: usize = operations.MAX_VECTORS_PER_WRITE;

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

const VectorRows = struct {
    file: std.Io.File,
    model: u64,
    rows: u64,
    batch: [VECTOR_BATCH]schema.StoredVector = undefined,
    batch_len: usize = 0,
    written: u64 = 0,

    fn open(io: std.Io, path: []const u8) !VectorRows {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);

        var header: [VECTORS_HEADER_BYTES]u8 = undefined;
        if (try file.readPositionalAll(io, &header, 0) != VECTORS_HEADER_BYTES) return error.VectorsFileTruncated;
        if (std.mem.readInt(u32, header[0..4], .little) != VECTORS_MAGIC) return error.VectorsFileFormat;
        if (std.mem.readInt(u32, header[4..8], .little) != VECTORS_VERSION) return error.VectorsFileFormat;
        const model = std.mem.readInt(u64, header[8..16], .little);
        if (model == 0) return error.VectorsFileFormat;
        return .{ .file = file, .model = model, .rows = std.mem.readInt(u64, header[16..24], .little) };
    }

    fn close(self: *VectorRows, io: std.Io) void {
        self.file.close(io);
    }

    fn stage(self: *VectorRows, db: *Directory, row: u64, link_id: u64) !void {
        if (row >= self.rows) return;
        var bytes: [VECTOR_ROW_BYTES]u8 = undefined;
        const at = VECTORS_HEADER_BYTES + row * VECTOR_ROW_BYTES;
        if (try self.file.readPositionalAll(db.io, &bytes, at) != VECTOR_ROW_BYTES) return error.VectorsFileTruncated;

        const scale: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
        if (!(scale > 0)) return;
        const slot = &self.batch[self.batch_len];
        slot.* = .{ .id = link_id, .scale = scale, .values = @bitCast(bytes[4..][0..schema.EMBEDDING_DIMS].*) };
        self.batch_len += 1;
        if (self.batch_len == VECTOR_BATCH) try self.flush(db);
    }

    fn flush(self: *VectorRows, db: *Directory) !void {
        if (self.batch_len == 0) return;
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        try db.commit(.{ .link_vectors_put = .{ .model = self.model, .vectors = self.batch[0..self.batch_len] } });
        self.written += self.batch_len;
        self.batch_len = 0;
    }
};

fn importLinks(
    db: *Directory,
    allocator: std.mem.Allocator,
    path_to_id: *std.StringHashMap(u64),
    tsv_path: []const u8,
    vectors: ?*VectorRows,
) !u64 {
    const data = try readFileAll(db.io, allocator, tsv_path);
    defer allocator.free(data);

    var n_created: u64 = 0;
    var n_skipped: u64 = 0;
    var row: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (row += 1) {
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

        const link_id = operations.createLink(db, cat_id, url, title, desc) catch |err| switch (err) {
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
        if (vectors) |v| try v.stage(db, row, link_id);
        n_created += 1;
        if (n_created % 5000 == 0) {
            if (vectors) |v| try v.flush(db);
            const snap = zigstore.snapshot.forceSnapshot(db.store.snapshotHost()) catch |e| blk: {
                log.warn("forceSnapshot failed: {}", .{e});
                break :blk zigstore.SnapshotResult{ .wal_sequence = 0, .duration_ms = 0 };
            };
            log.info("  inserted {d} links (checkpoint wal_seq={d} dur={d}ms)", .{ n_created, snap.wal_sequence, snap.duration_ms });
        }
    }
    if (vectors) |v| try v.flush(db);
    log.info("Links: created={d} skipped={d}", .{ n_created, n_skipped });
    return n_created;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const usage = "usage: dmoz_import <data_dir> <cats.tsv> <links.tsv> [vectors.bin]  (model file from DMOZDB_VECTOR_MODEL)";
    const data_dir = args.next() orelse fail(usage, .{});
    const cats_path = args.next() orelse fail(usage, .{});
    const links_path = args.next() orelse fail(usage, .{});
    const vectors_path = args.next();

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

    var config = Config.fromEnv(init.environ_map);
    config.data_dir = abs_data_dir;
    config.server = .{
        .cache_size_mb = 64,
        .thread_count = 1,
        .wal_batch_size = 1024,
        .snapshot_interval_s = 3600,
    };

    const pq = try vector_model.Model.load(io, allocator, config.vector_model);
    defer pq.deinit(allocator);

    const db = try Directory.init(io, allocator, config, pq);
    defer db.deinit();
    try db.recover();
    try operations.seedUrlBloom(db, .full_speed);

    var vectors: ?VectorRows = if (vectors_path) |p| try VectorRows.open(io, p) else null;
    defer if (vectors) |*v| v.close(io);

    var path_to_id = std.StringHashMap(u64).init(allocator);
    defer {
        var it = path_to_id.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        path_to_id.deinit();
    }

    const t0 = db.nowMillis();
    const n_cats = try importCategories(db, allocator, &path_to_id, cats_path);
    const t1 = db.nowMillis();
    const n_links = try importLinks(db, allocator, &path_to_id, links_path, if (vectors) |*v| v else null);
    const t2 = db.nowMillis();

    const n_vectors: u64 = if (vectors) |v| v.written else 0;
    log.info("DONE: {d} categories in {d}ms, {d} links and {d} vectors in {d}ms", .{ n_cats, t1 - t0, n_links, n_vectors, t2 - t1 });
}
