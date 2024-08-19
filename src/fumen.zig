const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const json = std.json;

const root = @import("perfect-tetris");
const NN = root.NN;

const NNInner = @import("zmai").genetic.neat.NN;

const nn_json = @embedFile("nn_json");

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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

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
