//! The one-shot importer builds a fresh store from the DMOZ TSV dumps: categories first, so
//! every link can resolve its topic path to an id, then links with their optional vectors,
//! checkpointing every few thousand links so a crash costs minutes rather than the whole run.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const Directory = @import("directory.zig").Directory;
const operations = @import("operations/operations.zig");
const schema = @import("schema.zig");
const vector_model = @import("vector_model.zig");
const Config = @import("main.zig").Config;

const log = std.log.scoped(.dmoz_import);

const root_name = "Top";
const root_slug = "top";

const vectors_magic: u32 = 0x52564D44;
const vectors_version: u32 = 1;
const vectors_header_bytes: usize = 24;
const vector_row_bytes: usize = 4 + schema.embedding_dimensions;
const vector_batch: usize = operations.vectors_per_write_max;
const progress_every: u64 = 5000;

fn fail(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("error: " ++ format ++ "\n", arguments);
    std.process.exit(1);
}

fn dir_is_empty(io: std.Io, path: []const u8) !bool {
    assert(path.len > 0);
    const data_directory = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => return true,
            else => return err,
        }
    };
    defer data_directory.close(io);
    var entries = data_directory.iterate();
    while (try entries.next(io)) |_| return false;
    return true;
}

fn read_field(fields: *std.mem.SplitIterator(u8, .scalar)) []const u8 {
    return fields.next() orelse "";
}

fn read_file_all(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);

    const buffer = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buffer);

    const bytes_read = try file.readPositionalAll(io, buffer, 0);
    if (bytes_read != stat.size) return error.UnexpectedEof;
    assert(bytes_read == buffer.len);
    return buffer;
}

fn import_categories(
    db: *Directory,
    allocator: std.mem.Allocator,
    path_to_id: *std.StringHashMap(u64),
    tsv_path: []const u8,
) !u64 {
    const top_id = (try operations.resolve_slug_path(db, root_slug)) orelse
        try operations.create_category(
            db,
            0,
            .{ .name = root_name, .slug = root_slug, .description = "" },
        );
    assert(top_id > 0);
    try path_to_id.put(try allocator.dupe(u8, "Top"), top_id);
    assert(path_to_id.count() >= 1);
    log.info("Root category Top (id={d})", .{top_id});

    const data = try read_file_all(db.io, allocator, tsv_path);
    defer allocator.free(data);

    var line_count: u64 = 0;
    var created_count: u64 = 0;
    var skipped_count: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (line_count += 1) {
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        const path = read_field(&fields);
        const parent_path = read_field(&fields);
        const name = read_field(&fields);
        const slug = read_field(&fields);

        if (path.len == 0 or name.len == 0 or slug.len == 0) {
            skipped_count += 1;
            continue;
        }

        var parent_id: u64 = 0;
        if (parent_path.len != 0) {
            if (path_to_id.get(parent_path)) |id| {
                assert(id > 0);
                parent_id = id;
            } else {
                skipped_count += 1;
                continue;
            }
        }

        const id = operations.create_category(
            db,
            parent_id,
            .{ .name = name, .slug = slug, .description = "" },
        ) catch |err| {
            log.warn("create_category failed for {s}: {}", .{ path, err });
            skipped_count += 1;
            continue;
        };
        assert(id > 0);
        const owned = try allocator.dupe(u8, path);
        try path_to_id.put(owned, id);
        created_count += 1;
        if (created_count % progress_every == 0) {
            log.info("  created {d} categories", .{created_count});
        }
    }
    assert(created_count + skipped_count <= line_count);
    log.info("Categories: created={d} skipped={d}", .{ created_count, skipped_count });
    return created_count;
}

