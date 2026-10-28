//! Tidy enforces the mechanical half of TigerStyle (https://tigerstyle.dev) on every Zig file
//! under `src/` and `bench/`, and on `build.zig`. It runs as part of `zig build test`, and it
//! depends on nothing but `std`, so `zig test src/tidy.zig` also works on any host.
//!
//! The judgement half (assertions on arguments and invariants, static allocation, push ifs up
//! and fors down, naming that says what a thing is) lives in `.claude/rules/zig.md` and in
//! review. Everything a parser can decide is decided here, once, for every file.

const std = @import("std");
const assert = std.debug.assert;
const Ast = std.zig.Ast;

const line_length_max: u32 = 100;
const function_line_count_max: u32 = 70;
const file_size_max: u32 = 4 * 1024 * 1024;
const functions_per_file_max: u32 = 512;
const assertion_density_min: f64 = 2.0;
const assertion_density_functions_min: u32 = 5;
const source_roots = [_][]const u8{ "src", "bench" };
const source_files_extra = [_][]const u8{"build.zig"};

const SourceFile = struct {
    path: []const u8,
    text: [:0]const u8,
    line_starts: []const u32,

    fn line_of(file: SourceFile, offset: u32) u32 {
        assert(file.line_starts.len > 0);
        assert(file.line_starts[0] == 0);

        var low: u32 = 0;
        var high: u32 = @intCast(file.line_starts.len);
        var iterations: u32 = 0;
        while (low < high) : (iterations += 1) {
            assert(iterations < 64);
            const middle = low + (high - low) / 2;
            if (file.line_starts[middle] <= offset) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }

        assert(low > 0);
        assert(low <= file.line_starts.len);
        assert(file.line_starts[low - 1] <= offset);
        return low - 1;
    }
};

const Function = struct {
    name: []const u8,
    proto_node: Ast.Node.Index,
    body_start: u32,
    body_end: u32,
    line_first: u32,
    line_last: u32,
    innermost: bool,
    assert_count: u32,
};

const Functions = struct {
    items: [functions_per_file_max]Function,
    count: u32,

    fn slice(functions: *Functions) []Function {
        assert(functions.count <= functions_per_file_max);
        const result = functions.items[0..functions.count];
        assert(result.len == functions.count);
        return result;
    }

    fn enclosing(functions: *Functions, offset: u32) ?u32 {
        var best: ?u32 = null;
        for (functions.slice(), 0..) |function, index| {
            if (offset < function.body_start) continue;
            if (offset > function.body_end) continue;
            if (best) |best_index| {
                const best_function = functions.items[best_index];
                if (function.body_start < best_function.body_start) continue;
            }
            best = @intCast(index);
        }
        if (best) |index| {
            assert(index < functions.count);
            assert(functions.items[index].body_start <= offset);
            assert(offset <= functions.items[index].body_end);
        }
        return best;
    }
};

const Report = struct {
    violation_count: u32,
    file_count: u32,
    function_count: u32,
    assert_count: u32,

    fn violation(
        report: *Report,
        file: SourceFile,
        line: u32,
        comptime format: []const u8,
        arguments: anytype,
    ) void {
        assert(line < file.line_starts.len);
        assert(file.path.len > 0);
        report.violation_count += 1;
        std.debug.print("{s}:{d}: " ++ format ++ "\n", .{ file.path, line + 1 } ++ arguments);
    }
};

// Walks every Zig file once, runs each check and prints every violation at once rather than
// stopping at the first, so one run shows the whole distance to clean.
test "tidy: every Zig file follows the mechanical TigerStyle rules" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var report = Report{
        .violation_count = 0,
        .file_count = 0,
        .function_count = 0,
        .assert_count = 0,
    };
    for (source_roots) |root| try tidy_tree(io, gpa, root, &report);
    for (source_files_extra) |path| try tidy_file(io, gpa, std.Io.Dir.cwd(), path, path, &report);

    assert(report.file_count > 0);
    const density = @as(f64, @floatFromInt(report.assert_count)) /
        @as(f64, @floatFromInt(@max(report.function_count, 1)));
    std.debug.print(
        "tidy: {d} files, {d} functions, {d} assertions ({d:.2} per function), {d} violations\n",
        .{
            report.file_count,
            report.function_count,
            report.assert_count,
            density,
            report.violation_count,
        },
    );
    if (report.violation_count > 0) return error.TidyViolations;
}

