const std = @import("std");
const time = std.time;

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const SevenBag = engine.bags.SevenBag;

const pc = @import("pc.zig");
const NN = @import("neat/NN.zig");
const Bot = @import("neat/Bot.zig");

pub fn main() !void {
    _ = std.os.windows.kernel32.SetConsoleOutputCP(65001);
    try pcBenchmark();
    getFeaturesBenchmark();
}

// There are 241,315,200 possible 4-line PCs from an empty board with a 7-bag
// randomiser, so creating a table of all of them is actually feasible.
// Mean: 201.543ms
// Max: 4.518s
pub fn pcBenchmark() !void {
    const RUN_COUNT = 100;

    std.debug.print(
        \\
        \\------------------
        \\   PC Benchmark
        \\------------------
        \\
    , .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const nn = try NN.load(allocator, "NNs/Fapae.json");
    defer nn.deinit(allocator);

    var total_time: u64 = 0;
    var max_time: u64 = 0;

    for (0..RUN_COUNT) |seed| {
        const gamestate = GameState.init(SevenBag.init(seed), engine.kicks.srsPlus);

        const start = time.nanoTimestamp();
        const solution = try pc.findPc(allocator, gamestate, nn, 4, 11);
        const time_taken: u64 = @intCast(time.nanoTimestamp() - start);
        total_time += time_taken;
        max_time = @max(max_time, time_taken);

        std.debug.print("Seed: {} | Time taken: {}\n", .{ seed, std.fmt.fmtDuration(time_taken) });
        allocator.free(solution);
    }

    std.debug.print("Mean: {}\n", .{std.fmt.fmtDuration(total_time / RUN_COUNT)});
    std.debug.print("Max: {}\n", .{std.fmt.fmtDuration(max_time)});
}

// Mean: 86ns
pub fn getFeaturesBenchmark() void {
    const RUN_COUNT = 100_000_000;

    std.debug.print(
        \\
        \\--------------------------------
        \\  Feature Extraction Benchmark
        \\--------------------------------
        \\
    , .{});

    // Randomly place 10 pieces
    var xor = std.Random.Xoroshiro128.init(0);
    const rand = xor.random();
    var game = GameState.init(SevenBag.init(xor.next()), engine.kicks.srsPlus);
    for (0..10) |_| {
        game.current.facing = rand.enumValue(engine.pieces.Facing);
        game.pos.x = rand.intRangeAtMost(i8, game.current.minX(), game.current.maxX());
        _ = game.dropToGround();
        _ = game.lockCurrent(-1);
    }

    const start = time.nanoTimestamp();
    for (0..RUN_COUNT - 1) |_| {
        _ = Bot.getFeatures(
            game.playfield,
            .{ true, true, true, true, true },
            1,
            2.1,
            -0.6,
        );
    }
    const feat = Bot.getFeatures(
        game.playfield,
        .{ true, true, true, true, true },
        1,
        2.1,
        -0.6,
    );
    const time_taken: u64 = @intCast(time.nanoTimestamp() - start);

    // Use if statement to prevent compiler from running at compile time
    var accum: f32 = 0;
    accum += feat[0];
    accum += feat[1];
    accum += feat[2];
    accum += feat[3];
    accum += feat[4];
    std.debug.print("{s}", .{if (accum == 0) "a" else ""});

    std.debug.print("Mean: {}\n", .{std.fmt.fmtDuration(time_taken / RUN_COUNT)});
}
