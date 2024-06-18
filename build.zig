const std = @import("std");
const Build = std.Build;

pub fn build(b: *Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Engine dependency
    const engine_module = b.dependency("engine", .{
        .target = target,
        .optimize = optimize,
    }).module("engine");
    const nterm_module = engine_module.import_table.get("nterm").?;

    // zmai dependency
    const zmai_module = b.dependency("zmai", .{
        .target = target,
        .optimize = optimize,
    }).module("zmai");

    // Add NN files
    const install_NNs = b.addInstallDirectory(.{
        .source_dir = lazyPath(b, "NNs"),
        .install_dir = .bin,
        .install_subdir = "NNs",
    });

    buildExe(b, target, optimize, engine_module, zmai_module, install_NNs);
    buildDemo(b, target, optimize, engine_module, nterm_module, zmai_module, install_NNs);
    buildTests(b, engine_module, zmai_module);
    buildBench(b, target, engine_module, zmai_module);
    buildTrain(b, target, optimize, engine_module, zmai_module);
    buildDisplay(b, target, optimize, engine_module, nterm_module);
}

fn buildExe(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_module: *Build.Module,
    zmai_module: *Build.Module,
    install_NNs: *Build.Step.InstallDir,
) void {
    const exe = b.addExecutable(.{
        .name = "perfect-tetris",
        .root_source_file = lazyPath(b, "src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("engine", engine_module);
    exe.root_module.addImport("zmai", zmai_module);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const install = b.addInstallArtifact(exe, .{});
    run_step.dependOn(&install.step);
    install.step.dependOn(&install_NNs.step);
}

fn buildDemo(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_module: *Build.Module,
    nterm_module: *Build.Module,
    zmai_module: *Build.Module,
    install_NNs: *Build.Step.InstallDir,
) void {
    const demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = lazyPath(b, "src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_exe.root_module.addImport("engine", engine_module);
    demo_exe.root_module.addImport("nterm", nterm_module);
    demo_exe.root_module.addImport("zmai", zmai_module);

    const run_cmd = b.addRunArtifact(demo_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const demo_step = b.step("demo", "Run the demo");
    demo_step.dependOn(&run_cmd.step);

    const install = b.addInstallArtifact(demo_exe, .{});
    demo_step.dependOn(&install.step);
    install.step.dependOn(&install_NNs.step);
}

fn buildTests(
    b: *Build,
    engine_module: *Build.Module,
    zmai_module: *Build.Module,
) void {
    const lib_tests = b.addTest(.{
        .root_source_file = lazyPath(b, "src/root.zig"),
    });
    lib_tests.root_module.addImport("engine", engine_module);
    lib_tests.root_module.addImport("zmai", zmai_module);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
}

fn buildBench(
    b: *Build,
    target: Build.ResolvedTarget,
    engine_module: *Build.Module,
    zmai_module: *Build.Module,
) void {
    const bench_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_source_file = lazyPath(b, "src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("engine", engine_module);
    bench_exe.root_module.addImport("zmai", zmai_module);

    const bench_cmd = b.addRunArtifact(bench_exe);
    bench_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        bench_cmd.addArgs(args);
    }
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_cmd.step);
}

fn buildTrain(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_module: *Build.Module,
    zmai_module: *Build.Module,
) void {
    const train_exe = b.addExecutable(.{
        .name = "nn-train",
        .root_source_file = lazyPath(b, "src/train.zig"),
        .target = target,
        .optimize = optimize,
    });
    train_exe.root_module.addImport("engine", engine_module);
    train_exe.root_module.addImport("zmai", zmai_module);

    const train_cmd = b.addRunArtifact(train_exe);
    train_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        train_cmd.addArgs(args);
    }
    const train_step = b.step("train", "Train neural networks");
    train_step.dependOn(&train_cmd.step);

    const install = b.addInstallArtifact(train_exe, .{});
    train_step.dependOn(&install.step);
}

fn buildDisplay(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_module: *Build.Module,
    nterm_module: *Build.Module,
) void {
    const display_exe = b.addExecutable(.{
        .name = "display",
        .root_source_file = lazyPath(b, "src/display.zig"),
        .target = target,
        .optimize = optimize,
    });
    display_exe.root_module.addImport("engine", engine_module);
    display_exe.root_module.addImport("nterm", nterm_module);

    const run_cmd = b.addRunArtifact(display_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const display_step = b.step("display", "Display PC solutions");
    display_step.dependOn(&run_cmd.step);

    const install = b.addInstallArtifact(display_exe, .{});
    display_step.dependOn(&install.step);
}

fn lazyPath(b: *Build, path: []const u8) Build.LazyPath {
    return .{
        .src_path = .{
            .owner = b,
            .sub_path = path,
        },
    };
}
