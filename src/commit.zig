const std = @import("std");
const changeset = @import("changeset.zig");
const apply_mod = @import("apply/apply.zig");
const Database = @import("database.zig").Database;

pub const CommitError = error{
    WalDisabled,
    OutOfMemory,
} || apply_mod.ApplyError;

pub fn commit(db: *Database, cs: changeset.ChangeSet) !void {
    const encoded = try changeset.encode(db.allocator, cs);
    defer db.allocator.free(encoded);

    var seq: u64 = 0;
    if (db.wal_writer) |*w| {
        seq = try w.append(.changeset, encoded);
    } else {
        return CommitError.WalDisabled;
    }

    {
        db.apply_mutex.lock();
        defer db.apply_mutex.unlock();
        while (db.last_applied_seq + 1 < seq) {
            db.apply_cond.wait(&db.apply_mutex);
        }
        const apply_result = apply_mod.apply(db, cs);
        db.last_applied_seq = seq;
        db.apply_cond.broadcast();
        try apply_result;
    }

    if (db.wal_writer) |*w| {
        try w.awaitDurable(seq);
    }
}

test "commit: requires WAL writer" {
    return error.SkipZigTest;
}
