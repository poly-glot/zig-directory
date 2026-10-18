const std = @import("std");
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const vector_index = @import("../vector_index.zig");
const link_mod = @import("operations_link.zig");

pub const MAX_VECTORS_PER_WRITE: usize = 32;
const LOAD_CHUNK: usize = 1024;

pub const VectorWrite = struct {
    link_id: u64,
    text_fingerprint: u64,
    embedding: vector_index.Embedding,
};

pub const VectorWriteResult = enum(u8) {
    ok = 0,
    not_found = 1,
    stale_text = 2,
    invalid_vector = 3,
};

pub fn putLinkVectors(db: *Directory, model: u64, writes: []const VectorWrite, results: []VectorWriteResult) !void {
    std.debug.assert(writes.len == results.len);
    if (model == 0) return error.InvalidEmbeddingModel;
    if (writes.len > MAX_VECTORS_PER_WRITE) return error.TooManyVectors;

    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    const current = db.vectors.model.load(.acquire);
    if (current != 0 and current != model) return error.EmbeddingModelMismatch;

    var accepted: [MAX_VECTORS_PER_WRITE]schema.LinkVector = undefined;
    var accepted_len: usize = 0;
    for (writes, results) |*w, *result| {
        result.* = try checkWrite(db, w, &accepted[accepted_len]);
        if (result.* == .ok) accepted_len += 1;
    }
    if (accepted_len == 0) return;

    try db.commit(.{ .link_vectors_put = .{ .model = model, .vectors = accepted[0..accepted_len] } });
}

fn checkWrite(db: *Directory, w: *const VectorWrite, out: *schema.LinkVector) !VectorWriteResult {
    const link = (try link_mod.getLink(db, w.link_id)) orelse return .not_found;
    if (schema.linkTextFingerprint(link) != w.text_fingerprint) return .stale_text;
    const q = vector_index.quantize(&w.embedding) orelse return .invalid_vector;
    out.* = .{ .link_id = w.link_id, .scale = q.scale, .values = q.values };
    return .ok;
}

pub fn getLinkVector(db: *Directory, link_id: u64) !?schema.LinkVector {
    const key = codec.encodeU64(link_id);
    var buf: [@sizeOf(schema.LinkVector)]u8 = undefined;
    const bytes = (try db.link_vectors().search(&key, &buf)) orelse return null;
    if (bytes.len != @sizeOf(schema.LinkVector)) return null;
    return std.mem.bytesToValue(schema.LinkVector, bytes[0..@sizeOf(schema.LinkVector)]);
}

pub fn loadVectorIndex(db: *Directory) !void {
    var next_id: u64 = 0;
    while (!db.vectors.loader_stop.load(.acquire)) {
        if (try loadVectorChunk(db, &next_id) < LOAD_CHUNK) {
            db.vectors.ready.store(true, .release);
            return;
        }
    }
}

fn loadVectorChunk(db: *Directory, next_id: *u64) !usize {
    db.vectors.lock.lockUncancelable(db.io);
    defer db.vectors.lock.unlock(db.io);

    const start_key = codec.encodeU64(next_id.*);
    var iter = try db.link_vectors().rangeScan(&start_key, null);
    defer iter.deinit();

    var scanned: usize = 0;
    while (scanned < LOAD_CHUNK) : (scanned += 1) {
        const entry = (try iter.next()) orelse return scanned;
        next_id.* = codec.decodeU64(entry.key[0..8]) + 1;
        if (entry.value.len != @sizeOf(schema.LinkVector)) continue;
        try db.vectors.putLocked(db.allocator, std.mem.bytesToValue(schema.LinkVector, entry.value[0..@sizeOf(schema.LinkVector)]));
    }
    return scanned;
}

const testing = std.testing;
const category = @import("operations_category.zig");
const search = @import("operations_search.zig");
const verifier = @import("../verifier.zig");

const MODEL: u64 = 0xB6E5_5A11;

fn axisEmbedding(axis: usize) vector_index.Embedding {
    var e: vector_index.Embedding = @splat(0);
    e[axis] = 1;
    return e;
}

fn writeFor(db: *Directory, link_id: u64, axis: usize) !VectorWrite {
    const link = (try link_mod.getLink(db, link_id)).?;
    return .{ .link_id = link_id, .text_fingerprint = schema.linkTextFingerprint(link), .embedding = axisEmbedding(axis) };
}

fn putOne(db: *Directory, model: u64, w: VectorWrite) !VectorWriteResult {
    var result: [1]VectorWriteResult = undefined;
    try putLinkVectors(db, model, &.{w}, &result);
    return result[0];
}

test "put_link_vectors stores a quantised vector, records the model, and indexes it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const id = try link_mod.createLink(db, top, "https://bonsai.example", "Bonsai", "Small trees");

    try testing.expectEqual(VectorWriteResult.ok, try putOne(db, MODEL, try writeFor(db, id, 3)));

    const stored = (try getLinkVector(db, id)).?;
    try testing.expectEqual(@as(i8, 127), stored.values[3]);
    try testing.expectEqual(MODEL, db.store.counter("embedding_model").*);
    try testing.expectEqual(MODEL, db.vectors.model.load(.acquire));
    try testing.expectEqual(@as(usize, 1), db.vectors.count(db.io));
}

