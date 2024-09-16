const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const engine = @import("engine");
const Bag = engine.bags.NoBag;
const Facing = engine.pieces.Facing;
const GameState = engine.GameState(Bag);
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;

const MAX_SEQ_LEN = 16;

pub const ValidateArgs = struct {
    help: bool = false,

    pub const wrap_len: u32 = 50;

    pub const shorthands = .{
        .h = "help",
    };

    pub const meta = .{
        .usage_summary = "validate [options] PATHS...",
        .full_text =
        \\Validates the perfect clear solutions saved at PATHS. This will validate
        \\that PATHS are valid .pc files and that all solutions are valid perfect
        \\clear solutions.
        ,
        .option_docs = .{
            .help = "Print this help message.",
        },
    };
};

pub fn main(args: ValidateArgs, path: []const u8) !void {
    _ = args; // autofix

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    try std.io.getStdOut().writer().print("Validating {s}\n", .{path});

    var solution_count: u64 = 0;
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();
    while (true) {
        const seq = reader.readInt(u48, .little) catch |e| {
            if (e == error.EndOfStream) {
                break;
            }
            return e;
        };
        const holds = try reader.readInt(u16, .little);

        var pieces = [_]PieceKind{undefined} ** MAX_SEQ_LEN;
        var next_len: usize = 0;
        while (next_len < MAX_SEQ_LEN) : (next_len += 1) {
            const p: u3 = @truncate(seq >> @intCast(3 * next_len));
            // 0b111 is the sentinel value for the end of the sequence.
            if (p == 0b111) {
                break;
            }
            pieces[next_len] = @enumFromInt(p);
        }
        if (next_len == 0) {
            try printValidationError(file, reader, solution_count);
            return;
        }

        var state = GameState.init(Bag.init(0), engine.kicks.none);
        for (1..next_len) |i| {
            const placement = try reader.readByte();

            if ((holds >> @intCast(i - 1)) & 1 == 1) {
                std.mem.swap(PieceKind, &pieces[0], &pieces[i]);
            }
            const facing: Facing = @enumFromInt(@as(u2, @truncate(placement)));
            state.current = Piece{ .facing = facing, .kind = pieces[i] };

            const canon_pos = placement >> 2;
            state.pos = state.current.fromCanonicalPosition(.{
                .x = @intCast(canon_pos % 10),
                .y = @intCast(canon_pos / 10),
            });

            const info = state.lockCurrent(-1);
            // Last move must be a PC
            if (i == next_len - 1 and !info.pc) {
                try printValidationError(file, reader, solution_count);
                return;
            }
        }

        solution_count += 1;
    }

    try std.io.getStdOut().writer().print(
        "Validated {} solutions. All solutions ok.\n",
        .{solution_count},
    );
}

fn printValidationError(
    file: std.fs.File,
    reader: anytype,
    solution_count: u64,
) !void {
    const bytes = try file.getPos() -
        @as(u64, @intCast(reader.context.end)) +
        @as(u64, @intCast(reader.context.start));
    try std.io.getStdOut().writer().print(
        "Error at solution {} (byte {})\n",
        .{ solution_count, bytes },
    );
}
