const std = @import("std");
const assert = std.debug.assert;

const engine = @import("engine");
const Bag = engine.bags.NoBag;
const Facing = engine.pieces.Facing;
const GameState = engine.GameState(Bag);
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;

// TODO: optionally validate all sequences exist?
const MAX_SEQ_LEN = 16;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.skip(); // Skip executable name
    defer args.deinit();

    const file_path = args.next() orelse {
        std.debug.print("Please enter a file path", .{});
        return;
    };
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var solution_count: u64 = 0;
    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();
    while (try file.getPos() < try file.getEndPos()) {
        const seq = try reader.readInt(u48, .little);
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
        assert(next_len > 0);

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
                return error.InvalidSolution;
            }
        }

        solution_count += 1;
    }

    std.debug.print("Verified {} solutions. All solutions ok.\n", .{solution_count});
}
