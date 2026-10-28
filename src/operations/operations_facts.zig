//! The graph-facts layer over links: loading the in-memory facts index from the category, link
//! and entity trees at startup, the entity writes the enricher sends, and the filter and count
//! queries the question pages answer from it. A query answers `ready = false` until the loader
//! has read every tree, so a half-built index never answers.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("zigstore").codec;
const inverted = @import("zigstore").inverted_index;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const facts_index = @import("../facts/facts_index.zig");
const entities = @import("../facts/entities.zig");
const changeset = @import("../changeset.zig");
const link_operations = @import("operations_link.zig");
const category = @import("operations_category.zig");
const search = @import("operations_search.zig");

const load_chunk: u32 = 512;
pub const query_words_max: usize = 32;
pub const entity_writes_max: usize = 64;

pub const EntityWrite = struct {
    link_id: u64,
    text_fingerprint: u64,
    facts: []const u8,
};

pub const EntityWriteResult = enum(u8) {
    ok = 0,
    not_found = 1,
    stale_text = 2,
    invalid_facts = 3,
};

pub fn put_link_entities(
    db: *Directory,
    writes: []const EntityWrite,
    results: []EntityWriteResult,
) !void {
    assert(writes.len == results.len);
    if (writes.len > entity_writes_max) return error.TooManyEntityWrites;

    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    var accepted: [entity_writes_max]changeset.LinkEntitiesEntry = undefined;
    var accepted_len: usize = 0;
    for (writes, results) |*write, *result| {
        result.* = try check_entity_write(db, write);
        if (result.* != .ok) continue;
        assert(accepted_len < accepted.len);
        accepted[accepted_len] = .{ .link_id = write.link_id, .facts = write.facts };
        accepted_len += 1;
    }
    assert(accepted_len <= writes.len);
    if (accepted_len == 0) return;

    try db.commit(.{ .link_entities_put = .{ .entries = accepted[0..accepted_len] } });
}

fn check_entity_write(db: *Directory, write: *const EntityWrite) !EntityWriteResult {
    const link = (try link_operations.get_link(db, write.link_id)) orelse return .not_found;
    assert(link.id == write.link_id);
    if (schema.link_text_fingerprint(&link) != write.text_fingerprint) return .stale_text;
    if (entities.decode(write.facts) == null) return .invalid_facts;
    return .ok;
}

pub const WordsMatch = enum(u8) { any = 0, all = 1 };

pub const LinkQuery = struct {
    facts: facts_index.Query = .{},
    words: []const u8 = "",
    words_match: WordsMatch = .any,
};

pub const QueriedLink = struct {
    link: schema.Link,
    row: facts_index.PageRow,
};

pub const LinkQueryResult = struct {
    ready: bool,
    answer: facts_index.Answer,
    links: []const QueriedLink,
};

const not_ready: LinkQueryResult = .{
    .ready = false,
    .answer = .{
        .total = 0,
        .sites = 0,
        .hosts = 0,
        .domains = 0,
        .groups = &.{},
        .page = &.{},
        .next_after_id = 0,
    },
    .links = &.{},
};

pub fn load_facts_index(db: *Directory) !void {
    db.facts.begin_load(db.io);
    try load_category_facts(db);
    try load_link_facts(db);
    try load_entity_facts(db);
    if (db.facts.loader_stop.load(.acquire)) return;
    db.facts.finish_load(db.io, db.allocator);
    assert(db.facts.ready.load(.acquire));
}

fn load_category_facts(db: *Directory) !void {
    const buffer = try db.allocator.alloc(schema.Category, load_chunk);
    defer db.allocator.free(buffer);

    var next_id: u64 = 0;
    while (!db.facts.loader_stop.load(.acquire)) {
        try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
        const chunk_start_id = next_id;
        const chunk = try read_category_chunk(db, &next_id, buffer);
        assert(chunk.len <= buffer.len);
        if (chunk.len > 0) assert(next_id > chunk_start_id);
        for (chunk) |record| try db.facts.load_category(db.io, db.allocator, &record);
        if (chunk.len < buffer.len) return;
    }
}

