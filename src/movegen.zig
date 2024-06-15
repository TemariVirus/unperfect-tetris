const std = @import("std");
const expect = std.testing.expect;
const Order = std.math.Order;

const engine = @import("engine");
const KickFn = engine.kicks.KickFn;
const Position = engine.pieces.Position;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Rotation = engine.kicks.Rotation;

const root = @import("root.zig");
const BoardMask = root.bit_masks.BoardMask;
pub const PiecePosition = root.PiecePosition;
const PiecePosSet = root.PiecePosSet(.{ 10, 10, 4 });
const PieceMask = root.bit_masks.PieceMask;
const Placement = root.Placement;

const PlacementStack = std.BoundedArray(PiecePosition, 240);

const Move = enum {
    left,
    right,
    rotate_cw,
    rotate_double,
    rotate_ccw,
    drop,

    const moves = blk: {
        var m = [_]Move{undefined} ** @typeInfo(Move).Enum.fields.len;
        for (@typeInfo(Move).Enum.fields, 0..) |field, i| {
            m[i] = @enumFromInt(field.value);
        }
        break :blk m;
    };
};

pub const Intermediate = struct {
    playfield: BoardMask,
    current: Piece,
    pos: Position,
    kicks: *const KickFn,

    pub fn makeMove(self: *Intermediate, move: Move) bool {
        return switch (move) {
            .left => blk: {
                if (self.pos.x <= self.current.minX()) {
                    break :blk false;
                }
                break :blk self.tryTranspose(.{ .x = self.pos.x - 1, .y = self.pos.y });
            },
            .right => blk: {
                if (self.pos.x >= self.current.maxX()) {
                    break :blk false;
                }
                break :blk self.tryTranspose(.{ .x = self.pos.x + 1, .y = self.pos.y });
            },
            .rotate_cw => self.tryRotate(.quarter_cw),
            .rotate_double => self.tryRotate(.half),
            .rotate_ccw => self.tryRotate(.quarter_ccw),
            .drop => blk: {
                if (self.pos.y <= self.current.minY()) {
                    break :blk false;
                }
                break :blk self.tryTranspose(.{ .x = self.pos.x, .y = self.pos.y - 1 });
            },
        };
    }

    fn tryTranspose(self: *Intermediate, pos: Position) bool {
        if (self.playfield.collides(self.current, pos)) {
            return false;
        }
        self.pos = pos;
        return true;
    }

    fn tryRotate(self: *Intermediate, rotation: Rotation) bool {
        const new_piece = Piece{
            .facing = self.current.facing.rotate(rotation),
            .kind = self.current.kind,
        };

        for (self.kicks(self.current, rotation)) |kick| {
            const kicked_pos = self.pos.add(kick);
            if (!self.playfield.collides(new_piece, kicked_pos)) {
                self.current = new_piece;
                self.pos = kicked_pos;
                return true;
            }
        }

        return false;
    }

    pub fn onGround(self: Intermediate) bool {
        return self.playfield.collides(
            self.current,
            Position{ .x = self.pos.x, .y = self.pos.y - 1 },
        );
    }
};

/// Returns the set of all placements where the top of the piece does not
/// exceed `max_height`.
pub fn allPlacements(
    playfield: BoardMask,
    kicks: *const KickFn,
    piece_kind: PieceKind,
    max_height: u3,
) PiecePosSet {
    var seen = PiecePosSet.init();
    var placements = PiecePosSet.init();
    var stack = PlacementStack.init(0) catch unreachable;

    // Start floating right above `max_height`
    {
        const piece = Piece{ .facing = .up, .kind = piece_kind };
        const pos = Position{
            .x = 0,
            .y = @as(i8, max_height) + piece.minY(),
        };
        stack.append(PiecePosition.pack(piece, pos)) catch unreachable;
    }

    while (stack.popOrNull()) |placement| {
        const piece, const pos = blk: {
            const temp = placement.unpack(piece_kind);
            break :blk .{ temp.piece, temp.pos };
        };
        if (seen.putGet(piece, pos)) {
            continue;
        }

        for (Move.moves) |move| {
            var new_game = Intermediate{
                .playfield = playfield,
                .current = piece,
                .pos = pos,
                .kicks = kicks,
            };

            // Skip if piece was unable to move
            if (!new_game.makeMove(move)) {
                continue;
            }
            if (seen.contains(new_game.current, new_game.pos)) {
                continue;
            }

            // Branch out after movement
            stack.append(
                PiecePosition.pack(new_game.current, new_game.pos),
            ) catch unreachable;

            // Skip this placement if the piece is too high, or if it's not on the ground
            if (new_game.pos.y + @as(i8, new_game.current.top()) > max_height or
                !new_game.onGround())
            {
                continue;
            }

            placements.put(new_game.current, new_game.pos);
        }
    }

    return placements;
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
    max_height: u3,
    comptime validFn: fn (BoardMask, u3) bool,
    score_args: anytype,
    comptime scoreFn: fn (BoardMask, u3, @TypeOf(score_args)) f32,
) !void {
    var iter = moves.iterator(piece);
    while (iter.next()) |placement| {
        var board = playfield;
        board.place(PieceMask.from(placement.piece), placement.pos);
        const cleared = board.clearLines(placement.pos.y);
        const new_height = max_height - cleared;
        if (!validFn(board, new_height)) {
            continue;
        }

        try queue.add(.{
            .placement = placement,
            .score = scoreFn(board, max_height, score_args),
        });
    }
}

test allPlacements {
    var playfield = BoardMask{};
    playfield.mask |= @as(u64, 0b0111111110) << 30;
    playfield.mask |= @as(u64, 0b0010000000) << 20;
    playfield.mask |= @as(u64, 0b0000001000) << 10;
    playfield.mask |= @as(u64, 0b0000000001);

    const PIECE = PieceKind.l;
    const placements = allPlacements(playfield, engine.kicks.srs, PIECE, 5);

    var iter = placements.iterator(PIECE);
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try expect(count == 25);
}