test "put_link_vectors rejects unknown links, text that changed since it was embedded, and empty vectors" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const id = try link_mod.createLink(db, top, "https://bonsai.example", "Bonsai", "Small trees");

    var unknown = try writeFor(db, id, 0);
    unknown.link_id = id + 100;
    var stale = try writeFor(db, id, 0);
    stale.text_fingerprint +%= 1;
    var empty = try writeFor(db, id, 0);
    empty.embedding = @splat(0);

    var results: [3]VectorWriteResult = undefined;
    try putLinkVectors(db, MODEL, &.{ unknown, stale, empty }, &results);
    try testing.expectEqual(VectorWriteResult.not_found, results[0]);
    try testing.expectEqual(VectorWriteResult.stale_text, results[1]);
    try testing.expectEqual(VectorWriteResult.invalid_vector, results[2]);
    try testing.expectEqual(@as(?schema.LinkVector, null), try getLinkVector(db, id));
    try testing.expectEqual(@as(u64, 0), db.store.counter("embedding_model").*);
}

test "put_link_vectors refuses a second embedding model and model id zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const id = try link_mod.createLink(db, top, "https://bonsai.example", "Bonsai", "");
    _ = try putOne(db, MODEL, try writeFor(db, id, 0));

    try testing.expectError(error.EmbeddingModelMismatch, putOne(db, MODEL + 1, try writeFor(db, id, 1)));
    try testing.expectError(error.InvalidEmbeddingModel, putOne(db, 0, try writeFor(db, id, 1)));
}

test "editing a link's title or description drops its vector; a status or url change keeps it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const id = try link_mod.createLink(db, top, "https://bonsai.example", "Bonsai", "Small trees");
    _ = try putOne(db, MODEL, try writeFor(db, id, 0));

    try link_mod.updateLinkStatus(db, id, @intFromEnum(schema.LinkStatus.rejected));
    try link_mod.updateLink(db, id, "https://bonsai-club.example", null, null);
    try testing.expect((try getLinkVector(db, id)) != null);
    try testing.expectEqual(@as(usize, 1), db.vectors.count(db.io));

    try link_mod.updateLink(db, id, null, null, "Miniature trees");
    try testing.expectEqual(@as(?schema.LinkVector, null), try getLinkVector(db, id));
    try testing.expectEqual(@as(usize, 0), db.vectors.count(db.io));
}

test "deleting a link drops its vector so the verifier finds no vector without a link" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const kept = try link_mod.createLink(db, top, "https://kept.example", "Kept", "");
    const gone = try link_mod.createLink(db, top, "https://gone.example", "Gone", "");
    var results: [2]VectorWriteResult = undefined;
    try putLinkVectors(db, MODEL, &.{ try writeFor(db, kept, 0), try writeFor(db, gone, 1) }, &results);

    try link_mod.deleteLink(db, gone);
    try testing.expectEqual(@as(?schema.LinkVector, null), try getLinkVector(db, gone));
    try testing.expectEqual(@as(usize, 1), db.vectors.count(db.io));

    var state: verifier.VerifierState = .{};
    try verifier.runOnce(db, &state);
    const health = state.indices[@intFromEnum(verifier.InvariantId.link_vectors_have_links)];
    try testing.expectEqual(@as(u64, 1), health.expected);
    try testing.expectEqual(@as(u64, 1), health.observed);
}

test "a crash after acked vector writes replays the WAL into the same vector index" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const ids = blk: {
        const a = try Directory.openTestInstance(testing.allocator, &tmp);
        const top = try category.createCategory(a, 0, "Top", "top", "");
        const first = try link_mod.createLink(a, top, "https://first.example", "First", "");
        const second = try link_mod.createLink(a, top, "https://second.example", "Second", "");
        const third = try link_mod.createLink(a, top, "https://third.example", "Third", "");
        var results: [3]VectorWriteResult = undefined;
        try putLinkVectors(a, MODEL, &.{ try writeFor(a, first, 0), try writeFor(a, second, 1), try writeFor(a, third, 2) }, &results);
        try link_mod.updateLink(a, second, null, "Second, renamed", null);
        a.deinitCrashTestInstance();
        break :blk .{ first, second, third };
    };

    const b = try Directory.openTestInstance(testing.allocator, &tmp);
    defer b.deinitTestInstance();
    try b.recover();
    try loadVectorIndex(b);

    try testing.expect(b.vectors.ready.load(.acquire));
    try testing.expectEqual(MODEL, b.vectors.model.load(.acquire));
    try testing.expectEqual(@as(usize, 2), b.vectors.count(b.io));
    try testing.expect((try getLinkVector(b, ids[0])) != null);
    try testing.expectEqual(@as(?schema.LinkVector, null), try getLinkVector(b, ids[1]));

    const query = vector_index.quantize(&axisEmbedding(2)).?;
    var buf: [1]@import("../ranking.zig").ScoredId = undefined;
    try testing.expectEqual(ids[2], b.vectors.nearest(b.io, &query, &buf)[0].id);
}

test "hybrid search adds a vector-only match, and falls back to keywords for another model" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const keyword_hit = try link_mod.createLink(db, top, "https://a.example", "Miniature trees", "");
    const meaning_hit = try link_mod.createLink(db, top, "https://b.example", "Bonsai", "Japanese art form");
    var results: [2]VectorWriteResult = undefined;
    try putLinkVectors(db, MODEL, &.{ try writeFor(db, keyword_hit, 0), try writeFor(db, meaning_hit, 1) }, &results);
    try loadVectorIndex(db);

    var buf: [8]schema.Link = undefined;
    const hybrid = try search.searchLinksHybrid(db, "miniature trees", MODEL, &axisEmbedding(1), 8, &buf);
    try testing.expect(hybrid.vector_used);
    try testing.expectEqual(@as(usize, 2), hybrid.links.len);

    const fallback = try search.searchLinksHybrid(db, "miniature trees", MODEL + 1, &axisEmbedding(1), 8, &buf);
    try testing.expect(!fallback.vector_used);
    try testing.expectEqual(@as(usize, 1), fallback.links.len);
    try testing.expectEqual(keyword_hit, fallback.links[0].id);
}
