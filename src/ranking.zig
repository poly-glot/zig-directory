//! Scored-id ranking shared by the keyword, vector and subtree halves of search: a bounded top-k
//! selector that keeps the k best hits offered to it, and reciprocal rank fusion over several
//! ranked lists. Hits order by score descending, then by ascending id so ties are stable.

const std = @import("std");
const assert = std.debug.assert;

pub const rrf_k: f64 = 60;

pub const ScoredId = struct {
    id: u64,
    score: f64,

    pub fn ranks_before(_: void, a: ScoredId, b: ScoredId) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.id < b.id;
    }
};

pub const TopK = struct {
    hits: []ScoredId,
    len: u32 = 0,
    worst: u32 = 0,

    pub fn init(buffer: []ScoredId) TopK {
        assert(buffer.len <= std.math.maxInt(u32));
        return .{ .hits = buffer };
    }

    pub fn offer(self: *TopK, hit: ScoredId) void {
        assert(self.len <= self.hits.len);
        if (self.hits.len == 0) return;
        if (self.len < self.hits.len) {
            self.hits[self.len] = hit;
            self.len += 1;
            assert(self.len <= self.hits.len);
            if (self.len == self.hits.len) self.find_worst();
            return;
        }
        assert(self.worst < self.len);
        if (!ScoredId.ranks_before({}, hit, self.hits[self.worst])) return;
        self.hits[self.worst] = hit;
        self.find_worst();
    }

    pub fn sorted(self: *TopK) []ScoredId {
        assert(self.len <= self.hits.len);
        const out = self.hits[0..self.len];
        std.sort.pdq(ScoredId, out, {}, ScoredId.ranks_before);
        if (out.len > 1) {
            for (out[1..], out[0 .. out.len - 1]) |later, earlier| {
                assert(!ScoredId.ranks_before({}, later, earlier));
            }
        }
        return out;
    }

    fn find_worst(self: *TopK) void {
        assert(self.len == self.hits.len);
        assert(self.len > 0);
        var worst: usize = 0;
        for (self.hits[1..self.len], 1..) |hit, index| {
            if (ScoredId.ranks_before({}, self.hits[worst], hit)) worst = index;
        }
        assert(worst < self.len);
        self.worst = @intCast(worst);
    }
};

pub fn reciprocal_rank_fusion(
    allocator: std.mem.Allocator,
    lists: []const []const ScoredId,
) ![]ScoredId {
    comptime assert(rrf_k > 0);
    var fused: std.AutoArrayHashMapUnmanaged(u64, f64) = .empty;
    defer fused.deinit(allocator);

    var hits_total: usize = 0;
    for (lists) |list| {
        hits_total += list.len;
        for (list, 0..) |hit, rank| {
            const contribution = 1.0 / (rrf_k + @as(f64, @floatFromInt(rank + 1)));
            const entry = try fused.getOrPutValue(allocator, hit.id, 0);
            entry.value_ptr.* += contribution;
        }
    }
    assert(fused.count() <= hits_total);

    const out = try allocator.alloc(ScoredId, fused.count());
    for (
        fused.keys(),
        fused.values(),
        out,
    ) |id, score, *slot| slot.* = .{ .id = id, .score = score };
    std.sort.pdq(ScoredId, out, {}, ScoredId.ranks_before);
    assert(out.len == fused.count());
    return out;
}

// Offer six hits to a three-slot selector and check the three best come back in rank order
// with the tie among equal scores broken by the lower id.
test "TopK keeps the k best by score, ties broken on ascending id" {
    var buffer: [3]ScoredId = undefined;
    var top = TopK.init(&buffer);
    for ([_]ScoredId{
        .{ .id = 1, .score = 0.1 },
        .{ .id = 2, .score = 0.9 },
        .{ .id = 3, .score = 0.5 },
        .{ .id = 4, .score = 0.5 },
        .{ .id = 5, .score = 0.7 },
        .{ .id = 6, .score = 0.5 },
    }) |hit| top.offer(hit);

    const best = top.sorted();
    try std.testing.expectEqual(@as(usize, 3), best.len);
    try std.testing.expectEqual(@as(u64, 2), best[0].id);
    try std.testing.expectEqual(@as(u64, 5), best[1].id);
    try std.testing.expectEqual(@as(u64, 3), best[2].id);
}

// Fuse a keyword list and a vector list that share one id and check that id leads, followed by
// the single-list ids in their own rank order.
test "reciprocal_rank_fusion favours ids ranked well by both lists" {
    const keyword = [_]ScoredId{
        .{ .id = 10, .score = 3 },
        .{ .id = 20, .score = 2 },
        .{ .id = 30, .score = 1 },
    };
    const vector = [_]ScoredId{ .{ .id = 20, .score = 0.9 }, .{ .id = 40, .score = 0.8 } };

    const fused = try reciprocal_rank_fusion(std.testing.allocator, &.{ &keyword, &vector });
    defer std.testing.allocator.free(fused);

    try std.testing.expectEqual(@as(usize, 4), fused.len);
    try std.testing.expectEqual(@as(u64, 20), fused[0].id);
    try std.testing.expectEqual(@as(u64, 10), fused[1].id);
    try std.testing.expectEqual(@as(u64, 40), fused[2].id);
    try std.testing.expectEqual(@as(u64, 30), fused[3].id);
}
