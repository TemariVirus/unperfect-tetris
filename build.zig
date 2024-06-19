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

    // zmai dependency
    const zmai_module = b.dependency("zmai", .{
        .target = target,
        .optimize = optimize,
    }).module("zmai");

    // Expose the library root
    const root_module = b.addModule("perfect-tetris", .{
        .root_source_file = lazyPath(b, "src/root.zig"),
        .imports = &.{
            .{ .name = "engine", .module = engine_module },
            .{ .name = "nterm", .module = engine_module.import_table.get("nterm").? },
            .{ .name = "zmai", .module = zmai_module },
        },
    });

    // Add options
    const small = b.option(
        bool,
        "small",
        "Optimise for perfect clears with 4 or fewer lines",
    ) orelse false;
    const options = b.addOptions();
    options.addOption(bool, "small", small);
    root_module.addOptions("options", options);

    // Add NN files
    const install_NNs = b.addInstallDirectory(.{
        .source_dir = lazyPath(b, "NNs"),
        .install_dir = .bin,
        .install_subdir = "NNs",
    });

    buildExe(b, target, optimize, root_module, install_NNs);
    buildDemo(b, target, optimize, root_module, install_NNs);
    buildTests(b, root_module);
    buildBench(b, target, root_module);
    buildTrain(b, target, optimize, root_module);
    buildDisplay(b, target, optimize, root_module);
}

fn buildExe(
    b: *Build,
    target: Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_module: *Build.Module,
    install_NNs: *Build.Step.InstallDir,
) void {
    const exe = b.addExecutable(.{
        .name = "perfect-tetris",
        .root_source_file = lazyPath(b, "src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("perfect-tetris", root_module);
    exe.root_module.addImport("engine", root_module.import_table.get("engine").?);
    exe.root_module.addImport("zmai", root_module.import_table.get("zmai").?);

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
    root_module: *Build.Module,
    install_NNs: *Build.Step.InstallDir,
) void {
    const demo_exe = b.addExecutable(.{
        .name = "demo",
        .root_source_file = lazyPath(b, "src/demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_exe.root_module.addImport("perfect-tetris", root_module);
    demo_exe.root_module.addImport("engine", root_module.import_table.get("engine").?);
    demo_exe.root_module.addImport("nterm", root_module.import_table.get("nterm").?);
    demo_exe.root_module.addImport("zmai", root_module.import_table.get("zmai").?);

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

fn buildTests(b: *Build, root_module: *Build.Module) void {
    const lib_tests = b.addTest(.{
        .root_source_file = lazyPath(b, "src/root.zig"),
    });
    lib_tests.root_module.addImport("options", root_module.import_table.get("options").?);
    lib_tests.root_module.addImport("engine", root_module.import_table.get("engine").?);
    lib_tests.root_module.addImport("zmai", root_module.import_table.get("zmai").?);

    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_lib_tests.step);
}

fn buildBench(
    b: *Build,
    target: Build.ResolvedTarget,
    root_module: *Build.Module,
) void {
    const bench_exe = b.addExecutable(.{
        .name = "benchmarks",
        .root_source_file = lazyPath(b, "src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    bench_exe.root_module.addImport("perfect-tetris", root_module);
    bench_exe.root_module.addImport("engine", root_module.import_table.get("engine").?);
    bench_exe.root_module.addImport("zmai", root_module.import_table.get("zmai").?);

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
    root_module: *Build.Module,
) void {
    const train_exe = b.addExecutable(.{
        .name = "nn-train",
        .root_source_file = lazyPath(b, "src/train.zig"),
        .target = target,
        .optimize = optimize,
    });
    train_exe.root_module.addImport("perfect-tetris", root_module);
    train_exe.root_module.addImport("engine", root_module.import_table.get("engine").?);
    train_exe.root_module.addImport("zmai", root_module.import_table.get("zmai").?);

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
    root_module: *Build.Module,
) void {
    const display_exe = b.addExecutable(.{
        .name = "display",
        .root_source_file = lazyPath(b, "src/display.zig"),
        .target = target,
        .optimize = optimize,
    });
    display_exe.root_module.addImport("perfect-tetris", root_module);
    display_exe.root_module.addImport("engine", root_module.import_table.get("engine").?);
    display_exe.root_module.addImport("nterm", root_module.import_table.get("nterm").?);

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