fn tidy_tree(io: std.Io, gpa: std.mem.Allocator, root: []const u8, report: *Report) !void {
    assert(root.len > 0);

    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try dir.walk(gpa);
    defer walker.deinit();

    var entries: u32 = 0;
    while (try walker.next(io)) |entry| : (entries += 1) {
        assert(entries < 4096);
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;

        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ root, entry.path });
        try tidy_file(io, gpa, dir, entry.path, path, report);
    }
}

fn tidy_file(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    sub_path: []const u8,
    display_path: []const u8,
    report: *Report,
) !void {
    assert(std.mem.endsWith(u8, display_path, ".zig"));
    assert(sub_path.len > 0);
    report.file_count += 1;

    const text = try dir.readFileAllocOptions(
        io,
        sub_path,
        gpa,
        .limited(file_size_max),
        .of(u8),
        0,
    );
    defer gpa.free(text);

    const line_starts = try line_starts_of(gpa, text);
    defer gpa.free(line_starts);

    const file = SourceFile{ .path = display_path, .text = text, .line_starts = line_starts };
    check_control_characters(file, report);
    check_line_lengths(file, report);
    check_comments(file, report);
    check_banned(file, report);

    var tree = try Ast.parse(gpa, text, .zig);
    defer tree.deinit(gpa);
    assert(tree.nodes.len > 0);
    if (tree.errors.len > 0) {
        report.violation(file, 0, "does not parse", .{});
        return;
    }

    var functions = Functions{ .items = undefined, .count = 0 };
    collect_functions(file, &tree, &functions);
    check_functions(file, &tree, &functions, report);
    check_calls(file, &tree, &functions, report);
    check_loops(file, &tree, report);
    check_declarations(file, &tree, report);

    report.function_count += functions.count;
    for (functions.slice()) |function| report.assert_count += function.assert_count;
    check_assertion_density(file, &functions, report);
}

/// TigerStyle asks for two assertions per function on average. Checking the average per file
/// keeps the average honest: a dense file cannot pay for an empty one. Files with only a few
/// functions are judged in review instead.
fn check_assertion_density(file: SourceFile, functions: *Functions, report: *Report) void {
    if (functions.count < assertion_density_functions_min) return;
    assert(functions.count >= assertion_density_functions_min);

    var assert_count: u32 = 0;
    for (functions.slice()) |function| assert_count += function.assert_count;
    const density = @as(f64, @floatFromInt(assert_count)) /
        @as(f64, @floatFromInt(functions.count));
    assert(density >= 0.0);
    if (density >= assertion_density_min) return;
    report.violation(
        file,
        0,
        "{d} assertions in {d} functions ({d:.2} per function); the minimum is {d:.1}",
        .{ assert_count, functions.count, density, assertion_density_min },
    );
}

fn line_starts_of(gpa: std.mem.Allocator, text: []const u8) ![]u32 {
    var count: u32 = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    assert(count >= 1);

    const line_starts = try gpa.alloc(u32, count);
    errdefer gpa.free(line_starts);
    assert(line_starts.len == count);

    line_starts[0] = 0;
    var next: u32 = 1;
    for (text, 0..) |byte, offset| {
        if (byte != '\n') continue;
        line_starts[next] = @intCast(offset + 1);
        next += 1;
    }

    assert(next == count);
    assert(line_starts[0] == 0);
    return line_starts;
}

fn check_control_characters(file: SourceFile, report: *Report) void {
    assert(file.line_starts.len > 0);
    if (std.mem.indexOfScalar(u8, file.text, '\t')) |offset| {
        report.violation(file, file.line_of(@intCast(offset)), "contains a tab", .{});
    }
    if (std.mem.indexOfScalar(u8, file.text, '\r')) |offset| {
        report.violation(file, file.line_of(@intCast(offset)), "contains a carriage return", .{});
    }
}

