const std = @import("std");
const zigstore = @import("zigstore");

pub const schema = @import("schema.zig");
pub const operations = @import("operations/operations.zig");
pub const directory = @import("directory.zig");
pub const binary_protocol = @import("binary_protocol.zig");
pub const subtree = @import("subtree.zig");
pub const verifier = @import("verifier.zig");
pub const vector_model = @import("vector_model.zig");

const Directory = directory.Directory;

const log = std.log.scoped(.dmozdb);

pub const Config = struct {
    server: zigstore.ServerConfig = .{},
    data_dir: []const u8 = "/var/lib/dmozdb",
    rename_inline_threshold: u32 = 5000,
    repair_worker_interval_ms: u32 = 1000,
    repair_worker_chunk_size: u32 = 10000,
    verifier_interval_s: u32 = 300,
    vector_model: []const u8 = "/usr/local/share/dmozdb/vector_model.bin",

    pub fn fromEnv(env: *const std.process.Environ.Map) Config {
        var config = Config{ .server = zigstore.ServerConfig.fromEnv("DMOZDB_", env) };
        if (env.get("DMOZDB_DATA_DIR")) |v| {
            config.data_dir = v;
        }
        if (env.get("DMOZDB_VECTOR_MODEL")) |v| {
            config.vector_model = v;
        }
        if (env.get("DMOZDB_RENAME_INLINE_THRESHOLD")) |v| {
            config.rename_inline_threshold = std.fmt.parseInt(u32, v, 10) catch config.rename_inline_threshold;
        }
        if (env.get("DMOZDB_REPAIR_WORKER_INTERVAL_MS")) |v| {
            config.repair_worker_interval_ms = std.fmt.parseInt(u32, v, 10) catch config.repair_worker_interval_ms;
        }
        if (env.get("DMOZDB_REPAIR_WORKER_CHUNK_SIZE")) |v| {
            config.repair_worker_chunk_size = std.fmt.parseInt(u32, v, 10) catch config.repair_worker_chunk_size;
        }
        if (env.get("DMOZDB_VERIFIER_INTERVAL_S")) |v| {
            config.verifier_interval_s = std.fmt.parseInt(u32, v, 10) catch config.verifier_interval_s;
        }
        return config;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const config = Config.fromEnv(init.environ_map);

    log.info("Dmoz Zig Development - starting up", .{});
    log.info("  bind={d}.{d}.{d}.{d}:{d} data_dir={s} cache={d}MB threads={d} trusted_ips={d}", .{
        config.server.bind_address[0], config.server.bind_address[1], config.server.bind_address[2], config.server.bind_address[3],
        config.server.port,            config.data_dir,               config.server.cache_size_mb,   config.server.thread_count,
        config.server.trusted_count,
    });

    const pq = vector_model.Model.load(init.io, allocator, config.vector_model) catch |err| {
        log.err("vector model {s} failed to load: {} — set DMOZDB_VECTOR_MODEL to the file the image ships", .{ config.vector_model, err });
        return err;
    };
    defer pq.deinit(allocator);
    log.info("  vector model {s} hash={x}", .{ config.vector_model, pq.hash });

    const db = try Directory.init(init.io, allocator, config, pq);
    defer db.deinit();

    try db.recover();
    db.startBackgroundThreads();

    log.info("Database ready. Starting server on port {d}...", .{config.server.port});

    try zigstore.run(directory.Store, db, Directory.handler(), config.server, .{});
}

test {
    _ = schema;
    _ = operations;
    _ = directory;
    _ = binary_protocol;
    _ = subtree;
    _ = verifier;
    _ = @import("wal/wal_apply.zig");
    _ = @import("e2e_test.zig");
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
    _ = @import("facts/sites.zig");
    _ = @import("facts/facts_index.zig");
    _ = @import("facts/entities.zig");
}

test "Config: every tuning knob has its documented default" {
    const default_cfg = Config{};
    try std.testing.expectEqual(@as(u32, 5000), default_cfg.rename_inline_threshold);
    try std.testing.expectEqual(@as(u32, 1000), default_cfg.repair_worker_interval_ms);
    try std.testing.expectEqual(@as(u32, 10000), default_cfg.repair_worker_chunk_size);
    try std.testing.expectEqual(@as(u32, 300), default_cfg.verifier_interval_s);
    try std.testing.expectEqualStrings("/usr/local/share/dmozdb/vector_model.bin", default_cfg.vector_model);
}
