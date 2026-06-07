const std = @import("std");
const zigstore = @import("zigstore");
const schema = @import("schema.zig");
const Directory = @import("directory.zig").Directory;
const Stats = @import("directory.zig").Stats;
const operations = @import("operations/operations.zig");
const conn_mod = @import("connection.zig");

const log = std.log.scoped(.binary);

pub const REQUEST_HEADER_SIZE: usize = 8;

pub const RESPONSE_HEADER_SIZE: usize = 10;

pub const HEADER_SIZE: usize = REQUEST_HEADER_SIZE;

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
};

pub const StatusPair = struct {
    status: Status,
    sub_status: SubStatus,
};

pub fn mapErrorWithSubStatus(err: anyerror) StatusPair {
    return switch (err) {
        error.DuplicateUrl => .{ .status = .duplicate, .sub_status = .duplicate_url },
        error.CategoryNotFound => .{ .status = .category_not_found, .sub_status = .none },
        error.ParentNotFound => .{ .status = .category_not_found, .sub_status = .parent_not_found },
        error.LinkNotFound => .{ .status = .not_found, .sub_status = .none },
        error.CategoryHasChildren => .{ .status = .has_children, .sub_status = .none },
        error.CircularHierarchy => .{ .status = .circular, .sub_status = .none },
        error.FieldTooLong => .{ .status = .invalid, .sub_status = .field_too_long },
        error.BufferTooSmall => .{ .status = .invalid, .sub_status = .buffer_too_small },
        error.PathTooDeep => .{ .status = .invalid, .sub_status = .path_too_deep },
        error.InvalidSlug => .{ .status = .invalid, .sub_status = .invalid_slug },
        error.UnsupportedOrder => .{ .status = .invalid, .sub_status = .unsupported_order },
        error.OffsetTooLarge => .{ .status = .invalid, .sub_status = .offset_too_large },
        error.SnapshotInProgress => .{ .status = .err, .sub_status = .already_in_progress },
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
    bulk_update_link_status = 34,
    bulk_delete_links = 35,
    counts_by_status = 36,
    ping = 255,
};

pub const GET_CATEGORIES_BY_IDS_MAX: u16 = 200;

pub const BULK_IMPORT_MAX_BYTES: usize = 60 * 1024;
pub const BULK_IMPORT_MAX_ITEMS: u32 = 50_000;
pub const BULK_IMPORT_CHUNK: u32 = 500;

fn ReadResult(comptime fields: []const struct { []const u8, type }) type {
    var sf: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |f, i| {
        sf[i] = .{
            .name = @ptrCast(f[0]),
            .type = f[1],
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(f[1]),
        };
    }
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &sf,
        .decls = &.{},
        .is_tuple = false,
    } });
}

fn ParsedPayload(comptime fields: []const struct { []const u8, type }) type {
    return struct {
        result: ReadResult(fields),
        rest: []const u8,
    };
}

fn parsePayload(
    comptime fields: []const struct { []const u8, type },
    data: []const u8,
) ?ParsedPayload(fields) {
    var off: usize = 0;
    var result: ReadResult(fields) = undefined;

    inline for (fields) |f| {
        const name: [:0]const u8 = @ptrCast(f[0]);
        const T = f[1];

        if (T == u64) {
            if (off + 8 > data.len) return null;
            @field(result, name) = std.mem.readInt(u64, data[off..][0..8], .little);
            off += 8;
        } else if (T == u32) {
            if (off + 4 > data.len) return null;
            @field(result, name) = std.mem.readInt(u32, data[off..][0..4], .little);
            off += 4;
        } else if (T == []const u8) {
            if (off + 2 > data.len) return null;
            const len = std.mem.readInt(u16, data[off..][0..2], .little);
            off += 2;
            if (off + len > data.len) return null;
            @field(result, name) = data[off..][0..len];
            off += len;
        } else {
            @compileError("parsePayload: unsupported type for field '" ++ f[0] ++ "'");
        }
    }

    return .{ .result = result, .rest = data[off..] };
}

fn advancePayload(
    comptime fields: []const struct { []const u8, type },
    data: []const u8,
) ?[]const u8 {
    var off: usize = 0;
    inline for (fields) |f| {
        const T = f[1];
        if (T == u64) {
            if (off + 8 > data.len) return null;
            off += 8;
        } else if (T == u32) {
            if (off + 4 > data.len) return null;
            off += 4;
        } else if (T == []const u8) {
            if (off + 2 > data.len) return null;
            const len = std.mem.readInt(u16, data[off..][0..2], .little);
            off += 2;
            if (off + len > data.len) return null;
            off += len;
        }
    }
    return data[off..];
}

