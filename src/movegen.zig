const std = @import("std");
const expect = std.testing.expect;
const Order = std.math.Order;

const engine = @import("engine");
const BoardMask = engine.bit_masks.BoardMask;
const GameState = engine.GameState(SevenBag);
const Position = engine.pieces.Position;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const SevenBag = engine.bags.SevenBag;

const root = @import("root.zig");
const NN = root.neat.NN;
pub const PiecePosition = root.PiecePosition;
const PiecePosSet = root.PiecePosSet(.{ 10, 24, 4 });
const Placement = root.Placement;

// By drawing a snaking path through the playfield, the highest density of
// pushed unexplored nodes (around 2 / 3) is achieved. Thus, the highest stack
// length is given by: 10 * 24 * 4 * (2 / 3) = 640.
const PlacementStack = std.BoundedArray(PiecePosition, 640);

const Move = enum {
    left,
    right,
    rotate_cw,
    rotate_double,
    rotate_ccw,
    drop,

    const moves = [_]Move{
        .left,
        .right,
        .rotate_cw,
        .rotate_double,
        .rotate_ccw,
        .drop,
    };
};

/// Returns the set of all placements where the top of the piece does not
/// exceed `max_height` and `validFn` returns true.
pub fn validMoves(
    game: GameState,
    piece_kind: PieceKind,
    max_height: u6,
    comptime validFn: fn ([]const u16) bool,
) PiecePosSet {
    const collisions = collisionSet(game.playfield, piece_kind, max_height);
    var seen = PiecePosSet.init();
    var placements = PiecePosSet.init();
    var stack = PlacementStack.init(0) catch unreachable;

    // Start floating right above `max_height`
    {
        const piece = Piece{ .facing = .up, .kind = piece_kind };
        const pos = Position{
            .x = 0,
            .y = @as(i8, @intCast(max_height)) + piece.minY(),
        };
        stack.append(PiecePosition.pack(piece, pos)) catch unreachable;
    }

    var new_game = game;
    while (stack.popOrNull()) |placement| {
        const piece, const pos = blk: {
            const temp = placement.unpack(piece_kind);
            break :blk .{ temp.piece, temp.pos };
        };
        if (seen.putGet(piece, pos)) {
            continue;
        }

        for (Move.moves) |move| {
            new_game.playfield = game.playfield;
            new_game.current = piece;
            new_game.pos = pos;

            // Skip if piece was unable to move
            switch (move) {
                .left => _ = new_game.slide(-1),
                .right => _ = new_game.slide(1),
                .rotate_cw => _ = new_game.rotate(.quarter_cw),
                .rotate_double => _ = new_game.rotate(.half),
                .rotate_ccw => _ = new_game.rotate(.quarter_ccw),
                .drop => if (new_game.pos.y > new_game.current.minY() and
                    !collisions.contains(
                    piece,
                    Position{ .x = new_game.pos.x, .y = new_game.pos.y - 1 },
                )) {
                    new_game.pos.y -= 1;
                },
            }
            if (seen.contains(new_game.current, new_game.pos)) {
                continue;
            }

            // Branch out after movement
            stack.append(PiecePosition.pack(new_game.current, new_game.pos)) catch unreachable;

            if (
            // Skip this placement if the piece is too high
            new_game.pos.y + @as(i8, new_game.current.top()) > max_height or
                // Only lock if on ground
                (new_game.pos.y > new_game.current.minY() and
                !collisions.contains(
                new_game.current,
                Position{ .x = new_game.pos.x, .y = new_game.pos.y - 1 },
            )) or
                // Skip this placement if it already exists.
                // Not strictly necessary but speeds things up
                placements.contains(new_game.current, new_game.pos))
            {
                continue;
            }

            new_game.playfield.place(new_game.current.mask(), new_game.pos);
            const cleared = new_game.playfield.clearLines(new_game.pos.y);
            const new_height = max_height - cleared;
            if (!validFn(new_game.playfield.rows[0..new_height])) {
                continue;
            }

            placements.put(new_game.current, new_game.pos);
        }
    }

    return placements;
}

fn collisionSet(playfield: BoardMask, piece_kind: PieceKind, max_height: u6) PiecePosSet {
    var collisions = PiecePosSet.init();
    inline for (@typeInfo(engine.pieces.Facing).Enum.fields) |facing| {
        const piece = Piece{ .facing = @enumFromInt(facing.value), .kind = piece_kind };

        var y = piece.minY();
        while (y <= @as(i8, @intCast(max_height)) + piece.minY() - 1) : (y += 1) {
            var x = piece.minX();
            while (x <= piece.maxX()) : (x += 1) {
                const pos = Position{ .x = x, .y = y };
                if (playfield.collides(piece.mask(), pos)) {
                    collisions.put(piece, pos);
                }
            }
        }
    }

    return collisions;
}

pub const MoveNode = struct {
    placement: Placement,
    score: f32,
};
const compareFn = (struct {
    fn cmp(_: void, a: MoveNode, b: MoveNode) Order {
        return std.math.order(b.score, a.score);
    }
}).cmp;
pub const MoveQueue = std.PriorityQueue(MoveNode, void, compareFn);

pub fn orderMoves(
    queue: *MoveQueue,
    playfield: BoardMask,
    piece: PieceKind,
    moves: PiecePosSet,
    score_args: anytype,
    comptime scoreFn: fn (BoardMask, Placement, @TypeOf(score_args)) f32,
) !void {
    var iter = moves.iterator(piece);
    while (iter.next()) |placement| {
        try queue.add(.{
            .placement = placement,
            .score = scoreFn(playfield, placement, score_args),
        });
    }
}

test validMoves {
    const validFn = (struct {
        pub fn valid(_: []const u16) bool {
            return true;
        }
    }).valid;

    var game = GameState.init(SevenBag.init(0), engine.kicks.srs);
    game.playfield.rows[4] |= 0b0000000000_0;
    game.playfield.rows[3] |= 0b0111111110_0;
    game.playfield.rows[2] |= 0b0010000000_0;
    game.playfield.rows[1] |= 0b0000001000_0;
    game.playfield.rows[0] |= 0b0000000001_0;

    const PIECE = PieceKind.l;
    const placements = validMoves(game, PIECE, 5, validFn);

    var iter = placements.iterator(PIECE);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try expect(count == 25);
}
