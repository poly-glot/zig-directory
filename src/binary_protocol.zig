//! Binary protocol handlers for dmozdb: the data plane that decodes one request payload and
//! writes its response frame in place into the connection's preallocated buffer. Payload bytes
//! are operating input and are answered with a status, never asserted; what a handler writes is
//! its own doing and must stay inside `response.len`, which every writer asserts.

const std = @import("std");
const assert = std.debug.assert;
const zigstore = @import("zigstore");
const protocol = zigstore.protocol;
const inverted = zigstore.inverted_index;
const schema = @import("schema.zig");
const Directory = @import("directory.zig").Directory;
const operations = @import("operations/operations.zig");
const operations_shared = @import("operations/operations_shared.zig");
const facts_index = @import("facts/facts_index.zig");
const countries = @import("facts/countries.zig");
const url_facts = @import("facts/url_facts.zig");
const entities = @import("facts/entities.zig");
const subtree = @import("subtree.zig");
const scratch_memory = @import("scratch.zig");
const vector_index = @import("vector_index.zig");

const log = std.log.scoped(.binary);

pub const response_header_size: usize = protocol.RESPONSE_HEADER_SIZE;

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

pub fn map_error_with_sub_status(err: anyerror) StatusPair {
    const pair: StatusPair = switch (err) {
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
        error.EmbeddingModelMismatch => .{
            .status = .invalid,
            .sub_status = .embedding_model_mismatch,
        },
        error.InvalidEmbeddingModel, error.TooManyVectors, error.TooManyEntityWrites => .{
            .status = .invalid,
            .sub_status = .none,
        },
        else => .{ .status = .err, .sub_status = .none },
    };
    assert(pair.status != .ok);
    return pair;
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

pub const get_categories_by_ids_max: u16 = 200;
pub const breadcrumbs_by_ids_max: u16 = 200;
const breadcrumb_bytes: usize = @sizeOf(u64) +
    @sizeOf(@FieldType(schema.Category, "name")) +
    @sizeOf(@FieldType(schema.Category, "slug"));

// The reserve is the largest single response the data plane can produce; the connection loop
// admits a frame only when that much buffer is free, so no handler needs to split a reply.
pub const response_reserve: usize = response_header_size +
    @as(usize, get_categories_by_ids_max) * @sizeOf(schema.Category);

pub const bulk_import_bytes_max: usize = 60 * 1024;
pub const bulk_import_items_max: u32 = 50_000;
pub const bulk_import_chunk: u32 = 500;
const bulk_import_result_bytes: usize = 6 * @sizeOf(u64);

// One item result is `[u8 status][u8 sub_status][u64 id]`; one id result is `[u64 id][u8 code]`.
const item_result_bytes: usize = 10;
const id_result_bytes: usize = @sizeOf(u64) + 1;
const bulk_items_max: u16 = 200;

const subtree_offset_max: u32 = 5000;
const subtree_limit_max: u32 = 100;
const subtree_limit_default: u32 = 50;
const subtree_fetch_max: u32 = 10_000;
// Ids come from the category index, which can name links deleted since; fetching twice the page
// lets the row writer skip the misses and still fill it.
const subtree_overprovision_factor: u32 = 2;
const subtree_request_bytes: usize = @sizeOf(u64) + 1 + 2 * @sizeOf(u32);
const subtree_rows_offset: usize = response_header_size + @sizeOf(u32);
const subtree_trailer_bytes: usize = 2 * @sizeOf(u64);
const subtree_frame_bytes_min: usize = subtree_rows_offset + subtree_trailer_bytes;
const ancestor_depth_max: usize = 64;
const browse_children_limit: u32 = 100;
const browse_frame_bytes_min: usize = response_header_size + @sizeOf(schema.Category) + 2 + 2 + 8;
const search_results_max: u32 = 50;
const status_filter_none: u8 = 0xFF;
const status_any: u8 = 0xFF;

comptime {
    assert(response_header_size == 10);
    assert(response_reserve <= zigstore.connection.RESPONSE_BUF_SIZE);
    assert(response_reserve >= browse_frame_bytes_min +
        (ancestor_depth_max + browse_children_limit) * @sizeOf(schema.Category));
    assert(response_reserve >= subtree_frame_bytes_min +
        @as(usize, subtree_limit_max) * @sizeOf(schema.Link));
    assert(response_reserve >= response_header_size + 2 +
        (ancestor_depth_max + 1) * breadcrumb_bytes);
    assert(response_reserve >= response_header_size + bulk_import_result_bytes);
    assert(response_reserve >= response_header_size + 4 + @as(usize, search_results_max) *
        (@sizeOf(schema.Category) + @sizeOf(schema.Link) + 1 + @sizeOf(operations.RowSite)));
    assert(response_reserve >= response_header_size + 4 +
        @as(usize, bulk_items_max) * id_result_bytes);
    assert(breadcrumb_bytes < @sizeOf(schema.Category));
    assert(item_result_bytes == 2 + @sizeOf(u64));
    assert(bulk_import_bytes_max + protocol.REQUEST_HEADER_SIZE <=
        zigstore.connection.REQUEST_BUF_SIZE);
    assert(bulk_import_chunk <= bulk_import_items_max);
    assert(subtree_limit_default <= subtree_limit_max);
    assert(subtree_limit_max * subtree_overprovision_factor <= subtree_fetch_max);
    assert(subtree_frame_bytes_min == 30);
    assert(ancestor_depth_max == operations_shared.depth_max);
    assert(status_filter_none == status_any);
}

const parsePayload = protocol.parsePayload;
const advancePayload = protocol.advancePayload;
const readOptionalString = protocol.readOptionalString;

fn write_response(response: []u8, op: u8, status: Status, count: u16, payload: []const u8) usize {
    const written = protocol.writeResp(response, op, base_status(status), count, payload);
    assert(written <= response.len);
    if (written > 0) assert(written == response_header_size + payload.len);
    return written;
}

fn write_row_list(comptime T: type, response: []u8, op_byte: u8, items: []const T) usize {
    assert(response.len >= response_header_size);
    const written = protocol.writeRowList(T, response, op_byte, items);
    assert(written <= response.len);
    return written;
}

fn write_ok_header(response: []u8, op_byte: u8, total_len: usize, count: u16) void {
    assert(total_len >= response_header_size);
    assert(total_len <= response.len);
    protocol.writeOkHeader(response, op_byte, @intCast(total_len), count);
}

fn write_raw_header(
    response: []u8,
    op_byte: u8,
    total_len: usize,
    status: Status,
    sub_status: SubStatus,
    count: u16,
) void {
    assert(total_len >= response_header_size);
    assert(total_len <= response.len);
    protocol.writeRawHeader(
        response,
        op_byte,
        @intCast(total_len),
        @intFromEnum(status),
        @intFromEnum(sub_status),
        count,
    );
}

fn write_error_response(response: []u8, op: u8, status: Status) usize {
    assert(status != .ok);
    assert(response.len >= response_header_size);
    return write_error_response_sub(response, op, status, .none);
}

fn write_error_response_sub(response: []u8, op: u8, status: Status, sub_status: SubStatus) usize {
    assert(status != .ok);
    assert(response.len >= response_header_size);
    const written = protocol.writeRawErrorResp(
        response,
        op,
        @intFromEnum(status),
        @intFromEnum(sub_status),
    );
    assert(written == response_header_size);
    return written;
}

fn base_status(status: Status) protocol.Status {
    assert(@intFromEnum(status) <= @intFromEnum(protocol.Status.err));
    return @enumFromInt(@intFromEnum(status));
}

fn write_mapped_error(response: []u8, op: u8, err: anyerror) usize {
    const pair = map_error_with_sub_status(err);
    assert(pair.status != .ok);
    const written = write_error_response_sub(response, op, pair.status, pair.sub_status);
    assert(written == response_header_size);
    return written;
}

const pair_ok = StatusPair{ .status = .ok, .sub_status = .none };
const pair_invalid = StatusPair{ .status = .invalid, .sub_status = .none };

fn write_item_result(response: []u8, offset: usize, pair: StatusPair, id: u64) usize {
    assert(offset + item_result_bytes <= response.len);
    if (pair.status == .ok) assert(id != 0);
    if (pair.status != .ok) assert(id == 0);
    response[offset] = @intFromEnum(pair.status);
    response[offset + 1] = @intFromEnum(pair.sub_status);
    std.mem.writeInt(u64, response[offset + 2 ..][0..8], id, .little);
    return offset + item_result_bytes;
}

fn append_row(response: []u8, offset: usize, row: anytype) usize {
    const bytes = std.mem.asBytes(row);
    assert(bytes.len > 0);
    assert(offset + bytes.len <= response.len);
    @memcpy(response[offset..][0..bytes.len], bytes);
    return offset + bytes.len;
}

fn write_u64s(response: []u8, start: usize, values: []const u64) usize {
    assert(start + values.len * @sizeOf(u64) <= response.len);
    var offset = start;
    for (values) |value| {
        std.mem.writeInt(u64, response[offset..][0..8], value, .little);
        offset += @sizeOf(u64);
    }
    assert(offset == start + values.len * @sizeOf(u64));
    return offset;
}

fn write_u64_frame(response: []u8, op_byte: u8, values: []const u64) usize {
    assert(values.len > 0);
    const frame_bytes = response_header_size + values.len * @sizeOf(u64);
    if (response.len < frame_bytes) return write_error_response(response, op_byte, .err);
    const offset = write_u64s(response, response_header_size, values);
    assert(offset == frame_bytes);
    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

fn write_counted_category_rows(
    response: []u8,
    start: usize,
    rows: []const schema.Category,
    tail_reserve: u32,
) usize {
    assert(start + 2 + tail_reserve <= response.len);
    var offset = start + 2;
    var written: u16 = 0;
    for (rows) |*row| {
        if (offset + @sizeOf(schema.Category) + tail_reserve > response.len) break;
        offset = append_row(response, offset, row);
        written += 1;
    }
    assert(written <= rows.len);
    assert(offset == start + 2 + @as(usize, written) * @sizeOf(schema.Category));
    assert(offset + tail_reserve <= response.len);
    std.mem.writeInt(u16, response[start..][0..2], written, .little);
    return offset;
}

fn is_known_link_status(code: u8) bool {
    comptime assert(@intFromEnum(schema.LinkStatus.pending) == 0);
    comptime assert(@intFromEnum(schema.LinkStatus.rejected) == 2);
    return code <= @intFromEnum(schema.LinkStatus.rejected);
}

fn BatchCreateHandlerType(
    comptime fields: []const struct { []const u8, type },
    comptime op_code: u8,
    comptime create: anytype,
) type {
    const Text = @typeInfo(@TypeOf(create)).@"fn".params[2].type.?;
    comptime assert(fields.len == 1 + @typeInfo(Text).@"struct".fields.len);
    return struct {
        fn handle(db: *Directory, response: []u8, payload: []const u8, count: u16) usize {
            if (response.len < response_header_size) return 0;

            var offset: usize = response_header_size;
            var data = payload;
            var written: u16 = 0;
            for (0..count) |_| {
                if (offset + item_result_bytes > response.len) break;

                // A truncated item ends the batch with one invalid result: nothing after it
                // can be framed, so charging the rest would only repeat the same answer.
                const parsed = parsePayload(fields, data) orelse {
                    offset = write_item_result(response, offset, pair_invalid, 0);
                    written += 1;
                    break;
                };
                const item = parsed.result;
                var text: Text = undefined;
                inline for (fields[1..]) |field| @field(text, field[0]) = @field(item, field[0]);
                const created = @call(.auto, create, .{ db, @field(item, fields[0][0]), text });
                if (created) |id| {
                    offset = write_item_result(response, offset, pair_ok, id);
                    data = parsed.rest;
                } else |err| {
                    offset = write_item_result(response, offset, map_error_with_sub_status(err), 0);
                    data = advancePayload(fields, data) orelse &.{};
                }
                written += 1;
            }
            assert(written <= count);
            assert(offset == response_header_size + @as(usize, written) * item_result_bytes);
            assert(offset <= response.len);

            write_ok_header(response, op_code, offset, written);
            return offset;
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

const ParsedLink = @FieldType(protocol.ParsedPayload(link_fields), "result");

const CreateLinks = BatchCreateHandlerType(
    link_fields,
    @intFromEnum(Op.create_link),
    operations.create_link,
);
const CreateCategories = BatchCreateHandlerType(
    category_fields,
    @intFromEnum(Op.create_category),
    operations.create_category,
);
const GetLink = GetHandlerType(schema.Link, operations.get_link);
const GetCategory = GetHandlerType(schema.Category, operations.get_category);
const DeleteLink = DeleteHandlerType(operations.delete_link);
const DeleteCategory = DeleteHandlerType(operations.delete_category);
const UpdateLink = TextUpdateHandlerType(operations.update_link);
const UpdateCategory = TextUpdateHandlerType(operations.update_category);
const MoveLink = MoveHandlerType(operations.move_link);
const MoveCategory = MoveHandlerType(operations.move_category);
const ListRootCategories = ListChildrenHandlerType(.none);
const ListChildren = ListChildrenHandlerType(.leading_id);
const ListLinks = ListLinksHandlerType(.leading_id, operations.list_links);
const ListAllLinks = ListLinksHandlerType(.none, operations.list_all_links);
const ListLinksBySubmitter = ListLinksHandlerType(.leading_id, operations.list_links_by_submitter);

pub fn dispatch(
    db: *Directory,
    op_byte: u8,
    payload: []const u8,
    count: u16,
    response: []u8,
) usize {
    assert(response.len >= response_header_size);
    const op = std.enums.fromInt(Op, op_byte) orelse {
        return write_error_response(response, op_byte, .invalid);
    };
    const written = switch (op) {
        .ping => write_response(response, op_byte, .ok, 0, &.{}),
        .create_link => CreateLinks.handle(db, response, payload, count),
        .create_category => CreateCategories.handle(db, response, payload, count),
        .get_link => GetLink.handle(db, response, op_byte, payload),
        .get_category => GetCategory.handle(db, response, op_byte, payload),
        .get_categories_by_ids => handle_get_categories_by_ids(db, response, op_byte, payload),
        .breadcrumbs_by_ids => handle_breadcrumbs_by_ids(db, response, op_byte, payload),
        .delete_link => DeleteLink.handle(db, response, op_byte, payload),
        .delete_category => DeleteCategory.handle(db, response, op_byte, payload),
        .update_category => UpdateCategory.handle(db, response, op_byte, payload),
        .move_category => MoveCategory.handle(db, response, op_byte, payload),
        .move_link => MoveLink.handle(db, response, op_byte, payload),
        .update_link => UpdateLink.handle(db, response, op_byte, payload),
        .list_root_categories => ListRootCategories.handle(db, response, op_byte, payload),
        .list_children => ListChildren.handle(db, response, op_byte, payload),
        .list_links => ListLinks.handle(db, response, op_byte, payload),
        .list_all_links => ListAllLinks.handle(db, response, op_byte, payload),
        .list_subtree_links => handle_list_subtree_links(db, response, op_byte, payload),
        .index_health => handle_index_health(db, response, op_byte),
        .run_verifier => handle_run_verifier(db, response, op_byte),
        .rebuild_index => handle_rebuild_index(db, response, op_byte),
        .snapshot => handle_snapshot(db, response, op_byte),
        .op_latency_stats => handle_op_latency_stats(db, response, op_byte),
        .bulk_import => handle_bulk_import(db, response, op_byte, payload, count),
        .create_submission => handle_create_submission(db, response, op_byte, payload),
        .update_link_status => handle_update_link_status(db, response, op_byte, payload),
        .list_links_by_submitter => ListLinksBySubmitter.handle(db, response, op_byte, payload),
        .browse_path => handle_browse_path(db, response, op_byte, payload),
        .search => handle_search(db, response, op_byte, payload),
        .stats => handle_stats(db, response, op_byte),
        .bulk_update_link_status => handle_bulk_update_link_status(db, response, op_byte, payload),
        .bulk_delete_links => handle_bulk_delete_links(db, response, op_byte, payload),
        .counts_by_status => handle_counts_by_status(db, response, op_byte),
        .put_link_vectors => handle_put_link_vectors(db, response, op_byte, payload),
        .query_links => handle_query_links(db, response, op_byte, payload),
        .put_link_entities => handle_put_link_entities(db, response, op_byte, payload),
        .match_names => handle_match_names(db, response, op_byte, payload),
        .put_category_vectors => handle_put_category_vectors(db, response, op_byte, payload),
    };
    assert(written <= response.len);
    if (written > 0) assert(written >= response_header_size);
    return written;
}

pub const ListSubtreeLinksRequest = struct {
    category_id: u64,
    order_code: u8,
    offset: u32,
    limit: u32,

    pub fn parse(payload: []const u8) ListSubtreeLinksRequest {
        assert(payload.len >= subtree_request_bytes);
        return .{
            .category_id = std.mem.readInt(u64, payload[0..8], .little),
            .order_code = payload[8],
            .offset = std.mem.readInt(u32, payload[9..13], .little),
            .limit = std.mem.readInt(u32, payload[13..17], .little),
        };
    }

    pub fn validate(self: *const ListSubtreeLinksRequest) !void {
        if (self.order_code != 0) return error.UnsupportedOrder;
        if (self.offset > subtree_offset_max) return error.OffsetTooLarge;
    }

    pub fn effective_limit(self: *const ListSubtreeLinksRequest) u32 {
        const limit: u32 = if (self.limit == 0)
            subtree_limit_default
        else
            @min(self.limit, subtree_limit_max);
        assert(limit >= 1);
        assert(limit <= subtree_limit_max);
        return limit;
    }
};

fn GetHandlerType(comptime T: type, comptime get: fn (*Directory, u64) anyerror!?T) type {
    return struct {
        fn handle(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
            comptime assert(response_header_size + @sizeOf(T) <= response_reserve);
            if (payload.len < 8) return write_error_response(response, op_byte, .invalid);
            const id = std.mem.readInt(u64, payload[0..8], .little);
            const found = get(db, id) catch |err| return write_mapped_error(response, op_byte, err);
            const item = found orelse return write_error_response(response, op_byte, .not_found);
            const written = write_response(response, op_byte, .ok, 1, std.mem.asBytes(&item));
            if (written > 0) assert(written == response_header_size + @sizeOf(T));
            return written;
        }
    };
}

fn handle_get_categories_by_ids(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 2) return write_error_response(response, op_byte, .invalid);
    const want: u16 = std.mem.readInt(u16, payload[0..2], .little);
    if (want > get_categories_by_ids_max) {
        return write_error_response(response, op_byte, .invalid);
    }
    const expected_payload_len: usize = 2 + @as(usize, want) * 8;
    if (payload.len < expected_payload_len) {
        return write_error_response(response, op_byte, .invalid);
    }

    const category_size = @sizeOf(schema.Category);
    if (response.len < response_header_size + @as(usize, want) * category_size) {
        return write_error_response(response, op_byte, .err);
    }

    var offset: usize = response_header_size;
    var found: u16 = 0;
    for (0..want) |i| {
        const id_offset: usize = 2 + i * 8;
        const id = std.mem.readInt(u64, payload[id_offset..][0..8], .little);
        const category = operations.get_category(db, id) catch null;
        if (category) |*row| {
            offset = append_row(response, offset, row);
            found += 1;
        }
    }
    assert(found <= want);
    assert(offset == response_header_size + @as(usize, found) * category_size);
    assert(offset <= response.len);

    write_ok_header(response, op_byte, offset, found);
    return offset;
}

fn write_crumb(response: []u8, offset: usize, category: *const schema.Category) usize {
    assert(category.id != 0);
    assert(offset + breadcrumb_bytes <= response.len);
    var end = offset;
    std.mem.writeInt(u64, response[end..][0..8], category.id, .little);
    end += 8;
    const name_bytes = std.mem.asBytes(&category.name);
    @memcpy(response[end..][0..name_bytes.len], name_bytes);
    end += name_bytes.len;
    const slug_bytes = std.mem.asBytes(&category.slug);
    @memcpy(response[end..][0..slug_bytes.len], slug_bytes);
    end += slug_bytes.len;
    assert(end == offset + breadcrumb_bytes);
    return end;
}

fn handle_breadcrumbs_by_ids(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 2) return write_error_response(response, op_byte, .invalid);
    const want: u16 = std.mem.readInt(u16, payload[0..2], .little);
    if (want > breadcrumbs_by_ids_max) return write_error_response(response, op_byte, .invalid);
    if (payload.len < 2 + @as(usize, want) * 8) {
        return write_error_response(response, op_byte, .invalid);
    }
    if (response.len < response_header_size) return write_error_response(response, op_byte, .err);

    var offset: usize = response_header_size;
    var groups: u16 = 0;
    for (0..want) |i| {
        const id = std.mem.readInt(u64, payload[2 + i * 8 ..][0..8], .little);

        var ancestors_buffer: [ancestor_depth_max]schema.Category = undefined;
        const ancestors = operations.walk_ancestors(db, id, &ancestors_buffer) catch
            ancestors_buffer[0..0];
        const category = operations.get_category(db, id) catch null;
        const crumbs: usize = if (category != null) ancestors.len + 1 else 0;
        assert(crumbs <= ancestor_depth_max + 1);
        if (category == null) assert(crumbs == 0);
        // A chain is answered whole or not at all, so a caller never mistakes a cut-off chain
        // for an unknown id.
        if (offset + 2 + crumbs * breadcrumb_bytes > response.len) break;

        std.mem.writeInt(u16, response[offset..][0..2], @intCast(crumbs), .little);
        offset += 2;
        if (category) |*own| {
            for (ancestors) |*ancestor| offset = write_crumb(response, offset, ancestor);
            offset = write_crumb(response, offset, own);
        }
        groups += 1;
    }
    assert(groups <= want);
    assert(offset <= response.len);

    write_ok_header(response, op_byte, offset, groups);
    return offset;
}

fn DeleteHandlerType(comptime delete: fn (*Directory, u64) anyerror!void) type {
    return struct {
        fn handle(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
            if (payload.len < 8) return write_error_response(response, op_byte, .invalid);
            const id = std.mem.readInt(u64, payload[0..8], .little);
            delete(db, id) catch |err| return write_mapped_error(response, op_byte, err);
            const written = write_response(response, op_byte, .ok, 0, &.{});
            assert(written == response_header_size);
            return written;
        }
    };
}

fn TextUpdateHandlerType(
    comptime update: fn (*Directory, u64, ?[]const u8, ?[]const u8, ?[]const u8) anyerror!void,
) type {
    return struct {
        fn handle(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
            if (payload.len < 9) return write_error_response(response, op_byte, .invalid);
            const id = std.mem.readInt(u64, payload[0..8], .little);
            const mask = payload[8];
            var offset: usize = 9;

            const first_text = readOptionalString(payload, &offset, mask, 0x01) orelse
                return write_error_response(response, op_byte, .invalid);
            const second_text = readOptionalString(payload, &offset, mask, 0x02) orelse
                return write_error_response(response, op_byte, .invalid);
            const third_text = readOptionalString(payload, &offset, mask, 0x04) orelse
                return write_error_response(response, op_byte, .invalid);
            assert(offset <= payload.len);
            if (mask & 0x01 == 0) assert(first_text == null);

            update(db, id, first_text, second_text, third_text) catch |err| {
                return write_mapped_error(response, op_byte, err);
            };
            const written = write_response(response, op_byte, .ok, 0, &.{});
            assert(written == response_header_size);
            return written;
        }
    };
}

fn MoveHandlerType(comptime move: fn (*Directory, operations.Move) anyerror!void) type {
    return struct {
        fn handle(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
            if (payload.len < 16) return write_error_response(response, op_byte, .invalid);
            const id = std.mem.readInt(u64, payload[0..8], .little);
            const destination = std.mem.readInt(u64, payload[8..16], .little);
            move(db, .{ .id = id, .new_parent_id = destination }) catch |err| {
                return write_mapped_error(response, op_byte, err);
            };
            const written = write_response(response, op_byte, .ok, 0, &.{});
            assert(written == response_header_size);
            return written;
        }
    };
}

const PageKey = enum { none, leading_id };

const ListWindow = struct {
    key: u64,
    offset: u32,
    limit: u32,
    fixed_len: u32,
};

fn parse_list_window(comptime page_key: PageKey, payload: []const u8) ?ListWindow {
    const key_len: usize = if (page_key == .leading_id) 8 else 0;
    if (payload.len < key_len + 8) return null;
    const window = ListWindow{
        .key = if (page_key == .leading_id) std.mem.readInt(u64, payload[0..8], .little) else 0,
        .offset = std.mem.readInt(u32, payload[key_len..][0..4], .little),
        .limit = std.mem.readInt(u32, payload[key_len + 4 ..][0..4], .little),
        .fixed_len = @intCast(key_len + 8),
    };
    assert(window.fixed_len <= payload.len);
    if (page_key == .none) assert(window.key == 0);
    return window;
}

fn ListChildrenHandlerType(comptime page_key: PageKey) type {
    return struct {
        fn handle(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
            const window = parse_list_window(page_key, payload) orelse
                return write_error_response(response, op_byte, .invalid);
            var buffer: [default_list_buffer_len(schema.Category)]schema.Category = undefined;
            const limit = @min(window.limit, @as(u32, @intCast(buffer.len)));
            assert(limit <= buffer.len);
            const items = operations.list_children(
                db,
                window.key,
                .{ .offset = window.offset, .limit = limit },
                &buffer,
            ) catch |err| return write_mapped_error(response, op_byte, err);
            assert(items.len <= limit);
            return write_row_list(schema.Category, response, op_byte, items);
        }
    };
}

fn ListLinksHandlerType(comptime page_key: PageKey, comptime list: anytype) type {
    return struct {
        fn handle(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
            const window = parse_list_window(page_key, payload) orelse
                return write_error_response(response, op_byte, .invalid);
            const extras = read_optional_list_extras(payload, window.fixed_len) orelse
                return write_error_response(response, op_byte, .invalid);
            var buffer: [default_list_buffer_len(schema.Link)]schema.Link = undefined;
            const page_options: operations.Page = .{
                .offset = window.offset,
                .limit = @min(window.limit, @as(u32, @intCast(buffer.len))),
                .after_id = extras.after_id,
                .status_filter = extras.status,
            };
            const listed = if (page_key == .leading_id)
                list(db, window.key, page_options, &buffer)
            else
                list(db, page_options, &buffer);
            const page = listed catch |err| return write_mapped_error(response, op_byte, err);
            assert(page.items.len <= page_options.limit);
            if (page.items.len < page_options.limit) assert(page.next_after_id == 0);
            return write_link_page(response, op_byte, &page);
        }
    };
}

fn handle_browse_path(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 2) return write_error_response(response, op_byte, .invalid);
    const path_len: usize = std.mem.readInt(u16, payload[0..2], .little);
    if (2 + path_len > payload.len) return write_error_response(response, op_byte, .invalid);
    const path = payload[2..][0..path_len];

    const category_id = (operations.resolve_slug_path(db, path) catch null) orelse
        return write_error_response(response, op_byte, .not_found);
    const category = (operations.get_category(db, category_id) catch null) orelse
        return write_error_response(response, op_byte, .not_found);

    db.drain_one_memtable(
        db.memtable_cat_by_parent(),
        db.cat_by_parent(),
    ) catch |err| log.warn("drain skipped before read: {}", .{err});
    db.drain_one_memtable(
        db.memtable_link_by_category(),
        db.link_by_category(),
    ) catch |err| log.warn("drain skipped before read: {}", .{err});

    if (response.len < browse_frame_bytes_min) return write_error_response(response, op_byte, .err);

    var ancestors_buffer: [ancestor_depth_max]schema.Category = undefined;
    const ancestors = operations.walk_ancestors(db, category_id, &ancestors_buffer) catch
        return write_error_response(response, op_byte, .err);
    assert(ancestors.len <= ancestor_depth_max);
    var children_buffer: [browse_children_limit]schema.Category = undefined;
    const children = operations.list_children(
        db,
        category_id,
        .{ .limit = browse_children_limit },
        &children_buffer,
    ) catch return write_error_response(response, op_byte, .err);
    assert(children.len <= browse_children_limit);

    var offset = append_row(response, response_header_size, &category);
    offset = write_counted_category_rows(response, offset, ancestors, 2 + 8);
    offset = write_counted_category_rows(response, offset, children, 8);
    offset = write_u64s(response, offset, &.{subtree_link_total(db, category_id)});
    assert(offset <= response.len);

    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

fn subtree_link_total(db: *Directory, category_id: u64) u64 {
    if (db.subtree_cache.get_link_count(category_id)) |hit| return hit;

    const descendants = subtree.collect_descendants_cached(
        db.cat_by_parent(),
        category_id,
        &db.subtree_cache,
        db.scratch(),
    ) catch |err| {
        log.warn(
            "browse_path: descendants of {d} unavailable, reporting 0 subtree links: {}",
            .{ category_id, err },
        );
        return 0;
    };
    defer db.scratch().free(descendants);

    assert(descendants.len >= 1);
    assert(descendants.len <= subtree.descendants_max);
    const total = subtree.count_subtree_links(
        db.link_by_category(),
        descendants,
        db.scratch(),
    ) catch |err| {
        log.warn(
            "browse_path: subtree link count of {d} unavailable, reporting 0: {}",
            .{ category_id, err },
        );
        return 0;
    };
    db.subtree_cache.put_link_count(.{ .root = category_id, .count = total }) catch |err| {
        log.warn("browse_path: subtree link count of {d} not cached: {}", .{ category_id, err });
    };
    return total;
}

const OptionalListExtras = struct { status: ?u8, after_id: u64 };

// The optional tail of a list request is either nothing, one status byte, or a status byte and
// a cursor; `status_filter_none` in the long form means "no filter", which the short form has
// no way to say.
fn read_optional_list_extras(payload: []const u8, fixed_len: usize) ?OptionalListExtras {
    if (payload.len < fixed_len) return null;
    const tail = payload[fixed_len..];
    const extras: OptionalListExtras = switch (tail.len) {
        0 => .{ .status = null, .after_id = 0 },
        1 => blk: {
            const status = tail[0];
            if (!is_known_link_status(status)) return null;
            break :blk .{ .status = status, .after_id = 0 };
        },
        9 => blk: {
            const status = tail[0];
            const after_id = std.mem.readInt(u64, tail[1..9], .little);
            if (status == status_filter_none) break :blk .{ .status = null, .after_id = after_id };
            if (!is_known_link_status(status)) return null;
            break :blk .{ .status = status, .after_id = after_id };
        },
        else => return null,
    };
    if (extras.status) |status| assert(is_known_link_status(status));
    if (tail.len < 9) assert(extras.after_id == 0);
    return extras;
}

fn write_link_page(response: []u8, op_byte: u8, page: *const operations.LinkPage) usize {
    var offset = write_row_list(schema.Link, response, op_byte, page.items);
    // The row writer stamps how many rows fit into the header; read it back rather than recount.
    const written = std.mem.readInt(u16, response[8..10], .little);
    assert(written <= page.items.len);
    if (offset + 8 > response.len) return write_error_response(response, op_byte, .err);
    std.mem.writeInt(u64, response[offset..][0..8], page.next_after_id, .little);
    offset += 8;
    assert(offset <= response.len);
    write_ok_header(response, op_byte, offset, written);
    return offset;
}

const SubtreePageSpec = struct {
    limit: u32,
    offset: u32,
    status_filter: ?u8,
    after_id: u64,

    fn cursor_mode(self: *const SubtreePageSpec) bool {
        return self.after_id > 0;
    }

    fn needs_full_scan(self: *const SubtreePageSpec) bool {
        return self.cursor_mode() or self.status_filter != null;
    }
};

const SubtreePageResult = struct { offset: u32, written: u32, total: u64, next_after_id: u64 };

fn write_subtree_link_rows(
    db: *Directory,
    response: []u8,
    link_ids: []const u64,
    unfiltered_total: u64,
    spec: *const SubtreePageSpec,
) SubtreePageResult {
    assert(link_ids.len <= subtree_fetch_max);
    assert(spec.limit <= subtree_limit_max);
    const cursor_mode = spec.cursor_mode();
    var offset = subtree_rows_offset;
    var written: u32 = 0;
    var total: u64 = if (spec.status_filter == null) unfiltered_total else 0;
    var skipped: u32 = 0;
    var passed_cursor = !cursor_mode;
    var next_after_id: u64 = 0;
    var last_written_id: u64 = 0;

    for (link_ids) |link_id| {
        const link = (operations.get_link(db, link_id) catch null) orelse continue;
        if (spec.status_filter) |status| {
            if (link.status != status) continue;
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
        // A filtered page keeps walking after it is full because the filtered total is counted
        // on the way; a plain page already knows its total and stops.
        if (written >= spec.limit) {
            next_after_id = last_written_id;
            if (spec.status_filter == null) break else continue;
        }
        if (offset + @sizeOf(schema.Link) + subtree_trailer_bytes > response.len) {
            if (spec.status_filter == null) break else continue;
        }
        offset = append_row(response, offset, &link);
        last_written_id = link.id;
        written += 1;
    }
    if (!cursor_mode) assert(passed_cursor);
    assert(written <= spec.limit);
    assert(offset == subtree_rows_offset + @as(usize, written) * @sizeOf(schema.Link));
    assert(offset + subtree_trailer_bytes <= response.len);
    if (spec.status_filter == null) assert(total == unfiltered_total);

    return .{
        .offset = @intCast(offset),
        .written = written,
        .total = total,
        .next_after_id = next_after_id,
    };
}

fn fetch_subtree_link_ids(
    db: *Directory,
    category_id: u64,
    descendants: []const u64,
    spec: *const SubtreePageSpec,
) !subtree.SubtreeLinkPage {
    if (spec.needs_full_scan()) {
        const page = try subtree.list_subtree_link_ids_scan(
            db.link_by_category(),
            descendants,
            .{ .limit = subtree_fetch_max },
            db.scratch(),
        );
        assert(page.link_ids.len <= subtree_fetch_max);
        return page;
    }
    const page_limit = spec.limit *| subtree_overprovision_factor;
    assert(page_limit <= subtree_fetch_max);
    const link_ids = try subtree.list_subtree_link_ids(
        db.link_by_category(),
        descendants,
        .{ .offset = spec.offset, .limit = page_limit },
        db.scratch(),
    );
    errdefer db.scratch().free(link_ids);
    assert(link_ids.len <= page_limit);

    const category = try operations.get_category(db, category_id);
    const total: u64 = if (category) |found| found.link_count_subtree else 0;
    return .{ .link_ids = link_ids, .total = total };
}

fn handle_list_subtree_links(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < subtree_request_bytes) {
        return write_error_response(response, op_byte, .invalid);
    }
    const request = ListSubtreeLinksRequest.parse(payload);
    request.validate() catch |err| return write_mapped_error(response, op_byte, err);
    const extras = read_optional_list_extras(payload, subtree_request_bytes) orelse {
        return write_error_response(response, op_byte, .invalid);
    };
    const spec = SubtreePageSpec{
        .limit = request.effective_limit(),
        .offset = request.offset,
        .status_filter = extras.status,
        .after_id = extras.after_id,
    };

    db.drain_one_memtable(
        db.memtable_cat_by_parent(),
        db.cat_by_parent(),
    ) catch |err| log.warn("drain skipped before read: {}", .{err});
    db.drain_one_memtable(
        db.memtable_link_by_category(),
        db.link_by_category(),
    ) catch |err| log.warn("drain skipped before read: {}", .{err});
    db.drain_one_memtable(
        db.memtable_links_by_id(),
        db.links_by_id(),
    ) catch |err| log.warn("drain skipped before read: {}", .{err});

    const descendants = subtree.collect_descendants_cached(
        db.cat_by_parent(),
        request.category_id,
        &db.subtree_cache,
        db.scratch(),
    ) catch |err| return write_mapped_error(response, op_byte, err);
    defer db.scratch().free(descendants);

    assert(descendants.len >= 1);
    assert(descendants.len <= subtree.descendants_max);
    if (response.len < subtree_frame_bytes_min) {
        return write_error_response(response, op_byte, .err);
    }

    const fetched = fetch_subtree_link_ids(
        db,
        request.category_id,
        descendants,
        &spec,
    ) catch |err| {
        return write_mapped_error(response, op_byte, err);
    };
    defer db.scratch().free(fetched.link_ids);

    const page = write_subtree_link_rows(db, response, fetched.link_ids, fetched.total, &spec);
    assert(page.written <= spec.limit);
    std.mem.writeInt(u32, response[response_header_size..][0..4], page.written, .little);
    const offset = write_u64s(response, page.offset, &.{ page.total, page.next_after_id });
    assert(offset <= response.len);

    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

const SearchScope = enum(u8) { both = 0, links_only = 1, categories_only = 2 };
const SearchMode = enum(u8) { all_terms = 0, ranked = 1, hybrid = 2 };
const embedding_bytes: usize = schema.embedding_dimensions * 4;
const hybrid_query_bytes: usize = 8 + embedding_bytes;
const vector_write_bytes: usize = 8 + 8 + embedding_bytes;
const category_vector_write_bytes: usize = 8 + embedding_bytes;

const MatchField = enum(u8) { title = 0, url = 1, description = 2, semantic = 3 };

const SearchRequest = struct {
    query: []const u8,
    limit: u32,
    scope: SearchScope,
    mode: SearchMode,
    query_vector: []const u8,
    cap_per_site: bool,

    fn parse(payload: []const u8) ?SearchRequest {
        if (payload.len < 6) return null;
        const query_len: usize = std.mem.readInt(u16, payload[0..2], .little);
        if (query_len < 2) return null;
        if (2 + query_len + 4 > payload.len) return null;
        const query = payload[2..][0..query_len];
        const limit = std.mem.readInt(u32, payload[2 + query_len ..][0..4], .little);

        const trailing = payload[2 + query_len + 4 ..];
        const options = trailing[0..@min(trailing.len, 2)];
        const scope: SearchScope = if (options.len >= 1)
            std.enums.fromInt(SearchScope, options[0]) orelse return null
        else
            .both;
        const mode: SearchMode = if (options.len == 2)
            std.enums.fromInt(SearchMode, options[1]) orelse return null
        else
            .all_terms;
        const vector_len: usize = if (mode == .hybrid) hybrid_query_bytes else 0;
        const after_options = trailing[options.len..];
        if (after_options.len < vector_len) return null;
        if (after_options.len > vector_len + 1) return null;

        // The cap byte asks for at most two links a site, which only a ranked list can honour.
        const cap_byte: u8 = if (after_options.len > vector_len) after_options[vector_len] else 0;
        if (cap_byte > 1) return null;
        if (cap_byte == 1) {
            if (mode == .all_terms) return null;
        }

        const request = SearchRequest{
            .query = query,
            .limit = limit,
            .scope = scope,
            .mode = mode,
            .query_vector = after_options[0..vector_len],
            .cap_per_site = cap_byte == 1,
        };
        assert(request.query.len >= 2);
        if (request.mode != .hybrid) assert(request.query_vector.len == 0);
        if (request.mode == .hybrid) assert(request.query_vector.len == hybrid_query_bytes);
        if (request.cap_per_site) assert(request.mode != .all_terms);
        return request;
    }
};

fn link_match_field(link: *const schema.Link, query: []const u8) MatchField {
    assert(query.len > 0);
    var token_buffer: [inverted.MAX_TOKEN_LEN]u8 = undefined;
    var tokens = inverted.TokenIterator.init(query);
    var seen: u32 = 0;
    while (tokens.next(&token_buffer)) |token| : (seen += 1) {
        assert(seen < query.len);
        if (std.ascii.findIgnoreCase(link.title.slice(), token) != null) return .title;
        if (std.ascii.findIgnoreCase(link.url.slice(), token) != null) return .url;
        if (std.ascii.findIgnoreCase(link.description.slice(), token) != null) return .description;
    }
    return .semantic;
}

fn search_categories_in_mode(
    db: *Directory,
    request: *const SearchRequest,
    limit: u32,
    buffer: []schema.Category,
) ![]schema.Category {
    assert(limit <= buffer.len);
    const found = switch (request.mode) {
        .all_terms => try operations.search_categories(db, request.query, limit, buffer),
        .ranked => try operations.search_categories_ranked(db, request.query, limit, buffer),
        .hybrid => blk: {
            assert(request.query_vector.len == hybrid_query_bytes);
            const model = std.mem.readInt(u64, request.query_vector[0..8], .little);
            var embedding: vector_index.Embedding = undefined;
            vector_index.read_embedding(request.query_vector[8..][0..embedding_bytes], &embedding);
            break :blk try operations.search_categories_hybrid(
                db,
                request.query,
                model,
                &embedding,
                limit,
                buffer,
            );
        },
    };
    assert(found.len <= limit);
    return found;
}

fn search_links_in_mode(
    db: *Directory,
    request: *const SearchRequest,
    limit: u32,
    buffer: []schema.Link,
    site_rows: ?[]operations.RowSite,
) !operations.HybridLinks {
    assert(limit <= buffer.len);
    const found: operations.HybridLinks = switch (request.mode) {
        .all_terms => .{
            .links = try operations.search_links(db, request.query, limit, buffer),
            .vector_used = false,
        },
        .ranked => .{
            .links = try operations.search_links_ranked(
                db,
                request.query,
                limit,
                buffer,
                site_rows,
            ),
            .vector_used = false,
        },
        .hybrid => blk: {
            assert(request.query_vector.len == hybrid_query_bytes);
            const model = std.mem.readInt(u64, request.query_vector[0..8], .little);
            var embedding: vector_index.Embedding = undefined;
            vector_index.read_embedding(request.query_vector[8..][0..embedding_bytes], &embedding);
            break :blk try operations.search_links_hybrid(
                db,
                request.query,
                model,
                &embedding,
                limit,
                buffer,
                site_rows,
            );
        },
    };
    assert(found.links.len <= limit);
    return found;
}

fn write_row_site(response: []u8, start: usize, row: *const operations.RowSite) usize {
    assert(start + 4 + row.key_len <= response.len);
    var offset = start;
    std.mem.writeInt(u16, response[offset..][0..2], row.key_len, .little);
    offset += 2;
    @memcpy(response[offset..][0..row.key_len], row.key());
    offset += row.key_len;
    std.mem.writeInt(u16, response[offset..][0..2], row.more, .little);
    offset += 2;
    assert(offset == start + 4 + row.key_len);
    return offset;
}

fn write_counted_link_rows(
    response: []u8,
    start: usize,
    links: []const schema.Link,
    row_sites: ?[]const operations.RowSite,
    query: []const u8,
) usize {
    assert(start + 2 <= response.len);
    if (row_sites) |rows| assert(rows.len == links.len);
    var offset = start + 2;
    var written: u16 = 0;
    for (links, 0..) |*link, i| {
        const site_bytes: usize = if (row_sites) |rows| 4 + @as(usize, rows[i].key_len) else 0;
        if (offset + @sizeOf(schema.Link) + 1 + site_bytes > response.len) break;
        offset = append_row(response, offset, link);
        response[offset] = @intFromEnum(link_match_field(link, query));
        offset += 1;
        if (row_sites) |rows| offset = write_row_site(response, offset, &rows[i]);
        written += 1;
    }
    assert(written <= links.len);
    assert(offset <= response.len);
    std.mem.writeInt(u16, response[start..][0..2], written, .little);
    return offset;
}

fn handle_search(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
    const request = SearchRequest.parse(payload) orelse
        return write_error_response(response, op_byte, .invalid);
    if (response.len < response_header_size + 4) {
        return write_error_response(response, op_byte, .err);
    }
    const limit = @min(request.limit, search_results_max);
    assert(limit <= search_results_max);

    var categories_buffer: [search_results_max]schema.Category = undefined;
    const categories = if (request.scope == .links_only)
        categories_buffer[0..0]
    else
        search_categories_in_mode(db, &request, limit, &categories_buffer) catch
            &[0]schema.Category{};
    assert(categories.len <= limit);
    var offset = write_counted_category_rows(response, response_header_size, categories, 2);

    var links_buffer: [search_results_max]schema.Link = undefined;
    var row_sites: [search_results_max]operations.RowSite = undefined;
    const site_rows: ?[]operations.RowSite = if (request.cap_per_site) &row_sites else null;
    const none = operations.HybridLinks{ .links = links_buffer[0..0], .vector_used = false };
    const found = if (request.scope == .categories_only)
        none
    else
        search_links_in_mode(db, &request, limit, &links_buffer, site_rows) catch none;
    assert(found.links.len <= limit);
    const found_sites: ?[]const operations.RowSite = if (request.cap_per_site)
        row_sites[0..found.links.len]
    else
        null;
    offset = write_counted_link_rows(response, offset, found.links, found_sites, request.query);

    if (request.mode == .hybrid) {
        if (offset + 1 > response.len) return write_error_response(response, op_byte, .err);
        response[offset] = @intFromBool(found.vector_used);
        offset += 1;
    }
    assert(offset <= response.len);

    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

pub const query_links_rows_max: u8 = 50;
const query_links_words_bytes_max: usize = 256;

const QueryLinksOptions = packed struct(u64) {
    via: u4 = 0,
    hosted_only: bool = false,
    all_words: bool = false,
    group_by: u4 = 0,
    status: u8 = status_any,
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

fn handle_query_links(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
    const parsed = parsePayload(query_links_fields, payload) orelse
        return write_error_response(response, op_byte, .invalid);
    var domain_buffer: [url_facts.host_len_max]u8 = undefined;
    const request = link_query_from(&parsed.result, &domain_buffer) orelse
        return write_error_response(response, op_byte, .invalid);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    const result = operations.query_links(
        db,
        &request,
        arena.allocator(),
    ) catch |err| switch (err) {
        error.NoSearchableWords => return write_error_response(response, op_byte, .invalid),
        else => return write_mapped_error(response, op_byte, err),
    };
    assert(result.links.len <= query_links_rows_max);
    if (!result.ready) assert(result.links.len == 0);

    var body: std.Io.Writer = .fixed(response[response_header_size..]);
    write_query_links_body(&body, &result) catch
        return write_error_response_sub(response, op_byte, .invalid, .buffer_too_small);
    const len = response_header_size + body.end;
    assert(len <= response.len);
    write_ok_header(response, op_byte, len, @intCast(result.links.len));
    return len;
}

fn link_query_from(
    parsed: anytype,
    domain_buffer: *[url_facts.host_len_max]u8,
) ?operations.LinkQuery {
    const options: QueryLinksOptions = @bitCast(parsed.options);
    const domain = std.mem.trimStart(u8, parsed.domain, ".");
    if (domain.len > domain_buffer.len) return null;
    if (parsed.words.len > query_links_words_bytes_max) return null;
    if (options.group_limit > query_links_rows_max) return null;
    if (options.limit > query_links_rows_max) return null;
    if (options.status != status_any) {
        if (!is_known_link_status(options.status)) return null;
    }
    if (options.via > facts_index.Via.all) return null;
    if (options.religions & ~entities.religion_mask != 0) return null;
    if (parsed.entity.len > entities.name_len_max) return null;

    const group_by = std.enums.fromInt(facts_index.GroupBy, options.group_by) orelse return null;
    const country: ?countries.Code = switch (parsed.country.len) {
        0 => null,
        2 => blk: {
            const code: countries.Code = parsed.country[0..2].*;
            if (!countries.is_assigned(code)) return null;
            break :blk code;
        },
        else => return null,
    };
    const domain_folded = std.ascii.lowerString(domain_buffer, domain);
    assert(domain_folded.len == domain.len);

    const query = operations.LinkQuery{
        .facts = .{
            .category_id = parsed.category_id,
            .domain_suffix = domain_folded,
            .country = country,
            .via = if (options.via == 0) facts_index.Via.all else options.via,
            .religions = options.religions,
            .entity_name = parsed.entity,
            .hosted_only = options.hosted_only,
            .subdomain_only = options.subdomain_only,
            .status = if (options.status == status_any) null else options.status,
            .group_by = group_by,
            .group_limit = options.group_limit,
            .page_limit = options.limit,
            .after_id = parsed.after_id,
        },
        .words = parsed.words,
        .words_match = if (options.all_words) .all else .any,
    };
    assert(query.facts.page_limit <= query_links_rows_max);
    return query;
}

fn write_query_links_body(
    writer: *std.Io.Writer,
    result: *const operations.LinkQueryResult,
) std.Io.Writer.Error!void {
    const answer = &result.answer;
    assert(answer.groups.len <= std.math.maxInt(u16));
    assert(result.links.len <= std.math.maxInt(u16));
    try writer.writeByte(@intFromBool(result.ready));
    for ([_]u64{
        answer.total,
        answer.sites,
        answer.hosts,
        answer.domains,
    }) |value| try writer.writeInt(u64, value, .little);

    try writer.writeInt(u16, @intCast(answer.groups.len), .little);
    for (answer.groups) |group| {
        try writer.writeInt(u16, @intCast(group.label.len), .little);
        try writer.writeAll(group.label);
        try writer.writeInt(u64, group.category_id, .little);
        try writer.writeInt(u64, group.links, .little);
        try writer.writeInt(u64, group.sites, .little);
    }

    try writer.writeInt(u16, @intCast(result.links.len), .little);
    for (result.links) |*item| {
        try writer.writeAll(std.mem.asBytes(&item.link));
        try writer.writeInt(u16, @intCast(item.row.site.len), .little);
        try writer.writeAll(item.row.site);
        try writer.writeAll(&item.row.cctld);
        try writer.writeAll(&item.row.category_country);
        try writer.writeInt(u16, item.row.religions, .little);
        assert(item.row.entity_countries.len <= std.math.maxInt(u8));
        try writer.writeByte(@intCast(item.row.entity_countries.len));
        for (item.row.entity_countries) |code| try writer.writeAll(&code);
    }
    try writer.writeInt(u64, answer.next_after_id, .little);
}

fn handle_match_names(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 2) return write_error_response(response, op_byte, .invalid);
    const count = std.mem.readInt(u16, payload[0..2], .little);
    if (count == 0) return write_error_response(response, op_byte, .invalid);
    if (count > operations.name_matches_max) {
        return write_error_response(response, op_byte, .invalid);
    }

    var phrases: [operations.name_matches_max][]const u8 = undefined;
    var offset: usize = 2;
    for (phrases[0..count]) |*phrase| {
        if (offset + 2 > payload.len) return write_error_response(response, op_byte, .invalid);
        const len = std.mem.readInt(u16, payload[offset..][0..2], .little);
        offset += 2;
        if (len == 0) return write_error_response(response, op_byte, .invalid);
        if (len > facts_index.folded_name_len_max) {
            return write_error_response(response, op_byte, .invalid);
        }
        if (offset + len > payload.len) return write_error_response(response, op_byte, .invalid);
        phrase.* = payload[offset..][0..len];
        offset += len;
    }
    if (offset != payload.len) return write_error_response(response, op_byte, .invalid);

    var arena = std.heap.ArenaAllocator.init(db.scratch());
    defer arena.deinit();

    var matches: [operations.name_matches_max]operations.NameMatch = undefined;
    const ready = operations.match_names(
        db,
        arena.allocator(),
        phrases[0..count],
        matches[0..count],
    ) catch |err| return write_mapped_error(response, op_byte, err);
    const answered = if (ready) matches[0..count] else matches[0..0];
    assert(answered.len <= count);

    var body: std.Io.Writer = .fixed(response[response_header_size..]);
    write_match_names_body(&body, ready, answered) catch
        return write_error_response_sub(response, op_byte, .invalid, .buffer_too_small);
    const len = response_header_size + body.end;
    assert(len <= response.len);
    write_ok_header(response, op_byte, len, @intCast(answered.len));
    return len;
}

fn write_match_names_body(
    writer: *std.Io.Writer,
    ready: bool,
    matches: []const operations.NameMatch,
) std.Io.Writer.Error!void {
    assert(matches.len <= operations.name_matches_max);
    if (!ready) assert(matches.len == 0);
    try writer.writeByte(@intFromBool(ready));
    try writer.writeInt(u16, @intCast(matches.len), .little);
    for (matches) |match| {
        try writer.writeInt(u64, match.category_id, .little);
        try writer.writeByte(@intFromBool(match.names_someone));
    }
}

const put_results_offset: usize = response_header_size + 2 + 2;

fn handle_put_link_entities(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 2) return write_error_response(response, op_byte, .invalid);
    const count = std.mem.readInt(u16, payload[0..2], .little);
    if (count == 0) return write_error_response(response, op_byte, .invalid);
    if (count > operations.entity_writes_max) {
        return write_error_response(response, op_byte, .invalid);
    }
    if (response.len < put_results_offset + @as(usize, count) * id_result_bytes) {
        return write_error_response(response, op_byte, .err);
    }

    var writes: [operations.entity_writes_max]operations.EntityWrite = undefined;
    var offset: usize = 2;
    for (writes[0..count]) |*write| {
        if (offset + 18 > payload.len) return write_error_response(response, op_byte, .invalid);
        write.link_id = std.mem.readInt(u64, payload[offset..][0..8], .little);
        write.text_fingerprint = std.mem.readInt(u64, payload[offset + 8 ..][0..8], .little);
        const len = std.mem.readInt(u16, payload[offset + 16 ..][0..2], .little);
        offset += 18;
        if (len > entities.encoded_len_max) {
            return write_error_response(response, op_byte, .invalid);
        }
        if (offset + len > payload.len) return write_error_response(response, op_byte, .invalid);
        write.facts = payload[offset..][0..len];
        offset += len;
    }
    if (offset != payload.len) return write_error_response(response, op_byte, .invalid);

    var results: [operations.entity_writes_max]operations.EntityWriteResult = undefined;
    operations.put_link_entities(
        db,
        writes[0..count],
        results[0..count],
    ) catch |err| return write_mapped_error(response, op_byte, err);

    var ok_count: u16 = 0;
    var reply_offset: usize = put_results_offset;
    for (writes[0..count], results[0..count]) |write, result| {
        std.mem.writeInt(u64, response[reply_offset..][0..8], write.link_id, .little);
        response[reply_offset + 8] = @intFromEnum(result);
        reply_offset += id_result_bytes;
        if (result == .ok) ok_count += 1;
    }
    assert(ok_count <= count);
    assert(reply_offset == put_results_offset + @as(usize, count) * id_result_bytes);
    assert(reply_offset <= response.len);
    std.mem.writeInt(u16, response[response_header_size..][0..2], ok_count, .little);
    std.mem.writeInt(u16, response[response_header_size + 2 ..][0..2], count - ok_count, .little);
    write_ok_header(response, op_byte, reply_offset, 0);
    return reply_offset;
}

fn handle_put_category_vectors(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 10) return write_error_response(response, op_byte, .invalid);
    const model = std.mem.readInt(u64, payload[0..8], .little);
    const count = std.mem.readInt(u16, payload[8..10], .little);
    if (count == 0) return write_error_response(response, op_byte, .invalid);
    if (count > operations.vectors_per_write_max) {
        return write_error_response(response, op_byte, .invalid);
    }
    if (payload.len != 10 + @as(usize, count) * category_vector_write_bytes) {
        return write_error_response(response, op_byte, .invalid);
    }
    if (response.len < put_results_offset + @as(usize, count) * id_result_bytes) {
        return write_error_response(response, op_byte, .err);
    }

    var writes: [operations.vectors_per_write_max]operations.CategoryVectorWrite = undefined;
    for (writes[0..count], 0..) |*write, i| {
        const item_offset = 10 + i * category_vector_write_bytes;
        const item = payload[item_offset..][0..category_vector_write_bytes];
        write.category_id = std.mem.readInt(u64, item[0..8], .little);
        vector_index.read_embedding(item[8..][0..embedding_bytes], &write.embedding);
    }

    var results: [operations.vectors_per_write_max]operations.VectorWriteResult = undefined;
    operations.put_category_vectors(
        db,
        model,
        writes[0..count],
        results[0..count],
    ) catch |err| return write_mapped_error(response, op_byte, err);

    var ok_count: u16 = 0;
    var offset: usize = put_results_offset;
    for (writes[0..count], results[0..count]) |write, result| {
        std.mem.writeInt(u64, response[offset..][0..8], write.category_id, .little);
        response[offset + 8] = @intFromEnum(result);
        offset += id_result_bytes;
        if (result == .ok) ok_count += 1;
    }
    assert(ok_count <= count);
    assert(offset == put_results_offset + @as(usize, count) * id_result_bytes);
    assert(offset <= response.len);
    std.mem.writeInt(u16, response[response_header_size..][0..2], ok_count, .little);
    std.mem.writeInt(u16, response[response_header_size + 2 ..][0..2], count - ok_count, .little);
    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

fn handle_put_link_vectors(db: *Directory, response: []u8, op_byte: u8, payload: []const u8) usize {
    if (payload.len < 10) return write_error_response(response, op_byte, .invalid);
    const model = std.mem.readInt(u64, payload[0..8], .little);
    const count = std.mem.readInt(u16, payload[8..10], .little);
    if (count == 0) return write_error_response(response, op_byte, .invalid);
    if (count > operations.vectors_per_write_max) {
        return write_error_response(response, op_byte, .invalid);
    }
    if (payload.len != 10 + @as(usize, count) * vector_write_bytes) {
        return write_error_response(response, op_byte, .invalid);
    }
    if (response.len < put_results_offset + @as(usize, count) * id_result_bytes) {
        return write_error_response(response, op_byte, .err);
    }

    var writes: [operations.vectors_per_write_max]operations.VectorWrite = undefined;
    for (writes[0..count], 0..) |*write, i| {
        const item = payload[10 + i * vector_write_bytes ..][0..vector_write_bytes];
        write.link_id = std.mem.readInt(u64, item[0..8], .little);
        write.text_fingerprint = std.mem.readInt(u64, item[8..16], .little);
        vector_index.read_embedding(item[16..][0..embedding_bytes], &write.embedding);
    }

    var results: [operations.vectors_per_write_max]operations.VectorWriteResult = undefined;
    operations.put_link_vectors(
        db,
        model,
        writes[0..count],
        results[0..count],
    ) catch |err| return write_mapped_error(response, op_byte, err);

    var ok_count: u16 = 0;
    var offset: usize = put_results_offset;
    for (writes[0..count], results[0..count]) |write, result| {
        std.mem.writeInt(u64, response[offset..][0..8], write.link_id, .little);
        response[offset + 8] = @intFromEnum(result);
        offset += id_result_bytes;
        if (result == .ok) ok_count += 1;
    }
    assert(ok_count <= count);
    assert(offset == put_results_offset + @as(usize, count) * id_result_bytes);
    assert(offset <= response.len);
    std.mem.writeInt(u16, response[response_header_size..][0..2], ok_count, .little);
    std.mem.writeInt(u16, response[response_header_size + 2 ..][0..2], count - ok_count, .little);
    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

fn write_index_health_frame(state_snapshot: anytype, response: []u8) usize {
    assert(state_snapshot.indices.len <= std.math.maxInt(u8));
    var offset: usize = response_header_size;
    std.mem.writeInt(i64, response[offset..][0..8], state_snapshot.last_run_at, .little);
    offset += 8;
    response[offset] = @intCast(state_snapshot.indices.len);
    offset += 1;
    for (state_snapshot.indices) |index| {
        assert(index.name.len <= std.math.maxInt(u8));
        response[offset] = @intCast(index.name.len);
        offset += 1;
        @memcpy(response[offset..][0..index.name.len], index.name);
        offset += index.name.len;
        std.mem.writeInt(u64, response[offset..][0..8], index.expected, .little);
        offset += 8;
        std.mem.writeInt(u64, response[offset..][0..8], index.observed, .little);
        offset += 8;
        std.mem.writeInt(u32, response[offset..][0..4], index.drift_bp(), .little);
        offset += 4;
    }
    offset = write_u64s(response, offset, &.{state_snapshot.slug_path_repair_queue_depth});
    std.mem.writeInt(
        i64,
        response[offset..][0..8],
        state_snapshot.slug_path_repair_worker_last_tick_ms,
        .little,
    );
    offset += 8;
    offset = write_u64s(response, offset, &.{
        state_snapshot.slug_path_repair_worker_tasks_processed,
        state_snapshot.slug_path_repair_worker_chunks_processed,
    });
    assert(offset <= response.len);
    return offset;
}

fn handle_index_health(db: *Directory, response: []u8, op_byte: u8) usize {
    const state_snapshot = db.verifier_state.snapshot(db);
    const offset = write_index_health_frame(&state_snapshot, response);
    assert(offset >= response_header_size + 8 + 1 + 4 * 8);
    assert(offset <= response.len);
    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

fn handle_run_verifier(db: *Directory, response: []u8, op_byte: u8) usize {
    @import("verifier.zig").run_once(db, &db.verifier_state) catch |err| {
        log.warn("run_verifier failed: {}", .{err});
    };
    const written = handle_index_health(db, response, op_byte);
    assert(written >= response_header_size);
    return written;
}

fn handle_rebuild_index(db: *Directory, response: []u8, op_byte: u8) usize {
    const repair = @import("repair/repair.zig");
    const stats = repair.rebuild_all_indices(db) catch |err| {
        log.err("rebuild_index failed: {}", .{err});
        return write_mapped_error(response, op_byte, err);
    };
    const written = write_u64_frame(
        response,
        op_byte,
        &.{ stats.categories_rebuilt, stats.links_rebuilt, stats.queue_entries_drained },
    );
    assert(written <= response.len);
    if (written > response_header_size) assert(written == response_header_size + 3 * @sizeOf(u64));
    return written;
}

fn handle_snapshot(db: *Directory, response: []u8, op_byte: u8) usize {
    const result = zigstore.snapshot.forceSnapshot(db.store.snapshotHost()) catch |err| {
        if (err != error.SnapshotInProgress) {
            log.err("snapshot op failed: {}", .{err});
        }
        return write_mapped_error(response, op_byte, err);
    };
    const written = write_u64_frame(response, op_byte, &.{
        result.wal_sequence,
        result.duration_ms,
    });
    assert(written <= response.len);
    if (written > response_header_size) assert(written == response_header_size + 2 * @sizeOf(u64));
    return written;
}

fn handle_op_latency_stats(db: *Directory, response: []u8, op_byte: u8) usize {
    const per_op_bytes: usize = 1 + 7 * @sizeOf(u64);

    var offset: usize = response_header_size;
    if (offset + 1 > response.len) return write_error_response(response, op_byte, .err);
    const count_offset = offset;
    offset += 1;

    var emitted: u8 = 0;
    for (db.op_latency, 0..) |*histogram, op_index| {
        const samples = histogram.samples();
        if (samples == 0) continue;
        if (offset + per_op_bytes > response.len) break;
        // The count byte cannot say 256, so a table where every op has samples drops the last.
        if (emitted == std.math.maxInt(u8)) break;

        assert(op_index <= std.math.maxInt(u8));
        response[offset] = @intCast(op_index);
        offset = write_u64s(response, offset + 1, &.{
            histogram.percentile(50.0),
            histogram.percentile(95.0),
            histogram.percentile(99.0),
            histogram.percentile(99.9),
            histogram.maxValue(),
            histogram.mean(),
            samples,
        });
        emitted += 1;
    }
    assert(offset == response_header_size + 1 + @as(usize, emitted) * per_op_bytes);
    assert(offset <= response.len);

    response[count_offset] = emitted;
    write_ok_header(response, op_byte, offset, 0);
    return offset;
}

const BulkImportTally = struct {
    inserted: u64 = 0,
    duplicates: u64 = 0,
    errors: u64 = 0,
    first_id: u64 = 0,
    last_id: u64 = 0,
};

fn bulk_import_one(db: *Directory, item: *const ParsedLink, tally: *BulkImportTally) void {
    const created = operations.create_link(
        db,
        item.category_id,
        .{ .url = item.url, .title = item.title, .description = item.description },
    );
    if (created) |id| {
        assert(id != 0);
        tally.inserted += 1;
        if (tally.first_id == 0) tally.first_id = id;
        tally.last_id = id;
    } else |err| switch (err) {
        error.DuplicateUrl => tally.duplicates += 1,
        else => tally.errors += 1,
    }
    if (tally.inserted == 0) assert(tally.first_id == 0);
    if (tally.inserted > 0) assert(tally.last_id >= tally.first_id);
}

fn handle_bulk_import(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
    count: u16,
) usize {
    if (response.len < response_header_size + bulk_import_result_bytes) {
        return write_error_response(response, op_byte, .err);
    }
    if (payload.len > bulk_import_bytes_max) {
        log.warn(
            "bulk_import: payload {d} bytes exceeds cap {d}",
            .{ payload.len, bulk_import_bytes_max },
        );
        return write_error_response_sub(response, op_byte, .invalid, .field_too_long);
    }
    if (@as(u32, count) > bulk_import_items_max) {
        log.warn("bulk_import: count {d} exceeds cap {d}", .{ count, bulk_import_items_max });
        return write_error_response_sub(response, op_byte, .invalid, .field_too_long);
    }

    const started_at = std.Io.Clock.awake.now(db.io);
    var tally = BulkImportTally{};
    var data = payload;
    var processed: u32 = 0;
    while (processed < count) : (processed += 1) {
        const parsed = parsePayload(link_fields, data) orelse {
            const remaining = count - processed;
            tally.errors += remaining;
            log.warn(
                "bulk_import: truncated frame at item {d}/{d}, " ++
                    "{d} unread items charged as errors",
                .{ processed, count, remaining },
            );
            break;
        };
        bulk_import_one(db, &parsed.result, &tally);
        data = parsed.rest;
        if (@rem(processed + 1, bulk_import_chunk) == 0) {
            log.info("bulk_import: processed {d}/{d} (inserted={d} dup={d} err={d})", .{
                processed + 1,
                count,
                tally.inserted,
                tally.duplicates,
                tally.errors,
            });
        }
    }
    assert(processed <= count);
    assert(tally.inserted + tally.duplicates + tally.errors == count);

    const finished_at = std.Io.Clock.awake.now(db.io);
    const elapsed_ms: u64 = @intCast(started_at.durationTo(finished_at).toMilliseconds());
    log.info("bulk_import: done count={d} inserted={d} dup={d} err={d} elapsed_ms={d}", .{
        count,
        tally.inserted,
        tally.duplicates,
        tally.errors,
        elapsed_ms,
    });

    return write_u64_frame(response, op_byte, &.{
        tally.inserted,
        tally.duplicates,
        tally.errors,
        tally.first_id,
        tally.last_id,
        elapsed_ms,
    });
}

fn handle_create_submission(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (response.len < response_header_size + item_result_bytes) return 0;

    const parsed = parsePayload(link_fields, payload) orelse
        return write_error_response(response, op_byte, .invalid);
    const rest = parsed.rest;
    if (rest.len < 8) return write_error_response(response, op_byte, .invalid);
    const submitter_id = std.mem.readInt(u64, rest[0..8], .little);

    const item = parsed.result;
    const options = operations.CreateLinkOptions{
        .status = @intFromEnum(schema.LinkStatus.pending),
        .submitter_id = submitter_id,
    };
    // A submission answers like a one-item create batch so the client decodes both the same way.
    const id = operations.create_link_with_options(
        db,
        item.category_id,
        .{ .url = item.url, .title = item.title, .description = item.description },
        options,
    ) catch |err| {
        const pair = map_error_with_sub_status(err);
        const offset = write_item_result(response, response_header_size, pair, 0);
        assert(offset == response_header_size + item_result_bytes);
        write_raw_header(response, op_byte, offset, pair.status, pair.sub_status, 1);
        return offset;
    };
    const offset = write_item_result(response, response_header_size, pair_ok, id);
    assert(offset == response_header_size + item_result_bytes);
    write_ok_header(response, op_byte, offset, 1);
    return offset;
}

fn handle_update_link_status(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 9) return write_error_response(response, op_byte, .invalid);
    const id = std.mem.readInt(u64, payload[0..8], .little);
    const status = payload[8];
    if (!is_known_link_status(status)) {
        return write_error_response_sub(response, op_byte, .invalid, .unsupported_order);
    }
    operations.update_link_status(db, id, status) catch |err| {
        return write_mapped_error(response, op_byte, err);
    };
    const written = write_response(response, op_byte, .ok, 0, &.{});
    assert(written == response_header_size);
    return written;
}

const BulkResultCode = enum(u8) {
    ok = 0,
    not_found = 1,
    already_in_state = 2,
    invalid_transition = 3,
};

fn handle_bulk_link_op(
    db: *Directory,
    response: []u8,
    options: struct { op_byte: u8, status: u8 },
    payload: []const u8,
    id_offset: usize,
    comptime apply_one: fn (*Directory, u64, u8) BulkResultCode,
) usize {
    if (payload.len < id_offset + 2) {
        return write_error_response(response, options.op_byte, .invalid);
    }
    const count = std.mem.readInt(u16, payload[id_offset..][0..2], .little);
    if (count > bulk_items_max) return write_error_response(response, options.op_byte, .invalid);
    const ids_start = id_offset + 2;
    const expected_len: usize = ids_start + @as(usize, count) * 8;
    if (payload.len != expected_len) {
        return write_error_response(response, options.op_byte, .invalid);
    }
    if (response.len < response_header_size + 4) {
        return write_error_response(response, options.op_byte, .err);
    }

    const ok_count_offset = response_header_size;
    const error_count_offset = response_header_size + 2;
    var offset: usize = response_header_size + 4;
    var ok_count: u16 = 0;
    var error_count: u16 = 0;
    for (0..count) |i| {
        const id = std.mem.readInt(u64, payload[ids_start + i * 8 ..][0..8], .little);
        if (offset + id_result_bytes > response.len) break;
        const code = apply_one(db, id, options.status);
        std.mem.writeInt(u64, response[offset..][0..8], id, .little);
        response[offset + 8] = @intFromEnum(code);
        offset += id_result_bytes;
        if (code == .ok) ok_count += 1 else error_count += 1;
    }
    const answered: usize = @as(usize, ok_count) + @as(usize, error_count);
    assert(answered <= count);
    assert(offset == response_header_size + 4 + answered * id_result_bytes);
    assert(offset <= response.len);

    std.mem.writeInt(u16, response[ok_count_offset..][0..2], ok_count, .little);
    std.mem.writeInt(u16, response[error_count_offset..][0..2], error_count, .little);
    write_ok_header(response, options.op_byte, offset, 0);
    return offset;
}

fn apply_bulk_status(db: *Directory, id: u64, status: u8) BulkResultCode {
    assert(is_known_link_status(status));
    operations.update_link_status_bulk_one(db, id, status) catch |err| return switch (err) {
        error.LinkNotFound => .not_found,
        error.AlreadyInState => .already_in_state,
        else => .not_found,
    };
    return .ok;
}

fn apply_bulk_delete(db: *Directory, id: u64, status: u8) BulkResultCode {
    assert(status == 0);
    operations.delete_link(db, id) catch |err| return switch (err) {
        error.LinkNotFound => .not_found,
        else => .not_found,
    };
    return .ok;
}

fn handle_bulk_update_link_status(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    if (payload.len < 3) return write_error_response(response, op_byte, .invalid);
    const status = payload[0];
    if (!is_known_link_status(status)) return write_error_response(response, op_byte, .invalid);
    const written = handle_bulk_link_op(
        db,
        response,
        .{ .op_byte = op_byte, .status = status },
        payload,
        1,
        apply_bulk_status,
    );
    assert(written <= response.len);
    return written;
}

fn handle_bulk_delete_links(
    db: *Directory,
    response: []u8,
    op_byte: u8,
    payload: []const u8,
) usize {
    const written = handle_bulk_link_op(
        db,
        response,
        .{ .op_byte = op_byte, .status = 0 },
        payload,
        0,
        apply_bulk_delete,
    );
    assert(written <= response.len);
    return written;
}

fn handle_counts_by_status(db: *Directory, response: []u8, op_byte: u8) usize {
    const counts = operations.counts_by_status(db) catch |err| return write_mapped_error(
        response,
        op_byte,
        err,
    );
    const written = write_u64_frame(response, op_byte, &.{
        counts.pending,
        counts.approved,
        counts.rejected,
    });
    assert(written <= response.len);
    if (written > response_header_size) assert(written == response_header_size + 3 * @sizeOf(u64));
    return written;
}

fn handle_stats(db: *Directory, response: []u8, op_byte: u8) usize {
    const stats = db.get_stats();
    const written = write_u64_frame(response, op_byte, &.{
        stats.category_count,
        stats.link_count,
        @as(u64, stats.page_count),
        stats.cache_hits,
        stats.cache_misses,
        stats.wal_pending_batch_entries,
    });
    assert(written <= response.len);
    if (written > response_header_size) assert(written == response_header_size + 6 * @sizeOf(u64));
    return written;
}

// A list page holds at most 100 rows and at most 128 KiB of them, so a full page of links (69
// rows) and a full page of categories (100 rows) both fit the response reserve with room over.
fn default_list_buffer_len(comptime T: type) usize {
    const list_budget_bytes: usize = 128 * 1024;
    const row_bytes = @sizeOf(T);
    const fit: usize = if (row_bytes == 0)
        100
    else
        @max(1, @divFloor(list_budget_bytes, row_bytes));
    const len = @min(fit, 100);
    assert(len >= 1);
    assert(len <= 100);
    return len;
}

// Decodes a hand-built link payload and checks every field, the empty description included.
test "parsePayload link fields" {
    const fields = link_fields;
    var buffer: [100]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 42, .little);
    const url = "https://test.com";
    std.mem.writeInt(u16, buffer[8..10], url.len, .little);
    @memcpy(buffer[10..][0..url.len], url);
    var offset: usize = 10 + url.len;
    std.mem.writeInt(u16, buffer[offset..][0..2], 4, .little);
    offset += 2;
    @memcpy(buffer[offset..][0..4], "Test");
    offset += 4;
    std.mem.writeInt(u16, buffer[offset..][0..2], 0, .little);
    offset += 2;

    const parsed = parsePayload(fields, buffer[0..offset]).?;
    try std.testing.expectEqual(@as(u64, 42), parsed.result.category_id);
    try std.testing.expectEqualSlices(u8, url, parsed.result.url);
    try std.testing.expectEqualSlices(u8, "Test", parsed.result.title);
    try std.testing.expectEqualSlices(u8, "", parsed.result.description);
}

// Skipping a record lands on the same tail as decoding it, so error paths stay in step.
test "advancePayload matches parsePayload" {
    const fields = link_fields;
    var buffer: [100]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 1, .little);
    std.mem.writeInt(u16, buffer[8..10], 3, .little);
    @memcpy(buffer[10..13], "abc");
    std.mem.writeInt(u16, buffer[13..15], 2, .little);
    @memcpy(buffer[15..17], "xy");
    std.mem.writeInt(u16, buffer[17..19], 0, .little);

    const parsed = parsePayload(fields, buffer[0..19]).?;
    const advanced = advancePayload(fields, buffer[0..19]).?;
    try std.testing.expectEqual(parsed.rest.len, advanced.len);
}

// Reads a masked optional string: present when its bit is set, null when the bit is clear.
test "readOptionalString" {
    var buffer: [20]u8 = undefined;
    std.mem.writeInt(u16, buffer[0..2], 5, .little);
    @memcpy(buffer[2..7], "hello");

    var offset: usize = 0;
    const result = readOptionalString(&buffer, &offset, 0x01, 0x01);
    try std.testing.expect(result != null);
    try std.testing.expectEqualSlices(u8, "hello", result.?.?);
    try std.testing.expectEqual(@as(usize, 7), offset);

    var offset_2: usize = 0;
    const result2 = readOptionalString(&buffer, &offset_2, 0x00, 0x01);
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.? == null);
}

// Decodes the 17-byte subtree request field by field from a hand-built buffer.
test "list_subtree_links: parses request payload" {
    var buffer: [17]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 42, .little);
    buffer[8] = 0;
    std.mem.writeInt(u32, buffer[9..13], 100, .little);
    std.mem.writeInt(u32, buffer[13..17], 50, .little);

    const request = ListSubtreeLinksRequest.parse(buffer[0..]);
    try std.testing.expectEqual(@as(u64, 42), request.category_id);
    try std.testing.expectEqual(@as(u8, 0), request.order_code);
    try std.testing.expectEqual(@as(u32, 100), request.offset);
    try std.testing.expectEqual(@as(u32, 50), request.limit);
}

// An offset beyond subtree_offset_max fails validation with OffsetTooLarge.
test "list_subtree_links: rejects an offset past the maximum" {
    var buffer: [17]u8 = undefined;
    std.mem.writeInt(u64, buffer[0..8], 42, .little);
    buffer[8] = 0;
    std.mem.writeInt(u32, buffer[9..13], 5001, .little);
    std.mem.writeInt(u32, buffer[13..17], 50, .little);

    const request = ListSubtreeLinksRequest.parse(buffer[0..]);
    try std.testing.expectError(error.OffsetTooLarge, request.validate());
}

// The smallest subtree frame is header, count and trailer: 30 bytes, enough for no rows.
test "list_subtree_links: min_frame allows empty result set" {
    try std.testing.expectEqual(@as(usize, 30), subtree_frame_bytes_min);
}

// Queues one repair task and reads the queue depth back from the fixed tail of the frame.
test "index_health response carries slug_path_repair_queue fields" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var task = schema.RepairTask{ .cat_id = 1, .op = .renamed_slug };
    var key: [8]u8 = undefined;
    std.mem.writeInt(u64, &key, 1, .big);
    try db.slug_path_repair_queue().insert(&key, std.mem.asBytes(&task));

    var response: [4096]u8 = undefined;
    const offset = handle_index_health(db, &response, @intFromEnum(Op.index_health));
    try std.testing.expect(offset > response_header_size + 9);

    const queue_depth = std.mem.readInt(u64, response[offset - 32 ..][0..8], .little);
    try std.testing.expectEqual(@as(u64, 1), queue_depth);
}

