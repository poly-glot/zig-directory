const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const build_tools = b.option(bool, "tools", "Also build dev tools: bench, dmoz_import") orelse false;

    const zigstore = b.dependency("zigstore", .{ .target = target, .optimize = optimize }).module("zigstore");

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

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("zigstore", zigstore);
    const unit_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    if (build_tools) {
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
    }

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
    run_gen_client.addArg("web/lib/dmoz-protocol.gen.ts");
    const gen_client_step = b.step("gen-client-ts", "Regenerate web/lib/dmoz-protocol.gen.ts");
    gen_client_step.dependOn(&run_gen_client.step);
}
