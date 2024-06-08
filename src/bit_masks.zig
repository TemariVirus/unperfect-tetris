const std = @import("std");
const assert = std.debug.assert;

const engine = @import("engine");
const BoardMaskEngine = engine.bit_masks.BoardMask;
const Piece = engine.pieces.Piece;
const PieceMaskEngine = engine.bit_masks.PieceMask;
const Position = engine.pieces.Position;

/// A 10 x 6 bit mask.
/// Coordinates start at (0, 0) at the bottom left corner.
/// X increases rightwards.
/// Y increases upwards.
pub const BoardMask = struct {
    pub const WIDTH = 10;
    pub const HEIGHT = 6;

    mask: u64 = 0,

    pub fn from(board_mask: BoardMaskEngine) BoardMask {
        var mask: u64 = 0;
        for (0..6) |y| {
            mask |= @as(u64, board_mask.rows[y] & ~BoardMaskEngine.EMPTY_ROW) << @intCast(y * 10) >> 1;
        }
        for (6..BoardMaskEngine.HEIGHT) |y| {
            assert(board_mask.rows[y] == BoardMaskEngine.EMPTY_ROW);
        }
        return .{ .mask = mask };
    }

    pub fn row(self: BoardMask, y: u3) u10 {
        assert(y >= 0 and y < HEIGHT);
        return @truncate(self.mask >> (@as(u6, y) * 10));
    }

    pub fn getShift(pos: Position) i8 {
        return @min(63, pos.y * WIDTH - pos.x);
    }

    pub fn collides(self: BoardMask, piece: Piece, pos: Position) bool {
        if (pos.x < piece.minX() or pos.x > piece.maxX() or pos.y < piece.minY()) {
            return true;
        }

        const shift = getShift(pos);
        if (shift > 0) {
            return self.mask & (PieceMask.from(piece).mask << @intCast(shift)) != 0;
        }
        return self.mask & (PieceMask.from(piece).mask >> @intCast(-shift)) != 0;
    }

    pub fn place(self: *BoardMask, piece: PieceMask, pos: Position) void {
        const shift = getShift(pos);
        self.mask |= if (shift > 0)
            piece.mask << @intCast(shift)
        else
            piece.mask >> @intCast(-shift);
    }

    /// Clears all filled lines in the playfield.
    /// Returns the number of lines cleared.
    pub fn clearLines(self: *BoardMask, y: i8) u3 {
        // TODO: check performance of storing clears as chunks
        var cleared: u3 = 0;
        var i: usize = @max(0, y);
        var full_row = (@as(u64, 1) << BoardMask.WIDTH) - 1;
        full_row = full_row << @intCast(i * WIDTH);
        while (i + cleared < HEIGHT) {
            if (self.mask & full_row == full_row) {
                cleared += 1;
                const bottom_mask = @as(u64, @bitCast(@as(i64, @bitCast(full_row)) & -@as(i64, @bitCast(full_row)))) - 1;
                const bottom = self.mask & bottom_mask;
                const top = (self.mask >> WIDTH) & ~bottom_mask;
                self.mask = top | bottom;
            } else {
                i += 1;
                full_row <<= 10;
            }
        }
        return cleared;
    }
};

/// A 10 x 4 bit mask.
/// Coordinates start at (0, 0) at the bottom left corner.
/// X increases rightwards.
/// Y increases upwards.
pub const PieceMask = struct {
    pub const WIDTH = 10;
    pub const HEIGHT = 4;

    mask: u64,

    pub fn from(piece: Piece) PieceMask {
        const table = comptime makeAttributeTable(PieceMask, fromRaw);
        return table[@as(u5, @bitCast(piece))];
    }

    fn fromRaw(piece: Piece) PieceMask {
        return fromMask(piece.mask());
    }

    pub fn fromMask(piece_mask: PieceMaskEngine) PieceMask {
        var mask: u64 = 0;
        for (0..4) |i| {
            mask |= @as(u64, (piece_mask.rows[i] >> 1)) << (i * 10);
        }
        return .{ .mask = mask };
    }

    // TODO: iterate through enum fields instead of hardcoded values
    fn makeAttributeTable(comptime T: type, comptime attribute: fn (Piece) T) [28]T {
        var table: [28]T = undefined;
        for (0..7) |piece_kind| {
            for (0..4) |facing| {
                const piece = Piece{
                    .facing = @enumFromInt(facing),
                    .kind = @enumFromInt(piece_kind),
                };
                table[@as(u5, @bitCast(piece))] = attribute(piece);
            }
        }
        return table;
    }
};