// Every operation error maps to the (status, sub_status) pair the client is written to expect.
test "map_error_with_sub_status: maps each known error to its pair" {
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
    for (cases) |case| {
        const got = map_error_with_sub_status(case.err);
        try std.testing.expectEqual(case.status, got.status);
        try std.testing.expectEqual(case.sub, got.sub_status);
    }
}

// An error reply is the bare 10-byte header with the status at byte 5 and sub_status at byte 6.
test "write_error_response_sub: stamps sub_status into the header" {
    var buffer: [32]u8 = undefined;
    const len = write_error_response_sub(
        &buffer,
        @intFromEnum(Op.create_link),
        .invalid,
        .field_too_long,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), len);
    try std.testing.expectEqual(@as(u32, 10), std.mem.readInt(u32, buffer[0..4], .little));
    try std.testing.expectEqual(@intFromEnum(Op.create_link), buffer[4]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), buffer[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.field_too_long), buffer[6]);
    try std.testing.expectEqual(@as(u8, 0), buffer[7]);
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, buffer[8..10], .little));
}

// A payload reply keeps sub_status at none and copies the payload after the header.
test "write_response: an ok reply carries sub_status none" {
    var buffer: [64]u8 = undefined;
    const payload = [_]u8{ 1, 2, 3, 4 };
    const len = write_response(&buffer, @intFromEnum(Op.ping), .ok, 1, &payload);
    try std.testing.expectEqual(@as(usize, response_header_size + 4), len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), buffer[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.none), buffer[6]);
    try std.testing.expectEqual(@as(u8, 0), buffer[7]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, buffer[8..10], .little));
    try std.testing.expectEqualSlices(u8, &payload, buffer[response_header_size..len]);
}

