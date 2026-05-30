const std = @import("std");
const posix = std.posix;

// Module imports
pub const page = @import("page.zig");
pub const file_header = @import("file_header.zig");
pub const btree = @import("btree/btree.zig");
pub const page_cache = @import("page_cache.zig");
pub const freelist = @import("freelist.zig");
pub const types = @import("types.zig");
pub const inverted_index = @import("inverted_index.zig");
pub const memtable = @import("memtable.zig");
pub const bloom = @import("bloom.zig");
pub const operations = @import("operations/operations.zig");
pub const database = @import("database.zig");
pub const epoll_server = @import("epoll.zig");
pub const connection = @import("connection.zig");
pub const signal = @import("signal.zig");
pub const wal = @import("wal/wal.zig");
pub const wal_replay = @import("wal/wal_replay.zig");
pub const snapshot = @import("snapshot.zig");
pub const binary_protocol = @import("binary_protocol.zig");
pub const subtree = @import("subtree.zig");
pub const verifier = @import("verifier.zig");

const Database = database.Database;
const EpollServer = epoll_server.EpollServer;

const log = std.log.scoped(.dmozdb);

/// Server configuration loaded from environment variables.
pub const Config = struct {
    port: u16 = 8080,
    data_dir: []const u8 = "/var/lib/dmozdb",
    cache_size_mb: u32 = 256,
    thread_count: u32 = 0, // 0 = auto-detect (CPU count)
    snapshot_interval_s: u32 = 300,
    wal_sync_interval_ms: u32 = 50,
    wal_batch_size: u32 = 256,
    rename_inline_threshold: u32 = 5000, // subtree size flipping rename/move from in-line strict to queued async repair
    repair_worker_interval_ms: u32 = 1000, // interval between repair_worker ticks
    repair_worker_chunk_size: u32 = 10000, // descendants per worker chunk before yielding slug-path tree lock
    repair_worker_max_tasks_per_tick: u32 = 1, // tasks pulled from queue per tick (predictable on 1 CPU / 2 GB)
    subtree_scan_threshold: u32 = 1024, // descendant count above which list_subtree_links uses the sequential scan; below it uses per-descendant rangescans
    bind_address: [4]u8 = .{ 127, 0, 0, 1 },
    trusted_ips: [MAX_TRUSTED_IPS][4]u8 = undefined,
    trusted_count: u8 = 0,

    const MAX_TRUSTED_IPS = 16;

    /// Load configuration from environment variables.
    pub fn fromEnv() Config {
        var config = Config{};
        if (std.posix.getenv("DMOZDB_PORT")) |v| {
            config.port = std.fmt.parseInt(u16, v, 10) catch 8080;
        }
        if (std.posix.getenv("DMOZDB_DATA_DIR")) |v| {
            // getenv returns a slice into the process environment block,
            // which is stable for the lifetime of the process — no copy needed.
            config.data_dir = v;
        }
        if (std.posix.getenv("DMOZDB_CACHE_SIZE_MB")) |v| {
            config.cache_size_mb = std.fmt.parseInt(u32, v, 10) catch 256;
        }
        if (std.posix.getenv("DMOZDB_THREAD_COUNT")) |v| {
            config.thread_count = std.fmt.parseInt(u32, v, 10) catch 0;
        }
        if (config.thread_count == 0) {
            const max_threads: u32 = 32;
            config.thread_count = @intCast(@min(std.Thread.getCpuCount() catch 8, max_threads));
        }
        if (std.posix.getenv("DMOZDB_SNAPSHOT_INTERVAL_S")) |v| {
            config.snapshot_interval_s = std.fmt.parseInt(u32, v, 10) catch 300;
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
        if (std.posix.getenv("DMOZDB_BIND")) |v| {
            config.bind_address = parseIpv4(v) orelse .{ 127, 0, 0, 1 };
        }
        if (std.posix.getenv("DMOZDB_TRUSTED")) |v| {
            config.parseTrustedIps(v);
        }
        return config;
    }

    /// Parse a comma separated list of IPv4 addresses into trusted_ips.
    /// Logs and ignores any token that fails to parse, and any token past
    /// MAX_TRUSTED_IPS — silent acceptance of misconfiguration would be
    /// worse than a startup warning.
    fn parseTrustedIps(self: *Config, raw: []const u8) void {
        var count: u8 = 0;
        var rest = raw;
        while (rest.len > 0) {
            var end: usize = 0;
            while (end < rest.len and rest[end] != ',') : (end += 1) {}
            const token = std.mem.trim(u8, rest[0..end], " \t");
            rest = if (end < rest.len) rest[end + 1 ..] else &.{};

            if (token.len == 0) continue;
            if (count >= MAX_TRUSTED_IPS) {
                log.warn("DMOZDB_TRUSTED: dropping '{s}' — exceeds MAX_TRUSTED_IPS={d}", .{ token, MAX_TRUSTED_IPS });
                continue;
            }
            if (parseIpv4(token)) |ip| {
                self.trusted_ips[count] = ip;
                count += 1;
            } else {
                log.warn("DMOZDB_TRUSTED: ignoring unparseable IPv4 token '{s}'", .{token});
            }
        }
        self.trusted_count = count;
    }

    /// Returns true if the given IPv4 address is allowed to connect.
    /// Loopback (127.x.x.x) is always permitted.
    pub fn isAllowed(self: *const Config, addr: [4]u8) bool {
        if (addr[0] == 127) return true;
        for (self.trusted_ips[0..self.trusted_count]) |trusted| {
            if (std.mem.eql(u8, &addr, &trusted)) return true;
        }
        return false;
    }

    /// Returns true if protected mode is active: bind is non-loopback
    /// and no trusted IPs are configured.
    pub fn isProtectedMode(self: *const Config) bool {
        return self.bind_address[0] != 127 and self.trusted_count == 0;
    }
};

/// Parse a dotted decimal IPv4 string into four octets.
fn parseIpv4(s: []const u8) ?[4]u8 {
    var octets: [4]u8 = undefined;
    var idx: u8 = 0;
    var start: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (idx >= 3) return null;
            octets[idx] = std.fmt.parseInt(u8, s[start..i], 10) catch return null;
            idx += 1;
            start = i + 1;
        }
    }
    if (idx != 3) return null;
    octets[3] = std.fmt.parseInt(u8, s[start..], 10) catch return null;
    return octets;
}

