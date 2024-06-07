const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "perfect-tetris",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    b.installArtifact(exe);

    // Engine dependency
    const engine_module = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
    }).module("engine");
    exe.root_module.addImport("engine", engine_module);

    const nterm_module = engine_module.import_table.get("nterm").?;

    // Add NN files
    const install_NNs = b.addInstallDirectory(.{
        .source_dir = .{ .path = "NNs" },
        .install_dir = .bin,
        .install_subdir = "NNs",
    });
    exe.step.dependOn(&install_NNs.step);

    // Add run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    buildDemo(b, target, optimize, engine_module, nterm_module, install_NNs);
    buildTests(b, engine_module);
    buildBench(b, target, engine_module);
}

fn buildDemo(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_module: *Build.Module,
    nterm_module: *Build.Module,
    install_NNs: *Build.Step.InstallDir,
) void {
    const train_exe = b.addExecutable(.{
        .name = "perfect-tetris-demo",
        .root_source_file = .{ .path = "src/demo.zig" },
        .target = target,
        .optimize = optimize,
    });
    train_exe.root_module.addImport("engine", engine_module);
    train_exe.root_module.addImport("nterm", nterm_module);

    b.installArtifact(train_exe);

    // Add demo step
    const run_cmd = b.addRunArtifact(train_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("demo", "Run the demo");
    train_exe.step.dependOn(&install_NNs.step);
    run_step.dependOn(&run_cmd.step);
}

fn buildTests(b: *Build, engine_module: *Build.Module) void {
    const lib_tests = b.addTest(.{
        .root_source_file = .{ .path = "src/root.zig" },
    });
    lib_tests.root_module.addImport("engine", engine_module);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
}

fn buildBench(b: *Build, target: Build.ResolvedTarget, engine_module: *Build.Module) void {
    const bench_exe = b.addExecutable(.{
        .name = "Budget Tetris Bot Benchmarks",
        .root_source_file = .{ .path = "src/bench.zig" },
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("engine", engine_module);

    b.installArtifact(bench_exe);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}