// Builds a create batch with a url over url_len_max and reads the per-item pair back.
test "create_link: an oversized url answers invalid, field_too_long" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );

    const oversized = try allocator.alloc(u8, operations_shared.url_len_max + 1000);
    defer allocator.free(oversized);
    @memset(oversized, 'a');

    var payload_buffer: [16384]u8 = undefined;
    var offset: usize = 0;
    std.mem.writeInt(u64, payload_buffer[offset..][0..8], category_id, .little);
    offset += 8;
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], @intCast(oversized.len), .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..oversized.len], oversized);
    offset += oversized.len;
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], 5, .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..5], "Title");
    offset += 5;
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], 0, .little);
    offset += 2;

    var response: [256]u8 = undefined;
    const written = CreateLinks.handle(db, &response, payload_buffer[0..offset], 1);
    try std.testing.expect(written >= response_header_size + 10);

    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    const item_status: Status = @enumFromInt(response[response_header_size]);
    const item_sub: SubStatus = @enumFromInt(response[response_header_size + 1]);
    try std.testing.expectEqual(Status.invalid, item_status);
    try std.testing.expectEqual(SubStatus.field_too_long, item_sub);
}

// An order code other than 0 is refused before any read with the unsupported_order sub-status.
test "list_subtree_links: an unknown order code answers unsupported_order" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 1, .little);
    payload[8] = 99;
    std.mem.writeInt(u32, payload[9..13], 0, .little);
    std.mem.writeInt(u32, payload[13..17], 50, .little);

    var response: [256]u8 = undefined;
    const len = handle_list_subtree_links(
        db,
        &response,
        @intFromEnum(Op.list_subtree_links),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.unsupported_order), response[6]);
    try std.testing.expectEqual(@as(u8, 0), response[7]);
}

