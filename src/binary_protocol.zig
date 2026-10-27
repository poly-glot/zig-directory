const std = @import("std");
const zigstore = @import("zigstore");
const protocol = zigstore.protocol;
const schema = @import("schema.zig");
const Directory = @import("directory.zig").Directory;
const operations = @import("operations/operations.zig");
const facts_index = @import("facts/facts_index.zig");
const countries = @import("facts/countries.zig");
const url_facts = @import("facts/url_facts.zig");
const entities = @import("facts/entities.zig");
const subtree = @import("subtree.zig");

const log = std.log.scoped(.binary);

pub const RESPONSE_HEADER_SIZE: usize = protocol.RESPONSE_HEADER_SIZE;

pub const Status = enum(u8) {
    ok = 0,
    not_found = 1,
    duplicate = 2,
    invalid = 3,
    err = 4,
    category_not_found = 5,
    has_children = 6,
    circular = 7,
};

pub const SubStatus = enum(u8) {
    none = 0,
    field_too_long = 1,
    invalid_slug = 2,
    buffer_too_small = 3,
    path_too_deep = 4,
    unsupported_order = 5,
    parent_not_found = 6,
    duplicate_url = 7,
    offset_too_large = 8,
    already_in_progress = 9,
    duplicate_slug = 10,
    embedding_model_mismatch = 11,
};

pub const StatusPair = struct {
    status: Status,
    sub_status: SubStatus,
};

pub fn mapErrorWithSubStatus(err: anyerror) StatusPair {
    return switch (err) {
        error.DuplicateUrl => .{ .status = .duplicate, .sub_status = .duplicate_url },
        error.DuplicateSlug => .{ .status = .duplicate, .sub_status = .duplicate_slug },
        error.CategoryNotFound => .{ .status = .category_not_found, .sub_status = .none },
        error.ParentNotFound => .{ .status = .category_not_found, .sub_status = .parent_not_found },
        error.LinkNotFound => .{ .status = .not_found, .sub_status = .none },
        error.CategoryHasChildren => .{ .status = .has_children, .sub_status = .none },
        error.CircularHierarchy => .{ .status = .circular, .sub_status = .none },
        error.FieldTooLong => .{ .status = .invalid, .sub_status = .field_too_long },
        error.PathTooDeep => .{ .status = .invalid, .sub_status = .path_too_deep },
        error.UnsupportedOrder => .{ .status = .invalid, .sub_status = .unsupported_order },
        error.OffsetTooLarge => .{ .status = .invalid, .sub_status = .offset_too_large },
        error.SnapshotInProgress => .{ .status = .err, .sub_status = .already_in_progress },
        error.EmbeddingModelMismatch => .{ .status = .invalid, .sub_status = .embedding_model_mismatch },
        error.InvalidEmbeddingModel, error.TooManyVectors, error.TooManyEntityWrites => .{ .status = .invalid, .sub_status = .none },
        else => .{ .status = .err, .sub_status = .none },
    };
}

pub const Op = enum(u8) {
    create_link = 1,
    create_category = 2,
    get_link = 3,
    get_category = 4,
    delete_link = 5,
    delete_category = 6,
    update_category = 7,
    move_category = 8,
    update_link = 9,
    list_root_categories = 10,
    browse_path = 11,
    list_children = 12,
    list_links = 13,
    search = 14,
    stats = 15,
    list_all_links = 16,
    list_subtree_links = 17,
    index_health = 18,
    run_verifier = 19,
    rebuild_index = 20,
    snapshot = 22,
    op_latency_stats = 23,
    bulk_import = 24,
    create_submission = 25,
    update_link_status = 26,
    list_links_by_submitter = 27,
    move_link = 28,
    get_categories_by_ids = 29,
    breadcrumbs_by_ids = 30,
    bulk_update_link_status = 34,
    bulk_delete_links = 35,
    counts_by_status = 36,
    put_link_vectors = 37,
    query_links = 38,
    put_link_entities = 39,
    match_names = 40,
    put_category_vectors = 41,
    ping = 255,
};

pub const GET_CATEGORIES_BY_IDS_MAX: u16 = 200;
pub const BREADCRUMBS_BY_IDS_MAX: u16 = 200;
const CRUMB_SIZE: usize = 8 + @sizeOf(@FieldType(schema.Category, "name")) + @sizeOf(@FieldType(schema.Category, "slug"));

pub const RESPONSE_RESERVE: usize = RESPONSE_HEADER_SIZE + @as(usize, GET_CATEGORIES_BY_IDS_MAX) * @sizeOf(schema.Category);

comptime {
    if (RESPONSE_RESERVE > zigstore.connection.RESPONSE_BUF_SIZE) @compileError("RESPONSE_RESERVE exceeds the connection response buffer");
}

pub const BULK_IMPORT_MAX_BYTES: usize = 60 * 1024;
pub const BULK_IMPORT_MAX_ITEMS: u32 = 50_000;
pub const BULK_IMPORT_CHUNK: u32 = 500;

const parsePayload = protocol.parsePayload;
const advancePayload = protocol.advancePayload;
const readOptionalString = protocol.readOptionalString;

fn writeResp(buf: []u8, op: u8, status: Status, count: u16, payload: []const u8) usize {
    return protocol.writeResp(buf, op, baseStatus(status), count, payload);
}

fn writeRowList(comptime T: type, resp: []u8, op_byte: u8, items: []const T) usize {
    return protocol.writeRowList(T, resp, op_byte, items);
}

fn writeOkHeader(resp: []u8, op_byte: u8, total_len: usize, count: u16) void {
    protocol.writeOkHeader(resp, op_byte, @intCast(total_len), count);
}

fn writeRawHeader(resp: []u8, op_byte: u8, total_len: usize, status: Status, sub: SubStatus, count: u16) void {
    protocol.writeRawHeader(resp, op_byte, @intCast(total_len), @intFromEnum(status), @intFromEnum(sub), count);
}

fn writeErrorResp(buf: []u8, op: u8, status: Status) usize {
    return writeErrorRespSub(buf, op, status, .none);
}

fn writeErrorRespSub(buf: []u8, op: u8, status: Status, sub: SubStatus) usize {
    return protocol.writeRawErrorResp(buf, op, @intFromEnum(status), @intFromEnum(sub));
}

fn baseStatus(status: Status) protocol.Status {
    return @enumFromInt(@intFromEnum(status));
}

fn writeMappedError(buf: []u8, op: u8, err: anyerror) usize {
    const pair = mapErrorWithSubStatus(err);
    return writeErrorRespSub(buf, op, pair.status, pair.sub_status);
}

const ITEM_RESULT_BYTES: usize = 10;
const OK_PAIR = StatusPair{ .status = .ok, .sub_status = .none };
const INVALID_PAIR = StatusPair{ .status = .invalid, .sub_status = .none };

fn writeItemResult(resp: []u8, off: usize, pair: StatusPair, id: u64) usize {
    resp[off] = @intFromEnum(pair.status);
    resp[off + 1] = @intFromEnum(pair.sub_status);
    std.mem.writeInt(u64, resp[off + 2 ..][0..8], id, .little);
    return off + ITEM_RESULT_BYTES;
}

fn appendRow(resp: []u8, off: usize, row: anytype) usize {
    const bytes = std.mem.asBytes(row);
    @memcpy(resp[off..][0..bytes.len], bytes);
    return off + bytes.len;
}

fn writeU64s(resp: []u8, start: usize, values: []const u64) usize {
    var off = start;
    for (values) |value| {
        std.mem.writeInt(u64, resp[off..][0..8], value, .little);
        off += 8;
    }
    return off;
}

fn writeU64Frame(resp: []u8, op_byte: u8, values: []const u64) usize {
    if (resp.len < RESPONSE_HEADER_SIZE + values.len * @sizeOf(u64)) return writeErrorResp(resp, op_byte, .err);
    const off = writeU64s(resp, RESPONSE_HEADER_SIZE, values);
    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

fn writeCountedCategoryRows(resp: []u8, start: usize, rows: []const schema.Category, tail_reserve: usize) usize {
    var off = start + 2;
    var written: u16 = 0;
    for (rows) |*row| {
        if (off + @sizeOf(schema.Category) + tail_reserve > resp.len) break;
        off = appendRow(resp, off, row);
        written += 1;
    }
    std.mem.writeInt(u16, resp[start..][0..2], written, .little);
    return off;
}

fn isKnownLinkStatus(code: u8) bool {
    return code <= @intFromEnum(schema.LinkStatus.rejected);
}

fn BatchCreateHandler(
    comptime fields: []const struct { []const u8, type },
    comptime op_code: u8,
    comptime createFn: anytype,
) type {
    return struct {
        fn handle(db: *Directory, resp: []u8, payload: []const u8, count: u16) usize {
            if (resp.len < RESPONSE_HEADER_SIZE) return 0;

            var off: usize = RESPONSE_HEADER_SIZE;
            var data = payload;
            var written: u16 = 0;

            for (0..count) |_| {
                if (off + ITEM_RESULT_BYTES > resp.len) break;

                const parsed = parsePayload(fields, data) orelse {
                    off = writeItemResult(resp, off, INVALID_PAIR, 0);
                    written += 1;
                    break;
                };
                const r = parsed.result;
                const created = @call(.auto, createFn, .{
                    db,
                    @field(r, fields[0][0]),
                    @field(r, fields[1][0]),
                    @field(r, fields[2][0]),
                    @field(r, fields[3][0]),
                });
                if (created) |id| {
                    off = writeItemResult(resp, off, OK_PAIR, id);
                    data = parsed.rest;
                } else |err| {
                    off = writeItemResult(resp, off, mapErrorWithSubStatus(err), 0);
                    data = advancePayload(fields, data) orelse &.{};
                }
                written += 1;
            }

            writeOkHeader(resp, op_code, off, written);
            return off;
        }
    };
}

const link_fields = &[_]struct { []const u8, type }{
    .{ "category_id", u64 },
    .{ "url", []const u8 },
    .{ "title", []const u8 },
    .{ "description", []const u8 },
};

const category_fields = &[_]struct { []const u8, type }{
    .{ "parent_id", u64 },
    .{ "name", []const u8 },
    .{ "slug", []const u8 },
    .{ "description", []const u8 },
};

const CreateLinks = BatchCreateHandler(link_fields, @intFromEnum(Op.create_link), operations.createLink);
const CreateCategories = BatchCreateHandler(category_fields, @intFromEnum(Op.create_category), operations.createCategory);

pub fn dispatch(db: *Directory, op_byte: u8, payload: []const u8, count: u16, resp: []u8) usize {
    const op: Op = std.enums.fromInt(Op, op_byte) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    return switch (op) {
        .ping => writeResp(resp, op_byte, .ok, 0, &.{}),
        .create_link => CreateLinks.handle(db, resp, payload, count),
        .create_category => CreateCategories.handle(db, resp, payload, count),
        .get_link => handleGet(schema.Link, db, resp, op_byte, payload, operations.getLink),
        .get_category => handleGet(schema.Category, db, resp, op_byte, payload, operations.getCategory),
        .get_categories_by_ids => handleGetCategoriesByIds(db, resp, op_byte, payload),
        .breadcrumbs_by_ids => handleBreadcrumbsByIds(db, resp, op_byte, payload),
        .delete_link => handleDelete(db, resp, op_byte, payload, operations.deleteLink),
        .delete_category => handleDelete(db, resp, op_byte, payload, operations.deleteCategory),
        .update_category => handleBitmaskUpdate(operations.updateCategory, db, resp, op_byte, payload),
        .move_category => handleMove(db, resp, op_byte, payload, operations.moveCategory),
        .move_link => handleMove(db, resp, op_byte, payload, operations.moveLink),
        .update_link => handleBitmaskUpdate(operations.updateLink, db, resp, op_byte, payload),
        .list_root_categories => handleListChildren(.none, db, resp, op_byte, payload),
        .list_children => handleListChildren(.leading_id, db, resp, op_byte, payload),
        .list_links => handleListLinks(.leading_id, operations.listLinks, db, resp, op_byte, payload),
        .list_all_links => handleListLinks(.none, operations.listAllLinks, db, resp, op_byte, payload),
        .list_subtree_links => handleListSubtreeLinks(db, resp, op_byte, payload),
        .index_health => handleIndexHealth(db, resp, op_byte),
        .run_verifier => handleRunVerifier(db, resp, op_byte),
        .rebuild_index => handleRebuildIndex(db, resp, op_byte),
        .snapshot => handleSnapshot(db, resp, op_byte),
        .op_latency_stats => handleOpLatencyStats(db, resp, op_byte),
        .bulk_import => handleBulkImport(db, resp, op_byte, payload, count),
        .create_submission => handleCreateSubmission(db, resp, op_byte, payload),
        .update_link_status => handleUpdateLinkStatus(db, resp, op_byte, payload),
        .list_links_by_submitter => handleListLinks(.leading_id, operations.listLinksBySubmitter, db, resp, op_byte, payload),
        .browse_path => handleBrowsePath(db, resp, op_byte, payload),
        .search => handleSearch(db, resp, op_byte, payload),
        .stats => handleStats(db, resp, op_byte),
        .bulk_update_link_status => handleBulkUpdateLinkStatus(db, resp, op_byte, payload),
        .bulk_delete_links => handleBulkDeleteLinks(db, resp, op_byte, payload),
        .counts_by_status => handleCountsByStatus(db, resp, op_byte),
        .put_link_vectors => handlePutLinkVectors(db, resp, op_byte, payload),
        .query_links => handleQueryLinks(db, resp, op_byte, payload),
        .put_link_entities => handlePutLinkEntities(db, resp, op_byte, payload),
        .match_names => handleMatchNames(db, resp, op_byte, payload),
        .put_category_vectors => handlePutCategoryVectors(db, resp, op_byte, payload),
    };
}

const MAX_SUBTREE_OFFSET: u32 = 5000;
const MAX_SUBTREE_LIMIT: u32 = 100;
const DEFAULT_SUBTREE_LIMIT: u32 = 50;
const MAX_SUBTREE_FETCH: u32 = 10_000;
const SUBTREE_OVERPROVISION_FACTOR: u32 = 2;
const MAX_ANCESTOR_DEPTH: usize = 64;
const BROWSE_CHILDREN_LIMIT: u32 = 100;
const SEARCH_MAX_RESULTS: u32 = 50;

pub const ListSubtreeLinksRequest = struct {
    cat_id: u64,
    order_code: u8,
    offset: u32,
    limit: u32,

    pub fn parse(payload: []const u8) ListSubtreeLinksRequest {
        return .{
            .cat_id = std.mem.readInt(u64, payload[0..8], .little),
            .order_code = payload[8],
            .offset = std.mem.readInt(u32, payload[9..13], .little),
            .limit = std.mem.readInt(u32, payload[13..17], .little),
        };
    }

    pub fn validate(self: ListSubtreeLinksRequest) !void {
        if (self.order_code != 0) return error.UnsupportedOrder;
        if (self.offset > MAX_SUBTREE_OFFSET) return error.OffsetTooLarge;
    }

    pub fn effectiveLimit(self: ListSubtreeLinksRequest) u32 {
        if (self.limit == 0) return DEFAULT_SUBTREE_LIMIT;
        return @min(self.limit, MAX_SUBTREE_LIMIT);
    }
};

fn handleGet(
    comptime T: type,
    db: *Directory,
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
    comptime getter: fn (*Directory, u64) anyerror!?T,
) usize {
    if (payload.len < 8) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const item = getter(db, id) catch |err| return writeMappedError(resp, op_byte, err);
    if (item) |v| {
        const bytes = std.mem.asBytes(&v);
        return writeResp(resp, op_byte, .ok, 1, bytes);
    }
    return writeErrorResp(resp, op_byte, .not_found);
}

fn handleGetCategoriesByIds(
    db: *Directory,
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 2) return writeErrorResp(resp, op_byte, .invalid);
    const want: u16 = std.mem.readInt(u16, payload[0..2], .little);
    if (want > GET_CATEGORIES_BY_IDS_MAX) {
        return writeErrorResp(resp, op_byte, .invalid);
    }
    const expected_payload_len: usize = 2 + @as(usize, want) * 8;
    if (payload.len < expected_payload_len) {
        return writeErrorResp(resp, op_byte, .invalid);
    }

    const cat_size = @sizeOf(schema.Category);
    if (resp.len < RESPONSE_HEADER_SIZE + @as(usize, want) * cat_size) {
        return writeErrorResp(resp, op_byte, .err);
    }

    var off: usize = RESPONSE_HEADER_SIZE;
    var found: u16 = 0;
    var i: usize = 0;
    while (i < want) : (i += 1) {
        const id_off: usize = 2 + i * 8;
        const id = std.mem.readInt(u64, payload[id_off..][0..8], .little);
        const maybe_cat = operations.getCategory(db, id) catch null;
        if (maybe_cat) |cat| {
            off = appendRow(resp, off, &cat);
            found += 1;
        }
    }

    writeOkHeader(resp, op_byte, off, found);
    return off;
}

