//! Shared client plumbing for the bench workloads: the request frame builder, the blocking
//! socket calls, seed-file loading, the worker runner and the JSONL record it emits. Bytes the
//! server sends back are operating input and are validated with errors; a frame this module
//! assembles never leaves its buffer and never overwrites the eight-byte request header.

const std = @import("std");
const assert = std.debug.assert;
const linux = std.os.linux;
const zigstore = @import("zigstore");

pub const Env = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    hostname: []const u8,
};

pub const AtomicHistogram = zigstore.histogram.AtomicHistogram;

// A request header is the u32 frame length, the op byte, a flags byte and the u16 item count.
pub const request_header_size: usize = 8;
const request_op_offset: usize = 4;
const request_flags_offset: usize = 5;
const request_count_offset: usize = 6;

// A response header is the u32 frame length, the op byte, the status and sub-status bytes, a
// reserved byte and the u16 item count.
pub const response_header_size: usize = 10;
pub const response_status_offset: usize = 5;
const response_sub_status_offset: usize = 6;
const response_count_offset: usize = 8;

pub const status_ok: u8 = 0;

const link_batch: u64 = 100;

// A batch item reply is a status byte, a sub-status byte and the u64 id.
const batch_item_bytes: usize = 10;

// A u64 prints as at most twenty decimal digits, which sizes every formatted url and title.
const u64_digits_max: usize = 20;
const link_url_bytes_max: usize = 64;
const link_title_bytes_max: usize = 32;

pub const workers_max: u32 = 256;

const file_bytes_max: u64 = 16 * 1024 * 1024;

const ping_response_bytes: usize = 64;

const sleep_ms_max: u64 = 60_000;

pub const Op = enum(u8) {
    create_link = 1,
    create_category = 2,
    get_link = 3,
    browse_path = 11,
    list_children = 12,
    search = 14,
    list_subtree_links = 17,
    bulk_import = 24,
    ping = 255,
};

pub const FrameBuilder = struct {
    buffer: []u8,
    pos: u32,

    pub fn init(buffer: []u8, op: Op) FrameBuilder {
        comptime assert(request_count_offset + @sizeOf(u16) == request_header_size);
        assert(buffer.len >= request_header_size);
        assert(buffer.len <= std.math.maxInt(u32));

        buffer[request_op_offset] = @intFromEnum(op);
        buffer[request_flags_offset] = 0;
        return .{ .buffer = buffer, .pos = request_header_size };
    }

    pub fn write_u8(self: *FrameBuilder, value: u8) void {
        assert(self.pos >= request_header_size);
        assert(self.pos + 1 <= self.buffer.len);

        self.buffer[self.pos] = value;
        self.pos += 1;
    }

    pub fn write_u16(self: *FrameBuilder, value: u16) void {
        assert(self.pos >= request_header_size);
        assert(self.pos + 2 <= self.buffer.len);

        std.mem.writeInt(u16, self.buffer[self.pos..][0..2], value, .little);
        self.pos += 2;
    }

    pub fn write_u32(self: *FrameBuilder, value: u32) void {
        assert(self.pos >= request_header_size);
        assert(self.pos + 4 <= self.buffer.len);

        std.mem.writeInt(u32, self.buffer[self.pos..][0..4], value, .little);
        self.pos += 4;
    }

    pub fn write_u64(self: *FrameBuilder, value: u64) void {
        assert(self.pos >= request_header_size);
        assert(self.pos + 8 <= self.buffer.len);

        std.mem.writeInt(u64, self.buffer[self.pos..][0..8], value, .little);
        self.pos += 8;
    }

    pub fn write_bytes(self: *FrameBuilder, bytes: []const u8) void {
        assert(self.pos >= request_header_size);
        assert(self.pos + bytes.len <= self.buffer.len);

        @memcpy(self.buffer[self.pos..][0..bytes.len], bytes);
        self.pos += @intCast(bytes.len);
    }

    pub fn write_u16_len_prefixed(self: *FrameBuilder, bytes: []const u8) void {
        assert(bytes.len <= std.math.maxInt(u16));
        const pos_before = self.pos;

        self.write_u16(@intCast(bytes.len));
        self.write_bytes(bytes);
        assert(self.pos == pos_before + 2 + bytes.len);
    }

    pub fn finalize(self: *FrameBuilder, count: u16) []const u8 {
        assert(self.pos >= request_header_size);
        assert(self.pos <= self.buffer.len);
        if (count == 0) assert(self.pos == request_header_size);

        std.mem.writeInt(u32, self.buffer[0..4], self.pos, .little);
        std.mem.writeInt(u16, self.buffer[request_count_offset..][0..2], count, .little);
        return self.buffer[0..self.pos];
    }
};