// Six leaf links, a page of two from offset one: two rows, total six and a cursor, walked once.
test "list_subtree_links: a plain page stops when full and reports the cached total" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    var category_ids: [6]u64 = undefined;
    for (0..6) |i| {
        var slug_buffer: [16]u8 = undefined;
        const slug = std.fmt.bufPrint(&slug_buffer, "c{d}", .{i}) catch unreachable;
        category_ids[i] = try operations.create_category(
            db,
            top_id,
            .{ .name = "x", .slug = slug, .description = "" },
        );
        var url_buffer: [32]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buffer, "https://x{d}.t", .{i}) catch unreachable;
        _ = try operations.create_link(
            db,
            category_ids[i],
            .{ .url = url, .title = "L", .description = "" },
        );
    }
    try db.drain_one_memtable(db.memtable_categories_by_id(), db.categories_by_id());
    try db.drain_one_memtable(db.memtable_cat_by_parent(), db.cat_by_parent());
    try db.drain_one_memtable(db.memtable_link_by_category(), db.link_by_category());
    try db.drain_one_memtable(db.memtable_links_by_id(), db.links_by_id());

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], top_id, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], 1, .little);
    std.mem.writeInt(u32, payload[13..17], 2, .little);

    var response: [4096]u8 = undefined;
    const len = handle_list_subtree_links(
        db,
        &response,
        @intFromEnum(Op.list_subtree_links),
        &payload,
    );
    const written = std.mem.readInt(u32, response[response_header_size..][0..4], .little);
    const total = std.mem.readInt(u64, response[len - 16 .. len - 8][0..8], .little);
    const next = std.mem.readInt(u64, response[len - 8 .. len][0..8], .little);

    try std.testing.expectEqual(@as(u32, 2), written);
    try std.testing.expectEqual(@as(u64, 6), total);
    try std.testing.expect(next != 0);

    const descendants = try subtree.collect_descendants_cached(
        db.cat_by_parent(),
        top_id,
        &db.subtree_cache,
        allocator,
    );
    defer allocator.free(descendants);
    const walked = try subtree.list_subtree_link_ids(
        db.link_by_category(),
        descendants,
        .{ .offset = 1, .limit = 2 },
        allocator,
    );
    defer allocator.free(walked);
    try std.testing.expectEqual(@as(usize, 2), walked.len);
}

