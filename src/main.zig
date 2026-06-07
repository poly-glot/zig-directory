const std = @import("std");
const zigstore = @import("zigstore");

pub const schema = @import("schema.zig");
pub const operations = @import("operations/operations.zig");
pub const directory = @import("directory.zig");
pub const binary_protocol = @import("binary_protocol.zig");
pub const subtree = @import("subtree.zig");
pub const verifier = @import("verifier.zig");

const Directory = directory.Directory;

const log = std.log.scoped(.dmozdb);

pub const Config = struct {
    server: zigstore.ServerConfig = .{},
    data_dir: []const u8 = "/var/lib/dmozdb",
    rename_inline_threshold: u32 = 5000,
    repair_worker_interval_ms: u32 = 1000,
    repair_worker_chunk_size: u32 = 10000,
    repair_worker_max_tasks_per_tick: u32 = 1,
    subtree_scan_threshold: u32 = 1024,

    pub fn fromEnv() Config {
        var config = Config{ .server = zigstore.ServerConfig.fromEnv("DMOZDB_") };
        if (std.posix.getenv("DMOZDB_DATA_DIR")) |v| {
            config.data_dir = v;
        }
        if (std.posix.getenv("DMOZDB_RENAME_INLINE_THRESHOLD")) |v| {
            config.rename_inline_threshold = std.fmt.parseInt(u32, v, 10) catch 5000;
        }
        if (std.posix.getenv("DMOZDB_REPAIR_WORKER_INTERVAL_MS")) |v| {
            config.repair_worker_interval_ms = std.fmt.parseInt(u32, v, 10) catch 1000;
        }
        if (std.posix.getenv("DMOZDB_REPAIR_WORKER_CHUNK_SIZE")) |v| {
            config.repair_worker_chunk_size = std.fmt.parseInt(u32, v, 10) catch 10000;
        }
        if (std.posix.getenv("DMOZDB_REPAIR_WORKER_MAX_TASKS_PER_TICK")) |v| {
            config.repair_worker_max_tasks_per_tick = std.fmt.parseInt(u32, v, 10) catch 1;
        }
        if (std.posix.getenv("DMOZDB_SUBTREE_SCAN_THRESHOLD")) |v| {
            config.subtree_scan_threshold = std.fmt.parseInt(u32, v, 10) catch 1024;
        }
        return config;
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.fromEnv();

    log.info("Dmoz Zig Development - starting up", .{});
    log.info("  bind={d}.{d}.{d}.{d}:{d} data_dir={s} cache={d}MB threads={d} trusted_ips={d}", .{
        config.server.bind_address[0], config.server.bind_address[1], config.server.bind_address[2], config.server.bind_address[3],
        config.server.port,            config.data_dir,               config.server.cache_size_mb,   config.server.thread_count,
        config.server.trusted_count,
    });

    const db = try Directory.init(allocator, config);
    defer db.deinit();

    try db.recover();
    db.startBackgroundThreads();

    log.info("Database ready. Starting server on port {d}...", .{config.server.port});

    try zigstore.run(directory.Store, db, Directory.handler(), config.server);
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
    _ = @import("repair/repair.zig");
}

test "Config: rename_inline_threshold default and env override" {
    const default_cfg = Config{};
    try std.testing.expectEqual(@as(u32, 5000), default_cfg.rename_inline_threshold);
    try std.testing.expectEqual(@as(u32, 1000), default_cfg.repair_worker_interval_ms);
    try std.testing.expectEqual(@as(u32, 10000), default_cfg.repair_worker_chunk_size);
    try std.testing.expectEqual(@as(u32, 1), default_cfg.repair_worker_max_tasks_per_tick);
}