pub fn write_link_item(
    frame_builder: *FrameBuilder,
    options: struct { category_id: u64, index: u64 },
    comptime url_format: []const u8,
) !void {
    comptime assert(url_format.len + u64_digits_max <= link_url_bytes_max);
    comptime assert(1 + u64_digits_max <= link_title_bytes_max);
    assert(options.category_id != 0);
    const pos_before = frame_builder.pos;

    var url_buffer: [link_url_bytes_max]u8 = undefined;
    var title_buffer: [link_title_bytes_max]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buffer, url_format, .{options.index});
    const title = try std.fmt.bufPrint(&title_buffer, "L{d}", .{options.index});
    frame_builder.write_u64(options.category_id);
    frame_builder.write_u16_len_prefixed(url);
    frame_builder.write_u16_len_prefixed(title);
    frame_builder.write_u16_len_prefixed("");
    assert(frame_builder.pos == pos_before + 8 + 2 + url.len + 2 + title.len + 2);
}

fn syscall(return_code: usize) !usize {
    return switch (linux.errno(return_code)) {
        .SUCCESS => return_code,
        .INTR => error.Interrupted,
        .CONNREFUSED => error.ConnectionRefused,
        .PIPE => error.BrokenPipe,
        .CONNRESET => error.ConnectionReset,
        else => error.Unexpected,
    };
}

fn write_fd(fd: i32, bytes: []const u8) !usize {
    assert(fd >= 0);
    assert(bytes.len > 0);

    const written = try syscall(linux.write(fd, bytes.ptr, bytes.len));
    assert(written <= bytes.len);
    return written;
}

fn read_fd(fd: i32, buffer: []u8) !usize {
    assert(fd >= 0);
    assert(buffer.len > 0);

    const read = try syscall(linux.read(fd, buffer.ptr, buffer.len));
    assert(read <= buffer.len);
    return read;
}

pub fn close_fd(fd: i32) void {
    assert(fd >= 0);
    _ = linux.close(fd);
}

pub fn send_and_receive(stream_fd: i32, frame: []const u8, response_buffer: []u8) !usize {
    assert(frame.len >= request_header_size);
    assert(response_buffer.len >= response_header_size);

    var sent: usize = 0;
    var writes: usize = 0;
    while (sent < frame.len) : (writes += 1) {
        assert(writes < frame.len);
        const n = try write_fd(stream_fd, frame[sent..]);
        if (n == 0) return error.WriteEof;
        sent += n;
    }
    assert(sent == frame.len);

    var read_total: usize = 0;
    var reads: usize = 0;
    while (read_total < response_header_size) : (reads += 1) {
        assert(reads < response_header_size);
        const n = try read_fd(stream_fd, response_buffer[read_total..]);
        if (n == 0) return error.ReadEof;
        read_total += n;
    }
    const response_len = std.mem.readInt(u32, response_buffer[0..4], .little);
    if (response_len < response_header_size) return error.ProtocolError;
    if (response_len > response_buffer.len) return error.ResponseTooLarge;
    while (read_total < response_len) : (reads += 1) {
        assert(reads < response_len);
        const n = try read_fd(stream_fd, response_buffer[read_total..]);
        if (n == 0) return error.ReadEof;
        read_total += n;
    }
    return response_len;
}

pub fn tcp_connect(host: []const u8, port: u16) !i32 {
    comptime assert(@sizeOf(linux.sockaddr.in) == 16);
    assert(host.len > 0);
    assert(port != 0);

    const address = try std.Io.net.Ip4Address.parse(host, port);
    const socket_address = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, address.port),
        .addr = @bitCast(address.bytes),
    };
    const fd: i32 = @intCast(try syscall(linux.socket(linux.AF.INET, linux.SOCK.STREAM, 0)));
    assert(fd >= 0);
    errdefer close_fd(fd);
    _ = try syscall(linux.connect(fd, &socket_address, @sizeOf(linux.sockaddr.in)));
    return fd;
}

