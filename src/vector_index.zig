const std = @import("std");
const schema = @import("schema.zig");
const ranking = @import("ranking.zig");

const DIMS = schema.EMBEDDING_DIMS;
const Row = [DIMS]i8;

pub const Embedding = [DIMS]f32;

pub const Quantized = struct {
    values: Row,
    scale: f32,
};

pub fn quantize(embedding: *const Embedding) ?Quantized {
    var norm_sq: f32 = 0;
    for (embedding) |x| {
        if (!std.math.isFinite(x)) return null;
        norm_sq += x * x;
    }
    if (!(norm_sq > 0) or !std.math.isFinite(norm_sq)) return null;

    const inv_norm = 1.0 / @sqrt(norm_sq);
    var max_abs: f32 = 0;
    for (embedding) |x| max_abs = @max(max_abs, @abs(x * inv_norm));

    const scale = max_abs / 127.0;
    var out: Quantized = .{ .values = undefined, .scale = scale };
    for (embedding, &out.values) |x, *q| {
        q.* = @intFromFloat(std.math.clamp(@round(x * inv_norm / scale), -127, 127));
    }
    return out;
}

pub fn readEmbedding(bytes: *const [DIMS * 4]u8, out: *Embedding) void {
    for (out, 0..) |*x, i| x.* = @bitCast(std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little));
}

fn dot(a: *const Row, b: *const Row) i32 {
    const a8: @Vector(DIMS, i8) = a.*;
    const b8: @Vector(DIMS, i8) = b.*;
    const a32: @Vector(DIMS, i32) = a8;
    const b32: @Vector(DIMS, i32) = b8;
    return @reduce(.Add, a32 *% b32);
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
        self.ids.deinit(allocator);
        self.scales.deinit(allocator);
        self.rows.deinit(allocator);
        self.position.deinit(allocator);
    }

    pub fn put(self: *VectorIndex, io: std.Io, allocator: std.mem.Allocator, v: schema.LinkVector) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.putLocked(allocator, v);
    }

    pub fn putLocked(self: *VectorIndex, allocator: std.mem.Allocator, v: schema.LinkVector) !void {
        if (self.position.get(v.link_id)) |at| {
            self.scales.items[at] = v.scale;
            self.rows.items[at] = v.values;
            return;
        }
        try self.ids.ensureUnusedCapacity(allocator, 1);
        try self.scales.ensureUnusedCapacity(allocator, 1);
        try self.rows.ensureUnusedCapacity(allocator, 1);
        try self.position.put(allocator, v.link_id, @intCast(self.ids.items.len));
        self.ids.appendAssumeCapacity(v.link_id);
        self.scales.appendAssumeCapacity(v.scale);
        self.rows.appendAssumeCapacity(v.values);
    }

    pub fn remove(self: *VectorIndex, io: std.Io, link_id: u64) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);

        const removed = self.position.fetchRemove(link_id) orelse return;
        const at = removed.value;
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
    }

    pub fn count(self: *VectorIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.ids.items.len;
    }

    pub fn nearest(self: *VectorIndex, io: std.Io, query: *const Quantized, out: []ranking.ScoredId) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var top = ranking.TopK.init(out);
        for (self.ids.items, self.scales.items, self.rows.items) |id, scale, *row| {
            const similarity = @as(f64, @floatFromInt(dot(row, &query.values))) * scale;
            top.offer(.{ .id = id, .score = similarity });
        }
        return top.sorted();
    }
};

fn unitVector(axis: usize) Embedding {
    var e: Embedding = @splat(0);
    e[axis] = 1;
    return e;
}

fn storedVector(link_id: u64, embedding: *const Embedding) schema.LinkVector {
    const q = quantize(embedding).?;
    return .{ .link_id = link_id, .scale = q.scale, .values = q.values };
}

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

test "quantize normalises, scales the largest component to 127, and rejects zero or non-finite input" {
    var e: Embedding = @splat(0);
    e[0] = 3;
    e[1] = -4;
    const q = quantize(&e).?;
    try std.testing.expectEqual(@as(i8, 95), q.values[0]);
    try std.testing.expectEqual(@as(i8, -127), q.values[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8 / 127.0), q.scale, 1e-6);

    try std.testing.expectEqual(@as(?Quantized, null), quantize(&@as(Embedding, @splat(0))));
    e[2] = std.math.nan(f32);
    try std.testing.expectEqual(@as(?Quantized, null), quantize(&e));
}

test "nearest ranks by dot product and remove keeps the remaining rows addressable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var index: VectorIndex = .{};
    defer index.deinit(allocator);

    try index.put(io, allocator, storedVector(1, &unitVector(0)));
    try index.put(io, allocator, storedVector(2, &unitVector(1)));
    var mixed: Embedding = @splat(0);
    mixed[0] = 1;
    mixed[1] = 1;
    try index.put(io, allocator, storedVector(3, &mixed));

    const query = quantize(&unitVector(0)).?;
    var buf: [2]ranking.ScoredId = undefined;
    var hits = index.nearest(io, &query, &buf);
    try std.testing.expectEqual(@as(u64, 1), hits[0].id);
    try std.testing.expectEqual(@as(u64, 3), hits[1].id);

    index.remove(io, 1);
    try std.testing.expectEqual(@as(usize, 2), index.count(io));
    hits = index.nearest(io, &query, &buf);
    try std.testing.expectEqual(@as(u64, 3), hits[0].id);
    try std.testing.expectEqual(@as(u64, 2), hits[1].id);

    try index.put(io, allocator, storedVector(2, &unitVector(0)));
    hits = index.nearest(io, &query, &buf);
    try std.testing.expectEqual(@as(u64, 2), hits[0].id);
    try std.testing.expectEqual(@as(usize, 2), index.count(io));
}
