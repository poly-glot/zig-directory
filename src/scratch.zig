//! Scratch memory for the request path. A pool of fixed-size slabs is reserved once at startup,
//! one per thread that serves requests or runs a background tick; a thread claims its slab on
//! first use and resets it at the start of every request. Inside a request `allocator` hands out
//! the slab, outside one (tests, the importer, startup) it hands out the general-purpose
//! allocator, so the server never allocates on the request path after initialization while the
//! same operations stay usable from a plain thread. A request that outgrows its slab gets
//! `error.OutOfMemory`, which handlers answer as a protocol error: the slab is the limit.

const std = @import("std");
const assert = std.debug.assert;

pub const slabs_max: u32 = 64;
pub const slab_bytes_min: u32 = 64 * 1024;
pub const slab_bytes_max: u32 = 1024 * 1024 * 1024;

var pool_generations = std.atomic.Value(u32).init(0);

pub const Pool = struct {
    slabs: [slabs_max]std.heap.FixedBufferAllocator,
    count: u32,
    slab_bytes: u32,
    claimed: std.atomic.Value(u32),
    generation: u32,

    /// Reserves `options.count` slabs of `options.slab_bytes` each from the page allocator.
    /// Pages are committed lazily by the kernel, so an untouched slab costs address space only.
    pub fn init(options: struct { count: u32, slab_bytes: u32 }) !Pool {
        const count = options.count;
        const slab_bytes = options.slab_bytes;
        assert(count >= 1);
        assert(count <= slabs_max);
        assert(slab_bytes >= slab_bytes_min);
        assert(slab_bytes <= slab_bytes_max);

        var pool = Pool{
            .slabs = undefined,
            .count = 0,
            .slab_bytes = slab_bytes,
            .claimed = std.atomic.Value(u32).init(0),
            .generation = pool_generations.fetchAdd(1, .monotonic) + 1,
        };
        assert(pool.generation >= 1);
        errdefer pool.deinit();

        for (0..count) |index| {
            const buffer = try std.heap.page_allocator.alloc(u8, slab_bytes);
            pool.slabs[index] = std.heap.FixedBufferAllocator.init(buffer);
            pool.count += 1;
        }

        assert(pool.count == count);
        return pool;
    }

    pub fn deinit(pool: *Pool) void {
        assert(pool.count <= slabs_max);
        for (pool.slabs[0..pool.count]) |*slab| {
            assert(slab.buffer.len == pool.slab_bytes);
            std.heap.page_allocator.free(slab.buffer);
        }
        pool.count = 0;
    }

    /// Hands out the next unclaimed slab. Running out is a programmer error: the count passed
    /// to `init` must cover every reactor and background thread, which are all known at startup.
    fn claim(pool: *Pool) *std.heap.FixedBufferAllocator {
        assert(pool.count >= 1);
        const index = pool.claimed.fetchAdd(1, .monotonic);
        if (index >= pool.count) {
            @panic("scratch pool exhausted: more threads than reserved at init");
        }
        assert(index < pool.count);
        return &pool.slabs[index];
    }
};

threadlocal var current: ?*std.heap.FixedBufferAllocator = null;
threadlocal var current_generation: u32 = 0;
threadlocal var active: bool = false;

/// Opens a request or a background tick on the calling thread: claims the thread's slab from
/// this pool on first use (a slab claimed from an earlier pool, as a previous test's Directory
/// left behind, is forgotten) and resets it. Requests do not nest.
pub fn begin(pool: *Pool) void {
    assert(!active);
    assert(pool.generation >= 1);
    if (current == null or current_generation != pool.generation) {
        current = pool.claim();
        current_generation = pool.generation;
    }
    const slab = current.?;
    assert(slab.buffer.len == pool.slab_bytes);
    slab.reset();
    active = true;
    assert(slab.end_index == 0);
}

