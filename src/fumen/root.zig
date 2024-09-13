const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const File = std.fs.File;

const engine = @import("engine");
const kicks = engine.kicks;
const GameState = engine.GameState(FumenReader.FixedBag);

const root = @import("perfect-tetris");
const NN = root.NN;
const pc = root.pc;
const pc_slow = root.pc_slow;
const Placement = root.Placement;

const enumValuesHelp = @import("../main.zig").enumValuesHelp;
const getNnOrDefault = @import("../main.zig").getNnOrDefault;
const FumenReader = @import("FumenReader.zig");

pub const Kicks = enum {
    none,
    none180,
    srs,
    srs180,
    srsPlus,
    srsTetrio,

    pub fn toEngine(self: Kicks) *const kicks.KickFn {
        return &switch (self) {
            .none => kicks.none,
            .none180 => kicks.none180,
            .srs => kicks.srs,
            .srs180 => kicks.srs180,
            .srsPlus => kicks.srsPlus,
            .srsTetrio => kicks.srsTetrio,
        };
    }
};

pub const OutputMode = enum {
    edit,
    list,
    view,

    pub fn toChr(self: OutputMode) u8 {
        return switch (self) {
            .edit => 'v',
            .list => 'D',
            .view => 'm',
        };
    }
};

pub const FumenArgs = struct {
    append: bool = false,
    help: bool = false,
    kicks: Kicks = .srs,
    nn: ?[]const u8 = null,
    @"output-type": OutputMode = .view,
    verbose: bool = false,

    pub const wrap_len: u32 = 35;

    pub const shorthands = .{
        .a = "append",
        .h = "help",
        .k = "kicks",
        .n = "nn",
        .t = "output-type",
        .v = "verbose",
    };

    pub const meta = .{
        .usage_summary = "fumen [options] INPUTS...",
        .full_text =
        \\Produces a perfect clear solution for each input fumen. Outputs each
        \\solution to stdout as a new fumen, separated by newlines. Fumen editor:
        \\https://fumen.zui.jp/#english.js
        ,
        .option_docs = .{
            .append = "Append solution frames to input fumen instead of making a new fumen from scratch.",
            .help = "Print this help message.",
            .kicks = std.fmt.comptimePrint(
                "Kick/rotation system to use. For kick systems that have a 180-less and 180 variant, the 180-less variant has no 180 rotations. The 180 variant has 180 rotations but no 180 kicks. " ++
                    enumValuesHelp(FumenArgs, Kicks) ++
                    " (default: {s})",
                .{@tagName((FumenArgs{}).kicks)},
            ),
            .nn = "The path to the neural network to use for the bot. If not provided, a default built-in network will be used.",
            .@"output-type" = std.fmt.comptimePrint(
                "The type of fumen to output. If append is true, this option is ignored. " ++
                    enumValuesHelp(FumenArgs, OutputMode) ++
                    " (default: {s})",
                .{@tagName((FumenArgs{}).@"output-type")},
            ),
            .verbose = "Print solve time and solution length to stderr.",
        },
    };
};

pub fn main(
    allocator: Allocator,
    args: FumenArgs,
    fumen: []const u8,
    nn: NN,
    stdout: File,
) !void {
    const start_t = std.time.nanoTimestamp();

    const parsed = try FumenReader.parse(allocator, fumen);
    defer parsed.deinit(allocator);

    const gamestate = parsed.toGameState(args.kicks.toEngine());
    const solution = findPc(
        allocator,
        parsed.next.len,
        gamestate,
        nn,
    ) catch |err| blk: {
        if (err != pc.FindPcError.NoPcExists and err != pc.FindPcError.SolutionTooLong) {
            return err;
        }
        std.debug.print("Unable to solve: {}\n", .{err});
        break :blk null;
    };
    defer if (solution) |sol| {
        allocator.free(sol);
    };
    const time_taken = std.time.nanoTimestamp() - start_t;

    // Print output fumen
    var bf = std.io.bufferedWriter(stdout.writer());
    const writer = bf.writer();
    if (solution) |sol| {
        try FumenReader.outputFumen(args, parsed, sol, writer);
    }
    try bf.flush();

    if (args.verbose) {
        if (solution) |sol| {
            std.debug.print(
                "Found solution of length {} in {}\n",
                .{ sol.len, std.fmt.fmtDuration(@intCast(time_taken)) },
            );
        } else {
            std.debug.print(
                "No solution found in {}\n",
                .{std.fmt.fmtDuration(@intCast(time_taken))},
            );
        }
    }
}

fn findPc(allocator: Allocator, len: usize, gamestate: GameState, nn: NN) ![]Placement {
    const placements = try allocator.alloc(Placement, len);
    errdefer allocator.free(placements);

    const field_height = blk: {
        var i: usize = engine.bit_masks.BoardMask.HEIGHT;
        while (i >= 1) : (i -= 1) {
            if (gamestate.playfield.rows[i - 1] != engine.bit_masks.BoardMask.EMPTY_ROW) {
                break;
            }
        }
        break :blk i;
    };
    const bits_set = blk: {
        var set: usize = 0;
        for (0..field_height) |i| {
            set += @popCount(gamestate.playfield.rows[i] & ~engine.bit_masks.BoardMask.EMPTY_ROW);
        }
        break :blk set;
    };
    const empty_cells = engine.bit_masks.BoardMask.WIDTH * field_height - bits_set;
    // Assumes that all pieces have 4 cells and that the playfield is 10 cells wide.
    // Thus, an odd number of empty cells means that a perfect clear is impossible.
    if (empty_cells % 2 == 1) {
        return pc.FindPcError.NoPcExists;
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
    const start_height = (4 * pieces_needed + bits_set) / engine.bit_masks.BoardMask.WIDTH;

    // Use fast pc if possible
    if (start_height <= 6) {
        const max_pieces = pieces_needed + ((6 - start_height) / 2 * 5);
        if (pc.findPc(
            FumenReader.FixedBag,
            allocator,
            gamestate,
            nn,
            @intCast(start_height),
            placements[0..@min(placements.len, max_pieces)],
        )) |solution| {
            assert(allocator.resize(placements, solution.len));
            return solution;
        } else |_| {}
    }

    const solution = try pc_slow.findPc(
        FumenReader.FixedBag,
        allocator,
        gamestate,
        nn,
        @intCast(start_height),
        placements,
    );
    assert(allocator.resize(placements, solution.len));
    return solution;
}

test {
    std.testing.refAllDecls(@This());
}