fn read_category_chunk(
    db: *Directory,
    next_id: *u64,
    buffer: []schema.Category,
) ![]schema.Category {
    assert(buffer.len > 0);
    const start_id = next_id.*;
    const start_key = codec.encodeU64(start_id);
    var iterator = try db.categories_by_id().rangeScan(&start_key, null);
    defer iterator.deinit();

    var len: usize = 0;
    while (len < buffer.len) {
        const entry = (try iterator.next()) orelse break;
        next_id.* = codec.decodeU64(entry.key[0..8]) + 1;
        if (entry.value.len < @sizeOf(schema.Category)) continue;
        buffer[len] = std.mem.bytesToValue(
            schema.Category,
            entry.value[0..@sizeOf(schema.Category)],
        );
        len += 1;
    }
    assert(len <= buffer.len);
    if (len > 0) assert(next_id.* > start_id);
    return buffer[0..len];
}

fn load_link_facts(db: *Directory) !void {
    const buffer = try db.allocator.alloc(schema.Link, load_chunk);
    defer db.allocator.free(buffer);

    var after_id: u64 = 0;
    while (!db.facts.loader_stop.load(.acquire)) {
        const page = try link_operations.list_all_links(
            db,
            .{ .limit = load_chunk, .after_id = after_id },
            buffer,
        );
        assert(page.items.len <= load_chunk);
        for (page.items) |link| try db.facts.load_link(db.io, db.allocator, &link);
        if (page.next_after_id == 0) return;
        assert(page.next_after_id > after_id);
        after_id = page.next_after_id;
    }
}

fn load_entity_facts(db: *Directory) !void {
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();

    var next_id: u64 = 0;
    while (!db.facts.loader_stop.load(.acquire)) {
        _ = arena.reset(.retain_capacity);
        const chunk_start_id = next_id;
        const chunk = try read_entity_chunk(db, &next_id, arena.allocator());
        assert(chunk.len <= load_chunk);
        if (chunk.len > 0) assert(next_id > chunk_start_id);
        for (chunk) |entry| try db.facts.load_entities(
            db.io,
            db.allocator,
            entry.link_id,
            entry.facts,
        );
        if (chunk.len < load_chunk) return;
    }
}

fn read_entity_chunk(
    db: *Directory,
    next_id: *u64,
    arena: std.mem.Allocator,
) ![]const changeset.LinkEntitiesEntry {
    const start_id = next_id.*;
    const start_key = codec.encodeU64(start_id);
    var iterator = try db.link_entities().rangeScan(&start_key, null);
    defer iterator.deinit();

    var chunk: std.ArrayListUnmanaged(changeset.LinkEntitiesEntry) = .empty;
    while (chunk.items.len < load_chunk) {
        const entry = (try iterator.next()) orelse break;
        const link_id = codec.decodeU64(entry.key[0..8]);
        next_id.* = link_id + 1;
        try chunk.append(arena, .{ .link_id = link_id, .facts = try arena.dupe(u8, entry.value) });
    }
    assert(chunk.items.len <= load_chunk);
    if (chunk.items.len > 0) assert(next_id.* > start_id);
    return chunk.items;
}

pub fn query_links(
    db: *Directory,
    request: *const LinkQuery,
    arena: std.mem.Allocator,
) !LinkQueryResult {
    if (!db.facts.ready.load(.acquire)) return not_ready;

    var query = request.facts;
    var allowed: facts_index.IdSet = .empty;
    if (request.words.len > 0) {
        allowed = try links_with_words(db, request.words, request.words_match, arena);
        query.allowed_ids = &allowed;
    }
    if (request.words.len == 0) assert(query.allowed_ids == null);
    const answer = try db.facts.query(db.io, db.scratch(), arena, query);
    assert(answer.page.len <= request.facts.page_limit);

    var links = try std.ArrayListUnmanaged(QueriedLink).initCapacity(arena, answer.page.len);
    for (answer.page) |row| {
        const link = (try link_operations.get_link(db, row.link_id)) orelse continue;
        links.appendAssumeCapacity(.{ .link = link, .row = row });
    }
    assert(links.items.len <= answer.page.len);
    return .{ .ready = true, .answer = answer, .links = links.items };
}