// An offset past subtree_offset_max is refused with the offset_too_large sub-status.
test "list_subtree_links: an oversize offset answers offset_too_large" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 1, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], subtree_offset_max + 1, .little);
    std.mem.writeInt(u32, payload[13..17], 50, .little);

    var response: [256]u8 = undefined;
    const len = handle_list_subtree_links(
        db,
        &response,
        @intFromEnum(Op.list_subtree_links),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.offset_too_large), response[6]);
}

// With no samples recorded the latency frame is the header and a zero count byte.
test "op_latency_stats (23): empty histograms produce count=0 response" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var response: [4096]u8 = undefined;
    const offset = handle_op_latency_stats(db, &response, @intFromEnum(Op.op_latency_stats));
    try std.testing.expectEqual(@as(usize, response_header_size + 1), offset);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@as(u8, 0), response[response_header_size]);
}

// Pipelines five pings through process_frames and finds a ping row with five samples.
test "op_latency_stats (23): reports one row per op that has samples" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var buffer_pair: zigstore.connection.BufferPair = .{};
    var connection: zigstore.connection.Connection = .{};
    connection.buf = &buffer_pair;

    var offset: usize = 0;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        std.mem.writeInt(u32, buffer_pair.request_buf[offset..][0..4], 8, .little);
        buffer_pair.request_buf[offset + 4] = @intFromEnum(Op.ping);
        buffer_pair.request_buf[offset + 5] = 0;
        std.mem.writeInt(u16, buffer_pair.request_buf[offset + 6 ..][0..2], 0, .little);
        offset += 8;
    }
    connection.bytes_read = offset;

    protocol.processFrames(db, &connection, &Directory.dispatch, db.op_latency, response_reserve);

    var response: [4096]u8 = undefined;
    const reply_len = handle_op_latency_stats(db, &response, @intFromEnum(Op.op_latency_stats));
    try std.testing.expect(reply_len > response_header_size + 1);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const count = response[response_header_size];
    try std.testing.expect(count >= 1);

    var position: usize = response_header_size + 1;
    var found_ping = false;
    var entry_index: u8 = 0;
    while (entry_index < count) : (entry_index += 1) {
        const op_code = response[position];
        position += 1;
        const samples = std.mem.readInt(u64, response[position + 6 * 8 ..][0..8], .little);
        if (op_code == @intFromEnum(Op.ping)) {
            try std.testing.expectEqual(@as(u64, 5), samples);
            found_ping = true;
        }
        position += 7 * 8;
    }
    try std.testing.expect(found_ping);
}

// A buffer short of six u64s gets an error header; an exact-size buffer gets the full frame.
test "handle_stats refuses an undersized response buffer instead of overflowing it" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var tail: [response_header_size + 8]u8 = undefined;
    const refused = handle_stats(db, &tail, @intFromEnum(Op.stats));
    try std.testing.expect(refused <= tail.len);
    try std.testing.expectEqual(@intFromEnum(Status.err), tail[5]);

    var exact: [response_header_size + 6 * 8]u8 = undefined;
    const written = handle_stats(db, &exact, @intFromEnum(Op.stats));
    try std.testing.expectEqual(@as(usize, response_header_size + 6 * 8), written);
    try std.testing.expectEqual(@intFromEnum(Status.ok), exact[5]);
}

// Forces a snapshot and checks the reported wal_sequence against the metadata on disk.
test "snapshot op (22): writes snapshot.meta and returns wal_sequence + duration_ms" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    _ = try operations.create_category(db, 0, .{ .name = "Top", .slug = "top", .description = "" });

    var response: [128]u8 = undefined;
    const offset = handle_snapshot(db, &response, @intFromEnum(Op.snapshot));
    try std.testing.expectEqual(@as(usize, response_header_size + 16), offset);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.none), response[6]);

    const snapshot = (try zigstore.snapshot.SnapshotManager.loadSnapshotMeta(
        db.io,
        db.config.data_dir,
    )).?;
    try std.testing.expectEqual(zigstore.snapshot.SNAP_MAGIC, snapshot.magic);

    const reported_seq = std.mem.readInt(u64, response[response_header_size..][0..8], .little);
    try std.testing.expectEqual(snapshot.wal_sequence, reported_seq);
}

// With the in-progress flag set the op answers err with already_in_progress.
test "snapshot op (22): concurrent invocation returns already_in_progress" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    db.store.snapshot_in_progress.store(true, .release);
    defer db.store.snapshot_in_progress.store(false, .release);

    var response: [128]u8 = undefined;
    const offset = handle_snapshot(db, &response, @intFromEnum(Op.snapshot));
    try std.testing.expectEqual(@as(usize, response_header_size), offset);
    try std.testing.expectEqual(@intFromEnum(Status.err), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.already_in_progress), response[6]);
}

// Creates a link, then sends the same url in a batch and reads the per-item pair back.
test "create_link: a duplicate url answers duplicate, duplicate_url" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    _ = try operations.create_link(
        db,
        category_id,
        .{ .url = "https://example.com", .title = "Title", .description = "" },
    );

    var payload_buffer: [256]u8 = undefined;
    var offset: usize = 0;
    std.mem.writeInt(u64, payload_buffer[offset..][0..8], category_id, .little);
    offset += 8;
    const url = "https://example.com";
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], @intCast(url.len), .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..url.len], url);
    offset += url.len;
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], 5, .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..5], "Title");
    offset += 5;
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], 0, .little);
    offset += 2;

    var response: [256]u8 = undefined;
    const written = CreateLinks.handle(db, &response, payload_buffer[0..offset], 1);
    try std.testing.expect(written >= response_header_size + 10);
    const item_status: Status = @enumFromInt(response[response_header_size]);
    const item_sub: SubStatus = @enumFromInt(response[response_header_size + 1]);
    try std.testing.expectEqual(Status.duplicate, item_status);
    try std.testing.expectEqual(SubStatus.duplicate_url, item_sub);
}