fn writeCrumb(resp: []u8, off: usize, cat: schema.Category) usize {
    var o = off;
    std.mem.writeInt(u64, resp[o..][0..8], cat.id, .little);
    o += 8;
    const name_bytes = std.mem.asBytes(&cat.name);
    @memcpy(resp[o..][0..name_bytes.len], name_bytes);
    o += name_bytes.len;
    const slug_bytes = std.mem.asBytes(&cat.slug);
    @memcpy(resp[o..][0..slug_bytes.len], slug_bytes);
    o += slug_bytes.len;
    return o;
}

fn handleBreadcrumbsByIds(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 2) return writeErrorResp(resp, op_byte, .invalid);
    const want: u16 = std.mem.readInt(u16, payload[0..2], .little);
    if (want > BREADCRUMBS_BY_IDS_MAX) return writeErrorResp(resp, op_byte, .invalid);
    if (payload.len < 2 + @as(usize, want) * 8) return writeErrorResp(resp, op_byte, .invalid);
    if (resp.len < RESPONSE_HEADER_SIZE) return writeErrorResp(resp, op_byte, .err);

    var off: usize = RESPONSE_HEADER_SIZE;
    var groups: u16 = 0;
    var i: usize = 0;
    while (i < want) : (i += 1) {
        const id = std.mem.readInt(u64, payload[2 + i * 8 ..][0..8], .little);

        var anc_buf: [64]schema.Category = undefined;
        const ancestors = operations.walkAncestors(db, id, &anc_buf) catch anc_buf[0..0];
        const self_cat = operations.getCategory(db, id) catch null;
        const crumbs: usize = if (self_cat != null) ancestors.len + 1 else 0;
        if (off + 2 + crumbs * CRUMB_SIZE > resp.len) break;

        std.mem.writeInt(u16, resp[off..][0..2], @intCast(crumbs), .little);
        off += 2;
        if (self_cat) |sc| {
            for (ancestors) |a| off = writeCrumb(resp, off, a);
            off = writeCrumb(resp, off, sc);
        }
        groups += 1;
    }

    writeOkHeader(resp, op_byte, off, groups);
    return off;
}

fn handleDelete(
    db: *Directory,
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
    comptime deleteFn: fn (*Directory, u64) anyerror!void,
) usize {
    if (payload.len < 8) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    deleteFn(db, id) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeResp(resp, op_byte, .ok, 0, &.{});
}

fn handleBitmaskUpdate(
    comptime updateFn: fn (*Directory, u64, ?[]const u8, ?[]const u8, ?[]const u8) anyerror!void,
    db: *Directory,
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 9) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const mask = payload[8];
    var off: usize = 9;

    const a = readOptionalString(payload, &off, mask, 0x01) orelse
        return writeErrorResp(resp, op_byte, .invalid);
    const b = readOptionalString(payload, &off, mask, 0x02) orelse
        return writeErrorResp(resp, op_byte, .invalid);
    const c = readOptionalString(payload, &off, mask, 0x04) orelse
        return writeErrorResp(resp, op_byte, .invalid);

    updateFn(db, id, a, b, c) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeResp(resp, op_byte, .ok, 0, &.{});
}

fn handleMove(
    db: *Directory,
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
    comptime moveFn: fn (*Directory, u64, u64) anyerror!void,
) usize {
    if (payload.len < 16) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const destination = std.mem.readInt(u64, payload[8..16], .little);
    moveFn(db, id, destination) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeResp(resp, op_byte, .ok, 0, &.{});
}

const PageKey = enum { none, leading_id };

const ListWindow = struct {
    key: u64,
    offset: u32,
    limit: u32,
    fixed_len: usize,
};

fn parseListWindow(comptime page_key: PageKey, payload: []const u8) ?ListWindow {
    const key_len: usize = if (page_key == .leading_id) 8 else 0;
    if (payload.len < key_len + 8) return null;
    return .{
        .key = if (page_key == .leading_id) std.mem.readInt(u64, payload[0..8], .little) else 0,
        .offset = std.mem.readInt(u32, payload[key_len..][0..4], .little),
        .limit = std.mem.readInt(u32, payload[key_len + 4 ..][0..4], .little),
        .fixed_len = key_len + 8,
    };
}

fn handleListChildren(comptime page_key: PageKey, db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    const window = parseListWindow(page_key, payload) orelse return writeErrorResp(resp, op_byte, .invalid);
    var buf: [defaultListBufLen(schema.Category)]schema.Category = undefined;
    const max = @min(window.limit, @as(u32, @intCast(buf.len)));
    const items = operations.listChildren(db, window.key, window.offset, max, &buf) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeRowList(schema.Category, resp, op_byte, items);
}

fn handleListLinks(
    comptime page_key: PageKey,
    comptime listFn: anytype,
    db: *Directory,
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    const window = parseListWindow(page_key, payload) orelse return writeErrorResp(resp, op_byte, .invalid);
    const extras = readOptionalListExtras(payload, window.fixed_len) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    var buf: [defaultListBufLen(schema.Link)]schema.Link = undefined;
    const max = @min(window.limit, @as(u32, @intCast(buf.len)));
    const listed = if (page_key == .leading_id)
        listFn(db, window.key, window.offset, max, &buf, extras.status, extras.after_id)
    else
        listFn(db, window.offset, max, &buf, extras.status, extras.after_id);
    const page = listed catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeLinkPage(resp, op_byte, page);
}

fn handleBrowsePath(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 2) return writeErrorResp(resp, op_byte, .invalid);
    const path_len: usize = std.mem.readInt(u16, payload[0..2], .little);
    if (2 + path_len > payload.len) return writeErrorResp(resp, op_byte, .invalid);
    const path = payload[2..][0..path_len];

    const cat_id = (operations.resolveSlugPath(db, path) catch null) orelse
        return writeErrorResp(resp, op_byte, .not_found);
    const cat = (operations.getCategory(db, cat_id) catch null) orelse
        return writeErrorResp(resp, op_byte, .not_found);

    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent()) catch |err| log.warn("drain skipped before read: {}", .{err});
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category()) catch |err| log.warn("drain skipped before read: {}", .{err});

    const MIN_FRAME = RESPONSE_HEADER_SIZE + @sizeOf(schema.Category) + 2 + 2 + 8;
    if (resp.len < MIN_FRAME) return writeErrorResp(resp, op_byte, .err);

    var anc_buf: [MAX_ANCESTOR_DEPTH]schema.Category = undefined;
    const ancestors = operations.walkAncestors(db, cat_id, &anc_buf) catch
        return writeErrorResp(resp, op_byte, .err);
    var children_buf: [BROWSE_CHILDREN_LIMIT]schema.Category = undefined;
    const children = operations.listChildren(db, cat_id, 0, BROWSE_CHILDREN_LIMIT, &children_buf) catch
        return writeErrorResp(resp, op_byte, .err);

    var off = appendRow(resp, RESPONSE_HEADER_SIZE, &cat);
    off = writeCountedCategoryRows(resp, off, ancestors, 2 + 8);
    off = writeCountedCategoryRows(resp, off, children, 8);
    off = writeU64s(resp, off, &.{subtreeLinkTotal(db, cat_id)});

    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

fn subtreeLinkTotal(db: *Directory, cat_id: u64) u64 {
    if (db.subtree_cache.getLinkCount(cat_id)) |hit| return hit;

    const descendants = subtree.collectDescendantsCached(db.cat_by_parent(), cat_id, &db.subtree_cache, db.allocator) catch |err| {
        log.warn("browse_path: descendants of {d} unavailable, reporting 0 subtree links: {}", .{ cat_id, err });
        return 0;
    };
    defer db.allocator.free(descendants);

    const total = subtree.countSubtreeLinks(db.link_by_category(), descendants, db.allocator) catch |err| {
        log.warn("browse_path: subtree link count of {d} unavailable, reporting 0: {}", .{ cat_id, err });
        return 0;
    };
    db.subtree_cache.putLinkCount(cat_id, total) catch |err| {
        log.warn("browse_path: subtree link count of {d} not cached: {}", .{ cat_id, err });
    };
    return total;
}

const NO_STATUS_FILTER: u8 = 0xFF;
const OptionalListExtras = struct { status: ?u8, after_id: u64 };

fn readOptionalListExtras(payload: []const u8, fixed_len: usize) ?OptionalListExtras {
    if (payload.len < fixed_len) return null;
    const tail = payload[fixed_len..];
    return switch (tail.len) {
        0 => OptionalListExtras{ .status = null, .after_id = 0 },
        1 => blk: {
            const s = tail[0];
            if (!isKnownLinkStatus(s)) break :blk null;
            break :blk OptionalListExtras{ .status = s, .after_id = 0 };
        },
        9 => blk: {
            const s = tail[0];
            const status: ?u8 = if (s == NO_STATUS_FILTER) null else if (!isKnownLinkStatus(s)) break :blk null else s;
            const a = std.mem.readInt(u64, tail[1..9], .little);
            break :blk OptionalListExtras{ .status = status, .after_id = a };
        },
        else => null,
    };
}

fn writeLinkPage(resp: []u8, op_byte: u8, page: operations.LinkPage) usize {
    var off = writeRowList(schema.Link, resp, op_byte, page.items);
    const written = std.mem.readInt(u16, resp[8..10], .little);
    if (off + 8 > resp.len) return writeErrorResp(resp, op_byte, .err);
    std.mem.writeInt(u64, resp[off..][0..8], page.next_after_id, .little);
    off += 8;
    writeOkHeader(resp, op_byte, off, written);
    return off;
}

const SUBTREE_ROWS_OFF: usize = RESPONSE_HEADER_SIZE + 4;
const SUBTREE_TRAILER_BYTES: usize = 8 + 8;
const SUBTREE_MIN_FRAME: usize = SUBTREE_ROWS_OFF + SUBTREE_TRAILER_BYTES;

const SubtreePageSpec = struct {
    limit: u32,
    offset: u32,
    status_filter: ?u8,
    after_id: u64,

    fn cursorMode(self: SubtreePageSpec) bool {
        return self.after_id > 0;
    }

    fn needsFullScan(self: SubtreePageSpec) bool {
        return self.cursorMode() or self.status_filter != null;
    }
};

const SubtreePageResult = struct { off: usize, written: u32, total: u64, next_after_id: u64 };

fn writeSubtreeLinkRows(
    db: *Directory,
    resp: []u8,
    link_ids: []const u64,
    unfiltered_total: u64,
    spec: SubtreePageSpec,
) SubtreePageResult {
    const cursor_mode = spec.cursorMode();
    var off = SUBTREE_ROWS_OFF;
    var written: u32 = 0;
    var total: u64 = if (spec.status_filter == null) unfiltered_total else 0;
    var skipped: u32 = 0;
    var passed_cursor = !cursor_mode;
    var next_after_id: u64 = 0;
    var last_written_id: u64 = 0;

    for (link_ids) |lid| {
        const link = (operations.getLink(db, lid) catch null) orelse continue;
        if (spec.status_filter) |s| {
            if (link.status != s) continue;
            total += 1;
        }
        if (!passed_cursor) {
            if (link.id == spec.after_id) passed_cursor = true;
            continue;
        }
        if (!cursor_mode and spec.status_filter != null and skipped < spec.offset) {
            skipped += 1;
            continue;
        }
        if (written >= spec.limit) {
            next_after_id = last_written_id;
            if (spec.status_filter == null) break else continue;
        }
        if (off + @sizeOf(schema.Link) + SUBTREE_TRAILER_BYTES > resp.len) {
            if (spec.status_filter == null) break else continue;
        }
        off = appendRow(resp, off, &link);
        last_written_id = link.id;
        written += 1;
    }

    return .{ .off = off, .written = written, .total = total, .next_after_id = next_after_id };
}

fn fetchSubtreeLinkIds(db: *Directory, cat_id: u64, descendants: []const u64, spec: SubtreePageSpec) !subtree.SubtreeLinkPage {
    if (spec.needsFullScan()) {
        return subtree.listSubtreeLinkIdsScan(db.link_by_category(), descendants, 0, MAX_SUBTREE_FETCH, db.allocator);
    }
    const page_limit = spec.limit *| SUBTREE_OVERPROVISION_FACTOR;
    const link_ids = try subtree.listSubtreeLinkIds(db.link_by_category(), descendants, spec.offset, page_limit, db.allocator);
    const category = try operations.getCategory(db, cat_id);
    return .{ .link_ids = link_ids, .total = if (category) |c| c.link_count_subtree else 0 };
}

fn handleListSubtreeLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 17) return writeErrorResp(resp, op_byte, .invalid);
    const req = ListSubtreeLinksRequest.parse(payload);
    req.validate() catch |err| return writeMappedError(resp, op_byte, err);
    const extras = readOptionalListExtras(payload, 17) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    const spec = SubtreePageSpec{
        .limit = req.effectiveLimit(),
        .offset = req.offset,
        .status_filter = extras.status,
        .after_id = extras.after_id,
    };

    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent()) catch |err| log.warn("drain skipped before read: {}", .{err});
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category()) catch |err| log.warn("drain skipped before read: {}", .{err});
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id()) catch |err| log.warn("drain skipped before read: {}", .{err});

    const descendants = subtree.collectDescendantsCached(
        db.cat_by_parent(),
        req.cat_id,
        &db.subtree_cache,
        db.allocator,
    ) catch |err| return writeMappedError(resp, op_byte, err);
    defer db.allocator.free(descendants);

    if (resp.len < SUBTREE_MIN_FRAME) return writeErrorResp(resp, op_byte, .err);

    const slice = fetchSubtreeLinkIds(db, req.cat_id, descendants, spec) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    defer db.allocator.free(slice.link_ids);

    const page = writeSubtreeLinkRows(db, resp, slice.link_ids, slice.total, spec);
    std.mem.writeInt(u32, resp[RESPONSE_HEADER_SIZE..][0..4], page.written, .little);
    if (page.off + SUBTREE_TRAILER_BYTES > resp.len) return writeErrorResp(resp, op_byte, .err);
    const off = writeU64s(resp, page.off, &.{ page.total, page.next_after_id });

    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

