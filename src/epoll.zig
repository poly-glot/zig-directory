const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const conn_mod = @import("connection.zig");
const signal = @import("signal.zig");
const Database = @import("database.zig").Database;
const Config = @import("main.zig").Config;
const binary_protocol = @import("binary_protocol.zig");

const log = std.log.scoped(.epoll);

pub const MAX_CONNECTIONS = 4096;
const MAX_EVENTS = 64;

/// Number of I/O buffer pairs kept in the pool.
/// Only connections actively reading or writing hold a buffer.
pub const BUFFER_POOL_SIZE: u16 = 256;

/// Connection idle timeout in seconds.
const CONNECTION_TIMEOUT_S: i64 = 30;

pub const EpollServer = struct {
    allocator: std.mem.Allocator,
    db: *Database,
    config: Config,
    epoll_fd: posix.fd_t,
    listen_fd: posix.fd_t,
    connections: [MAX_CONNECTIONS]conn_mod.Connection,

    // O(1) fd -> slot index mapping. Only accessed by the epoll thread.
    fd_to_slot: std.AutoHashMap(posix.fd_t, u16),

    // O(1) free connection slot stack. Only accessed by the epoll thread.
    free_slot_stack: []u16,
    free_slot_count: u32,

    // Buffer pool — avoids large upfront allocation.
    buffer_pairs: []conn_mod.BufferPair,
    free_stack: []u16,
    free_count: u32,
    buf_pool_size: u32,

    // Binary connections with pending responses — written in a batch after
    // all readable events are processed (Redis-style event loop).
    binary_write_fds: [MAX_CONNECTIONS]posix.fd_t = undefined,
    binary_write_count: u32 = 0,

    const Self = @This();

    /// Create N reactors. Each reactor has its own listen socket (SO_REUSEPORT),
    /// epoll fd, and connections. Kernel distributes incoming connections.
    pub fn createMulti(allocator: std.mem.Allocator, db: *Database, config: Config, count: u32) ![]*Self {
        const reactors = try allocator.alloc(*Self, count);
        errdefer allocator.free(reactors);
        for (reactors, 0..) |*rp, i| {
            rp.* = try createOne(allocator, db, config, i == 0);
        }
        return reactors;
    }

    pub fn create(allocator: std.mem.Allocator, db: *Database, config: Config) !*Self {
        return createOne(allocator, db, config, true);
    }

    fn createOne(allocator: std.mem.Allocator, db: *Database, config: Config, register_shutdown: bool) !*Self {
        // 1. Create binary protocol listen socket (non-blocking).
        const listen_fd = try posix.socket(
            posix.AF.INET,
            @as(u32, posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC),
            0,
        );
        errdefer posix.close(listen_fd);

        // 2. Set SO_REUSEADDR and SO_REUSEPORT.
        try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
        try posix.setsockopt(listen_fd, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));

        // 3. Bind to configured address (default 127.0.0.1).
        const addr = std.net.Address.initIp4(config.bind_address, config.port);
        try posix.bind(listen_fd, &addr.any, addr.getOsSockLen());

        // 4. Listen with backlog 4096.
        try posix.listen(listen_fd, 4096);

        // 5. Create epoll instance.
        const epoll_fd = try posix.epoll_create1(linux.EPOLL.CLOEXEC);
        errdefer posix.close(epoll_fd);

        // 6. Register listen socket.
        var listen_event = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .fd = listen_fd },
        };
        try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &listen_event);

        // 7. Register signal shutdown pipe — only on primary reactor.
        if (register_shutdown) {
            const shutdown_fd = signal.getShutdownPipeFd();
            if (shutdown_fd != -1) {
                var shutdown_event = linux.epoll_event{
                    .events = linux.EPOLL.IN,
                    .data = .{ .fd = shutdown_fd },
                };
                try posix.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, shutdown_fd, &shutdown_event);
            }
        }

        // 8. Allocate buffer pool.
        const buf_pool_size: u32 = @max(BUFFER_POOL_SIZE, config.thread_count * 64);
        const buffer_pairs = try allocator.alloc(conn_mod.BufferPair, buf_pool_size);
        errdefer allocator.free(buffer_pairs);
        const buf_free_stack = try allocator.alloc(u16, buf_pool_size);
        errdefer allocator.free(buf_free_stack);

        // 9. Allocate free connection slot stack.
        const slot_stack = try allocator.alloc(u16, MAX_CONNECTIONS);
        errdefer allocator.free(slot_stack);

        // 10. Heap-allocate the server.
        const server = try allocator.create(Self);
        errdefer allocator.destroy(server);

        server.allocator = allocator;
        server.db = db;
        server.config = config;
        server.epoll_fd = epoll_fd;
        server.listen_fd = listen_fd;
        server.buffer_pairs = buffer_pairs;
        server.free_stack = buf_free_stack;
        server.buf_pool_size = buf_pool_size;
        server.fd_to_slot = std.AutoHashMap(posix.fd_t, u16).init(allocator);
        server.free_slot_stack = slot_stack;
        server.binary_write_count = 0;

        // Initialize all connections as empty.
        for (&server.connections) |*c| {
            c.* = conn_mod.Connection{};
        }

        // Initialize free connection slot stack.
        server.free_slot_count = MAX_CONNECTIONS;
        for (0..MAX_CONNECTIONS) |i| {
            server.free_slot_stack[i] = @intCast(i);
        }

        // Initialize buffer free stack.
        server.free_count = buf_pool_size;
        for (0..buf_pool_size) |i| {
            server.free_stack[i] = @intCast(i);
        }

        log.info("Listening on {d}.{d}.{d}.{d}:{d} (epoll fd={d}, listen fd={d}, buffer pool={d})", .{
            config.bind_address[0], config.bind_address[1], config.bind_address[2], config.bind_address[3],
            config.port,            epoll_fd,               listen_fd,              BUFFER_POOL_SIZE,
        });

        if (config.isProtectedMode()) {
            log.warn("PROTECTED MODE: listening on non-loopback address with no trusted IPs configured. " ++
                "Non-loopback connections will be rejected. Set DMOZDB_TRUSTED to allow specific IPs.", .{});
        }

        return server;
    }

    /// Release all resources.
    pub fn destroy(self: *Self) void {
        for (&self.connections) |*c| {
            if (c.isActive() and c.fd != -1) {
                posix.close(c.fd);
                if (c.buf) |bp| self.releaseBuffer(bp);
                c.reset();
            }
        }

        posix.close(self.epoll_fd);
        posix.close(self.listen_fd);
        signal.closeShutdownPipe();

        self.fd_to_slot.deinit();
        const allocator = self.allocator;
        allocator.free(self.free_slot_stack);
        allocator.free(self.free_stack);
        allocator.free(self.buffer_pairs);
        allocator.destroy(self);
    }

    /// Main event loop — two-pass Redis-style design.
    ///   Pass 1: read + parse + execute for all connections.
    ///   Pass 2: flush all pending responses.
    pub fn run(self: *Self) !void {
        var events: [MAX_EVENTS]linux.epoll_event = undefined;
        const shutdown_fd = signal.getShutdownPipeFd();

        log.info("Entering event loop", .{});

        while (!signal.shutdownRequested()) {
            const n = posix.epoll_wait(self.epoll_fd, &events, 1000);

            self.binary_write_count = 0;
            var got_shutdown = false;

            // Pass 1: accepts, reads, system events.
            for (events[0..n]) |ev| {
                const fd = ev.data.fd;

                if (fd == self.listen_fd) {
                    self.acceptConnection();
                } else if (fd == shutdown_fd) {
                    log.info("Shutdown signal received via pipe", .{});
                    got_shutdown = true;
                    break;
                } else {
                    self.handleEvent(fd, ev.events);
                }
            }
            if (got_shutdown) break;

            // Pass 2: flush all pending binary responses.
            self.flushBinaryWrites();

            // Sweep idle connections for timeout enforcement.
            self.sweepIdleConnections();
        }

        log.info("Event loop exiting, flushing database...", .{});
        self.db.flushHeader() catch |err| {
            log.err("Failed to flush database header on shutdown: {}", .{err});
        };
    }

    /// Accept one or more pending connections.
    fn acceptConnection(self: *Self) void {
        while (true) {
            var peer_addr: posix.sockaddr = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr);
            const client_fd = posix.accept(self.listen_fd, &peer_addr, &addr_len, @as(u32, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC)) catch |err| {
                if (err == error.WouldBlock) return;
                log.warn("Accept failed: {}", .{err});
                return;
            };

            // Defense-in-depth: only accept IPv4. The listen socket is
            // created with AF_INET, so any other family here would
            // indicate a misconfiguration; the previous check skipped
            // the allowlist for unknown families instead of rejecting.
            if (peer_addr.family != posix.AF.INET) {
                log.warn("Rejected connection: unexpected address family {d}", .{peer_addr.family});
                posix.close(client_fd);
                continue;
            }
            const in_addr: *const posix.sockaddr.in = @ptrCast(@alignCast(&peer_addr));
            const octets: [4]u8 = @bitCast(in_addr.addr);
            if (!self.config.isAllowed(octets)) {
                log.warn("Protected mode: rejected connection from {d}.{d}.{d}.{d}", .{
                    octets[0], octets[1], octets[2], octets[3],
                });
                posix.close(client_fd);
                continue;
            }

            const free = self.findFreeSlot() orelse {
                if (self.evictIdleConnection()) |_| {
                    const retry_free = self.findFreeSlot() orelse {
                        posix.close(client_fd);
                        continue;
                    };
                    self.setupConnection(client_fd, retry_free.conn, retry_free.idx);
                    continue;
                }
                log.warn("No free connection slots, rejecting fd={d}", .{client_fd});
                posix.close(client_fd);
                continue;
            };

            self.setupConnection(client_fd, free.conn, free.idx);
        }
    }

    fn setupConnection(self: *Self, client_fd: posix.fd_t, slot: *conn_mod.Connection, slot_idx: u16) void {
        // Disable Nagle for low-latency small frames.
        posix.setsockopt(client_fd, posix.IPPROTO.TCP, std.os.linux.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};

        const bp = self.acquireBuffer() orelse {
            log.warn("Buffer pool exhausted, rejecting fd={d} (pool={d})", .{ client_fd, self.buf_pool_size });
            posix.close(client_fd);
            return;
        };

        slot.fd = client_fd;
        slot.phase = .reading_request;
        slot.buf = bp;
        slot.bytes_read = 0;
        slot.last_activity = std.time.timestamp();

        self.fd_to_slot.put(client_fd, slot_idx) catch {
            log.warn("fd_to_slot map full for fd={d}", .{client_fd});
            posix.close(client_fd);
            self.releaseBuffer(bp);
            slot.reset();
            return;
        };

        // Register with epoll for reading.
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ET | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .fd = client_fd },
        };
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, client_fd, &ev) catch {
            log.warn("epoll_ctl ADD failed for fd={d}", .{client_fd});
            posix.close(client_fd);
            _ = self.fd_to_slot.remove(client_fd);
            self.releaseBuffer(bp);
            slot.reset();
        };
    }

    fn handleEvent(self: *Self, fd: posix.fd_t, events: u32) void {
        const conn = self.findConnection(fd) orelse {
            posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null) catch {};
            posix.close(fd);
            return;
        };

        if (events & (linux.EPOLL.ERR | linux.EPOLL.HUP) != 0) {
            self.closeConnection(fd);
            return;
        }

        // Readable — edge-triggered: must drain all available data.
        if (events & linux.EPOLL.IN != 0 and conn.phase == .reading_request) {
            conn.last_activity = std.time.timestamp();
            const bp = conn.buf orelse {
                self.closeConnection(fd);
                return;
            };

            while (true) {
                const remaining = bp.request_buf[conn.bytes_read..];
                if (remaining.len == 0) {
                    log.warn("Request buffer full for fd={d}, closing", .{fd});
                    self.closeConnection(fd);
                    return;
                }

                const n = posix.read(fd, remaining) catch |err| {
                    if (err == error.WouldBlock) break;
                    self.closeConnection(fd);
                    return;
                };

                if (n == 0) {
                    self.closeConnection(fd);
                    return;
                }

                conn.bytes_read += n;

                // Process all complete frames inline (Redis model).
                if (conn.bytes_read >= binary_protocol.HEADER_SIZE) {
                    binary_protocol.processFrames(self.db, conn);
                    if (conn.response_len > 0) {
                        conn.bytes_written = 0;
                        conn.phase = .writing_response;
                        self.binary_write_fds[self.binary_write_count] = fd;
                        self.binary_write_count += 1;
                        return;
                    }
                }
            }
        }

        // Writable — only fires for connections that hit WouldBlock during flush.
        if (events & linux.EPOLL.OUT != 0 and conn.phase == .writing_response) {
            self.finishBinaryWrite(fd, conn);
        }
    }

    /// Flush all pending binary responses in one pass.
    fn flushBinaryWrites(self: *Self) void {
        for (self.binary_write_fds[0..self.binary_write_count]) |fd| {
            const conn = self.findConnection(fd) orelse continue;
            if (conn.phase != .writing_response) continue;
            self.finishBinaryWrite(fd, conn);
        }
        self.binary_write_count = 0;
    }

    /// Write a binary connection's response and transition back to reading.
    fn finishBinaryWrite(self: *Self, fd: posix.fd_t, conn: *conn_mod.Connection) void {
        var done = false;
        while (!done) {
            done = conn.writeChunk() catch {
                self.closeConnection(fd);
                return;
            };
            if (!done) {
                // WouldBlock — arm for EPOLLOUT to retry later.
                self.armForWrite(conn);
                return;
            }
        }

        // Write completed — go back to reading.
        conn.bytes_written = 0;
        conn.response_len = 0;
        conn.phase = .reading_request;
        conn.last_activity = std.time.timestamp();
    }

    fn closeConnection(self: *Self, fd: posix.fd_t) void {
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null) catch {};

        if (self.fd_to_slot.get(fd)) |slot_idx| {
            const conn = &self.connections[slot_idx];
            if (conn.buf) |bp| self.releaseBuffer(bp);
            conn.reset();
            self.returnSlot(slot_idx);
        }

        _ = self.fd_to_slot.remove(fd);
        posix.close(fd);
    }

    fn armForWrite(self: *Self, conn: *conn_mod.Connection) void {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.OUT | linux.EPOLL.ET | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .fd = conn.fd },
        };
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, conn.fd, &ev) catch {
            self.closeConnection(conn.fd);
        };
    }

    fn sweepIdleConnections(self: *Self) void {
        const now = std.time.timestamp();
        for (&self.connections) |*c| {
            if (!c.isActive() or c.fd == -1) continue;
            if (c.phase != .reading_request) continue;
            if (now - c.last_activity > CONNECTION_TIMEOUT_S) {
                self.closeConnection(c.fd);
            }
        }
    }

    fn evictIdleConnection(self: *Self) ?u16 {
        var oldest_time: i64 = std.math.maxInt(i64);
        var oldest_fd: posix.fd_t = -1;

        for (&self.connections) |*c| {
            if (c.phase == .reading_request and c.last_activity < oldest_time) {
                oldest_time = c.last_activity;
                oldest_fd = c.fd;
            }
        }

        if (oldest_fd != -1) {
            const slot_idx = self.fd_to_slot.get(oldest_fd);
            self.closeConnection(oldest_fd);
            return slot_idx;
        }
        return null;
    }

    fn findConnection(self: *Self, fd: posix.fd_t) ?*conn_mod.Connection {
        const slot_idx = self.fd_to_slot.get(fd) orelse return null;
        const conn = &self.connections[slot_idx];
        if (conn.isActive()) return conn;
        return null;
    }

    fn findFreeSlot(self: *Self) ?struct { conn: *conn_mod.Connection, idx: u16 } {
        if (self.free_slot_count == 0) return null;
        self.free_slot_count -= 1;
        const idx = self.free_slot_stack[self.free_slot_count];
        return .{ .conn = &self.connections[idx], .idx = idx };
    }

    fn returnSlot(self: *Self, idx: u16) void {
        self.free_slot_stack[self.free_slot_count] = idx;
        self.free_slot_count += 1;
    }

    fn acquireBuffer(self: *Self) ?*conn_mod.BufferPair {
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const idx = self.free_stack[self.free_count];
        return &self.buffer_pairs[idx];
    }

    fn releaseBuffer(self: *Self, pair: *conn_mod.BufferPair) void {
        const base = @intFromPtr(self.buffer_pairs.ptr);
        const addr = @intFromPtr(pair);
        const idx: u32 = @intCast((addr - base) / @sizeOf(conn_mod.BufferPair));
        if (idx >= self.buf_pool_size) return;

        // Zero the entire pair on release. BufferPair is left `undefined`
        // at construction; without this, a handler that ever read past
        // `bytes_read` (by accident or via a future bug) could observe
        // bytes from the previous connection that held this slot. The
        // 192 KB memset is on the connection-close path, not the per-
        // request hot path.
        @memset(std.mem.asBytes(pair), 0);

        self.free_stack[self.free_count] = @intCast(idx);
        self.free_count += 1;
    }
};

test "EpollServer MAX_CONNECTIONS is reasonable" {
    try std.testing.expect(MAX_CONNECTIONS >= 1024);
    try std.testing.expect(MAX_CONNECTIONS <= 65536);
}

test "Buffer pool size fits in u16" {
    try std.testing.expect(BUFFER_POOL_SIZE <= std.math.maxInt(u16));
}

test "Connection timeout constants are reasonable" {
    try std.testing.expect(CONNECTION_TIMEOUT_S > 0);
    try std.testing.expect(CONNECTION_TIMEOUT_S <= 300);
}