fn writeResponseHeader(
    buf: []u8,
    total_len: u32,
    op: u8,
    status: Status,
    sub_status: SubStatus,
    count: u16,
) void {
    std.mem.writeInt(u32, buf[0..4], total_len, .little);
    buf[4] = op;
    buf[5] = @intFromEnum(status);
    buf[6] = @intFromEnum(sub_status);
    buf[7] = 0;
    std.mem.writeInt(u16, buf[8..10], count, .little);
}

fn writeResp(buf: []u8, op: u8, status: Status, count: u16, payload: []const u8) usize {
    const total: usize = RESPONSE_HEADER_SIZE + payload.len;
    if (buf.len < total) {
        return 0;
    }
    writeResponseHeader(buf, @intCast(total), op, status, .none, count);
    if (payload.len > 0) @memcpy(buf[RESPONSE_HEADER_SIZE..][0..payload.len], payload);
    return total;
}

fn writeErrorResp(buf: []u8, op: u8, status: Status) usize {
    return writeErrorRespSub(buf, op, status, .none);
}

fn writeErrorRespSub(buf: []u8, op: u8, status: Status, sub: SubStatus) usize {
    const total: u32 = @intCast(RESPONSE_HEADER_SIZE);
    writeResponseHeader(buf, total, op, status, sub, 0);
    return total;
}

fn writeMappedError(buf: []u8, op: u8, err: anyerror) usize {
    const pair = mapErrorWithSubStatus(err);
    return writeErrorRespSub(buf, op, pair.status, pair.sub_status);
}

fn mapError(err: anyerror) Status {
    return mapErrorWithSubStatus(err).status;
}