pub fn ping(stream_fd: i32) !void {
    comptime assert(ping_response_bytes >= response_header_size);

    var request: [request_header_size]u8 = undefined;
    var frame_builder = FrameBuilder.init(&request, .ping);
    const frame = frame_builder.finalize(0);
    assert(frame.len == request_header_size);

    var response_buffer: [ping_response_bytes]u8 = undefined;
    _ = try send_and_receive(stream_fd, frame, &response_buffer);
    if (response_buffer[response_status_offset] != status_ok) return error.PingFailed;
}

pub fn create_category(
    stream_fd: i32,
    request_buffer: []u8,
    response_buffer: []u8,
    parent_id: u64,
    text: struct { name: []const u8, slug: []const u8, description: []const u8 },
) !u64 {
    assert(parent_id != 0);
    assert(text.name.len > 0);
    assert(text.slug.len > 0);
    assert(response_buffer.len >= response_header_size + batch_item_bytes);

    var frame_builder = FrameBuilder.init(request_buffer, .create_category);
    frame_builder.write_u64(parent_id);
    frame_builder.write_u16_len_prefixed(text.name);
    frame_builder.write_u16_len_prefixed(text.slug);
    frame_builder.write_u16_len_prefixed(text.description);
    const frame = frame_builder.finalize(1);
    const response_len = try send_and_receive(stream_fd, frame, response_buffer);
    if (response_len < response_header_size + batch_item_bytes) return error.ProtocolError;
    if (response_buffer[response_status_offset] != status_ok) {
        std.debug.print(
            "create_category failed: server status={d} sub={d}\n",
            .{
                response_buffer[response_status_offset],
                response_buffer[response_sub_status_offset],
            },
        );
        return error.CreateCategoryFailed;
    }
    const item_status = response_buffer[response_header_size];
    if (item_status != status_ok) {
        const item_sub_status = response_buffer[response_header_size + 1];
        std.debug.print(
            "create_category item failed: status={d} sub={d}\n",
            .{ item_status, item_sub_status },
        );
        return error.CreateCategoryFailed;
    }
    const id = std.mem.readInt(u64, response_buffer[response_header_size + 2 ..][0..8], .little);
    if (id == 0) return error.ProtocolError;
    return id;
}

pub const IdRange = struct {
    min: u64 = 0,
    max: u64 = 0,

    pub fn pick(self: IdRange, random: std.Random) u64 {
        assert(self.min <= self.max);

        const id = self.min + random.uintLessThan(u64, self.max - self.min + 1);
        assert(id >= self.min);
        assert(id <= self.max);
        return id;
    }
};

pub fn create_links_round_robin(
    stream_fd: i32,
    request_buffer: []u8,
    response_buffer: []u8,
    category_ids: []const u64,
    count: u64,
) !IdRange {
    assert(category_ids.len > 0);

    var range = IdRange{};
    var sent: u64 = 0;
    while (sent < count) {
        const batch = @min(link_batch, count - sent);
        assert(batch > 0);
        assert(batch <= link_batch);

        var frame_builder = FrameBuilder.init(request_buffer, .create_link);
        var batch_index: u64 = 0;
        while (batch_index < batch) : (batch_index += 1) {
            const category_id = category_ids[@intCast((sent + batch_index) % category_ids.len)];
            try write_link_item(
                &frame_builder,
                .{ .category_id = category_id, .index = sent + batch_index + 1 },
                "https://b{d}.t",
            );
        }
        const frame = frame_builder.finalize(@intCast(batch));
        const response_len = try send_and_receive(stream_fd, frame, response_buffer);
        try collect_batch_ids(response_buffer[0..response_len], @intCast(batch), &range);
        sent += batch;
    }
    assert(sent == count);
    if (count > 0) assert(range.min != 0);
    if (count > 0) assert(range.min <= range.max);
    return range;
}

