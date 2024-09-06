const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const json = std.json;

const root = @import("perfect-tetris");
const NN = root.NN;

const enumValuesHelp = @import("main.zig").enumValuesHelp;

const kicks = @import("engine").kicks;

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

const FumenReader = struct {
    pub const InitError = error{
        UnsupportedFumenVersion,
    };
    pub const PollError = error{
        EndOfData,
    };

    const encode_table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const decode_table = blk: {
        var table = [_]u7{64} ** 256;

        for (encode_table, 0..) |char, i| {
            table[char] = i;
        }

        break :blk table;
    };

    data: []const u8,
    pos: usize = 0,

    pub fn init(fumen: []const u8) InitError!FumenReader {
        // Only version 1.15 is supported
        const start = std.mem.indexOf(u8, fumen, "115@") orelse
            return InitError.UnsupportedFumenVersion;
        // fumen may be a url, remove addons (which come after a '#')
        const end = std.mem.indexOfScalar(u8, fumen, '#') orelse fumen.len;
        return .{
            // + 4 to skip the "115@" prefix
            .data = fumen[start + 4 .. end],
        };
    }

    pub fn poll(self: *FumenReader, n: usize) PollError!u32 {
        assert(n <= 5);

        var result: u32 = 0;
        for (0..n) |i| {
            result += try self.pollOne() << @intCast(6 * i);
        }
        return result;
    }

    fn pollOne(self: *FumenReader) PollError!u32 {
        // Read until next valid character
        while (self.pos < self.data.len) : (self.pos += 1) {
            if (decode_table[self.data[self.pos]] < 64) {
                break;
            }
        } else {
            return PollError.EndOfData;
        }

        defer self.pos += 1;
        return decode_table[self.data[self.pos]];
    }
};

// TODO: Implement fumen command
pub fn main(allocator: Allocator, args: FumenArgs, fumen: []const u8) !void {
    _ = args; // autofix
    _ = fumen; // autofix

    // Solving step
    const nn = try getNn(allocator);
    defer nn.deinit(allocator);

    // var d = try FumenReader.init(args.positionals[0]);
    // while (true) {
    //     std.debug.print("{}\n", .{d.poll(1) catch break});
    // }
}

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