fn BatchCreateHandler(
    comptime fields: []const struct { []const u8, type },
    comptime op_code: u8,
    comptime createFn: anytype,
) type {
    return struct {
        fn handle(db: *Directory, resp: []u8, payload: []const u8, count: u16) usize {
            const ITEM_BYTES: usize = 10;
            if (resp.len < RESPONSE_HEADER_SIZE) return 0;

            var off: usize = RESPONSE_HEADER_SIZE;
            var data = payload;
            var written: u16 = 0;

            for (0..count) |_| {
                if (off + ITEM_BYTES > resp.len) break;

                const parsed = parsePayload(fields, data);
                if (parsed) |p| {
                    const r = p.result;
                    const id = @call(.auto, createFn, .{
                        db,
                        @field(r, fields[0][0]),
                        @field(r, fields[1][0]),
                        @field(r, fields[2][0]),
                        @field(r, fields[3][0]),
                    }) catch |err| {
                        const pair = mapErrorWithSubStatus(err);
                        resp[off] = @intFromEnum(pair.status);
                        resp[off + 1] = @intFromEnum(pair.sub_status);
                        off += 2;
                        @memset(resp[off..][0..8], 0);
                        off += 8;
                        written += 1;
                        data = advancePayload(fields, data) orelse &.{};
                        continue;
                    };
                    resp[off] = @intFromEnum(Status.ok);
                    resp[off + 1] = @intFromEnum(SubStatus.none);
                    off += 2;
                    std.mem.writeInt(u64, resp[off..][0..8], id, .little);
                    off += 8;
                    written += 1;
                    data = p.rest;
                } else {
                    resp[off] = @intFromEnum(Status.invalid);
                    resp[off + 1] = @intFromEnum(SubStatus.none);
                    off += 2;
                    @memset(resp[off..][0..8], 0);
                    off += 8;
                    written += 1;
                    break;
                }
            }

            writeResponseHeader(resp, @intCast(off), op_code, .ok, .none, written);
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

const RESPONSE_RESERVE = RESPONSE_HEADER_SIZE + @as(usize, GET_CATEGORIES_BY_IDS_MAX) * @sizeOf(schema.Category);

fn pipelineHasRoom(resp_off: usize, buf_len: usize) bool {
    return resp_off == 0 or buf_len - resp_off >= RESPONSE_RESERVE;
}

pub fn processFrames(
    db: *Directory,
    conn: *conn_mod.Connection,
) void {
    const bp = conn.buf orelse return;
    const data = bp.request_buf[0..conn.bytes_read];
    var consumed: usize = 0;
    var resp_off: usize = 0;

    while (consumed + REQUEST_HEADER_SIZE <= data.len) {
        if (!pipelineHasRoom(resp_off, bp.response_buf.len)) break;
        if (resp_off + RESPONSE_HEADER_SIZE > bp.response_buf.len) break;

        const frame = data[consumed..];
        const total_len = std.mem.readInt(u32, frame[0..4], .little);

        if (total_len > data.len - consumed) break;

        const op_byte = frame[4];

        if (total_len < REQUEST_HEADER_SIZE) {
            resp_off += writeErrorResp(bp.response_buf[resp_off..], op_byte, .invalid);
            consumed += REQUEST_HEADER_SIZE;
            continue;
        }

        const count = std.mem.readInt(u16, frame[6..8], .little);
        const payload = frame[REQUEST_HEADER_SIZE..total_len];

        const op: Op = std.meta.intToEnum(Op, op_byte) catch {
            resp_off += writeErrorResp(bp.response_buf[resp_off..], op_byte, .invalid);
            consumed += total_len;
            continue;
        };

        const t0 = std.time.nanoTimestamp();
        const written = dispatch(db, op, op_byte, payload, count, bp.response_buf[resp_off..]);
        const t1 = std.time.nanoTimestamp();
        const dt: u64 = if (t1 > t0) @intCast(t1 - t0) else 0;
        db.op_latency[op_byte].recordValue(dt);

        if (written == 0) break;
        resp_off += written;
        consumed += total_len;
    }

    if (consumed > 0) {
        const remaining = conn.bytes_read - consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, bp.request_buf[0..remaining], bp.request_buf[consumed..conn.bytes_read]);
        }
        conn.bytes_read = remaining;
    }

    conn.response_len = resp_off;
}

fn dispatch(db: *Directory, op: Op, op_byte: u8, payload: []const u8, count: u16, resp: []u8) usize {
    return switch (op) {
        .ping => writeResp(resp, op_byte, .ok, 0, &.{}),
        .create_link => CreateLinks.handle(db, resp, payload, count),
        .create_category => CreateCategories.handle(db, resp, payload, count),
        .get_link => handleGet(schema.Link, db, resp, op_byte, payload, operations.getLink),
        .get_category => handleGet(schema.Category, db, resp, op_byte, payload, operations.getCategory),
        .get_categories_by_ids => handleGetCategoriesByIds(db, resp, op_byte, payload),
        .delete_link => handleDelete(db, resp, op_byte, payload, operations.deleteLink),
        .delete_category => handleDelete(db, resp, op_byte, payload, operations.deleteCategory),
        .update_category => handleBitmaskUpdate(operations.updateCategory, db, resp, op_byte, payload),
        .move_category => handleMoveCategory(db, resp, op_byte, payload),
        .move_link => handleMoveLink(db, resp, op_byte, payload),
        .update_link => handleBitmaskUpdate(operations.updateLink, db, resp, op_byte, payload),
        .list_root_categories => handleListRootCategories(db, resp, op_byte, payload),
        .list_children => handleListChildren(db, resp, op_byte, payload),
        .list_links => handleListLinks(db, resp, op_byte, payload),
        .list_all_links => handleListAllLinks(db, resp, op_byte, payload),
        .list_subtree_links => handleListSubtreeLinks(db, resp, op_byte, payload),
        .index_health => handleIndexHealth(db, resp, op_byte),
        .run_verifier => handleRunVerifier(db, resp, op_byte),
        .rebuild_index => handleRebuildIndex(db, resp, op_byte),
        .snapshot => handleSnapshot(db, resp, op_byte),
        .op_latency_stats => handleOpLatencyStats(db, resp, op_byte),
        .bulk_import => handleBulkImport(db, resp, op_byte, payload, count),
        .create_submission => handleCreateSubmission(db, resp, op_byte, payload),
        .update_link_status => handleUpdateLinkStatus(db, resp, op_byte, payload),
        .list_links_by_submitter => handleListLinksBySubmitter(db, resp, op_byte, payload),
        .browse_path => handleBrowsePath(db, resp, op_byte, payload),
        .search => handleSearch(db, resp, op_byte, payload),
        .stats => handleStats(db, resp, op_byte),
        .bulk_update_link_status => handleBulkUpdateLinkStatus(db, resp, op_byte, payload),
        .bulk_delete_links => handleBulkDeleteLinks(db, resp, op_byte, payload),
        .counts_by_status => handleCountsByStatus(db, resp, op_byte),
    };
}

const MAX_SUBTREE_OFFSET: u32 = 5000;
const MAX_SUBTREE_LIMIT: u32 = 100;
const DEFAULT_SUBTREE_LIMIT: u32 = 50;

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
            const bytes = std.mem.asBytes(&cat);
            @memcpy(resp[off..][0..bytes.len], bytes);
            off += bytes.len;
            found += 1;
        }
    }

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, found);
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

fn handleMoveCategory(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 16) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const new_parent = std.mem.readInt(u64, payload[8..16], .little);
    operations.moveCategory(db, id, new_parent) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeResp(resp, op_byte, .ok, 0, &.{});
}

fn handleMoveLink(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 16) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const new_cat = std.mem.readInt(u64, payload[8..16], .little);
    operations.moveLink(db, id, new_cat) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeResp(resp, op_byte, .ok, 0, &.{});
}

