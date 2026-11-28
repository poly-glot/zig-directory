//! The server entry point: read the configuration from the environment, load the vector model,
//! open and recover the directory, start its background workers, and hand the store to the
//! zigstore reactor. Nothing is served before recovery has completed.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");

pub const schema = @import("schema.zig");
pub const operations = @import("operations/operations.zig");
pub const directory = @import("directory.zig");
pub const binary_protocol = @import("binary_protocol.zig");
pub const subtree = @import("subtree.zig");
pub const verifier = @import("verifier.zig");
pub const vector_model = @import("vector_model.zig");
const changeset = @import("changeset.zig");

const Directory = directory.Directory;

const log = std.log.scoped(.dmozdb);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var rejected_key: []const u8 = "";
    var config = Config.from_env(init.environ_map, &rejected_key) catch |err| {
        log.err("{s}={s} is not a value dmozdb accepts — fix it or unset it", .{
            rejected_key,
            init.environ_map.get(rejected_key) orelse "",
        });
        return err;
    };
    const data_dir = resolve_data_dir(init.io, allocator, config.data_dir) catch |err| {
        log.err("data dir {s} cannot be opened: {}", .{ config.data_dir, err });
        return err;
    };
    defer allocator.free(data_dir);
    config.data_dir = data_dir;
    assert(std.fs.path.isAbsolute(config.data_dir));

    log.info("Dmoz Zig Development - starting up", .{});
    log.info(
        "  bind={d}.{d}.{d}.{d}:{d} data_dir={s} cache={d}MB threads={d} trusted_ips={d}",
        .{
            config.server.bind_address[0],
            config.server.bind_address[1],
            config.server.bind_address[2],
            config.server.bind_address[3],
            config.server.port,
            config.data_dir,
            config.server.cache_size_mb,
            config.server.thread_count,
            config.server.trusted_count,
        },
    );

    const model = vector_model.Model.load(init.io, allocator, config.vector_model) catch |err| {
        log.err(
            "vector model {s} failed to load: {} — " ++
                "set DMOZDB_VECTOR_MODEL to the file the image ships",
            .{ config.vector_model, err },
        );
        return err;
    };
    defer model.deinit(allocator);
    log.info("  vector model {s} hash={x}", .{ config.vector_model, model.hash });

    const db = try Directory.init(init.io, allocator, config, model);
    defer db.deinit();

    try db.recover();
    assert(db.derived_counts_checkpointed());
    db.start_background_threads();

    log.info("Database ready. Starting server on port {d}...", .{config.server.port});

    try zigstore.run(directory.Store, db, Directory.handler(), config.server, .{});
}

const scratch_slab_mb_min: u32 = 1;
const scratch_slab_mb_max: u32 = 1024;
// The engine counts cache frames in u32 and refuses a budget with more frames than that
// (`error.CacheSizeTooLarge` from `Store.init`), so the knob stops one megabyte short of it and
// that error cannot come from configuration. The engine pads its header to exactly one page.
const page_bytes: u64 = @sizeOf(directory.Store.Header);
const megabyte_bytes: u64 = 1024 * 1024;
pub const cache_size_mb_max: u32 = @intCast(
    @divFloor(@as(u64, std.math.maxInt(u32)) * page_bytes, megabyte_bytes),
);
// Each reactor (thread_count / 2 of them) needs its own scratch slab, and the pool holds
// `scratch.slabs_max`; directory.zig asserts the relation at comptime.
pub const thread_count_max: u32 = 64;

comptime {
    assert(page_bytes >= 4096);
    assert(@divExact(megabyte_bytes, page_bytes) >= 1);
    assert(@divExact(@as(u64, cache_size_mb_max) * megabyte_bytes, page_bytes) <=
        std.math.maxInt(u32));
    assert(@divExact((@as(u64, cache_size_mb_max) + 1) * megabyte_bytes, page_bytes) >
        std.math.maxInt(u32));
    assert(scratch_slab_mb_min <= scratch_slab_mb_max);
}

/// The data directory as an absolute path, created if it is missing. zigstore and the header
/// upgrade open every file with the std `*Absolute` calls, which assert an absolute path, so a
/// relative DMOZDB_DATA_DIR is resolved here once, against the working directory. It resolves
/// before it creates: createDirPath fails with NotDir on a symlink to a directory, a common
/// development and volume layout.
pub fn resolve_data_dir(
    io: std.Io,
    allocator: std.mem.Allocator,
    data_dir: []const u8,
) ![:0]u8 {
    assert(data_dir.len > 0);
    const cwd = std.Io.Dir.cwd();
    const path = cwd.realPathFileAlloc(io, data_dir, allocator) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try cwd.createDirPath(io, data_dir);
            break :blk try cwd.realPathFileAlloc(io, data_dir, allocator);
        },
        else => return err,
    };
    assert(std.fs.path.isAbsolute(path));
    return path;
}