fn check_line_lengths(file: SourceFile, report: *Report) void {
    var lines = std.mem.splitScalar(u8, file.text, '\n');
    var line_index: u32 = 0;
    while (lines.next()) |line| : (line_index += 1) {
        assert(line_index < file.line_starts.len);
        const length = std.unicode.utf8CountCodepoints(line) catch line.len;
        if (length <= line_length_max) continue;
        if (has_link(line)) continue;
        if (multiline_string_value(line)) |value| {
            const value_length = std.unicode.utf8CountCodepoints(value) catch value.len;
            if (value_length <= line_length_max) continue;
        }
        report.violation(file, line_index, "line exceeds {d} columns", .{line_length_max});
    }
    assert(line_index == file.line_starts.len);
}

fn has_link(line: []const u8) bool {
    return std.mem.indexOf(u8, line, "https://") != null;
}

fn multiline_string_value(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, trimmed, "\\\\")) return null;
    assert(trimmed.len >= 2);
    return trimmed[2..];
}

const CommentBlock = struct {
    line_first: u32,
    line_last: u32,
    first_text: []const u8,
    last_text: []const u8,
};

fn check_comments(file: SourceFile, report: *Report) void {
    var lines = std.mem.splitScalar(u8, file.text, '\n');
    var line_index: u32 = 0;
    var block: ?CommentBlock = null;
    while (lines.next()) |line| : (line_index += 1) {
        assert(line_index < file.line_starts.len);
        const text = comment_text(line) orelse {
            if (block) |open| check_comment_block(file, open, report);
            block = null;
            continue;
        };
        if (block) |*open| {
            open.line_last = line_index;
            open.last_text = text;
        } else {
            block = .{
                .line_first = line_index,
                .line_last = line_index,
                .first_text = text,
                .last_text = text,
            };
        }
    }
    if (block) |open| check_comment_block(file, open, report);
    assert(line_index == file.line_starts.len);
}

fn comment_text(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " ");
    if (!std.mem.startsWith(u8, trimmed, "//")) return null;
    const after_slashes = std.mem.trimStart(u8, trimmed, "/");
    assert(after_slashes.len + 2 <= trimmed.len);
    if (std.mem.startsWith(u8, after_slashes, "!")) {
        assert(after_slashes.len >= 1);
        return after_slashes[1..];
    }
    return after_slashes;
}

fn check_comment_block(file: SourceFile, block: CommentBlock, report: *Report) void {
    assert(block.line_first <= block.line_last);
    assert(block.line_last < file.line_starts.len);
    if (std.mem.eql(u8, std.mem.trim(u8, block.first_text, " "), "zig fmt: off")) return;
    if (std.mem.eql(u8, std.mem.trim(u8, block.first_text, " "), "zig fmt: on")) return;

    if (block.first_text.len == 0) {
        report.violation(file, block.line_first, "empty comment", .{});
        return;
    }
    if (block.first_text[0] != ' ') {
        report.violation(file, block.line_first, "comment needs a space after the slashes", .{});
        return;
    }

    const first = std.mem.trim(u8, block.first_text, " ");
    if (first.len > 0 and std.ascii.isLower(first[0])) {
        report.violation(file, block.line_first, "comment must start with a capital letter", .{});
    }

    const last = std.mem.trimEnd(u8, block.last_text, " ");
    if (last.len == 0) return;
    if (has_link(last)) return;
    switch (last[last.len - 1]) {
        '.', ':', '?', '!' => {},
        else => report.violation(
            file,
            block.line_last,
            "comment must end with a full stop or a colon",
            .{},
        ),
    }
}