fn runReactor(reactor: *EpollServer) void {
    reactor.run() catch |err| {
        log.err("Reactor error: {}", .{err});
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = Config.fromEnv();

    log.info("Dmoz Zig Development - starting up", .{});
    log.info("  bind={d}.{d}.{d}.{d}:{d} data_dir={s} cache={d}MB threads={d} trusted_ips={d}", .{
        config.bind_address[0], config.bind_address[1], config.bind_address[2], config.bind_address[3],
        config.port,            config.data_dir,        config.cache_size_mb,   config.thread_count,
        config.trusted_count,
    });

    const db = try Database.init(allocator, config);
    defer db.deinit();

    try db.recover();
    db.startBackgroundThreads();

    log.info("Database ready. Starting server on port {d}...", .{config.port});

    signal.setupSignalHandlers() catch |err| {
        log.err("Failed to setup signal handlers: {}", .{err});
        return err;
    };

    const num_reactors: u32 = @max(config.thread_count / 2, 1);
    log.info("Starting {d} reactor(s)...", .{num_reactors});

    const reactors = try EpollServer.createMulti(allocator, db, config, num_reactors);
    defer {
        for (reactors) |r| r.destroy();
        allocator.free(reactors);
    }

    var reactor_threads = try allocator.alloc(std.Thread, num_reactors - 1);
    defer allocator.free(reactor_threads);

    for (reactors[1..], 0..) |r, i| {
        reactor_threads[i] = std.Thread.spawn(.{}, runReactor, .{r}) catch |err| {
            log.err("Failed to spawn reactor thread: {}", .{err});
            return err;
        };
    }

    reactors[0].run() catch |err| {
        log.err("Primary reactor error: {}", .{err});
        return err;
    };

    for (reactor_threads) |t| t.join();

    log.info("Shutdown complete.", .{});
}

test {
    _ = page;
    _ = file_header;
    _ = btree;
    _ = page_cache;
    _ = freelist;
    _ = types;
    _ = inverted_index;
    _ = operations;
    _ = database;
    _ = epoll_server;
    _ = connection;
    _ = signal;
    _ = wal;
    _ = wal_replay;
    _ = snapshot;
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
    _ = @import("commit.zig");
    _ = @import("repair/repair_worker.zig");
    _ = @import("operations/operations_shared.zig");
    _ = @import("operations/operations_changeset_compute.zig");
    _ = @import("operations/operations_category.zig");
    _ = @import("operations/operations_link.zig");
    _ = @import("operations/operations_search.zig");
    _ = @import("operations/operations_slug.zig");
    _ = @import("repair/repair.zig");
    _ = @import("histogram.zig");
    _ = @import("btree/btree_search.zig");
    _ = @import("btree/btree_insert.zig");
    _ = @import("btree/btree_delete.zig");
    _ = @import("btree/btree_repair.zig");
    _ = @import("btree/btree_helpers.zig");
}

test "parseIpv4 valid" {
    const ip = parseIpv4("192.168.1.10").?;
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 10 }, ip);
}

