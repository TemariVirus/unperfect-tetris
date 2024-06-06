const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;

const engine = @import("engine");
const kicks = engine.kicks;
const BoardMask = engine.bit_masks.BoardMask;
const GameState = engine.GameState(SevenBag);
const PieceKind = engine.pieces.PieceKind;
const SevenBag = engine.bags.SevenBag;

const root = @import("root.zig");
const Bot = root.neat.Bot;
const movegen = root.movegen;
const NN = root.neat.NN;
const Placement = root.Placement;

const SearchNode = struct {
    // TODO: compress the boardmask
    board: BoardMask,
    // Needed to keep track of parity of holds
    current: PieceKind,
    // Needed to differentiate different states with same boards
    max_height: u6,
};
const NodeSet = std.AutoHashMap(SearchNode, void);

const VISUALISE = false;

pub const FindPcError = error{
    NoPcExists,
    NotEnoughPieces,
};

// TODO: take a playfield and kick fn instead of a gamestate
/// Finds a perfect clear with the least number of pieces possible for the given
/// game state, and returns the sequence of placements required to achieve it.
///
/// Returns an error if no perfect clear exists, or if the number of pieces needed
/// exceeds `max_pieces`.
pub fn findPc(
    allocator: Allocator,
    game: GameState,
    nn: NN,
    min_height: u6,
    comptime max_pieces: usize,
) ![]Placement {
    const field_height = blk: {
        var i: usize = BoardMask.HEIGHT;
        while (i >= 1) : (i -= 1) {
            if (game.playfield.rows[i - 1] != BoardMask.EMPTY_ROW) {
                break;
            }
        }
        break :blk i;
    };
    const bits_set = blk: {
        var set: usize = 0;
        for (0..field_height) |i| {
            set += @popCount(game.playfield.rows[i] & ~BoardMask.EMPTY_ROW);
        }
        break :blk set;
    };
    const empty_cells = BoardMask.WIDTH * field_height - bits_set;

    // Assumes that all pieces have 4 cells and that the playfield is 10 cells wide.
    // Thus, an odd number of empty cells means that a perfect clear is impossible.
    if (empty_cells % 2 == 1) {
        return FindPcError.NoPcExists;
    }

    var pieces_needed = if (empty_cells % 4 == 2)
        (empty_cells + 10) / 4
    else
        empty_cells / 4;
    if (pieces_needed == 0) {
        pieces_needed = 5;
    }

    var cache = NodeSet.init(allocator);
    defer cache.deinit();

    var pieces = getPieces(game, max_pieces);
    // 20 is the lowest common multiple of the width of the playfield (10) and the
    // number of cells in a piece (4). 20 / 4 = 5 extra pieces for each bigger
    // perfect clear
    while (pieces_needed <= pieces.len) : (pieces_needed += 5) {
        const max_height = (4 * pieces_needed + bits_set) / BoardMask.WIDTH;
        if (max_height < min_height) {
            continue;
        }

        const placements = try allocator.alloc(Placement, pieces_needed);
        errdefer allocator.free(placements);

        cache.clearRetainingCapacity();
        if (try findPcInner(allocator, game, &pieces, placements, &cache, nn, @intCast(max_height))) {
            return placements;
        }

        allocator.free(placements);
    }

    return FindPcError.NotEnoughPieces;
}

fn getPieces(game: GameState, comptime pieces_count: usize) [pieces_count]PieceKind {
    if (pieces_count == 0) {
        return .{};
    }
    if (pieces_count == 1) {
        return .{game.current.kind};
    }

    var pieces = [_]PieceKind{undefined} ** pieces_count;
    pieces[0] = game.current.kind;
    const start: usize = if (game.hold_kind) |hold| blk: {
        pieces[1] = hold;
        break :blk 2;
    } else 1;

    for (game.next_pieces, start..) |piece, i| {
        if (i >= pieces.len) {
            break;
        }
        pieces[i] = piece;
    }

    var bag_copy = game.bag;
    for (@min(pieces.len, start + game.next_pieces.len)..pieces.len) |i| {
        pieces[i] = bag_copy.next();
    }

    return pieces;
}