fn check_banned(file: SourceFile, report: *Report) void {
    const Ban = struct { needle: []const u8, reason: []const u8 };
    const bans = [_]Ban{
        .{ .needle = "Self = " ++ "@This()", .reason = "use the type name instead of Self" },
        .{ .needle = "std.debug." ++ "assert(", .reason = "import assert and call assert()" },
        .{ .needle = "FIX" ++ "ME", .reason = "address it before merging" },
        .{ .needle = "TO" ++ "DO", .reason = "zero technical debt: do it now or file an issue" },
    };
    for (bans) |ban| {
        assert(ban.needle.len > 0);
        assert(ban.reason.len > 0);
        const offset = std.mem.indexOf(u8, file.text, ban.needle) orelse continue;
        assert(offset + ban.needle.len <= file.text.len);
        report.violation(file, file.line_of(@intCast(offset)), "banned `{s}`: {s}", .{
            ban.needle,
            ban.reason,
        });
    }
}

fn collect_functions(file: SourceFile, tree: *const Ast, functions: *Functions) void {
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) continue;

        const proto_node, const body_node = tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        const body_start = tree.tokenStart(tree.firstToken(body_node));
        const body_end = tree.tokenStart(tree.lastToken(body_node));
        assert(body_start <= body_end);
        assert(functions.count < functions_per_file_max);

        functions.items[functions.count] = .{
            .name = tree.tokenSlice(proto.name_token.?),
            .proto_node = proto_node,
            .body_start = body_start,
            .body_end = body_end,
            .line_first = file.line_of(body_start),
            .line_last = file.line_of(body_end),
            .innermost = true,
            .assert_count = 0,
        };
        functions.count += 1;
    }
    assert(functions.count <= functions_per_file_max);

    for (functions.slice()) |*outer| {
        for (functions.slice()) |inner| {
            if (inner.body_start <= outer.body_start) continue;
            if (inner.body_end >= outer.body_end) continue;
            outer.innermost = false;
        }
    }
}

fn check_functions(
    file: SourceFile,
    tree: *const Ast,
    functions: *Functions,
    report: *Report,
) void {
    for (functions.slice()) |function| {
        assert(function.body_start <= function.body_end);
        assert(function.line_first <= function.line_last);
        const line_count = function.line_last - function.line_first;
        if (function.innermost and line_count > function_line_count_max) {
            report.violation(file, function.line_first, "`{s}` is {d} lines; the limit is {d}", .{
                function.name,
                line_count,
                function_line_count_max,
            });
        }
        check_function_name(file, function, report);
        check_function_parameters(file, tree, function, report);
    }
}

/// Names that a dependency's comptime interface dictates: zigstore's tsgen reads
/// `FieldTable.tsType`, and std.json looks its hooks up by these exact names.
const interface_names = [_][]const u8{
    "tsType",
    "jsonStringify",
    "jsonParse",
    "jsonParseFromValue",
};

fn check_function_name(file: SourceFile, function: Function, report: *Report) void {
    const name = function.name;
    assert(name.len > 0);
    assert(function.line_first < file.line_starts.len);

    if (std.ascii.isUpper(name[0])) {
        if (!std.mem.endsWith(u8, name, "Type")) {
            report.violation(
                file,
                function.line_first,
                "`{s}` returns a type, so end it with `Type`",
                .{name},
            );
        }
        return;
    }
    for (interface_names) |interface_name| {
        if (std.mem.eql(u8, name, interface_name)) return;
    }
    if (!is_snake_case(name)) {
        report.violation(file, function.line_first, "`{s}` is not snake_case", .{name});
    }
}

fn is_snake_case(name: []const u8) bool {
    assert(name.len > 0);
    for (name) |byte| {
        if (std.ascii.isLower(byte)) continue;
        if (std.ascii.isDigit(byte)) continue;
        if (byte == '_') continue;
        return false;
    }
    return true;
}

fn is_screaming_case(name: []const u8) bool {
    assert(name.len > 0);
    var letters: u32 = 0;
    for (name) |byte| {
        if (std.ascii.isUpper(byte)) {
            letters += 1;
            continue;
        }
        if (std.ascii.isDigit(byte)) continue;
        if (byte == '_') continue;
        return false;
    }
    assert(letters <= name.len);
    return letters >= 2;
}