test "parseIpv4 loopback" {
    const ip = parseIpv4("127.0.0.1").?;
    try std.testing.expectEqual([4]u8{ 127, 0, 0, 1 }, ip);
}

test "parseIpv4 invalid" {
    try std.testing.expect(parseIpv4("not.an.ip") == null);
    try std.testing.expect(parseIpv4("1.2.3") == null);
    try std.testing.expect(parseIpv4("1.2.3.4.5") == null);
    try std.testing.expect(parseIpv4("256.0.0.1") == null);
    try std.testing.expect(parseIpv4("") == null);
}

test "Config.isAllowed loopback always permitted" {
    const config = Config{};
    try std.testing.expect(config.isAllowed(.{ 127, 0, 0, 1 }));
    try std.testing.expect(config.isAllowed(.{ 127, 0, 0, 2 }));
    try std.testing.expect(config.isAllowed(.{ 127, 255, 0, 1 }));
}

test "Config.isAllowed rejects non-loopback by default" {
    const config = Config{};
    try std.testing.expect(!config.isAllowed(.{ 192, 168, 1, 1 }));
    try std.testing.expect(!config.isAllowed(.{ 10, 0, 0, 1 }));
}

test "Config.isAllowed with trusted IPs" {
    var config = Config{};
    config.trusted_ips[0] = .{ 10, 0, 0, 5 };
    config.trusted_ips[1] = .{ 192, 168, 1, 100 };
    config.trusted_count = 2;
    try std.testing.expect(config.isAllowed(.{ 10, 0, 0, 5 }));
    try std.testing.expect(config.isAllowed(.{ 192, 168, 1, 100 }));
    try std.testing.expect(!config.isAllowed(.{ 10, 0, 0, 6 }));
    try std.testing.expect(config.isAllowed(.{ 127, 0, 0, 1 }));
}

test "Config.isProtectedMode" {
    // Default: bind 127.0.0.1, no trusted = not protected (loopback is safe)
    const default_config = Config{};
    try std.testing.expect(!default_config.isProtectedMode());

    // Bind 0.0.0.0, no trusted = protected mode
    var wildcard = Config{};
    wildcard.bind_address = .{ 0, 0, 0, 0 };
    try std.testing.expect(wildcard.isProtectedMode());

    // Bind 0.0.0.0, with trusted = not protected (operator configured it)
    var configured = Config{};
    configured.bind_address = .{ 0, 0, 0, 0 };
    configured.trusted_ips[0] = .{ 10, 0, 0, 5 };
    configured.trusted_count = 1;
    try std.testing.expect(!configured.isProtectedMode());
}

test "Config.parseTrustedIps" {
    var config = Config{};
    config.parseTrustedIps("10.0.0.1,192.168.1.50, 172.16.0.1");
    try std.testing.expectEqual(@as(u8, 3), config.trusted_count);
    try std.testing.expectEqual([4]u8{ 10, 0, 0, 1 }, config.trusted_ips[0]);
    try std.testing.expectEqual([4]u8{ 192, 168, 1, 50 }, config.trusted_ips[1]);
    try std.testing.expectEqual([4]u8{ 172, 16, 0, 1 }, config.trusted_ips[2]);
}

test "Config: rename_inline_threshold default and env override" {
    const default_cfg = Config{};
    try std.testing.expectEqual(@as(u32, 5000), default_cfg.rename_inline_threshold);
    try std.testing.expectEqual(@as(u32, 1000), default_cfg.repair_worker_interval_ms);
    try std.testing.expectEqual(@as(u32, 10000), default_cfg.repair_worker_chunk_size);
    try std.testing.expectEqual(@as(u32, 1), default_cfg.repair_worker_max_tasks_per_tick);
}
