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

const Directory = directory.Directory;

const log = std.log.scoped(.dmozdb);

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const config = Config.from_env(init.environ_map);

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

pub const Config = struct {
    server: zigstore.ServerConfig = .{},
    data_dir: []const u8 = "/var/lib/dmozdb",
    rename_inline_threshold: u32 = 5000,
    repair_worker_interval_ms: u32 = 1000,
    repair_worker_chunk_size: u32 = 10000,
    verifier_interval_s: u32 = 300,
    vector_model: []const u8 = "/usr/local/share/dmozdb/vector_model.bin",
    scratch_slab_mb: u32 = 32,

    // A knob that fails to parse keeps its default: the environment is operating input, so it
    // is tolerated and logged by the caller, never asserted.
    pub fn from_env(env: *const std.process.Environ.Map) Config {
        var config = Config{ .server = zigstore.ServerConfig.fromEnv("DMOZDB_", env) };
        if (env.get("DMOZDB_DATA_DIR")) |value| {
            config.data_dir = value;
        }
        if (env.get("DMOZDB_VECTOR_MODEL")) |value| {
            config.vector_model = value;
        }
        if (env.get("DMOZDB_RENAME_INLINE_THRESHOLD")) |value| {
            const parsed = std.fmt.parseInt(u32, value, 10);
            config.rename_inline_threshold = parsed catch config.rename_inline_threshold;
        }
        if (env.get("DMOZDB_REPAIR_WORKER_INTERVAL_MS")) |value| {
            const parsed = std.fmt.parseInt(u32, value, 10);
            config.repair_worker_interval_ms = parsed catch config.repair_worker_interval_ms;
        }
        if (env.get("DMOZDB_REPAIR_WORKER_CHUNK_SIZE")) |value| {
            const parsed = std.fmt.parseInt(u32, value, 10);
            config.repair_worker_chunk_size = parsed catch config.repair_worker_chunk_size;
        }
        if (env.get("DMOZDB_VERIFIER_INTERVAL_S")) |value| {
            const parsed = std.fmt.parseInt(u32, value, 10);
            config.verifier_interval_s = parsed catch config.verifier_interval_s;
        }
        if (env.get("DMOZDB_SCRATCH_SLAB_MB")) |value| {
            const parsed = std.fmt.parseInt(u32, value, 10) catch config.scratch_slab_mb;
            config.scratch_slab_mb = @min(@max(parsed, scratch_slab_mb_min), scratch_slab_mb_max);
        }
        return config;
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
    _ = @import("facts/sites.zig");
    _ = @import("facts/facts_index.zig");
    _ = @import("facts/entities.zig");
}

// Goal: the documented defaults are the real defaults. Method: compare a default Config field
// by field with the values the deployment docs promise.
test "Config: every tuning knob has its documented default" {
    const default_config = Config{};
    try std.testing.expectEqual(@as(u32, 5000), default_config.rename_inline_threshold);
    try std.testing.expectEqual(@as(u32, 1000), default_config.repair_worker_interval_ms);
    try std.testing.expectEqual(@as(u32, 10000), default_config.repair_worker_chunk_size);
    try std.testing.expectEqual(@as(u32, 300), default_config.verifier_interval_s);
    try std.testing.expectEqualStrings(
        "/usr/local/share/dmozdb/vector_model.bin",
        default_config.vector_model,
    );
}