pub const name_matches_max: usize = 32;

pub const NameMatch = struct {
    category_id: u64 = 0,
    names_someone: bool = false,
};

pub fn match_names(
    db: *Directory,
    arena: std.mem.Allocator,
    phrases: []const []const u8,
    out: []NameMatch,
) !bool {
    assert(phrases.len == out.len);
    assert(phrases.len <= name_matches_max);
    if (!db.facts.ready.load(.acquire)) return false;
    for (phrases, out) |phrase, *match| {
        match.* = .{ .names_someone = db.facts.names_someone(db.io, phrase) };
        var largest: u64 = 0;
        for (try db.facts.categories_named(db.io, arena, phrase)) |id| {
            const candidate = (try category.get_category(db, id)) orelse continue;
            if (match.category_id != 0 and candidate.link_count_subtree <= largest) continue;
            match.category_id = id;
            largest = candidate.link_count_subtree;
        }
    }
    return true;
}

fn links_with_words(
    db: *Directory,
    words: []const u8,
    match: WordsMatch,
    arena: std.mem.Allocator,
) !facts_index.IdSet {
    assert(words.len > 0);
    const tokens = try distinct_tokens(words, arena);
    assert(tokens.len <= query_words_max);
    if (tokens.len == 0) return error.NoSearchableWords;

    var allowed: facts_index.IdSet = .empty;
    for (tokens, 0..) |token, i| {
        const ids = try search.postings_for_token(
            db.links_index_tree(),
            token,
            arena,
            std.math.maxInt(usize),
        );
        if (match == .any or i == 0) {
            for (ids) |id| try allowed.put(arena, id, {});
            continue;
        }
        var kept: facts_index.IdSet = .empty;
        for (ids) |id| {
            if (allowed.contains(id)) try kept.put(arena, id, {});
        }
        assert(kept.count() <= allowed.count());
        allowed = kept;
    }
    return allowed;
}

fn distinct_tokens(words: []const u8, arena: std.mem.Allocator) ![]const []const u8 {
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var token_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var iterator = inverted.TokenIterator.init(words);
    while (iterator.next(&token_buffer)) |token| {
        assert(token.len >= inverted.MIN_TOKEN_LEN);
        assert(token.len <= inverted.MAX_TOKEN_LEN);
        if (tokens.items.len == query_words_max) break;
        if (contains_token(tokens.items, token)) continue;
        try tokens.append(arena, try arena.dupe(u8, token));
    }
    assert(tokens.items.len <= query_words_max);
    return tokens.items;
}

fn contains_token(tokens: []const []const u8, token: []const u8) bool {
    assert(tokens.len <= query_words_max);
    assert(token.len > 0);
    for (tokens) |existing| {
        if (std.mem.eql(u8, existing, token)) return true;
    }
    return false;
}

const testing = std.testing;

fn answer_for(db: *Directory, arena: std.mem.Allocator, request: LinkQuery) !facts_index.Answer {
    const result = try query_links(db, &request, arena);
    try testing.expect(result.ready);
    assert(result.links.len <= result.answer.page.len);
    return result.answer;
}

// Goal: a query answers `ready = false` until the loader has finished. Method: query before
// and after `load_facts_index`.
test "query_links is not ready until the loader has read the trees" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(!(try query_links(db, &.{}, arena_state.allocator())).ready);

    try load_facts_index(db);
    try testing.expect((try query_links(db, &.{}, arena_state.allocator())).ready);
}

