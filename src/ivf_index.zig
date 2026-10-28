//! The IVF-PQ index over link vectors: every vector lives in one of `cell_count` cells as `M`
//! one-byte codes, stored transposed in blocks of `block_vectors` rows so a block scores with one
//! gather per codebook. A cell's code array is always whole blocks with no empty trailing block,
//! and the position map and the cells always describe the same set of ids.

const std = @import("std");
const assert = std.debug.assert;
const ranking = @import("ranking.zig");
const vector_model = @import("vector_model.zig");

const Model = vector_model.Model;
const Codes = vector_model.Codes;
const Encoded = vector_model.Encoded;
const Float = vector_model.Float;
const Lut = vector_model.Lut;
const cell_count = vector_model.cell_count;
const M = vector_model.M;
const K = vector_model.K;

pub const block_vectors: usize = 8;
const block_bytes: usize = M * block_vectors;

const Position = struct { cell: u16, index: u32 };

const Cell = struct {
    codes: std.ArrayListUnmanaged(u8) = .empty,
    ids: std.ArrayListUnmanaged(u64) = .empty,

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        assert(self.codes.items.len % block_bytes == 0);
        assert(self.ids.items.len <= self.blocks() * block_vectors);
        self.codes.deinit(allocator);
        self.ids.deinit(allocator);
    }

    fn append(self: *Cell, allocator: std.mem.Allocator, id: u64, codes: *const Codes) !void {
        const index = self.ids.items.len;
        assert(index <= self.blocks() * block_vectors);
        if (index % block_vectors == 0) try self.codes.appendNTimes(allocator, 0, block_bytes);
        errdefer {
            if (index % block_vectors == 0) self.codes.items.len -= block_bytes;
        }
        try self.ids.append(allocator, id);
        self.write_codes(index, codes);
        assert(self.ids.items.len == index + 1);
        assert(self.ids.items.len <= self.blocks() * block_vectors);
        assert(self.blocks() * block_vectors < self.ids.items.len + block_vectors);
    }

    fn code_offset(index: usize) usize {
        comptime assert(block_bytes == M * block_vectors);
        const offset = @divFloor(index, block_vectors) * block_bytes + index % block_vectors;
        assert(offset % block_bytes < block_vectors);
        return offset;
    }

    fn write_codes(self: *Cell, index: usize, codes: *const Codes) void {
        assert(index < self.ids.items.len);
        const first = code_offset(index);
        assert(first + (M - 1) * block_vectors < self.codes.items.len);
        for (codes, 0..) |code, m| self.codes.items[first + m * block_vectors] = code;
    }

    fn read_codes(self: *const Cell, index: usize, out: *Codes) void {
        assert(index < self.ids.items.len);
        const first = code_offset(index);
        assert(first + (M - 1) * block_vectors < self.codes.items.len);
        for (out, 0..) |*code, m| code.* = self.codes.items[first + m * block_vectors];
    }

    fn swap_remove(self: *Cell, index: usize) ?u64 {
        assert(index < self.ids.items.len);
        const last = self.ids.items.len - 1;
        var moved: ?u64 = null;
        if (index != last) {
            var codes: Codes = undefined;
            self.read_codes(last, &codes);
            self.write_codes(index, &codes);
            self.ids.items[index] = self.ids.items[last];
            moved = self.ids.items[index];
        }
        self.ids.items.len = last;
        if (last % block_vectors == 0) self.codes.items.len -= block_bytes;
        assert(self.ids.items.len <= self.blocks() * block_vectors);
        assert(self.blocks() * block_vectors < self.ids.items.len + block_vectors);
        return moved;
    }

    fn blocks(self: *const Cell) usize {
        assert(self.codes.items.len % block_bytes == 0);
        return @divExact(self.codes.items.len, block_bytes);
    }
};