fn findPcInner(
    allocator: Allocator,
    game: GameState,
    pieces: []PieceKind,
    placements: []Placement,
    cache: *NodeSet,
    nn: NN,
    max_height: u6,
) !bool {
    // Base case; check for perfect clear
    if (placements.len == 0) {
        return max_height == 0;
    }

    const node = SearchNode{
        .board = game.playfield,
        .current = pieces[0],
        .max_height = max_height,
    };
    // TODO: WAS ~97% cache hit rate, consider optimising the cache
    if ((try cache.getOrPut(node)).found_existing) {
        return false;
    }

    if (VISUALISE) {
        std.debug.print("\x1B[1;1H{}", .{game});
    }

    const scoreFn = struct {
        fn score(_game: GameState, placement: Placement, _nn: NN) f32 {
            var new_game = _game;
            new_game.playfield.place(placement.piece.mask(), placement.pos);
            // TODO: move clearlines to boardmask
            _ = new_game.clearLines();

            const features = Bot.getFeatures(new_game.playfield, _nn.inputs_used, 0, 0, 0);
            return _nn.predict(features)[0];
        }
    }.score;

    var moves = blk: {
        var moves = movegen.MoveQueue.init(allocator, {});

        const m1 = movegen.validMoves(game, pieces[0], max_height, isPcPossible);
        try movegen.orderMoves(&moves, game, pieces[0], m1, nn, scoreFn);
        // Check for unique hold
        if (pieces.len < 2 or pieces[0] == pieces[1]) {
            break :blk moves;
        }

        const m2 = movegen.validMoves(game, pieces[1], max_height, isPcPossible);
        try movegen.orderMoves(&moves, game, pieces[1], m2, nn, scoreFn);
        break :blk moves;
    };
    defer moves.deinit();

    while (moves.removeOrNull()) |move| {
        const placement = move.placement;
        // Hold if needed
        if (placement.piece.kind != pieces[0]) {
            std.mem.swap(PieceKind, &pieces[0], &pieces[1]);
        }

        var new_game = game;
        new_game.pos = placement.pos;
        // Place piece
        if (VISUALISE) {
            // Hide the current piece behind where it was just placed
            new_game.current = placement.piece;
        }
        new_game.playfield.place(placement.piece.mask(), placement.pos);
        // TODO: Optimize clearLines
        const cleared = new_game.clearLines();

        const new_height = max_height - cleared;
        if (try findPcInner(
            allocator,
            new_game,
            pieces[1..],
            placements[1..],
            cache,
            nn,
            new_height,
        )) {
            placements[0] = placement;
            return true;
        }
    }

    return false;
}

// TODO: Check against dictionary of possible PCs if the remaining peice count
// is high (maybe around 6 to 7)
// TODO: Check performance benefit of using flood fill for more thorough checking
/// A fast check to see if a perfect clear is possible by making sure every empty
/// "segment" of the playfield has a multiple of 4 cells.
fn isPcPossible(rows: []const u16) bool {
    var walls = ~BoardMask.EMPTY_ROW;
    for (rows) |row| {
        walls &= row | (row << 1);
    }
    walls &= walls ^ (walls >> 1); // Reduce consecutive walls to 1 wide walls

    while (walls != 0) {
        const old_walls = walls;
        walls &= walls - 1; // Clear lowest bit
        // A mask of all the bits before the removed wall
        const right_of_wall = (walls ^ old_walls) - 1;

        // Each "segment" separated by a wall must have a multiple of 4 empty cells,
        // as pieces can only be placed in one segment (each piece occupies 4 cells).
        var empty_count: u16 = 0;
        for (rows) |row| {
            // All of the other segments to the right are confirmed to have a
            // multiple of 4 empty cells, so it doesn't matter if we count them again.
            const segment = ~row & right_of_wall;
            empty_count += @popCount(segment);
        }
        if (empty_count % 4 != 0) {
            return false;
        }
    }

    return true;
}

test "4-line PC" {
    const allocator = std.testing.allocator;

    var gamestate = GameState.init(kicks.srsPlus);

    const nn = try NN.load(allocator, "NNs/Fapae.json");
    defer nn.deinit(allocator);

    const solution = try findPc(allocator, gamestate, nn, 0, 11);
    defer allocator.free(solution);

    try expect(solution.len == 10);

    for (solution[0 .. solution.len - 1]) |placement| {
        gamestate.current = placement.piece;
        gamestate.pos = placement.pos;
        try expect(!gamestate.lockCurrent(-1).pc);
    }

    gamestate.current = solution[solution.len - 1].piece;
    gamestate.pos = solution[solution.len - 1].pos;
    try expect(gamestate.lockCurrent(-1).pc);
}
