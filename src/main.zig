const std = @import("std");

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const PieceKind = engine.pieces.PieceKind;
const SevenBag = engine.bags.SevenBag;

const next = @import("next.zig");
const NN = @import("neat/NN.zig");
const pc = @import("pc.zig");

const MAX_HEIGHT = 4;
const NEXT_LEN = MAX_HEIGHT * 5 / 2;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const nn = try NN.load(allocator, "NNs/Fapae.json");

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

pub fn countNextSequences() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    inline for (2..16) |i| {
        const start = std.time.nanoTimestamp();
        const ExtendedArray = next.PieceArray(i + 1);
        var iter_count: usize = 0;
        var seen_count: usize = 0;

        const lock_len = @max(i, 7) - 6; // Adjust this number so that `seen` never
        // exceeds the L3 cache for best performance.
        var lock_iter = next.DigitsIterator(lock_len).init(0, 7);
        while (lock_iter.next()) |locks| {
            seen.clearRetainingCapacity();
            var next_iter = next.NextIterator(i, lock_len).init(locks);
            while (next_iter.next()) |pieces| {
                // TODO: write proof that this counts perfectly
                // Hold is smaller than current; place it in the back
                var p = ExtendedArray.init(pieces.items);
                for (0..p.get(i - 1)) |hold| {
                    try seen.put(p.set(i, @intCast(hold)).items, {});
                }
                // Hold is larger than current; swap with current to place current in the back
                p = p.set(i, p.get(i - 1));
                for (p.get(i)..7) |hold| {
                    try seen.put(p.set(i - 1, @intCast(hold)).items, {});
                }
                iter_count += 1;
            }
            seen_count += seen.count() * 7;
        }

        const t: u64 = @intCast(std.time.nanoTimestamp() - start);
        std.debug.print(
            "{:2} | Iters: {:11} | Distinct: {:11} | Time: {}\n",
            .{ i, iter_count, seen_count, std.fmt.fmtDuration(t) },
        );
    }
}
