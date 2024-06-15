pub const bit_masks = @import("bit_masks.zig");
const BoardMask = bit_masks.BoardMask;
pub const movegen = @import("movegen.zig");
pub const next = @import("next.zig");
pub const pc = @import("pc.zig");

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expect = std.testing.expect;

const engine = @import("engine");
const Facing = engine.pieces.Facing;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Position = engine.pieces.Position;

const NNInner = @import("zmai").genetic.neat.NN;

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

    pub fn unpack(self: PiecePosition, piece_kind: PieceKind) Placement {
        return .{
            .piece = .{ .kind = piece_kind, .facing = self.facing },
            .pos = .{ .y = self.y, .x = self.x },
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
                .pos = .{
                    .x = @as(i8, @intCast(x)) + piece.minX(),
                    .y = @as(i8, @intCast(y)) + piece.minY(),
                },
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

pub const NN = struct {
    net: NNInner,
    inputs_used: [7]bool,

    pub fn load(allocator: Allocator, path: []const u8) !NN {
        var inputs_used: [7]bool = undefined;
        const nn = try NNInner.load(allocator, path, &inputs_used);
        return .{
            .net = nn,
            .inputs_used = inputs_used,
        };
    }

    pub fn deinit(self: NN, allocator: Allocator) void {
        self.net.deinit(allocator);
    }

    pub fn predict(self: NN, input: [7]f32) f32 {
        var output: [1]f32 = undefined;
        self.net.predict(&input, &output);
        return output[0];
    }
};

// TODO: Optimise with SIMD?
pub fn getFeatures(playfield: BoardMask, max_height: u3, inputs_used: [7]bool) [7]f32 {
    // Find highest block in each column. Heights start from 0
    var column = comptime blk: {
        var column = @as(u64, 1);
        column |= column << BoardMask.WIDTH;
        column |= column << BoardMask.WIDTH;
        column |= column << (3 * BoardMask.WIDTH);
        break :blk column;
    };

    var heights: [10]i32 = undefined;
    var highest: u3 = 0;
    for (0..10) |x| {
        const height: u3 = @intCast(6 - ((@clz(playfield.mask & column) - 4) / 10));
        heights[x] = height;
        highest = @max(highest, height);
        column <<= 1;
    }

    // Standard height (sqrt of sum of squares of heights)
    const std_h = if (inputs_used[0]) blk: {
        var sqr_sum: i32 = 0;
        for (heights) |h| {
            sqr_sum += h * h;
        }
        break :blk @sqrt(@as(f32, @floatFromInt(sqr_sum)));
    } else undefined;

    // Caves (empty cells with an overhang)
    const caves: f32 = if (inputs_used[1]) blk: {
        const aug_heights = inner: {
            var aug_h: [10]i32 = undefined;
            aug_h[0] = @min(heights[0] - 2, heights[1]);
            for (1..9) |x| {
                aug_h[x] = @min(heights[x] - 2, @max(heights[x - 1], heights[x + 1]));
            }
            aug_h[9] = @min(heights[9] - 2, heights[8]);
            // NOTE: Uncomment this line to restore the bug in the original code
            // aug_h[9] = @min(heights[9] - 2, heights[8] - 1);
            break :inner aug_h;
        };

        var caves: i32 = 0;
        for (0..@max(1, highest) - 1) |y| {
            var covered = ~playfield.row(@intCast(y)) & playfield.row(@intCast(y + 1));
            // Iterate through set bits
            while (covered != 0) : (covered &= covered - 1) {
                const x = @ctz(covered);
                if (y <= aug_heights[x]) {
                    // Caves deeper down get larger values
                    caves += heights[x] - @as(i32, @intCast(y));
                }
            }
        }

        break :blk @floatFromInt(caves);
    } else undefined;

    // Pillars (sum of min differences in heights)
    const pillars: f32 = if (inputs_used[2]) blk: {
        var pillars: i32 = 0;
        for (0..10) |x| {
            // Columns at the sides map to 0 if they are taller
            var diff: i32 = switch (x) {
                // NOTE: Uncomment this line to restore the bug in the original code
                // 0 => @min(0, heights[1] - heights[0]),
                0 => @max(0, heights[1] - heights[0]),
                1...8 => @intCast(@min(
                    @abs(heights[x - 1] - heights[x]),
                    @abs(heights[x + 1] - heights[x]),
                )),
                9 => @max(0, heights[8] - heights[9]),
                else => unreachable,
            };
            // Exaggerate large differences
            if (diff > 2) {
                diff *= diff;
            }
            pillars += diff;
        }
        break :blk @floatFromInt(pillars);
    } else undefined;

    // Row trasitions
    const row_mask = comptime blk: {
        var row_mask: u64 = 0b1111111110;
        row_mask |= row_mask << BoardMask.WIDTH;
        row_mask |= row_mask << BoardMask.WIDTH;
        row_mask |= row_mask << (3 * BoardMask.WIDTH);
        break :blk row_mask;
    };
    const row_trans: f32 = if (inputs_used[3])
        @floatFromInt(@popCount((playfield.mask ^ (playfield.mask << 1)) & row_mask))
    else
        undefined;

    // Column trasitions
    const col_trans: f32 = if (inputs_used[4]) blk: {
        var col_trans: u32 = @popCount(playfield.row(@max(1, highest) - 1));
        for (0..@max(1, highest) - 1) |y| {
            col_trans += @popCount(playfield.row(@intCast(y)) ^ playfield.row(@intCast(y + 1)));
        }
        break :blk @floatFromInt(col_trans);
    } else undefined;

    return .{
        std_h,
        caves,
        pillars,
        row_trans,
        col_trans,
        // Max height
        @floatFromInt(max_height),
        // Empty cells
        @floatFromInt(@as(u6, max_height) * 10 - @popCount(playfield.mask)),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test getFeatures {
    const features = getFeatures(
        BoardMask{
            .mask = 0b0000000100 << (5 * BoardMask.WIDTH) |
                0b0000100000 << (4 * BoardMask.WIDTH) |
                0b0011010001 << (3 * BoardMask.WIDTH) |
                0b1000000001 << (2 * BoardMask.WIDTH) |
                0b0010000001 << (1 * BoardMask.WIDTH) |
                0b1111111111 << (0 * BoardMask.WIDTH),
        },
        6,
        [_]bool{true} ** 7,
    );
    try expect(features[0] == 11.7046995);
    try expect(features[1] == 10);
    try expect(features[2] == 47);
    try expect(features[3] == 14);
    try expect(features[4] == 22);
    try expect(features[5] == 6);
    try expect(features[6] == 40);
}