fn handleListRootCategories(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 8) return writeErrorResp(resp, op_byte, .invalid);
    const offset = std.mem.readInt(u32, payload[0..4], .little);
    const limit = std.mem.readInt(u32, payload[4..8], .little);
    const N = comptime defaultListBufLen(schema.Category);
    var buf: [N]schema.Category = undefined;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    const items = operations.listChildren(db, 0, offset, max, &buf) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeRowList(schema.Category, resp, op_byte, items);
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

    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());

    const MIN_FRAME = RESPONSE_HEADER_SIZE + @sizeOf(schema.Category) + 2 + 2 + 8;
    if (resp.len < MIN_FRAME) return writeErrorResp(resp, op_byte, .err);

    var off: usize = RESPONSE_HEADER_SIZE;

    const cat_bytes = std.mem.asBytes(&cat);
    @memcpy(resp[off..][0..cat_bytes.len], cat_bytes);
    off += cat_bytes.len;

    var anc_buf: [64]schema.Category = undefined;
    const ancestors = operations.walkAncestors(db, cat_id, &anc_buf) catch
        return writeErrorResp(resp, op_byte, .err);
    const anc_count_off = off;
    off += 2;
    var anc_written: u16 = 0;
    for (ancestors) |a| {
        if (off + @sizeOf(schema.Category) + 2 + 8 > resp.len) break;
        const ab = std.mem.asBytes(&a);
        @memcpy(resp[off..][0..ab.len], ab);
        off += ab.len;
        anc_written += 1;
    }
    std.mem.writeInt(u16, resp[anc_count_off..][0..2], anc_written, .little);

    var children_buf: [100]schema.Category = undefined;
    const children = operations.listChildren(db, cat_id, 0, 100, &children_buf) catch
        return writeErrorResp(resp, op_byte, .err);
    const child_count_off = off;
    off += 2;
    var children_written: u16 = 0;
    for (children) |child| {
        if (off + @sizeOf(schema.Category) + 8 > resp.len) break;
        const cb = std.mem.asBytes(&child);
        @memcpy(resp[off..][0..cb.len], cb);
        off += cb.len;
        children_written += 1;
    }
    std.mem.writeInt(u16, resp[child_count_off..][0..2], children_written, .little);

    const subtree = @import("subtree.zig");
    const total_links: u64 = if (db.subtree_cache.getLinkCount(cat_id)) |hit|
        hit
    else blk: {
        const desc = subtree.collectDescendantsCached(
            db.cat_by_parent(),
            cat_id,
            &db.subtree_cache,
            db.allocator,
        ) catch break :blk 0;
        defer db.allocator.free(desc);
        const t = subtree.countSubtreeLinks(db.link_by_category(), desc, db.allocator) catch break :blk 0;
        db.subtree_cache.putLinkCount(cat_id, t) catch {};
        break :blk t;
    };
    std.mem.writeInt(u64, resp[off..][0..8], total_links, .little);
    off += 8;

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

fn handleListChildren(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 16) return writeErrorResp(resp, op_byte, .invalid);
    const parent_id = std.mem.readInt(u64, payload[0..8], .little);
    const offset = std.mem.readInt(u32, payload[8..12], .little);
    const limit = std.mem.readInt(u32, payload[12..16], .little);
    const N = comptime defaultListBufLen(schema.Category);
    var buf: [N]schema.Category = undefined;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    const items = operations.listChildren(db, parent_id, offset, max, &buf) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeRowList(schema.Category, resp, op_byte, items);
}

fn handleListLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 16) return writeErrorResp(resp, op_byte, .invalid);
    const cat_id = std.mem.readInt(u64, payload[0..8], .little);
    const offset = std.mem.readInt(u32, payload[8..12], .little);
    const limit = std.mem.readInt(u32, payload[12..16], .little);
    const extras = readOptionalListExtras(payload, 16) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    const N = comptime defaultListBufLen(schema.Link);
    var buf: [N]schema.Link = undefined;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    const page = operations.listLinks(db, cat_id, offset, max, &buf, extras.status, extras.after_id) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeLinkPage(resp, op_byte, page);
}

fn handleListAllLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 8) return writeErrorResp(resp, op_byte, .invalid);
    const offset = std.mem.readInt(u32, payload[0..4], .little);
    const limit = std.mem.readInt(u32, payload[4..8], .little);
    const extras = readOptionalListExtras(payload, 8) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    const N = comptime defaultListBufLen(schema.Link);
    var buf: [N]schema.Link = undefined;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    const page = operations.listAllLinks(db, offset, max, &buf, extras.status, extras.after_id) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeLinkPage(resp, op_byte, page);
}