// Fifty creates in one frame: the durable sequence has caught up and fsyncs are fewer than items.
test "a dispatched create_link frame is durable when acknowledged" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    const items = 50;
    var payload: [items * 64]u8 = undefined;
    var offset: usize = 0;
    var url_buffer: [32]u8 = undefined;
    for (0..items) |i| {
        const url = try std.fmt.bufPrint(&url_buffer, "https://g{d}.example", .{i});
        offset = append_bulk_item(
            &payload,
            offset,
            category_id,
            .{ .url = url, .title = "T", .description = "" },
        );
    }

    const fsyncs_before = db.store.walFsyncCount();
    var response: [4096]u8 = undefined;
    var gate: zigstore.protocol.FrameGate = undefined;
    _ = Directory.dispatch(
        db,
        @intFromEnum(Op.create_link),
        payload[0..offset],
        items,
        &response,
        &gate,
    );

    const wal = &db.store.wal_writer.?;
    try std.testing.expectEqual(wal.getSequence(), db.store.durableSeqPublished());
    try std.testing.expect(db.store.walFsyncCount() - fsyncs_before < items);
    try std.testing.expectEqual(@as(u64, items), (try operations.counts_by_status(db)).approved);
}

const response_status_offset: usize = 5;

// The read path runs inside the thread's scratch slab: a search dispatched through
// Directory.dispatch claims exactly one slab, answers ok, and leaves no request open.
test "a dispatched search allocates from the thread's scratch slab" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    _ = try operations.create_link(
        db,
        category_id,
        .{ .url = "https://artistic.example", .title = "artistic", .description = "" },
    );

    const query = "artistic";
    var payload: [2 + query.len + 4]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], query.len, .little);
    @memcpy(payload[2..][0..query.len], query);
    std.mem.writeInt(u32, payload[2 + query.len ..][0..4], 10, .little);

    var response: [16384]u8 = undefined;
    var gate: zigstore.protocol.FrameGate = undefined;
    const claimed_before = db.scratch_pool.claimed.load(.monotonic);
    const written = Directory.dispatch(
        db,
        @intFromEnum(Op.search),
        &payload,
        1,
        &response,
        &gate,
    );

    try std.testing.expect(written > response_header_size);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[response_status_offset]);
    try std.testing.expectEqual(claimed_before + 1, db.scratch_pool.claimed.load(.monotonic));
    try std.testing.expect(!scratch_memory.is_active());
}

fn append_bulk_item(
    buffer: []u8,
    start: usize,
    category_id: u64,
    text: operations.LinkText,
) usize {
    assert(text.url.len <= std.math.maxInt(u16));
    assert(text.title.len <= std.math.maxInt(u16));
    assert(text.description.len <= std.math.maxInt(u16));
    var offset = start;
    std.mem.writeInt(u64, buffer[offset..][0..8], category_id, .little);
    offset += 8;
    std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(text.url.len), .little);
    offset += 2;
    @memcpy(buffer[offset..][0..text.url.len], text.url);
    offset += text.url.len;
    std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(text.title.len), .little);
    offset += 2;
    @memcpy(buffer[offset..][0..text.title.len], text.title);
    offset += text.title.len;
    std.mem.writeInt(u16, buffer[offset..][0..2], @intCast(text.description.len), .little);
    offset += 2;
    @memcpy(buffer[offset..][0..text.description.len], text.description);
    offset += text.description.len;
    assert(offset <= buffer.len);
    return offset;
}

// A zero-item import answers six zero counters.
test "bulk_import (24): empty count returns all-zero stats" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var response: [128]u8 = undefined;
    const offset = handle_bulk_import(db, &response, @intFromEnum(Op.bulk_import), &.{}, 0);
    try std.testing.expectEqual(@as(usize, response_header_size + 48), offset);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.none), response[6]);

    var i: usize = 0;
    while (i < 6) : (i += 1) {
        const value_offset = response_header_size + i * 8;
        const value = std.mem.readInt(u64, response[value_offset..][0..8], .little);
        try std.testing.expectEqual(@as(u64, 0), value);
    }
}

// Packs a thousand links into one frame and checks the counts and the first and last ids.
test "bulk_import (24): inserts 1000 items in a single frame" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    const item_count: u32 = 1000;
    const payload_buffer = try allocator.alloc(u8, bulk_import_bytes_max);
    defer allocator.free(payload_buffer);

    var offset: usize = 0;
    var i: u32 = 0;
    var url_buffer: [64]u8 = undefined;
    var title_buffer: [32]u8 = undefined;
    while (i < item_count) : (i += 1) {
        const url = try std.fmt.bufPrint(&url_buffer, "https://bulk{d}.test", .{i});
        const title = try std.fmt.bufPrint(&title_buffer, "T{d}", .{i});
        offset = append_bulk_item(
            payload_buffer,
            offset,
            category_id,
            .{ .url = url, .title = title, .description = "" },
        );
    }

    var response: [128]u8 = undefined;
    const reply_len = handle_bulk_import(
        db,
        &response,
        @intFromEnum(Op.bulk_import),
        payload_buffer[0..offset],
        @intCast(item_count),
    );
    try std.testing.expectEqual(@as(usize, response_header_size + 48), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const inserted = std.mem.readInt(u64, response[response_header_size..][0..8], .little);
    const duplicates = std.mem.readInt(u64, response[response_header_size + 8 ..][0..8], .little);
    const errors = std.mem.readInt(u64, response[response_header_size + 16 ..][0..8], .little);
    const first_id = std.mem.readInt(u64, response[response_header_size + 24 ..][0..8], .little);
    const last_id = std.mem.readInt(u64, response[response_header_size + 32 ..][0..8], .little);

    try std.testing.expectEqual(@as(u64, 1000), inserted);
    try std.testing.expectEqual(@as(u64, 0), duplicates);
    try std.testing.expectEqual(@as(u64, 0), errors);
    try std.testing.expect(first_id != 0);
    try std.testing.expect(last_id >= first_id);

    try std.testing.expect((try operations.get_link(db, first_id)) != null);
    try std.testing.expect((try operations.get_link(db, last_id)) != null);
}

// A bad url in the middle counts as one error while the items around it are inserted.
test "bulk_import (24): an invalid item is counted and the rest go through" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    const oversized = try allocator.alloc(u8, operations_shared.url_len_max + 1000);
    defer allocator.free(oversized);
    @memset(oversized, 'a');

    const payload_buffer = try allocator.alloc(u8, bulk_import_bytes_max);
    defer allocator.free(payload_buffer);

    var offset: usize = 0;
    offset = append_bulk_item(
        payload_buffer,
        offset,
        category_id,
        .{ .url = "https://good1.test", .title = "G1", .description = "" },
    );
    offset = append_bulk_item(
        payload_buffer,
        offset,
        category_id,
        .{ .url = oversized, .title = "Bad", .description = "" },
    );
    offset = append_bulk_item(
        payload_buffer,
        offset,
        category_id,
        .{ .url = "https://good2.test", .title = "G2", .description = "" },
    );

    var response: [128]u8 = undefined;
    const reply_len = handle_bulk_import(
        db,
        &response,
        @intFromEnum(Op.bulk_import),
        payload_buffer[0..offset],
        3,
    );
    try std.testing.expect(reply_len == response_header_size + 48);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const inserted = std.mem.readInt(u64, response[response_header_size..][0..8], .little);
    const duplicates = std.mem.readInt(u64, response[response_header_size + 8 ..][0..8], .little);
    const errors = std.mem.readInt(u64, response[response_header_size + 16 ..][0..8], .little);

    try std.testing.expectEqual(@as(u64, 2), inserted);
    try std.testing.expectEqual(@as(u64, 0), duplicates);
    try std.testing.expectEqual(@as(u64, 1), errors);
}

// A payload over bulk_import_bytes_max is refused with field_too_long before any parse.
test "bulk_import (24): payload exceeding byte cap is rejected" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const oversized = try allocator.alloc(u8, bulk_import_bytes_max + 1);
    defer allocator.free(oversized);
    @memset(oversized, 0);

    var response: [128]u8 = undefined;
    const reply_len = handle_bulk_import(db, &response, @intFromEnum(Op.bulk_import), oversized, 1);
    try std.testing.expectEqual(@as(usize, response_header_size), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.field_too_long), response[6]);
}

// Sends a submission frame and reads the stored link back: pending, with the submitter id.
test "create_submission: writes a pending Link with the supplied submitter_id" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );

    var payload_buffer: [256]u8 = undefined;
    var offset: usize = 0;
    std.mem.writeInt(u64, payload_buffer[offset..][0..8], category_id, .little);
    offset += 8;
    const url = "https://example.com/submission";
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], @intCast(url.len), .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..url.len], url);
    offset += url.len;
    const title = "Submitted Site";
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], @intCast(title.len), .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..title.len], title);
    offset += title.len;
    const description = "Pending review.";
    std.mem.writeInt(u16, payload_buffer[offset..][0..2], @intCast(description.len), .little);
    offset += 2;
    @memcpy(payload_buffer[offset..][0..description.len], description);
    offset += description.len;
    std.mem.writeInt(u64, payload_buffer[offset..][0..8], 7777, .little);
    offset += 8;

    var response: [128]u8 = undefined;
    const reply_len = handle_create_submission(
        db,
        &response,
        @intFromEnum(Op.create_submission),
        payload_buffer[0..offset],
    );
    try std.testing.expect(reply_len >= response_header_size + 10);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const item_status: Status = @enumFromInt(response[response_header_size]);
    try std.testing.expectEqual(Status.ok, item_status);
    const id = std.mem.readInt(u64, response[response_header_size + 2 ..][0..8], .little);
    try std.testing.expect(id > 0);

    const link = (try operations.get_link(db, id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
    try std.testing.expectEqual(@as(u64, 7777), link.submitter_id);
}

// Approves a pending link through the op and reads the new status back.
test "update_link_status: flips pending to approved" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    const id = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://x.example", .title = "X", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 1 },
    );

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], id, .little);
    payload[8] = @intFromEnum(schema.LinkStatus.approved);

    var response: [64]u8 = undefined;
    const reply_len = handle_update_link_status(
        db,
        &response,
        @intFromEnum(Op.update_link_status),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const link = (try operations.get_link(db, id)).?;
    try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.approved)), link.status);
}

// Six links of mixed status: the filtered page has the three pending, the plain page all six.
test "list_all_links (op=16) with trailing status byte filters by status" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );

    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://a.example", .title = "a", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 1 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://b.example", .title = "b", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.approved), .submitter_id = 2 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://c.example", .title = "c", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 3 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://d.example", .title = "d", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.rejected), .submitter_id = 4 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://e.example", .title = "e", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.approved), .submitter_id = 5 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://f.example", .title = "f", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 6 },
    );

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 0, .little);
    std.mem.writeInt(u32, payload[4..8], 50, .little);
    payload[8] = @intFromEnum(schema.LinkStatus.pending);

    var response: [8192]u8 = undefined;
    const reply_len = ListAllLinks.handle(
        db,
        &response,
        @intFromEnum(Op.list_all_links),
        &payload,
    );
    try std.testing.expect(reply_len >= response_header_size);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const item_count = std.mem.readInt(u16, response[8..10], .little);
    try std.testing.expectEqual(@as(u16, 3), item_count);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const start = response_header_size + i * @sizeOf(schema.Link);
        const link = std.mem.bytesToValue(schema.Link, response[start..][0..@sizeOf(schema.Link)]);
        try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
    }

    var payload_all: [8]u8 = undefined;
    std.mem.writeInt(u32, payload_all[0..4], 0, .little);
    std.mem.writeInt(u32, payload_all[4..8], 50, .little);
    var response_all: [16384]u8 = undefined;
    const reply_all = ListAllLinks.handle(
        db,
        &response_all,
        @intFromEnum(Op.list_all_links),
        &payload_all,
    );
    try std.testing.expect(reply_all >= response_header_size);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response_all[5]);
    try std.testing.expectEqual(@as(u16, 6), std.mem.readInt(u16, response_all[8..10], .little));
}

// The status filter applies inside the requested category only.
test "list_links (op=13) with trailing status byte filters within a category" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    const other_id = try operations.create_category(
        db,
        0,
        .{ .name = "Other", .slug = "other", .description = "" },
    );

    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://p1.example", .title = "p1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://a1.example", .title = "a1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.approved) },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://p2.example", .title = "p2", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        other_id,
        .{ .url = "https://o1.example", .title = "o1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        other_id,
        .{ .url = "https://o2.example", .title = "o2", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], category_id, .little);
    std.mem.writeInt(u32, payload[8..12], 0, .little);
    std.mem.writeInt(u32, payload[12..16], 50, .little);
    payload[16] = @intFromEnum(schema.LinkStatus.pending);

    var response: [8192]u8 = undefined;
    const reply_len = ListLinks.handle(
        db,
        &response,
        @intFromEnum(Op.list_links),
        &payload,
    );
    try std.testing.expect(reply_len >= response_header_size);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const item_count = std.mem.readInt(u16, response[8..10], .little);
    try std.testing.expectEqual(@as(u16, 2), item_count);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const start = response_header_size + i * @sizeOf(schema.Link);
        const link = std.mem.bytesToValue(schema.Link, response[start..][0..@sizeOf(schema.Link)]);
        try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
        try std.testing.expectEqual(category_id, link.category_id);
    }
}

// The status filter applies to one submitter's links only.
test "list_links_by_submitter (op=27) with trailing status byte filters for one submitter" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://x1.example", .title = "x1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 100 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://x2.example", .title = "x2", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 100 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://x3.example", .title = "x3", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.approved), .submitter_id = 100 },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://y1.example", .title = "y1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending), .submitter_id = 200 },
    );

    var payload: [17]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 100, .little);
    std.mem.writeInt(u32, payload[8..12], 0, .little);
    std.mem.writeInt(u32, payload[12..16], 50, .little);
    payload[16] = @intFromEnum(schema.LinkStatus.pending);

    var response: [8192]u8 = undefined;
    const reply_len = ListLinksBySubmitter.handle(
        db,
        &response,
        @intFromEnum(Op.list_links_by_submitter),
        &payload,
    );
    try std.testing.expect(reply_len >= response_header_size);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const item_count = std.mem.readInt(u16, response[8..10], .little);
    try std.testing.expectEqual(@as(u16, 2), item_count);
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const start = response_header_size + i * @sizeOf(schema.Link);
        const link = std.mem.bytesToValue(schema.Link, response[start..][0..@sizeOf(schema.Link)]);
        try std.testing.expectEqual(@as(u8, @intFromEnum(schema.LinkStatus.pending)), link.status);
        try std.testing.expectEqual(@as(u64, 100), link.submitter_id);
    }
}

// Pending links in two children are returned together and the total counts only them.
test "list_subtree_links (op=17): the status byte filters the whole subtree" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const a_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "A", .slug = "a", .description = "" },
    );
    const b_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "B", .slug = "b", .description = "" },
    );

    _ = try operations.create_link_with_options(
        db,
        a_id,
        .{ .url = "https://a1.example", .title = "a1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        a_id,
        .{ .url = "https://a2.example", .title = "a2", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        a_id,
        .{ .url = "https://a3.example", .title = "a3", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.approved) },
    );
    _ = try operations.create_link_with_options(
        db,
        b_id,
        .{ .url = "https://b1.example", .title = "b1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );

    var payload: [18]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], top_id, .little);
    payload[8] = 0;
    std.mem.writeInt(u32, payload[9..13], 0, .little);
    std.mem.writeInt(u32, payload[13..17], 50, .little);
    payload[17] = @intFromEnum(schema.LinkStatus.pending);

    var response: [16384]u8 = undefined;
    const reply_len = handle_list_subtree_links(
        db,
        &response,
        @intFromEnum(Op.list_subtree_links),
        &payload,
    );
    try std.testing.expect(reply_len >= response_header_size + 4 + 8);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const returned = std.mem.readInt(u32, response[response_header_size..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 3), returned);

    const link_bytes_end = response_header_size + 4 + returned * @sizeOf(schema.Link);
    const total = std.mem.readInt(u64, response[link_bytes_end..][0..8], .little);
    try std.testing.expectEqual(@as(u64, 3), total);
}

// One flip, one already in state, one unknown id: the reply carries a code per id in order.
test "bulk_update_link_status (op=34) reports per-id result codes" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    const approved = @intFromEnum(schema.LinkStatus.approved);
    const link_a = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://a.example", .title = "a", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    const link_b = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://b.example", .title = "b", .description = "" },
        .{ .status = approved },
    );
    const missing_id: u64 = 999_999;

    var payload: [3 + 24]u8 = undefined;
    payload[0] = approved;
    std.mem.writeInt(u16, payload[1..3], 3, .little);
    std.mem.writeInt(u64, payload[3..11], link_a, .little);
    std.mem.writeInt(u64, payload[11..19], link_b, .little);
    std.mem.writeInt(u64, payload[19..27], missing_id, .little);

    var response: [256]u8 = undefined;
    const len = handle_bulk_update_link_status(
        db,
        &response,
        @intFromEnum(Op.bulk_update_link_status),
        &payload,
    );
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const ok_count = std.mem.readInt(u16, response[response_header_size..][0..2], .little);
    const err_count = std.mem.readInt(u16, response[response_header_size + 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 1), ok_count);
    try std.testing.expectEqual(@as(u16, 2), err_count);

    var offset: usize = response_header_size + 4;
    const id0 = std.mem.readInt(u64, response[offset..][0..8], .little);
    try std.testing.expectEqual(link_a, id0);
    try std.testing.expectEqual(@as(u8, 0), response[offset + 8]);
    offset += 9;
    const id1 = std.mem.readInt(u64, response[offset..][0..8], .little);
    try std.testing.expectEqual(link_b, id1);
    try std.testing.expectEqual(@as(u8, 2), response[offset + 8]);
    offset += 9;
    const id2 = std.mem.readInt(u64, response[offset..][0..8], .little);
    try std.testing.expectEqual(missing_id, id2);
    try std.testing.expectEqual(@as(u8, 1), response[offset + 8]);
    offset += 9;
    try std.testing.expectEqual(offset, len);

    try std.testing.expectEqual(approved, (try operations.get_link(db, link_a)).?.status);
}

