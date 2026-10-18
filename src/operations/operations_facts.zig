const std = @import("std");
const codec = @import("zigstore").codec;
const inverted = @import("zigstore").inverted_index;
const schema = @import("../schema.zig");
const Directory = @import("../directory.zig").Directory;
const facts_index = @import("../facts/facts_index.zig");
const entities = @import("../facts/entities.zig");
const changeset = @import("../changeset.zig");
const link_mod = @import("operations_link.zig");
const category = @import("operations_category.zig");
const search = @import("operations_search.zig");

const LOAD_CHUNK: u32 = 512;
pub const MAX_QUERY_WORDS: usize = 32;
pub const MAX_ENTITY_WRITES: usize = 64;

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

pub fn putLinkEntities(db: *Directory, writes: []const EntityWrite, results: []EntityWriteResult) !void {
    std.debug.assert(writes.len == results.len);
    if (writes.len > MAX_ENTITY_WRITES) return error.TooManyEntityWrites;

    db.write_mutex.lockUncancelable(db.io);
    defer db.write_mutex.unlock(db.io);

    var accepted: [MAX_ENTITY_WRITES]changeset.LinkEntitiesEntry = undefined;
    var accepted_len: usize = 0;
    for (writes, results) |w, *result| {
        result.* = try checkEntityWrite(db, w);
        if (result.* != .ok) continue;
        accepted[accepted_len] = .{ .link_id = w.link_id, .facts = w.facts };
        accepted_len += 1;
    }
    if (accepted_len == 0) return;

    try db.commit(.{ .link_entities_put = .{ .entries = accepted[0..accepted_len] } });
}

fn checkEntityWrite(db: *Directory, w: EntityWrite) !EntityWriteResult {
    const link = (try link_mod.getLink(db, w.link_id)) orelse return .not_found;
    if (schema.linkTextFingerprint(link) != w.text_fingerprint) return .stale_text;
    if (entities.decode(w.facts) == null) return .invalid_facts;
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
    .answer = .{ .total = 0, .sites = 0, .hosts = 0, .domains = 0, .groups = &.{}, .page = &.{}, .next_after_id = 0 },
    .links = &.{},
};

pub fn loadFactsIndex(db: *Directory) !void {
    db.facts.beginLoad(db.io);
    try loadCategoryFacts(db);
    try loadLinkFacts(db);
    try loadEntityFacts(db);
    if (db.facts.loader_stop.load(.acquire)) return;
    db.facts.finishLoad(db.io, db.allocator);
}

fn loadCategoryFacts(db: *Directory) !void {
    const buf = try db.allocator.alloc(schema.Category, LOAD_CHUNK);
    defer db.allocator.free(buf);

    var next_id: u64 = 0;
    while (!db.facts.loader_stop.load(.acquire)) {
        try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
        const chunk = try readCategoryChunk(db, &next_id, buf);
        for (chunk) |cat| try db.facts.loadCategory(db.io, db.allocator, cat);
        if (chunk.len < buf.len) return;
    }
}

fn readCategoryChunk(db: *Directory, next_id: *u64, buf: []schema.Category) ![]schema.Category {
    const start_key = codec.encodeU64(next_id.*);
    var iter = try db.categories_by_id().rangeScan(&start_key, null);
    defer iter.deinit();

    var len: usize = 0;
    while (len < buf.len) {
        const entry = (try iter.next()) orelse break;
        next_id.* = codec.decodeU64(entry.key[0..8]) + 1;
        if (entry.value.len < @sizeOf(schema.Category)) continue;
        buf[len] = std.mem.bytesToValue(schema.Category, entry.value[0..@sizeOf(schema.Category)]);
        len += 1;
    }
    return buf[0..len];
}

fn loadLinkFacts(db: *Directory) !void {
    const buf = try db.allocator.alloc(schema.Link, LOAD_CHUNK);
    defer db.allocator.free(buf);

    var after_id: u64 = 0;
    while (!db.facts.loader_stop.load(.acquire)) {
        const page = try link_mod.listAllLinks(db, 0, LOAD_CHUNK, buf, null, after_id);
        for (page.items) |link| try db.facts.loadLink(db.io, db.allocator, link);
        if (page.next_after_id == 0) return;
        after_id = page.next_after_id;
    }
}

fn loadEntityFacts(db: *Directory) !void {
    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();

    var next_id: u64 = 0;
    while (!db.facts.loader_stop.load(.acquire)) {
        _ = arena.reset(.retain_capacity);
        const chunk = try readEntityChunk(db, &next_id, arena.allocator());
        for (chunk) |entry| try db.facts.loadEntities(db.io, db.allocator, entry.link_id, entry.facts);
        if (chunk.len < LOAD_CHUNK) return;
    }
}

