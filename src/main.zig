const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

const demo = @import("demo.zig");
const DemoArgs = demo.DemoArgs;
const display = @import("display.zig");
const DisplayArgs = display.DisplayArgs;
const fumen = @import("fumen/root.zig");
const FumenArgs = fumen.FumenArgs;
const validate = @import("validate.zig");
const ValidateArgs = validate.ValidateArgs;

const NN = @import("perfect-tetris").NN;
const NNInner = @import("zmai").genetic.neat.NN;

const zig_args = @import("zig-args");
const Error = zig_args.Error;

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
        \\  demo         Demostrates the solver's speed with a tetris playing bot.
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const exe_args = try zig_args.parseWithVerbForCurrentProcess(
        Args,
        Verb,
        allocator,
        .{ .forward = handleArgsError },
    );
    defer exe_args.deinit();

    const exe_name = std.fs.path.stem(exe_args.executable_name.?);
    const verb = exe_args.verb orelse {
        try zig_args.printHelp(Args, exe_name, stdout);
        return;
    };

    // Help flag gets consumed by global options, so use that instead.
    // Verb-specific help flags only exist for the help message.
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
            try demo.main(allocator, args);
        },
        .display => |args| {
            if (exe_args.options.help or exe_args.positionals.len == 0) {
                try zig_args.printHelp(DisplayArgs, exe_name, stdout);
                return;
            }

            try display.main(allocator, args, exe_args.positionals[0]);
        },
        .fumen => |args| {
            if (exe_args.options.help or exe_args.positionals.len == 0) {
                try zig_args.printHelp(FumenArgs, exe_name, stdout);
                return;
            }

            const nn = try getNnOrDefault(allocator, args.nn);
            defer nn.deinit(allocator);

            for (exe_args.positionals) |fumen_str| {
                try fumen.main(
                    allocator,
                    args,
                    fumen_str,
                    nn,
                    std.io.getStdOut(),
                );
            }
        },
        .validate => |args| {
            if (exe_args.options.help or exe_args.positionals.len == 0) {
                try zig_args.printHelp(ValidateArgs, exe_name, stdout);
                return;
            }

            for (exe_args.positionals) |path| {
                try validate.main(args, path);
            }
        },
    }
}

fn handleArgsError(err: Error) !void {
    try std.io.getStdErr().writer().print("{}\n", .{err});
    std.process.exit(1);
}

pub fn enumValuesHelp(ArgsT: type, Enum: type) []const u8 {
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

pub fn getNnOrDefault(allocator: Allocator, nn_path: ?[]const u8) !NN {
    if (nn_path) |path| {
        return try NN.load(allocator, path);
    }

    // Use embedded neural network as default
    const obj = try json.parseFromSlice(NNInner.NNJson, allocator, @embedFile("nn_json"), .{
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
