//! The exact int8 vector index behind category search: every row is a unit vector quantized so
//! its largest component is ±127, and a query scores against all rows by a widened dot product.
//! The three column arrays and the position map always describe the same set of ids.

const std = @import("std");
const assert = std.debug.assert;
const schema = @import("schema.zig");
const ranking = @import("ranking.zig");

const dimensions = schema.embedding_dimensions;
const Row = [dimensions]i8;

pub const Embedding = [dimensions]f32;

pub const Quantized = struct {
    values: Row,
    scale: f32,
};

pub fn quantize(embedding: *const Embedding) ?Quantized {
    var norm_squared: f32 = 0;
    for (embedding) |x| {
        if (!std.math.isFinite(x)) return null;
        norm_squared += x * x;
    }
    if (!(norm_squared > 0)) return null;
    if (!std.math.isFinite(norm_squared)) return null;

    const inverse_norm = 1.0 / @sqrt(norm_squared);
    var component_abs_max: f32 = 0;
    for (embedding) |x| component_abs_max = @max(component_abs_max, @abs(x * inverse_norm));
    assert(component_abs_max > 0);

    const scale = component_abs_max / 127.0;
    assert(std.math.isFinite(scale));
    assert(scale > 0);
    var out: Quantized = .{ .values = undefined, .scale = scale };
    var largest: u8 = 0;
    for (embedding, &out.values) |x, *quantized| {
        quantized.* = @intFromFloat(std.math.clamp(@round(x * inverse_norm / scale), -127, 127));
        largest = @max(largest, @abs(quantized.*));
    }
    assert(largest > 0);
    return out;
}

pub fn read_embedding(bytes: *const [dimensions * 4]u8, out: *Embedding) void {
    comptime assert(@sizeOf(Embedding) == dimensions * 4);
    for (out, 0..) |*x, i| x.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
}

fn dot(a: *const Row, b: *const Row) i32 {
    comptime assert(dimensions * 128 * 128 <= std.math.maxInt(i32));
    const a_narrow: @Vector(dimensions, i8) = a.*;
    const b_narrow: @Vector(dimensions, i8) = b.*;
    const a_wide: @Vector(dimensions, i32) = a_narrow;
    const b_wide: @Vector(dimensions, i32) = b_narrow;
    return @reduce(.Add, a_wide *% b_wide);
}

pub fn similarity(stored: *const schema.StoredVector, query: *const Quantized) f64 {
    assert(std.math.isFinite(query.scale));
    assert(query.scale > 0);
    return @as(f64, @floatFromInt(dot(&stored.values, &query.values))) * stored.scale;
}

pub const VectorIndex = struct {
    lock: std.Io.RwLock = .init,
    ids: std.ArrayListUnmanaged(u64) = .empty,
    scales: std.ArrayListUnmanaged(f32) = .empty,
    rows: std.ArrayListUnmanaged(Row) = .empty,
    position: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    model: std.atomic.Value(u64) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    loader_stop: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *VectorIndex, allocator: std.mem.Allocator) void {
        assert(self.ids.items.len == self.scales.items.len);
        assert(self.ids.items.len == self.rows.items.len);
        self.ids.deinit(allocator);
        self.scales.deinit(allocator);
        self.rows.deinit(allocator);
        self.position.deinit(allocator);
    }

    pub fn put(
        self: *VectorIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        vector: *const schema.StoredVector,
    ) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.put_locked(allocator, vector);
    }

    pub fn put_locked(
        self: *VectorIndex,
        allocator: std.mem.Allocator,
        vector: *const schema.StoredVector,
    ) !void {
        assert(self.ids.items.len == self.scales.items.len);
        assert(self.ids.items.len == self.rows.items.len);
        if (self.position.get(vector.id)) |at| {
            assert(at < self.ids.items.len);
            self.scales.items[at] = vector.scale;
            self.rows.items[at] = vector.values;
            return;
        }
        assert(self.ids.items.len < std.math.maxInt(u32));
        try self.ids.ensureUnusedCapacity(allocator, 1);
        try self.scales.ensureUnusedCapacity(allocator, 1);
        try self.rows.ensureUnusedCapacity(allocator, 1);
        try self.position.put(allocator, vector.id, @intCast(self.ids.items.len));
        self.ids.appendAssumeCapacity(vector.id);
        self.scales.appendAssumeCapacity(vector.scale);
        self.rows.appendAssumeCapacity(vector.values);
        assert(self.position.count() == self.ids.items.len);
    }

    pub fn remove(self: *VectorIndex, io: std.Io, id: u64) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const removed = self.position.fetchRemove(id) orelse return;
        const at = removed.value;
        assert(at < self.ids.items.len);
        const last = self.ids.items.len - 1;
        if (at != last) {
            const moved_id = self.ids.items[last];
            self.ids.items[at] = moved_id;
            self.scales.items[at] = self.scales.items[last];
            self.rows.items[at] = self.rows.items[last];
            self.position.putAssumeCapacity(moved_id, at);
        }
        self.ids.items.len = last;
        self.scales.items.len = last;
        self.rows.items.len = last;
        assert(self.position.count() == self.ids.items.len);
        assert(self.ids.items.len == self.rows.items.len);
    }

    pub fn count(self: *VectorIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        assert(self.position.count() == self.ids.items.len);
        return self.ids.items.len;
    }

    pub fn nearest(
        self: *VectorIndex,
        io: std.Io,
        query: *const Quantized,
        out: []ranking.ScoredId,
    ) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        assert(self.ids.items.len == self.scales.items.len);
        assert(self.ids.items.len == self.rows.items.len);

        var top = ranking.TopK.init(out);
        for (self.ids.items, self.scales.items, self.rows.items) |id, scale, *row| {
            const score = @as(f64, @floatFromInt(dot(row, &query.values))) * scale;
            top.offer(.{ .id = id, .score = score });
        }
        const hits = top.sorted();
        assert(hits.len <= out.len);
        assert(hits.len <= self.ids.items.len);
        return hits;
    }

    pub fn score_ids(
        self: *VectorIndex,
        io: std.Io,
        ids: []const u64,
        query: *const Quantized,
        out: []ranking.ScoredId,
    ) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var top = ranking.TopK.init(out);
        for (ids) |id| {
            const at = self.position.get(id) orelse continue;
            assert(at < self.rows.items.len);
            const score = @as(
                f64,
                @floatFromInt(dot(&self.rows.items[at], &query.values)),
            ) * self.scales.items[at];
            top.offer(.{ .id = id, .score = score });
        }
        const hits = top.sorted();
        assert(hits.len <= ids.len);
        assert(hits.len <= out.len);
        return hits;
    }
};