// Goal: the live facts index follows creates, moves, edits, deletes and status changes, and a
// reload from the trees produces the same answer. Method: apply each write, query, rebuild
// the index from scratch, then compare the grouped answers.
test "facts follow every write through the apply path and a reload from the trees agrees" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try load_facts_index(db);

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const society = try category.create_category(
        db,
        top,
        .{ .name = "Society", .slug = "society", .description = "" },
    );
    const pakistan = try category.create_category(
        db,
        society,
        .{ .name = "Pakistan", .slug = "pakistan", .description = "" },
    );
    const arts = try category.create_category(
        db,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );

    const moved = try link_operations.create_link(
        db,
        arts,
        .{ .url = "http://samvak.tripod.com/", .title = "Samvak", .description = "" },
    );
    const edited = try link_operations.create_link(
        db,
        society,
        .{ .url = "http://example.com/", .title = "Example", .description = "" },
    );
    const deleted = try link_operations.create_link(
        db,
        society,
        .{ .url = "http://gone.example.org/", .title = "Gone", .description = "" },
    );
    const pending = try link_operations.create_link(
        db,
        society,
        .{ .url = "http://www.uet.edu.pk/", .title = "UET", .description = "" },
    );
    try link_operations.move_link(db, .{ .id = moved, .new_parent_id = pakistan });
    try link_operations.update_link(db, edited, "http://www.storyofpakistan.com/", null, null);
    try link_operations.delete_link(db, deleted);
    try link_operations.update_link_status(db, pending, @intFromEnum(schema.LinkStatus.pending));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const live = try answer_for(
        db,
        arena,
        .{ .facts = .{ .country = "PK".*, .group_by = .domain } },
    );
    try testing.expectEqual(@as(u64, 1), live.total);
    try testing.expectEqual(moved, live.page[0].link_id);
    const live_society = try answer_for(
        db,
        arena,
        .{ .facts = .{ .category_id = society, .status = null, .group_by = .domain } },
    );
    try testing.expectEqual(@as(u64, 3), live_society.total);
    try testing.expectEqualStrings("storyofpakistan.com", live_society.groups[0].label);

    db.facts.deinit(db.allocator);
    db.facts = .{};
    try load_facts_index(db);

    const reloaded = try answer_for(
        db,
        arena,
        .{ .facts = .{ .category_id = society, .status = null, .group_by = .domain } },
    );
    try testing.expectEqual(live_society.total, reloaded.total);
    try testing.expectEqual(live_society.sites, reloaded.sites);
    for (live_society.groups, reloaded.groups) |live_group, reloaded_group| {
        try testing.expectEqualStrings(live_group.label, reloaded_group.label);
        try testing.expectEqual(live_group.links, reloaded_group.links);
    }
}

// Goal: facts rebuilt after a crash replay match the acknowledged writes, including a delete.
// Method: write three links and delete one, crash, recover, then query hosted sites.
test "a crash after acked writes replays the WAL into the same facts" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const kept = blk: {
        const crashed = try Directory.open_test_instance(testing.allocator, &temporary_directory);
        const top = try category.create_category(
            crashed,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const arts = try category.create_category(
            crashed,
            top,
            .{ .name = "Arts", .slug = "arts", .description = "" },
        );
        _ = try link_operations.create_link(
            crashed,
            arts,
            .{ .url = "http://members.tripod.com/~one/", .title = "One", .description = "" },
        );
        const two = try link_operations.create_link(
            crashed,
            arts,
            .{ .url = "http://members.tripod.com/~two/", .title = "Two", .description = "" },
        );
        const three = try link_operations.create_link(
            crashed,
            arts,
            .{ .url = "http://three.blogspot.com/", .title = "Three", .description = "" },
        );
        try link_operations.delete_link(crashed, two);
        crashed.deinit_crash_test_instance();
        break :blk three;
    };

    const recovered = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer recovered.deinit_test_instance();
    try recovered.recover();
    try load_facts_index(recovered);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const answer = try answer_for(
        recovered,
        arena_state.allocator(),
        .{ .facts = .{ .hosted_only = true, .group_by = .domain } },
    );
    try testing.expectEqual(@as(u64, 2), answer.total);
    try testing.expectEqual(@as(u64, 2), answer.sites);
    try testing.expectEqual(kept, answer.page[1].link_id);
}