fn handleListLinksBySubmitter(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 16) return writeErrorResp(resp, op_byte, .invalid);
    const submitter_id = std.mem.readInt(u64, payload[0..8], .little);
    const offset = std.mem.readInt(u32, payload[8..12], .little);
    const limit = std.mem.readInt(u32, payload[12..16], .little);
    const extras = readOptionalListExtras(payload, 16) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    const N = comptime defaultListBufLen(schema.Link);
    var buf: [N]schema.Link = undefined;
    const max = @min(limit, @as(u32, @intCast(buf.len)));
    const page = operations.listLinksBySubmitter(db, submitter_id, offset, max, &buf, extras.status, extras.after_id) catch |err| {
        return writeMappedError(resp, op_byte, err);
    };
    return writeLinkPage(resp, op_byte, page);
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
            if (s > 2) break :blk null;
            break :blk OptionalListExtras{ .status = s, .after_id = 0 };
        },
        9 => blk: {
            const s = tail[0];
            const status: ?u8 = if (s == NO_STATUS_FILTER) null else if (s > 2) break :blk null else s;
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
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, written);
    return off;
}

fn handleListSubtreeLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 17) return writeErrorResp(resp, op_byte, .invalid);
    const req = ListSubtreeLinksRequest.parse(payload);
    req.validate() catch |err| return writeMappedError(resp, op_byte, err);
    const extras = readOptionalListExtras(payload, 17) orelse {
        return writeErrorResp(resp, op_byte, .invalid);
    };
    const status_filter = extras.status;
    const cursor_mode = extras.after_id > 0;

    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    const subtree = @import("subtree.zig");

    const descendants = subtree.collectDescendantsCached(
        db.cat_by_parent(),
        req.cat_id,
        &db.subtree_cache,
        db.allocator,
    ) catch |err| return writeMappedError(resp, op_byte, err);
    defer db.allocator.free(descendants);

    const limit = req.effectiveLimit();

    const min_frame: usize = RESPONSE_HEADER_SIZE + 4 + 8 + 8;
    if (resp.len < min_frame) return writeErrorResp(resp, op_byte, .err);

    const MAX_SUBTREE_FETCH: u32 = 10_000;
    const overprovision_factor: u32 = 2;
    const full_scan = cursor_mode or status_filter != null;
    const fetch_offset: u32 = if (full_scan) 0 else req.offset;
    const fetch_limit: u32 = if (full_scan) MAX_SUBTREE_FETCH else limit *| overprovision_factor;

    const scan_threshold: u32 = db.config.subtree_scan_threshold;
    const slice = if (descendants.len > scan_threshold)
        subtree.listSubtreeLinkIdsScan(
            db.link_by_category(),
            descendants,
            fetch_offset,
            fetch_limit,
            db.allocator,
        ) catch |err| return writeMappedError(resp, op_byte, err)
    else
        subtree.listSubtreeLinkIds(
            db.link_by_category(),
            descendants,
            fetch_offset,
            fetch_limit,
            db.allocator,
        ) catch |err| return writeMappedError(resp, op_byte, err);
    defer db.allocator.free(slice.link_ids);

    var off: usize = RESPONSE_HEADER_SIZE + 4;
    var written: u32 = 0;
    var total: u64 = if (status_filter == null) slice.total else 0;
    var skipped: u32 = 0;
    var passed_cursor = !cursor_mode;
    var next_after_id: u64 = 0;
    var last_written_id: u64 = 0;

    for (slice.link_ids) |lid| {
        const link = (operations.getLink(db, lid) catch null) orelse continue;
        if (status_filter) |s| {
            if (link.status != s) continue;
            total += 1;
        }
        if (!passed_cursor) {
            if (link.id == extras.after_id) passed_cursor = true;
            continue;
        }
        if (!cursor_mode and status_filter != null and skipped < req.offset) {
            skipped += 1;
            continue;
        }
        if (written >= limit) {
            next_after_id = last_written_id;
            if (status_filter == null) break else continue;
        }
        if (off + @sizeOf(schema.Link) + 16 > resp.len) {
            if (status_filter == null) break else continue;
        }
        const lb = std.mem.asBytes(&link);
        @memcpy(resp[off..][0..lb.len], lb);
        off += lb.len;
        last_written_id = link.id;
        written += 1;
    }

    std.mem.writeInt(u32, resp[RESPONSE_HEADER_SIZE..][0..4], written, .little);
    if (off + 16 > resp.len) return writeErrorResp(resp, op_byte, .err);
    std.mem.writeInt(u64, resp[off..][0..8], total, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], next_after_id, .little);
    off += 8;

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

const SearchScope = enum(u8) { both = 0, links_only = 1, categories_only = 2 };

const inverted = @import("inverted_index.zig");

fn linkMatchField(link: schema.Link, query: []const u8) u8 {
    var tok_buf: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var it = inverted.TokenIterator.init(query);
    while (it.next(&tok_buf)) |tok| {
        if (std.ascii.indexOfIgnoreCase(link.title.slice(), tok) != null) return 0;
        if (std.ascii.indexOfIgnoreCase(link.url.slice(), tok) != null) return 1;
        if (std.ascii.indexOfIgnoreCase(link.description.slice(), tok) != null) return 2;
    }
    return 0;
}