const integer_type_names = [_][]const u8{
    "u8",  "u16", "u32", "u64", "u128", "usize",
    "i8",  "i16", "i32", "i64", "i128", "isize",
    "f32", "f64",
};

/// Two scalars of one type are mix-up prone (TigerStyle's rule); two strings are often a
/// natural pair (`key`, `value`), so strings are flagged from three.
const string_type_name = "[]const u8";
const string_parameters_max: u32 = 2;

fn check_function_parameters(
    file: SourceFile,
    tree: *const Ast,
    function: Function,
    report: *Report,
) void {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, function.proto_node).?;
    if (is_comparator(tree, proto)) return;
    var counts = [_]u32{0} ** integer_type_names.len;

    var parameters = proto.iterate(tree);
    var parameter_count: u32 = 0;
    var string_count: u32 = 0;
    while (parameters.next()) |parameter| : (parameter_count += 1) {
        assert(parameter_count < 64);
        const type_node = parameter.type_expr orelse continue;
        const type_source = tree.getNodeSource(type_node);
        for (integer_type_names, 0..) |name, index| {
            if (std.mem.eql(u8, type_source, name)) counts[index] += 1;
        }
        if (std.mem.eql(u8, type_source, string_type_name)) string_count += 1;
    }
    assert(parameter_count <= 64);
    assert(string_count <= parameter_count);
    if (string_count > string_parameters_max) {
        report.violation(
            file,
            function.line_first,
            "`{s}` takes {d} `{s}` parameters: use an options struct",
            .{ function.name, string_count, string_type_name },
        );
    }

    for (counts, 0..) |count, index| {
        if (count < 2) continue;
        report.violation(
            file,
            function.line_first,
            "`{s}` takes {d} `{s}` parameters: use an options struct",
            .{ function.name, count, integer_type_names[index] },
        );
    }
}

/// `std.sort` dictates a comparator's shape (`fn (context, a: T, b: T) bool` or `Order`), so
/// its two same-typed parameters are not a dimensionality smell.
fn is_comparator(tree: *const Ast, proto: Ast.full.FnProto) bool {
    const return_node = proto.ast.return_type.unwrap() orelse return false;
    const return_source = tree.getNodeSource(return_node);
    assert(return_source.len > 0);
    if (std.mem.eql(u8, return_source, "bool")) return true;
    return std.mem.endsWith(u8, return_source, "Order");
}

fn check_calls(file: SourceFile, tree: *const Ast, functions: *Functions, report: *Report) void {
    assert(functions.count <= functions_per_file_max);
    var reach: [functions_per_file_max]std.StaticBitSet(functions_per_file_max) = undefined;
    for (reach[0..functions.count]) |*row| row.* = .initEmpty();

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const callee = callee_name(tree, node) orelse continue;
        const offset = tree.tokenStart(tree.nodeMainToken(node));
        const caller_index = functions.enclosing(offset) orelse continue;
        assert(caller_index < functions.count);
        const caller = &functions.items[caller_index];

        if (std.mem.eql(u8, callee.name, "assert")) caller.assert_count += 1;
        if (std.mem.eql(u8, callee.name, caller.name) and calls_own_type(tree, caller.*, callee)) {
            report.violation(
                file,
                file.line_of(offset),
                "`{s}` calls itself: recursion is banned",
                .{caller.name},
            );
        }
        if (callee.receiver != null) continue;
        for (functions.slice(), 0..) |candidate, candidate_index| {
            if (std.mem.eql(u8, candidate.name, callee.name)) {
                reach[caller_index].set(candidate_index);
            }
        }
    }

    check_call_cycles(file, functions, reach[0..functions.count], report);
}

const Callee = struct { name: []const u8, receiver: ?[]const u8 };

