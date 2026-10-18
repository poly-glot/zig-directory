const std = @import("std");

pub const RRF_K: f64 = 60;

pub const ScoredId = struct {
    id: u64,
    score: f64,

    pub fn ranksBefore(_: void, a: ScoredId, b: ScoredId) bool {
        if (a.score != b.score) return a.score > b.score;
        return a.id < b.id;
    }
};

pub const TopK = struct {
    hits: []ScoredId,
    len: usize = 0,
    worst: usize = 0,

    pub fn init(buf: []ScoredId) TopK {
        return .{ .hits = buf };
    }

    pub fn offer(self: *TopK, hit: ScoredId) void {
        if (self.hits.len == 0) return;
        if (self.len < self.hits.len) {
            self.hits[self.len] = hit;
            self.len += 1;
            if (self.len == self.hits.len) self.findWorst();
            return;
        }
        if (!ScoredId.ranksBefore({}, hit, self.hits[self.worst])) return;
        self.hits[self.worst] = hit;
        self.findWorst();
    }

    pub fn sorted(self: *TopK) []ScoredId {
        const out = self.hits[0..self.len];
        std.sort.pdq(ScoredId, out, {}, ScoredId.ranksBefore);
        return out;
    }

    fn findWorst(self: *TopK) void {
        var worst: usize = 0;
        for (self.hits[1..self.len], 1..) |hit, i| {
            if (ScoredId.ranksBefore({}, self.hits[worst], hit)) worst = i;
        }
        self.worst = worst;
    }
};

pub fn reciprocalRankFusion(allocator: std.mem.Allocator, lists: []const []const ScoredId) ![]ScoredId {
    var fused: std.AutoArrayHashMapUnmanaged(u64, f64) = .empty;
    defer fused.deinit(allocator);

    for (lists) |list| {
        for (list, 0..) |hit, rank| {
            const contribution = 1.0 / (RRF_K + @as(f64, @floatFromInt(rank + 1)));
            const entry = try fused.getOrPutValue(allocator, hit.id, 0);
            entry.value_ptr.* += contribution;
        }
    }

    const out = try allocator.alloc(ScoredId, fused.count());
    for (fused.keys(), fused.values(), out) |id, score, *slot| slot.* = .{ .id = id, .score = score };
    std.sort.pdq(ScoredId, out, {}, ScoredId.ranksBefore);
    return out;
}

test "TopK keeps the k best by score, ties broken on ascending id" {
    var buf: [3]ScoredId = undefined;
    var top = TopK.init(&buf);
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

test "reciprocalRankFusion favours ids ranked well by both lists" {
    const keyword = [_]ScoredId{ .{ .id = 10, .score = 3 }, .{ .id = 20, .score = 2 }, .{ .id = 30, .score = 1 } };
    const vector = [_]ScoredId{ .{ .id = 20, .score = 0.9 }, .{ .id = 40, .score = 0.8 } };

    const fused = try reciprocalRankFusion(std.testing.allocator, &.{ &keyword, &vector });
    defer std.testing.allocator.free(fused);

    try std.testing.expectEqual(@as(usize, 4), fused.len);
    try std.testing.expectEqual(@as(u64, 20), fused[0].id);
    try std.testing.expectEqual(@as(u64, 10), fused[1].id);
    try std.testing.expectEqual(@as(u64, 40), fused[2].id);
    try std.testing.expectEqual(@as(u64, 30), fused[3].id);
}
