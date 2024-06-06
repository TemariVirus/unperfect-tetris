pub const movegen = @import("movegen.zig");
pub const neat = @import("neat.zig");
pub const next = @import("next.zig");
pub const pc = @import("pc.zig");

const std = @import("std");
const assert = std.debug.assert;

const engine = @import("engine");
const Facing = engine.pieces.Facing;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Position = engine.pieces.Position;

pub const Placement = struct {
    piece: Piece,
    pos: Position,
};

pub const PiecePosition = packed struct {
    y: i8,
    x: i6,
    facing: Facing,

    pub fn pack(piece: Piece, pos: Position) PiecePosition {
        return PiecePosition{
            .y = pos.y,
            .x = @intCast(pos.x),
            .facing = piece.facing,
        };
    }
};

/// A set of combinations of pieces and their positions, within certain bounds
/// as defined by `shape`.
pub fn PiecePosSet(comptime shape: [3]usize) type {
    const len = shape[0] * shape[1] * shape[2];
    const BackingSet = std.StaticBitSet(len);

    return struct {
        const Self = @This();

        data: BackingSet,

        pub const Iterator = struct {
            set: BackingSet.Iterator(.{}),
            piece: PieceKind,

            pub fn next(self: *Iterator) ?Placement {
                if (self.set.next()) |index| {
                    return reverseIndex(self.piece, index);
                }
                return null;
            }
        };

        /// Initialises an empty set.
        pub fn init() Self {
            return Self{
                .data = BackingSet.initEmpty(),
            };
        }

        /// Converts a piece and position to an index into the backing bit set.
        pub fn flatIndex(piece: Piece, pos: Position) usize {
            const facing = @intFromEnum(piece.facing);
            const x: usize = @intCast(pos.x - piece.minX());
            const y: usize = @intCast(pos.y - piece.minY());

            assert(x < shape[0]);
            assert(y < shape[1]);
            assert(facing < shape[2]);

            return x + y * shape[0] + facing * shape[0] * shape[1];
        }

        /// Converts an index into the backing bit set to it's coressponding piece and
        /// position.
        pub fn reverseIndex(piece_kind: PieceKind, index: usize) Placement {
            const x = index % shape[0];
            const y = (index / shape[0]) % shape[1];
            const facing = index / (shape[0] * shape[1]);

            const piece = Piece{ .kind = piece_kind, .facing = @enumFromInt(facing) };
            return .{
                .piece = piece,
                .pos = .{ .x = @as(i8, @intCast(x)) + piece.minX(), .y = @as(i8, @intCast(y)) + piece.minY() },
            };
        }

        /// Returns `true` if the set contains the given piece-position combination;
        /// Otherwise, `false`.
        pub fn contains(self: Self, piece: Piece, pos: Position) bool {
            const index = Self.flatIndex(piece, pos);
            return self.data.isSet(index);
        }

        /// Adds the given piece-position combination to the set.
        pub fn put(self: *Self, piece: Piece, pos: Position) void {
            const index = Self.flatIndex(piece, pos);
            self.data.set(index);
        }

        /// Adds the given piece-position combination to the set. Returns `true` if the
        /// combination was already in the set; Otherwise, `false`.
        pub fn putGet(self: *Self, piece: Piece, pos: Position) bool {
            const index = Self.flatIndex(piece, pos);

            const was_set = self.data.isSet(index);
            self.data.set(index);
            return was_set;
        }

        /// Returns an iterator over the set.
        pub fn iterator(self: *const Self, piece_kind: PieceKind) Iterator {
            return Iterator{
                .set = self.data.iterator(.{}),
                .piece = piece_kind,
            };
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
