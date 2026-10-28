//! The product-quantization model behind link vector search: `cell_count` IVF centroids and `M`
//! codebooks of `K` centers over `sub_dimensions` floats each, read from one little-endian file
//! whose header names its shape. A loaded model holds only finite floats, so every score the
//! indexes derive from it is a number.

const std = @import("std");
const assert = std.debug.assert;
const schema = @import("schema.zig");

pub const dimensions = schema.embedding_dimensions;
pub const cell_count: usize = 256;
pub const M = schema.pq_subquantizers;
pub const K: usize = 256;
pub const sub_dimensions: usize = @divExact(dimensions, M);
pub const probe_min: usize = 32;

const file_magic: u32 = 0x4D564D44;
const file_version: u32 = 1;
const header_bytes: usize = 24;
const centroid_floats: usize = cell_count * dimensions;
const book_floats: usize = M * K * sub_dimensions;
pub const file_bytes: usize = header_bytes + (centroid_floats + book_floats) * 4;

pub const Float = [dimensions]f32;
pub const Codes = [M]u8;
pub const Lut = [M * K]f32;
pub const Encoded = struct { cell: u16, codes: Codes };

pub const LoadError = error{
    VectorModelTruncated,
    VectorModelFormat,
    VectorModelShape,
    VectorModelValue,
};