const VectorRows = struct {
    file: std.Io.File,
    model: u64,
    rows: u64,
    batch: [vector_batch]schema.StoredVector = undefined,
    batch_len: u32 = 0,
    written: u64 = 0,

    // The file header is `[u32 magic][u32 version][u64 model][u64 rows]`, then one
    // `[f32 scale][i8 × dimensions]` row per link in TSV order.
    fn open(io: std.Io, path: []const u8) !VectorRows {
        comptime assert(vectors_header_bytes == 2 * @sizeOf(u32) + 2 * @sizeOf(u64));
        comptime assert(vector_row_bytes == @sizeOf(f32) + schema.embedding_dimensions);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);

        var header: [vectors_header_bytes]u8 = undefined;
        const header_read = try file.readPositionalAll(io, &header, 0);
        if (header_read != vectors_header_bytes) return error.VectorsFileTruncated;
        const magic = std.mem.readInt(u32, header[0..4], .little);
        if (magic != vectors_magic) return error.VectorsFileFormat;
        const version = std.mem.readInt(u32, header[4..8], .little);
        if (version != vectors_version) return error.VectorsFileFormat;
        const model = std.mem.readInt(u64, header[8..16], .little);
        if (model == 0) return error.VectorsFileFormat;
        assert(model != 0);
        return .{
            .file = file,
            .model = model,
            .rows = std.mem.readInt(u64, header[16..24], .little),
        };
    }

    fn close(self: *VectorRows, io: std.Io) void {
        self.file.close(io);
    }

    fn stage(self: *VectorRows, db: *Directory, options: struct { row: u64, link_id: u64 }) !void {
        if (options.row >= self.rows) return;
        assert(options.link_id > 0);
        assert(self.batch_len < vector_batch);
        var bytes: [vector_row_bytes]u8 = undefined;
        const at = vectors_header_bytes + options.row * vector_row_bytes;
        const row_read = try self.file.readPositionalAll(db.io, &bytes, at);
        if (row_read != vector_row_bytes) return error.VectorsFileTruncated;

        const scale: f32 = @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
        if (!(scale > 0)) return;
        const slot = &self.batch[self.batch_len];
        slot.* = .{
            .id = options.link_id,
            .scale = scale,
            .values = @bitCast(bytes[4..][0..schema.embedding_dimensions].*),
        };
        self.batch_len += 1;
        assert(self.batch_len <= vector_batch);
        if (self.batch_len == vector_batch) try self.flush(db);
    }

    fn flush(self: *VectorRows, db: *Directory) !void {
        if (self.batch_len == 0) return;
        assert(self.batch_len > 0);
        assert(self.batch_len <= vector_batch);
        const written_before = self.written;
        db.write_mutex.lockUncancelable(db.io);
        defer db.write_mutex.unlock(db.io);
        try db.commit(.{ .link_vectors_put = .{
            .model = self.model,
            .vectors = self.batch[0..self.batch_len],
        } });
        self.written += self.batch_len;
        self.batch_len = 0;
        assert(self.written > written_before);
    }
};

fn import_links(
    db: *Directory,
    allocator: std.mem.Allocator,
    path_to_id: *std.StringHashMap(u64),
    tsv_path: []const u8,
    vectors: ?*VectorRows,
) !u64 {
    const data = try read_file_all(db.io, allocator, tsv_path);
    defer allocator.free(data);

    var created_count: u64 = 0;
    var skipped_count: u64 = 0;
    var row: u64 = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| : (row += 1) {
        if (line.len == 0) continue;

        var fields = std.mem.splitScalar(u8, line, '\t');
        const topic = read_field(&fields);
        const url = read_field(&fields);
        const title = read_field(&fields);
        const description = read_field(&fields);

        if (topic.len == 0 or url.len == 0) {
            skipped_count += 1;
            continue;
        }

        const category_id = path_to_id.get(topic) orelse {
            skipped_count += 1;
            continue;
        };
        assert(category_id > 0);

        const link_id = operations.create_link(
            db,
            category_id,
            .{ .url = url, .title = title, .description = description },
        ) catch |err| switch (err) {
            error.DuplicateUrl => {
                skipped_count += 1;
                continue;
            },
            else => {
                log.warn("create_link failed for {s}: {}", .{ url, err });
                skipped_count += 1;
                continue;
            },
        };
        assert(link_id > 0);
        if (vectors) |rows| try rows.stage(db, .{ .row = row, .link_id = link_id });
        created_count += 1;
        if (created_count % progress_every == 0) {
            if (vectors) |rows| try rows.flush(db);
            const snapshot = zigstore.snapshot.forceSnapshot(
                db.store.snapshotHost(),
            ) catch |err| blk: {
                log.warn("forceSnapshot failed: {}", .{err});
                break :blk zigstore.SnapshotResult{ .wal_sequence = 0, .duration_ms = 0 };
            };
            log.info(
                "  inserted {d} links (checkpoint wal_seq={d} dur={d}ms)",
                .{ created_count, snapshot.wal_sequence, snapshot.duration_ms },
            );
        }
    }
    if (vectors) |rows| try rows.flush(db);
    if (vectors) |rows| assert(rows.batch_len == 0);
    assert(created_count + skipped_count <= row);
    log.info("Links: created={d} skipped={d}", .{ created_count, skipped_count });
    return created_count;
}

