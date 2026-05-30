const std = @import("std");

/// Lock-free bloom filter for fast negative lookups.
///
/// Used to skip expensive B+Tree searches when checking for duplicate URLs.
/// If the bloom filter says "not present", the URL is definitely new — no
/// B+Tree search needed. False positives (~0.1% at design capacity) fall
/// through to the B+Tree for confirmation.
///
/// Thread safety: uses @atomicRmw for set, @atomicLoad for test.
/// Multiple threads can concurrently add and check without locks.
pub const BloomFilter = struct {
    bits: []std.atomic.Value(u64),
    num_bits: u64,
    allocator: std.mem.Allocator,

    /// Number of hash functions. 7 is optimal for 10 bits/element (~0.8% FPR).
    const K = 7;

    /// Initialize a bloom filter with approximately `capacity` expected elements.
    /// Uses ~10 bits per element for ~0.8% false positive rate.
    pub fn init(allocator: std.mem.Allocator, capacity: u64) !BloomFilter {
        // 10 bits per element, rounded up to u64 boundary.
        const num_bits = @max(capacity * 10, 1024);
        const num_words = (num_bits + 63) / 64;
        const bits = try allocator.alloc(std.atomic.Value(u64), num_words);
        for (bits) |*w| w.* = std.atomic.Value(u64).init(0);
        return .{
            .bits = bits,
            .num_bits = num_words * 64,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BloomFilter) void {
        self.allocator.free(self.bits);
    }

    /// Add an element to the filter (lock-free).
    pub fn add(self: *BloomFilter, key: []const u8) void {
        const h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(1, key);
        for (0..K) |i| {
            const bit_idx = (h1 +% h2 *% i) % self.num_bits;
            const word_idx = bit_idx / 64;
            const bit_pos: u6 = @intCast(bit_idx % 64);
            _ = self.bits[word_idx].fetchOr(@as(u64, 1) << bit_pos, .monotonic);
        }
    }

    /// Test if an element might be in the filter.
    /// Returns false = definitely not present. Returns true = probably present.
    pub fn mayContain(self: *const BloomFilter, key: []const u8) bool {
        const h1 = std.hash.Wyhash.hash(0, key);
        const h2 = std.hash.Wyhash.hash(1, key);
        for (0..K) |i| {
            const bit_idx = (h1 +% h2 *% i) % self.num_bits;
            const word_idx = bit_idx / 64;
            const bit_pos: u6 = @intCast(bit_idx % 64);
            if (self.bits[word_idx].load(.monotonic) & (@as(u64, 1) << bit_pos) == 0) {
                return false;
            }
        }
        return true;
    }

    /// Approximate number of bits set (for diagnostics).
    pub fn popCount(self: *const BloomFilter) u64 {
        var total: u64 = 0;
        for (self.bits) |*w| {
            total += @popCount(w.load(.monotonic));
        }
        return total;
    }
};

test "BloomFilter add and check" {
    var bf = try BloomFilter.init(std.testing.allocator, 1000);
    defer bf.deinit();

    bf.add("https://example.com");
    bf.add("https://ziglang.org");

    try std.testing.expect(bf.mayContain("https://example.com"));
    try std.testing.expect(bf.mayContain("https://ziglang.org"));
    // Very unlikely false positive for an unseen URL.
    // (Not guaranteed but astronomically unlikely with 1000 capacity and 2 entries.)
    try std.testing.expect(!bf.mayContain("https://definitely-not-added.com"));
}

test "BloomFilter no false negatives" {
    var bf = try BloomFilter.init(std.testing.allocator, 10000);
    defer bf.deinit();

    // Add 5000 URLs.
    var buf: [64]u8 = undefined;
    for (0..5000) |i| {
        const len = std.fmt.bufPrint(&buf, "https://test{d}.com", .{i}) catch continue;
        bf.add(len);
    }

    // Every added URL MUST be found (zero false negatives).
    for (0..5000) |i| {
        const len = std.fmt.bufPrint(&buf, "https://test{d}.com", .{i}) catch continue;
        try std.testing.expect(bf.mayContain(len));
    }
}

test "BloomFilter false positive rate" {
    var bf = try BloomFilter.init(std.testing.allocator, 10000);
    defer bf.deinit();

    // Add 10,000 URLs.
    var buf: [64]u8 = undefined;
    for (0..10000) |i| {
        const len = std.fmt.bufPrint(&buf, "https://added{d}.com", .{i}) catch continue;
        bf.add(len);
    }

    // Check 10,000 URLs that were NOT added. Count false positives.
    var false_positives: u32 = 0;
    for (0..10000) |i| {
        const len = std.fmt.bufPrint(&buf, "https://notadded{d}.com", .{i}) catch continue;
        if (bf.mayContain(len)) false_positives += 1;
    }

    // With 10 bits/element and K=7, FPR should be ~0.8%.
    // Allow up to 3% as safety margin in test.
    const fpr = @as(f64, @floatFromInt(false_positives)) / 10000.0;
    try std.testing.expect(fpr < 0.03);
}

test "BloomFilter concurrent add" {
    var bf = try BloomFilter.init(std.testing.allocator, 100000);
    defer bf.deinit();

    const Writer = struct {
        fn run(filter: *BloomFilter, offset: u32) void {
            var buf: [64]u8 = undefined;
            for (0..10000) |i| {
                const len = std.fmt.bufPrint(&buf, "https://t{d}_{d}.com", .{ offset, i }) catch continue;
                filter.add(len);
            }
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, Writer.run, .{ &bf, @as(u32, @intCast(idx)) });
    }
    for (&threads) |t| t.join();

    // Verify all 40,000 entries are present.
    var buf: [64]u8 = undefined;
    var missing: u32 = 0;
    for (0..4) |tid| {
        for (0..10000) |i| {
            const len = std.fmt.bufPrint(&buf, "https://t{d}_{d}.com", .{ tid, i }) catch continue;
            if (!bf.mayContain(len)) missing += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 0), missing);
}

test "BloomFilter empty filter never says yes" {
    var bf = try BloomFilter.init(std.testing.allocator, 1000);
    defer bf.deinit();

    try std.testing.expect(!bf.mayContain("anything"));
    try std.testing.expect(!bf.mayContain(""));
    try std.testing.expect(!bf.mayContain("https://example.com"));
    try std.testing.expectEqual(@as(u64, 0), bf.popCount());
}

test "BloomFilter concurrent add + query is safe" {
    var bf = try BloomFilter.init(std.testing.allocator, 100000);
    defer bf.deinit();

    const Adder = struct {
        fn run(filter: *BloomFilter) void {
            var buf: [64]u8 = undefined;
            for (0..5000) |i| {
                const s = std.fmt.bufPrint(&buf, "key{d}", .{i}) catch continue;
                filter.add(s);
            }
        }
    };
    const Reader = struct {
        fn run(filter: *BloomFilter, hits: *std.atomic.Value(u64)) void {
            var buf: [64]u8 = undefined;
            for (0..5000) |i| {
                const s = std.fmt.bufPrint(&buf, "key{d}", .{i}) catch continue;
                if (filter.mayContain(s)) _ = hits.fetchAdd(1, .monotonic);
            }
        }
    };

    var hits = std.atomic.Value(u64).init(0);
    const t1 = try std.Thread.spawn(.{}, Adder.run, .{&bf});
    const t2 = try std.Thread.spawn(.{}, Reader.run, .{ &bf, &hits });
    t1.join();
    t2.join();

    // After adder finished, every queried key must hit.
    var post: u32 = 0;
    var buf: [64]u8 = undefined;
    for (0..5000) |i| {
        const s = std.fmt.bufPrint(&buf, "key{d}", .{i}) catch continue;
        if (bf.mayContain(s)) post += 1;
    }
    try std.testing.expectEqual(@as(u32, 5000), post);
}

test "BloomFilter bit count grows monotonically" {
    var bf = try BloomFilter.init(std.testing.allocator, 10000);
    defer bf.deinit();

    var prev = bf.popCount();
    var buf: [64]u8 = undefined;
    for (0..200) |i| {
        const s = try std.fmt.bufPrint(&buf, "url-{d}-monotonic", .{i});
        bf.add(s);
        const now = bf.popCount();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}

test "BloomFilter overflow degrades but does not crash" {
    // Tiny capacity, then jam ten times the design size into it.
    var bf = try BloomFilter.init(std.testing.allocator, 1000);
    defer bf.deinit();

    var buf: [64]u8 = undefined;
    for (0..10_000) |i| {
        const s = std.fmt.bufPrint(&buf, "overflow-{d}", .{i}) catch continue;
        bf.add(s);
    }

    // Inserted items still report mayContain=true (no false negatives).
    for (0..10_000) |i| {
        const s = std.fmt.bufPrint(&buf, "overflow-{d}", .{i}) catch continue;
        try std.testing.expect(bf.mayContain(s));
    }

    // Bit count is bounded by num_bits (no overflow / panic).
    try std.testing.expect(bf.popCount() <= bf.num_bits);
}

test "BloomFilter hash determinism across instances" {
    var a = try BloomFilter.init(std.testing.allocator, 1000);
    defer a.deinit();
    var b = try BloomFilter.init(std.testing.allocator, 1000);
    defer b.deinit();

    a.add("https://hash-determinism.test");
    b.add("https://hash-determinism.test");

    // Identical inputs to identical-capacity filters must light identical
    // bits — that's what makes the bloom rebuildable from links_by_id.
    try std.testing.expectEqual(a.num_bits, b.num_bits);
    try std.testing.expectEqual(a.popCount(), b.popCount());

    // Lock down the property: every bit set in `a` is set in `b`.
    for (a.bits, b.bits) |*wa, *wb| {
        try std.testing.expectEqual(wa.load(.monotonic), wb.load(.monotonic));
    }
}

test "BloomFilter edge inputs (empty, single byte, max length)" {
    var bf = try BloomFilter.init(std.testing.allocator, 1000);
    defer bf.deinit();

    bf.add("");
    bf.add("x");
    var long_buf: [4096]u8 = undefined;
    @memset(&long_buf, 'q');
    bf.add(&long_buf);

    try std.testing.expect(bf.mayContain(""));
    try std.testing.expect(bf.mayContain("x"));
    try std.testing.expect(bf.mayContain(&long_buf));
}

test "BloomFilter init accepts variable capacities" {
    const caps = [_]u64{ 1, 1024, 100_000, 10_000_000 };
    inline for (caps) |cap| {
        var bf = try BloomFilter.init(std.testing.allocator, cap);
        defer bf.deinit();
        // num_bits is rounded up to >= 1024 minimum.
        try std.testing.expect(bf.num_bits >= 1024);
        bf.add("probe");
        try std.testing.expect(bf.mayContain("probe"));
    }
}
