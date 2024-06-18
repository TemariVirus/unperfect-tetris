const std = @import("std");
const fs = std.fs;

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const PieceKind = engine.pieces.PieceKind;
const Player = engine.Player(SevenBag);
const SevenBag = engine.bags.SevenBag;

const nterm = @import("nterm");
const View = nterm.View;

const NEXT_LEN = 11;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    try nterm.init(
        allocator,
        std.io.getStdOut(),
        1,
        Player.DISPLAY_W + 2,
        Player.DISPLAY_H,
    );
    defer nterm.deinit();

    const player_view = View{
        .left = 1,
        .top = 0,
        .width = Player.DISPLAY_W,
        .height = Player.DISPLAY_H,
    };

    const file = try fs.cwd().openFile("pc-data/4.pc", .{});
    defer file.close();

    const reader = file.reader();

    while (try file.getPos() < try file.getEndPos()) {
        var player = Player.init(
            "reader",
            SevenBag.init(0),
            engine.kicks.srs,
            .{ .target_mode = .none },
            player_view,
            playSfxDummy,
        );

        const pack = try reader.readInt(u48, .little);
        const holds = try reader.readInt(u16, .little);

        var pieces = [_]PieceKind{undefined} ** NEXT_LEN;
        for (0..NEXT_LEN) |i| {
            pieces[i] = @enumFromInt(@as(u3, (@truncate(pack >> @intCast(3 * i)))));
        }
        player.state.hold_kind = pieces[0];
        player.state.current = engine.pieces.Piece{
            .facing = .up,
            .kind = pieces[1],
        };
        @memcpy(player.state.next_pieces[0..7], pieces[2..9]);
        player.state.bag.context.index = 0;
        @memcpy(player.state.bag.context.pieces[0..2], pieces[9..11]);

        for (0..NEXT_LEN - 1) |i| {
            const byte = try reader.readByte();

            if ((holds >> @intCast(i)) & 1 == 1) {
                player.hold();
            }
            const facing: engine.pieces.Facing = @enumFromInt(@as(u2, @truncate(byte)));
            player.state.current.facing = facing;

            const pos = byte >> 2;
            const x = pos % 10;
            const y = pos / 10;
            player.state.pos = player.state.current.fromCanonicalPosition(.{ .x = @intCast(x), .y = @intCast(y) });

            player.hardDrop(0, &.{});

            try player.draw();
            try nterm.render();

            var b = [2]u8{ 0, 0 };
            _ = try std.io.getStdIn().readAll(&b);
        }
    }
}

fn playSfxDummy(_: engine.player.Sfx) void {}
