//! Link ids grouped by a key: the adjacency behind the facts index. A key is a category id, a
//! registrable-domain string id or an entity-name string id, and the rows under it are the
//! links filed there. Three flat arrays hold every group (the distinct keys in order, where
//! each key's rows start, and the rows), so a lookup is one binary search and a slice, and the
//! structure is rebuilt in one pass rather than maintained row by row.

const std = @import("std");
const assert = std.debug.assert;

pub const rows_max: usize = std.math.maxInt(u32);

pub const Row = struct {
    key: u64,
    link_id: u64,

    fn before(_: void, a: Row, b: Row) bool {
        if (a.key != b.key) return a.key < b.key;
        return a.link_id < b.link_id;
    }
};

pub const Adjacency = struct {
    keys: []u64 = &.{},
    starts: []u32 = &.{},
    link_ids: []u64 = &.{},

    pub fn deinit(self: *Adjacency, gpa: std.mem.Allocator) void {
        if (self.keys.len > 0) assert(self.starts.len == self.keys.len + 1);
        assert(self.keys.len <= self.link_ids.len);
        gpa.free(self.keys);
        gpa.free(self.starts);
        gpa.free(self.link_ids);
        self.* = .{};
    }

    /// Replaces every group with `rows`, which are sorted in place. The old groups stay intact
    /// if an allocation fails, so a reader never sees half of each.
    pub fn rebuild(self: *Adjacency, gpa: std.mem.Allocator, rows: []Row) !void {
        assert(rows.len <= rows_max);
        std.sort.pdq(Row, rows, {}, Row.before);

        const keys = try gpa.alloc(u64, distinct_keys(rows));
        errdefer gpa.free(keys);
        const starts = try gpa.alloc(u32, keys.len + 1);
        errdefer gpa.free(starts);
        const link_ids = try gpa.alloc(u64, rows.len);
        errdefer gpa.free(link_ids);

        var group: usize = 0;
        for (rows, link_ids, 0..) |row, *link_id, index| {
            link_id.* = row.link_id;
            if (index > 0 and rows[index - 1].key == row.key) {
                assert(rows[index - 1].link_id < row.link_id);
                continue;
            }
            keys[group] = row.key;
            starts[group] = @intCast(index);
            group += 1;
        }
        assert(group == keys.len);
        starts[group] = @intCast(rows.len);
        assert(starts[0] == 0);

        self.deinit(gpa);
        self.* = .{ .keys = keys, .starts = starts, .link_ids = link_ids };
    }

    /// The links filed under `key`, in ascending id order; empty for a key with none.
    pub fn of(self: *const Adjacency, key: u64) []const u64 {
        const group = std.sort.binarySearch(u64, self.keys, key, order_u64) orelse return &.{};
        assert(group + 1 < self.starts.len);
        assert(self.keys[group] == key);
        const start = self.starts[group];
        const end = self.starts[group + 1];
        assert(start < end);
        assert(end <= self.link_ids.len);
        return self.link_ids[start..end];
    }
};

fn distinct_keys(sorted: []const Row) usize {
    var distinct: usize = 0;
    for (sorted, 0..) |row, index| {
        if (index > 0) assert(!Row.before({}, row, sorted[index - 1]));
        if (index == 0 or sorted[index - 1].key != row.key) distinct += 1;
    }
    assert(distinct <= sorted.len);
    return distinct;
}

fn order_u64(context: u64, item: u64) std.math.Order {
    return std.math.order(context, item);
}

const testing = std.testing;

// Goal: a rebuild groups rows by key whatever order they arrive in, and a lookup returns each
// group's links in ascending order. Method: build from shuffled rows, look up every key, a
// missing key, then rebuild from nothing.
test "adjacency groups rows by key and answers a missing key with nothing" {
    var groups: Adjacency = .{};
    defer groups.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), groups.of(7).len);

    var rows = [_]Row{
        .{ .key = 9, .link_id = 30 },
        .{ .key = 2, .link_id = 11 },
        .{ .key = 9, .link_id = 4 },
        .{ .key = 2, .link_id = 10 },
        .{ .key = 5, .link_id = 77 },
    };
    try groups.rebuild(testing.allocator, &rows);

    try testing.expectEqualSlices(u64, &.{ 10, 11 }, groups.of(2));
    try testing.expectEqualSlices(u64, &.{77}, groups.of(5));
    try testing.expectEqualSlices(u64, &.{ 4, 30 }, groups.of(9));
    try testing.expectEqual(@as(usize, 0), groups.of(3).len);
    try testing.expectEqual(@as(usize, 0), groups.of(10).len);

    try groups.rebuild(testing.allocator, &.{});
    try testing.expectEqual(@as(usize, 0), groups.of(2).len);
}