const SearchScope = enum(u8) { both = 0, links_only = 1, categories_only = 2 };
const SearchMode = enum(u8) { all_terms = 0, ranked = 1, hybrid = 2 };
const EMBEDDING_BYTES: usize = schema.EMBEDDING_DIMS * 4;
const HYBRID_QUERY_BYTES: usize = 8 + EMBEDDING_BYTES;
const VECTOR_WRITE_BYTES: usize = 8 + 8 + EMBEDDING_BYTES;
const CATEGORY_VECTOR_WRITE_BYTES: usize = 8 + EMBEDDING_BYTES;

const inverted = @import("zigstore").inverted_index;
const vector_index = @import("vector_index.zig");

const MatchField = enum(u8) { title = 0, url = 1, description = 2, semantic = 3 };

fn linkMatchField(link: schema.Link, query: []const u8) MatchField {
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var it = inverted.TokenIterator.init(query);
    while (it.next(&tok_buf)) |tok| {
        if (std.ascii.findIgnoreCase(link.title.slice(), tok) != null) return .title;
        if (std.ascii.findIgnoreCase(link.url.slice(), tok) != null) return .url;
        if (std.ascii.findIgnoreCase(link.description.slice(), tok) != null) return .description;
    }
    return .semantic;
}

fn searchCategoriesInMode(db: *Directory, mode: SearchMode, query: []const u8, query_vector: []const u8, max: u32, buf: []schema.Category) ![]schema.Category {
    return switch (mode) {
        .all_terms => operations.searchCategories(db, query, max, buf),
        .ranked => operations.searchCategoriesRanked(db, query, max, buf),
        .hybrid => {
            const model = std.mem.readInt(u64, query_vector[0..8], .little);
            var embedding: vector_index.Embedding = undefined;
            vector_index.readEmbedding(query_vector[8..][0..EMBEDDING_BYTES], &embedding);
            return operations.searchCategoriesHybrid(db, query, model, &embedding, max, buf);
        },
    };
}

fn searchLinksInMode(db: *Directory, mode: SearchMode, query: []const u8, query_vector: []const u8, max: u32, buf: []schema.Link, site_rows: ?[]operations.RowSite) !operations.HybridLinks {
    return switch (mode) {
        .all_terms => .{ .links = try operations.searchLinks(db, query, max, buf), .vector_used = false },
        .ranked => .{ .links = try operations.searchLinksRanked(db, query, max, buf, site_rows), .vector_used = false },
        .hybrid => {
            const model = std.mem.readInt(u64, query_vector[0..8], .little);
            var embedding: vector_index.Embedding = undefined;
            vector_index.readEmbedding(query_vector[8..][0..EMBEDDING_BYTES], &embedding);
            return operations.searchLinksHybrid(db, query, model, &embedding, max, buf, site_rows);
        },
    };
}

fn writeRowSite(resp: []u8, start: usize, row: *const operations.RowSite) usize {
    var off = start;
    std.mem.writeInt(u16, resp[off..][0..2], row.key_len, .little);
    off += 2;
    @memcpy(resp[off..][0..row.key_len], row.key());
    off += row.key_len;
    std.mem.writeInt(u16, resp[off..][0..2], row.more, .little);
    return off + 2;
}

fn handleSearch(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 6) return writeErrorResp(resp, op_byte, .invalid);
    const query_len: usize = std.mem.readInt(u16, payload[0..2], .little);
    if (query_len < 2) return writeErrorResp(resp, op_byte, .invalid);
    if (2 + query_len + 4 > payload.len) return writeErrorResp(resp, op_byte, .invalid);
    const query = payload[2..][0..query_len];
    const limit = std.mem.readInt(u32, payload[2 + query_len ..][0..4], .little);

    const trailing = payload[2 + query_len + 4 ..];
    const options = trailing[0..@min(trailing.len, 2)];
    const scope: SearchScope = if (options.len >= 1)
        std.enums.fromInt(SearchScope, options[0]) orelse return writeErrorResp(resp, op_byte, .invalid)
    else
        .both;
    const mode: SearchMode = if (options.len == 2)
        std.enums.fromInt(SearchMode, options[1]) orelse return writeErrorResp(resp, op_byte, .invalid)
    else
        .all_terms;
    const expected_vector_len: usize = if (mode == .hybrid) HYBRID_QUERY_BYTES else 0;
    const after_options = trailing[options.len..];
    if (after_options.len != expected_vector_len and after_options.len != expected_vector_len + 1) return writeErrorResp(resp, op_byte, .invalid);
    const query_vector = after_options[0..expected_vector_len];
    const cap_byte: u8 = if (after_options.len > expected_vector_len) after_options[expected_vector_len] else 0;
    if (cap_byte > 1 or (cap_byte == 1 and mode == .all_terms)) return writeErrorResp(resp, op_byte, .invalid);
    const cap_per_site = cap_byte == 1;

    if (resp.len < RESPONSE_HEADER_SIZE + 4) return writeErrorResp(resp, op_byte, .err);

    const max = @min(limit, SEARCH_MAX_RESULTS);

    var cat_buf: [SEARCH_MAX_RESULTS]schema.Category = undefined;
    const cats = if (scope == .links_only)
        cat_buf[0..0]
    else
        searchCategoriesInMode(db, mode, query, query_vector, max, &cat_buf) catch &[0]schema.Category{};
    var off = writeCountedCategoryRows(resp, RESPONSE_HEADER_SIZE, cats, 2);

    var link_buf: [SEARCH_MAX_RESULTS]schema.Link = undefined;
    var row_sites: [SEARCH_MAX_RESULTS]operations.RowSite = undefined;
    const site_rows: ?[]operations.RowSite = if (cap_per_site) &row_sites else null;
    const found: operations.HybridLinks = if (scope == .categories_only)
        .{ .links = link_buf[0..0], .vector_used = false }
    else
        searchLinksInMode(db, mode, query, query_vector, max, &link_buf, site_rows) catch .{ .links = link_buf[0..0], .vector_used = false };
    const links = found.links;
    const link_count_off = off;
    off += 2;
    var links_written: u16 = 0;
    for (links, row_sites[0..links.len]) |*link, *row| {
        const site_bytes: usize = if (cap_per_site) 4 + @as(usize, row.key_len) else 0;
        if (off + @sizeOf(schema.Link) + 1 + site_bytes > resp.len) break;
        off = appendRow(resp, off, link);
        resp[off] = @intFromEnum(linkMatchField(link.*, query));
        off += 1;
        if (cap_per_site) off = writeRowSite(resp, off, row);
        links_written += 1;
    }
    std.mem.writeInt(u16, resp[link_count_off..][0..2], links_written, .little);

    if (mode == .hybrid) {
        if (off + 1 > resp.len) return writeErrorResp(resp, op_byte, .err);
        resp[off] = @intFromBool(found.vector_used);
        off += 1;
    }

    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

pub const QUERY_LINKS_MAX_ROWS: u8 = 50;
const QUERY_LINKS_MAX_WORDS_BYTES: usize = 256;
const ANY_STATUS: u8 = 0xFF;

const QueryLinksOptions = packed struct(u64) {
    via: u4 = 0,
    hosted_only: bool = false,
    all_words: bool = false,
    group_by: u4 = 0,
    status: u8 = ANY_STATUS,
    group_limit: u8 = 0,
    limit: u8 = 0,
    religions: u16 = 0,
    subdomain_only: bool = false,
    _unused: u13 = 0,
};

const query_links_fields = &[_]struct { []const u8, type }{
    .{ "category_id", u64 },
    .{ "domain", []const u8 },
    .{ "country", []const u8 },
    .{ "options", u64 },
    .{ "words", []const u8 },
    .{ "entity", []const u8 },
    .{ "after_id", u64 },
};

fn handleQueryLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    const parsed = parsePayload(query_links_fields, payload) orelse return writeErrorResp(resp, op_byte, .invalid);
    var domain_buf: [url_facts.MAX_HOST_LEN]u8 = undefined;
    const request = linkQueryFrom(parsed.result, &domain_buf) orelse return writeErrorResp(resp, op_byte, .invalid);

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    const result = operations.queryLinks(db, request, arena.allocator()) catch |err| switch (err) {
        error.NoSearchableWords => return writeErrorResp(resp, op_byte, .invalid),
        else => return writeMappedError(resp, op_byte, err),
    };

    var body: std.Io.Writer = .fixed(resp[RESPONSE_HEADER_SIZE..]);
    writeQueryLinksBody(&body, result) catch return writeErrorRespSub(resp, op_byte, .invalid, .buffer_too_small);
    const len = RESPONSE_HEADER_SIZE + body.end;
    writeOkHeader(resp, op_byte, len, @intCast(result.links.len));
    return len;
}

fn linkQueryFrom(p: anytype, domain_buf: *[url_facts.MAX_HOST_LEN]u8) ?operations.LinkQuery {
    const options: QueryLinksOptions = @bitCast(p.options);
    const domain = std.mem.trimStart(u8, p.domain, ".");
    if (domain.len > domain_buf.len or p.words.len > QUERY_LINKS_MAX_WORDS_BYTES) return null;
    if (options.group_limit > QUERY_LINKS_MAX_ROWS or options.limit > QUERY_LINKS_MAX_ROWS) return null;
    if (options.status != ANY_STATUS and options.status > @intFromEnum(schema.LinkStatus.rejected)) return null;
    if (options.via > facts_index.Via.all or options.religions & ~entities.RELIGION_MASK != 0) return null;
    if (p.entity.len > entities.MAX_NAME_LEN) return null;

    const group_by = std.enums.fromInt(facts_index.GroupBy, options.group_by) orelse return null;
    const country: ?countries.Code = switch (p.country.len) {
        0 => null,
        2 => if (countries.isAssigned(p.country[0..2].*)) p.country[0..2].* else return null,
        else => return null,
    };

    return .{
        .facts = .{
            .category_id = p.category_id,
            .domain_suffix = std.ascii.lowerString(domain_buf, domain),
            .country = country,
            .via = if (options.via == 0) facts_index.Via.all else options.via,
            .religions = options.religions,
            .entity_name = p.entity,
            .hosted_only = options.hosted_only,
            .subdomain_only = options.subdomain_only,
            .status = if (options.status == ANY_STATUS) null else options.status,
            .group_by = group_by,
            .group_limit = options.group_limit,
            .page_limit = options.limit,
            .after_id = p.after_id,
        },
        .words = p.words,
        .words_match = if (options.all_words) .all else .any,
    };
}

fn writeQueryLinksBody(w: *std.Io.Writer, result: operations.LinkQueryResult) std.Io.Writer.Error!void {
    const answer = result.answer;
    try w.writeByte(@intFromBool(result.ready));
    for ([_]u64{ answer.total, answer.sites, answer.hosts, answer.domains }) |n| try w.writeInt(u64, n, .little);

    try w.writeInt(u16, @intCast(answer.groups.len), .little);
    for (answer.groups) |group| {
        try w.writeInt(u16, @intCast(group.label.len), .little);
        try w.writeAll(group.label);
        try w.writeInt(u64, group.category_id, .little);
        try w.writeInt(u64, group.links, .little);
        try w.writeInt(u64, group.sites, .little);
    }

    try w.writeInt(u16, @intCast(result.links.len), .little);
    for (result.links) |item| {
        try w.writeAll(std.mem.asBytes(&item.link));
        try w.writeInt(u16, @intCast(item.row.site.len), .little);
        try w.writeAll(item.row.site);
        try w.writeAll(&item.row.cctld);
        try w.writeAll(&item.row.category_country);
        try w.writeInt(u16, item.row.religions, .little);
        try w.writeByte(@intCast(item.row.entity_countries.len));
        for (item.row.entity_countries) |code| try w.writeAll(&code);
    }
    try w.writeInt(u64, answer.next_after_id, .little);
}

fn handleMatchNames(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 2) return writeErrorResp(resp, op_byte, .invalid);
    const count = std.mem.readInt(u16, payload[0..2], .little);
    if (count == 0 or count > operations.MAX_NAME_MATCHES) return writeErrorResp(resp, op_byte, .invalid);

    var phrases: [operations.MAX_NAME_MATCHES][]const u8 = undefined;
    var off: usize = 2;
    for (phrases[0..count]) |*phrase| {
        if (off + 2 > payload.len) return writeErrorResp(resp, op_byte, .invalid);
        const len = std.mem.readInt(u16, payload[off..][0..2], .little);
        off += 2;
        if (len == 0 or len > facts_index.MAX_FOLDED_NAME or off + len > payload.len) return writeErrorResp(resp, op_byte, .invalid);
        phrase.* = payload[off..][0..len];
        off += len;
    }
    if (off != payload.len) return writeErrorResp(resp, op_byte, .invalid);

    var arena = std.heap.ArenaAllocator.init(db.allocator);
    defer arena.deinit();
    var matches: [operations.MAX_NAME_MATCHES]operations.NameMatch = undefined;
    const ready = operations.matchNames(db, arena.allocator(), phrases[0..count], matches[0..count]) catch |err| return writeMappedError(resp, op_byte, err);
    const answered = if (ready) matches[0..count] else matches[0..0];

    var body: std.Io.Writer = .fixed(resp[RESPONSE_HEADER_SIZE..]);
    writeMatchNamesBody(&body, ready, answered) catch return writeErrorRespSub(resp, op_byte, .invalid, .buffer_too_small);
    const len = RESPONSE_HEADER_SIZE + body.end;
    writeOkHeader(resp, op_byte, len, @intCast(answered.len));
    return len;
}

fn writeMatchNamesBody(w: *std.Io.Writer, ready: bool, matches: []const operations.NameMatch) std.Io.Writer.Error!void {
    try w.writeByte(@intFromBool(ready));
    try w.writeInt(u16, @intCast(matches.len), .little);
    for (matches) |match| {
        try w.writeInt(u64, match.category_id, .little);
        try w.writeByte(@intFromBool(match.names_someone));
    }
}

fn handlePutLinkEntities(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 2) return writeErrorResp(resp, op_byte, .invalid);
    const count = std.mem.readInt(u16, payload[0..2], .little);
    if (count == 0 or count > operations.MAX_ENTITY_WRITES) return writeErrorResp(resp, op_byte, .invalid);
    if (resp.len < RESPONSE_HEADER_SIZE + 4 + @as(usize, count) * 9) return writeErrorResp(resp, op_byte, .err);

    var writes: [operations.MAX_ENTITY_WRITES]operations.EntityWrite = undefined;
    var off: usize = 2;
    for (writes[0..count]) |*w| {
        if (off + 18 > payload.len) return writeErrorResp(resp, op_byte, .invalid);
        w.link_id = std.mem.readInt(u64, payload[off..][0..8], .little);
        w.text_fingerprint = std.mem.readInt(u64, payload[off + 8 ..][0..8], .little);
        const len = std.mem.readInt(u16, payload[off + 16 ..][0..2], .little);
        off += 18;
        if (len > entities.MAX_ENCODED_LEN or off + len > payload.len) return writeErrorResp(resp, op_byte, .invalid);
        w.facts = payload[off..][0..len];
        off += len;
    }
    if (off != payload.len) return writeErrorResp(resp, op_byte, .invalid);

    var results: [operations.MAX_ENTITY_WRITES]operations.EntityWriteResult = undefined;
    operations.putLinkEntities(db, writes[0..count], results[0..count]) catch |err| return writeMappedError(resp, op_byte, err);

    var ok_count: u16 = 0;
    var reply_off: usize = RESPONSE_HEADER_SIZE + 4;
    for (writes[0..count], results[0..count]) |w, result| {
        std.mem.writeInt(u64, resp[reply_off..][0..8], w.link_id, .little);
        resp[reply_off + 8] = @intFromEnum(result);
        reply_off += 9;
        if (result == .ok) ok_count += 1;
    }
    std.mem.writeInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], ok_count, .little);
    std.mem.writeInt(u16, resp[RESPONSE_HEADER_SIZE + 2 ..][0..2], count - ok_count, .little);
    writeOkHeader(resp, op_byte, reply_off, 0);
    return reply_off;
}

