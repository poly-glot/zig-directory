const std = @import("std");
const zigstore = @import("zigstore");
const changeset = @import("../changeset.zig");
const apply_mod = @import("../apply/apply.zig");
const Directory = @import("../directory.zig").Directory;

pub const WalApplier = struct {
    db: *Directory,

    pub fn apply(self: *WalApplier, entry: zigstore.ReplayEntry) !void {
        switch (entry.op_code) {
            changeset.CHANGESET_OP => {
                var arena = std.heap.ArenaAllocator.init(self.db.allocator);
                defer arena.deinit();
                const cs = changeset.decode(arena.allocator(), entry.data) catch |err| {
                    std.log.err(
                        "WAL replay: changeset decode failed at seq {d}: {s}",
                        .{ entry.sequence, @errorName(err) },
                    );
                    return err;
                };
                try apply_mod.apply(self.db, cs);
            },
            else => return error.UnknownWalOpCode,
        }
    }
};

test "WAL applier propagates errors instead of swallowing them" {
    const apply_fn = @TypeOf(WalApplier.apply);
    const fn_info = @typeInfo(apply_fn).@"fn";
    const ret_info = @typeInfo(fn_info.return_type.?);
    try std.testing.expect(ret_info == .error_union);
}

test "WAL replay re-derives subtree counts via cascade" {
    const allocator = std.testing.allocator;
    const ops = @import("../operations/operations.zig");
    const codec = @import("zigstore").codec;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const top_id_persisted: u64 = blk: {
        var db = try Directory.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();

        const top_id = try ops.createCategory(db, 0, "Top", "top", "");
        const a_id = try ops.createCategory(db, top_id, "A", "a", "");
        _ = try ops.createLink(db, a_id, "https://x.example", "x", "");

        const top = (try ops.getCategory(db, top_id)).?;
        try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);

        var tampered = top;
        tampered.link_count_subtree = 0;
        const id_key = codec.encodeU64(top_id);
        try db.categories_by_id().insert(&id_key, std.mem.asBytes(&tampered));

        break :blk top_id;
    };

    {
        var db = try Directory.openTestInstance(allocator, &tmp);
        defer db.deinitTestInstance();

        const top = (try ops.getCategory(db, top_id_persisted)).?;
        try std.testing.expectEqual(@as(u64, 1), top.link_count_subtree);
    }
}
