const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const json = std.json;
const unicode = std.unicode;

const NN = @import("perfect-tetris").NN;
const enumValuesHelp = @import("main.zig").enumValuesHelp;

const engine = @import("engine");
const BoardMask = engine.bit_masks.BoardMask;
const Color = ColorArray.PackedColor;
const ColorArray = engine.player.ColorArray;
const Facing = engine.pieces.Facing;
const kicks = engine.kicks;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Position = engine.pieces.Position;

const NNInner = @import("zmai").genetic.neat.NN;
const nn_json = @embedFile("nn_json");

pub const Kicks = enum {
    none,
    none180,
    srs,
    srs180,
    srsPlus,
    srsTetrio,

    pub fn toEngine(self: Kicks) kicks.KickFn {
        switch (self) {
            .none => return kicks.none,
            .none180 => return kicks.none180,
            .srs => return kicks.srs,
            .srs180 => return kicks.srs180,
            .srsPlus => return kicks.srsPlus,
            .srsTetrio => return kicks.srsTetrio,
        }
    }
};

pub const OutputMode = enum {
    edit,
    list,
    view,
};

pub const FumenArgs = struct {
    append: bool = false,
    help: bool = false,
    kicks: Kicks = .srs,
    @"output-type": OutputMode = .view,

    pub const wrap_len: u32 = 40;

    pub const shorthands = .{
        .a = "append",
        .h = "help",
        .k = "kicks",
        .t = "output-type",
    };

    pub const meta = .{
        .usage_summary = "fumen [options] INPUTS...",
        .full_text =
        \\Produces a perfect clear solution for each input fumen. Outputs each
        \\solution as a new fumen, separated by newlines.
        ,
        .option_docs = .{
            .append = "Append solution frames to input fumen instead of making a new fumen from scratch.",
            .help = "Print this help message.",
            // TODO
            // For kick systems that have a
            // 180-less and 180 variant, the 180-less variant has no 180
            // rotations. The 180 variant has 180 rotations but no 180 kicks.
            // Kick systems
            .kicks = std.fmt.comptimePrint(
                "Permitted kick/rotation system. " ++
                    enumValuesHelp(FumenArgs, Kicks) ++
                    " (default: {s})",
                .{@tagName((FumenArgs{}).kicks)},
            ),
            .@"output-type" = std.fmt.comptimePrint(
                "The type of fumen to output. If append is true, this option is ignored. " ++
                    enumValuesHelp(FumenArgs, OutputMode) ++
                    " (default: {s})",
                .{@tagName((FumenArgs{}).@"output-type")},
            ),
        },
    };
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

    // pub fn toEngine(self: FumenRotation, piece_kind: PieceKind) Facing {
    //     return switch (piece_kind) {
    //         .o => .right,
    //         .i => switch (self) {
    //             .south => .up,
    //             .east => .right,
    //             .north => .up,
    //             .west => .right,
    //         },
    //         .s, .z => switch (self) {
    //             .south => .down,
    //             .east => .left,
    //             .north => .down,
    //             .west => .left,
    //         },
    //         .t, .j, .l => switch (self) {
    //             .south => .down,
    //             .east => .right,
    //             .north => .up,
    //             .west => .left,
    //         },
    //     };
    // }
};

pub const FumenError = error{
    EndOfData,
    InvalidBlock,
    InvalidCaption,
    InvalidFieldLength,
    // InvalidPieceLocation,
    NonZeroLocationForEmptyPiece,
    UnsupportedFumenVersion,
};
const FumenReader = struct {
    const encode_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const decode_table = blk: {
        var table = [_]?u6{null} ** 256;
        for (encode_table, 0..) |char, i| {
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
    field: [240]FumenBlock = [_]FumenBlock{.empty} ** 240,
    field_repeat: u6 = 0,

    pub fn init(allocator: Allocator, fumen: []const u8) FumenError!FumenReader {
        // Only version 1.15 is supported
        const start = std.mem.lastIndexOf(u8, fumen, "115@") orelse
            return FumenError.UnsupportedFumenVersion;
        // Fumen may be a url, remove addons (which come after a '#')
        const end = std.mem.indexOfScalar(u8, fumen[start..], '#') orelse fumen.len;
        return .{
            .allocator = allocator,
            // + 4 to skip the "115@" prefix
            .data = fumen[start + 4 .. end],
        };
    }

    fn pollOne(self: *FumenReader) FumenError!u6 {
        // Read until next valid character (fumens sometimes contain '?'s that should be ignored)
        while (self.pos < self.data.len) : (self.pos += 1) {
            if (decode_table[self.data[self.pos]]) |v| {
                self.pos += 1;
                return v;
            }
        }
        return FumenError.EndOfData;
    }

    pub fn poll(self: *FumenReader, n: usize) FumenError!u32 {
        assert(n <= 5);

        var result: u32 = 0;
        for (0..n) |i| {
            result += @as(u32, try self.pollOne()) << @intCast(6 * i);
        }
        return result;
    }

    fn readField(self: *FumenReader) FumenError!void {
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

    fn readPieceAndFlags(self: *FumenReader) FumenError!struct {
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
            if (piece) |_| {
                break :blk Position{
                    .x = @intCast(location % 10),
                    .y = @intCast(location / 10),
                };
            }
            if (location != 0) {
                return FumenError.NonZeroLocationForEmptyPiece;
            }
            break :blk null;
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

    fn readCaption(self: *FumenReader) (Allocator.Error || FumenError)![]u8 {
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
                std.unicode.utf8Encode(codepoint, caption.items[write..]) catch
                return FumenError.InvalidCaption;
            continue;
        }

        caption.items.len = write;
        return try caption.toOwnedSlice();
    }

    pub fn readPage(self: *FumenReader) (Allocator.Error || FumenError)!void {
        try self.readField();
        const piece, const pos, const flags = try self.readPieceAndFlags();
        std.debug.print("piece: {any}, pos: {any}\n", .{ piece, pos });
        std.debug.print("flags: {any}\n", .{flags});

        if (flags.has_caption) {
            const caption = try self.readCaption();
            defer self.allocator.free(caption);

            std.debug.print("{s}\n", .{caption});
        }
    }
};

fn getNn(allocator: Allocator) !NN {
    const obj = try json.parseFromSlice(NNInner.NNJson, allocator, nn_json, .{
        .ignore_unknown_fields = true,
    });
    defer obj.deinit();

    var inputs_used: [NN.INPUT_COUNT]bool = undefined;
    const _nn = try NNInner.fromJson(allocator, obj.value, &inputs_used);
    return NN{
        .net = _nn,
        .inputs_used = inputs_used,
    };
}

// TODO: Implement fumen command
pub fn main(allocator: Allocator, args: FumenArgs, fumen: []const u8) !void {
    _ = args; // autofix

    // Solving step
    const nn = try getNn(allocator);
    defer nn.deinit(allocator);

    var reader = try FumenReader.init(allocator, fumen);
    for (0..3) |_| {
        try reader.readPage();
    }
}
