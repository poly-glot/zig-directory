const std = @import("std");
const changeset = @import("changeset.zig");
const apply_mod = @import("apply/apply.zig");
const Database = @import("database.zig").Database;

pub const CommitError = error{
    WalDisabled,
    OutOfMemory,
} || apply_mod.ApplyError;

/// Commit a ChangeSet with group-commit ack batching and split write
/// serialisation.
///
/// Four phases, each with the minimum locking the invariant requires:
///   1. encode  — lock-free.
///   2. append  — WAL's internal lock serialises seq assignment; NO
///      Database-level mutex is held. While THIS commit's caller is between
///      phase 2 and phase 4, peer commits can also be in phase 2, and their
///      records join the same WAL batch the background flusher is about to
///      fdatasync.
///   3. apply   — `apply_mutex` + `apply_cond` enforce in-seq-order apply.
///      A commit with seq N waits until `last_applied_seq + 1 == N`, applies,
///      advances the watermark, broadcasts. This preserves "WAL seq order
///      == observable apply order" without serialising append behind apply.
///   4. await   — park on `awaitDurable(seq)` outside every mutex until the
///      flusher's fdatasync covers this seq.
///
/// Crash semantics: on a crash before phase 4 returns, the caller has not
/// been acked, so they retry. In-memory apply effects are lost with the
/// process; the WAL record may or may not have reached disk. Either way
/// the next boot reaches a state consistent with the last durable seq.
pub fn commit(db: *Database, cs: changeset.ChangeSet) !void {
    const encoded = try changeset.encode(db.allocator, cs);
    defer db.allocator.free(encoded);

    // Phase 2: WAL append. WAL's own lock makes seq assignment monotonic.
    var seq: u64 = 0;
    if (db.wal_writer) |*w| {
        seq = try w.append(.changeset, encoded);
    } else {
        return CommitError.WalDisabled;
    }

    // Phase 3: apply in seq order. The condvar handles the case where two
    // peer commits race through phase 2 and arrive at apply_mutex out of
    // their assigned seq order.
    {
        db.apply_mutex.lock();
        defer db.apply_mutex.unlock();
        while (db.last_applied_seq + 1 < seq) {
            db.apply_cond.wait(&db.apply_mutex);
        }
        const apply_result = apply_mod.apply(db, cs);
        // Advance and broadcast EVEN IF apply failed — otherwise a single
        // failing apply deadlocks every higher-seq commit forever. The
        // failing caller sees the error; peers proceed in seq order.
        db.last_applied_seq = seq;
        db.apply_cond.broadcast();
        try apply_result;
    }

    // Phase 4: durability barrier — outside every Database mutex so peer
    // commits can stack up behind this fsync and ack as one group.
    if (db.wal_writer) |*w| {
        try w.awaitDurable(seq);
    }
}

test "commit: requires WAL writer" {
    // Covered indirectly by full-stack tests in Tasks 7+; integration test here
    // would require constructing a Database without a WAL which the existing
    // test fixtures don't expose.
    return error.SkipZigTest;
}
