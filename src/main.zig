const std = @import("std");

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const PieceKind = engine.pieces.PieceKind;
const SevenBag = engine.bags.SevenBag;

const root = @import("root.zig");
const next = root.next;
const NN = root.NN;
const pc = root.pc;

const MAX_HEIGHT = 4;
const NEXT_LEN = MAX_HEIGHT * 5 / 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const nn = try NN.load(allocator, "NNs/Fast.json");

    var iter = next.SequenceIterator(NEXT_LEN + 1, @min(7, NEXT_LEN)).init(allocator);
    defer iter.deinit();

    var solved: usize = 0;
    var count: usize = 0;

    // # 5 lookaheads no hold
    // Solved 120 out of 13020 (0.922%)
    // 3.58ms per sequence
    //
    // # 6 lookaheads empty hold
    // Solved 576 out of 69300 (0.831%)
    // Took 3.731ms per sequence
    //
    // # 5/6 lookaheads any hold
    // Solved 3522 out of 57750 (6.099%)
    // Took 2.962ms per sequence
    // 76,743,468 4-line PCs left
    const start = std.time.nanoTimestamp();
    while (try iter.next()) |pieces| {
        count += 1;

        const solution = pc.findPc(
            allocator,
            gameWithPieces(&pieces),
            nn,
            0,
            NEXT_LEN + 1,
        ) catch continue;
        defer allocator.free(solution);

        solved += 1;
        std.debug.print("Solved {} out of {}\n", .{ solved, count });
    }
    const time: u64 = @intCast(std.time.nanoTimestamp() - start);

    std.debug.print("Solved {} out of {} ({d:.3}%)\n", .{
        solved,
        count,
        @as(f64, @floatFromInt(solved)) / @as(f64, @floatFromInt(count)) * 100,
    });
    std.debug.print("Took {} per sequence\n", .{std.fmt.fmtDuration(time / count)});
}

fn gameWithPieces(pieces: []const PieceKind) GameState {
    var game = GameState.init(SevenBag.init(0), engine.kicks.srs);
    game.current.kind = pieces[0];
    game.hold_kind = pieces[1];

    for (0..@min(pieces.len - 2, game.next_pieces.len)) |i| {
        game.next_pieces[i] = pieces[i + 2];
    }
    game.bag.context.index = 0;
    for (0..pieces.len -| 9) |i| {
        game.bag.context.pieces[i] = pieces[i + 9];
    }

    return game;
}
