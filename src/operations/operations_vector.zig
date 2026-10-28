//! Embedding writes and the vector index loaders: a vector is accepted only for a link whose
//! title and description still match the fingerprint it was embedded from, under a single model
//! per store, and the loaders rebuild the in-memory indexes from the vector trees at startup in
//! bounded chunks.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const vector_index = @import("../vector_index.zig");
const vector_model = @import("../vector_model.zig");
const link_operations = @import("operations_link.zig");

pub const vectors_per_write_max: usize = 32;
const load_chunk: usize = 1024;

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

pub const CategoryVectorWrite = struct {
    category_id: u64,
    embedding: vector_index.Embedding,
};

pub fn put_link_vectors(
    db: *Directory,
    model: u64,
    writes: []const VectorWrite,
    results: []VectorWriteResult,
) !void {
    assert(writes.len == results.len);
    if (model == 0) return error.InvalidEmbeddingModel;
    if (writes.len > vectors_per_write_max) return error.TooManyVectors;

    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    const current = db.link_vector_index.model.load(.acquire);
    if (current != 0 and current != model) return error.EmbeddingModelMismatch;

    var accepted: [vectors_per_write_max]schema.StoredVector = undefined;
    var accepted_len: usize = 0;
    for (writes, results) |*write, *result| {
        assert(accepted_len < accepted.len);
        result.* = try check_write(db, write, &accepted[accepted_len]);
        if (result.* == .ok) accepted_len += 1;
    }
    assert(accepted_len <= writes.len);
    if (accepted_len == 0) return;

    try db.commit(.{ .link_vectors_put = .{
        .model = model,
        .vectors = accepted[0..accepted_len],
    } });
}

fn check_write(
    db: *Directory,
    write: *const VectorWrite,
    out: *schema.StoredVector,
) !VectorWriteResult {
    const link = (try link_operations.get_link(db, write.link_id)) orelse return .not_found;
    assert(link.id == write.link_id);
    if (schema.link_text_fingerprint(&link) != write.text_fingerprint) return .stale_text;
    const quantized = vector_index.quantize(&write.embedding) orelse return .invalid_vector;
    assert(quantized.scale > 0);
    assert(std.math.isFinite(quantized.scale));
    out.* = .{ .id = write.link_id, .scale = quantized.scale, .values = quantized.values };
    return .ok;
}

pub fn put_category_vectors(
    db: *Directory,
    model: u64,
    writes: []const CategoryVectorWrite,
    results: []VectorWriteResult,
) !void {
    assert(writes.len == results.len);
    if (model == 0) return error.InvalidEmbeddingModel;
    if (writes.len > vectors_per_write_max) return error.TooManyVectors;

    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    const current = db.link_vector_index.model.load(.acquire);
    if (current != 0 and current != model) return error.EmbeddingModelMismatch;

    var accepted: [vectors_per_write_max]schema.StoredVector = undefined;
    var accepted_len: usize = 0;
    for (writes, results) |*write, *result| {
        assert(accepted_len < accepted.len);
        result.* = try check_category_write(db, write, &accepted[accepted_len]);
        if (result.* == .ok) accepted_len += 1;
    }
    assert(accepted_len <= writes.len);
    if (accepted_len == 0) return;

    try db.commit(.{ .category_vectors_put = .{
        .model = model,
        .vectors = accepted[0..accepted_len],
    } });
}

fn check_category_write(
    db: *Directory,
    write: *const CategoryVectorWrite,
    out: *schema.StoredVector,
) !VectorWriteResult {
    const target = (try category.get_category(db, write.category_id)) orelse return .not_found;
    assert(target.id == write.category_id);
    const quantized = vector_index.quantize(&write.embedding) orelse return .invalid_vector;
    assert(quantized.scale > 0);
    assert(std.math.isFinite(quantized.scale));
    out.* = .{ .id = write.category_id, .scale = quantized.scale, .values = quantized.values };
    return .ok;
}

pub fn get_link_vector(db: *Directory, link_id: u64) !?schema.StoredVector {
    comptime assert(@sizeOf(schema.LinkVector) >= @sizeOf(schema.StoredVector));
    const key = codec.encodeU64(link_id);
    var buffer: [@sizeOf(schema.LinkVector)]u8 = undefined;
    const bytes = (try db.link_vectors().search(&key, &buffer)) orelse return null;
    const stored = schema.stored_vector_prefix(bytes) orelse return null;
    assert(stored.id == link_id);
    return stored;
}

pub fn load_vector_index(db: *Directory) !void {
    var next_id: u64 = 0;
    while (!db.link_vector_index.loader_stop.load(.acquire)) {
        const chunk_start_id = next_id;
        const scanned = try load_link_chunk(db, &next_id);
        assert(scanned <= load_chunk);
        if (scanned > 0) assert(next_id > chunk_start_id);
        if (scanned < load_chunk) {
            db.link_vector_index.ready.store(true, .release);
            return;
        }
    }
}