// Goal: the words filter is an OR by default and an AND on request, and a query with no
// searchable word is refused. Method: three links, two words, both match modes.
test "a words filter keeps links matching any word, or only those matching all" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try load_facts_index(db);

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top,
        .{ .url = "http://a.example/", .title = "Islamic art", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top,
        .{ .url = "http://b.example/", .title = "Muslim and Islamic history", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        top,
        .{ .url = "http://c.example/", .title = "Garden roses", .description = "" },
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(
        @as(u64, 2),
        (try answer_for(db, arena, .{ .words = "islamic muslim", .words_match = .any })).total,
    );
    try testing.expectEqual(
        @as(u64, 1),
        (try answer_for(db, arena, .{ .words = "islamic muslim", .words_match = .all })).total,
    );
    try testing.expectError(error.NoSearchableWords, query_links(db, &.{ .words = "a" }, arena));
}

fn islam_in_pakistan(buffer: []u8, person: []const u8) ![]const u8 {
    assert(person.len > 0);
    assert(person.len <= entities.name_len_max);
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeByte(1);
    try writer.writeInt(u16, @as(u16, 1) << @intFromEnum(entities.Religion.islam), .little);
    try writer.writeByte(1);
    try writer.writeAll("PK");
    try writer.writeByte(1);
    try writer.writeByte(@intCast(person.len));
    try writer.writeAll(person);
    try writer.writeByte(0);
    return buffer[0..writer.end];
}

fn entity_write(db: *Directory, link_id: u64, facts: []const u8) !EntityWrite {
    assert(facts.len <= entities.encoded_len_max);
    const link = (try link_operations.get_link(db, link_id)).?;
    assert(link.id == link_id);
    return .{
        .link_id = link_id,
        .text_fingerprint = schema.link_text_fingerprint(&link),
        .facts = facts,
    };
}

// Goal: valid facts are stored and found by entity name, while an unknown link, a stale
// fingerprint and malformed facts are each refused with their own result, and more writes
// than the maximum are rejected whole. Method: four writes in one call, then the overflow.
test "put_link_entities accepts valid facts and refuses the rest" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try load_facts_index(db);

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const id = try link_operations.create_link(
        db,
        top,
        .{
            .url = "http://www.storyofpakistan.com/",
            .title = "Story of Pakistan: Deoband Movement",
            .description = "",
        },
    );
    var buffer: [128]u8 = undefined;
    const facts = try islam_in_pakistan(&buffer, "Muhammad Qasim Nanautavi");

    var stale = try entity_write(db, id, facts);
    stale.text_fingerprint +%= 1;
    const writes = [_]EntityWrite{
        try entity_write(db, id, facts),
        .{ .link_id = 999_999, .text_fingerprint = 0, .facts = facts },
        stale,
        try entity_write(db, id, "\x01\xff\xff"),
    };
    var results: [writes.len]EntityWriteResult = undefined;
    try put_link_entities(db, &writes, &results);

    try testing.expectEqualSlices(
        EntityWriteResult,
        &.{ .ok, .not_found, .stale_text, .invalid_facts },
        &results,
    );
    var value_buffer: [entities.encoded_len_max]u8 = undefined;
    const key = codec.encodeU64(id);
    try testing.expectEqualSlices(
        u8,
        facts,
        (try db.link_entities().search(&key, &value_buffer)).?,
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const answer = try answer_for(
        db,
        arena_state.allocator(),
        .{ .facts = .{ .entity_name = "muhammad qasim nanautavi" } },
    );
    try testing.expectEqual(@as(u64, 1), answer.total);
    const too_many = [_]EntityWrite{writes[0]} ** (entity_writes_max + 1);
    var too_many_results: [too_many.len]EntityWriteResult = undefined;
    try testing.expectError(
        error.TooManyEntityWrites,
        put_link_entities(db, &too_many, &too_many_results),
    );
}

// Goal: entity facts come back after a crash replay and reload, except for a link whose text
// changed after it was described. Method: two described links, one retitled, crash, recover.
test "entity facts survive a crash replay, a reload, and are dropped with the text they describe" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();

    const ids = blk: {
        const crashed = try Directory.open_test_instance(testing.allocator, &temporary_directory);
        const top = try category.create_category(
            crashed,
            0,
            .{ .name = "Top", .slug = "top", .description = "" },
        );
        const kept = try link_operations.create_link(
            crashed,
            top,
            .{ .url = "http://www.farooqia.com/", .title = "Jamia Farooqia", .description = "" },
        );
        const retitled = try link_operations.create_link(
            crashed,
            top,
            .{
                .url = "http://www.storyofpakistan.com/",
                .title = "Story of Pakistan",
                .description = "",
            },
        );
        var buffer: [2][128]u8 = undefined;
        var results: [2]EntityWriteResult = undefined;
        try put_link_entities(crashed, &.{
            try entity_write(crashed, kept, try islam_in_pakistan(
                &buffer[0],
                "Mufti Muhammad Shafi",
            )),
            try entity_write(crashed, retitled, try islam_in_pakistan(
                &buffer[1],
                "Muhammad Ali Jinnah",
            )),
        }, &results);
        try link_operations.update_link(
            crashed,
            retitled,
            null,
            "Story of Pakistan, renamed",
            null,
        );
        crashed.deinit_crash_test_instance();
        break :blk .{ kept, retitled };
    };

    const recovered = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer recovered.deinit_test_instance();
    try recovered.recover();
    try load_facts_index(recovered);

    try testing.expectEqual(@as(usize, 1), recovered.facts.entity_count(recovered.io));
    try testing.expect(recovered.facts.entities.get(ids[0]) != null);
    try testing.expect(recovered.facts.entities.get(ids[1]) == null);
    try testing.expectEqual(@as(u64, 1), recovered.link_entities().entryCount());
}