fn collect_batch_ids(response: []const u8, expected_count: u16, range: *IdRange) !void {
    comptime assert(batch_item_bytes == 1 + 1 + @sizeOf(u64));
    assert(expected_count > 0);
    assert(expected_count <= link_batch);

    if (response.len < response_header_size) return error.ProtocolError;
    if (response[response_status_offset] != status_ok) return error.ProtocolError;
    const count = std.mem.readInt(u16, response[response_count_offset..][0..2], .little);
    if (count != expected_count) return error.ProtocolError;

    var offset: usize = response_header_size;
    for (0..count) |_| {
        if (offset + batch_item_bytes > response.len) return error.ProtocolError;
        if (response[offset] != status_ok) return error.BatchItemFailed;
        const id = std.mem.readInt(u64, response[offset + 2 ..][0..8], .little);
        if (id == 0) return error.ProtocolError;
        if (range.min == 0 or id < range.min) range.min = id;
        if (id > range.max) range.max = id;
        offset += batch_item_bytes;
    }
    assert(offset == response_header_size + @as(usize, count) * batch_item_bytes);
    assert(range.min <= range.max);
}

pub fn ensure_dir(io: std.Io, path: []const u8) !void {
    assert(path.len > 0);
    try std.Io.Dir.cwd().createDirPath(io, path);
}

pub fn read_file_alloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    assert(path.len > 0);

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const size = (try file.stat(io)).size;
    if (size > file_bytes_max) return error.FileTooLarge;

    const data = try allocator.alloc(u8, size);
    errdefer allocator.free(data);

    const read = try file.readPositionalAll(io, data, 0);
    if (read != size) return error.UnexpectedEof;
    return data;
}

pub fn write_file_all(io: std.Io, path: []const u8, lines: []const []const u8) !void {
    assert(path.len > 0);
    assert(lines.len > 0);

    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);

    for (lines) |line| try file.writeStreamingAll(io, line);
}

pub fn seed_path(allocator: std.mem.Allocator, data_dir: []const u8) ![]u8 {
    assert(data_dir.len > 0);
    return std.fmt.allocPrint(allocator, "{s}/seed.json", .{data_dir});
}

pub const SeedInfo = struct {
    category_id_min: u64,
    category_id_max: u64,
    link_id_min: u64,
    link_id_max: u64,
    sample_paths: []const []const u8 = &.{},
    sample_query_tokens: []const []const u8 = &.{},

    pub fn link_ids(self: *const SeedInfo) IdRange {
        assert(self.link_id_min <= self.link_id_max);
        return .{ .min = self.link_id_min, .max = self.link_id_max };
    }

    pub fn category_ids(self: *const SeedInfo) IdRange {
        assert(self.category_id_min <= self.category_id_max);
        return .{ .min = self.category_id_min, .max = self.category_id_max };
    }
};

pub fn load_seed(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.json.Parsed(SeedInfo) {
    assert(path.len > 0);

    const data = try read_file_alloc(io, allocator, path);
    defer allocator.free(data);

    const parsed = try std.json.parseFromSlice(SeedInfo, allocator, data, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    });
    errdefer parsed.deinit();

    if (parsed.value.category_id_min > parsed.value.category_id_max) return error.InvalidSeed;
    if (parsed.value.link_id_min > parsed.value.link_id_max) return error.InvalidSeed;
    return parsed;
}

pub const LatencyStats = struct {
    p50: u64,
    p95: u64,
    p99: u64,
    p99_9: u64,
    max: u64,
    mean: u64,
    samples: u64,
};

pub const RssStats = struct {
    peak: u64,
    final: u64,
    note: ?[]const u8,
};

pub const rss_stats_unavailable = RssStats{ .peak = 0, .final = 0, .note = "rss_unavailable" };

pub const ErrorCounts = struct {
    connect_failed: u64,
    timeout: u64,
    protocol_error: u64,
};