fn readEntityChunk(db: *Directory, next_id: *u64, arena: std.mem.Allocator) ![]const changeset.LinkEntitiesEntry {
    const start_key = codec.encodeU64(next_id.*);
    var iter = try db.link_entities().rangeScan(&start_key, null);
    defer iter.deinit();

    var chunk: std.ArrayListUnmanaged(changeset.LinkEntitiesEntry) = .empty;
    while (chunk.items.len < LOAD_CHUNK) {
        const entry = (try iter.next()) orelse break;
        const link_id = codec.decodeU64(entry.key[0..8]);
        next_id.* = link_id + 1;
        try chunk.append(arena, .{ .link_id = link_id, .facts = try arena.dupe(u8, entry.value) });
    }
    return chunk.items;
}

pub fn queryLinks(db: *Directory, request: LinkQuery, arena: std.mem.Allocator) !LinkQueryResult {
    if (!db.facts.ready.load(.acquire)) return not_ready;

    var query = request.facts;
    var allowed: facts_index.IdSet = .empty;
    if (request.words.len > 0) {
        allowed = try linksWithWords(db, request.words, request.words_match, arena);
        query.allowed_ids = &allowed;
    }
    const answer = try db.facts.query(db.io, db.allocator, arena, query);

    var links = try std.ArrayListUnmanaged(QueriedLink).initCapacity(arena, answer.page.len);
    for (answer.page) |row| {
        const link = (try link_mod.getLink(db, row.link_id)) orelse continue;
        links.appendAssumeCapacity(.{ .link = link, .row = row });
    }
    return .{ .ready = true, .answer = answer, .links = links.items };
}

pub const MAX_NAME_MATCHES: usize = 32;

pub const NameMatch = struct {
    category_id: u64 = 0,
    names_someone: bool = false,
};

pub fn matchNames(db: *Directory, arena: std.mem.Allocator, phrases: []const []const u8, out: []NameMatch) !bool {
    if (!db.facts.ready.load(.acquire)) return false;
    for (phrases, out) |phrase, *match| {
        match.* = .{ .names_someone = db.facts.namesSomeone(db.io, phrase) };
        var largest: u64 = 0;
        for (try db.facts.categoriesNamed(db.io, arena, phrase)) |id| {
            const cat = (try category.getCategory(db, id)) orelse continue;
            if (match.category_id != 0 and cat.link_count_subtree <= largest) continue;
            match.category_id = id;
            largest = cat.link_count_subtree;
        }
    }
    return true;
}

fn linksWithWords(db: *Directory, words: []const u8, match: WordsMatch, arena: std.mem.Allocator) !facts_index.IdSet {
    const tokens = try distinctTokens(words, arena);
    if (tokens.len == 0) return error.NoSearchableWords;

    var allowed: facts_index.IdSet = .empty;
    for (tokens, 0..) |token, i| {
        const ids = try search.postingsForToken(db.links_index_tree(), token, arena, std.math.maxInt(usize));
        if (match == .any or i == 0) {
            for (ids) |id| try allowed.put(arena, id, {});
            continue;
        }
        var kept: facts_index.IdSet = .empty;
        for (ids) |id| {
            if (allowed.contains(id)) try kept.put(arena, id, {});
        }
        allowed = kept;
    }
    return allowed;
}

fn distinctTokens(words: []const u8, arena: std.mem.Allocator) ![]const []const u8 {
    var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var it = inverted.TokenIterator.init(words);
    while (it.next(&tok_buf)) |token| {
        if (tokens.items.len == MAX_QUERY_WORDS) break;
        if (containsToken(tokens.items, token)) continue;
        try tokens.append(arena, try arena.dupe(u8, token));
    }
    return tokens.items;
}

fn containsToken(tokens: []const []const u8, token: []const u8) bool {
    for (tokens) |existing| {
        if (std.mem.eql(u8, existing, token)) return true;
    }
    return false;
}

const testing = std.testing;

fn answerFor(db: *Directory, arena: std.mem.Allocator, request: LinkQuery) !facts_index.Answer {
    const result = try queryLinks(db, request, arena);
    try testing.expect(result.ready);
    return result.answer;
}

test "query_links is not ready until the loader has read the trees" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expect(!(try queryLinks(db, .{}, arena_state.allocator())).ready);

    try loadFactsIndex(db);
    try testing.expect((try queryLinks(db, .{}, arena_state.allocator())).ready);
}