fn handleSearch(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 6) return writeErrorResp(resp, op_byte, .invalid);
    const query_len: usize = std.mem.readInt(u16, payload[0..2], .little);
    if (query_len < 2) return writeErrorResp(resp, op_byte, .invalid);
    if (2 + query_len + 4 > payload.len) return writeErrorResp(resp, op_byte, .invalid);
    const query = payload[2..][0..query_len];
    const limit = std.mem.readInt(u32, payload[2 + query_len ..][0..4], .little);

    const consumed: usize = 2 + query_len + 4;
    const scope: SearchScope = switch (payload.len - consumed) {
        0 => .both,
        1 => blk: {
            const s = payload[consumed];
            if (s > 2) return writeErrorResp(resp, op_byte, .invalid);
            break :blk @enumFromInt(s);
        },
        else => return writeErrorResp(resp, op_byte, .invalid),
    };

    if (resp.len < RESPONSE_HEADER_SIZE + 4) return writeErrorResp(resp, op_byte, .err);

    const max = @min(limit, 50);
    var off: usize = RESPONSE_HEADER_SIZE;

    var cat_buf: [50]schema.Category = undefined;
    const cats = if (scope == .links_only)
        cat_buf[0..0]
    else
        operations.searchCategories(db, query, max, &cat_buf) catch &[0]schema.Category{};
    const cat_count_off = off;
    off += 2;
    var cats_written: u16 = 0;
    for (cats) |cat| {
        if (off + @sizeOf(schema.Category) + 2 > resp.len) break;
        const cb = std.mem.asBytes(&cat);
        @memcpy(resp[off..][0..cb.len], cb);
        off += cb.len;
        cats_written += 1;
    }
    std.mem.writeInt(u16, resp[cat_count_off..][0..2], cats_written, .little);

    var link_buf: [50]schema.Link = undefined;
    const links = if (scope == .categories_only)
        link_buf[0..0]
    else
        operations.searchLinks(db, query, max, &link_buf) catch &[0]schema.Link{};
    const link_count_off = off;
    off += 2;
    var links_written: u16 = 0;
    for (links) |link| {
        if (off + @sizeOf(schema.Link) + 1 > resp.len) break;
        const lb = std.mem.asBytes(&link);
        @memcpy(resp[off..][0..lb.len], lb);
        off += lb.len;
        resp[off] = linkMatchField(link, query);
        off += 1;
        links_written += 1;
    }
    std.mem.writeInt(u16, resp[link_count_off..][0..2], links_written, .little);

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
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
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
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

    const PAYLOAD_BYTES: usize = 24;
    if (resp.len < RESPONSE_HEADER_SIZE + PAYLOAD_BYTES) return writeErrorResp(resp, op_byte, .err);

    var off: usize = RESPONSE_HEADER_SIZE;
    std.mem.writeInt(u64, resp[off..][0..8], stats.categories_rebuilt, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], stats.links_rebuilt, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], stats.queue_entries_drained, .little);
    off += 8;

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

fn handleSnapshot(db: *Directory, resp: []u8, op_byte: u8) usize {
    const result = zigstore.snapshot.forceSnapshot(db.store.snapshotHost()) catch |err| {
        if (err != error.SnapshotInProgress) {
            log.err("snapshot op failed: {}", .{err});
        }
        return writeMappedError(resp, op_byte, err);
    };

    const PAYLOAD_BYTES: usize = 16;
    if (resp.len < RESPONSE_HEADER_SIZE + PAYLOAD_BYTES) return writeErrorResp(resp, op_byte, .err);

    var off: usize = RESPONSE_HEADER_SIZE;
    std.mem.writeInt(u64, resp[off..][0..8], result.wal_sequence, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], result.duration_ms, .little);
    off += 8;

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
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
        off += 1;
        std.mem.writeInt(u64, resp[off..][0..8], h.percentile(50.0), .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], h.percentile(95.0), .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], h.percentile(99.0), .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], h.percentile(99.9), .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], h.maxValue(), .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], h.mean(), .little);
        off += 8;
        std.mem.writeInt(u64, resp[off..][0..8], samples, .little);
        off += 8;
        emitted += 1;
    }

    resp[count_off] = emitted;
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

