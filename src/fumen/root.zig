const std = @import("std");
const Allocator = std.mem.Allocator;
const File = std.fs.File;

const kicks = @import("engine").kicks;

const root = @import("perfect-tetris");
const NN = root.NN;
const pc = root.pc;
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
        \\solution to stdout as a new fumen, separated by newlines.
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
    const placements = try allocator.alloc(Placement, parsed.next.len + 1);
    defer allocator.free(placements);

    const solution = pc.findPc(
        FumenReader.FixedBag,
        allocator,
        gamestate,
        nn,
        0,
        placements,
    ) catch |err| blk: {
        if (err != pc.FindPcError.NoPcExists and err != pc.FindPcError.SolutionTooLong) {
            return err;
        }
        std.debug.print("Unable to solve: {}\n", .{err});
        break :blk null;
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