pub const LinkVectorIndex = struct {
    codebooks: *const Model,
    lock: std.Io.RwLock = .init,
    cells: [cell_count]Cell = @splat(.{}),
    position: std.AutoHashMapUnmanaged(u64, Position) = .empty,
    model: std.atomic.Value(u64) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    loader_stop: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *LinkVectorIndex, allocator: std.mem.Allocator) void {
        var stored: usize = 0;
        for (&self.cells) |*cell| stored += cell.ids.items.len;
        assert(stored == self.position.count());
        for (&self.cells) |*cell| cell.deinit(allocator);
        self.position.deinit(allocator);
    }

    pub fn put(
        self: *LinkVectorIndex,
        io: std.Io,
        allocator: std.mem.Allocator,
        id: u64,
        encoded: *const Encoded,
    ) !void {
        assert(encoded.cell < cell_count);
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.put_locked(allocator, id, encoded);
    }

    pub fn put_locked(
        self: *LinkVectorIndex,
        allocator: std.mem.Allocator,
        id: u64,
        encoded: *const Encoded,
    ) !void {
        assert(encoded.cell < cell_count);
        if (self.position.get(id)) |position| {
            assert(position.cell < cell_count);
            if (position.cell == encoded.cell) {
                self.cells[position.cell].write_codes(position.index, &encoded.codes);
                return;
            }
            self.remove_locked(id);
        }
        try self.position.ensureUnusedCapacity(allocator, 1);
        const cell = &self.cells[encoded.cell];
        try cell.append(allocator, id, &encoded.codes);
        assert(cell.ids.items.len > 0);
        assert(cell.ids.items.len - 1 <= std.math.maxInt(u32));
        self.position.putAssumeCapacity(
            id,
            .{ .cell = encoded.cell, .index = @intCast(cell.ids.items.len - 1) },
        );
        assert(self.position.contains(id));
    }

    pub fn remove(self: *LinkVectorIndex, io: std.Io, id: u64) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.remove_locked(id);
    }

    fn remove_locked(self: *LinkVectorIndex, id: u64) void {
        const position = (self.position.fetchRemove(id) orelse return).value;
        assert(position.cell < cell_count);
        assert(position.index < self.cells[position.cell].ids.items.len);
        const moved = self.cells[position.cell].swap_remove(position.index);
        if (moved) |moved_id| {
            assert(moved_id != id);
            self.position.putAssumeCapacity(moved_id, position);
        }
    }

    pub fn count(self: *LinkVectorIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        var stored: usize = 0;
        for (&self.cells) |*cell| stored += cell.ids.items.len;
        assert(stored == self.position.count());
        return self.position.count();
    }

    pub fn shortlist(
        self: *LinkVectorIndex,
        io: std.Io,
        query: *const Float,
        out: []ranking.ScoredId,
    ) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var order: [cell_count]u16 = undefined;
        self.codebooks.rank_cells(query, &order);
        var lut: Lut = undefined;
        self.codebooks.lut(query, &lut);

        var top = ranking.TopK.init(out);
        var covered: usize = 0;
        for (order, 0..) |cell, probed| {
            if (probed >= vector_model.probe_min) {
                if (covered >= out.len) break;
            }
            covered += scan_cell(&self.cells[cell], &lut, &top);
        }
        assert(covered <= self.position.count());
        const hits = top.sorted();
        assert(hits.len <= out.len);
        assert(hits.len <= covered);
        return hits;
    }

    pub fn score_ids(
        self: *LinkVectorIndex,
        io: std.Io,
        ids: []const u64,
        query: *const Float,
        out: []ranking.ScoredId,
    ) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var lut: Lut = undefined;
        self.codebooks.lut(query, &lut);

        var top = ranking.TopK.init(out);
        var codes: Codes = undefined;
        for (ids) |id| {
            const position = self.position.get(id) orelse continue;
            assert(position.index < self.cells[position.cell].ids.items.len);
            self.cells[position.cell].read_codes(position.index, &codes);
            top.offer(.{ .id = id, .score = vector_model.approximate_score(&lut, &codes) });
        }
        const hits = top.sorted();
        assert(hits.len <= ids.len);
        assert(hits.len <= out.len);
        return hits;
    }
};

fn scan_cell(cell: *const Cell, lut: *const Lut, top: *ranking.TopK) usize {
    comptime assert(block_bytes == M * block_vectors);
    const live_total = cell.ids.items.len;
    assert(live_total <= cell.blocks() * block_vectors);
    for (0..cell.blocks()) |block| {
        const base = block * block_bytes;
        var sums: @Vector(block_vectors, f32) = @splat(0);
        for (0..M) |m| {
            var gathered: [block_vectors]f32 = undefined;
            const row = cell.codes.items[base + m * block_vectors ..][0..block_vectors];
            for (0..block_vectors) |slot| gathered[slot] = lut[m * K + row[slot]];
            sums += @as(@Vector(block_vectors, f32), gathered);
        }
        const scores: [block_vectors]f32 = sums;
        const first = block * block_vectors;
        const live = @min(block_vectors, live_total - first);
        assert(live > 0);
        for (scores[0..live], cell.ids.items[first..][0..live]) |score, id| {
            top.offer(.{ .id = id, .score = score });
        }
    }
    return live_total;
}

const testing = std.testing;

fn unit(seed: u64) Float {
    var prng = std.Random.DefaultPrng.init(seed);
    var vector: Float = undefined;
    for (&vector) |*x| x.* = prng.random().floatNorm(f32);
    vector_model.normalize_in_place(&vector);
    assert(@abs(vector_model.dot(&vector, &vector) - 1) < 1e-3);
    return vector;
}