pub const WorkloadParams = union(enum) {
    seed: struct { categories: u32, links: u64, depth: u32 },
    create_link: struct { workers: u32, batch_size: u32, ops_per_worker: u64 },
    get_link: struct { workers: u32, ops_per_worker: u64, seed_path: []const u8 },
    browse: struct { kind: []const u8, workers: u32, ops_per_worker: u64, seed_path: []const u8 },
    search: struct {
        target: []const u8,
        workers: u32,
        ops_per_worker: u64,
        query_corpus_size: u32,
    },
    mixed: struct { workers: u32, read_pct: u32, ops_per_worker: u64 },
    cold: struct { kind: []const u8, iterations: u32, server_cmd: []const u8 },

    // The std.json hook is looked up under this exact name; without it a record's params
    // would carry the union tag and no longer match the baseline JSONL shape.
    pub fn jsonStringify(self: WorkloadParams, json_writer: *std.json.Stringify) !void {
        switch (self) {
            inline else => |payload| try json_writer.write(payload),
        }
    }
};

pub const BenchRecord = struct {
    schema_version: u32 = 1,
    ts: i64,
    host: []const u8,
    git_rev: []const u8,
    profile: []const u8,
    workload: []const u8,
    params: WorkloadParams,
    duration_ms: u64,
    ops_total: u64,
    ops_per_sec: u64,
    latency_ns: LatencyStats,
    rss_bytes: RssStats,
    errors: ErrorCounts,
};

pub fn append_json_line(env: Env, output_path: ?[]const u8, record: *const BenchRecord) !void {
    const line = try std.json.Stringify.valueAlloc(env.allocator, record.*, .{});
    defer env.allocator.free(line);

    assert(std.mem.startsWith(u8, line, "{"));
    assert(std.mem.indexOfScalar(u8, line, '\n') == null);

    const path = output_path orelse {
        try std.Io.File.stdout().writeStreamingAll(env.io, line);
        try std.Io.File.stdout().writeStreamingAll(env.io, "\n");
        return;
    };
    const file = try std.Io.Dir.cwd().createFile(env.io, path, .{ .truncate = false });
    defer file.close(env.io);

    const end = (try file.stat(env.io)).size;
    try file.writePositionalAll(env.io, line, end);
    try file.writePositionalAll(env.io, "\n", end + line.len);
}

pub const RssSampler = struct {
    io: std.Io,
    pid: i32,
    interval_ms: u64,
    thread: ?std.Thread = null,
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    final: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const peak_update_attempts_max = 1024;
    const status_path_bytes_max: usize = 64;
    const status_bytes_max: usize = 4096;

    pub fn start(self: *RssSampler) !void {
        if (self.interval_ms == 0) return;
        assert(self.thread == null);
        self.thread = try std.Thread.spawn(.{}, sample_loop, .{self});
    }

    pub fn stop(self: *RssSampler) void {
        if (self.interval_ms == 0) assert(self.thread == null);
        self.shutdown.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    fn sample_loop(self: *RssSampler) void {
        assert(self.interval_ms > 0);
        while (!self.shutdown.load(.acquire)) {
            std.Io.sleep(
                self.io,
                .fromMilliseconds(@intCast(self.interval_ms)),
                .awake,
            ) catch return;
            const rss = read_rss_bytes(self.io, self.pid) catch |err| {
                std.log.warn("rss sample failed: {s}", .{@errorName(err)});
                continue;
            };
            for (0..peak_update_attempts_max) |_| {
                const current = self.peak.load(.monotonic);
                if (rss <= current) break;
                if (self.peak.cmpxchgWeak(current, rss, .monotonic, .monotonic) == null) break;
            }
            assert(self.peak.load(.monotonic) >= rss);
            self.final.store(rss, .monotonic);
        }
    }

    fn read_rss_bytes(io: std.Io, pid: i32) !u64 {
        comptime assert(status_path_bytes_max >= "/proc/".len + 11 + "/status".len);

        var path_buffer: [status_path_bytes_max]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "/proc/{d}/status", .{pid});
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        var buffer: [status_bytes_max]u8 = undefined;
        var n: usize = 0;
        while (n < buffer.len) {
            const got = try file.readStreaming(io, &.{buffer[n..]});
            if (got == 0) break;
            n += got;
        }
        assert(n <= buffer.len);
        var lines = std.mem.tokenizeScalar(u8, buffer[0..n], '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "VmRSS:")) continue;
            var parts = std.mem.tokenizeAny(u8, line, " \t");
            _ = parts.next();
            const kib_text = parts.next() orelse return error.ParseError;
            const kib = try std.fmt.parseInt(u64, kib_text, 10);
            return kib * 1024;
        }
        return error.NoVmRSS;
    }
};