fn handlePutCategoryVectors(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 10) return writeErrorResp(resp, op_byte, .invalid);
    const model = std.mem.readInt(u64, payload[0..8], .little);
    const count = std.mem.readInt(u16, payload[8..10], .little);
    if (count == 0 or count > operations.MAX_VECTORS_PER_WRITE) return writeErrorResp(resp, op_byte, .invalid);
    if (payload.len != 10 + @as(usize, count) * CATEGORY_VECTOR_WRITE_BYTES) return writeErrorResp(resp, op_byte, .invalid);
    if (resp.len < RESPONSE_HEADER_SIZE + 4 + @as(usize, count) * 9) return writeErrorResp(resp, op_byte, .err);

    var writes: [operations.MAX_VECTORS_PER_WRITE]operations.CategoryVectorWrite = undefined;
    for (writes[0..count], 0..) |*w, i| {
        const item = payload[10 + i * CATEGORY_VECTOR_WRITE_BYTES ..][0..CATEGORY_VECTOR_WRITE_BYTES];
        w.category_id = std.mem.readInt(u64, item[0..8], .little);
        vector_index.readEmbedding(item[8..][0..EMBEDDING_BYTES], &w.embedding);
    }

    var results: [operations.MAX_VECTORS_PER_WRITE]operations.VectorWriteResult = undefined;
    operations.putCategoryVectors(db, model, writes[0..count], results[0..count]) catch |err| return writeMappedError(resp, op_byte, err);

    var ok_count: u16 = 0;
    var off: usize = RESPONSE_HEADER_SIZE + 4;
    for (writes[0..count], results[0..count]) |w, result| {
        std.mem.writeInt(u64, resp[off..][0..8], w.category_id, .little);
        resp[off + 8] = @intFromEnum(result);
        off += 9;
        if (result == .ok) ok_count += 1;
    }
    std.mem.writeInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], ok_count, .little);
    std.mem.writeInt(u16, resp[RESPONSE_HEADER_SIZE + 2 ..][0..2], count - ok_count, .little);
    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

fn handlePutLinkVectors(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 10) return writeErrorResp(resp, op_byte, .invalid);
    const model = std.mem.readInt(u64, payload[0..8], .little);
    const count = std.mem.readInt(u16, payload[8..10], .little);
    if (count == 0 or count > operations.MAX_VECTORS_PER_WRITE) return writeErrorResp(resp, op_byte, .invalid);
    if (payload.len != 10 + @as(usize, count) * VECTOR_WRITE_BYTES) return writeErrorResp(resp, op_byte, .invalid);
    if (resp.len < RESPONSE_HEADER_SIZE + 4 + @as(usize, count) * 9) return writeErrorResp(resp, op_byte, .err);

    var writes: [operations.MAX_VECTORS_PER_WRITE]operations.VectorWrite = undefined;
    for (writes[0..count], 0..) |*w, i| {
        const item = payload[10 + i * VECTOR_WRITE_BYTES ..][0..VECTOR_WRITE_BYTES];
        w.link_id = std.mem.readInt(u64, item[0..8], .little);
        w.text_fingerprint = std.mem.readInt(u64, item[8..16], .little);
        vector_index.readEmbedding(item[16..][0..EMBEDDING_BYTES], &w.embedding);
    }

    var results: [operations.MAX_VECTORS_PER_WRITE]operations.VectorWriteResult = undefined;
    operations.putLinkVectors(db, model, writes[0..count], results[0..count]) catch |err| return writeMappedError(resp, op_byte, err);

    var ok_count: u16 = 0;
    var off: usize = RESPONSE_HEADER_SIZE + 4;
    for (writes[0..count], results[0..count]) |w, result| {
        std.mem.writeInt(u64, resp[off..][0..8], w.link_id, .little);
        resp[off + 8] = @intFromEnum(result);
        off += 9;
        if (result == .ok) ok_count += 1;
    }
    std.mem.writeInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], ok_count, .little);
    std.mem.writeInt(u16, resp[RESPONSE_HEADER_SIZE + 2 ..][0..2], count - ok_count, .little);
    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

fn writeIndexHealthFrame(state_snapshot: anytype, resp: []u8) usize {
    var off: usize = RESPONSE_HEADER_SIZE;
    std.mem.writeInt(i64, resp[off..][0..8], state_snapshot.last_run_at, .little);
    off += 8;
    resp[off] = @intCast(state_snapshot.indices.len);
    off += 1;
    for (state_snapshot.indices) |idx| {
        const name_len: u8 = @intCast(idx.name.len);
        resp[off] = name_len;
        off += 1;
        @memcpy(resp[off..][0..idx.name.len], idx.name);
        off += idx.name.len;
        std.mem.writeInt(u64, resp[off..][0..8], idx.expected, .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], idx.observed, .little);
        off += 8;
        std.mem.writeInt(u32, resp[off..][0..4], idx.driftBp(), .little);
        off += 4;
    }
    std.mem.writeInt(u64, resp[off..][0..8], state_snapshot.slug_path_repair_queue_depth, .little);
    off += 8;
    std.mem.writeInt(i64, resp[off..][0..8], state_snapshot.slug_path_repair_worker_last_tick_ms, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], state_snapshot.slug_path_repair_worker_tasks_processed, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], state_snapshot.slug_path_repair_worker_chunks_processed, .little);
    off += 8;
    return off;
}

fn handleIndexHealth(db: *Directory, resp: []u8, op_byte: u8) usize {
    const snap = db.verifier_state.snapshot(db);
    const off = writeIndexHealthFrame(snap, resp);
    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

fn handleRunVerifier(db: *Directory, resp: []u8, op_byte: u8) usize {
    @import("verifier.zig").runOnce(db, &db.verifier_state) catch |err| {
        log.warn("run_verifier failed: {}", .{err});
    };
    return handleIndexHealth(db, resp, op_byte);
}

fn handleRebuildIndex(db: *Directory, resp: []u8, op_byte: u8) usize {
    const repair = @import("repair/repair.zig");
    const stats = repair.rebuildAllIndices(db) catch |err| {
        log.err("rebuild_index failed: {}", .{err});
        return writeMappedError(resp, op_byte, err);
    };
    return writeU64Frame(resp, op_byte, &.{ stats.categories_rebuilt, stats.links_rebuilt, stats.queue_entries_drained });
}

fn handleSnapshot(db: *Directory, resp: []u8, op_byte: u8) usize {
    const result = zigstore.snapshot.forceSnapshot(db.store.snapshotHost()) catch |err| {
        if (err != error.SnapshotInProgress) {
            log.err("snapshot op failed: {}", .{err});
        }
        return writeMappedError(resp, op_byte, err);
    };
    return writeU64Frame(resp, op_byte, &.{ result.wal_sequence, result.duration_ms });
}

fn handleOpLatencyStats(db: *Directory, resp: []u8, op_byte: u8) usize {
    const PER_OP_BYTES: usize = 1 + 7 * 8;

    var off: usize = RESPONSE_HEADER_SIZE;
    if (off + 1 > resp.len) return writeErrorResp(resp, op_byte, .err);
    const count_off = off;
    off += 1;

    var emitted: u8 = 0;
    var i: usize = 0;
    while (i < db.op_latency.len) : (i += 1) {
        const h = &db.op_latency[i];
        const samples = h.samples();
        if (samples == 0) continue;
        if (off + PER_OP_BYTES > resp.len) break;
        if (emitted == 255) break;

        resp[off] = @intCast(i);
        off = writeU64s(resp, off + 1, &.{
            h.percentile(50.0),
            h.percentile(95.0),
            h.percentile(99.0),
            h.percentile(99.9),
            h.maxValue(),
            h.mean(),
            samples,
        });
        emitted += 1;
    }

    resp[count_off] = emitted;
    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

const BULK_IMPORT_RESULT_BYTES: usize = 6 * @sizeOf(u64);

fn handleBulkImport(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8, count: u16) usize {
    if (resp.len < RESPONSE_HEADER_SIZE + BULK_IMPORT_RESULT_BYTES) return writeErrorResp(resp, op_byte, .err);

    if (payload.len > BULK_IMPORT_MAX_BYTES) {
        log.warn("bulk_import: payload {d} bytes exceeds cap {d}", .{ payload.len, BULK_IMPORT_MAX_BYTES });
        return writeErrorRespSub(resp, op_byte, .invalid, .field_too_long);
    }
    if (@as(u32, count) > BULK_IMPORT_MAX_ITEMS) {
        log.warn("bulk_import: count {d} exceeds cap {d}", .{ count, BULK_IMPORT_MAX_ITEMS });
        return writeErrorRespSub(resp, op_byte, .invalid, .field_too_long);
    }

    const t_start = std.Io.Clock.awake.now(db.io);

    var inserted: u64 = 0;
    var duplicates: u64 = 0;
    var errors: u64 = 0;
    var first_id: u64 = 0;
    var last_id: u64 = 0;

    var data = payload;
    var processed: u32 = 0;
    var since_log: u32 = 0;

    while (processed < count) {
        const parsed = parsePayload(link_fields, data) orelse {
            const remaining = count - processed;
            errors += remaining;
            log.warn("bulk_import: truncated frame at item {d}/{d}, {d} unread items charged as errors", .{
                processed, count, remaining,
            });
            break;
        };
        const r = parsed.result;

        const id_or_err = operations.createLink(db, r.category_id, r.url, r.title, r.description);
        if (id_or_err) |id| {
            inserted += 1;
            if (first_id == 0) first_id = id;
            last_id = id;
        } else |err| switch (err) {
            error.DuplicateUrl => duplicates += 1,
            else => errors += 1,
        }

        data = parsed.rest;
        processed += 1;
        since_log += 1;
        if (since_log >= BULK_IMPORT_CHUNK) {
            log.info("bulk_import: processed {d}/{d} (inserted={d} dup={d} err={d})", .{
                processed, count, inserted, duplicates, errors,
            });
            since_log = 0;
        }
    }

    const elapsed_ms: u64 = @intCast(t_start.durationTo(std.Io.Clock.awake.now(db.io)).toMilliseconds());

    log.info("bulk_import: done count={d} inserted={d} dup={d} err={d} elapsed_ms={d}", .{
        count, inserted, duplicates, errors, elapsed_ms,
    });

    return writeU64Frame(resp, op_byte, &.{ inserted, duplicates, errors, first_id, last_id, elapsed_ms });
}

fn handleCreateSubmission(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (resp.len < RESPONSE_HEADER_SIZE + ITEM_RESULT_BYTES) return 0;

    const parsed = parsePayload(link_fields, payload) orelse
        return writeErrorResp(resp, op_byte, .invalid);
    const rest = parsed.rest;
    if (rest.len < 8) return writeErrorResp(resp, op_byte, .invalid);
    const submitter_id = std.mem.readInt(u64, rest[0..8], .little);

    const r = parsed.result;
    const opts = operations.CreateLinkOpts{
        .status = @intFromEnum(schema.LinkStatus.pending),
        .submitter_id = submitter_id,
    };
    const id = operations.createLinkWithOpts(
        db,
        r.category_id,
        r.url,
        r.title,
        r.description,
        opts,
    ) catch |err| {
        const pair = mapErrorWithSubStatus(err);
        const off = writeItemResult(resp, RESPONSE_HEADER_SIZE, pair, 0);
        writeRawHeader(resp, op_byte, off, pair.status, pair.sub_status, 1);
        return off;
    };
    const off = writeItemResult(resp, RESPONSE_HEADER_SIZE, OK_PAIR, id);
    writeOkHeader(resp, op_byte, off, 1);
    return off;
}

fn handleUpdateLinkStatus(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 9) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const status = payload[8];
    if (!isKnownLinkStatus(status)) return writeErrorRespSub(resp, op_byte, .invalid, .unsupported_order);
    operations.updateLinkStatus(db, id, status) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeResp(resp, op_byte, .ok, 0, &.{});
}

const BULK_MAX: u16 = 200;

const BulkResultCode = enum(u8) {
    ok = 0,
    not_found = 1,
    already_in_state = 2,
    invalid_transition = 3,
};

fn handleBulkLinkOp(
    resp: []u8,
    op_byte: u8,
    payload: []const u8,
    id_off: usize,
    db: *Directory,
    status: u8,
    comptime applyOne: fn (*Directory, u64, u8) BulkResultCode,
) usize {
    if (payload.len < id_off + 2) return writeErrorResp(resp, op_byte, .invalid);
    const count = std.mem.readInt(u16, payload[id_off..][0..2], .little);
    if (count > BULK_MAX) return writeErrorResp(resp, op_byte, .invalid);
    const ids_start = id_off + 2;
    const expected_len: usize = ids_start + @as(usize, count) * 8;
    if (payload.len != expected_len) return writeErrorResp(resp, op_byte, .invalid);

    if (resp.len < RESPONSE_HEADER_SIZE + 4) return writeErrorResp(resp, op_byte, .err);

    var off: usize = RESPONSE_HEADER_SIZE;
    const ok_off = off;
    off += 2;
    const err_off = off;
    off += 2;
    var ok_count: u16 = 0;
    var err_count: u16 = 0;

    var i: usize = 0;
    while (i < count) : (i += 1) {
        const id = std.mem.readInt(u64, payload[ids_start + i * 8 ..][0..8], .little);
        if (off + 9 > resp.len) break;
        const code = applyOne(db, id, status);
        std.mem.writeInt(u64, resp[off..][0..8], id, .little);
        resp[off + 8] = @intFromEnum(code);
        off += 9;
        if (code == .ok) ok_count += 1 else err_count += 1;
    }

    std.mem.writeInt(u16, resp[ok_off..][0..2], ok_count, .little);
    std.mem.writeInt(u16, resp[err_off..][0..2], err_count, .little);
    writeOkHeader(resp, op_byte, off, 0);
    return off;
}

fn applyBulkStatus(db: *Directory, id: u64, status: u8) BulkResultCode {
    operations.updateLinkStatusBulkOne(db, id, status) catch |err| return switch (err) {
        error.LinkNotFound => .not_found,
        error.AlreadyInState => .already_in_state,
        else => .not_found,
    };
    return .ok;
}

fn applyBulkDelete(db: *Directory, id: u64, status: u8) BulkResultCode {
    _ = status;
    operations.deleteLink(db, id) catch |err| return switch (err) {
        error.LinkNotFound => .not_found,
        else => .not_found,
    };
    return .ok;
}

fn handleBulkUpdateLinkStatus(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 3) return writeErrorResp(resp, op_byte, .invalid);
    const status = payload[0];
    if (!isKnownLinkStatus(status)) return writeErrorResp(resp, op_byte, .invalid);
    return handleBulkLinkOp(resp, op_byte, payload, 1, db, status, applyBulkStatus);
}

