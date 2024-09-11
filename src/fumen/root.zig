const std = @import("std");
const Allocator = std.mem.Allocator;

const kicks = @import("engine").kicks;

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
};

pub const FumenArgs = struct {
    append: bool = false,
    help: bool = false,
    kicks: Kicks = .srs,
    nn: ?[]const u8 = null,
    @"output-type": OutputMode = .view,

    pub const wrap_len: u32 = 40;

    pub const shorthands = .{
        .a = "append",
        .h = "help",
        .k = "kicks",
        .n = "nn",
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
            .nn = "The path to the neural network to use for the bot. If not provided, a default built-in network will be used.",
            .@"output-type" = std.fmt.comptimePrint(
                "The type of fumen to output. If append is true, this option is ignored. " ++
                    enumValuesHelp(FumenArgs, OutputMode) ++
                    " (default: {s})",
                .{@tagName((FumenArgs{}).@"output-type")},
            ),
        },
    };
};

// TODO: Implement fumen command
pub fn main(allocator: Allocator, args: FumenArgs, fumen: []const u8) !void {
    const parsed = try FumenReader.parse(allocator, fumen);
    defer parsed.deinit(allocator);

    const nn = try getNnOrDefault(allocator, args.nn);
    defer nn.deinit(allocator);

    const gamestate = parsed.toGameState(args.kicks.toEngine());
    std.debug.print("{}\n", .{gamestate});
}
