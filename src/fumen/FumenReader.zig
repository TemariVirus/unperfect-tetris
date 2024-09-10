const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const unicode = std.unicode;

const engine = @import("engine");
const Color = ColorArray.PackedColor;
const ColorArray = engine.player.ColorArray;
const Facing = engine.pieces.Facing;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Position = engine.pieces.Position;

const NextArray = std.ArrayList(PieceKind);

const Self = @This();

const b64_encode_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const b64_decode_table = blk: {
    var table = [_]?u6{null} ** 256;
    for (b64_encode_table, 0..) |char, i| {
        table[char] = i;
    }
    break :blk table;
};

const caption_encode_table = blk: {
    var table = [_]?u6{null} ** 256;
    for (caption_decode_table, 0..) |char, i| {
        table[char] = i;
    }
    break :blk table;
};
const caption_decode_table =
    \\ !"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~
;

allocator: Allocator,
data: []const u8,
pos: usize = 0,
// Extra data kept accross pages for bookkeeping
field: [240]FumenBlock = [_]FumenBlock{.empty} ** 240,
field_repeat: u6 = 0,
hold: ?PieceKind = null,
current: ?PieceKind = null,
next: NextArray,

pub const FixedBag = struct {
    pieces: []PieceKind,
    index: usize = 0,

    pub fn init(seed: u64) Self {
        _ = seed; // autofix
        return .{ .pieces = &.{} };
    }

    pub fn next(self: *Self) PieceKind {
        defer self.index += 1;
        return self.pieces[self.index];
    }

    pub fn setSeed(self: *Self, seed: u64) void {
        _ = self; // autofix
        _ = seed; // autofix
    }
};

const FumenBlock = enum(u8) {
    empty = 0,
    i = 1,
    l = 2,
    o = 3,
    z = 4,
    t = 5,
    j = 6,
    s = 7,
    garbage = 8,

    pub fn toEngine(self: FumenBlock) Color {
        return switch (self) {
            .empty => .empty,
            .i => PieceKind.color(.i),
            .l => PieceKind.color(.l),
            .o => PieceKind.color(.o),
            .z => PieceKind.color(.z),
            .t => PieceKind.color(.t),
            .j => PieceKind.color(.j),
            .s => PieceKind.color(.s),
            .garbage => .garbage,
        };
    }

    pub fn toPieceKind(self: FumenBlock) PieceKind {
        return switch (self) {
            .i => .i,
            .l => .l,
            .o => .o,
            .z => .z,
            .t => .t,
            .j => .j,
            .s => .s,
            else => unreachable,
        };
    }

    pub fn fromPieceKind(self: PieceKind) FumenBlock {
        return switch (self) {
            .i => .i,
            .l => .l,
            .o => .o,
            .z => .z,
            .t => .t,
            .j => .j,
            .s => .s,
        };
    }
};

const FumenRotation = enum(u2) {
    south = 0,
    east = 1,
    north = 2,
    west = 3,

    pub fn toEngine(self: FumenRotation) Facing {
        return switch (self) {
            .south => .down,
            .east => .right,
            .north => .up,
            .west => .left,
        };
    }
};

pub const AllocOrFumenError = Allocator.Error || FumenError;
pub const FumenError = error{
    EndOfData,
    InvalidBlock,
    InvalidCaption,
    InvalidFieldLength,
    InvalidPieceLocation,
    InvalidPieceLetter,
    InvalidQuizCaption,
    InvalidQuizPiece,
    UnsupportedFumenVersion,
};

// TODO: convert reader data to output state
pub fn parse(allocator: Allocator, fumen: []const u8) AllocOrFumenError!void {
    var reader = try Self.init(allocator, fumen);
    defer reader.deinit();

    while (reader.pos < reader.data.len) {
        try reader.readPage();
    }
}

fn init(allocator: Allocator, fumen: []const u8) FumenError!Self {
    // Only version 1.15 is supported
    const start = std.mem.lastIndexOf(u8, fumen, "115@") orelse
        return FumenError.UnsupportedFumenVersion;
    // Fumen may be a url, remove addons (which come after a '#')
    const end = std.mem.indexOfScalar(u8, fumen[start..], '#') orelse fumen.len;
    return .{
        .allocator = allocator,
        // + 4 to skip the "115@" prefix
        .data = fumen[start + 4 .. end],
        .next = NextArray.init(allocator),
    };
}

