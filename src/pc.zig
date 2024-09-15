const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expect = std.testing.expect;

const engine = @import("engine");
const GameState = engine.GameState;
const KickFn = engine.kicks.KickFn;
const PieceKind = engine.pieces.PieceKind;
const SevenBag = engine.bags.SevenBag;

const root = @import("root.zig");
const BoardMask = root.bit_masks.BoardMask;
const movegen = root.movegen;
const NN = root.NN;
const PieceMask = root.bit_masks.PieceMask;
const Placement = root.Placement;

const SearchNode = packed struct {
    board: u60,
    depth: u4,
};
const NodeSet = std.AutoHashMap(SearchNode, void);

pub const FindPcError = error{
    NoPcExists,
    SolutionTooLong,
};

/// Finds a perfect clear with the least number of pieces possible for the given
/// game state, and returns the sequence of placements required to achieve it.
///
/// Returns an error if no perfect clear exists, or if the number of pieces needed
/// exceeds `max_pieces`.
pub fn findPc(
    comptime BagType: type,
    allocator: Allocator,
    game: GameState(BagType),
    nn: NN,
    min_height: u3,
    placements: []Placement,
) ![]Placement {
    const playfield = BoardMask.from(game.playfield);

    const field_height = blk: {
        var full_row: u64 = 0b1111111111 << ((BoardMask.HEIGHT - 1) * BoardMask.WIDTH);
        while (full_row != 0) : (full_row >>= BoardMask.WIDTH) {
            if (playfield.mask & full_row != 0) {
                break;
            }
        }
        break :blk (@bitSizeOf(@TypeOf(full_row)) - @clz(full_row)) / BoardMask.WIDTH;
    };
    const bits_set = @popCount(playfield.mask);
    const empty_cells = BoardMask.WIDTH * field_height - bits_set;

    // Assumes that all pieces have 4 cells and that the playfield is 10 cells wide.
    // Thus, an odd number of empty cells means that a perfect clear is impossible.
    if (empty_cells % 2 == 1) {
        return FindPcError.NoPcExists;
    }

    var pieces_needed = if (empty_cells % 4 == 2)
        // If the number of empty cells is not a multiple of 4, we need to fill
        // an extra so that it becomes a multiple of 4
        // 2 + 10 = 12 which is a multiple of 4
        (empty_cells + 10) / 4
    else
        empty_cells / 4;
    // Don't return an empty solution
    if (pieces_needed == 0) {
        pieces_needed = 5;
    }

    const pieces = try getPieces(BagType, allocator, game, placements.len + 1);
    defer allocator.free(pieces);

    var cache = NodeSet.init(allocator);
    defer cache.deinit();

    // Pre-allocate a queue for each placement
    const queues = try allocator.alloc(movegen.MoveQueue, placements.len);
    for (0..queues.len) |i| {
        queues[i] = movegen.MoveQueue.init(allocator, {});
    }
    defer allocator.free(queues);
    defer for (queues) |queue| {
        queue.deinit();
    };

    // 20 is the lowest common multiple of the width of the playfield (10) and the
    // number of cells in a piece (4). 20 / 4 = 5 extra pieces for each bigger
    // perfect clear
    while (pieces_needed <= placements.len) : (pieces_needed += 5) {
        const max_height = (4 * pieces_needed + bits_set) / BoardMask.WIDTH;
        if (max_height < min_height) {
            continue;
        }

        if (try findPcInner(
            playfield,
            pieces[0 .. pieces_needed + 1],
            queues[0..pieces_needed],
            placements[0..pieces_needed],
            game.kicks,
            &cache,
            nn,
            @intCast(max_height),
        )) {
            return placements[0..pieces_needed];
        }

        // Clear cache and queues
        cache.clearRetainingCapacity();
        for (queues) |*queue| {
            queue.items.len = 0;
        }
    }

    return FindPcError.SolutionTooLong;
}

/// Extracts `pieces_count` pieces from the game state, in the format [current, hold, next...].
pub fn getPieces(
    comptime BagType: type,
    allocator: Allocator,
    game: GameState(BagType),
    pieces_count: usize,
) ![]PieceKind {
    if (pieces_count == 0) {
        return &.{};
    }

    var pieces = try allocator.alloc(PieceKind, pieces_count);
    pieces[0] = game.current.kind;
    if (pieces_count == 1) {
        return pieces;
    }

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

    // If next pieces are not enough, fill the rest from the bag
    var bag_copy = game.bag;
    for (@min(pieces.len, start + game.next_pieces.len)..pieces.len) |i| {
        pieces[i] = bag_copy.next();
    }

    return pieces;
}

