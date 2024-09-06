const std = @import("std");

const engine = @import("engine");
const kicks = engine.kicks;

const zig_args = @import("zig-args");

const root = @import("perfect-tetris");
const demo = @import("demo.zig");
const display = @import("display.zig");
const validate = @import("validate.zig");

const Args = struct {
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
    };

    pub const meta = .{
        .usage_summary = "COMMAND [options] [INPUT]",
        .full_text =
        \\Blazingly fast Tetris perfect clear solver.
        \\
        \\Commands:
        \\  demo         Demostrates the perfect clear solver's speed with a tetris playing bot.
        \\  display      Displays the perfect clear solutions saved at PATH.
        \\  fumen        Produces a perfect clear solution for each input fumen.
        \\  validate     Validates the perfect clear solutions saved at PATHS.
        ,
        .option_docs = .{
            .help = "Print this help message.",
        },
    };
};

const VerbType = enum {
    demo,
    display,
    fumen,
    validate,
};

const Verb = union(VerbType) {
    demo: DemoArgs,
    display: DisplayArgs,
    fumen: FumenArgs,
    validate: ValidateArgs,
};

const DemoArgs = struct {
    help: bool = false,
    nn: ?[]const u8 = null,
    pps: u32 = 10,

    pub const wrap_len: u32 = 50;

    pub const shorthands = .{
        .h = "help",
        .n = "nn",
        .p = "pps",
    };

    pub const meta = .{
        .usage_summary = "demo [options]",
        .full_text = "Demostrates the perfect clear solver's speed with a tetris playing bot.",
        .option_docs = .{
            .help = "Print this help message.",
            .nn = "The path to the neural network to use for the bot. If not provided, a default built-in network will be used.",
            .pps = "The target pieces per second of the bot. (default: 10)",
        },
    };
};

const DisplayArgs = struct {
    help: bool = false,

    pub const wrap_len: u32 = 50;

    pub const shorthands = .{
        .h = "help",
    };

    pub const meta = .{
        .usage_summary = "display [options] PATH",
        .full_text = "Displays the perfect clear solutions saved at PATH. Press `enter` to display the next solution.",
        .option_docs = .{
            .help = "Print this help message.",
        },
    };
};

const Kicks = enum {
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

const OutputMode = enum {
    edit,
    list,
    view,
};

const FumenArgs = struct {
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
        .full_text = "Produces a perfect clear solution for each input fumen. Outputs each solution as a new fumen, separated by newlines.",
        .option_docs = .{
            .append = "Append solution frames to input fumen instead of making a new fumen from scratch.",
            .help = "Print this help message.",
            // TODO
            // For kick systems that have a
            // 180-less and 180 variant, the 180-less variant has no 180
            // rotations. The 180 variant has 180 rotations but no 180 kicks.
            // Kick systems
            .kicks = "Permitted kick/rotation system. " ++
                enumValuesHelp(FumenArgs, Kicks) ++
                " (default: srs)",
            .@"output-type" = "The type of fumen to output. If append is true, this option is ignored. " ++
                enumValuesHelp(FumenArgs, OutputMode) ++
                " (default: view)",
        },
    };
};

const ValidateArgs = struct {
    help: bool = false,

    pub const wrap_len: u32 = 50;

    pub const shorthands = .{
        .h = "help",
    };

    pub const meta = .{
        .usage_summary = "validate [options] PATHS...",
        .full_text = "Validates the perfect clear solutions saved at PATHS. This will validate that PATHS are valid .pc files and that all solutions are valid perfect clear solutions.",
        .option_docs = .{
            .help = "Print this help message.",
        },
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exe_args = zig_args.parseWithVerbForCurrentProcess(
        Args,
        Verb,
        allocator,
        .print,
    ) catch |e| {
        return e;
    };
    defer exe_args.deinit();

    const exe_name = std.fs.path.stem(exe_args.executable_name.?);
    const verb = exe_args.verb orelse {
        try zig_args.printHelp(Args, exe_name, stdout);
        return;
    };

    // help flag get consumed by global options, so use that instead. Verb-specific
    // help flags only exist for the help message.
    switch (verb) {
        .demo => |args| {
            if (exe_args.options.help) {
                try zig_args.printHelp(DemoArgs, exe_name, stdout);
                return;
            }

            if (args.pps == 0) {
                try stderr.print("PPS option must be greater than 0\n", .{});
                return;
            }
            try demo.main(allocator, args.nn, args.pps);
        },
        .display => |_| {
            if (exe_args.options.help or exe_args.positionals.len == 0) {
                try zig_args.printHelp(DisplayArgs, exe_name, stdout);
                return;
            }

            try display.main(allocator, exe_args.positionals[0]);
        },
        .fumen => |args| {
            _ = args; // autofix
            if (exe_args.options.help or exe_args.positionals.len == 0) {
                try zig_args.printHelp(FumenArgs, exe_name, stdout);
                return;
            }

            // for (exe_args.positionals) |path| {
            // }
        },
        .validate => |_| {
            if (exe_args.options.help or exe_args.positionals.len == 0) {
                try zig_args.printHelp(ValidateArgs, exe_name, stdout);
                return;
            }

            for (exe_args.positionals) |path| {
                try validate.main(path);
            }
        },
    }
}

fn enumValuesHelp(ArgsT: type, Enum: type) []const u8 {
    const max_option_len = blk: {
        var max_option_len = 0;
        for (@typeInfo(ArgsT).Struct.fields) |field| {
            max_option_len = @max(max_option_len, field.name.len);
        }
        break :blk max_option_len;
    };

    const total_len = blk: {
        var total_len = max_option_len + 13 + "Supported Values:\n".len;
        for (@typeInfo(Enum).Enum.fields) |field| {
            total_len += max_option_len + 15 + field.name.len + 1;
        }
        break :blk total_len;
    };

    var buf: [total_len]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var str = std.ArrayList(u8).initCapacity(allocator, total_len) catch unreachable;
    const writer = str.writer();

    writer.writeAll("Supported Values: [") catch unreachable;
    for (@typeInfo(Enum).Enum.fields, 0..) |field, i| {
        writer.writeAll(field.name) catch unreachable;
        if (i < @typeInfo(Enum).Enum.fields.len - 1) {
            writer.writeByte(',') catch unreachable;
        }
    }
    writer.writeByte(']') catch unreachable;

    return str.items;
}