pub const Model = struct {
    centroids: *[cell_count]Float,
    books: *[M][K][sub_dimensions]f32,
    book_norms: *[M][K]f32,
    hash: u64,

    pub fn load(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !*Model {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);

        const bytes = try allocator.alloc(u8, file_bytes);
        defer allocator.free(bytes);

        const read_len = try file.readPositionalAll(io, bytes, 0);
        assert(read_len <= file_bytes);
        if (read_len != file_bytes) return LoadError.VectorModelTruncated;

        return from_bytes(allocator, bytes);
    }

    pub fn from_bytes(allocator: std.mem.Allocator, bytes: []const u8) !*Model {
        comptime assert(header_bytes == 6 * @sizeOf(u32));
        comptime assert(@sizeOf([cell_count]Float) == centroid_floats * @sizeOf(f32));
        comptime assert(@sizeOf([M][K][sub_dimensions]f32) == book_floats * @sizeOf(f32));
        if (bytes.len != file_bytes) return LoadError.VectorModelTruncated;
        if (read_u32(bytes, 0) != file_magic) return LoadError.VectorModelFormat;
        if (read_u32(bytes, 4) != file_version) return LoadError.VectorModelFormat;
        if (read_u32(bytes, 8) != cell_count) return LoadError.VectorModelShape;
        if (read_u32(bytes, 12) != M) return LoadError.VectorModelShape;
        if (read_u32(bytes, 16) != K) return LoadError.VectorModelShape;
        if (read_u32(bytes, 20) != dimensions) return LoadError.VectorModelShape;

        const self = try allocator.create(Model);
        errdefer allocator.destroy(self);
        self.centroids = try allocator.create([cell_count]Float);
        errdefer allocator.destroy(self.centroids);
        self.books = try allocator.create([M][K][sub_dimensions]f32);
        errdefer allocator.destroy(self.books);
        self.book_norms = try allocator.create([M][K]f32);
        errdefer allocator.destroy(self.book_norms);

        const centroid_bytes = bytes[header_bytes..][0 .. centroid_floats * 4];
        const book_bytes = bytes[header_bytes + centroid_floats * 4 ..][0 .. book_floats * 4];
        try read_floats(centroid_bytes, @as(*[centroid_floats]f32, @ptrCast(self.centroids)));
        try read_floats(book_bytes, @as(*[book_floats]f32, @ptrCast(self.books)));
        self.hash = std.hash.Fnv1a_64.hash(bytes);
        // A stored link vector carries `model_hash = 0` when no model coded it, and its codes
        // are reused only when that hash matches the loaded model, so a model must never hash
        // to zero.
        assert(self.hash != 0);
        self.compute_book_norms();
        return self;
    }

    pub fn deinit(self: *const Model, allocator: std.mem.Allocator) void {
        allocator.destroy(self.centroids);
        allocator.destroy(self.books);
        allocator.destroy(self.book_norms);
        allocator.destroy(self);
    }

    pub fn synthetic(allocator: std.mem.Allocator, seed: u64) !*Model {
        comptime assert(header_bytes == 6 * @sizeOf(u32));
        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();

        const bytes = try allocator.alloc(u8, file_bytes);
        defer allocator.free(bytes);

        write_u32(bytes, 0, file_magic);
        write_u32(bytes, 4, file_version);
        write_u32(bytes, 8, cell_count);
        write_u32(bytes, 12, M);
        write_u32(bytes, 16, K);
        write_u32(bytes, 20, dimensions);

        var at: usize = header_bytes;
        for (0..cell_count) |_| {
            var centroid: Float = undefined;
            for (&centroid) |*x| x.* = random.floatNorm(f32);
            normalize_in_place(&centroid);
            assert(@abs(dot(&centroid, &centroid) - 1) < 1e-3);
            for (centroid) |x| {
                write_u32(bytes, at, @bitCast(x));
                at += 4;
            }
        }
        assert(at == header_bytes + centroid_floats * 4);
        const component_scale = 1.0 / @sqrt(@as(f32, dimensions));
        for (0..book_floats) |_| {
            write_u32(bytes, at, @bitCast(random.floatNorm(f32) * component_scale));
            at += 4;
        }
        assert(at == file_bytes);
        return from_bytes(allocator, bytes);
    }

    pub fn encode(self: *const Model, stored: *const schema.StoredVector) Encoded {
        comptime assert(@typeInfo(@TypeOf(stored.values)).array.len == dimensions);
        var vector: Float = undefined;
        for (&vector, stored.values) |*x, quantized| {
            x.* = @as(f32, @floatFromInt(quantized)) * stored.scale;
        }
        const encoded = self.encode_float(&vector);
        assert(encoded.cell < cell_count);
        return encoded;
    }

    pub fn encode_float(self: *const Model, vector: *const Float) Encoded {
        comptime assert(M * sub_dimensions == dimensions);
        comptime assert(K - 1 <= std.math.maxInt(u8));
        var out: Encoded = .{ .cell = self.nearest_cell(vector), .codes = undefined };
        assert(out.cell < cell_count);
        for (0..M) |m| {
            const sub_slice = vector[m * sub_dimensions ..][0..sub_dimensions];
            const sub: @Vector(sub_dimensions, f32) = sub_slice.*;
            var best_k: usize = 0;
            var best_distance: f32 = std.math.inf(f32);
            for (0..K) |k| {
                const center: @Vector(sub_dimensions, f32) = self.books[m][k];
                const distance = self.book_norms[m][k] - 2 * @reduce(.Add, sub * center);
                if (distance < best_distance) {
                    best_distance = distance;
                    best_k = k;
                }
            }
            assert(best_k < K);
            out.codes[m] = @intCast(best_k);
        }
        return out;
    }

    pub fn nearest_cell(self: *const Model, vector: *const Float) u16 {
        comptime assert(cell_count - 1 <= std.math.maxInt(u16));
        var best: usize = 0;
        var best_score = -std.math.inf(f32);
        for (self.centroids, 0..) |*centroid, index| {
            const score = dot(centroid, vector);
            if (score > best_score) {
                best_score = score;
                best = index;
            }
        }
        assert(best < cell_count);
        return @intCast(best);
    }

    pub fn rank_cells(self: *const Model, query: *const Float, out: *[cell_count]u16) void {
        comptime assert(cell_count - 1 <= std.math.maxInt(u16));
        var scores: [cell_count]f32 = undefined;
        for (self.centroids, &scores) |*centroid, *score| score.* = dot(centroid, query);
        for (out, 0..) |*slot, index| slot.* = @intCast(index);
        std.sort.pdq(u16, out, &scores, cell_ranks_before);

        var seen = std.StaticBitSet(cell_count).initEmpty();
        for (out) |cell| seen.set(cell);
        assert(seen.count() == cell_count);
        for (out[0 .. cell_count - 1], out[1..]) |first, second| {
            assert(!cell_ranks_before(&scores, second, first));
        }
    }

    pub fn lut(self: *const Model, query: *const Float, out: *Lut) void {
        comptime assert(M * sub_dimensions == dimensions);
        comptime assert(M * K == @typeInfo(Lut).array.len);
        comptime assert(K == std.math.maxInt(u8) + 1);
        for (0..M) |m| {
            const sub_slice = query[m * sub_dimensions ..][0..sub_dimensions];
            const sub: @Vector(sub_dimensions, f32) = sub_slice.*;
            for (0..K) |k| {
                const center: @Vector(sub_dimensions, f32) = self.books[m][k];
                out[m * K + k] = @reduce(.Add, sub * center);
            }
        }
    }

    fn compute_book_norms(self: *Model) void {
        for (0..M) |m| {
            for (0..K) |k| {
                const center: @Vector(sub_dimensions, f32) = self.books[m][k];
                const norm = @reduce(.Add, center * center);
                assert(norm >= 0);
                self.book_norms[m][k] = norm;
            }
        }
    }
};