const EnvironmentError = error{InvalidEnvironment};

pub const Config = struct {
    server: zigstore.ServerConfig = .{},
    data_dir: []const u8 = "/var/lib/dmozdb",
    rename_inline_threshold: u32 = 5000,
    repair_worker_interval_ms: u32 = 1000,
    // Each chunk holds write_mutex while it visits this many categories: 1,000 visits held it
    // about 45 ms on the 92k store, where 10,000 held it 340 to 460 ms.
    repair_worker_chunk_size: u32 = 1000,
    verifier_interval_s: u32 = 300,
    vector_model: []const u8 = "/usr/local/share/dmozdb/vector_model.bin",
    scratch_slab_mb: u32 = 32,

    // The environment is operating input: a knob that does not parse or is out of range is
    // refused with its name in `rejected_key`, never replaced by a default the operator did not
    // ask for. zigstore's own parser falls back silently, so its knobs are checked here first.
    pub fn from_env(
        env: *const std.process.Environ.Map,
        rejected_key: *[]const u8,
    ) EnvironmentError!Config {
        try check_server_env(env, rejected_key);
        var config = Config{ .server = zigstore.ServerConfig.fromEnv("DMOZDB_", env) };
        if (env.get("DMOZDB_BIND")) |value| {
            const address = std.Io.net.Ip4Address.parse(value, 0) catch
                return reject(rejected_key, "DMOZDB_BIND");
            if (!std.mem.eql(u8, &address.bytes, &config.server.bind_address)) {
                return reject(rejected_key, "DMOZDB_BIND");
            }
        }
        if (env.get("DMOZDB_DATA_DIR")) |value| {
            if (value.len == 0) return reject(rejected_key, "DMOZDB_DATA_DIR");
            config.data_dir = value;
        }
        if (env.get("DMOZDB_VECTOR_MODEL")) |value| {
            config.vector_model = value;
        }
        const any: Range = .{ .min = 0, .max = std.math.maxInt(u32) };
        const slab: Range = .{ .min = scratch_slab_mb_min, .max = scratch_slab_mb_max };
        // Each decides how many slug-path swaps one change set carries, and one change set is
        // one WAL record, so both stop where the largest such record still fits.
        const swaps: Range = .{ .min = 0, .max = changeset.swaps_per_change_set_max };
        if (try parse_knob(env, "DMOZDB_RENAME_INLINE_THRESHOLD", swaps, rejected_key)) |value| {
            config.rename_inline_threshold = value;
        }
        if (try parse_knob(env, "DMOZDB_REPAIR_WORKER_INTERVAL_MS", any, rejected_key)) |value| {
            config.repair_worker_interval_ms = value;
        }
        if (try parse_knob(env, "DMOZDB_REPAIR_WORKER_CHUNK_SIZE", swaps, rejected_key)) |value| {
            config.repair_worker_chunk_size = value;
        }
        if (try parse_knob(env, "DMOZDB_VERIFIER_INTERVAL_S", any, rejected_key)) |value| {
            config.verifier_interval_s = value;
        }
        if (try parse_knob(env, "DMOZDB_SCRATCH_SLAB_MB", slab, rejected_key)) |value| {
            config.scratch_slab_mb = value;
        }
        assert(config.server.thread_count <= thread_count_max);
        assert(config.server.cache_size_mb <= cache_size_mb_max);
        assert(config.rename_inline_threshold <= changeset.swaps_per_change_set_max);
        assert(config.repair_worker_chunk_size <= changeset.swaps_per_change_set_max);
        return config;
    }

    fn check_server_env(
        env: *const std.process.Environ.Map,
        rejected_key: *[]const u8,
    ) EnvironmentError!void {
        const any: Range = .{ .min = 0, .max = std.math.maxInt(u32) };
        const port: Range = .{ .min = 0, .max = std.math.maxInt(u16) };
        const cache: Range = .{ .min = 1, .max = cache_size_mb_max };
        const threads: Range = .{ .min = 0, .max = thread_count_max };
        _ = try parse_knob(env, "DMOZDB_PORT", port, rejected_key);
        _ = try parse_knob(env, "DMOZDB_CACHE_SIZE_MB", cache, rejected_key);
        _ = try parse_knob(env, "DMOZDB_THREAD_COUNT", threads, rejected_key);
        _ = try parse_knob(env, "DMOZDB_SNAPSHOT_INTERVAL_S", any, rejected_key);
        _ = try parse_knob(env, "DMOZDB_WAL_SYNC_INTERVAL_MS", any, rejected_key);
        _ = try parse_knob(env, "DMOZDB_WAL_BATCH_SIZE", any, rejected_key);
        assert(port.max == std.math.maxInt(u16));
        assert(cache.max == cache_size_mb_max);
    }

    const Range = struct { min: u32, max: u32 };

    fn parse_knob(
        env: *const std.process.Environ.Map,
        comptime key: []const u8,
        range: Range,
        rejected_key: *[]const u8,
    ) EnvironmentError!?u32 {
        comptime assert(std.mem.startsWith(u8, key, "DMOZDB_"));
        assert(range.min <= range.max);
        const value = env.get(key) orelse return null;
        const parsed = std.fmt.parseInt(u32, value, 10) catch return reject(rejected_key, key);
        if (parsed < range.min) return reject(rejected_key, key);
        if (parsed > range.max) return reject(rejected_key, key);
        return parsed;
    }

    fn reject(rejected_key: *[]const u8, key: []const u8) EnvironmentError {
        assert(key.len > "DMOZDB_".len);
        assert(std.mem.startsWith(u8, key, "DMOZDB_"));
        rejected_key.* = key;
        return EnvironmentError.InvalidEnvironment;
    }
};