// A count above bulk_items_max is refused before any id is read.
test "bulk_update_link_status (op=34) caps at 200" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [3]u8 = undefined;
    payload[0] = 1;
    std.mem.writeInt(u16, payload[1..3], 201, .little);
    var response: [64]u8 = undefined;
    const len = handle_bulk_update_link_status(
        db,
        &response,
        @intFromEnum(Op.bulk_update_link_status),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// Two real ids and one unknown: two ok, one error, and the real links are gone.
test "bulk_delete_links (op=35): mixed found / not-found" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    const link_a = try operations.create_link(
        db,
        category_id,
        .{ .url = "https://a.example", .title = "a", .description = "" },
    );
    const link_b = try operations.create_link(
        db,
        category_id,
        .{ .url = "https://b.example", .title = "b", .description = "" },
    );
    const missing_id: u64 = 999_999;

    var payload: [2 + 24]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 3, .little);
    std.mem.writeInt(u64, payload[2..10], link_a, .little);
    std.mem.writeInt(u64, payload[10..18], link_b, .little);
    std.mem.writeInt(u64, payload[18..26], missing_id, .little);

    var response: [256]u8 = undefined;
    _ = handle_bulk_delete_links(db, &response, @intFromEnum(Op.bulk_delete_links), &payload);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u16, 2),
        std.mem.readInt(u16, response[response_header_size..][0..2], .little),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        std.mem.readInt(u16, response[response_header_size + 2 ..][0..2], .little),
    );

    try std.testing.expect((try operations.get_link(db, link_a)) == null);
    try std.testing.expect((try operations.get_link(db, link_b)) == null);
}

// Four links across three statuses come back as the three counters.
test "counts_by_status (op=36) returns per-status totals" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const category_id = try operations.create_category(
        db,
        0,
        .{ .name = "Cat", .slug = "cat", .description = "" },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://p1.example", .title = "p1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://p2.example", .title = "p2", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.pending) },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://a1.example", .title = "a1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.approved) },
    );
    _ = try operations.create_link_with_options(
        db,
        category_id,
        .{ .url = "https://r1.example", .title = "r1", .description = "" },
        .{ .status = @intFromEnum(schema.LinkStatus.rejected) },
    );

    var response: [128]u8 = undefined;
    const len = handle_counts_by_status(db, &response, @intFromEnum(Op.counts_by_status));
    try std.testing.expectEqual(@as(usize, response_header_size + 24), len);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u64, 2),
        std.mem.readInt(u64, response[response_header_size..][0..8], .little),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        std.mem.readInt(u64, response[response_header_size + 8 ..][0..8], .little),
    );
    try std.testing.expectEqual(
        @as(u64, 1),
        std.mem.readInt(u64, response[response_header_size + 16 ..][0..8], .little),
    );
}

// The scope byte drops a section and each link row says which field matched.
test "search (op=14): scope byte filters sections and links carry match_field" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try operations.create_category(
        db,
        top_id,
        .{ .name = "Artistic", .slug = "artistic", .description = "" },
    );
    _ = try operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/x", .title = "Artistic Tutorial", .description = "" },
    );
    _ = try operations.create_link(
        db,
        top_id,
        .{ .url = "https://betaword.example", .title = "Plain Title", .description = "" },
    );

    const Parsed = struct {
        category_count: u16,
        link_count: u16,
        first_match_field: u8,
    };
    const parse = struct {
        fn run(response: []const u8) Parsed {
            var offset: usize = response_header_size;
            const category_count = std.mem.readInt(u16, response[offset..][0..2], .little);
            offset += 2 + @as(usize, category_count) * @sizeOf(schema.Category);
            const link_count = std.mem.readInt(u16, response[offset..][0..2], .little);
            offset += 2;
            assert(offset <= response.len);
            var match_field: u8 = 255;
            if (link_count > 0) match_field = response[offset + @sizeOf(schema.Link)];
            return .{
                .category_count = category_count,
                .link_count = link_count,
                .first_match_field = match_field,
            };
        }
    }.run;

    const build_payload = struct {
        fn run(buffer: []u8, query: []const u8, limit: u32, scope: ?u8) usize {
            assert(query.len <= std.math.maxInt(u16));
            std.mem.writeInt(u16, buffer[0..2], @intCast(query.len), .little);
            @memcpy(buffer[2..][0..query.len], query);
            std.mem.writeInt(u32, buffer[2 + query.len ..][0..4], limit, .little);
            var len: usize = 2 + query.len + 4;
            if (scope) |scope_byte| {
                buffer[len] = scope_byte;
                len += 1;
            }
            assert(len <= buffer.len);
            return len;
        }
    }.run;

    var payload_buffer: [64]u8 = undefined;
    var response: [16384]u8 = undefined;

    var payload_len = build_payload(&payload_buffer, "artistic", 50, null);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0..payload_len]);
    var parsed = parse(&response);
    try std.testing.expect(parsed.category_count >= 1);
    try std.testing.expect(parsed.link_count >= 1);
    try std.testing.expectEqual(@as(u8, 0), parsed.first_match_field);

    payload_len = build_payload(&payload_buffer, "artistic", 50, 1);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0..payload_len]);
    parsed = parse(&response);
    try std.testing.expectEqual(@as(u16, 0), parsed.category_count);
    try std.testing.expect(parsed.link_count >= 1);

    payload_len = build_payload(&payload_buffer, "artistic", 50, 2);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0..payload_len]);
    parsed = parse(&response);
    try std.testing.expect(parsed.category_count >= 1);
    try std.testing.expectEqual(@as(u16, 0), parsed.link_count);

    payload_len = build_payload(&payload_buffer, "betaword", 50, 1);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0..payload_len]);
    parsed = parse(&response);
    try std.testing.expectEqual(@as(u16, 1), parsed.link_count);
    try std.testing.expectEqual(@as(u8, 1), parsed.first_match_field);
}

// All-terms finds nothing for a two-word query, ranked finds the link, an unknown mode is refused.
test "search (op=14): the mode byte selects ranked matching" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    _ = try operations.create_link(
        db,
        top_id,
        .{ .url = "https://example.com/x", .title = "Bonsai Nursery", .description = "" },
    );

    const link_count = struct {
        fn run(response: []const u8) u16 {
            var offset: usize = response_header_size;
            const category_count = std.mem.readInt(u16, response[offset..][0..2], .little);
            offset += 2 + @as(usize, category_count) * @sizeOf(schema.Category);
            assert(offset + 2 <= response.len);
            return std.mem.readInt(u16, response[offset..][0..2], .little);
        }
    }.run;

    const query = "bonsai trees";
    var payload_buffer: [64]u8 = undefined;
    std.mem.writeInt(u16, payload_buffer[0..2], query.len, .little);
    @memcpy(payload_buffer[2..][0..query.len], query);
    std.mem.writeInt(u32, payload_buffer[2 + query.len ..][0..4], 50, .little);
    const base = 2 + query.len + 4;

    var response: [16384]u8 = undefined;

    payload_buffer[base] = @intFromEnum(SearchScope.links_only);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 1]);
    try std.testing.expectEqual(@as(u16, 0), link_count(&response));

    payload_buffer[base + 1] = @intFromEnum(SearchMode.all_terms);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 2]);
    try std.testing.expectEqual(@as(u16, 0), link_count(&response));

    payload_buffer[base + 1] = @intFromEnum(SearchMode.ranked);
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 2]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@as(u16, 1), link_count(&response));

    payload_buffer[base + 1] = 9;
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 2]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    payload_buffer[base + 1] = @intFromEnum(SearchMode.ranked);
    payload_buffer[base + 2] = 0;
    payload_buffer[base + 3] = 0;
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 4]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// Four links on one site and one on another: three rows, and the site's last row says two more.
test "search (op=14): the cap byte keeps two links a site" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    for ([_][]const u8{ "https://example.com/a", "https://example.com/b", "https://example.com/c", "https://example.com/d", "https://other.org/" }) |url| {
        _ = try operations.create_link(
            db,
            top_id,
            .{ .url = url, .title = "Bonsai Nursery", .description = "" },
        );
    }

    const query = "bonsai";
    var payload_buffer: [64]u8 = undefined;
    std.mem.writeInt(u16, payload_buffer[0..2], query.len, .little);
    @memcpy(payload_buffer[2..][0..query.len], query);
    std.mem.writeInt(u32, payload_buffer[2 + query.len ..][0..4], 50, .little);
    const base = 2 + query.len + 4;
    payload_buffer[base] = @intFromEnum(SearchScope.links_only);
    payload_buffer[base + 1] = @intFromEnum(SearchMode.ranked);
    payload_buffer[base + 2] = 1;

    var response: [16384]u8 = undefined;
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 3]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    var offset: usize = response_header_size + 2;
    try std.testing.expectEqual(
        @as(u16, 3),
        std.mem.readInt(u16, response[offset..][0..2], .little),
    );
    offset += 2;
    const Row = struct { site: []const u8, more: u16 };
    var rows: [3]Row = undefined;
    for (&rows) |*row| {
        offset += @sizeOf(schema.Link) + 1;
        const len = std.mem.readInt(u16, response[offset..][0..2], .little);
        row.* = .{
            .site = response[offset + 2 ..][0..len],
            .more = std.mem.readInt(u16, response[offset + 2 + len ..][0..2], .little),
        };
        offset += 4 + len;
    }
    try std.testing.expectEqual(@as(u16, 0), rows[0].more);
    try std.testing.expectEqualStrings("example.com", rows[1].site);
    try std.testing.expectEqual(@as(u16, 2), rows[1].more);
    try std.testing.expectEqualStrings("other.org", rows[2].site);

    payload_buffer[base + 2] = 2;
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 3]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    payload_buffer[base + 1] = @intFromEnum(SearchMode.all_terms);
    payload_buffer[base + 2] = 1;
    _ = handle_search(db, &response, @intFromEnum(Op.search), payload_buffer[0 .. base + 3]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// Stores one vector, refuses a short frame and a wrong model, then finds the link by vector.
test "put_link_vectors (op=37) and hybrid search (op=14 mode 2) frames" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try operations.create_link(
        db,
        top_id,
        .{ .url = "https://bonsai.example", .title = "Bonsai Nursery", .description = "" },
    );
    const link = (try operations.get_link(db, link_id)).?;
    const model: u64 = 0xB6E5;

    var put: [10 + vector_write_bytes]u8 = @splat(0);
    std.mem.writeInt(u64, put[0..8], model, .little);
    std.mem.writeInt(u16, put[8..10], 1, .little);
    std.mem.writeInt(u64, put[10..18], link_id, .little);
    std.mem.writeInt(u64, put[18..26], schema.link_text_fingerprint(&link), .little);
    std.mem.writeInt(u32, put[26..30], @bitCast(@as(f32, 1)), .little);

    var response: [16384]u8 = undefined;
    _ = handle_put_link_vectors(
        db,
        &response,
        @intFromEnum(Op.put_link_vectors),
        put[0 .. put.len - 1],
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    _ = handle_put_link_vectors(db, &response, @intFromEnum(Op.put_link_vectors), &put);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u16, 1),
        std.mem.readInt(u16, response[response_header_size..][0..2], .little),
    );
    try std.testing.expectEqual(
        link_id,
        std.mem.readInt(u64, response[response_header_size + 4 ..][0..8], .little),
    );
    try std.testing.expectEqual(@as(u8, 0), response[response_header_size + 12]);

    std.mem.writeInt(u64, put[0..8], model + 1, .little);
    _ = handle_put_link_vectors(db, &response, @intFromEnum(Op.put_link_vectors), &put);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.embedding_model_mismatch), response[6]);

    try operations.load_vector_index(db);

    const query = "zzzz";
    var search: [2 + query.len + 4 + 2 + hybrid_query_bytes]u8 = @splat(0);
    std.mem.writeInt(u16, search[0..2], query.len, .little);
    @memcpy(search[2..][0..query.len], query);
    std.mem.writeInt(u32, search[2 + query.len ..][0..4], 10, .little);
    const options_offset = 2 + query.len + 4;
    search[options_offset] = @intFromEnum(SearchScope.links_only);
    search[options_offset + 1] = @intFromEnum(SearchMode.hybrid);
    std.mem.writeInt(u64, search[options_offset + 2 ..][0..8], model, .little);
    std.mem.writeInt(u32, search[options_offset + 10 ..][0..4], @bitCast(@as(f32, 1)), .little);

    _ = handle_search(db, &response, @intFromEnum(Op.search), search[0 .. search.len - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    const len = handle_search(db, &response, @intFromEnum(Op.search), &search);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    const links_off = response_header_size + 2;
    try std.testing.expectEqual(
        @as(u16, 1),
        std.mem.readInt(u16, response[links_off..][0..2], .little),
    );
    try std.testing.expectEqual(
        link_id,
        std.mem.readInt(u64, response[links_off + 2 ..][0..8], .little),
    );
    try std.testing.expectEqual(
        @intFromEnum(MatchField.semantic),
        response[links_off + 2 + @sizeOf(schema.Link)],
    );
    try std.testing.expectEqual(@as(u8, 1), response[len - 1]);
}

fn hybrid_search_frame(buffer: []u8, query: []const u8, model: u64, axis: usize) []const u8 {
    assert(axis < schema.embedding_dimensions);
    const frame = buffer[0 .. 2 + query.len + 4 + 2 + hybrid_query_bytes];
    assert(frame.len <= buffer.len);
    @memset(frame, 0);
    std.mem.writeInt(u16, frame[0..2], @intCast(query.len), .little);
    @memcpy(frame[2..][0..query.len], query);
    std.mem.writeInt(u32, frame[2 + query.len ..][0..4], 10, .little);
    const options_offset = 2 + query.len + 4;
    frame[options_offset] = @intFromEnum(SearchScope.both);
    frame[options_offset + 1] = @intFromEnum(SearchMode.hybrid);
    std.mem.writeInt(u64, frame[options_offset + 2 ..][0..8], model, .little);
    const axis_offset = options_offset + 10 + axis * 4;
    std.mem.writeInt(u32, frame[axis_offset..][0..4], @bitCast(@as(f32, 1)), .little);
    return frame;
}

fn category_vector_frame(
    buffer: []u8,
    options: struct { model: u64, category_id: u64 },
    axis: usize,
) []const u8 {
    assert(axis < schema.embedding_dimensions);
    const frame = buffer[0 .. 10 + category_vector_write_bytes];
    assert(frame.len <= buffer.len);
    @memset(frame, 0);
    std.mem.writeInt(u64, frame[0..8], options.model, .little);
    std.mem.writeInt(u16, frame[8..10], 1, .little);
    std.mem.writeInt(u64, frame[10..18], options.category_id, .little);
    std.mem.writeInt(u32, frame[18 + axis * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
    return frame;
}

// A known category is stored, an unknown one answers not_found, a short frame is refused.
test "put_category_vectors (op=41) stores a vector for a known category" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const model: u64 = 0xB6E5;
    var put_buffer: [10 + category_vector_write_bytes]u8 = undefined;
    var response: [16384]u8 = undefined;

    const put = category_vector_frame(&put_buffer, .{ .model = model, .category_id = top_id }, 0);
    _ = handle_put_category_vectors(
        db,
        &response,
        @intFromEnum(Op.put_category_vectors),
        put[0 .. put.len - 1],
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    _ = handle_put_category_vectors(db, &response, @intFromEnum(Op.put_category_vectors), put);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u16, 1),
        std.mem.readInt(u16, response[response_header_size..][0..2], .little),
    );
    try std.testing.expectEqual(
        top_id,
        std.mem.readInt(u64, response[response_header_size + 4 ..][0..8], .little),
    );
    try std.testing.expectEqual(@as(u8, 0), response[response_header_size + 12]);

    const unknown = category_vector_frame(
        &put_buffer,
        .{ .model = model, .category_id = top_id + 100 },
        0,
    );
    _ = handle_put_category_vectors(db, &response, @intFromEnum(Op.put_category_vectors), unknown);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u16, 0),
        std.mem.readInt(u16, response[response_header_size..][0..2], .little),
    );
    try std.testing.expectEqual(
        @intFromEnum(operations.VectorWriteResult.not_found),
        response[response_header_size + 12],
    );
}

// Only the Jazz category's vector points at the query, yet its descendant link is returned.
test "hybrid search finds a link through its category's vector" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top_id = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const jazz_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "Jazz", .slug = "jazz", .description = "" },
    );
    const players_id = try operations.create_category(
        db,
        jazz_id,
        .{ .name = "Players", .slug = "players", .description = "" },
    );
    const pets_id = try operations.create_category(
        db,
        top_id,
        .{ .name = "Pets", .slug = "pets", .description = "" },
    );
    const damas_id = try operations.create_link(
        db,
        players_id,
        .{ .url = "https://damas.example", .title = "Damas", .description = "" },
    );
    const kennel_id = try operations.create_link(
        db,
        pets_id,
        .{ .url = "https://kennel.example", .title = "Kennel", .description = "" },
    );
    const model: u64 = 0xB6E5;

    var link_writes: [2]operations.VectorWrite = undefined;
    for (&link_writes, [_]u64{ damas_id, kennel_id }, [_]usize{ 1, 2 }) |*write, id, axis| {
        const link = (try operations.get_link(db, id)).?;
        write.* = .{
            .link_id = id,
            .text_fingerprint = schema.link_text_fingerprint(&link),
            .embedding = @splat(0),
        };
        write.embedding[axis] = 1;
    }
    link_writes[1].embedding[0] = 0.5;
    var link_results: [2]operations.VectorWriteResult = undefined;
    try operations.put_link_vectors(db, model, &link_writes, &link_results);

    var put_buffer: [10 + category_vector_write_bytes]u8 = undefined;
    var response: [16384]u8 = undefined;
    _ = handle_put_category_vectors(
        db,
        &response,
        @intFromEnum(Op.put_category_vectors),
        category_vector_frame(&put_buffer, .{ .model = model, .category_id = jazz_id }, 0),
    );
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    try operations.load_vector_index(db);
    try operations.load_category_vector_index(db);
    try operations.load_facts_index(db);

    var search_buffer: [2 + 16 + 4 + 2 + hybrid_query_bytes]u8 = undefined;
    _ = handle_search(
        db,
        &response,
        @intFromEnum(Op.search),
        hybrid_search_frame(&search_buffer, "saxophonists", model, 0),
    );
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);

    const category_count = std.mem.readInt(u16, response[response_header_size..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 1), category_count);
    try std.testing.expectEqual(
        jazz_id,
        std.mem.readInt(u64, response[response_header_size + 2 ..][0..8], .little),
    );

    const links_off = response_header_size + 2 + @sizeOf(schema.Category);
    try std.testing.expectEqual(
        @as(u16, 2),
        std.mem.readInt(u16, response[links_off..][0..2], .little),
    );
    try std.testing.expectEqual(
        damas_id,
        std.mem.readInt(u64, response[links_off + 2 ..][0..8], .little),
    );
}