fn handleBulkDeleteLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    return handleBulkLinkOp(resp, op_byte, payload, 0, db, 0, applyBulkDelete);
}

fn handleCountsByStatus(db: *Directory, resp: []u8, op_byte: u8) usize {
    const counts = operations.countsByStatus(db) catch |err| return writeMappedError(resp, op_byte, err);
    return writeU64Frame(resp, op_byte, &.{ counts.pending, counts.approved, counts.rejected });
}

fn handleStats(db: *Directory, resp: []u8, op_byte: u8) usize {
    const s = db.getStats();
    return writeU64Frame(resp, op_byte, &.{
        s.category_count,
        s.link_count,
        @as(u64, s.page_count),
        s.cache_hits,
        s.cache_misses,
        s.wal_pending_batch_entries,
    });
}

fn defaultListBufLen(comptime T: type) usize {
    const budget: usize = 128 * 1024;
    const per = @sizeOf(T);
    const n: usize = if (per == 0) 100 else @max(1, budget / per);
    return @min(n, 100);
}

test "parsePayload link fields" {
    const fields = link_fields;
    var buf: [100]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 42, .little);
    const url = "https://test.com";
    std.mem.writeInt(u16, buf[8..10], url.len, .little);
    @memcpy(buf[10..][0..url.len], url);
    var off: usize = 10 + url.len;
    std.mem.writeInt(u16, buf[off..][0..2], 4, .little);
    off += 2;
    @memcpy(buf[off..][0..4], "Test");
    off += 4;
    std.mem.writeInt(u16, buf[off..][0..2], 0, .little);
    off += 2;

    const parsed = parsePayload(fields, buf[0..off]).?;
    try std.testing.expectEqual(@as(u64, 42), parsed.result.category_id);
    try std.testing.expectEqualSlices(u8, url, parsed.result.url);
    try std.testing.expectEqualSlices(u8, "Test", parsed.result.title);
    try std.testing.expectEqualSlices(u8, "", parsed.result.description);
}

test "advancePayload matches parsePayload" {
    const fields = link_fields;
    var buf: [100]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 1, .little);
    std.mem.writeInt(u16, buf[8..10], 3, .little);
    @memcpy(buf[10..13], "abc");
    std.mem.writeInt(u16, buf[13..15], 2, .little);
    @memcpy(buf[15..17], "xy");
    std.mem.writeInt(u16, buf[17..19], 0, .little);

    const parsed = parsePayload(fields, buf[0..19]).?;
    const advanced = advancePayload(fields, buf[0..19]).?;
    try std.testing.expectEqual(parsed.rest.len, advanced.len);
}

test "readOptionalString" {
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], 5, .little);
    @memcpy(buf[2..7], "hello");

    var off: usize = 0;
    const result = readOptionalString(&buf, &off, 0x01, 0x01);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "hello", result.?.?);
    try std.testing.expectEqual(@as(usize, 7), off);

    var off2: usize = 0;
    const result2 = readOptionalString(&buf, &off2, 0x00, 0x01);
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.? == null);
}

test "list_subtree_links: parses request payload" {
    var buf: [17]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 42, .little);
    buf[8] = 0;
    std.mem.writeInt(u32, buf[9..13], 100, .little);
    std.mem.writeInt(u32, buf[13..17], 50, .little);

    const r = ListSubtreeLinksRequest.parse(buf[0..]);
    try std.testing.expectEqual(@as(u64, 42), r.cat_id);
    try std.testing.expectEqual(@as(u8, 0), r.order_code);
    try std.testing.expectEqual(@as(u32, 100), r.offset);
    try std.testing.expectEqual(@as(u32, 50), r.limit);
}

test "list_subtree_links: rejects offset > 5000" {
    var buf: [17]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], 42, .little);
    buf[8] = 0;
    std.mem.writeInt(u32, buf[9..13], 5001, .little);
    std.mem.writeInt(u32, buf[13..17], 50, .little);

    const r = ListSubtreeLinksRequest.parse(buf[0..]);
    try std.testing.expectError(error.OffsetTooLarge, r.validate());
}

test "list_subtree_links: min_frame allows empty result set" {
    try std.testing.expectEqual(@as(usize, 30), SUBTREE_MIN_FRAME);
}

test "index_health response carries slug_path_repair_queue fields" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var task = schema.RepairTask{ .cat_id = 1, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));

    var resp: [4096]u8 = undefined;
    const off = handleIndexHealth(db, &resp, @intFromEnum(Op.index_health));
    try std.testing.expect(off > RESPONSE_HEADER_SIZE + 9);

    const queue_depth = std.mem.readInt(u64, resp[off - 32 ..][0..8], .little);
    try std.testing.expectEqual(@as(u64, 1), queue_depth);
}

test "mapErrorWithSubStatus: maps each known error to a distinct (status, sub_status) pair" {
    const cases = [_]struct { err: anyerror, status: Status, sub: SubStatus }{
        .{ .err = error.FieldTooLong, .status = .invalid, .sub = .field_too_long },
        .{ .err = error.PathTooDeep, .status = .invalid, .sub = .path_too_deep },
        .{ .err = error.UnsupportedOrder, .status = .invalid, .sub = .unsupported_order },
        .{ .err = error.OffsetTooLarge, .status = .invalid, .sub = .offset_too_large },
        .{ .err = error.ParentNotFound, .status = .category_not_found, .sub = .parent_not_found },
        .{ .err = error.DuplicateUrl, .status = .duplicate, .sub = .duplicate_url },
        .{ .err = error.DuplicateSlug, .status = .duplicate, .sub = .duplicate_slug },
        .{ .err = error.LinkNotFound, .status = .not_found, .sub = .none },
        .{ .err = error.CategoryHasChildren, .status = .has_children, .sub = .none },
        .{ .err = error.CircularHierarchy, .status = .circular, .sub = .none },
        .{ .err = error.OutOfMemory, .status = .err, .sub = .none },
    };
    for (cases) |c| {
        const got = mapErrorWithSubStatus(c.err);
        try std.testing.expectEqual(c.status, got.status);
        try std.testing.expectEqual(c.sub, got.sub_status);
    }
}

test "writeErrorRespSub: emits 10-byte response header with sub_status at offset 6" {
    var buf: [32]u8 = undefined;
    const len = writeErrorRespSub(&buf, @intFromEnum(Op.create_link), .invalid, .field_too_long);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), len);
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buf[0..4], .little));
    try std.testing.expectEqual(@intFromEnum(Op.create_link), buf[4]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), buf[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.field_too_long), buf[6]);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buf[8..10], .little));
}

test "writeResp: ok response carries sub_status=none in header" {
    var buf: [64]u8 = undefined;
    const payload = [_]u8{ 1, 2, 3, 4 };
    const len = writeResp(&buf, @intFromEnum(Op.ping), .ok, 1, &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 4), len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), buf[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.none), buf[6]);
    try std.testing.expectEqual(@as(u8, 0), buf[7]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buf[8..10], .little));
    try std.testing.expectEqualSlices(u8, &payload, buf[RESPONSE_HEADER_SIZE..len]);
}

test "create_link: oversized URL produces status=invalid, sub_status=field_too_long" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");

    const operations_shared = @import("operations/operations_shared.zig");
    const oversized = try allocator.alloc(u8, operations_shared.MAX_URL_LEN + 1000);
    defer allocator.free(oversized);
    @memset(oversized, 'a');

    var payload_buf: [16384]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u64, payload_buf[off..][0..8], cat_id, .little);
    off += 8;
    std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(oversized.len), .little);
    off += 2;
    @memcpy(payload_buf[off..][0..oversized.len], oversized);
    off += oversized.len;
    std.mem.writeInt(u16, payload_buf[off..][0..2], 5, .little);
    off += 2;
    @memcpy(payload_buf[off..][0..5], "Title");
    off += 5;
    std.mem.writeInt(u16, payload_buf[off..][0..2], 0, .little);
    off += 2;

    var resp: [256]u8 = undefined;
    const written = CreateLinks.handle(db, &resp, payload_buf[0..off], 1);
    try std.testing.expect(written >= RESPONSE_HEADER_SIZE + 10);

    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    const item_status: Status = @enumFromInt(resp[RESPONSE_HEADER_SIZE]);
    const item_sub: SubStatus = @enumFromInt(resp[RESPONSE_HEADER_SIZE + 1]);
    try std.testing.expectEqual(Status.invalid, item_status);
    try std.testing.expectEqual(SubStatus.field_too_long, item_sub);
}

test "list_subtree_links: unsupported order_code produces sub_status=unsupported_order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 1, .little);
    payload[8] = 99;
    std.mem.writeInt(u32, payload[9..13], 0, .little);
    std.mem.writeInt(u32, payload[13..17], 50, .little);

    var resp: [256]u8 = undefined;
    const len = handleListSubtreeLinks(db, &resp, @intFromEnum(Op.list_subtree_links), &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.unsupported_order), resp[6]);
    try std.testing.expectEqual(@as(u8, 0), resp[7]);
}

test "list_subtree_links: a plain page stops walking once filled and reports link_count_subtree as total" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const ops = @import("operations/operations.zig");
    const top_id = try ops.createCategory(db, 0, "Top", "top", "");
    var cat_ids: [6]u64 = undefined;
    for (0..6) |i| {
        var slug_buf: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buf, "c{d}", .{i}) catch unreachable;
        cat_ids[i] = try ops.createCategory(db, top_id, "x", slug, "");
        var url_buf: [32]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://x{d}.t", .{i}) catch unreachable;
        _ = try ops.createLink(db, cat_ids[i], url, "L", "");
    }
    try db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    try db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());
    try db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());
    try db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], top_id, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], 1, .little);
    std.mem.writeInt(u32, payload[13..17], 2, .little);

    var resp: [4096]u8 = undefined;
    const len = handleListSubtreeLinks(db, &resp, @intFromEnum(Op.list_subtree_links), &payload);
    const written = std.mem.readInt(u32, resp[RESPONSE_HEADER_SIZE..][0..4], .little);
    const total = std.mem.readInt(u64, resp[len - 16 .. len - 8][0..8], .little);
    const next = std.mem.readInt(u64, resp[len - 8 .. len][0..8], .little);

    try std.testing.expectEqual(@as(u32, 2), written);
    try std.testing.expectEqual(@as(u64, 6), total);
    try std.testing.expect(next != 0);

    const descendants = try subtree.collectDescendantsCached(db.cat_by_parent(), top_id, &db.subtree_cache, allocator);
    defer allocator.free(descendants);
    const walked = try subtree.listSubtreeLinkIds(db.link_by_category(), descendants, 1, 2, allocator);
    defer allocator.free(walked);
    try std.testing.expectEqual(@as(usize, 2), walked.len);
}

test "list_subtree_links: oversize offset produces sub_status=offset_too_large" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 1, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], MAX_SUBTREE_OFFSET + 1, .little);
    std.mem.writeInt(u32, payload[13..17], 50, .little);

    var resp: [256]u8 = undefined;
    const len = handleListSubtreeLinks(db, &resp, @intFromEnum(Op.list_subtree_links), &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.offset_too_large), resp[6]);
}

test "op_latency_stats (23): empty histograms produce count=0 response" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var resp: [4096]u8 = undefined;
    const off = handleOpLatencyStats(db, &resp, @intFromEnum(Op.op_latency_stats));
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 1), off);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u8, 0), resp[RESPONSE_HEADER_SIZE]);
}

test "op_latency_stats (23): records latency through processFrames + reports per op" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var bp: zigstore.connection.BufferPair = .{};
    var conn: zigstore.connection.Connection = .{};
    conn.buf = &bp;

    var off: usize = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        std.mem.writeInt(u32, bp.request_buf[off..][0..4], 8, .little);
        bp.request_buf[off + 4] = @intFromEnum(Op.ping);
        bp.request_buf[off + 5] = 0;
        std.mem.writeInt(u16, bp.request_buf[off + 6 ..][0..2], 0, .little);
        off += 8;
    }
    conn.bytes_read = off;

    protocol.processFrames(db, &conn, &Directory.dispatch, db.op_latency, RESPONSE_RESERVE);

    var resp: [4096]u8 = undefined;
    const reply_len = handleOpLatencyStats(db, &resp, @intFromEnum(Op.op_latency_stats));
    try std.testing.expect(reply_len > RESPONSE_HEADER_SIZE + 1);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const count = resp[RESPONSE_HEADER_SIZE];
    try std.testing.expect(count >= 1);

    var p: usize = RESPONSE_HEADER_SIZE + 1;
    var found_ping = false;
    var k: u8 = 0;
    while (k < count) : (k += 1) {
        const op_code = resp[p];
        p += 1;
        const samples = std.mem.readInt(u64, resp[p + 6 * 8 ..][0..8], .little);
        if (op_code == @intFromEnum(Op.ping)) {
            try std.testing.expectEqual(@as(u64, 5), samples);
            found_ping = true;
        }
        p += 7 * 8;
    }
    try std.testing.expect(found_ping);
}

test "handleStats refuses an undersized response buffer instead of overflowing it" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var tail: [RESPONSE_HEADER_SIZE + 8]u8 = undefined;
    const refused = handleStats(db, &tail, @intFromEnum(Op.stats));
    try std.testing.expect(refused <= tail.len);
    try std.testing.expectEqual(@intFromEnum(Status.err), tail[5]);

    var exact: [RESPONSE_HEADER_SIZE + 6 * 8]u8 = undefined;
    const written = handleStats(db, &exact, @intFromEnum(Op.stats));
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 6 * 8), written);
    try std.testing.expectEqual(@intFromEnum(Status.ok), exact[5]);
}

test "snapshot op (22): writes snapshot.meta and returns wal_sequence + duration_ms" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    _ = try operations.createCategory(db, 0, "Top", "top", "");

    var resp: [128]u8 = undefined;
    const off = handleSnapshot(db, &resp, @intFromEnum(Op.snapshot));
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 16), off);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.none), resp[6]);

    const snap = (try zigstore.snapshot.SnapshotManager.loadSnapshotMeta(db.io, db.config.data_dir)).?;
    try std.testing.expectEqual(zigstore.snapshot.SNAP_MAGIC, snap.magic);

    const reported_seq = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE..][0..8], .little);
    try std.testing.expectEqual(snap.wal_sequence, reported_seq);
}

test "snapshot op (22): concurrent invocation returns already_in_progress" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    db.store.snapshot_in_progress.store(true, .release);
    defer db.store.snapshot_in_progress.store(false, .release);

    var resp: [128]u8 = undefined;
    const off = handleSnapshot(db, &resp, @intFromEnum(Op.snapshot));
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), off);
    try std.testing.expectEqual(@intFromEnum(Status.err), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.already_in_progress), resp[6]);
}

