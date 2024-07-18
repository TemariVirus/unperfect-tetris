const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const json = std.json;

const root = @import("perfect-tetris");
const NN = root.NN;

const zig_args = @import("zig-args");

const NNInner = @import("zmai").genetic.neat.NN;

const nn_json = @embedFile("nn_json");

const Args = struct {
    pub const meta = .{
        .usage_summary = "[options] INPUT",
        .option_docs = .{},
    };
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const args = try zig_args.parseForCurrentProcess(Args, allocator, .silent);
    defer args.deinit();

    const nn = try getNn(allocator);
    defer nn.deinit(allocator);
    std.debug.print("{s}\n", .{args.positionals});
    try zig_args.printHelp(Args, "perfect-tetris", std.io.getStdOut().writer());
}

fn getNn(allocator: Allocator) !NN {
    const obj = try json.parseFromSlice(NNInner.NNJson, allocator, nn_json, .{
        .ignore_unknown_fields = true,
    });
    defer obj.deinit();

    var inputs_used: [NN.INPUT_SIZE]bool = undefined;
    const _nn = try NNInner.fromJson(allocator, obj.value, &inputs_used);
    return NN{
        .net = _nn,
        .inputs_used = inputs_used,
    };
}