fn findPcInner(
    playfield: BoardMask,
    pieces: []PieceKind,
    queues: []movegen.MoveQueue,
    placements: []Placement,
    kick_fn: *const KickFn,
    cache: *NodeSet,
    nn: NN,
    max_height: u3,
) !bool {
    // Base case; check for perfect clear
    if (placements.len == 0) {
        return max_height == 0;
    }

    const node = SearchNode{
        .board = @truncate(playfield.mask),
        .depth = @intCast(placements.len - 1),
    };
    if ((try cache.getOrPut(node)).found_existing) {
        return false;
    }

    // Add moves to queue
    queues[0].items.len = 0;
    const m1 = movegen.allPlacements(playfield, kick_fn, pieces[0], max_height);
    movegen.orderMoves(
        &queues[0],
        playfield,
        pieces[0],
        m1,
        max_height,
        isPcPossible,
        nn,
        orderScore,
    );
    // Check for unique hold
    if (pieces.len > 1 and pieces[0] != pieces[1]) {
        const m2 = movegen.allPlacements(playfield, kick_fn, pieces[1], max_height);
        movegen.orderMoves(
            &queues[0],
            playfield,
            pieces[1],
            m2,
            max_height,
            isPcPossible,
            nn,
            orderScore,
        );
    }

    var held_odd_times = false;
    while (queues[0].removeOrNull()) |move| {
        const placement = move.placement;
        // Hold if needed
        if (placement.piece.kind != pieces[0]) {
            std.mem.swap(PieceKind, &pieces[0], &pieces[1]);
            held_odd_times = !held_odd_times;
        }
        assert(pieces[0] == placement.piece.kind);

        var board = playfield;
        board.place(PieceMask.from(placement.piece), placement.pos);
        const cleared = board.clearLines(placement.pos.y);

        const new_height = max_height - cleared;
        if (try findPcInner(
            board,
            pieces[1..],
            queues[1..],
            placements[1..],
            kick_fn,
            cache,
            nn,
            new_height,
        )) {
            placements[0] = placement;
            return true;
        }
    }
    // Unhold if held an odd number of times so that pieces are in the same order
    if (held_odd_times) {
        std.mem.swap(PieceKind, &pieces[0], &pieces[1]);
    }

    return false;
}

/// A fast check to see if a perfect clear is possible by making sure every empty
/// "segment" of the playfield has a multiple of 4 cells. Assumes the total number
/// of empty cells is a multiple of 4.
fn isPcPossible(playfield: BoardMask, max_height: u3) bool {
    assert(playfield.mask >> (@as(u6, max_height) * BoardMask.WIDTH) == 0);
    assert((@as(u6, max_height) * BoardMask.WIDTH - @popCount(playfield.mask)) % 4 == 0);

    var walls: u64 = (1 << BoardMask.WIDTH) - 1;
    for (0..max_height) |y| {
        const row = playfield.row(@intCast(y));
        walls &= row | (row << 1);
    }
    walls &= walls ^ (walls << 1); // Reduce consecutive walls to 1 wide

    while (walls != 0) {
        // A mask of all the bits before the first wall
        var right_of_wall = root.bit_masks.lsb(walls) - 1;
        // Duplicate to all rows
        for (@min(1, max_height)..max_height) |_| {
            right_of_wall |= right_of_wall << BoardMask.WIDTH;
        }

        // Each "segment" separated by a wall must have a multiple of 4 empty cells,
        // as pieces can only be placed in one segment (each piece occupies 4 cells).
        // All of the other segments to the right are confirmed to have a
        // multiple of 4 empty cells, so it doesn't matter if we count them again.
        const empty_count = @popCount(~playfield.mask & right_of_wall);
        if (empty_count % 4 != 0) {
            return false;
        }

        // Clear lowest bit
        walls &= walls - 1;
    }

    // The remaining empty cells must also be a multiple of 4, so we don't need to
    // check the leftmost segment
    return true;
}

fn orderScore(playfield: BoardMask, max_height: u3, nn: NN) f32 {
    const features = root.getFeatures(playfield, max_height, nn.inputs_used);
    return nn.predict(features);
}

test "4-line PC" {
    const allocator = std.testing.allocator;

    var gamestate = GameState(SevenBag).init(SevenBag.init(0), engine.kicks.srsPlus);

    const nn = try NN.load(allocator, "NNs/Fast3.json");
    defer nn.deinit(allocator);

    const placements = try allocator.alloc(Placement, 10);
    defer allocator.free(placements);

    const solution = try findPc(SevenBag, allocator, gamestate, nn, 0, placements);
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

test isPcPossible {
    var playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0111111110) << 30;
    playfield.mask |= @as(u64, 0b0010000000) << 20;
    playfield.mask |= @as(u64, 0b0000001000) << 10;
    playfield.mask |= @as(u64, 0b0000001001);
    try expect(isPcPossible(playfield, 4));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0000000000) << 30;
    playfield.mask |= @as(u64, 0b0010011000) << 20;
    playfield.mask |= @as(u64, 0b0000011000) << 10;
    playfield.mask |= @as(u64, 0b0000011001);
    try expect(isPcPossible(playfield, 4));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0010011100) << 20;
    playfield.mask |= @as(u64, 0b0000011000) << 10;
    playfield.mask |= @as(u64, 0b0000011011);
    try expect(!isPcPossible(playfield, 3));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0010010000) << 20;
    playfield.mask |= @as(u64, 0b0000001000) << 10;
    playfield.mask |= @as(u64, 0b0000001011);
    try expect(isPcPossible(playfield, 3));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0100011100) << 20;
    playfield.mask |= @as(u64, 0b0010001000) << 10;
    playfield.mask |= @as(u64, 0b0111111011);
    try expect(!isPcPossible(playfield, 3));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0100010000) << 20;
    playfield.mask |= @as(u64, 0b0010011000) << 10;
    playfield.mask |= @as(u64, 0b0100011011);
    try expect(isPcPossible(playfield, 3));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0100111000) << 20;
    playfield.mask |= @as(u64, 0b0011011100) << 10;
    playfield.mask |= @as(u64, 0b1100111000);
    try expect(!isPcPossible(playfield, 3));

    playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0100111000) << 20;
    playfield.mask |= @as(u64, 0b0011111100) << 10;
    playfield.mask |= @as(u64, 0b0100111000);
    try expect(isPcPossible(playfield, 3));
}