fn deinit(self: *Self) void {
    self.next.deinit();
}

fn pollOne(self: *Self) FumenError!u6 {
    // Read until next valid character (fumens sometimes contain '?'s that should be ignored)
    while (self.pos < self.data.len) : (self.pos += 1) {
        if (b64_decode_table[self.data[self.pos]]) |v| {
            self.pos += 1;
            return v;
        }
    }
    return FumenError.EndOfData;
}

fn poll(self: *Self, n: usize) FumenError!u32 {
    assert(n <= 5);

    var result: u32 = 0;
    for (0..n) |i| {
        result += @as(u32, try self.pollOne()) << @intCast(6 * i);
    }
    return result;
}

fn readField(self: *Self) FumenError!void {
    if (self.field_repeat > 0) {
        self.field_repeat -= 1;
        return;
    }

    // If diff is empty, read the repeat count
    if (try self.poll(2) == 9 * self.field.len - 1) {
        self.field_repeat = try self.pollOne();
        return;
    }
    self.pos -= 2;

    // Read run-length encoded playfield
    var total: u32 = 0;
    while (total < self.field.len) {
        const run = try self.poll(2);

        // Don't substract 8 yet to prevent underflow
        const block_temp = @intFromEnum(self.field[total]) + (run / 240);
        if (block_temp < 8 or block_temp > 16) {
            return FumenError.InvalidBlock;
        }

        const block: FumenBlock = @enumFromInt(block_temp - 8);
        const len = (run % 240) + 1;
        for (total..total + len) |i| {
            self.field[i] = block;
        }
        total += len;
    }

    if (total != self.field.len) {
        return FumenError.InvalidFieldLength;
    }
}

fn boolFromInt(x: u1) bool {
    return switch (x) {
        0 => false,
        1 => true,
    };
}

fn readPieceAndFlags(self: *Self) FumenError!struct {
    ?Piece,
    ?Position,
    struct {
        raise: bool,
        mirror: bool,
        has_caption: bool,
        lock: bool,
    },
} {
    var v = try self.poll(3);

    const piece = blk: {
        const block: FumenBlock = @enumFromInt(v % 8);
        v /= 8;
        const rotation: FumenRotation = @enumFromInt(v % 4);
        v /= 4;
        break :blk if (block == .empty)
            null
        else
            Piece{
                .facing = rotation.toEngine(),
                .kind = block.toPieceKind(),
            };
    };

    const pos = blk: {
        const location = v % 240;
        break :blk if (piece) |_| Position{
            .x = @intCast(location % 10),
            .y = @intCast(location / 10),
        } else null;
    };
    v /= 240;

    const raise = boolFromInt(@intCast(v % 2));
    v /= 2;
    const mirror = boolFromInt(@intCast(v % 2));
    v /= 2;
    // NOTE: The color flag is only used for the first page. From the
    // second page onwards, `color` is always `false`.
    _ = boolFromInt(@intCast(v % 2)); // color
    v /= 2;
    const has_caption = boolFromInt(@intCast(v % 2));
    v /= 2;
    const lock = !boolFromInt(@intCast(v % 2));

    return .{
        piece,
        pos,
        .{
            .raise = raise,
            .mirror = mirror,
            .has_caption = has_caption,
            .lock = lock,
        },
    };
}