pub const CommonOptions = struct {
    profile: []const u8 = "unconstrained",
    output_path: ?[]const u8 = null,
    workers: u32 = 4,
    ops_per_worker: u64 = 10000,
    warmup_ops: u64 = 1000,
    connect_host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    rss_sample_ms: u64 = 200,
    git_rev: ?[]const u8 = null,
};

pub fn parse_common_options(
    args: *std.process.Args.Iterator,
    leftovers: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
) !CommonOptions {
    var options = CommonOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--profile")) {
            options.profile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--output")) {
            options.output_path = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--workers")) {
            const value = args.next() orelse return error.MissingValue;
            options.workers = try std.fmt.parseInt(u32, value, 10);
        } else if (std.mem.eql(u8, arg, "--ops-per-worker")) {
            const value = args.next() orelse return error.MissingValue;
            options.ops_per_worker = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--warmup-ops")) {
            const value = args.next() orelse return error.MissingValue;
            options.warmup_ops = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--connect-host")) {
            options.connect_host = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const value = args.next() orelse return error.MissingValue;
            options.port = try std.fmt.parseInt(u16, value, 10);
        } else if (std.mem.eql(u8, arg, "--rss-sample-ms")) {
            const value = args.next() orelse return error.MissingValue;
            options.rss_sample_ms = try std.fmt.parseInt(u64, value, 10);
        } else if (std.mem.eql(u8, arg, "--git-rev")) {
            options.git_rev = args.next() orelse return error.MissingValue;
        } else {
            try leftovers.append(allocator, arg);
        }
    }
    if (options.workers > workers_max) return error.TooManyWorkers;
    if (options.connect_host.len == 0) return error.InvalidHost;
    if (options.port == 0) return error.InvalidPort;
    return options;
}

pub fn now(io: std.Io) std.Io.Timestamp {
    return std.Io.Clock.awake.now(io);
}

pub fn elapsed_ns(io: std.Io, since: std.Io.Timestamp) u64 {
    const ns = since.durationTo(now(io)).toNanoseconds();
    assert(ns >= 0);
    return @intCast(ns);
}

pub fn elapsed_ms(io: std.Io, since: std.Io.Timestamp) u64 {
    return @divFloor(elapsed_ns(io, since), std.time.ns_per_ms);
}

pub fn unix_millis(io: std.Io) i64 {
    return std.Io.Clock.real.now(io).toMilliseconds();
}

