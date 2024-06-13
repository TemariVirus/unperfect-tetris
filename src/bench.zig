const std = @import("std");
const time = std.time;

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const SevenBag = engine.bags.SevenBag;

const root = @import("root.zig");
const NN = root.NN;
const pc = root.pc;

pub fn main() !void {
    try pcBenchmark();
    getFeaturesBenchmark();
}

// Mean: 33.383ms
// Max: 576.272ms
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

    const nn = try NN.load(allocator, "NNs/Fast.json");
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

        std.debug.print(
            "Seed: {:<2} | Time taken: {}\n",
            .{ seed, std.fmt.fmtDuration(time_taken) },
        );
        allocator.free(solution);
    }

    std.debug.print("Mean: {}\n", .{std.fmt.fmtDuration(total_time / RUN_COUNT)});
    std.debug.print("Max: {}\n", .{std.fmt.fmtDuration(max_time)});
}

// Mean: 41ns
pub fn getFeaturesBenchmark() void {
    const RUN_COUNT = 100_000_000;

    std.debug.print(
        \\
        \\--------------------------------
        \\  Feature Extraction Benchmark
        \\--------------------------------
        \\
    , .{});

    // Randomly place 3 pieces
    var xor = std.Random.Xoroshiro128.init(0);
    const rand = xor.random();
    var game = GameState.init(SevenBag.init(xor.next()), engine.kicks.srsPlus);
    for (0..3) |_| {
        game.current.facing = rand.enumValue(engine.pieces.Facing);
        game.pos.x = rand.intRangeAtMost(i8, game.current.minX(), game.current.maxX());
        _ = game.dropToGround();
        _ = game.lockCurrent(-1);
    }
    const playfield = root.bit_masks.BoardMask.from(game.playfield);

    const start = time.nanoTimestamp();
    for (0..RUN_COUNT) |_| {
        std.mem.doNotOptimizeAway(
            root.getFeatures(playfield, .{ true, true, true, true, true }),
        );
    }
    const time_taken: u64 = @intCast(time.nanoTimestamp() - start);

    std.debug.print("Mean: {}\n", .{std.fmt.fmtDuration(time_taken / RUN_COUNT)});
}
