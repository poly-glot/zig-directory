const std = @import("std");
const schema = @import("schema.zig");

pub const DIMS = schema.EMBEDDING_DIMS;
pub const CELLS: usize = 256;
pub const M = schema.PQ_SUBQUANTIZERS;
pub const K: usize = 256;
pub const SUB: usize = DIMS / M;
pub const MIN_PROBE: usize = 32;

const MAGIC: u32 = 0x4D564D44;
const VERSION: u32 = 1;
const HEADER_BYTES: usize = 24;
const CENTROID_FLOATS: usize = CELLS * DIMS;
const BOOK_FLOATS: usize = M * K * SUB;
pub const FILE_BYTES: usize = HEADER_BYTES + (CENTROID_FLOATS + BOOK_FLOATS) * 4;

pub const Float = [DIMS]f32;
pub const Codes = [M]u8;
pub const Lut = [M * K]f32;
pub const Encoded = struct { cell: u16, codes: Codes };

pub const LoadError = error{ VectorModelTruncated, VectorModelFormat, VectorModelShape };

pub const Model = struct {
    centroids: *[CELLS]Float,
    books: *[M][K][SUB]f32,
    book_norms: *[M][K]f32,
    hash: u64,

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*Model {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const bytes = try allocator.alloc(u8, FILE_BYTES);
        defer allocator.free(bytes);
        const got = try file.readPositionalAll(io, bytes, 0);
        if (got != FILE_BYTES) return LoadError.VectorModelTruncated;

        return fromBytes(allocator, bytes);
    }

    pub fn fromBytes(allocator: std.mem.Allocator, bytes: []const u8) !*Model {
        if (bytes.len != FILE_BYTES) return LoadError.VectorModelTruncated;
        if (readU32(bytes, 0) != MAGIC or readU32(bytes, 4) != VERSION) return LoadError.VectorModelFormat;
        if (readU32(bytes, 8) != CELLS or readU32(bytes, 12) != M or readU32(bytes, 16) != K or readU32(bytes, 20) != DIMS) return LoadError.VectorModelShape;

        const self = try allocator.create(Model);
        errdefer allocator.destroy(self);
        self.centroids = try allocator.create([CELLS]Float);
        errdefer allocator.destroy(self.centroids);
        self.books = try allocator.create([M][K][SUB]f32);
        errdefer allocator.destroy(self.books);
        self.book_norms = try allocator.create([M][K]f32);
        errdefer allocator.destroy(self.book_norms);

        readFloats(bytes[HEADER_BYTES..][0 .. CENTROID_FLOATS * 4], @ptrCast(self.centroids));
        readFloats(bytes[HEADER_BYTES + CENTROID_FLOATS * 4 ..][0 .. BOOK_FLOATS * 4], @ptrCast(self.books));
        self.hash = std.hash.Fnv1a_64.hash(bytes);
        self.computeBookNorms();
        return self;
    }

    pub fn deinit(self: *const Model, allocator: std.mem.Allocator) void {
        allocator.destroy(self.centroids);
        allocator.destroy(self.books);
        allocator.destroy(self.book_norms);
        allocator.destroy(self);
    }

    pub fn synthetic(allocator: std.mem.Allocator, seed: u64) !*Model {
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        const bytes = try allocator.alloc(u8, FILE_BYTES);
        defer allocator.free(bytes);
        writeU32(bytes, 0, MAGIC);
        writeU32(bytes, 4, VERSION);
        writeU32(bytes, 8, CELLS);
        writeU32(bytes, 12, M);
        writeU32(bytes, 16, K);
        writeU32(bytes, 20, DIMS);

        var at: usize = HEADER_BYTES;
        for (0..CELLS) |_| {
            var centroid: Float = undefined;
            for (&centroid) |*x| x.* = random.floatNorm(f32);
            normalizeInPlace(&centroid);
            for (centroid) |x| {
                writeF32(bytes, at, x);
                at += 4;
            }
        }
        const component_scale = 1.0 / @sqrt(@as(f32, DIMS));
        for (0..BOOK_FLOATS) |_| {
            writeF32(bytes, at, random.floatNorm(f32) * component_scale);
            at += 4;
        }
        return fromBytes(allocator, bytes);
    }

    pub fn encode(self: *const Model, stored: *const schema.StoredVector) Encoded {
        var v: Float = undefined;
        dequantize(stored, &v);
        return self.encodeFloat(&v);
    }

    pub fn encodeFloat(self: *const Model, v: *const Float) Encoded {
        var out: Encoded = .{ .cell = self.nearestCell(v), .codes = undefined };
        for (0..M) |m| {
            const sub: @Vector(SUB, f32) = v[m * SUB ..][0..SUB].*;
            var best_k: usize = 0;
            var best_d: f32 = std.math.inf(f32);
            for (0..K) |k| {
                const center: @Vector(SUB, f32) = self.books[m][k];
                const d = self.book_norms[m][k] - 2 * @reduce(.Add, sub * center);
                if (d < best_d) {
                    best_d = d;
                    best_k = k;
                }
            }
            out.codes[m] = @intCast(best_k);
        }
        return out;
    }

    pub fn nearestCell(self: *const Model, v: *const Float) u16 {
        var best: usize = 0;
        var best_score = -std.math.inf(f32);
        for (self.centroids, 0..) |*centroid, i| {
            const score = dot(centroid, v);
            if (score > best_score) {
                best_score = score;
                best = i;
            }
        }
        return @intCast(best);
    }

    pub fn rankCells(self: *const Model, query: *const Float, out: *[CELLS]u16) void {
        var scores: [CELLS]f32 = undefined;
        for (self.centroids, &scores) |*centroid, *score| score.* = dot(centroid, query);
        for (out, 0..) |*slot, i| slot.* = @intCast(i);
        std.sort.pdq(u16, out, &scores, cellRanksBefore);
    }

    pub fn lut(self: *const Model, query: *const Float, out: *Lut) void {
        for (0..M) |m| {
            const sub: @Vector(SUB, f32) = query[m * SUB ..][0..SUB].*;
            for (0..K) |k| {
                const center: @Vector(SUB, f32) = self.books[m][k];
                out[m * K + k] = @reduce(.Add, sub * center);
            }
        }
    }

    fn computeBookNorms(self: *Model) void {
        for (0..M) |m| {
            for (0..K) |k| {
                const center: @Vector(SUB, f32) = self.books[m][k];
                self.book_norms[m][k] = @reduce(.Add, center * center);
            }
        }
    }
};