pub fn sleep_ms(io: std.Io, ms: u64) void {
    assert(ms > 0);
    assert(ms <= sleep_ms_max);
    std.Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

pub const Frame = struct {
    bytes: []const u8,
    ops: u64 = 1,
};

pub const Worker = struct {
    id: u32,
    random: std.Random,
    request_buffer: []u8,
    counter: u64 = 0,
    ops_completed: u64 = 0,
};

pub const Run = struct {
    env: Env,
    options: CommonOptions,
    histogram: AtomicHistogram = .{},
    ops_completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    connect_failed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    protocol_error: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    duration_ms: u64 = 0,
    rss: RssStats = rss_stats_unavailable,

    pub fn init(env: Env, options: CommonOptions) Run {
        return .{ .env = env, .options = options };
    }

    pub fn run_workers(self: *Run, comptime Context: type, context: *Context) !void {
        if (self.options.workers == 0) return error.InvalidWorkers;
        assert(self.options.workers <= workers_max);
        assert(self.ops_completed_total() == 0);

        const Main = struct {
            fn main(bench: *Run, worker_context: *Context, id: u32) void {
                assert(id < bench.options.workers);
                worker_loop(Context, bench, worker_context, id) catch |err| {
                    std.log.warn("worker {d} fatal: {s}", .{ id, @errorName(err) });
                };
            }
        };

        const threads = try self.env.allocator.alloc(std.Thread, self.options.workers);
        defer self.env.allocator.free(threads);

        const t_start = now(self.env.io);
        for (threads, 0..) |*thread, index| {
            thread.* = try std.Thread.spawn(
                .{},
                Main.main,
                .{ self, context, @as(u32, @intCast(index)) },
            );
        }
        for (threads) |thread| thread.join();
        self.duration_ms = elapsed_ms(self.env.io, t_start);

        assert(self.connect_failed.load(.monotonic) <= self.options.workers);
        assert(self.protocol_error.load(.monotonic) <= self.options.workers);
    }

    pub fn ops_completed_total(self: *const Run) u64 {
        return self.ops_completed.load(.monotonic);
    }

    pub fn record(
        self: *const Run,
        workload: []const u8,
        params: WorkloadParams,
        ops_total: u64,
    ) BenchRecord {
        assert(workload.len > 0);
        const histogram = &self.histogram;
        const latency = LatencyStats{
            .p50 = histogram.percentile(50.0),
            .p95 = histogram.percentile(95.0),
            .p99 = histogram.percentile(99.0),
            .p99_9 = histogram.percentile(99.9),
            .max = histogram.maxValue(),
            .mean = histogram.mean(),
            .samples = histogram.samples(),
        };
        assert(latency.p50 <= latency.p95);
        assert(latency.p95 <= latency.p99);
        assert(latency.p99 <= latency.p99_9);
        assert(latency.p99_9 <= latency.max);
        assert(latency.mean <= latency.max);

        const ops_per_sec: u64 = if (self.duration_ms > 0)
            @divFloor(ops_total * 1000, self.duration_ms)
        else
            0;
        return .{
            .ts = unix_millis(self.env.io),
            .host = self.env.hostname,
            .git_rev = self.options.git_rev orelse "unknown",
            .profile = self.options.profile,
            .workload = workload,
            .params = params,
            .duration_ms = self.duration_ms,
            .ops_total = ops_total,
            .ops_per_sec = ops_per_sec,
            .latency_ns = latency,
            .rss_bytes = self.rss,
            .errors = .{
                .connect_failed = self.connect_failed.load(.monotonic),
                .timeout = 0,
                .protocol_error = self.protocol_error.load(.monotonic),
            },
        };
    }

    pub fn emit(
        self: *const Run,
        workload: []const u8,
        params: WorkloadParams,
        ops_total: u64,
    ) !void {
        const bench_record = self.record(workload, params, ops_total);
        try append_json_line(self.env, self.options.output_path, &bench_record);
    }
};

fn worker_loop(comptime Context: type, bench: *Run, context: *Context, id: u32) !void {
    assert(id < bench.options.workers);

    const fd = tcp_connect(bench.options.connect_host, bench.options.port) catch {
        _ = bench.connect_failed.fetchAdd(1, .monotonic);
        return;
    };
    defer close_fd(fd);

    const request_buffer = try bench.env.allocator.alloc(u8, Context.request_buffer_size);
    defer bench.env.allocator.free(request_buffer);

    const response_buffer = try bench.env.allocator.alloc(u8, Context.response_buffer_size);
    defer bench.env.allocator.free(response_buffer);

    const seed: u64 = if (@hasDecl(Context, "prng_seed")) Context.prng_seed(id) else id;
    var prng = std.Random.DefaultPrng.init(seed);
    var worker = Worker{ .id = id, .random = prng.random(), .request_buffer = request_buffer };
    defer _ = bench.ops_completed.fetchAdd(worker.ops_completed, .monotonic);

    while (worker.ops_completed < bench.options.ops_per_worker) {
        const frame = try context.next_frame(&worker);
        assert(frame.ops > 0);
        assert(frame.bytes.len >= request_header_size);
        assert(frame.bytes.len <= request_buffer.len);

        const t0 = now(bench.env.io);
        const response_len = send_and_receive(fd, frame.bytes, response_buffer) catch {
            _ = bench.protocol_error.fetchAdd(1, .monotonic);
            return;
        };
        const latency_ns = elapsed_ns(bench.env.io, t0);

        if (!accepted(Context, context, response_buffer[0..response_len], latency_ns)) {
            _ = bench.protocol_error.fetchAdd(1, .monotonic);
            return;
        }

        if (worker.ops_completed >= bench.options.warmup_ops) {
            bench.histogram.recordValue(latency_ns);
        }
        worker.ops_completed += frame.ops;
    }
    assert(worker.ops_completed >= bench.options.ops_per_worker);
}

fn accepted(comptime Context: type, context: *Context, response: []const u8, latency_ns: u64) bool {
    if (!@hasDecl(Context, "on_response")) return true;
    return context.on_response(response, latency_ns);
}

// Goal: the frame header the server reads carries the length, op and count that were built.
// Method: build one create_link frame and decode the three header fields by hand.
test "FrameBuilder: round-trip a create_link frame" {
    var buffer: [256]u8 = undefined;
    var frame_builder = FrameBuilder.init(&buffer, .create_link);
    frame_builder.write_u64(42);
    frame_builder.write_u16_len_prefixed("https://example.com");
    frame_builder.write_u16_len_prefixed("Example");
    frame_builder.write_u16_len_prefixed("");
    const frame = frame_builder.finalize(1);

    const len = std.mem.readInt(u32, frame[0..4], .little);
    try std.testing.expectEqual(frame.len, len);
    try std.testing.expectEqual(@as(u8, 1), frame[4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, frame[6..8], .little));
}

const test_env = Env{
    .io = std.testing.io,
    .allocator = std.testing.allocator,
    .environ = undefined,
    .hostname = "test",
};

// Goal: an empty histogram reports all-zero latency so a seed record keeps its baseline shape.
// Method: record a seed run with no samples and read the zeros back.
test "Run.record: an empty histogram reports zero latency" {
    const bench = Run.init(test_env, .{});
    const seed_params = WorkloadParams{ .seed = .{ .categories = 1, .links = 1, .depth = 1 } };
    const bench_record = bench.record("seed", seed_params, 2);
    try std.testing.expectEqual(@as(u64, 0), bench_record.latency_ns.p99);
    try std.testing.expectEqual(@as(u64, 0), bench_record.latency_ns.mean);
    try std.testing.expectEqual(@as(u64, 0), bench_record.latency_ns.samples);
    try std.testing.expectEqual(@as(u64, 0), bench_record.ops_per_sec);
    try std.testing.expectEqualStrings("rss_unavailable", bench_record.rss_bytes.note.?);
}

// Goal: params serialize flat, without the union tag, as every bench/baseline-*.jsonl line
// shows. Method: stringify one seed params value and compare the exact text.
test "WorkloadParams: serializes without the union tag" {
    const seed_params = WorkloadParams{ .seed = .{ .categories = 1, .links = 2, .depth = 3 } };
    const text = try std.json.Stringify.valueAlloc(std.testing.allocator, seed_params, .{});
    defer std.testing.allocator.free(text);

    try std.testing.expectEqualStrings("{\"categories\":1,\"links\":2,\"depth\":3}", text);
}

// Goal: one record is one line of the output file. Method: append the same record twice and
// count the newlines.
test "append_json_line: appends one JSONL line per record" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = path_buffer[0..try temporary.dir.realPath(std.testing.io, &path_buffer)];
    const file = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.jsonl", .{path});
    defer std.testing.allocator.free(file);

    const bench_record = BenchRecord{
        .ts = 1714838400000,
        .host = "test",
        .git_rev = "deadbeef",
        .profile = "unconstrained",
        .workload = "create_link",
        .params = .{ .create_link = .{ .workers = 4, .batch_size = 10, .ops_per_worker = 1000 } },
        .duration_ms = 1234,
        .ops_total = 4000,
        .ops_per_sec = 3243,
        .latency_ns = .{
            .p50 = 100,
            .p95 = 200,
            .p99 = 300,
            .p99_9 = 400,
            .max = 500,
            .mean = 150,
            .samples = 4000,
        },
        .rss_bytes = rss_stats_unavailable,
        .errors = .{ .connect_failed = 0, .timeout = 0, .protocol_error = 0 },
    };
    try append_json_line(test_env, file, &bench_record);
    try append_json_line(test_env, file, &bench_record);

    const contents = try read_file_alloc(std.testing.io, std.testing.allocator, file);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, contents, "\n"));
}
