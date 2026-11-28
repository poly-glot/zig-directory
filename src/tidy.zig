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
const tree_entries_max: u32 = 4096;
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
    // Lines of the body less the lines of functions nested in it, so a function that holds a
    // local struct with methods is measured too, without charging it for those methods.
    line_count_own: u32,
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

    fn enclosing_other(functions: *Functions, inner_index: usize) ?u32 {
        assert(inner_index < functions.count);
        const inner = functions.items[inner_index];
        var best: ?u32 = null;
        for (functions.slice(), 0..) |outer, index| {
            if (outer.body_start >= inner.body_start) continue;
            if (outer.body_end <= inner.body_end) continue;
            if (best) |best_index| {
                if (outer.body_start < functions.items[best_index].body_start) continue;
            }
            best = @intCast(index);
        }
        if (best) |index| assert(index != inner_index);
        return best;
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
    // The self-tests count violations without printing them.
    quiet: bool,

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
        if (report.quiet) return;
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
        .quiet = false,
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
        if (entries >= tree_entries_max) return error.TidyTreeTooLarge;
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

    try tidy_source(gpa, display_path, text, report);
}

fn tidy_source(
    gpa: std.mem.Allocator,
    display_path: []const u8,
    text: [:0]const u8,
    report: *Report,
) !void {
    assert(display_path.len > 0);
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
    collect_functions(file, &tree, &functions, report);
    check_functions(file, &tree, &functions, report);
    check_calls(file, &tree, &functions, report);
    check_loops(file, &tree, report);
    check_declarations(file, &tree, report);
    check_usize_aliases(file, &tree, report);

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

fn collect_functions(
    file: SourceFile,
    tree: *const Ast,
    functions: *Functions,
    report: *Report,
) void {
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        if (tree.nodeTag(node) != .fn_decl) continue;
        if (functions.count == functions_per_file_max) {
            report.violation(file, 0, "more than {d} functions in one file", .{
                functions_per_file_max,
            });
            break;
        }

        const proto_node, const body_node = tree.nodeData(node).node_and_node;
        var buffer: [1]Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, proto_node).?;
        const body_start = tree.tokenStart(tree.firstToken(body_node));
        const body_end = tree.tokenStart(tree.lastToken(body_node));
        assert(body_start <= body_end);
        assert(functions.count < functions_per_file_max);
        const line_first = file.line_of(body_start);
        const line_last = file.line_of(body_end);

        functions.items[functions.count] = .{
            .name = tree.tokenSlice(proto.name_token.?),
            .proto_node = proto_node,
            .body_start = body_start,
            .body_end = body_end,
            .line_first = line_first,
            .line_last = line_last,
            .line_count_own = line_last - line_first,
            .assert_count = 0,
        };
        functions.count += 1;
    }
    assert(functions.count <= functions_per_file_max);
    subtract_nested_lines(functions);
}

// Each nested function's lines come off the function that most closely encloses it.
fn subtract_nested_lines(functions: *Functions) void {
    for (functions.slice(), 0..) |inner, inner_index| {
        const parent_index = functions.enclosing_other(inner_index) orelse continue;
        const parent = &functions.items[parent_index];
        assert(parent.body_start < inner.body_start);
        const nested_lines = inner.line_last - inner.line_first + 1;
        parent.line_count_own -|= nested_lines;
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
        assert(function.line_count_own <= function.line_last - function.line_first);
        if (function.line_count_own > function_line_count_max) {
            report.violation(file, function.line_first, "`{s}` is {d} lines; the limit is {d}", .{
                function.name,
                function.line_count_own,
                function_line_count_max,
            });
        }
        check_function_name(file, function, report);
        check_function_parameters(file, tree, function, report);
    }
}

