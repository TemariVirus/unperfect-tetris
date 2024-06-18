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
    buildBench(b, target, engine_module, zmai_module, install_NNs);
    buildTrain(b, target, optimize, engine_module, zmai_module);
    buildRead(b, target, optimize, engine_module, nterm_module, install_NNs);
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

    exe.step.dependOn(&install_NNs.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
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

    demo_exe.step.dependOn(&install_NNs.step);
    b.installArtifact(demo_exe);

    const run_cmd = b.addRunArtifact(demo_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("demo", "Run the demo");
    run_step.dependOn(&run_cmd.step);
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
    install_NNs: *Build.Step.InstallDir,
) void {
    const bench_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_source_file = lazyPath(b, "src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("engine", engine_module);
    bench_exe.root_module.addImport("zmai", zmai_module);

    bench_exe.step.dependOn(&install_NNs.step);

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

    b.installArtifact(train_exe);

    const train_cmd = b.addRunArtifact(train_exe);
    train_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        train_cmd.addArgs(args);
    }
    const train_step = b.step("train", "Train neural networks");
    train_step.dependOn(&train_cmd.step);
}

fn buildRead(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine_module: *Build.Module,
    nterm_module: *Build.Module,
    install_NNs: *Build.Step.InstallDir,
) void {
    const read_exe = b.addExecutable(.{
        .name = "read",
        .root_source_file = lazyPath(b, "src/read.zig"),
        .target = target,
        .optimize = optimize,
    });
    read_exe.root_module.addImport("engine", engine_module);
    read_exe.root_module.addImport("nterm", nterm_module);

    read_exe.step.dependOn(&install_NNs.step);
    b.installArtifact(read_exe);

    const run_cmd = b.addRunArtifact(read_exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("read", "Run the read program");
    run_step.dependOn(&run_cmd.step);
}

fn lazyPath(b: *Build, path: []const u8) Build.LazyPath {
    return .{
        .src_path = .{
            .owner = b,
            .sub_path = path,
        },
    };
}