test "create_link: duplicate URL produces status=duplicate, sub_status=duplicate_url" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    _ = try operations.createLink(db, cat_id, "https://example.com", "Title", "");

    var payload_buf: [256]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u64, payload_buf[off..][0..8], cat_id, .little);
    off += 8;
    const url = "https://example.com";
    std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(url.len), .little);
    off += 2;
    @memcpy(payload_buf[off..][0..url.len], url);
    off += url.len;
    std.mem.writeInt(u16, payload_buf[off..][0..2], 5, .little);
    off += 2;
    @memcpy(payload_buf[off..][0..5], "Title");
    off += 5;
    std.mem.writeInt(u16, payload_buf[off..][0..2], 0, .little);
    off += 2;

    var resp: [256]u8 = undefined;
    const written = CreateLinks.handle(db, &resp, payload_buf[0..off], 1);
    try std.testing.expect(written >= RESPONSE_HEADER_SIZE + 10);
    const item_status: Status = @enumFromInt(resp[RESPONSE_HEADER_SIZE]);
    const item_sub: SubStatus = @enumFromInt(resp[RESPONSE_HEADER_SIZE + 1]);
    try std.testing.expectEqual(Status.duplicate, item_status);
    try std.testing.expectEqual(SubStatus.duplicate_url, item_sub);
}

test "a dispatched create_link frame is durable before it is acknowledged and shares fsyncs across its items" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    const items = 50;
    var payload: [items * 64]u8 = undefined;
    var off: usize = 0;
    var url_buf: [32]u8 = undefined;
    for (0..items) |i| {
        const url = try std.fmt.bufPrint(&url_buf, "https://g{d}.example", .{i});
        off = appendBulkItem(&payload, off, cat_id, url, "T", "");
    }

    const fsyncs_before = db.store.walFsyncCount();
    var resp: [4096]u8 = undefined;
    var gate: zigstore.protocol.FrameGate = undefined;
    _ = Directory.dispatch(db, @intFromEnum(Op.create_link), payload[0..off], items, &resp, &gate);

    const wal = &db.store.wal_writer.?;
    try std.testing.expectEqual(wal.getSequence(), db.store.durableSeqPublished());
    try std.testing.expect(db.store.walFsyncCount() - fsyncs_before < items);
    try std.testing.expectEqual(@as(u64, items), (try operations.countsByStatus(db)).approved);
}

fn appendBulkItem(
    buf: []u8,
    off_in: usize,
    cat_id: u64,
    url: []const u8,
    title: []const u8,
    desc: []const u8,
) usize {
    var off = off_in;
    std.mem.writeInt(u64, buf[off..][0..8], cat_id, .little);
    off += 8;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(url.len), .little);
    off += 2;
    @memcpy(buf[off..][0..url.len], url);
    off += url.len;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(title.len), .little);
    off += 2;
    @memcpy(buf[off..][0..title.len], title);
    off += title.len;
    std.mem.writeInt(u16, buf[off..][0..2], @intCast(desc.len), .little);
    off += 2;
    @memcpy(buf[off..][0..desc.len], desc);
    off += desc.len;
    return off;
}

test "bulk_import (24): empty count returns all-zero stats" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var resp: [128]u8 = undefined;
    const off = handleBulkImport(db, &resp, @intFromEnum(Op.bulk_import), &.{}, 0);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 48), off);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.none), resp[6]);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const v = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + i * 8 ..][0..8], .little);
        try std.testing.expectEqual(@as(u64, 0), v);
    }
}

test "bulk_import (24): inserts 1000 items in a single frame" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Top", "top", "");

    const N: u32 = 1000;
    const payload_buf = try allocator.alloc(u8, BULK_IMPORT_MAX_BYTES);
    defer allocator.free(payload_buf);

    var off: usize = 0;
    var i: u32 = 0;
    var url_buf: [64]u8 = undefined;
    var title_buf: [32]u8 = undefined;
    while (i < N) : (i += 1) {
        const url = try std.fmt.bufPrint(&url_buf, "https://bulk{d}.test", .{i});
        const title = try std.fmt.bufPrint(&title_buf, "T{d}", .{i});
        off = appendBulkItem(payload_buf, off, cat_id, url, title, "");
    }

    var resp: [128]u8 = undefined;
    const reply_len = handleBulkImport(db, &resp, @intFromEnum(Op.bulk_import), payload_buf[0..off], @intCast(N));
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 48), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const inserted = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE..][0..8], .little);
    const duplicates = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 8 ..][0..8], .little);
    const errors = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 16 ..][0..8], .little);
    const first_id = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 24 ..][0..8], .little);
    const last_id = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 32 ..][0..8], .little);

    try std.testing.expectEqual(@as(u64, 1000), inserted);
    try std.testing.expectEqual(@as(u64, 0), duplicates);
    try std.testing.expectEqual(@as(u64, 0), errors);
    try std.testing.expect(first_id != 0);
    try std.testing.expect(last_id >= first_id);

    try std.testing.expect((try operations.getLink(db, first_id)) != null);
    try std.testing.expect((try operations.getLink(db, last_id)) != null);
}

test "bulk_import (24): mid-stream invalid item is counted, subsequent items go through" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Top", "top", "");

    const operations_shared = @import("operations/operations_shared.zig");
    const oversized = try allocator.alloc(u8, operations_shared.MAX_URL_LEN + 1000);
    defer allocator.free(oversized);
    @memset(oversized, 'a');

    const payload_buf = try allocator.alloc(u8, BULK_IMPORT_MAX_BYTES);
    defer allocator.free(payload_buf);

    var off: usize = 0;
    off = appendBulkItem(payload_buf, off, cat_id, "https://good1.test", "G1", "");
    off = appendBulkItem(payload_buf, off, cat_id, oversized, "Bad", "");
    off = appendBulkItem(payload_buf, off, cat_id, "https://good2.test", "G2", "");

    var resp: [128]u8 = undefined;
    const reply_len = handleBulkImport(db, &resp, @intFromEnum(Op.bulk_import), payload_buf[0..off], 3);
    try std.testing.expect(reply_len == RESPONSE_HEADER_SIZE + 48);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const inserted = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE..][0..8], .little);
    const duplicates = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 8 ..][0..8], .little);
    const errors = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 16 ..][0..8], .little);

    try std.testing.expectEqual(@as(u64, 2), inserted);
    try std.testing.expectEqual(@as(u64, 0), duplicates);
    try std.testing.expectEqual(@as(u64, 1), errors);
}

test "bulk_import (24): payload exceeding byte cap is rejected" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const oversized = try allocator.alloc(u8, BULK_IMPORT_MAX_BYTES + 1);
    defer allocator.free(oversized);
    @memset(oversized, 0);

    var resp: [128]u8 = undefined;
    const reply_len = handleBulkImport(db, &resp, @intFromEnum(Op.bulk_import), oversized, 1);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.field_too_long), resp[6]);
}

test "create_submission: writes a pending Link with the supplied submitter_id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");

    var payload_buf: [256]u8 = undefined;
    var off: usize = 0;
    std.mem.writeInt(u64, payload_buf[off..][0..8], cat_id, .little);
    off += 8;
    const url = "https://example.com/submission";
    std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(url.len), .little);
    off += 2;
    @memcpy(payload_buf[off..][0..url.len], url);
    off += url.len;
    const title = "Submitted Site";
    std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(title.len), .little);
    off += 2;
    @memcpy(payload_buf[off..][0..title.len], title);
    off += title.len;
    const desc = "Pending review.";
    std.mem.writeInt(u16, payload_buf[off..][0..2], @intCast(desc.len), .little);
    off += 2;
    @memcpy(payload_buf[off..][0..desc.len], desc);
    off += desc.len;
    std.mem.writeInt(u64, payload_buf[off..][0..8], 7777, .little);
    off += 8;

    var resp: [128]u8 = undefined;
    const reply_len = handleCreateSubmission(db, &resp, @intFromEnum(Op.create_submission), payload_buf[0..off]);
    try std.testing.expect(reply_len >= RESPONSE_HEADER_SIZE + 10);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const item_status: Status = @enumFromInt(resp[RESPONSE_HEADER_SIZE]);
    try std.testing.expectEqual(Status.ok, item_status);
    const id = std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 2 ..][0..8], .little);
    try std.testing.expect(id > 0);

    const link = (try operations.getLink(db, id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
    try std.testing.expectEqual(@as(u64, 7777), link.submitter_id);
}

test "update_link_status: flips pending → approved" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    const id = try operations.createLinkWithOpts(
        db,
        cat_id,
        "https://x.example",
        "X",
        "",
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 1 },
    );

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], id, .little);
    payload[8] = @intFromEnum(schema.LinkStatus.approved);

    var resp: [64]u8 = undefined;
    const reply_len = handleUpdateLinkStatus(db, &resp, @intFromEnum(Op.update_link_status), &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const link = (try operations.getLink(db, id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.approved)), link.status);
}

test "list_all_links (op=16) with trailing status byte filters by status" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");

    _ = try operations.createLinkWithOpts(db, cat_id, "https://a.example", "a", "", .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 1 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://b.example", "b", "", .{ .status = @intFromEnum(schema.LinkStatus.approved), .submitter_id = 2 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://c.example", "c", "", .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 3 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://d.example", "d", "", .{ .status = @intFromEnum(schema.LinkStatus.rejected), .submitter_id = 4 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://e.example", "e", "", .{ .status = @intFromEnum(schema.LinkStatus.approved), .submitter_id = 5 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://f.example", "f", "", .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 6 });

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 0, .little);
    std.mem.writeInt(u32, payload[4..8], 50, .little);
    payload[8] = @intFromEnum(schema.LinkStatus.pending);

    var resp: [8192]u8 = undefined;
    const reply_len = handleListLinks(.none, operations.listAllLinks, db, &resp, @intFromEnum(Op.list_all_links), &payload);
    try std.testing.expect(reply_len >= RESPONSE_HEADER_SIZE);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const item_count = std.mem.readInt(u16, resp[8..10], .little);
    try std.testing.expectEqual(@as(u16, 3), item_count);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const start = RESPONSE_HEADER_SIZE + i * @sizeOf(schema.Link);
        const link = std.mem.bytesToValue(schema.Link, resp[start..][0..@sizeOf(schema.Link)]);
        try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
    }

    var payload_all: [8]u8 = undefined;
    std.mem.writeInt(u32, payload_all[0..4], 0, .little);
    std.mem.writeInt(u32, payload_all[4..8], 50, .little);
    var resp_all: [16384]u8 = undefined;
    const reply_all = handleListLinks(.none, operations.listAllLinks, db, &resp_all, @intFromEnum(Op.list_all_links), &payload_all);
    try std.testing.expect(reply_all >= RESPONSE_HEADER_SIZE);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp_all[5]);
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, resp_all[8..10], .little));
}

test "list_links (op=13) with trailing status byte filters within a category" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    const other_id = try operations.createCategory(db, 0, "Other", "other", "");

    _ = try operations.createLinkWithOpts(db, cat_id, "https://p1.example", "p1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://a1.example", "a1", "", .{ .status = @intFromEnum(schema.LinkStatus.approved) });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://p2.example", "p2", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, other_id, "https://o1.example", "o1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, other_id, "https://o2.example", "o2", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], cat_id, .little);
    std.mem.writeInt(u32, payload[8..12], 0, .little);
    std.mem.writeInt(u32, payload[12..16], 50, .little);
    payload[16] = @intFromEnum(schema.LinkStatus.pending);

    var resp: [8192]u8 = undefined;
    const reply_len = handleListLinks(.leading_id, operations.listLinks, db, &resp, @intFromEnum(Op.list_links), &payload);
    try std.testing.expect(reply_len >= RESPONSE_HEADER_SIZE);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const item_count = std.mem.readInt(u16, resp[8..10], .little);
    try std.testing.expectEqual(@as(u16, 2), item_count);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const start = RESPONSE_HEADER_SIZE + i * @sizeOf(schema.Link);
        const link = std.mem.bytesToValue(schema.Link, resp[start..][0..@sizeOf(schema.Link)]);
        try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
        try std.testing.expectEqual(cat_id, link.category_id);
    }
}

test "list_links_by_submitter (op=27) with trailing status byte filters for one submitter" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    _ = try operations.createLinkWithOpts(db, cat_id, "https://x1.example", "x1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 100 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://x2.example", "x2", "", .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 100 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://x3.example", "x3", "", .{ .status = @intFromEnum(schema.LinkStatus.approved), .submitter_id = 100 });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://y1.example", "y1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 200 });

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 100, .little);
    std.mem.writeInt(u32, payload[8..12], 0, .little);
    std.mem.writeInt(u32, payload[12..16], 50, .little);
    payload[16] = @intFromEnum(schema.LinkStatus.pending);

    var resp: [8192]u8 = undefined;
    const reply_len = handleListLinks(.leading_id, operations.listLinksBySubmitter, db, &resp, @intFromEnum(Op.list_links_by_submitter), &payload);
    try std.testing.expect(reply_len >= RESPONSE_HEADER_SIZE);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const item_count = std.mem.readInt(u16, resp[8..10], .little);
    try std.testing.expectEqual(@as(u16, 2), item_count);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const start = RESPONSE_HEADER_SIZE + i * @sizeOf(schema.Link);
        const link = std.mem.bytesToValue(schema.Link, resp[start..][0..@sizeOf(schema.Link)]);
        try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
        try std.testing.expectEqual(@as(u64, 100), link.submitter_id);
    }
}

test "list_subtree_links (op=17) with trailing status byte filters whole subtree + filtered total" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    const a_id = try operations.createCategory(db, top_id, "A", "a", "");
    const b_id = try operations.createCategory(db, top_id, "B", "b", "");

    _ = try operations.createLinkWithOpts(db, a_id, "https://a1.example", "a1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, a_id, "https://a2.example", "a2", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, a_id, "https://a3.example", "a3", "", .{ .status = @intFromEnum(schema.LinkStatus.approved) });
    _ = try operations.createLinkWithOpts(db, b_id, "https://b1.example", "b1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });

    var payload: [18]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], top_id, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], 0, .little);
    std.mem.writeInt(u32, payload[13..17], 50, .little);
    payload[17] = @intFromEnum(schema.LinkStatus.pending);

    var resp: [16384]u8 = undefined;
    const reply_len = handleListSubtreeLinks(db, &resp, @intFromEnum(Op.list_subtree_links), &payload);
    try std.testing.expect(reply_len >= RESPONSE_HEADER_SIZE + 4 + 8);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const returned = std.mem.readInt(u32, resp[RESPONSE_HEADER_SIZE..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 3), returned);

    const link_bytes_end = RESPONSE_HEADER_SIZE + 4 + returned * @sizeOf(schema.Link);
    const total = std.mem.readInt(u64, resp[link_bytes_end..][0..8], .little);
    try std.testing.expectEqual(@as(u64, 3), total);
}

test "bulk_update_link_status (op=34) reports per-id result codes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const a = try operations.createLinkWithOpts(db, cat_id, "https://a.example", "a", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    const b = try operations.createLinkWithOpts(db, cat_id, "https://b.example", "b", "", .{ .status = approved });
    const c: u64 = 999_999;

    var payload: [3 + 24]u8 = undefined;
    payload[0] = approved;
    std.mem.writeInt(u16, payload[1..3], 3, .little);
    std.mem.writeInt(u64, payload[3..11], a, .little);
    std.mem.writeInt(u64, payload[11..19], b, .little);
    std.mem.writeInt(u64, payload[19..27], c, .little);

    var resp: [256]u8 = undefined;
    const len = handleBulkUpdateLinkStatus(db, &resp, @intFromEnum(Op.bulk_update_link_status), &payload);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const ok_count = std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little);
    const err_count = std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE + 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 1), ok_count);
    try std.testing.expectEqual(@as(u16, 2), err_count);

    var off: usize = RESPONSE_HEADER_SIZE + 4;
    const id0 = std.mem.readInt(u64, resp[off..][0..8], .little);
    try std.testing.expectEqual(a, id0);
    try std.testing.expectEqual(@as(u8, 0), resp[off + 8]);
    off += 9;
    const id1 = std.mem.readInt(u64, resp[off..][0..8], .little);
    try std.testing.expectEqual(b, id1);
    try std.testing.expectEqual(@as(u8, 2), resp[off + 8]);
    off += 9;
    const id2 = std.mem.readInt(u64, resp[off..][0..8], .little);
    try std.testing.expectEqual(c, id2);
    try std.testing.expectEqual(@as(u8, 1), resp[off + 8]);
    off += 9;
    try std.testing.expectEqual(off, len);

    try std.testing.expectEqual(approved, (try operations.getLink(db, a)).?.status);
}

