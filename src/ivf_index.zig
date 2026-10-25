const std = @import("std");
const ranking = @import("ranking.zig");
const vector_model = @import("vector_model.zig");

const Model = vector_model.Model;
const Codes = vector_model.Codes;
const Encoded = vector_model.Encoded;
const Float = vector_model.Float;
const Lut = vector_model.Lut;
const CELLS = vector_model.CELLS;
const M = vector_model.M;
const K = vector_model.K;

pub const BLOCK: usize = 8;
const BLOCK_BYTES: usize = M * BLOCK;

const Pos = struct { cell: u16, index: u32 };

const Cell = struct {
    codes: std.ArrayListUnmanaged(u8) = .empty,
    ids: std.ArrayListUnmanaged(u64) = .empty,

    fn deinit(self: *Cell, allocator: std.mem.Allocator) void {
        self.codes.deinit(allocator);
        self.ids.deinit(allocator);
    }

    fn append(self: *Cell, allocator: std.mem.Allocator, id: u64, codes: *const Codes) !void {
        const index = self.ids.items.len;
        if (index % BLOCK == 0) try self.codes.appendNTimes(allocator, 0, BLOCK_BYTES);
        errdefer {
            if (index % BLOCK == 0) self.codes.items.len -= BLOCK_BYTES;
        }
        try self.ids.append(allocator, id);
        self.writeCodes(index, codes);
    }

    fn codeOffset(index: usize, m: usize) usize {
        return (index / BLOCK) * BLOCK_BYTES + m * BLOCK + index % BLOCK;
    }

    fn writeCodes(self: *Cell, index: usize, codes: *const Codes) void {
        for (codes, 0..) |code, m| self.codes.items[codeOffset(index, m)] = code;
    }

    fn readCodes(self: *const Cell, index: usize, out: *Codes) void {
        for (out, 0..) |*code, m| code.* = self.codes.items[codeOffset(index, m)];
    }

    fn swapRemove(self: *Cell, index: usize) ?u64 {
        const last = self.ids.items.len - 1;
        var moved: ?u64 = null;
        if (index != last) {
            var codes: Codes = undefined;
            self.readCodes(last, &codes);
            self.writeCodes(index, &codes);
            self.ids.items[index] = self.ids.items[last];
            moved = self.ids.items[index];
        }
        self.ids.items.len = last;
        if (last % BLOCK == 0) self.codes.items.len -= BLOCK_BYTES;
        return moved;
    }

    fn blocks(self: *const Cell) usize {
        return self.codes.items.len / BLOCK_BYTES;
    }
};

pub const LinkVectorIndex = struct {
    pq: *const Model,
    lock: std.Io.RwLock = .init,
    cells: [CELLS]Cell = @splat(.{}),
    position: std.AutoHashMapUnmanaged(u64, Pos) = .empty,
    model: std.atomic.Value(u64) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),
    loader_stop: std.atomic.Value(bool) = .init(false),

    pub fn deinit(self: *LinkVectorIndex, allocator: std.mem.Allocator) void {
        for (&self.cells) |*cell| cell.deinit(allocator);
        self.position.deinit(allocator);
    }

    pub fn put(self: *LinkVectorIndex, io: std.Io, allocator: std.mem.Allocator, id: u64, encoded: Encoded) !void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        try self.putLocked(allocator, id, encoded);
    }

    pub fn putLocked(self: *LinkVectorIndex, allocator: std.mem.Allocator, id: u64, encoded: Encoded) !void {
        if (self.position.get(id)) |pos| {
            if (pos.cell == encoded.cell) {
                self.cells[pos.cell].writeCodes(pos.index, &encoded.codes);
                return;
            }
            self.removeLocked(id);
        }
        try self.position.ensureUnusedCapacity(allocator, 1);
        const cell = &self.cells[encoded.cell];
        try cell.append(allocator, id, &encoded.codes);
        self.position.putAssumeCapacity(id, .{ .cell = encoded.cell, .index = @intCast(cell.ids.items.len - 1) });
    }

    pub fn remove(self: *LinkVectorIndex, io: std.Io, id: u64) void {
        self.lock.lockUncancelable(io);
        defer self.lock.unlock(io);
        self.removeLocked(id);
    }

    fn removeLocked(self: *LinkVectorIndex, id: u64) void {
        const pos = (self.position.fetchRemove(id) orelse return).value;
        if (self.cells[pos.cell].swapRemove(pos.index)) |moved| self.position.putAssumeCapacity(moved, pos);
    }

    pub fn count(self: *LinkVectorIndex, io: std.Io) usize {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);
        return self.position.count();
    }

    pub fn shortlist(self: *LinkVectorIndex, io: std.Io, query: *const Float, out: []ranking.ScoredId) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var order: [CELLS]u16 = undefined;
        self.pq.rankCells(query, &order);
        var lut: Lut = undefined;
        self.pq.lut(query, &lut);

        var top = ranking.TopK.init(out);
        var covered: usize = 0;
        for (order, 0..) |cell, probed| {
            if (probed >= vector_model.MIN_PROBE and covered >= out.len) break;
            covered += scanCell(&self.cells[cell], &lut, &top);
        }
        return top.sorted();
    }

    pub fn scoreIds(self: *LinkVectorIndex, io: std.Io, ids: []const u64, query: *const Float, out: []ranking.ScoredId) []ranking.ScoredId {
        self.lock.lockSharedUncancelable(io);
        defer self.lock.unlockShared(io);

        var lut: Lut = undefined;
        self.pq.lut(query, &lut);

        var top = ranking.TopK.init(out);
        var codes: Codes = undefined;
        for (ids) |id| {
            const pos = self.position.get(id) orelse continue;
            self.cells[pos.cell].readCodes(pos.index, &codes);
            top.offer(.{ .id = id, .score = vector_model.approximateScore(&lut, &codes) });
        }
        return top.sorted();
    }
};