fn readCaption(self: *Self) AllocOrFumenError![]u8 {
    const len = try self.poll(2);
    var caption = try std.ArrayList(u8).initCapacity(self.allocator, len);
    errdefer caption.deinit();

    var i: u32 = 0;
    while (i < len) : (i += 4) {
        var v = try self.poll(5);
        for (0..@min(4, len - i)) |_| {
            if (v % 96 >= caption_decode_table.len) {
                return FumenError.InvalidCaption;
            }
            caption.appendAssumeCapacity(caption_decode_table[v % 96]);
            v /= 96;
        }
    }

    // Unescape characters
    var read: usize = 0;
    var write: usize = 0;
    while (read < caption.items.len) {
        if (caption.items[read] != '%') {
            caption.items[write] = caption.items[read];
            read += 1;
            write += 1;
            continue;
        }

        if (read + 2 >= caption.items.len) {
            return FumenError.InvalidCaption;
        }
        const codepoint = if (caption.items[read + 1] != 'u') blk: {
            defer read += 3;
            break :blk std.fmt.parseInt(
                u21,
                caption.items[read + 1 .. read + 3],
                16,
            ) catch return FumenError.InvalidCaption;
        } else blk: {
            if (read + 5 >= caption.items.len) {
                return FumenError.InvalidCaption;
            }
            defer read += 6;
            break :blk std.fmt.parseInt(
                u21,
                caption.items[read + 2 .. read + 6],
                16,
            ) catch return FumenError.InvalidCaption;
        };
        write +=
            unicode.utf8Encode(codepoint, caption.items[write..]) catch
            return FumenError.InvalidCaption;
        continue;
    }

    caption.items.len = write;
    return try caption.toOwnedSlice();
}

fn readPieceKind(char: u8) ?PieceKind {
    return switch (char) {
        'I' => .i,
        'O' => .o,
        'T' => .t,
        'L' => .l,
        'J' => .j,
        'S' => .s,
        'Z' => .z,
        else => null,
    };
}

fn readQuiz(self: *Self, caption: []const u8) AllocOrFumenError!void {
    // Hold piece
    var i: usize = 0;
    if (caption[i] != '[') {
        return FumenError.InvalidQuizCaption;
    }
    i += 1;
    if (caption[i] == ']') {
        self.hold = null;
    } else {
        self.hold = readPieceKind(caption[i]) orelse
            return FumenError.InvalidPieceLetter;
        i += 1;
        if (caption[i] != ']') {
            return FumenError.InvalidQuizCaption;
        }
    }
    i += 1;

    // Current piece
    if (caption[i] != '(') {
        return FumenError.InvalidQuizCaption;
    }
    i += 1;
    if (caption[i] == ')') {
        self.current = null;
    } else {
        self.current = readPieceKind(caption[i]) orelse
            return FumenError.InvalidPieceLetter;
        i += 1;
        if (caption[i] != ')') {
            return FumenError.InvalidQuizCaption;
        }
    }
    i += 1;

    self.next.clearRetainingCapacity();
    try self.next.ensureTotalCapacity(caption.len - i);
    for (i..caption.len) |j| {
        const piece_kind = readPieceKind(caption[j]) orelse
            return FumenError.InvalidPieceLetter;
        self.next.appendAssumeCapacity(piece_kind);
    }
    std.mem.reverse(PieceKind, self.next.items);
}

fn getMinos(piece: Piece) [4]Position {
    return switch (piece.kind) {
        .i => switch (piece.facing) {
            .up, .down => [_]Position{
                .{ .x = -1, .y = 0 },
                .{ .x = 0, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = 2, .y = 0 },
            },
            .left, .right => [_]Position{
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = 1 },
                .{ .x = 0, .y = 2 },
            },
        },
        .o => [_]Position{
            .{ .x = 0, .y = 0 },
            .{ .x = 1, .y = 0 },
            .{ .x = 0, .y = 1 },
            .{ .x = 1, .y = 1 },
        },
        .t => switch (piece.facing) {
            .up => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = 0, .y = -1 },
            },
            .right => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 1 },
                .{ .x = 1, .y = 0 },
            },
            .down => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = 0, .y = 1 },
            },
            .left => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 1 },
                .{ .x = -1, .y = 0 },
            },
        },
        .l => switch (piece.facing) {
            .up => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = 1, .y = -1 },
            },
            .right => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 1 },
                .{ .x = 1, .y = 1 },
            },
            .down => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = -1, .y = 1 },
            },
            .left => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 1 },
                .{ .x = -1, .y = -1 },
            },
        },
        .j => switch (piece.facing) {
            .up => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = -1, .y = -1 },
            },
            .right => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 1 },
                .{ .x = 1, .y = -1 },
            },
            .down => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = 1, .y = 1 },
            },
            .left => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = -1 },
                .{ .x = 0, .y = 1 },
                .{ .x = -1, .y = 1 },
            },
        },
        .s => switch (piece.facing) {
            .up, .down => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 1, .y = 0 },
                .{ .x = -1, .y = 1 },
                .{ .x = 0, .y = 1 },
            },
            .left, .right => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = 1 },
                .{ .x = -1, .y = 0 },
                .{ .x = -1, .y = -1 },
            },
        },
        .z => switch (piece.facing) {
            .up, .down => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = -1, .y = 0 },
                .{ .x = 0, .y = 1 },
                .{ .x = 1, .y = 1 },
            },
            .left, .right => [_]Position{
                .{ .x = 0, .y = 0 },
                .{ .x = 0, .y = 1 },
                .{ .x = 1, .y = 0 },
                .{ .x = 1, .y = -1 },
            },
        },
    };
}