fn cellRanksBefore(scores: *const [CELLS]f32, a: u16, b: u16) bool {
    if (scores[a] != scores[b]) return scores[a] > scores[b];
    return a < b;
}

pub fn dequantize(stored: *const schema.StoredVector, out: *Float) void {
    for (out, stored.values) |*x, q| x.* = @as(f32, @floatFromInt(q)) * stored.scale;
}

pub fn normalizeInPlace(v: *Float) void {
    const inv_norm = 1.0 / @sqrt(dot(v, v));
    for (v) |*x| x.* *= inv_norm;
}

pub fn dot(a: *const Float, b: *const Float) f32 {
    const va: @Vector(DIMS, f32) = a.*;
    const vb: @Vector(DIMS, f32) = b.*;
    return @reduce(.Add, va * vb);
}

pub fn approximateScore(lut: *const Lut, codes: *const Codes) f32 {
    var sum: f32 = 0;
    for (codes, 0..) |code, m| sum += lut[m * K + code];
    return sum;
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn writeU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn writeF32(bytes: []u8, at: usize, value: f32) void {
    writeU32(bytes, at, @bitCast(value));
}

fn readFloats(bytes: []const u8, out: [*]f32) void {
    for (0..bytes.len / 4) |i| out[i] = @bitCast(readU32(bytes, i * 4));
}

const testing = std.testing;

fn axis(i: usize) Float {
    var v: Float = @splat(0);
    v[i] = 1;
    return v;
}

test "a synthetic model round-trips through the file parser and hashes its bytes" {
    const a = try Model.synthetic(testing.allocator, 1);
    defer a.deinit(testing.allocator);
    const b = try Model.synthetic(testing.allocator, 1);
    defer b.deinit(testing.allocator);
    const c = try Model.synthetic(testing.allocator, 2);
    defer c.deinit(testing.allocator);

    try testing.expectEqual(a.hash, b.hash);
    try testing.expect(a.hash != c.hash);
    try testing.expectApproxEqAbs(@as(f32, 1), dot(&a.centroids[0], &a.centroids[0]), 1e-4);
}

test "the parser refuses a truncated file, a wrong magic, and a wrong shape" {
    const bytes = try testing.allocator.alloc(u8, FILE_BYTES);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);

    try testing.expectError(LoadError.VectorModelTruncated, Model.fromBytes(testing.allocator, bytes[0 .. FILE_BYTES - 1]));
    try testing.expectError(LoadError.VectorModelFormat, Model.fromBytes(testing.allocator, bytes));

    writeU32(bytes, 0, MAGIC);
    writeU32(bytes, 4, VERSION);
    writeU32(bytes, 8, CELLS);
    writeU32(bytes, 12, M);
    writeU32(bytes, 16, K);
    writeU32(bytes, 20, DIMS + 1);
    try testing.expectError(LoadError.VectorModelShape, Model.fromBytes(testing.allocator, bytes));
}

