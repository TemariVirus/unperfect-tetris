const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "perfect-tetris",
        .root_source_file = lazyPath(b, "src/main.zig"),
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
        .source_dir = lazyPath(b, "NNs"),
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
    const demo_exe = b.addExecutable(.{
        .name = "perfect-tetris-demo",
        .root_source_file = lazyPath(b, "src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_exe.root_module.addImport("engine", engine_module);
    demo_exe.root_module.addImport("nterm", nterm_module);

    b.installArtifact(demo_exe);

    // Add demo step
    const run_cmd = b.addRunArtifact(demo_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("demo", "Run the demo");
    demo_exe.step.dependOn(&install_NNs.step);
    run_step.dependOn(&run_cmd.step);
}

fn buildTests(b: *Build, engine_module: *Build.Module) void {
    const lib_tests = b.addTest(.{
        .root_source_file = lazyPath(b, "src/root.zig"),
    });
    lib_tests.root_module.addImport("engine", engine_module);
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
}

fn buildBench(
    b: *Build,
    target: Build.ResolvedTarget,
    engine_module: *Build.Module,
) void {
    const bench_exe = b.addExecutable(.{
        .name = "Budget Tetris Bot Benchmarks",
        .root_source_file = lazyPath(b, "src/bench.zig"),
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

fn lazyPath(b: *Build, path: []const u8) Build.LazyPath {
    return .{
        .src_path = .{
            .owner = b,
            .sub_path = path,
        },
    };
}