fn clearLines(self: *Self) void {
    // Bottom row should not be cleared, start from second bottom row
    var y: usize = 23;
    var cleared: usize = 0;
    while (y > 0) {
        y -= 1;
        var full = true;
        for (0..10) |x| {
            self.field[(y + cleared) * 10 + x] = self.field[y * 10 + x];
            if (self.field[y * 10 + x] == .empty) {
                full = false;
            }
        }
        if (full) {
            cleared += 1;
        }
    }

    // Add empty rows at the top
    for (0..cleared) |i| {
        for (0..10) |x| {
            self.field[i * 10 + x] = .empty;
        }
    }
}

fn riseField(self: *Self) void {
    for (0..self.field.len - 10) |i| {
        self.field[i] = self.field[i + 10];
    }
    // Empty botom row
    for (self.field.len - 10..self.field.len) |i| {
        self.field[i] = .empty;
    }
}

fn mirrorField(self: *Self) void {
    // Don't mirror bottom row
    for (0..23) |y| {
        for (0..10) |x| {
            self.field[y * 10 + x] = self.field[y * 10 + 9 - x];
        }
    }
}

fn readPage(self: *Self) AllocOrFumenError!void {
    try self.readField();
    const piece, const pos, const flags = try self.readPieceAndFlags();

    if (flags.has_caption) {
        const caption = try self.readCaption();
        defer self.allocator.free(caption);
        std.debug.print("comment: {s}\n", .{caption});
        // Check for quiz prefix
        if (std.mem.startsWith(u8, caption, "#Q=")) {
            try self.readQuiz(caption[3..]);
            if (self.current == null) {
                self.current = self.next.popOrNull();
            }
        } else {
            // Else empty quiz state
            self.hold = null;
            self.current = null;
            self.next.clearRetainingCapacity();
        }
    }

    if (!flags.lock) {
        return;
    }

    // Place piece
    if (piece) |p| blk: {
        assert(pos != null);

        for (getMinos(p)) |mino| {
            const mino_pos = pos.?.add(mino);
            // Pieces cannot be placed in bottom row, but can extend out of the top
            if (mino_pos.x < 0 or mino_pos.x >= 10 or mino_pos.y >= 23) {
                return FumenError.InvalidPieceLocation;
            }
            // Pieces should not overlap with existing blocks
            const index: usize = if (@as(i32, mino_pos.y) * 10 + mino_pos.x < 0)
                continue
            else
                @intCast(@as(i32, mino_pos.y) * 10 + mino_pos.x);
            if (self.field[index] != .empty) {
                return FumenError.InvalidPieceLocation;
            }
            self.field[index] = FumenBlock.fromPieceKind(p.kind);
        }

        // Don't update quiz state if quiz is over
        if (self.current == null and self.hold == null and self.next.items.len == 0) {
            break :blk;
        }

        assert(self.current != null);
        if (p.kind != self.current) {
            std.mem.swap(?PieceKind, &self.current, &self.hold);
            if (self.current == null) {
                self.current = self.next.popOrNull();
            }
        }
        if (p.kind != self.current) {
            return FumenError.InvalidQuizPiece;
        }
        self.current = self.next.popOrNull();
    }
    self.clearLines();

    if (flags.raise) {
        self.riseField();
    }
    if (flags.mirror) {
        self.mirrorField();
    }
}