pub fn load_category_vector_index(db: *Directory) !void {
    var next_id: u64 = 0;
    while (!db.category_vector_index.loader_stop.load(.acquire)) {
        const chunk_start_id = next_id;
        const scanned = try load_category_chunk(db, &next_id);
        assert(scanned <= load_chunk);
        if (scanned > 0) assert(next_id > chunk_start_id);
        if (scanned < load_chunk) {
            db.category_vector_index.ready.store(true, .release);
            return;
        }
    }
}

fn load_link_chunk(db: *Directory, next_id: *u64) !usize {
    const index = &db.link_vector_index;
    index.lock.lockUncancelable(db.io);
    defer index.lock.unlock(db.io);

    const start_id = next_id.*;
    const start_key = codec.encodeU64(start_id);
    var iterator = try db.link_vectors().rangeScan(&start_key, null);
    defer iterator.deinit();

    var scanned: usize = 0;
    while (scanned < load_chunk) : (scanned += 1) {
        const entry = (try iterator.next()) orelse break;
        next_id.* = codec.decodeU64(entry.key[0..8]) + 1;
        const stored = schema.stored_vector_prefix(entry.value) orelse continue;
        try index.put_locked(
            db.allocator,
            stored.id,
            &codes_for(index.codebooks, entry.value, &stored),
        );
    }
    assert(scanned <= load_chunk);
    if (scanned > 0) assert(next_id.* > start_id);
    return scanned;
}

// A record written under the current model file carries its cell and codes, so only a record
// from another model file is encoded again; the stored vector is the record's prefix.
fn codes_for(
    model: *const vector_model.Model,
    bytes: []const u8,
    stored: *const schema.StoredVector,
) vector_model.Encoded {
    comptime assert(@offsetOf(schema.LinkVector, "vector") == 0);
    assert(bytes.len >= @sizeOf(schema.StoredVector));
    if (bytes.len == @sizeOf(schema.LinkVector)) {
        const record = std.mem.bytesToValue(
            schema.LinkVector,
            bytes[0..@sizeOf(schema.LinkVector)],
        );
        assert(record.vector.id == stored.id);
        if (record.model_hash == model.hash) return .{ .cell = record.cell, .codes = record.codes };
    }
    return model.encode(stored);
}

fn load_category_chunk(db: *Directory, next_id: *u64) !usize {
    const index = &db.category_vector_index;
    index.lock.lockUncancelable(db.io);
    defer index.lock.unlock(db.io);

    const start_id = next_id.*;
    const start_key = codec.encodeU64(start_id);
    var iterator = try db.category_vectors().rangeScan(&start_key, null);
    defer iterator.deinit();

    var scanned: usize = 0;
    while (scanned < load_chunk) : (scanned += 1) {
        const entry = (try iterator.next()) orelse break;
        next_id.* = codec.decodeU64(entry.key[0..8]) + 1;
        if (entry.value.len != @sizeOf(schema.StoredVector)) continue;
        try index.put_locked(
            db.allocator,
            &std.mem.bytesToValue(
                schema.StoredVector,
                entry.value[0..@sizeOf(schema.StoredVector)],
            ),
        );
    }
    assert(scanned <= load_chunk);
    if (scanned > 0) assert(next_id.* > start_id);
    return scanned;
}

const testing = std.testing;
const category = @import("operations_category.zig");
const search = @import("operations_search.zig");
const verifier = @import("../verifier.zig");

const test_model: u64 = 0xB6E5_5A11;

fn axis_embedding(axis: usize) vector_index.Embedding {
    assert(axis < schema.embedding_dimensions);
    var embedding: vector_index.Embedding = @splat(0);
    embedding[axis] = 1;
    return embedding;
}

fn write_for(db: *Directory, link_id: u64, axis: usize) !VectorWrite {
    const link = (try link_operations.get_link(db, link_id)).?;
    assert(link.id == link_id);
    return .{
        .link_id = link_id,
        .text_fingerprint = schema.link_text_fingerprint(&link),
        .embedding = axis_embedding(axis),
    };
}

fn put_one(db: *Directory, model: u64, write: VectorWrite) !VectorWriteResult {
    assert(write.link_id != 0);
    var result: [1]VectorWriteResult = undefined;
    try put_link_vectors(db, model, &.{write}, &result);
    return result[0];
}