test "facts follow every write through the apply path and a reload from the trees agrees" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();
    try loadFactsIndex(db);

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const society = try category.createCategory(db, top, "Society", "society", "");
    const pakistan = try category.createCategory(db, society, "Pakistan", "pakistan", "");
    const arts = try category.createCategory(db, top, "Arts", "arts", "");

    const moved = try link_mod.createLink(db, arts, "http://samvak.tripod.com/", "Samvak", "");
    const edited = try link_mod.createLink(db, society, "http://example.com/", "Example", "");
    const deleted = try link_mod.createLink(db, society, "http://gone.example.org/", "Gone", "");
    const pending = try link_mod.createLink(db, society, "http://www.uet.edu.pk/", "UET", "");
    try link_mod.moveLink(db, moved, pakistan);
    try link_mod.updateLink(db, edited, "http://www.storyofpakistan.com/", null, null);
    try link_mod.deleteLink(db, deleted);
    try link_mod.updateLinkStatus(db, pending, @intFromEnum(schema.LinkStatus.pending));

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const live = try answerFor(db, arena, .{ .facts = .{ .country = "PK".*, .group_by = .domain } });
    try testing.expectEqual(@as(u64, 1), live.total);
    try testing.expectEqual(moved, live.page[0].link_id);
    const live_society = try answerFor(db, arena, .{ .facts = .{ .category_id = society, .status = null, .group_by = .domain } });
    try testing.expectEqual(@as(u64, 3), live_society.total);
    try testing.expectEqualStrings("storyofpakistan.com", live_society.groups[0].label);

    db.facts.deinit(db.allocator);
    db.facts = .{};
    try loadFactsIndex(db);

    const reloaded = try answerFor(db, arena, .{ .facts = .{ .category_id = society, .status = null, .group_by = .domain } });
    try testing.expectEqual(live_society.total, reloaded.total);
    try testing.expectEqual(live_society.sites, reloaded.sites);
    for (live_society.groups, reloaded.groups) |a, b| {
        try testing.expectEqualStrings(a.label, b.label);
        try testing.expectEqual(a.links, b.links);
    }
}

test "a crash after acked writes replays the WAL into the same facts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const kept = blk: {
        const a = try Directory.openTestInstance(testing.allocator, &tmp);
        const top = try category.createCategory(a, 0, "Top", "top", "");
        const arts = try category.createCategory(a, top, "Arts", "arts", "");
        _ = try link_mod.createLink(a, arts, "http://members.tripod.com/~one/", "One", "");
        const two = try link_mod.createLink(a, arts, "http://members.tripod.com/~two/", "Two", "");
        const three = try link_mod.createLink(a, arts, "http://three.blogspot.com/", "Three", "");
        try link_mod.deleteLink(a, two);
        a.deinitCrashTestInstance();
        break :blk three;
    };

    const b = try Directory.openTestInstance(testing.allocator, &tmp);
    defer b.deinitTestInstance();
    try b.recover();
    try loadFactsIndex(b);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const answer = try answerFor(b, arena_state.allocator(), .{ .facts = .{ .hosted_only = true, .group_by = .domain } });
    try testing.expectEqual(@as(u64, 2), answer.total);
    try testing.expectEqual(@as(u64, 2), answer.sites);
    try testing.expectEqual(kept, answer.page[1].link_id);
}

test "a words filter keeps links matching any word, or only those matching all" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();
    try loadFactsIndex(db);

    const top = try category.createCategory(db, 0, "Top", "top", "");
    _ = try link_mod.createLink(db, top, "http://a.example/", "Islamic art", "");
    _ = try link_mod.createLink(db, top, "http://b.example/", "Muslim and Islamic history", "");
    _ = try link_mod.createLink(db, top, "http://c.example/", "Garden roses", "");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(u64, 2), (try answerFor(db, arena, .{ .words = "islamic muslim", .words_match = .any })).total);
    try testing.expectEqual(@as(u64, 1), (try answerFor(db, arena, .{ .words = "islamic muslim", .words_match = .all })).total);
    try testing.expectError(error.NoSearchableWords, queryLinks(db, .{ .words = "a" }, arena));
}

fn islamInPakistan(buf: []u8, person: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeByte(1);
    try w.writeInt(u16, @as(u16, 1) << @intFromEnum(entities.Religion.islam), .little);
    try w.writeByte(1);
    try w.writeAll("PK");
    try w.writeByte(1);
    try w.writeByte(@intCast(person.len));
    try w.writeAll(person);
    try w.writeByte(0);
    return buf[0..w.end];
}

fn entityWrite(db: *Directory, link_id: u64, facts: []const u8) !EntityWrite {
    const link = (try link_mod.getLink(db, link_id)).?;
    return .{ .link_id = link_id, .text_fingerprint = schema.linkTextFingerprint(link), .facts = facts };
}