fn callee_name(tree: *const Ast, node: Ast.Node.Index) ?Callee {
    switch (tree.nodeTag(node)) {
        .call_one, .call_one_comma, .call, .call_comma => {},
        else => return null,
    }
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    const callee = call.ast.fn_expr;
    switch (tree.nodeTag(callee)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(callee));
            assert(name.len > 0);
            return .{ .name = name, .receiver = null };
        },
        .field_access => {
            const receiver_node, const name_token = tree.nodeData(callee).node_and_token;
            const receiver = if (tree.nodeTag(receiver_node) == .identifier)
                tree.tokenSlice(tree.nodeMainToken(receiver_node))
            else
                "";
            const name = tree.tokenSlice(name_token);
            assert(name.len > 0);
            return .{ .name = name, .receiver = receiver };
        },
        else => return null,
    }
}

/// A method call through the first parameter (`self.deinit()` inside `deinit`) is recursion;
/// the same name on another receiver (`protocol.write_response(...)`) is a wrapper.
fn calls_own_type(tree: *const Ast, caller: Function, callee: Callee) bool {
    assert(caller.name.len > 0);
    assert(std.mem.eql(u8, caller.name, callee.name));
    const receiver = callee.receiver orelse return true;
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, caller.proto_node).?;
    var parameters = proto.iterate(tree);
    const first = parameters.next() orelse return false;
    const name_token = first.name_token orelse return false;
    return std.mem.eql(u8, tree.tokenSlice(name_token), receiver);
}

fn check_call_cycles(
    file: SourceFile,
    functions: *Functions,
    reach: []std.StaticBitSet(functions_per_file_max),
    report: *Report,
) void {
    assert(reach.len == functions.count);

    var rounds: u32 = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        assert(rounds <= functions.count);
        changed = false;
        for (reach, 0..) |*row, from| {
            var targets = row.iterator(.{});
            var steps: u32 = 0;
            while (targets.next()) |to| : (steps += 1) {
                assert(steps < functions_per_file_max);
                if (to == from) continue;
                const before = row.count();
                row.setUnion(reach[to]);
                if (row.count() != before) changed = true;
            }
        }
    }

    for (reach, 0..) |row, index| {
        if (!row.isSet(index)) continue;
        const function = functions.items[index];
        report.violation(file, function.line_first, "`{s}` is part of a recursive call cycle", .{
            function.name,
        });
    }
}

fn check_loops(file: SourceFile, tree: *const Ast, report: *Report) void {
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const loop = tree.fullWhile(node) orelse continue;
        const condition = loop.ast.cond_expr;
        if (tree.nodeTag(condition) != .identifier) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(condition)), "true")) continue;
        assert(loop.ast.while_token < tree.tokens.len);
        const offset = tree.tokenStart(loop.ast.while_token);
        assert(offset < file.text.len);
        report.violation(file, file.line_of(offset), "`while (true)` has no bound", .{});
    }
}

fn check_declarations(file: SourceFile, tree: *const Ast, report: *Report) void {
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        switch (tree.nodeTag(node)) {
            .simple_var_decl, .global_var_decl, .local_var_decl, .aligned_var_decl => {
                const name_token = tree.nodeMainToken(node) + 1;
                assert(name_token < tree.tokens.len);
                const name = tree.tokenSlice(name_token);
                assert(name.len > 0);
                if (!is_screaming_case(name)) continue;
                report.violation(
                    file,
                    file.line_of(tree.tokenStart(name_token)),
                    "`{s}`: constants are snake_case with the qualifier last",
                    .{name},
                );
            },
            .container_field_init, .container_field_align, .container_field => {
                const field = tree.fullContainerField(node).?;
                const type_node = field.ast.type_expr.unwrap() orelse continue;
                const type_source = tree.getNodeSource(type_node);
                if (std.mem.indexOf(u8, type_source, "usize") == null) continue;
                const name = tree.tokenSlice(field.ast.main_token);
                report.violation(
                    file,
                    file.line_of(tree.tokenStart(field.ast.main_token)),
                    "field `{s}` is usize: use an explicitly sized integer",
                    .{name},
                );
            },
            else => {},
        }
    }
}