test "bulk_update_link_status (op=34) caps at 200" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [3]u8 = undefined;
    payload[0] = 1;
    std.mem.writeInt(u16, payload[1..3], 201, .little);
    var resp: [64]u8 = undefined;
    const len = handleBulkUpdateLinkStatus(db, &resp, @intFromEnum(Op.bulk_update_link_status), &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "bulk_delete_links (op=35): mixed found / not-found" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    const a = try operations.createLink(db, cat_id, "https://a.example", "a", "");
    const b = try operations.createLink(db, cat_id, "https://b.example", "b", "");
    const c: u64 = 999_999;

    var payload: [2 + 24]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 3, .little);
    std.mem.writeInt(u64, payload[2..10], a, .little);
    std.mem.writeInt(u64, payload[10..18], b, .little);
    std.mem.writeInt(u64, payload[18..26], c, .little);

    var resp: [256]u8 = undefined;
    _ = handleBulkDeleteLinks(db, &resp, @intFromEnum(Op.bulk_delete_links), &payload);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE + 2 ..][0..2], .little));

    try std.testing.expect((try operations.getLink(db, a)) == null);
    try std.testing.expect((try operations.getLink(db, b)) == null);
}

test "counts_by_status (op=36) returns per-status totals" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const cat_id = try operations.createCategory(db, 0, "Cat", "cat", "");
    _ = try operations.createLinkWithOpts(db, cat_id, "https://p1.example", "p1", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://p2.example", "p2", "", .{ .status = @intFromEnum(schema.LinkStatus.pending) });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://a1.example", "a1", "", .{ .status = @intFromEnum(schema.LinkStatus.approved) });
    _ = try operations.createLinkWithOpts(db, cat_id, "https://r1.example", "r1", "", .{ .status = @intFromEnum(schema.LinkStatus.rejected) });

    var resp: [128]u8 = undefined;
    const len = handleCountsByStatus(db, &resp, @intFromEnum(Op.counts_by_status));
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE + 24), len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 8 ..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 16 ..][0..8], .little));
}

test "search (op=14): scope byte filters sections and links carry match_field" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    _ = try operations.createCategory(db, top_id, "Artistic", "artistic", "");
    _ = try operations.createLink(db, top_id, "https://example.com/x", "Artistic Tutorial", "");
    _ = try operations.createLink(db, top_id, "https://betaword.example", "Plain Title", "");

    const Parsed = struct {
        cat_count: u16,
        link_count: u16,
        first_match_field: u8,
    };
    const parse = struct {
        fn run(resp: []const u8) Parsed {
            var off: usize = RESPONSE_HEADER_SIZE;
            const cc = std.mem.readInt(u16, resp[off..][0..2], .little);
            off += 2 + @as(usize, cc) * @sizeOf(schema.Category);
            const lc = std.mem.readInt(u16, resp[off..][0..2], .little);
            off += 2;
            var mf: u8 = 255;
            if (lc > 0) mf = resp[off + @sizeOf(schema.Link)];
            return .{ .cat_count = cc, .link_count = lc, .first_match_field = mf };
        }
    }.run;

    const buildPayload = struct {
        fn run(buf: []u8, q: []const u8, limit: u32, scope: ?u8) usize {
            std.mem.writeInt(u16, buf[0..2], @intCast(q.len), .little);
            @memcpy(buf[2..][0..q.len], q);
            std.mem.writeInt(u32, buf[2 + q.len ..][0..4], limit, .little);
            var n: usize = 2 + q.len + 4;
            if (scope) |s| {
                buf[n] = s;
                n += 1;
            }
            return n;
        }
    }.run;

    var pbuf: [64]u8 = undefined;
    var resp: [16384]u8 = undefined;

    var n = buildPayload(&pbuf, "artistic", 50, null);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0..n]);
    var p = parse(&resp);
    try std.testing.expect(p.cat_count >= 1);
    try std.testing.expect(p.link_count >= 1);
    try std.testing.expectEqual(@as(u8, 0), p.first_match_field);

    n = buildPayload(&pbuf, "artistic", 50, 1);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0..n]);
    p = parse(&resp);
    try std.testing.expectEqual(@as(u16, 0), p.cat_count);
    try std.testing.expect(p.link_count >= 1);

    n = buildPayload(&pbuf, "artistic", 50, 2);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0..n]);
    p = parse(&resp);
    try std.testing.expect(p.cat_count >= 1);
    try std.testing.expectEqual(@as(u16, 0), p.link_count);

    n = buildPayload(&pbuf, "betaword", 50, 1);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0..n]);
    p = parse(&resp);
    try std.testing.expectEqual(@as(u16, 1), p.link_count);
    try std.testing.expectEqual(@as(u8, 1), p.first_match_field);
}

test "search (op=14): mode byte selects ranked matching and absent mode keeps all-terms" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    _ = try operations.createLink(db, top_id, "https://example.com/x", "Bonsai Nursery", "");

    const linkCount = struct {
        fn run(resp: []const u8) u16 {
            var off: usize = RESPONSE_HEADER_SIZE;
            const cc = std.mem.readInt(u16, resp[off..][0..2], .little);
            off += 2 + @as(usize, cc) * @sizeOf(schema.Category);
            return std.mem.readInt(u16, resp[off..][0..2], .little);
        }
    }.run;

    const query = "bonsai trees";
    var pbuf: [64]u8 = undefined;
    std.mem.writeInt(u16, pbuf[0..2], query.len, .little);
    @memcpy(pbuf[2..][0..query.len], query);
    std.mem.writeInt(u32, pbuf[2 + query.len ..][0..4], 50, .little);
    const base = 2 + query.len + 4;

    var resp: [16384]u8 = undefined;

    pbuf[base] = @intFromEnum(SearchScope.links_only);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 1]);
    try std.testing.expectEqual(@as(u16, 0), linkCount(&resp));

    pbuf[base + 1] = @intFromEnum(SearchMode.all_terms);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 2]);
    try std.testing.expectEqual(@as(u16, 0), linkCount(&resp));

    pbuf[base + 1] = @intFromEnum(SearchMode.ranked);
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 2]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 1), linkCount(&resp));

    pbuf[base + 1] = 9;
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 2]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    pbuf[base + 1] = @intFromEnum(SearchMode.ranked);
    pbuf[base + 2] = 0;
    pbuf[base + 3] = 0;
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 4]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "search (op=14): a trailing cap byte keeps two links a site and the site's last row says how many more it had" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    for ([_][]const u8{ "https://example.com/a", "https://example.com/b", "https://example.com/c", "https://example.com/d", "https://other.org/" }) |url| {
        _ = try operations.createLink(db, top_id, url, "Bonsai Nursery", "");
    }

    const query = "bonsai";
    var pbuf: [64]u8 = undefined;
    std.mem.writeInt(u16, pbuf[0..2], query.len, .little);
    @memcpy(pbuf[2..][0..query.len], query);
    std.mem.writeInt(u32, pbuf[2 + query.len ..][0..4], 50, .little);
    const base = 2 + query.len + 4;
    pbuf[base] = @intFromEnum(SearchScope.links_only);
    pbuf[base + 1] = @intFromEnum(SearchMode.ranked);
    pbuf[base + 2] = 1;

    var resp: [16384]u8 = undefined;
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 3]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    var off: usize = RESPONSE_HEADER_SIZE + 2;
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, resp[off..][0..2], .little));
    off += 2;
    const Row = struct { site: []const u8, more: u16 };
    var rows: [3]Row = undefined;
    for (&rows) |*row| {
        off += @sizeOf(schema.Link) + 1;
        const len = std.mem.readInt(u16, resp[off..][0..2], .little);
        row.* = .{ .site = resp[off + 2 ..][0..len], .more = std.mem.readInt(u16, resp[off + 2 + len ..][0..2], .little) };
        off += 4 + len;
    }
    try std.testing.expectEqual(@as(u16, 0), rows[0].more);
    try std.testing.expectEqualStrings("example.com", rows[1].site);
    try std.testing.expectEqual(@as(u16, 2), rows[1].more);
    try std.testing.expectEqualStrings("other.org", rows[2].site);

    pbuf[base + 2] = 2;
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 3]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    pbuf[base + 1] = @intFromEnum(SearchMode.all_terms);
    pbuf[base + 2] = 1;
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), pbuf[0 .. base + 3]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "put_link_vectors (op=37) and hybrid search (op=14 mode 2) frames" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    const link_id = try operations.createLink(db, top_id, "https://bonsai.example", "Bonsai Nursery", "");
    const link = (try operations.getLink(db, link_id)).?;
    const model: u64 = 0xB6E5;

    var put: [10 + VECTOR_WRITE_BYTES]u8 = @splat(0);
    std.mem.writeInt(u64, put[0..8], model, .little);
    std.mem.writeInt(u16, put[8..10], 1, .little);
    std.mem.writeInt(u64, put[10..18], link_id, .little);
    std.mem.writeInt(u64, put[18..26], schema.linkTextFingerprint(link), .little);
    std.mem.writeInt(u32, put[26..30], @bitCast(@as(f32, 1)), .little);

    var resp: [16384]u8 = undefined;
    _ = handlePutLinkVectors(db, &resp, @intFromEnum(Op.put_link_vectors), put[0 .. put.len - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    _ = handlePutLinkVectors(db, &resp, @intFromEnum(Op.put_link_vectors), &put);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little));
    try std.testing.expectEqual(link_id, std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 4 ..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 0), resp[RESPONSE_HEADER_SIZE + 12]);

    std.mem.writeInt(u64, put[0..8], model + 1, .little);
    _ = handlePutLinkVectors(db, &resp, @intFromEnum(Op.put_link_vectors), &put);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.embedding_model_mismatch), resp[6]);

    try operations.loadVectorIndex(db);

    const query = "zzzz";
    var search: [2 + query.len + 4 + 2 + HYBRID_QUERY_BYTES]u8 = @splat(0);
    std.mem.writeInt(u16, search[0..2], query.len, .little);
    @memcpy(search[2..][0..query.len], query);
    std.mem.writeInt(u32, search[2 + query.len ..][0..4], 10, .little);
    const opts = 2 + query.len + 4;
    search[opts] = @intFromEnum(SearchScope.links_only);
    search[opts + 1] = @intFromEnum(SearchMode.hybrid);
    std.mem.writeInt(u64, search[opts + 2 ..][0..8], model, .little);
    std.mem.writeInt(u32, search[opts + 10 ..][0..4], @bitCast(@as(f32, 1)), .little);

    _ = handleSearch(db, &resp, @intFromEnum(Op.search), search[0 .. search.len - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    const len = handleSearch(db, &resp, @intFromEnum(Op.search), &search);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    const links_off = RESPONSE_HEADER_SIZE + 2;
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[links_off..][0..2], .little));
    try std.testing.expectEqual(link_id, std.mem.readInt(u64, resp[links_off + 2 ..][0..8], .little));
    try std.testing.expectEqual(@intFromEnum(MatchField.semantic), resp[links_off + 2 + @sizeOf(schema.Link)]);
    try std.testing.expectEqual(@as(u8, 1), resp[len - 1]);
}

fn hybridSearchFrame(buf: []u8, query: []const u8, model: u64, axis: usize) []const u8 {
    const frame = buf[0 .. 2 + query.len + 4 + 2 + HYBRID_QUERY_BYTES];
    @memset(frame, 0);
    std.mem.writeInt(u16, frame[0..2], @intCast(query.len), .little);
    @memcpy(frame[2..][0..query.len], query);
    std.mem.writeInt(u32, frame[2 + query.len ..][0..4], 10, .little);
    const opts = 2 + query.len + 4;
    frame[opts] = @intFromEnum(SearchScope.both);
    frame[opts + 1] = @intFromEnum(SearchMode.hybrid);
    std.mem.writeInt(u64, frame[opts + 2 ..][0..8], model, .little);
    std.mem.writeInt(u32, frame[opts + 10 + axis * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
    return frame;
}

fn categoryVectorFrame(buf: []u8, model: u64, category_id: u64, axis: usize) []const u8 {
    const frame = buf[0 .. 10 + CATEGORY_VECTOR_WRITE_BYTES];
    @memset(frame, 0);
    std.mem.writeInt(u64, frame[0..8], model, .little);
    std.mem.writeInt(u16, frame[8..10], 1, .little);
    std.mem.writeInt(u64, frame[10..18], category_id, .little);
    std.mem.writeInt(u32, frame[18 + axis * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
    return frame;
}

test "put_category_vectors (op=41) stores a vector for a known category and refuses an unknown one or a short frame" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    const model: u64 = 0xB6E5;
    var put_buf: [10 + CATEGORY_VECTOR_WRITE_BYTES]u8 = undefined;
    var resp: [16384]u8 = undefined;

    const put = categoryVectorFrame(&put_buf, model, top_id, 0);
    _ = handlePutCategoryVectors(db, &resp, @intFromEnum(Op.put_category_vectors), put[0 .. put.len - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    _ = handlePutCategoryVectors(db, &resp, @intFromEnum(Op.put_category_vectors), put);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little));
    try std.testing.expectEqual(top_id, std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 4 ..][0..8], .little));
    try std.testing.expectEqual(@as(u8, 0), resp[RESPONSE_HEADER_SIZE + 12]);

    const unknown = categoryVectorFrame(&put_buf, model, top_id + 100, 0);
    _ = handlePutCategoryVectors(db, &resp, @intFromEnum(Op.put_category_vectors), unknown);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little));
    try std.testing.expectEqual(@intFromEnum(operations.VectorWriteResult.not_found), resp[RESPONSE_HEADER_SIZE + 12]);
}