/// Names that a dependency's comptime interface dictates: zigstore's tsgen reads
/// `FieldTable.tsType`, std.json looks its hooks up by these exact names, and a stand-in for a
/// zigstore tree must answer `rangeScan` as `BPlusTree` does.
const interface_names = [_][]const u8{
    "tsType",
    "rangeScan",
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
/// its two same-typed parameters are not a dimensionality smell. A `bool` function with more
/// same-typed parameters than that (`in_range(low, high, value)`) is not a comparator.
fn is_comparator(tree: *const Ast, proto: Ast.full.FnProto) bool {
    const return_node = proto.ast.return_type.unwrap() orelse return false;
    const return_source = tree.getNodeSource(return_node);
    assert(return_source.len > 0);
    const returns_order = std.mem.endsWith(u8, return_source, "Order");
    if (!returns_order and !std.mem.eql(u8, return_source, "bool")) return false;

    var types: [3][]const u8 = undefined;
    var count: u32 = 0;
    var parameters = proto.iterate(tree);
    while (parameters.next()) |parameter| : (count += 1) {
        if (count == types.len) return false;
        const type_node = parameter.type_expr orelse return false;
        types[count] = tree.getNodeSource(type_node);
    }
    assert(count <= types.len);
    if (count < 2) return false;
    const a = types[count - 2];
    const b = types[count - 1];
    if (!std.mem.eql(u8, a, b)) return false;
    if (count == 3) return !std.mem.eql(u8, types[0], a);
    return true;
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

        if (std.mem.eql(u8, callee.name, "assert") and !asserts_literal(tree, node)) {
            caller.assert_count += 1;
        }
        if (std.mem.eql(u8, callee.name, caller.name) and calls_own_type(tree, caller.*, callee)) {
            report.violation(
                file,
                file.line_of(offset),
                "`{s}` calls itself: recursion is banned",
                .{caller.name},
            );
        }
        // A method call through the caller's first parameter (`self.pong()` inside `ping`) is
        // an edge like a plain call; a call on any other receiver (`list.deinit()`,
        // `Store.init()`) names another type's function and is not.
        if (callee.receiver) |receiver| {
            const first = first_parameter_name(tree, caller.*) orelse continue;
            if (!std.mem.eql(u8, receiver, first)) continue;
        }
        for (functions.slice(), 0..) |candidate, candidate_index| {
            if (std.mem.eql(u8, candidate.name, callee.name)) {
                reach[caller_index].set(candidate_index);
            }
        }
    }

    check_call_cycles(file, functions, reach[0..functions.count], report);
}

const Callee = struct { name: []const u8, receiver: ?[]const u8 };

// `assert(true)` states nothing, so it does not pay toward the assertion density.
fn asserts_literal(tree: *const Ast, node: Ast.Node.Index) bool {
    var buffer: [1]Ast.Node.Index = undefined;
    const call = tree.fullCall(&buffer, node).?;
    if (call.ast.params.len != 1) return false;
    const argument = call.ast.params[0];
    if (tree.nodeTag(argument) != .identifier) return false;
    const name = tree.tokenSlice(tree.nodeMainToken(argument));
    assert(name.len > 0);
    return std.mem.eql(u8, name, "true") or std.mem.eql(u8, name, "false");
}

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
    const first = first_parameter_name(tree, caller) orelse return false;
    return std.mem.eql(u8, first, receiver);
}

fn first_parameter_name(tree: *const Ast, function: Function) ?[]const u8 {
    var buffer: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buffer, function.proto_node).?;
    var parameters = proto.iterate(tree);
    const first = parameters.next() orelse return null;
    const name_token = first.name_token orelse return null;
    const name = tree.tokenSlice(name_token);
    assert(name.len > 0);
    return name;
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
        if (tree.fullWhile(node)) |loop| {
            if (!condition_is_constant(tree, loop.ast.cond_expr)) continue;
            assert(loop.ast.while_token < tree.tokens.len);
            const offset = tree.tokenStart(loop.ast.while_token);
            assert(offset < file.text.len);
            report.violation(file, file.line_of(offset), "`while` on a constant has no bound", .{});
        } else if (tree.nodeTag(node) == .for_range) {
            const range_end = tree.nodeData(node).node_and_opt_node[1].unwrap() orelse continue;
            const end_source = tree.getNodeSource(range_end);
            if (std.mem.indexOf(u8, end_source, "maxInt(") == null) continue;
            const offset = tree.tokenStart(tree.firstToken(node));
            report.violation(file, file.line_of(offset), "`for` up to maxInt has no bound", .{});
        }
    }
}