fn unit_vector(axis: usize) Embedding {
    assert(axis < dimensions);
    var embedding: Embedding = @splat(0);
    embedding[axis] = 1;
    return embedding;
}

fn stored_vector(id: u64, embedding: *const Embedding) schema.StoredVector {
    assert(id != 0);
    const quantized = quantize(embedding).?;
    assert(quantized.scale > 0);
    return .{ .id = id, .scale = quantized.scale, .values = quantized.values };
}

// Fill two rows with the extreme int8 values in different patterns and compare the vector dot
// product with a scalar sum widened to i32.
test "dot over extreme i8 rows equals the scalar widened sum" {
    var a: Row = undefined;
    var b: Row = undefined;
    for (&a, &b, 0..) |*x, *y, i| {
        x.* = if (i % 2 == 0) -128 else 127;
        y.* = if (i % 3 == 0) -128 else 127;
    }
    var expected: i32 = 0;
    for (a, b) |x, y| expected += @as(i32, x) * @as(i32, y);
    try std.testing.expectEqual(expected, dot(&a, &b));
}

// Quantize a 3-4-5 vector: the largest component lands on 127, the scale is its magnitude over
// 127, and a zero or NaN input is refused.
test "quantize normalises and scales the largest component to 127" {
    var embedding: Embedding = @splat(0);
    embedding[0] = 3;
    embedding[1] = -4;
    const quantized = quantize(&embedding).?;
    try std.testing.expectEqual(@as(i8, 95), quantized.values[0]);
    try std.testing.expectEqual(@as(i8, -127), quantized.values[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8 / 127.0), quantized.scale, 1e-6);

    try std.testing.expectEqual(@as(?Quantized, null), quantize(&@as(Embedding, @splat(0))));
    embedding[2] = std.math.nan(f32);
    try std.testing.expectEqual(@as(?Quantized, null), quantize(&embedding));
}

// Store three vectors, query along one axis, then remove and re-put rows and check the ranking
// and the count follow every change.
test "nearest ranks by dot product and remove keeps the remaining rows addressable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var index: VectorIndex = .{};
    defer index.deinit(allocator);

    try index.put(io, allocator, &stored_vector(1, &unit_vector(0)));
    try index.put(io, allocator, &stored_vector(2, &unit_vector(1)));
    var mixed: Embedding = @splat(0);
    mixed[0] = 1;
    mixed[1] = 1;
    try index.put(io, allocator, &stored_vector(3, &mixed));

    const query = quantize(&unit_vector(0)).?;
    var buffer: [2]ranking.ScoredId = undefined;
    var hits = index.nearest(io, &query, &buffer);
    try std.testing.expectEqual(@as(u64, 1), hits[0].id);
    try std.testing.expectEqual(@as(u64, 3), hits[1].id);

    index.remove(io, 1);
    try std.testing.expectEqual(@as(usize, 2), index.count(io));
    hits = index.nearest(io, &query, &buffer);
    try std.testing.expectEqual(@as(u64, 3), hits[0].id);
    try std.testing.expectEqual(@as(u64, 2), hits[1].id);

    try index.put(io, allocator, &stored_vector(2, &unit_vector(0)));
    hits = index.nearest(io, &query, &buffer);
    try std.testing.expectEqual(@as(u64, 2), hits[0].id);
    try std.testing.expectEqual(@as(usize, 2), index.count(io));
}

// Ask for a subset of ids including one that was never stored and check only the stored ones
// come back, in score order.
test "score_ids ranks only the asked ids and skips ids without a vector" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var index: VectorIndex = .{};
    defer index.deinit(allocator);

    try index.put(io, allocator, &stored_vector(1, &unit_vector(0)));
    try index.put(io, allocator, &stored_vector(2, &unit_vector(1)));
    var mixed: Embedding = @splat(0);
    mixed[0] = 1;
    mixed[1] = 1;
    try index.put(io, allocator, &stored_vector(3, &mixed));

    const query = quantize(&unit_vector(0)).?;
    var buffer: [4]ranking.ScoredId = undefined;
    const hits = index.score_ids(io, &.{ 3, 2, 99 }, &query, &buffer);
    try std.testing.expectEqual(@as(usize, 2), hits.len);
    try std.testing.expectEqual(@as(u64, 3), hits[0].id);
    try std.testing.expectEqual(@as(u64, 2), hits[1].id);
}