test {
    _ = schema;
    _ = operations;
    _ = directory;
    _ = binary_protocol;
    _ = subtree;
    _ = verifier;
    _ = @import("wal/wal_apply.zig");
    _ = @import("e2e_test.zig");
    _ = @import("tidy.zig");
    _ = @import("scratch.zig");
    _ = @import("changeset.zig");
    _ = @import("apply/apply.zig");
    _ = @import("apply/apply_link.zig");
    _ = @import("apply/apply_category.zig");
    _ = @import("apply/apply_repair.zig");
    _ = @import("repair/repair_worker.zig");
    _ = @import("operations/operations_shared.zig");
    _ = @import("operations/operations_changeset_compute.zig");
    _ = @import("operations/operations_category.zig");
    _ = @import("operations/operations_link.zig");
    _ = @import("operations/operations_search.zig");
    _ = @import("operations/operations_slug.zig");
    _ = @import("operations/operations_vector.zig");
    _ = @import("operations/operations_facts.zig");
    _ = @import("repair/repair.zig");
    _ = @import("header_upgrade.zig");
    _ = @import("ranking.zig");
    _ = @import("vector_index.zig");
    _ = vector_model;
    _ = @import("ivf_index.zig");
    _ = @import("facts/countries.zig");
    _ = @import("facts/url_facts.zig");
    _ = @import("facts/adjacency.zig");
    _ = @import("facts/sites.zig");
    _ = @import("facts/facts_index.zig");
    _ = @import("facts/entities.zig");
    _ = @import("derived_snapshot.zig");
    _ = @import("status_counts_test.zig");
}

// Goal: the documented defaults are the real defaults. Method: compare a default Config field
// by field with the values the deployment docs promise.
test "Config: every tuning knob has its documented default" {
    const default_config = Config{};
    try std.testing.expectEqual(@as(u32, 5000), default_config.rename_inline_threshold);
    try std.testing.expectEqual(@as(u32, 1000), default_config.repair_worker_interval_ms);
    try std.testing.expectEqual(@as(u32, 1000), default_config.repair_worker_chunk_size);
    try std.testing.expectEqual(@as(u32, 300), default_config.verifier_interval_s);
    try std.testing.expectEqualStrings(
        "/usr/local/share/dmozdb/vector_model.bin",
        default_config.vector_model,
    );
}

fn put_environment(
    env: *std.process.Environ.Map,
    pairs: []const [2][]const u8,
) !void {
    assert(pairs.len > 0);
    for (pairs) |pair| try env.put(pair[0], pair[1]);
    assert(env.count() >= pairs.len);
}

// Goal: every knob the environment sets reaches the config. Method: one map with a value for
// each tuning knob, then compare field by field.
test "Config.from_env: reads every knob it is given" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try put_environment(&env, &.{
        .{ "DMOZDB_PORT", "9090" },
        .{ "DMOZDB_BIND", "0.0.0.0" },
        .{ "DMOZDB_CACHE_SIZE_MB", std.fmt.comptimePrint("{d}", .{cache_size_mb_max}) },
        .{ "DMOZDB_THREAD_COUNT", "64" },
        .{ "DMOZDB_DATA_DIR", "/srv/dmozdb" },
        .{ "DMOZDB_RENAME_INLINE_THRESHOLD", "7" },
        .{ "DMOZDB_VERIFIER_INTERVAL_S", "60" },
        .{ "DMOZDB_SCRATCH_SLAB_MB", "8" },
    });
    var rejected_key: []const u8 = "";
    const config = try Config.from_env(&env, &rejected_key);
    try std.testing.expectEqual(@as(u16, 9090), config.server.port);
    try std.testing.expectEqual([4]u8{ 0, 0, 0, 0 }, config.server.bind_address);
    try std.testing.expectEqual(cache_size_mb_max, config.server.cache_size_mb);
    try std.testing.expectEqual(thread_count_max, config.server.thread_count);
    try std.testing.expectEqualStrings("/srv/dmozdb", config.data_dir);
    try std.testing.expectEqual(@as(u32, 7), config.rename_inline_threshold);
    try std.testing.expectEqual(@as(u32, 60), config.verifier_interval_s);
    try std.testing.expectEqual(@as(u32, 8), config.scratch_slab_mb);
    try std.testing.expectEqualStrings("", rejected_key);
}