test "put_link_entities stores valid facts and refuses unknown links, stale text and malformed facts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();
    try loadFactsIndex(db);

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const id = try link_mod.createLink(db, top, "http://www.storyofpakistan.com/", "Story of Pakistan: Deoband Movement", "");
    var buf: [128]u8 = undefined;
    const facts = try islamInPakistan(&buf, "Muhammad Qasim Nanautavi");

    var stale = try entityWrite(db, id, facts);
    stale.text_fingerprint +%= 1;
    const writes = [_]EntityWrite{
        try entityWrite(db, id, facts),
        .{ .link_id = 999_999, .text_fingerprint = 0, .facts = facts },
        stale,
        try entityWrite(db, id, "\x01\xff\xff"),
    };
    var results: [writes.len]EntityWriteResult = undefined;
    try putLinkEntities(db, &writes, &results);

    try testing.expectEqualSlices(EntityWriteResult, &.{ .ok, .not_found, .stale_text, .invalid_facts }, &results);
    var value_buf: [entities.MAX_ENCODED_LEN]u8 = undefined;
    const key = codec.encodeU64(id);
    try testing.expectEqualSlices(u8, facts, (try db.link_entities().search(&key, &value_buf)).?);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const answer = try answerFor(db, arena_state.allocator(), .{ .facts = .{ .entity_name = "muhammad qasim nanautavi" } });
    try testing.expectEqual(@as(u64, 1), answer.total);
    const too_many = [_]EntityWrite{writes[0]} ** (MAX_ENTITY_WRITES + 1);
    var too_many_results: [too_many.len]EntityWriteResult = undefined;
    try testing.expectError(error.TooManyEntityWrites, putLinkEntities(db, &too_many, &too_many_results));
}

test "entity facts survive a crash replay, a reload, and are dropped with the text they describe" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const ids = blk: {
        const a = try Directory.openTestInstance(testing.allocator, &tmp);
        const top = try category.createCategory(a, 0, "Top", "top", "");
        const kept = try link_mod.createLink(a, top, "http://www.farooqia.com/", "Jamia Farooqia", "");
        const retitled = try link_mod.createLink(a, top, "http://www.storyofpakistan.com/", "Story of Pakistan", "");
        var buf: [2][128]u8 = undefined;
        var results: [2]EntityWriteResult = undefined;
        try putLinkEntities(a, &.{
            try entityWrite(a, kept, try islamInPakistan(&buf[0], "Mufti Muhammad Shafi")),
            try entityWrite(a, retitled, try islamInPakistan(&buf[1], "Muhammad Ali Jinnah")),
        }, &results);
        try link_mod.updateLink(a, retitled, null, "Story of Pakistan, renamed", null);
        a.deinitCrashTestInstance();
        break :blk .{ kept, retitled };
    };

    const b = try Directory.openTestInstance(testing.allocator, &tmp);
    defer b.deinitTestInstance();
    try b.recover();
    try loadFactsIndex(b);

    try testing.expectEqual(@as(usize, 1), b.facts.entityCount(b.io));
    try testing.expect(b.facts.entities.get(ids[0]) != null);
    try testing.expect(b.facts.entities.get(ids[1]) == null);
    try testing.expectEqual(@as(u64, 1), b.link_entities().entryCount());
}

test "match_names picks the largest category with a name in any case or number and knows who links name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = try Directory.openTestInstance(testing.allocator, &tmp);
    defer db.deinitTestInstance();
    try loadFactsIndex(db);

    const top = try category.createCategory(db, 0, "Top", "top", "");
    const arts = try category.createCategory(db, top, "Arts", "arts", "");
    const society = try category.createCategory(db, top, "Society", "society", "");
    const art = try category.createCategory(db, society, "Art", "art", "");
    _ = try link_mod.createLink(db, arts, "http://one.example.com/", "One", "");
    _ = try link_mod.createLink(db, arts, "http://two.example.com/", "Two", "");
    const poem = try link_mod.createLink(db, art, "http://www.versedaily.org/mermaid.shtml", "Mermaid by Moniza Alvi", "");

    var buf: [128]u8 = undefined;
    var results: [1]EntityWriteResult = undefined;
    try putLinkEntities(db, &.{try entityWrite(db, poem, try islamInPakistan(&buf, "Moniza Alvi"))}, &results);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var matches: [4]NameMatch = undefined;
    try testing.expect(try matchNames(db, arena_state.allocator(), &.{ "art", "SOCIETY", "moniza alvi", "jazz" }, &matches));

    try testing.expectEqual(arts, matches[0].category_id);
    try testing.expectEqual(society, matches[1].category_id);
    try testing.expect(matches[2].names_someone);
    try testing.expectEqual(@as(u64, 0), matches[2].category_id);
    try testing.expectEqual(NameMatch{}, matches[3]);
}
