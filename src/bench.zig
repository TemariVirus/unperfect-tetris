const std = @import("std");
const time = std.time;

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const SevenBag = engine.bags.SevenBag;

const root = @import("perfect-tetris");
const NN = root.NN;
const pc = root.pc;

pub fn main() !void {
    try pcBenchmark(4);
    getFeaturesBenchmark();
}

// Mean: 28.869ms
// Max: 442.807ms
pub fn pcBenchmark(comptime height: u8) !void {
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

    const nn = try NN.load(allocator, "NNs/Fast2.json");
    defer nn.deinit(allocator);

    const placements = try allocator.alloc(root.Placement, height * 10 / 4);
    defer allocator.free(placements);

    const start = time.nanoTimestamp();
    var max_time: u64 = 0;
    for (0..RUN_COUNT) |seed| {
        const gamestate = GameState.init(SevenBag.init(seed), engine.kicks.srsPlus);

        const solve_start = time.nanoTimestamp();
        const solution = try pc.findPc(allocator, gamestate, nn, height, placements);
        const time_taken: u64 = @intCast(time.nanoTimestamp() - solve_start);
        max_time = @max(max_time, time_taken);
        std.mem.doNotOptimizeAway(solution);

        std.debug.print(
            "Seed: {:<2} | Time taken: {}\n",
            .{ seed, std.fmt.fmtDuration(time_taken) },
        );
    }
    const total_time: u64 = @intCast(time.nanoTimestamp() - start);

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
            root.getFeatures(playfield, 6, [_]bool{true} ** 7),
        );
    }
    const time_taken: u64 = @intCast(time.nanoTimestamp() - start);

    std.debug.print("Mean: {}\n", .{std.fmt.fmtDuration(time_taken / RUN_COUNT)});
}