// Goal: a phrase resolves to the largest category carrying that name in any case or number,
// and a person named in entity facts is reported as naming someone. Method: `art`, `SOCIETY`,
// a person and an unknown word in one call.
test "match_names resolves category names and person names" {
    var temporary_directory = testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = try Directory.open_test_instance(testing.allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try load_facts_index(db);

    const top = try category.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const arts = try category.create_category(
        db,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    const society = try category.create_category(
        db,
        top,
        .{ .name = "Society", .slug = "society", .description = "" },
    );
    const art = try category.create_category(
        db,
        society,
        .{ .name = "Art", .slug = "art", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        arts,
        .{ .url = "http://one.example.com/", .title = "One", .description = "" },
    );
    _ = try link_operations.create_link(
        db,
        arts,
        .{ .url = "http://two.example.com/", .title = "Two", .description = "" },
    );
    const poem = try link_operations.create_link(
        db,
        art,
        .{
            .url = "http://www.versedaily.org/mermaid.shtml",
            .title = "Mermaid by Moniza Alvi",
            .description = "",
        },
    );

    var buffer: [128]u8 = undefined;
    var results: [1]EntityWriteResult = undefined;
    try put_link_entities(
        db,
        &.{try entity_write(db, poem, try islam_in_pakistan(&buffer, "Moniza Alvi"))},
        &results,
    );

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var matches: [4]NameMatch = undefined;
    try testing.expect(try match_names(
        db,
        arena_state.allocator(),
        &.{ "art", "SOCIETY", "moniza alvi", "jazz" },
        &matches,
    ));

    try testing.expectEqual(arts, matches[0].category_id);
    try testing.expectEqual(society, matches[1].category_id);
    try testing.expect(matches[2].names_someone);
    try testing.expectEqual(@as(u64, 0), matches[2].category_id);
    try testing.expectEqual(NameMatch{}, matches[3]);
}