// Goal: an accepted vector is stored quantised, the model id is recorded and the in-memory
// index holds it. Method: one axis vector, then the stored record, the counter and the index.
test "put_link_vectors stores a quantised vector, records the model, and indexes it" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const id = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://bonsai.example", .title = "Bonsai", .description = "Small trees" },
    );

    try testing.expectEqual(
        VectorWriteResult.ok,
        try put_one(db, test_model, try write_for(db, id, 3)),
    );

    const stored = (try get_link_vector(db, id)).?;
    try testing.expectEqual(@as(i8, 127), stored.values[3]);
    try testing.expectEqual(test_model, db.store.counter("embedding_model").*);
    try testing.expectEqual(test_model, db.link_vector_index.model.load(.acquire));
    try testing.expectEqual(@as(usize, 1), db.link_vector_index.count(db.io));
}

// Goal: an unknown link, a stale text fingerprint and a zero vector are each refused with
// their own result and nothing is stored. Method: three bad writes in one call.
test "put_link_vectors refuses a bad write per result" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const id = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://bonsai.example", .title = "Bonsai", .description = "Small trees" },
    );

    var unknown = try write_for(db, id, 0);
    unknown.link_id = id + 100;
    var stale = try write_for(db, id, 0);
    stale.text_fingerprint +%= 1;
    var empty = try write_for(db, id, 0);
    empty.embedding = @splat(0);

    var results: [3]VectorWriteResult = undefined;
    try put_link_vectors(db, test_model, &.{ unknown, stale, empty }, &results);
    try testing.expectEqual(VectorWriteResult.not_found, results[0]);
    try testing.expectEqual(VectorWriteResult.stale_text, results[1]);
    try testing.expectEqual(VectorWriteResult.invalid_vector, results[2]);
    try testing.expectEqual(@as(?schema.StoredVector, null), try get_link_vector(db, id));
    try testing.expectEqual(@as(u64, 0), db.store.counter("embedding_model").*);
}

// Goal: a store holds vectors of one model, and model id zero is invalid. Method: write
// under one model, then under another and under zero.
test "put_link_vectors refuses a second embedding model and model id zero" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const id = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://bonsai.example", .title = "Bonsai", .description = "" },
    );
    _ = try put_one(db, test_model, try write_for(db, id, 0));

    try testing.expectError(
        error.EmbeddingModelMismatch,
        put_one(db, test_model + 1, try write_for(db, id, 1)),
    );
    try testing.expectError(error.InvalidEmbeddingModel, put_one(db, 0, try write_for(db, id, 1)));
}

// Goal: a vector is dropped only when the text it embeds changes. Method: change the status
// and url, confirm the vector stays, then change the description.
test "editing a link's title or description drops its vector; a status or url change keeps it" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const id = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://bonsai.example", .title = "Bonsai", .description = "Small trees" },
    );
    _ = try put_one(db, test_model, try write_for(db, id, 0));

    try link_operations.update_link_status(db, id, @intFromEnum(schema.LinkStatus.rejected));
    try link_operations.update_link(db, id, "https://bonsai-club.example", null, null);
    try testing.expect((try get_link_vector(db, id)) != null);
    try testing.expectEqual(@as(usize, 1), db.link_vector_index.count(db.io));

    try link_operations.update_link(db, id, null, null, "Miniature trees");
    try testing.expectEqual(@as(?schema.StoredVector, null), try get_link_vector(db, id));
    try testing.expectEqual(@as(usize, 0), db.link_vector_index.count(db.io));
}

// Goal: a delete drops the link's vector so the verifier's orphan check stays clean. Method:
// two vectors, one link deleted, then the index count and one verifier pass.
test "deleting a link drops its vector so the verifier finds no vector without a link" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const kept = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://kept.example", .title = "Kept", .description = "" },
    );
    const gone = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://gone.example", .title = "Gone", .description = "" },
    );
    var results: [2]VectorWriteResult = undefined;
    try put_link_vectors(
        db,
        test_model,
        &.{ try write_for(db, kept, 0), try write_for(db, gone, 1) },
        &results,
    );

    try link_operations.delete_link(db, gone);
    try testing.expectEqual(@as(?schema.StoredVector, null), try get_link_vector(db, gone));
    try testing.expectEqual(@as(usize, 1), db.link_vector_index.count(db.io));

    var state: verifier.VerifierState = .{};
    try verifier.run_once(db, &state);
    const health = state.indices[@intFromEnum(verifier.InvariantId.link_vectors_have_links)];
    try testing.expectEqual(@as(u64, 1), health.expected);
    try testing.expectEqual(@as(u64, 1), health.observed);
}