fn cell_ranks_before(scores: *const [cell_count]f32, a: u16, b: u16) bool {
    assert(a < cell_count);
    assert(b < cell_count);
    if (scores[a] != scores[b]) return scores[a] > scores[b];
    return a < b;
}

pub fn normalize_in_place(vector: *Float) void {
    const norm_squared = dot(vector, vector);
    assert(norm_squared > 0);
    const inverse_norm = 1.0 / @sqrt(norm_squared);
    assert(std.math.isFinite(inverse_norm));
    for (vector) |*x| x.* *= inverse_norm;
}

pub fn dot(a: *const Float, b: *const Float) f32 {
    const a_vector: @Vector(dimensions, f32) = a.*;
    const b_vector: @Vector(dimensions, f32) = b.*;
    return @reduce(.Add, a_vector * b_vector);
}

pub fn approximate_score(lut: *const Lut, codes: *const Codes) f32 {
    comptime assert(M * K == @typeInfo(Lut).array.len);
    comptime assert(K == std.math.maxInt(u8) + 1);
    var sum: f32 = 0;
    for (codes, 0..) |code, m| sum += lut[m * K + code];
    return sum;
}

fn read_u32(bytes: []const u8, at: usize) u32 {
    assert(at % @sizeOf(u32) == 0);
    assert(at + @sizeOf(u32) <= bytes.len);
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn write_u32(bytes: []u8, at: usize, value: u32) void {
    assert(at % @sizeOf(u32) == 0);
    assert(at + @sizeOf(u32) <= bytes.len);
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn read_floats(bytes: []const u8, out: []f32) LoadError!void {
    assert(bytes.len % @sizeOf(f32) == 0);
    assert(out.len * @sizeOf(f32) == bytes.len);
    for (out, 0..) |*x, index| {
        const value: f32 = @bitCast(read_u32(bytes, index * 4));
        if (!std.math.isFinite(value)) return LoadError.VectorModelValue;
        x.* = value;
    }
}

const testing = std.testing;

// Build two models from the same seed and one from another: equal seeds hash equal, a different
// seed hashes differently, and every centroid is a unit vector.
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

// Hand the parser a short buffer, a zeroed header, a header with the wrong dimension count and
// a valid header followed by a NaN float, and check each is refused with its own error.
test "the parser refuses a truncated file, a wrong magic, a wrong shape and a NaN float" {
    const bytes = try testing.allocator.alloc(u8, file_bytes);
    defer testing.allocator.free(bytes);
    @memset(bytes, 0);

    try testing.expectError(
        LoadError.VectorModelTruncated,
        Model.from_bytes(testing.allocator, bytes[0 .. file_bytes - 1]),
    );
    try testing.expectError(
        LoadError.VectorModelFormat,
        Model.from_bytes(testing.allocator, bytes),
    );

    write_u32(bytes, 0, file_magic);
    write_u32(bytes, 4, file_version);
    write_u32(bytes, 8, cell_count);
    write_u32(bytes, 12, M);
    write_u32(bytes, 16, K);
    write_u32(bytes, 20, dimensions + 1);
    try testing.expectError(LoadError.VectorModelShape, Model.from_bytes(testing.allocator, bytes));

    write_u32(bytes, 20, dimensions);
    write_u32(bytes, header_bytes, @bitCast(std.math.nan(f32)));
    try testing.expectError(LoadError.VectorModelValue, Model.from_bytes(testing.allocator, bytes));
}

// Query with a centroid itself: nearest_cell answers its index, rank_cells puts it first and the
// rest follow in descending dot product.
test "the nearest cell is the centroid with the largest dot product and rank_cells puts it first" {
    const model = try Model.synthetic(testing.allocator, 3);
    defer model.deinit(testing.allocator);

    const query = model.centroids[17];
    try testing.expectEqual(@as(u16, 17), model.nearest_cell(&query));

    var order: [cell_count]u16 = undefined;
    model.rank_cells(&query, &order);
    try testing.expectEqual(@as(u16, 17), order[0]);
    for (order[0 .. cell_count - 1], order[1..]) |first, second| {
        try testing.expect(dot(
            &model.centroids[first],
            &query,
        ) >= dot(&model.centroids[second], &query));
    }
}

fn random_unit(seed: u64) Float {
    var prng = std.Random.DefaultPrng.init(seed);
    var vector: Float = undefined;
    for (&vector) |*x| x.* = prng.random().floatNorm(f32);
    normalize_in_place(&vector);
    assert(@abs(dot(&vector, &vector) - 1) < 1e-3);
    return vector;
}

// Code a random unit vector, score its own codes through its LUT and check the result is close
// to its exact self dot product and above the score of another vector's codes.
test "the LUT score of a vector's own codes tracks its exact dot product" {
    const model = try Model.synthetic(testing.allocator, 4);
    defer model.deinit(testing.allocator);

    const vector = random_unit(40);
    const encoded = model.encode_float(&vector);

    var lut: Lut = undefined;
    model.lut(&vector, &lut);
    const approx = approximate_score(&lut, &encoded.codes);
    const exact = dot(&vector, &vector);
    try testing.expect(@abs(approx - exact) < 0.35);

    const other = random_unit(41);
    try testing.expect(approximate_score(&lut, &model.encode_float(&other).codes) < approx);
}

// Quantize a float vector to int8, encode both forms and check the cell agrees and nearly every
// code does, so a stored row codes like the embedding it came from.
test "encode dequantises an int8 row before coding it" {
    const model = try Model.synthetic(testing.allocator, 5);
    defer model.deinit(testing.allocator);

    var vector: Float = undefined;
    for (&vector, 0..) |*x, i| x.* = @floatFromInt((i % 7) + 1);
    normalize_in_place(&vector);
    const quantized = @import("vector_index.zig").quantize(&vector).?;
    const stored = schema.StoredVector{
        .id = 1,
        .scale = quantized.scale,
        .values = quantized.values,
    };

    const from_float = model.encode_float(&vector);
    const from_stored = model.encode(&stored);
    try testing.expectEqual(from_float.cell, from_stored.cell);
    var agree: usize = 0;
    for (from_float.codes, from_stored.codes) |a, b| agree += @intFromBool(a == b);
    try testing.expect(agree >= M - 4);
}