fn fill(index: *LinkVectorIndex, first_id: u64, n: usize) !void {
    assert(first_id != 0);
    for (0..n) |i| {
        const id = first_id + i;
        try index.put(testing.io, testing.allocator, id, &index.codebooks.encode_float(&unit(id)));
    }
}

// Store fifty random unit vectors and query each by its own embedding: with so few rows every
// cell is probed, so each vector must come back first.
test "shortlist finds a stored vector by its own embedding while the index is small" {
    const model = try Model.synthetic(testing.allocator, 11);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .codebooks = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 50);
    try testing.expectEqual(@as(usize, 50), index.count(testing.io));

    var buffer: [5]ranking.ScoredId = undefined;
    for (1..51) |id| {
        const hits = index.shortlist(testing.io, &unit(id), &buffer);
        try testing.expectEqual(@as(usize, 5), hits.len);
        try testing.expectEqual(@as(u64, id), hits[0].id);
    }
}

// Remove four ids (first, last and middle rows, plus one unknown id) and check every remaining
// id is still found by its embedding and the removed ones are not.
test "remove swaps the cell's last row into the hole and keeps every other id findable" {
    const model = try Model.synthetic(testing.allocator, 12);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .codebooks = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 40);
    for ([_]u64{ 3, 17, 40, 1 }) |id| index.remove(testing.io, id);
    index.remove(testing.io, 999);
    try testing.expectEqual(@as(usize, 36), index.count(testing.io));

    var buffer: [3]ranking.ScoredId = undefined;
    for (1..41) |id| {
        const hits = index.shortlist(testing.io, &unit(id), &buffer);
        const expect_present = id != 3 and id != 17 and id != 40 and id != 1;
        try testing.expectEqual(expect_present, hits[0].id == id);
    }
}

// Re-put one id with forty different embeddings: the count stays put, the id is always found
// under its latest embedding, at least one re-put crosses cells, and every cell holds exactly
// as many blocks as its rows need.
test "put of an existing id re-codes it in place or moves it to its new cell" {
    const model = try Model.synthetic(testing.allocator, 13);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .codebooks = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 10);
    var moved_to_other_cell = false;
    for (100..140) |seed| {
        const encoded = model.encode_float(&unit(seed));
        const before = index.position.get(5).?.cell;
        try index.put(testing.io, testing.allocator, 5, &encoded);
        moved_to_other_cell = moved_to_other_cell or encoded.cell != before;
        try testing.expectEqual(@as(usize, 10), index.count(testing.io));

        var buffer: [1]ranking.ScoredId = undefined;
        try testing.expectEqual(
            @as(u64, 5),
            index.shortlist(testing.io, &unit(seed), &buffer)[0].id,
        );
    }
    try testing.expect(moved_to_other_cell);

    var total: usize = 0;
    for (index.cells) |cell| {
        total += cell.ids.items.len;
        try testing.expectEqual(
            try std.math.divCeil(usize, cell.ids.items.len, block_vectors),
            cell.blocks(),
        );
    }
    try testing.expectEqual(@as(usize, 10), total);
}

// Score a handful of ids including an unknown one and check only the stored ids come back, with
// the queried vector's own id first.
test "score_ids ranks only the asked ids by approximate score and skips unknown ids" {
    const model = try Model.synthetic(testing.allocator, 14);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .codebooks = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 20);
    var buffer: [4]ranking.ScoredId = undefined;
    const hits = index.score_ids(testing.io, &.{ 7, 2, 500, 9 }, &unit(7), &buffer);
    try testing.expectEqual(@as(usize, 3), hits.len);
    try testing.expectEqual(@as(u64, 7), hits[0].id);
}

// Put more vectors than one block holds into a single cell by nudging one anchor embedding, then
// check a shortlist over that cell scores exactly the live rows and none of the block padding.
test "a cell that grows past the block boundary scores every live row and no padding" {
    const model = try Model.synthetic(testing.allocator, 15);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .codebooks = model };
    defer index.deinit(testing.allocator);

    const anchor = unit(42);
    var ids: usize = 0;
    var seed: u64 = 1000;
    while (ids < block_vectors + 3) : (seed += 1) {
        var vector = anchor;
        vector[seed % vector_model.dimensions] += 0.05;
        vector_model.normalize_in_place(&vector);
        const encoded = model.encode_float(&vector);
        if (encoded.cell != model.nearest_cell(&anchor)) continue;
        try index.put(testing.io, testing.allocator, seed, &encoded);
        ids += 1;
    }

    var buffer: [block_vectors * 2]ranking.ScoredId = undefined;
    const hits = index.shortlist(testing.io, &anchor, &buffer);
    try testing.expectEqual(@as(usize, block_vectors + 3), hits.len);
}