fn query_links_request(
    buffer: []u8,
    category_id: u64,
    filter: struct { domain: []const u8, country: []const u8, words: []const u8 },
    options: QueryLinksOptions,
) ![]const u8 {
    assert(filter.domain.len <= std.math.maxInt(u16));
    assert(filter.words.len <= std.math.maxInt(u16));
    var writer: std.Io.Writer = .fixed(buffer);
    try writer.writeInt(u64, category_id, .little);
    for ([_][]const u8{ filter.domain, filter.country }) |text| {
        try writer.writeInt(u16, @intCast(text.len), .little);
        try writer.writeAll(text);
    }
    try writer.writeInt(u64, @bitCast(options), .little);
    for ([_][]const u8{ filter.words, "" }) |text| {
        try writer.writeInt(u16, @intCast(text.len), .little);
        try writer.writeAll(text);
    }
    try writer.writeInt(u64, 0, .little);
    assert(writer.end <= buffer.len);
    return buffer[0..writer.end];
}

// Unready answers a zero byte; ready answers totals, groups and rows; bad options are refused.
test "query_links (op=38) answers counts, groups and a page" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const arts = try operations.create_category(
        db,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    const subdomain_site = try operations.create_link(
        db,
        arts,
        .{ .url = "http://samvak.tripod.com/", .title = "Samvak", .description = "" },
    );
    _ = try operations.create_link(
        db,
        arts,
        .{ .url = "http://members.tripod.com/~fuzzy/", .title = "Fuzzy", .description = "" },
    );
    _ = try operations.create_link(
        db,
        arts,
        .{ .url = "http://www.uet.edu.pk/", .title = "UET", .description = "" },
    );

    const op = @intFromEnum(Op.query_links);
    const by_site: QueryLinksOptions = .{
        .status = 1,
        .group_by = @intFromEnum(facts_index.GroupBy.site),
        .group_limit = 10,
        .limit = 10,
    };
    var request_buffer: [256]u8 = undefined;
    var response: [16384]u8 = undefined;
    const body = response_header_size;

    _ = handle_query_links(
        db,
        &response,
        op,
        try query_links_request(
            &request_buffer,
            arts,
            .{ .domain = "tripod.com", .country = "", .words = "" },
            by_site,
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@as(u8, 0), response[body]);

    try operations.load_facts_index(db);
    const len = handle_query_links(
        db,
        &response,
        op,
        try query_links_request(
            &request_buffer,
            arts,
            .{ .domain = ".Tripod.com", .country = "", .words = "" },
            by_site,
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@as(u8, 1), response[body]);
    try std.testing.expectEqual(
        @as(u64, 2),
        std.mem.readInt(u64, response[body + 1 ..][0..8], .little),
    );
    try std.testing.expectEqual(
        @as(u64, 2),
        std.mem.readInt(u64, response[body + 9 ..][0..8], .little),
    );
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, response[8..10], .little));

    var offset: usize = body + 33;
    const group_count = std.mem.readInt(u16, response[offset..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 2), group_count);
    offset += 2;
    for (0..group_count) |_| {
        const label_len = std.mem.readInt(u16, response[offset..][0..2], .little);
        offset += 2 + label_len + 24;
    }

    try std.testing.expectEqual(
        @as(u16, 2),

        std.mem.readInt(u16, response[offset..][0..2], .little),
    );
    offset += 2;
    try std.testing.expectEqual(
        subdomain_site,
        std.mem.readInt(u64, response[offset..][0..8], .little),
    );
    offset += @sizeOf(schema.Link);
    const site_len = std.mem.readInt(u16, response[offset..][0..2], .little);
    try std.testing.expectEqualStrings("samvak.tripod.com", response[offset + 2 ..][0..site_len]);
    const row_tail = 4 + 2 + 1;
    const fuzzy_row = @sizeOf(schema.Link) + 2 + "members.tripod.com/~fuzzy".len + row_tail;
    try std.testing.expectEqual(len - 8, offset + 2 + site_len + row_tail + fuzzy_row);

    _ = handle_query_links(
        db,
        &response,
        op,
        try query_links_request(
            &request_buffer,
            0,
            .{ .domain = "", .country = "ZZ", .words = "" },
            by_site,
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    _ = handle_query_links(
        db,
        &response,
        op,
        try query_links_request(
            &request_buffer,
            0,
            .{ .domain = "", .country = "", .words = "" },
            .{ .limit = query_links_rows_max + 1 },
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    _ = handle_query_links(
        db,
        &response,
        op,
        try query_links_request(
            &request_buffer,
            0,
            .{ .domain = "", .country = "", .words = "" },
            .{ .group_by = 9 },
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    _ = handle_query_links(
        db,
        &response,
        op,
        try query_links_request(
            &request_buffer,
            0,
            .{ .domain = "", .country = "", .words = "a" },
            .{},
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// Art names the Arts category, an unknown phrase answers zero, and a short frame is refused.
test "match_names (op=40) answers each phrase with its category" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try operations.load_facts_index(db);

    const top = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const arts = try operations.create_category(
        db,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    _ = try operations.create_link(
        db,
        arts,
        .{ .url = "http://one.example.com/", .title = "One", .description = "" },
    );

    var request: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&request);
    try writer.writeInt(u16, 2, .little);
    for ([_][]const u8{ "Art", "no such thing" }) |phrase| {
        try writer.writeInt(u16, @intCast(phrase.len), .little);
        try writer.writeAll(phrase);
    }

    var response: [512]u8 = undefined;
    const op = @intFromEnum(Op.match_names);
    _ = handle_match_names(db, &response, op, request[0 .. writer.end - 1]);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    _ = handle_match_names(db, &response, op, request[0..writer.end]);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    const body = response[response_header_size..];
    try std.testing.expectEqual(@as(u8, 1), body[0]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, body[1..3], .little));
    try std.testing.expectEqual(arts, std.mem.readInt(u64, body[3..11], .little));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, body[12..20], .little));
}

// One valid and one invalid record answer their codes; the stored religion then filters a query.
test "put_link_entities (op=39) stores facts that query_links can filter on" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();
    try operations.load_facts_index(db);

    const top = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const link_id = try operations.create_link(
        db,
        top,
        .{
            .url = "http://www.breslov.org/",
            .title = "Breslov",
            .description = "Rebbe Nachman of Breslov",
        },
    );
    const link = (try operations.get_link(db, link_id)).?;
    const facts = "\x01\x04\x00\x01UA\x01\x0dRebbe Nachman\x00";

    var put: [2 + 18 + facts.len + 18 + 3]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&put);
    try writer.writeInt(u16, 2, .little);
    try writer.writeInt(u64, link_id, .little);
    try writer.writeInt(u64, schema.link_text_fingerprint(&link), .little);
    try writer.writeInt(u16, facts.len, .little);
    try writer.writeAll(facts);
    try writer.writeInt(u64, link_id, .little);
    try writer.writeInt(u64, schema.link_text_fingerprint(&link), .little);
    try writer.writeInt(u16, 3, .little);
    try writer.writeAll("\x02\x00\x00");

    var response: [16384]u8 = undefined;
    _ = handle_put_link_entities(
        db,
        &response,
        @intFromEnum(Op.put_link_entities),
        put[0 .. put.len - 1],
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);

    _ = handle_put_link_entities(db, &response, @intFromEnum(Op.put_link_entities), &put);
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u16, 1),
        std.mem.readInt(u16, response[response_header_size..][0..2], .little),
    );
    try std.testing.expectEqual(@as(u8, 0), response[response_header_size + 4 + 8]);
    try std.testing.expectEqual(@as(u8, 3), response[response_header_size + 4 + 9 + 8]);

    var request_buffer: [256]u8 = undefined;
    const judaism: u16 = @as(u16, 1) << @intFromEnum(entities.Religion.judaism);
    _ = handle_query_links(
        db,
        &response,
        @intFromEnum(Op.query_links),
        try query_links_request(
            &request_buffer,
            0,
            .{ .domain = "", .country = "UA", .words = "" },
            .{ .status = 1, .religions = judaism, .limit = 5 },
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(
        @as(u64, 1),
        std.mem.readInt(u64, response[response_header_size + 1 ..][0..8], .little),
    );

    _ = handle_query_links(
        db,
        &response,
        @intFromEnum(Op.query_links),
        try query_links_request(
            &request_buffer,
            0,
            .{ .domain = "", .country = "", .words = "" },
            .{ .religions = 0x8000 },
        ),
    );
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// A status byte above rejected is refused as invalid.
test "list_all_links with out-of-range status returns invalid" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u32, payload[0..4], 0, .little);
    std.mem.writeInt(u32, payload[4..8], 10, .little);
    payload[8] = 99;

    var response: [64]u8 = undefined;
    const reply_len = ListAllLinks.handle(
        db,
        &response,
        @intFromEnum(Op.list_all_links),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// A status byte above rejected answers invalid with unsupported_order.
test "update_link_status: out-of-range status returns invalid + unsupported_order" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [9]u8 = undefined;
    std.mem.writeInt(u64, payload[0..8], 1, .little);
    payload[8] = 42;

    var response: [64]u8 = undefined;
    const reply_len = handle_update_link_status(
        db,
        &response,
        @intFromEnum(Op.update_link_status),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
    try std.testing.expectEqual(@intFromEnum(SubStatus.unsupported_order), response[6]);
}

// Two known ids and one unknown: two rows in request order and a count of two.
test "get_categories_by_ids (29): mix of hits and misses returns only the hits" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const a_id = try operations.create_category(
        db,
        0,
        .{ .name = "Alpha", .slug = "alpha", .description = "" },
    );
    const b_id = try operations.create_category(
        db,
        0,
        .{ .name = "Beta", .slug = "beta", .description = "" },
    );

    const want: u16 = 3;
    var payload: [2 + 3 * 8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], want, .little);
    std.mem.writeInt(u64, payload[2..][0..8], a_id, .little);
    std.mem.writeInt(u64, payload[10..][0..8], 999_999, .little);
    std.mem.writeInt(u64, payload[18..][0..8], b_id, .little);

    var response: [4096]u8 = undefined;
    const reply_len = handle_get_categories_by_ids(
        db,
        &response,
        @intFromEnum(Op.get_categories_by_ids),
        &payload,
    );

    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    const count = std.mem.readInt(u16, response[8..10], .little);
    try std.testing.expectEqual(@as(u16, 2), count);

    const category_size = @sizeOf(schema.Category);
    try std.testing.expectEqual(
        @as(usize, response_header_size + 2 * category_size),
        reply_len,
    );

    const category_0 = std.mem.bytesToValue(
        schema.Category,
        response[response_header_size..][0..category_size],
    );
    const category_1 = std.mem.bytesToValue(
        schema.Category,
        response[response_header_size + category_size ..][0..category_size],
    );
    try std.testing.expectEqual(a_id, category_0.id);
    try std.testing.expectEqual(b_id, category_1.id);
}

// A count above get_categories_by_ids_max is refused before any id is read.
test "get_categories_by_ids (29): a count over the maximum is invalid" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [2]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], get_categories_by_ids_max + 1, .little);
    var response: [128]u8 = undefined;
    const reply_len = handle_get_categories_by_ids(
        db,
        &response,
        @intFromEnum(Op.get_categories_by_ids),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// A count of three with one id present is refused as invalid.
test "get_categories_by_ids (29): truncated payload returns invalid" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    var payload: [2 + 8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 3, .little);
    std.mem.writeInt(u64, payload[2..][0..8], 1, .little);
    var response: [128]u8 = undefined;
    const reply_len = handle_get_categories_by_ids(
        db,
        &response,
        @intFromEnum(Op.get_categories_by_ids),
        &payload,
    );
    try std.testing.expectEqual(@as(usize, response_header_size), reply_len);
    try std.testing.expectEqual(@intFromEnum(Status.invalid), response[5]);
}

// A three-deep category answers a chain of three crumbs from the root down to itself.
test "breadcrumbs_by_ids (30): returns root->leaf inclusive chain per id" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const arts = try operations.create_category(
        db,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    const music = try operations.create_category(
        db,
        arts,
        .{ .name = "Music", .slug = "music", .description = "" },
    );

    var payload: [2 + 8]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 1, .little);
    std.mem.writeInt(u64, payload[2..][0..8], music, .little);

    var response: [8192]u8 = undefined;
    const reply_len = handle_breadcrumbs_by_ids(
        db,
        &response,
        @intFromEnum(Op.breadcrumbs_by_ids),
        &payload,
    );

    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, response[8..10], .little));

    var offset: usize = response_header_size;
    try std.testing.expectEqual(
        @as(u16, 3),
        std.mem.readInt(u16, response[offset..][0..2], .little),
    );
    offset += 2;
    try std.testing.expectEqual(top, std.mem.readInt(u64, response[offset..][0..8], .little));
    offset += breadcrumb_bytes;
    try std.testing.expectEqual(arts, std.mem.readInt(u64, response[offset..][0..8], .little));
    offset += breadcrumb_bytes;
    try std.testing.expectEqual(music, std.mem.readInt(u64, response[offset..][0..8], .little));
    offset += breadcrumb_bytes;
    try std.testing.expectEqual(offset, reply_len);
}

// An unknown id answers an empty chain in its place so groups line up with the request.
test "breadcrumbs_by_ids (30): unresolved id yields an empty group, preserving order" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );

    var payload: [2 + 16]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 2, .little);
    std.mem.writeInt(u64, payload[2..][0..8], 999_999, .little);
    std.mem.writeInt(u64, payload[10..][0..8], top, .little);

    var response: [8192]u8 = undefined;
    _ = handle_breadcrumbs_by_ids(db, &response, @intFromEnum(Op.breadcrumbs_by_ids), &payload);

    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, response[8..10], .little));
    var offset: usize = response_header_size;
    try std.testing.expectEqual(
        @as(u16, 0),
        std.mem.readInt(u16, response[offset..][0..2], .little),
    );
    offset += 2;
    try std.testing.expectEqual(
        @as(u16, 1),
        std.mem.readInt(u16, response[offset..][0..2], .little),
    );
}

// With room for one chain of three, the second copy is dropped rather than cut short.
test "breadcrumbs_by_ids (30): a small reply answers whole chains only" {
    const allocator = std.testing.allocator;
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    var db = try Directory.open_test_instance(allocator, &temporary_directory);
    defer db.deinit_test_instance();

    const top = try operations.create_category(
        db,
        0,
        .{ .name = "Top", .slug = "top", .description = "" },
    );
    const arts = try operations.create_category(
        db,
        top,
        .{ .name = "Arts", .slug = "arts", .description = "" },
    );
    const music = try operations.create_category(
        db,
        arts,
        .{ .name = "Music", .slug = "music", .description = "" },
    );

    var payload: [2 + 16]u8 = undefined;
    std.mem.writeInt(u16, payload[0..2], 2, .little);
    std.mem.writeInt(u64, payload[2..][0..8], music, .little);
    std.mem.writeInt(u64, payload[10..][0..8], music, .little);

    const reply_bytes = response_header_size + 2 + 3 * breadcrumb_bytes + 2 + breadcrumb_bytes;
    var response: [reply_bytes]u8 = undefined;
    const reply_len = handle_breadcrumbs_by_ids(
        db,
        &response,
        @intFromEnum(Op.breadcrumbs_by_ids),
        &payload,
    );

    try std.testing.expectEqual(@intFromEnum(Status.ok), response[5]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, response[8..10], .little));
    try std.testing.expectEqual(
        @as(u16, 3),
        std.mem.readInt(u16, response[response_header_size..][0..2], .little),
    );
    try std.testing.expectEqual(response_header_size + 2 + 3 * breadcrumb_bytes, reply_len);
}

fn fuzz_process_frames_one(_: void, smith: *std.testing.Smith) anyerror!void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer assert(gpa.deinit() == .ok);
    var temporary_directory = std.testing.tmpDir(.{});
    defer temporary_directory.cleanup();
    const db = Directory.open_test_instance(gpa.allocator(), &temporary_directory) catch return;
    defer db.deinit_test_instance();

    var buffer_pair: zigstore.connection.BufferPair = .{};
    var connection = zigstore.connection.Connection{
        .phase = .reading_request,
        .buf = &buffer_pair,
    };
    connection.bytes_read = smith.slice(&buffer_pair.request_buf);
    protocol.processFrames(db, &connection, &Directory.dispatch, db.op_latency, response_reserve);
    assert(connection.response_len <= buffer_pair.response_buf.len);
    assert(connection.bytes_read <= buffer_pair.request_buf.len);
}

// Feeds smith-generated bytes through process_frames; nothing may panic or leak.
test "fuzz: process_frames tolerates arbitrary request frames" {
    try std.testing.fuzz({}, fuzz_process_frames_one, .{
        .corpus = &.{
            &.{},
            &[_]u8{ 8, 0, 0, 0, 255, 0, 0, 0 },
            &[_]u8{ 14, 0, 0, 0, 14, 0, 0, 0, 0xFF, 0xFF, 0, 0, 0, 0 },
            &[_]u8{ 10, 0, 0, 0, 11, 0, 0, 0, 0xFF, 0xFF },
        },
    });
}