/// Closes the request opened by `begin`; the slab's contents are dead from here on.
pub fn end() void {
    assert(active);
    const slab = current.?;
    assert(slab.end_index <= slab.buffer.len);
    active = false;
}

/// The allocator for memory that lives no longer than the current request: the thread's slab
/// inside a request, `gpa` outside one.
pub fn allocator(gpa: std.mem.Allocator) std.mem.Allocator {
    if (!active) return gpa;
    const slab = current.?;
    assert(slab.end_index <= slab.buffer.len);
    return slab.allocator();
}

/// Whether the calling thread is inside a request or tick opened by `begin`.
pub fn is_active() bool {
    if (active) assert(current != null);
    return active;
}

fn slab_owns(slab: *const std.heap.FixedBufferAllocator, bytes: []const u8) bool {
    assert(slab.buffer.len > 0);
    assert(bytes.len <= slab.buffer.len);
    const start = @intFromPtr(slab.buffer.ptr);
    const address = @intFromPtr(bytes.ptr);
    return address >= start and address + bytes.len <= start + slab.buffer.len;
}

// Outside a request the scratch allocator is the general-purpose allocator, so code that runs
// from tests or the importer keeps its ordinary allocation behaviour.
test "scratch: outside a request the allocator is the gpa" {
    var pool = try Pool.init(.{ .count = 1, .slab_bytes = slab_bytes_min });
    defer pool.deinit();

    try std.testing.expect(!is_active());
    const bytes = try allocator(std.testing.allocator).alloc(u8, 16);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(!slab_owns(&pool.slabs[0], bytes));
}

// Inside a request every allocation lands in the thread's slab, the slab is reset by the next
// request, and a request larger than the slab is refused with OutOfMemory rather than growing.
test "scratch: a request allocates from its slab, resets, and is bounded by the slab" {
    var pool = try Pool.init(.{ .count = 2, .slab_bytes = slab_bytes_min });
    defer pool.deinit();

    begin(&pool);
    try std.testing.expect(is_active());
    const first = try allocator(std.testing.allocator).alloc(u8, 1024);
    try std.testing.expect(slab_owns(current.?, first));
    try std.testing.expectError(
        error.OutOfMemory,
        allocator(std.testing.allocator).alloc(u8, slab_bytes_min),
    );
    end();

    begin(&pool);
    const second = try allocator(std.testing.allocator).alloc(u8, 1024);
    try std.testing.expectEqual(first.ptr, second.ptr);
    end();
    try std.testing.expect(!is_active());
    try std.testing.expectEqual(@as(u32, 1), pool.claimed.load(.monotonic));

    var later = try Pool.init(.{ .count = 1, .slab_bytes = slab_bytes_min });
    defer later.deinit();
    begin(&later);
    const third = try allocator(std.testing.allocator).alloc(u8, 1024);
    try std.testing.expect(slab_owns(&later.slabs[0], third));
    end();
    try std.testing.expectEqual(@as(u32, 1), later.claimed.load(.monotonic));
}

// Each thread claims its own slab exactly once, so two threads never share scratch memory.
test "scratch: threads claim distinct slabs" {
    var pool = try Pool.init(.{ .count = 3, .slab_bytes = slab_bytes_min });
    defer pool.deinit();

    const Worker = struct {
        fn run(shared: *Pool, seen: *?[*]u8) void {
            begin(shared);
            const bytes = allocator(std.testing.allocator).alloc(u8, 8) catch unreachable;
            seen.* = bytes.ptr;
            end();
        }
    };
    var first_pointer: ?[*]u8 = null;
    var second_pointer: ?[*]u8 = null;
    const first = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &first_pointer });
    first.join();
    const second = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &second_pointer });
    second.join();

    try std.testing.expect(first_pointer != null);
    try std.testing.expect(second_pointer != null);
    try std.testing.expect(first_pointer.? != second_pointer.?);
    try std.testing.expectEqual(@as(u32, 2), pool.claimed.load(.monotonic));
}
