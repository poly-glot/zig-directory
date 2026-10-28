//! Replays one WAL entry through the same applier as a live commit, so recovery and the
//! request path cannot diverge in what they write to the trees.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const changeset = @import("../changeset.zig");
const apply_module = @import("../apply/apply.zig");
const Directory = @import("../directory.zig").Directory;

pub const WalApplier = struct {
    db: *Directory,

    pub fn apply(self: *WalApplier, entry: zigstore.ReplayEntry) !void {
        switch (entry.op_code) {
            changeset.changeset_op => {
                var arena = std.heap.ArenaAllocator.init(self.db.allocator);
                defer arena.deinit();

                const change_set = changeset.decode(arena.allocator(), entry.data) catch |err| {
                    std.log.err(
                        "WAL replay: changeset decode failed at seq {d}: {s}",
                        .{ entry.sequence, @errorName(err) },
                    );
                    return err;
                };
                assert(@intFromEnum(std.meta.activeTag(change_set)) == entry.data[1]);
                try apply_module.apply(self.db, &change_set);
            },
            else => return error.UnknownWalOpCode,
        }
    }
};

// A decode or apply failure must reach recovery instead of being skipped, so the applier's
// return type is checked to be an error union.
test "WAL applier propagates errors instead of swallowing them" {
    const apply_function = @TypeOf(WalApplier.apply);
    const function_info = @typeInfo(apply_function).@"fn";
    const return_info = @typeInfo(function_info.return_type.?);
    try std.testing.expect(return_info == .error_union);
}

// Build Top/A with one link, zero Top's subtree count directly in the tree, then reopen: the
// replayed link insert cascades the count back to one.
test "WAL replay re-derives subtree counts via cascade" {
    const allocator = std.testing.allocator;
    const ops = @import("../operations/operations.zig");
    const codec = @import("zigstore").codec;

    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const top_id_persisted: u64 = blk: {
        var db = try Directory.open_test_instance(allocator, &temporary_directory);
        defer db.deinit_test_instance();

        const top_id = try ops.create_category(
            db,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const a_id = try ops.create_category(
            db,
            top_id,
            .{ .name = "A", .slug = "a", .description = "" },
        );
        _ = try ops.create_link(
            db,
            a_id,
            .{ .url = "https://x.example", .title = "x", .description = "" },
        );

        const top = (try ops.get_category(db, top_id)).?;
        try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);

        var tampered = top;
        tampered.link_count_subtree = 0;
        const id_key = codec.encodeU64(top_id);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&tampered));

        break :blk top_id;
    };

    {
        var db = try Directory.open_test_instance(allocator, &temporary_directory);
        defer db.deinit_test_instance();

        const top = (try ops.get_category(db, top_id_persisted)).?;
        try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
    }
}
