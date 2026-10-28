//! Build graph for dmozdb: the server executable with its `run` step, the `test` step over the
//! `src/` and `bench/` test roots, the `-Dtools=true` executables (bench and dmoz_import, always
//! ReleaseFast so their numbers stay comparable across runs) and the `gen-client-ts` generator
//! step. Each helper registers exactly the steps its name says, so `build` fixes the step list.

const std = @import("std");
const assert = std.debug.assert;

// The top-level steps are install, uninstall, run, test and gen-client-ts.
const top_level_steps_count: u32 = 5;
const generated_client_path = "web/lib/dmoz-protocol.gen.ts";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_tools = b.option(
        bool,
        "tools",
        "Also build dev tools: bench, dmoz_import",
    ) orelse false;

    const zigstore = b.dependency(
        "zigstore",
        .{ .target = target, .optimize = optimize },
    ).module("zigstore");

    add_server(b, target, optimize, zigstore);
    add_tests(b, target, optimize, zigstore);
    if (build_tools) add_tools(b, target, zigstore);
    add_client_generator(b, target, optimize, zigstore);

    assert(b.top_level_steps.count() == top_level_steps_count);
    const installed_count: usize = if (build_tools) 3 else 1;
    assert(b.getInstallStep().dependencies.items.len == installed_count);
}

fn add_server(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigstore: *std.Build.Module,
) void {
    const installed_before = b.getInstallStep().dependencies.items.len;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("zigstore", zigstore);
    const exe = b.addExecutable(.{
        .name = "dmozdb",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run dmozdb server");
    run_step.dependOn(&run_cmd.step);

    assert(b.getInstallStep().dependencies.items.len == installed_before + 1);
    assert(run_step.dependencies.items.len == 1);
}

fn add_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigstore: *std.Build.Module,
) void {
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zigstore", zigstore);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const bench_test_mod = b.createModule(.{
        .root_source_file = b.path("bench/common.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_test_mod.addImport("zigstore", zigstore);
    const bench_tests = b.addTest(.{
        .root_module = bench_test_mod,
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_bench_tests.step);

    assert(test_step.dependencies.items.len == 2);
    assert(b.top_level_steps.contains("test"));
}

fn add_tools(b: *std.Build, target: std.Build.ResolvedTarget, zigstore: *std.Build.Module) void {
    const installed_before = b.getInstallStep().dependencies.items.len;

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_mod.addImport("zigstore", zigstore);
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = bench_mod,
    });
    b.installArtifact(bench);

    const import_mod = b.createModule(.{
        .root_source_file = b.path("src/import_main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    import_mod.addImport("zigstore", zigstore);
    const import_exe = b.addExecutable(.{
        .name = "dmoz_import",
        .root_module = import_mod,
    });
    b.installArtifact(import_exe);

    assert(bench_mod.optimize.? == import_mod.optimize.?);
    assert(b.getInstallStep().dependencies.items.len == installed_before + 2);
}

fn add_client_generator(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zigstore: *std.Build.Module,
) void {
    comptime assert(std.mem.endsWith(u8, generated_client_path, ".gen.ts"));

    const gen_client_mod = b.createModule(.{
        .root_source_file = b.path("src/gen_client_ts.zig"),
        .target = target,
        .optimize = optimize,
    });
    gen_client_mod.addImport("zigstore", zigstore);
    const gen_client_exe = b.addExecutable(.{
        .name = "gen_client_ts",
        .root_module = gen_client_mod,
    });
    const run_gen_client = b.addRunArtifact(gen_client_exe);
    run_gen_client.addArg(generated_client_path);
    const gen_client_step = b.step("gen-client-ts", "Regenerate " ++ generated_client_path);
    gen_client_step.dependOn(&run_gen_client.step);

    assert(gen_client_step.dependencies.items.len == 1);
    assert(b.top_level_steps.contains("gen-client-ts"));
}