test "hybrid search finds a link through its category's meaning when neither its text nor its own vector matches" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top_id = try operations.createCategory(db, 0, "Top", "top", "");
    const jazz_id = try operations.createCategory(db, top_id, "Jazz", "jazz", "");
    const players_id = try operations.createCategory(db, jazz_id, "Players", "players", "");
    const pets_id = try operations.createCategory(db, top_id, "Pets", "pets", "");
    const damas_id = try operations.createLink(db, players_id, "https://damas.example", "Damas", "");
    const kennel_id = try operations.createLink(db, pets_id, "https://kennel.example", "Kennel", "");
    const model: u64 = 0xB6E5;

    var link_writes: [2]operations.VectorWrite = undefined;
    for (&link_writes, [_]u64{ damas_id, kennel_id }, [_]usize{ 1, 2 }) |*w, id, axis| {
        const link = (try operations.getLink(db, id)).?;
        w.* = .{ .link_id = id, .text_fingerprint = schema.linkTextFingerprint(link), .embedding = @splat(0) };
        w.embedding[axis] = 1;
    }
    link_writes[1].embedding[0] = 0.5;
    var link_results: [2]operations.VectorWriteResult = undefined;
    try operations.putLinkVectors(db, model, &link_writes, &link_results);

    var put_buf: [10 + CATEGORY_VECTOR_WRITE_BYTES]u8 = undefined;
    var resp: [16384]u8 = undefined;
    _ = handlePutCategoryVectors(db, &resp, @intFromEnum(Op.put_category_vectors), categoryVectorFrame(&put_buf, model, jazz_id, 0));
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    try operations.loadVectorIndex(db);
    try operations.loadCategoryVectorIndex(db);
    try operations.loadFactsIndex(db);

    var search_buf: [2 + 16 + 4 + 2 + HYBRID_QUERY_BYTES]u8 = undefined;
    _ = handleSearch(db, &resp, @intFromEnum(Op.search), hybridSearchFrame(&search_buf, "saxophonists", model, 0));
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);

    const cat_count = std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 1), cat_count);
    try std.testing.expectEqual(jazz_id, std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 2 ..][0..8], .little));

    const links_off = RESPONSE_HEADER_SIZE + 2 + @sizeOf(schema.Category);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, resp[links_off..][0..2], .little));
    try std.testing.expectEqual(damas_id, std.mem.readInt(u64, resp[links_off + 2 ..][0..8], .little));
}

fn queryLinksRequest(buf: []u8, category_id: u64, domain: []const u8, country: []const u8, options: QueryLinksOptions, words: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeInt(u64, category_id, .little);
    for ([_][]const u8{ domain, country }) |text| {
        try w.writeInt(u16, @intCast(text.len), .little);
        try w.writeAll(text);
    }
    try w.writeInt(u64, @bitCast(options), .little);
    for ([_][]const u8{ words, "" }) |text| {
        try w.writeInt(u16, @intCast(text.len), .little);
        try w.writeAll(text);
    }
    try w.writeInt(u64, 0, .little);
    return buf[0..w.end];
}

test "query_links (op=38) answers counts, groups and a hydrated page, and refuses bad options" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try operations.createCategory(db, 0, "Top", "top", "");
    const arts = try operations.createCategory(db, top, "Arts", "arts", "");
    const subdomain_site = try operations.createLink(db, arts, "http://samvak.tripod.com/", "Samvak", "");
    _ = try operations.createLink(db, arts, "http://members.tripod.com/~fuzzy/", "Fuzzy", "");
    _ = try operations.createLink(db, arts, "http://www.uet.edu.pk/", "UET", "");

    const op = @intFromEnum(Op.query_links);
    const by_site: QueryLinksOptions = .{ .status = 1, .group_by = @intFromEnum(facts_index.GroupBy.site), .group_limit = 10, .limit = 10 };
    var req_buf: [256]u8 = undefined;
    var resp: [16384]u8 = undefined;
    const body = RESPONSE_HEADER_SIZE;

    _ = handleQueryLinks(db, &resp, op, try queryLinksRequest(&req_buf, arts, "tripod.com", "", by_site, ""));
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u8, 0), resp[body]);

    try operations.loadFactsIndex(db);
    const len = handleQueryLinks(db, &resp, op, try queryLinksRequest(&req_buf, arts, ".Tripod.com", "", by_site, ""));
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u8, 1), resp[body]);
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, resp[body + 1 ..][0..8], .little));
    try std.testing.expectEqual(@as(u64, 2), std.mem.readInt(u64, resp[body + 9 ..][0..8], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, resp[8..10], .little));

    var off: usize = body + 33;
    const group_count = std.mem.readInt(u16, resp[off..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 2), group_count);
    off += 2;
    for (0..group_count) |_| off += 2 + std.mem.readInt(u16, resp[off..][0..2], .little) + 24;

    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, resp[off..][0..2], .little));
    off += 2;
    try std.testing.expectEqual(subdomain_site, std.mem.readInt(u64, resp[off..][0..8], .little));
    off += @sizeOf(schema.Link);
    const site_len = std.mem.readInt(u16, resp[off..][0..2], .little);
    try std.testing.expectEqualStrings("samvak.tripod.com", resp[off + 2 ..][0..site_len]);
    const row_tail = 4 + 2 + 1;
    try std.testing.expectEqual(len - 8, off + 2 + site_len + row_tail + @sizeOf(schema.Link) + 2 + "members.tripod.com/~fuzzy".len + row_tail);

    _ = handleQueryLinks(db, &resp, op, try queryLinksRequest(&req_buf, 0, "", "ZZ", by_site, ""));
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    _ = handleQueryLinks(db, &resp, op, try queryLinksRequest(&req_buf, 0, "", "", .{ .limit = QUERY_LINKS_MAX_ROWS + 1 }, ""));
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    _ = handleQueryLinks(db, &resp, op, try queryLinksRequest(&req_buf, 0, "", "", .{ .group_by = 9 }, ""));
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    _ = handleQueryLinks(db, &resp, op, try queryLinksRequest(&req_buf, 0, "", "", .{}, "a"));
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "match_names (op=40) answers each phrase with its largest same-named category and refuses a short frame" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    try operations.loadFactsIndex(db);

    const top = try operations.createCategory(db, 0, "Top", "top", "");
    const arts = try operations.createCategory(db, top, "Arts", "arts", "");
    _ = try operations.createLink(db, arts, "http://one.example.com/", "One", "");

    var req: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&req);
    try w.writeInt(u16, 2, .little);
    for ([_][]const u8{ "Art", "no such thing" }) |phrase| {
        try w.writeInt(u16, @intCast(phrase.len), .little);
        try w.writeAll(phrase);
    }

    var resp: [512]u8 = undefined;
    const op = @intFromEnum(Op.match_names);
    _ = handleMatchNames(db, &resp, op, req[0 .. w.end - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    _ = handleMatchNames(db, &resp, op, req[0..w.end]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    const body = resp[RESPONSE_HEADER_SIZE..];
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, body[1..3], .little));
    try std.testing.expectEqual(arts, std.mem.readInt(u64, body[3..11], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[12..20], .little));
}

test "put_link_entities (op=39) answers per-item codes and query_links (op=38) filters on what it stored" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();
    try operations.loadFactsIndex(db);

    const top = try operations.createCategory(db, 0, "Top", "top", "");
    const link_id = try operations.createLink(db, top, "http://www.breslov.org/", "Breslov", "Rebbe Nachman of Breslov");
    const link = (try operations.getLink(db, link_id)).?;
    const facts = "\x01\x04\x00\x01UA\x01\x0dRebbe Nachman\x00";

    var put: [2 + 18 + facts.len + 18 + 3]u8 = undefined;
    var w: std.Io.Writer = .fixed(&put);
    try w.writeInt(u16, 2, .little);
    try w.writeInt(u64, link_id, .little);
    try w.writeInt(u64, schema.linkTextFingerprint(link), .little);
    try w.writeInt(u16, facts.len, .little);
    try w.writeAll(facts);
    try w.writeInt(u64, link_id, .little);
    try w.writeInt(u64, schema.linkTextFingerprint(link), .little);
    try w.writeInt(u16, 3, .little);
    try w.writeAll("\x02\x00\x00");

    var resp: [16384]u8 = undefined;
    _ = handlePutLinkEntities(db, &resp, @intFromEnum(Op.put_link_entities), put[0 .. put.len - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);

    _ = handlePutLinkEntities(db, &resp, @intFromEnum(Op.put_link_entities), &put);
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little));
    try std.testing.expectEqual(@as(u8, 0), resp[RESPONSE_HEADER_SIZE + 4 + 8]);
    try std.testing.expectEqual(@as(u8, 3), resp[RESPONSE_HEADER_SIZE + 4 + 9 + 8]);

    var req_buf: [256]u8 = undefined;
    const judaism: u16 = @as(u16, 1) << @intFromEnum(entities.Religion.judaism);
    _ = handleQueryLinks(db, &resp, @intFromEnum(Op.query_links), try queryLinksRequest(&req_buf, 0, "", "UA", .{ .status = 1, .religions = judaism, .limit = 5 }, ""));
    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, resp[RESPONSE_HEADER_SIZE + 1 ..][0..8], .little));

    _ = handleQueryLinks(db, &resp, @intFromEnum(Op.query_links), try queryLinksRequest(&req_buf, 0, "", "", .{ .religions = 0x8000 }, ""));
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "list_all_links with out-of-range status returns invalid" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 0, .little);
    std.mem.writeInt(u32, payload[4..8], 10, .little);
    payload[8] = 99;

    var resp: [64]u8 = undefined;
    const reply_len = handleListLinks(.none, operations.listAllLinks, db, &resp, @intFromEnum(Op.list_all_links), &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "update_link_status: out-of-range status returns invalid + unsupported_order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 1, .little);
    payload[8] = 42;

    var resp: [64]u8 = undefined;
    const reply_len = handleUpdateLinkStatus(db, &resp, @intFromEnum(Op.update_link_status), &payload);
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.unsupported_order), resp[6]);
}

test "get_categories_by_ids (29): mix of hits and misses returns only the hits" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const a_id = try operations.createCategory(db, 0, "Alpha", "alpha", "");
    const b_id = try operations.createCategory(db, 0, "Beta", "beta", "");

    const want: u16 = 3;
    var payload: [2 + 3 * 8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], want, .little);
    std.mem.writeInt(u64, payload[2..][0..8], a_id, .little);
    std.mem.writeInt(u64, payload[10..][0..8], 999_999, .little);
    std.mem.writeInt(u64, payload[18..][0..8], b_id, .little);

    var resp: [4096]u8 = undefined;
    const reply_len = handleGetCategoriesByIds(
        db,
        &resp,
        @intFromEnum(Op.get_categories_by_ids),
        &payload,
    );

    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    const count = std.mem.readInt(u16, resp[8..10], .little);
    try std.testing.expectEqual(@as(u16, 2), count);

    const cat_size = @sizeOf(schema.Category);
    try std.testing.expectEqual(
        @as(usize, RESPONSE_HEADER_SIZE + 2 * cat_size),
        reply_len,
    );

    const cat0 = std.mem.bytesToValue(
        schema.Category,
        resp[RESPONSE_HEADER_SIZE..][0..cat_size],
    );
    const cat1 = std.mem.bytesToValue(
        schema.Category,
        resp[RESPONSE_HEADER_SIZE + cat_size ..][0..cat_size],
    );
    try std.testing.expectEqual(a_id, cat0.id);
    try std.testing.expectEqual(b_id, cat1.id);
}

test "get_categories_by_ids (29): count > GET_CATEGORIES_BY_IDS_MAX returns invalid" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], GET_CATEGORIES_BY_IDS_MAX + 1, .little);
    var resp: [128]u8 = undefined;
    const reply_len = handleGetCategoriesByIds(
        db,
        &resp,
        @intFromEnum(Op.get_categories_by_ids),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "get_categories_by_ids (29): truncated payload returns invalid" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    var payload: [2 + 8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 3, .little);
    std.mem.writeInt(u64, payload[2..][0..8], 1, .little);
    var resp: [128]u8 = undefined;
    const reply_len = handleGetCategoriesByIds(
        db,
        &resp,
        @intFromEnum(Op.get_categories_by_ids),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, RESPONSE_HEADER_SIZE), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), resp[5]);
}

test "breadcrumbs_by_ids (30): returns root->leaf inclusive chain per id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try operations.createCategory(db, 0, "Top", "top", "");
    const arts = try operations.createCategory(db, top, "Arts", "arts", "");
    const music = try operations.createCategory(db, arts, "Music", "music", "");

    var payload: [2 + 8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 1, .little);
    std.mem.writeInt(u64, payload[2..][0..8], music, .little);

    var resp: [8192]u8 = undefined;
    const reply_len = handleBreadcrumbsByIds(db, &resp, @intFromEnum(Op.breadcrumbs_by_ids), &payload);

    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[8..10], .little));

    var off: usize = RESPONSE_HEADER_SIZE;
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, resp[off..][0..2], .little));
    off += 2;
    try std.testing.expectEqual(top, std.mem.readInt(u64, resp[off..][0..8], .little));
    off += CRUMB_SIZE;
    try std.testing.expectEqual(arts, std.mem.readInt(u64, resp[off..][0..8], .little));
    off += CRUMB_SIZE;
    try std.testing.expectEqual(music, std.mem.readInt(u64, resp[off..][0..8], .little));
    off += CRUMB_SIZE;
    try std.testing.expectEqual(off, reply_len);
}

test "breadcrumbs_by_ids (30): unresolved id yields an empty group, preserving order" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try operations.createCategory(db, 0, "Top", "top", "");

    var payload: [2 + 16]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 2, .little);
    std.mem.writeInt(u64, payload[2..][0..8], 999_999, .little);
    std.mem.writeInt(u64, payload[10..][0..8], top, .little);

    var resp: [8192]u8 = undefined;
    _ = handleBreadcrumbsByIds(db, &resp, @intFromEnum(Op.breadcrumbs_by_ids), &payload);

    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, resp[8..10], .little));
    var off: usize = RESPONSE_HEADER_SIZE;
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, resp[off..][0..2], .little));
    off += 2;
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[off..][0..2], .little));
}

test "breadcrumbs_by_ids (30): a reply too small for every chain answers a prefix, never an empty chain for a known id" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try Directory.openTestInstance(allocator, &tmp);
    defer db.deinitTestInstance();

    const top = try operations.createCategory(db, 0, "Top", "top", "");
    const arts = try operations.createCategory(db, top, "Arts", "arts", "");
    const music = try operations.createCategory(db, arts, "Music", "music", "");

    var payload: [2 + 16]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 2, .little);
    std.mem.writeInt(u64, payload[2..][0..8], music, .little);
    std.mem.writeInt(u64, payload[10..][0..8], music, .little);

    var resp: [RESPONSE_HEADER_SIZE + 2 + 3 * CRUMB_SIZE + 2 + CRUMB_SIZE]u8 = undefined;
    const reply_len = handleBreadcrumbsByIds(db, &resp, @intFromEnum(Op.breadcrumbs_by_ids), &payload);

    try std.testing.expectEqual(@intFromEnum(Status.ok), resp[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, resp[8..10], .little));
    try std.testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, resp[RESPONSE_HEADER_SIZE..][0..2], .little));
    try std.testing.expectEqual(RESPONSE_HEADER_SIZE + 2 + 3 * CRUMB_SIZE, reply_len);
}

fn fuzzProcessFramesOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = Directory.openTestInstance(gpa.allocator(), &tmp) catch return;
    defer db.deinitTestInstance();

    var bp: zigstore.connection.BufferPair = .{};
    var conn = zigstore.connection.Connection{ .phase = .reading_request, .buf = &bp };
    conn.bytes_read = smith.slice(&bp.request_buf);
    protocol.processFrames(db, &conn, &Directory.dispatch, db.op_latency, RESPONSE_RESERVE);
}

test "fuzz: processFrames tolerates arbitrary request frames" {
    try std.testing.fuzz({}, fuzzProcessFramesOne, .{
        .corpus = &.{
            &.{},
            &[_]u8{ 8, 0, 0, 0, 255, 0, 0, 0 },
            &[_]u8{ 14, 0, 0, 0, 14, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0 },
            &[_]u8{ 10, 0, 0, 0, 11, 0, 0, 0, 0xFF, 0xFF },
        },
    });
}