// `true`, or a comparison of two number literals such as `1 == 1`: a condition that can never
// change, so the loop is bounded by nothing.
fn condition_is_constant(tree: *const Ast, condition: Ast.Node.Index) bool {
    switch (tree.nodeTag(condition)) {
        .identifier => {
            const name = tree.tokenSlice(tree.nodeMainToken(condition));
            assert(name.len > 0);
            return std.mem.eql(u8, name, "true");
        },
        .equal_equal,
        .bang_equal,
        .less_than,
        .greater_than,
        .less_or_equal,
        .greater_or_equal,
        => {
            const left, const right = tree.nodeData(condition).node_and_node;
            if (tree.nodeTag(left) != .number_literal) return false;
            return tree.nodeTag(right) == .number_literal;
        },
        else => return false,
    }
}

const usize_aliases_max: u32 = 16;

// `const Index = usize;` and then `index: Index` is still a usize field, so the names a file
// gives to usize are collected first and its fields checked against them.
fn check_usize_aliases(file: SourceFile, tree: *const Ast, report: *Report) void {
    var aliases: [usize_aliases_max][]const u8 = undefined;
    var alias_count: u32 = 0;
    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const declaration = tree.fullVarDecl(node) orelse continue;
        const init_node = declaration.ast.init_node.unwrap() orelse continue;
        if (!std.mem.eql(u8, tree.getNodeSource(init_node), "usize")) continue;
        if (alias_count == usize_aliases_max) break;
        aliases[alias_count] = tree.tokenSlice(declaration.ast.mut_token + 1);
        alias_count += 1;
    }
    assert(alias_count <= usize_aliases_max);
    if (alias_count == 0) return;

    for (0..tree.nodes.len) |index| {
        const node: Ast.Node.Index = @enumFromInt(index);
        const field = tree.fullContainerField(node) orelse continue;
        const type_node = field.ast.type_expr.unwrap() orelse continue;
        const type_source = tree.getNodeSource(type_node);
        for (aliases[0..alias_count]) |alias| {
            if (!std.mem.eql(u8, type_source, alias)) continue;
            report.violation(
                file,
                file.line_of(tree.tokenStart(field.ast.main_token)),
                "field `{s}` is usize through `{s}`: use an explicitly sized integer",
                .{ tree.tokenSlice(field.ast.main_token), alias },
            );
        }
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

fn violations_in(text: [:0]const u8) !u32 {
    var report = Report{
        .violation_count = 0,
        .file_count = 0,
        .function_count = 0,
        .assert_count = 0,
        .quiet = true,
    };
    try tidy_source(std.testing.allocator, "fixture.zig", text, &report);
    assert(report.file_count == 0);
    return report.violation_count;
}

const Fixture = struct { name: []const u8, text: [:0]const u8, violations: u32 };

const fixture_long_body = "    _ = 0;\n" ** (function_line_count_max + 4);

const fixtures = [_]Fixture{
    .{ .name = "clean", .violations = 0, .text =
    \\fn add(left: u32, right: i64) u32 {
    \\    _ = right;
    \\    return left;
    \\}
    \\
    },
    .{ .name = "direct recursion", .violations = 2, .text =
    \\fn walk(depth: u32) void {
    \\    if (depth > 0) walk(depth - 1);
    \\}
    \\
    },
    .{ .name = "recursion through the receiver", .violations = 2, .text =
    \\const Node = struct {
    \\    fn ping(node: *Node, depth: u32) void {
    \\        if (depth > 0) node.pong(depth - 1);
    \\    }
    \\    fn pong(node: *Node, depth: u32) void {
    \\        if (depth > 0) node.ping(depth - 1);
    \\    }
    \\};
    \\
    },
    .{ .name = "a call on another receiver is not recursion", .violations = 0, .text =
    \\const List = struct {
    \\    fn deinit(list: *List, other: *List) void {
    \\        other.deinit(list);
    \\    }
    \\};
    \\
    },
    .{ .name = "while true", .violations = 1, .text =
    \\fn spin() void {
    \\    while (true) {}
    \\}
    \\
    },
    .{ .name = "while on a literal comparison", .violations = 1, .text =
    \\fn spin() void {
    \\    while (1 == 1) {}
    \\}
    \\
    },
    .{ .name = "for up to maxInt", .violations = 1, .text =
    \\const std = @import("std");
    \\fn spin() void {
    \\    for (0..std.math.maxInt(u64)) |_| {}
    \\}
    \\
    },
    .{
        .name = "long function",
        .violations = 1,
        .text = "fn long() void {\n" ++ fixture_long_body ++ "}\n",
    },
    .{
        .name = "long function holding a nested function",
        .violations = 1,
        .text = "fn long() void {\n" ++ fixture_long_body ++
            "    const Local = struct {\n        fn tiny() void {}\n    };\n" ++
            "    _ = Local;\n}\n",
    },
    .{ .name = "same-typed integers", .violations = 1, .text =
    \\fn span(low: u32, high: u32) void {
    \\    _ = low;
    \\    _ = high;
    \\}
    \\
    },
    .{ .name = "same-typed integers returning bool", .violations = 1, .text =
    \\fn in_range(low: u32, high: u32, value: u32) bool {
    \\    return low <= value and value <= high;
    \\}
    \\
    },
    .{ .name = "comparator", .violations = 0, .text =
    \\fn less_than(context: void, left: u32, right: u32) bool {
    \\    _ = context;
    \\    return left < right;
    \\}
    \\
    },
    .{ .name = "three strings", .violations = 1, .text =
    \\fn join(first: []const u8, second: []const u8, third: []const u8) void {
    \\    _ = .{ first, second, third };
    \\}
    \\
    },
    .{ .name = "usize field", .violations = 1, .text =
    \\const Slot = struct { index: usize };
    \\
    },
    .{ .name = "usize field through an alias", .violations = 1, .text =
    \\const Index = usize;
    \\const Slot = struct { index: Index };
    \\
    },
    .{ .name = "function name", .violations = 1, .text =
    \\fn doThing() void {}
    \\
    },
    .{ .name = "type function name", .violations = 1, .text =
    \\fn Make() type {
    \\    return u8;
    \\}
    \\
    },
    .{ .name = "screaming constant", .violations = 1, .text =
    \\const SIZE_MAX = 4;
    \\
    },
    .{ .name = "lowercase comment", .violations = 1, .text =
    \\// lower case start.
    \\const size_max = 4;
    \\
    },
    .{ .name = "comment without a space", .violations = 1, .text =
    \\//No space.
    \\const size_max = 4;
    \\
    },
    .{ .name = "comment without a full stop", .violations = 1, .text =
    \\// No full stop
    \\const size_max = 4;
    \\
    },
    .{
        .name = "banned word",
        .violations = 1,
        .text = "// " ++ "TO" ++ "DO: later.\nconst size_max = 4;\n",
    },
    .{ .name = "tab", .violations = 1, .text = "const size_max =\t4;\n" },
    .{
        .name = "long line",
        .violations = 1,
        .text = "const name = \"" ++ "x" ** line_length_max ++ "\";\n",
    },
    .{ .name = "does not parse", .violations = 1, .text = "const = ;\n" },
    .{
        .name = "assert(true) does not count toward density",
        .violations = 1,
        .text = "fn one() void {\n    assert(true);\n    assert(true);\n}\n" ** 5,
    },
};

// Goal: every mechanical rule demonstrably fires, so a regression in one is caught here rather
// than by a clean run over a tree that happens not to break it. Method: one small source per
// rule, checked through the same path as a file on disk, against its expected violation count.
test "tidy: each rule fires on a fixture that breaks it" {
    var failures: u32 = 0;
    for (fixtures) |fixture| {
        const found = try violations_in(fixture.text);
        if (found == fixture.violations) continue;
        failures += 1;
        std.debug.print("tidy fixture `{s}`: {d} violations, expected {d}\n", .{
            fixture.name,
            found,
            fixture.violations,
        });
    }
    try std.testing.expectEqual(@as(u32, 0), failures);
}

// Goal: a file with more functions than the checker holds is a violation, not a crash. Method:
// generate one function past the maximum and check it.
test "tidy: too many functions in one file is reported, not asserted" {
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..functions_per_file_max + 1) |index| {
        try text.print(gpa, "fn function_{d}() void {{}}\n", .{index});
    }
    const source = try text.toOwnedSliceSentinel(gpa, 0);
    defer gpa.free(source);

    // The functions also carry no assertions, which is the second violation.
    try std.testing.expectEqual(@as(u32, 2), try violations_in(source));
}