// Goal: vectors come back after a crash replay, minus the one whose link was retitled, and
// the loader marks the index ready. Method: three vectors, one retitle, crash, recover, load.
test "a crash after acked vector writes replays the WAL into the same vector index" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const ids = blk: {
        const crashed = try Directory.open_test_instance(testing.allocator, &temporary_directory);
        const top = try category.create_category(
            crashed,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const first = try link_operations.create_link(
            crashed,
            top,
            .{ .url = "https://first.example", .title = "First", .description = "" },
        );
        const second = try link_operations.create_link(
            crashed,
            top,
            .{ .url = "https://second.example", .title = "Second", .description = "" },
        );
        const third = try link_operations.create_link(
            crashed,
            top,
            .{ .url = "https://third.example", .title = "Third", .description = "" },
        );
        var results: [3]VectorWriteResult = undefined;
        try put_link_vectors(
            crashed,
            test_model,
            &.{
                try write_for(crashed, first, 0),
                try write_for(crashed, second, 1),
                try write_for(crashed, third, 2),
            },
            &results,
        );
        try link_operations.update_link(crashed, second, null, "Second, renamed", null);
        crashed.deinit_crash_test_instance();
        break :blk .{ first, second, third };
    };

    const recovered = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer recovered.deinit_test_instance();
    try recovered.recover();
    try load_vector_index(recovered);

    try testing.expect(recovered.link_vector_index.ready.load(.acquire));
    try testing.expectEqual(test_model, recovered.link_vector_index.model.load(.acquire));
    try testing.expectEqual(@as(usize, 2), recovered.link_vector_index.count(recovered.io));
    try testing.expect((try get_link_vector(recovered, ids[0])) != null);
    try testing.expectEqual(
        @as(?schema.StoredVector, null),
        try get_link_vector(recovered, ids[1]),
    );

    var buffer: [1]@import("../ranking.zig").ScoredId = undefined;
    try testing.expectEqual(
        ids[2],
        recovered.link_vector_index.shortlist(recovered.io, &axis_embedding(2), &buffer)[0].id,
    );
}

// Goal: the loader accepts a bare stored vector and re-encodes a record written under another
// model file instead of trusting its codes. Method: insert both record shapes, then load.
test "the loader codes a format-8 record and re-codes a record written under another model file" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const legacy = vector_index.quantize(&axis_embedding(4)).?;
    const legacy_record = schema.StoredVector{
        .id = 41,
        .scale = legacy.scale,
        .values = legacy.values,
    };
    const legacy_key = codec.encodeU64(41);
    try db.link_vectors().insert(&legacy_key, std.mem.asBytes(&legacy_record));

    const foreign = vector_index.quantize(&axis_embedding(5)).?;
    const foreign_record = schema.LinkVector{
        .vector = .{ .id = 42, .scale = foreign.scale, .values = foreign.values },
        .model_hash = db.link_vector_index.codebooks.hash +% 1,
        .cell = 0,
        .codes = @splat(0),
    };
    const foreign_key = codec.encodeU64(42);
    try db.link_vectors().insert(&foreign_key, std.mem.asBytes(&foreign_record));

    try load_vector_index(db);
    try testing.expectEqual(@as(usize, 2), db.link_vector_index.count(db.io));

    var buffer: [1]@import("../ranking.zig").ScoredId = undefined;
    try testing.expectEqual(
        @as(u64, 41),
        db.link_vector_index.shortlist(db.io, &axis_embedding(4), &buffer)[0].id,
    );
    try testing.expectEqual(
        @as(u64, 42),
        db.link_vector_index.shortlist(db.io, &axis_embedding(5), &buffer)[0].id,
    );
    try testing.expectEqual(
        db.link_vector_index.codebooks.encode(&foreign_record.vector).cell,
        db.link_vector_index.position.get(42).?.cell,
    );
}

// Goal: hybrid search adds a link found only by vector similarity, and falls back to keywords
// alone when the query embedding comes from another model. Method: two links, two models.
test "hybrid search adds a vector-only match, and falls back to keywords for another model" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const keyword_hit = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://a.example", .title = "Miniature trees", .description = "" },
    );
    const meaning_hit = try link_operations.create_link(
        db,
        top,
        .{ .url = "https://b.example", .title = "Bonsai", .description = "Japanese art form" },
    );
    var results: [2]VectorWriteResult = undefined;
    try put_link_vectors(
        db,
        test_model,
        &.{ try write_for(db, keyword_hit, 0), try write_for(db, meaning_hit, 1) },
        &results,
    );
    try load_vector_index(db);

    var buffer: [8]schema.Link = undefined;
    const hybrid = try search.search_links_hybrid(
        db,
        "miniature trees",
        test_model,
        &axis_embedding(1),
        8,
        &buffer,
        null,
    );
    try testing.expect(hybrid.vector_used);
    try testing.expectEqual(@as(usize, 2), hybrid.links.len);

    const fallback = try search.search_links_hybrid(
        db,
        "miniature trees",
        test_model + 1,
        &axis_embedding(1),
        8,
        &buffer,
        null,
    );
    try testing.expect(!fallback.vector_used);
    try testing.expectEqual(@as(usize, 1), fallback.links.len);
    try testing.expectEqual(keyword_hit, fallback.links[0].id);
}