fn scanCell(cell: *const Cell, lut: *const Lut, top: *ranking.TopK) usize {
    const n = cell.ids.items.len;
    for (0..cell.blocks()) |b| {
        const base = b * BLOCK_BYTES;
        var acc: @Vector(BLOCK, f32) = @splat(0);
        for (0..M) |m| {
            var gathered: [BLOCK]f32 = undefined;
            const row = cell.codes.items[base + m * BLOCK ..][0..BLOCK];
            for (0..BLOCK) |r| gathered[r] = lut[m * K + row[r]];
            acc += @as(@Vector(BLOCK, f32), gathered);
        }
        const scores: [BLOCK]f32 = acc;
        const first = b * BLOCK;
        const live = @min(BLOCK, n - first);
        for (scores[0..live], cell.ids.items[first..][0..live]) |score, id| top.offer(.{ .id = id, .score = score });
    }
    return n;
}

const testing = std.testing;

fn unit(seed: u64) Float {
    var prng = std.Random.DefaultPrng.init(seed);
    var v: Float = undefined;
    for (&v) |*x| x.* = prng.random().floatNorm(f32);
    vector_model.normalizeInPlace(&v);
    return v;
}

fn fill(index: *LinkVectorIndex, first_id: u64, n: usize) !void {
    for (0..n) |i| {
        const id = first_id + i;
        try index.put(testing.io, testing.allocator, id, index.pq.encodeFloat(&unit(id)));
    }
}

test "shortlist finds a stored vector by its own embedding and probes every cell while the index is small" {
    const model = try Model.synthetic(testing.allocator, 11);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .pq = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 50);
    try testing.expectEqual(@as(usize, 50), index.count(testing.io));

    var buf: [5]ranking.ScoredId = undefined;
    for (1..51) |id| {
        const hits = index.shortlist(testing.io, &unit(id), &buf);
        try testing.expectEqual(@as(usize, 5), hits.len);
        try testing.expectEqual(@as(u64, id), hits[0].id);
    }
}

test "remove swaps the cell's last row into the hole and keeps every other id findable" {
    const model = try Model.synthetic(testing.allocator, 12);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .pq = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 40);
    for ([_]u64{ 3, 17, 40, 1 }) |id| index.remove(testing.io, id);
    index.remove(testing.io, 999);
    try testing.expectEqual(@as(usize, 36), index.count(testing.io));

    var buf: [3]ranking.ScoredId = undefined;
    for (1..41) |id| {
        const hits = index.shortlist(testing.io, &unit(id), &buf);
        const expect_present = id != 3 and id != 17 and id != 40 and id != 1;
        try testing.expectEqual(expect_present, hits[0].id == id);
    }
}

test "put of an existing id re-codes it in place or moves it to its new cell without duplicating" {
    const model = try Model.synthetic(testing.allocator, 13);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .pq = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 10);
    var moved_to_other_cell = false;
    for (100..140) |seed| {
        const encoded = model.encodeFloat(&unit(seed));
        const before = index.position.get(5).?.cell;
        try index.put(testing.io, testing.allocator, 5, encoded);
        moved_to_other_cell = moved_to_other_cell or encoded.cell != before;
        try testing.expectEqual(@as(usize, 10), index.count(testing.io));

        var buf: [1]ranking.ScoredId = undefined;
        try testing.expectEqual(@as(u64, 5), index.shortlist(testing.io, &unit(seed), &buf)[0].id);
    }
    try testing.expect(moved_to_other_cell);

    var total: usize = 0;
    for (index.cells) |cell| {
        total += cell.ids.items.len;
        try testing.expectEqual((cell.ids.items.len + BLOCK - 1) / BLOCK, cell.blocks());
    }
    try testing.expectEqual(@as(usize, 10), total);
}

test "scoreIds ranks only the asked ids by approximate score and skips unknown ids" {
    const model = try Model.synthetic(testing.allocator, 14);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .pq = model };
    defer index.deinit(testing.allocator);

    try fill(&index, 1, 20);
    var buf: [4]ranking.ScoredId = undefined;
    const hits = index.scoreIds(testing.io, &.{ 7, 2, 500, 9 }, &unit(7), &buf);
    try testing.expectEqual(@as(usize, 3), hits.len);
    try testing.expectEqual(@as(u64, 7), hits[0].id);
}

test "a cell that grows past the block boundary scores every live row and none of the padding" {
    const model = try Model.synthetic(testing.allocator, 15);
    defer model.deinit(testing.allocator);
    var index = LinkVectorIndex{ .pq = model };
    defer index.deinit(testing.allocator);

    const anchor = unit(42);
    var ids: usize = 0;
    var seed: u64 = 1000;
    while (ids < BLOCK + 3) : (seed += 1) {
        var v = anchor;
        v[seed % 384] += 0.05;
        vector_model.normalizeInPlace(&v);
        const encoded = model.encodeFloat(&v);
        if (encoded.cell != model.nearestCell(&anchor)) continue;
        try index.put(testing.io, testing.allocator, seed, encoded);
        ids += 1;
    }

    var buf: [BLOCK * 2]ranking.ScoredId = undefined;
    const hits = index.shortlist(testing.io, &anchor, &buf);
    try testing.expectEqual(@as(usize, BLOCK + 3), hits.len);
}