// Goal: a knob that does not parse or is out of range stops start-up with the variable's name
// instead of a silent default. Method: one map per bad value, each refused, naming its key.
test "Config.from_env: refuses an unparseable or out-of-range knob by name" {
    const cases = [_][2][]const u8{
        .{ "DMOZDB_PORT", "70000" },
        .{ "DMOZDB_PORT", "-1" },
        .{ "DMOZDB_BIND", "1.2.3" },
        .{ "DMOZDB_CACHE_SIZE_MB", std.fmt.comptimePrint("{d}", .{cache_size_mb_max + 1}) },
        .{ "DMOZDB_CACHE_SIZE_MB", "0" },
        .{ "DMOZDB_THREAD_COUNT", "65" },
        .{ "DMOZDB_THREAD_COUNT", "4294967295" },
        .{ "DMOZDB_WAL_BATCH_SIZE", "many" },
        .{ "DMOZDB_DATA_DIR", "" },
        .{ "DMOZDB_VERIFIER_INTERVAL_S", "5m" },
        .{ "DMOZDB_SCRATCH_SLAB_MB", "0" },
        .{ "DMOZDB_SCRATCH_SLAB_MB", "1025" },
        .{
            "DMOZDB_RENAME_INLINE_THRESHOLD",
            std.fmt.comptimePrint("{d}", .{changeset.swaps_per_change_set_max + 1}),
        },
        .{
            "DMOZDB_REPAIR_WORKER_CHUNK_SIZE",
            std.fmt.comptimePrint("{d}", .{changeset.swaps_per_change_set_max + 1}),
        },
    };
    for (cases) |case| {
        var env = std.process.Environ.Map.init(std.testing.allocator);
        defer env.deinit();
        try put_environment(&env, &.{case});
        var rejected_key: []const u8 = "";
        try std.testing.expectError(
            error.InvalidEnvironment,
            Config.from_env(&env, &rejected_key),
        );
        try std.testing.expectEqualStrings(case[0], rejected_key);
    }
}

// Goal: a relative DMOZDB_DATA_DIR, as in the README quickstart, opens the store instead of
// tripping the std assertion in the `*Absolute` file calls. Method: a path relative to the
// working directory, resolved as main does, then a full open, recover and close on it.
test "a relative DMOZDB_DATA_DIR resolves to an absolute directory the store opens" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var relative_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const relative = try std.fmt.bufPrint(
        &relative_buffer,
        ".zig-cache/tmp/{s}/data",
        .{temporary_directory.sub_path},
    );
    try std.testing.expect(!std.fs.path.isAbsolute(relative));

    const data_dir = try resolve_data_dir(std.testing.io, allocator, relative);
    defer allocator.free(data_dir);
    try std.testing.expect(std.fs.path.isAbsolute(data_dir));

    const model = try vector_model.Model.synthetic(allocator, 1);
    defer model.deinit(allocator);
    const db = try Directory.init(std.testing.io, allocator, .{
        .data_dir = data_dir,
        .server = .{ .cache_size_mb = 16, .thread_count = 1, .wal_batch_size = 32 },
    }, model);
    defer db.deinit();
    try db.recover();
}

// Goal: a DMOZDB_DATA_DIR whose last component is a symlink to a directory still resolves, as
// it did before the data dir was resolved in main. Method: a real directory and a link to it,
// resolved through the link; the result is the real directory's absolute path.
test "a symlinked DMOZDB_DATA_DIR resolves to the directory it points at" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    try temporary_directory.dir.createDir(std.testing.io, "data", .default_dir);
    try temporary_directory.dir.symLink(std.testing.io, "data", "link", .{ .is_directory = true });

    var link_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(
        &link_buffer,
        ".zig-cache/tmp/{s}/link",
        .{temporary_directory.sub_path},
    );
    const data_dir = try resolve_data_dir(std.testing.io, allocator, link);
    defer allocator.free(data_dir);
    try std.testing.expect(std.fs.path.isAbsolute(data_dir));
    try std.testing.expectEqualStrings("data", std.fs.path.basename(data_dir));
}