// The importer refuses an existing database: it issues ids from a fresh counter and would
// otherwise interleave them with rows it cannot see.
fn open_empty_data_dir(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const path = cwd.realPathFileAlloc(io, data_dir, allocator) catch |err| switch (err) {
        error.FileNotFound => blk: {
            cwd.createDir(io, data_dir, .default_dir) catch |create_err| switch (create_err) {
                error.PathAlreadyExists => {},
                else => return create_err,
            };
            break :blk try cwd.realPathFileAlloc(io, data_dir, allocator);
        },
        else => return err,
    };
    errdefer allocator.free(path);
    assert(path.len > 0);
    assert(std.fs.path.isAbsolute(path));

    if (!try dir_is_empty(io, path)) {
        fail("data dir {s} is not empty — refusing to import into an existing database", .{path});
    }
    return path;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const usage = "usage: dmoz_import <data_dir> <cats.tsv> <links.tsv> [vectors.bin]  " ++
        "(model file from DMOZDB_VECTOR_MODEL)";
    const data_dir = args.next() orelse fail(usage, .{});
    const categories_path = args.next() orelse fail(usage, .{});
    const links_path = args.next() orelse fail(usage, .{});
    const vectors_path = args.next();

    const data_dir_absolute = try open_empty_data_dir(io, allocator, data_dir);
    defer allocator.free(data_dir_absolute);

    var config = Config.from_env(init.environ_map);
    config.data_dir = data_dir_absolute;
    config.server = .{
        .cache_size_mb = 64,
        .thread_count = 1,
        .wal_batch_size = 1024,
        .snapshot_interval_s = 3600,
    };

    const model = try vector_model.Model.load(io, allocator, config.vector_model);
    defer model.deinit(allocator);

    const db = try Directory.init(io, allocator, config, model);
    defer db.deinit();
    try db.recover();
    try operations.seed_url_bloom(db, .full_speed);
    assert(db.url_bloom_ready.load(.acquire));

    var vectors: ?VectorRows = if (vectors_path) |path| try VectorRows.open(io, path) else null;
    defer if (vectors) |*rows| rows.close(io);

    var path_to_id = std.StringHashMap(u64).init(allocator);
    defer {
        var entries = path_to_id.iterator();
        while (entries.next()) |entry| allocator.free(entry.key_ptr.*);
        path_to_id.deinit();
    }

    const started_ms = db.now_millis();
    const category_count = try import_categories(db, allocator, &path_to_id, categories_path);
    const categories_done_ms = db.now_millis();
    const link_count = try import_links(
        db,
        allocator,
        &path_to_id,
        links_path,
        if (vectors) |*rows| rows else null,
    );
    const links_done_ms = db.now_millis();
    assert(path_to_id.count() <= category_count + 1);

    const vector_count: u64 = if (vectors) |rows| rows.written else 0;
    assert(vector_count <= link_count);
    log.info("DONE: {d} categories in {d}ms, {d} links and {d} vectors in {d}ms", .{
        category_count,
        categories_done_ms - started_ms,
        link_count,
        vector_count,
        links_done_ms - categories_done_ms,
    });
}