fn handleBulkImport(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8, count: u16) usize {
    const PAYLOAD_BYTES: usize = 48;
    if (resp.len < RESPONSE_HEADER_SIZE + PAYLOAD_BYTES) return writeErrorResp(resp, op_byte, .err);

    if (payload.len > BULK_IMPORT_MAX_BYTES) {
        log.warn("bulk_import: payload {d} bytes exceeds cap {d}", .{ payload.len, BULK_IMPORT_MAX_BYTES });
        return writeErrorRespSub(resp, op_byte, .invalid, .field_too_long);
    }
    if (@as(u32, count) > BULK_IMPORT_MAX_ITEMS) {
        log.warn("bulk_import: count {d} exceeds cap {d}", .{ count, BULK_IMPORT_MAX_ITEMS });
        return writeErrorRespSub(resp, op_byte, .invalid, .field_too_long);
    }

    const t_start = std.time.nanoTimestamp();

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

    const t_end = std.time.nanoTimestamp();
    const elapsed_ms: u64 = @intCast(@divTrunc(t_end - t_start, std.time.ns_per_ms));

    log.info("bulk_import: done count={d} inserted={d} dup={d} err={d} elapsed_ms={d}", .{
        count, inserted, duplicates, errors, elapsed_ms,
    });

    var off: usize = RESPONSE_HEADER_SIZE;
    std.mem.writeInt(u64, resp[off..][0..8], inserted, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], duplicates, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], errors, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], first_id, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], last_id, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], elapsed_ms, .little);
    off += 8;

    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

fn handleCreateSubmission(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    const ITEM_BYTES: usize = 10;
    if (resp.len < RESPONSE_HEADER_SIZE + ITEM_BYTES) return 0;

    const parsed = parsePayload(link_fields, payload) orelse
        return writeErrorResp(resp, op_byte, .invalid);
    const rest = parsed.rest;
    if (rest.len < 8) return writeErrorResp(resp, op_byte, .invalid);
    const submitter_id = std.mem.readInt(u64, rest[0..8], .little);

    var off: usize = RESPONSE_HEADER_SIZE;
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
        resp[off] = @intFromEnum(pair.status);
        resp[off + 1] = @intFromEnum(pair.sub_status);
        off += 2;
        @memset(resp[off..][0..8], 0);
        off += 8;
        writeResponseHeader(resp, @intCast(off), op_byte, pair.status, pair.sub_status, 1);
        return off;
    };
    resp[off] = @intFromEnum(Status.ok);
    resp[off + 1] = @intFromEnum(SubStatus.none);
    off += 2;
    std.mem.writeInt(u64, resp[off..][0..8], id, .little);
    off += 8;
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 1);
    return off;
}

fn handleUpdateLinkStatus(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 9) return writeErrorResp(resp, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const status = payload[8];
    if (status > 2) return writeErrorRespSub(resp, op_byte, .invalid, .unsupported_order);
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
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
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
    if (status > 2) return writeErrorResp(resp, op_byte, .invalid);
    return handleBulkLinkOp(resp, op_byte, payload, 1, db, status, applyBulkStatus);
}

fn handleBulkDeleteLinks(db: *Directory, resp: []u8, op_byte: u8, payload: []const u8) usize {
    return handleBulkLinkOp(resp, op_byte, payload, 0, db, 0, applyBulkDelete);
}

fn handleCountsByStatus(db: *Directory, resp: []u8, op_byte: u8) usize {
    const counts = operations.countsByStatus(db) catch |err| return writeMappedError(resp, op_byte, err);
    if (resp.len < RESPONSE_HEADER_SIZE + 24) return writeErrorResp(resp, op_byte, .err);
    var off: usize = RESPONSE_HEADER_SIZE;
    std.mem.writeInt(u64, resp[off..][0..8], counts.pending, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], counts.approved, .little);
    off += 8;
    std.mem.writeInt(u64, resp[off..][0..8], counts.rejected, .little);
    off += 8;
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

fn handleStats(db: *Directory, resp: []u8, op_byte: u8) usize {
    const s = db.getStats();
    const values = [_]u64{
        s.category_count,
        s.link_count,
        @as(u64, s.page_count),
        s.cache_hits,
        s.cache_misses,
        s.wal_pending_batch_entries,
    };
    if (resp.len < RESPONSE_HEADER_SIZE + values.len * @sizeOf(u64)) {
        return writeErrorResp(resp, op_byte, .err);
    }
    var off: usize = RESPONSE_HEADER_SIZE;
    for (values) |val| {
        std.mem.writeInt(u64, resp[off..][0..8], val, .little);
        off += 8;
    }
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, 0);
    return off;
}

fn readOptionalString(payload: []const u8, off: *usize, mask: u8, bit: u8) ?(?[]const u8) {
    if (mask & bit == 0) return @as(?[]const u8, null);
    if (off.* + 2 > payload.len) return null;
    const len = std.mem.readInt(u16, payload[off.*..][0..2], .little);
    off.* += 2;
    if (off.* + len > payload.len) return null;
    const s = payload[off.*..][0..len];
    off.* += len;
    return s;
}