test "the nearest cell is the centroid with the largest dot product and rankCells puts it first" {
    const model = try Model.synthetic(testing.allocator, 3);
    defer model.deinit(testing.allocator);

    const query = model.centroids[17];
    try testing.expectEqual(@as(u16, 17), model.nearestCell(&query));

    var order: [CELLS]u16 = undefined;
    model.rankCells(&query, &order);
    try testing.expectEqual(@as(u16, 17), order[0]);
    for (order[0 .. CELLS - 1], order[1..]) |first, second| {
        try testing.expect(dot(&model.centroids[first], &query) >= dot(&model.centroids[second], &query));
    }
}

fn randomUnit(seed: u64) Float {
    var prng = std.Random.DefaultPrng.init(seed);
    var v: Float = undefined;
    for (&v) |*x| x.* = prng.random().floatNorm(f32);
    normalizeInPlace(&v);
    return v;
}

test "the LUT score of a vector's own codes tracks its exact dot product" {
    const model = try Model.synthetic(testing.allocator, 4);
    defer model.deinit(testing.allocator);

    const v = randomUnit(40);
    const encoded = model.encodeFloat(&v);

    var lut: Lut = undefined;
    model.lut(&v, &lut);
    const approx = approximateScore(&lut, &encoded.codes);
    const exact = dot(&v, &v);
    try testing.expect(@abs(approx - exact) < 0.35);

    const other = randomUnit(41);
    try testing.expect(approximateScore(&lut, &model.encodeFloat(&other).codes) < approx);
}

test "encode dequantises an int8 row before coding so a stored vector codes like its float source" {
    const model = try Model.synthetic(testing.allocator, 5);
    defer model.deinit(testing.allocator);

    var v: Float = undefined;
    for (&v, 0..) |*x, i| x.* = @floatFromInt((i % 7) + 1);
    normalizeInPlace(&v);
    const q = @import("vector_index.zig").quantize(&v).?;
    const stored = schema.StoredVector{ .id = 1, .scale = q.scale, .values = q.values };

    const from_float = model.encodeFloat(&v);
    const from_stored = model.encode(&stored);
    try testing.expectEqual(from_float.cell, from_stored.cell);
    var agree: usize = 0;
    for (from_float.codes, from_stored.codes) |a, b| agree += @intFromBool(a == b);
    try testing.expect(agree >= M - 4);
}