fn writeRowList(comptime T: type, resp: []u8, op_byte: u8, items: []const T) usize {
    var off: usize = RESPONSE_HEADER_SIZE;
    var written_count: u16 = 0;
    for (items) |item| {
        const bytes = std.mem.asBytes(&item);
        if (off + bytes.len > resp.len) break;
        @memcpy(resp[off..][0..bytes.len], bytes);
        off += bytes.len;
        written_count += 1;
    }
    writeResponseHeader(resp, @intCast(off), op_byte, .ok, .none, written_count);
    return off;
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
    const min_frame_required: usize = RESPONSE_HEADER_SIZE + 4 + 8 + 8;
    try std.testing.expectEqual(@as(usize, 30), min_frame_required);
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
        .{ .err = error.InvalidSlug, .status = .invalid, .sub = .invalid_slug },
        .{ .err = error.BufferTooSmall, .status = .invalid, .sub = .buffer_too_small },
        .{ .err = error.PathTooDeep, .status = .invalid, .sub = .path_too_deep },
        .{ .err = error.UnsupportedOrder, .status = .invalid, .sub = .unsupported_order },
        .{ .err = error.OffsetTooLarge, .status = .invalid, .sub = .offset_too_large },
        .{ .err = error.ParentNotFound, .status = .category_not_found, .sub = .parent_not_found },
        .{ .err = error.DuplicateUrl, .status = .duplicate, .sub = .duplicate_url },
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

test "list_subtree_links: small subtree (<= scan_threshold) and large subtree both return correct results" {
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
    db.drainOneMemtable(db.mt_categories_by_id(), db.categories_by_id());
    db.drainOneMemtable(db.mt_cat_by_parent(), db.cat_by_parent());
    db.drainOneMemtable(db.mt_link_by_category(), db.link_by_category());
    db.drainOneMemtable(db.mt_links_by_id(), db.links_by_id());

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], top_id, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], 0, .little);
    std.mem.writeInt(u32, payload[13..17], 20, .little);

    db.config.subtree_scan_threshold = 5;
    var resp_a: [4096]u8 = undefined;
    const len_a = handleListSubtreeLinks(db, &resp_a, @intFromEnum(Op.list_subtree_links), &payload);
    const total_a = std.mem.readInt(u64, resp_a[len_a - 16 .. len_a - 8][0..8], .little);
    const next_a = std.mem.readInt(u64, resp_a[len_a - 8 .. len_a][0..8], .little);

    db.config.subtree_scan_threshold = 100;
    var resp_b: [4096]u8 = undefined;
    const len_b = handleListSubtreeLinks(db, &resp_b, @intFromEnum(Op.list_subtree_links), &payload);
    const total_b = std.mem.readInt(u64, resp_b[len_b - 16 .. len_b - 8][0..8], .little);

    try std.testing.expectEqual(@as(u64, 6), total_a);
    try std.testing.expectEqual(total_a, total_b);
    try std.testing.expectEqual(len_a, len_b);
    try std.testing.expectEqual(@as(u64, 0), next_a);
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

    var bp: conn_mod.BufferPair = .{};
    var conn: conn_mod.Connection = .{};
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

    processFrames(db, &conn);

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

test "pipelineHasRoom defers a frame once the buffer can't hold a worst-case response" {
    const buf = conn_mod.RESPONSE_BUF_SIZE;
    try std.testing.expect(pipelineHasRoom(0, buf));
    try std.testing.expect(pipelineHasRoom(buf - RESPONSE_RESERVE, buf));
    try std.testing.expect(!pipelineHasRoom(buf - RESPONSE_RESERVE + 1, buf));
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

    const snap = (try zigstore.snapshot.SnapshotManager.loadSnapshotMeta(db.config.data_dir)).?;
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
    const reply_len = handleListAllLinks(db, &resp, @intFromEnum(Op.list_all_links), &payload);
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
    const reply_all = handleListAllLinks(db, &resp_all, @intFromEnum(Op.list_all_links), &payload_all);
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
    const reply_len = handleListLinks(db, &resp, @intFromEnum(Op.list_links), &payload);
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
    const reply_len = handleListLinksBySubmitter(db, &resp, @intFromEnum(Op.list_links_by_submitter), &payload);
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
    const reply_len = handleListAllLinks(db, &resp, @intFromEnum(Op.list_all_links), &payload);
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

fn fuzzProcessFramesOne(_: void, input: []const u8) anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db = Directory.openTestInstance(gpa.allocator(), &tmp) catch return;
    defer db.deinitTestInstance();

    var bp: conn_mod.BufferPair = .{};
    var conn = conn_mod.Connection{ .phase = .reading_request, .buf = &bp };
    const n = @min(input.len, bp.request_buf.len);
    @memcpy(bp.request_buf[0..n], input[0..n]);
    conn.bytes_read = n;
    processFrames(db, &conn);
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
