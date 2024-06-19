const std = @import("std");
const assert = std.debug.assert;

const engine = @import("engine");
const Facing = engine.pieces.Facing;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Position = engine.pieces.Position;

const nterm = @import("nterm");
const View = nterm.View;

// Set max sequence length to 16 to handle up to 6-line PCs.
const MAX_SEQ_LEN = 16;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(allocator);
    _ = args.skip(); // Skip executable name
    defer args.deinit();

    const pc_path = args.next() orelse {
        std.debug.print("Please enter a file path", .{});
        return;
    };

    try nterm.init(
        allocator,
        std.io.getStdOut(),
        1,
        0,
        0,
    );
    defer nterm.deinit();

    const file = try std.fs.cwd().openFile(pc_path, .{});
    defer file.close();

    const reader = file.reader();
    while (try file.getPos() < try file.getEndPos()) {
        const pack = try reader.readInt(u48, .little);
        const holds = try reader.readInt(u16, .little);

        var pieces = [_]PieceKind{undefined} ** MAX_SEQ_LEN;
        var next_len: usize = 0;
        while (next_len < MAX_SEQ_LEN) : (next_len += 1) {
            const p: u3 = @truncate(pack >> @intCast(3 * next_len));
            // 0b111 is the sentinel value for the end of the sequence.
            if (p == 0b111) {
                break;
            }
            pieces[next_len] = @enumFromInt(p);
        }
        assert(next_len > 0);

        try nterm.setCanvasSize(
            (11 + 5) * 2 + 1,
            @intCast(@max(22, next_len * 3 + 2)),
        );
        drawSequence(pieces[0..next_len]);

        const matrix_box = View{
            .left = 0,
            .top = nterm.canvasSize().height - 22,
            .width = 10 * 2 + 2,
            .height = 22,
        };
        matrix_box.drawBox(0, 0, matrix_box.height, matrix_box.width);

        var row_occupancy = [_]u8{0} ** 20;
        const matrix_view = matrix_box.sub(
            1,
            1,
            matrix_box.width - 2,
            matrix_box.height - 2,
        );
        for (1..next_len) |i| {
            const placement = try reader.readByte();

            if ((holds >> @intCast(i - 1)) & 1 == 1) {
                std.mem.swap(PieceKind, &pieces[0], &pieces[i]);
            }
            const facing: Facing = @enumFromInt(@as(u2, @truncate(placement)));
            const piece = Piece{ .facing = facing, .kind = pieces[i] };

            const canon_pos = placement >> 2;
            const x = canon_pos % 10;
            const y = canon_pos / 10;
            const pos = piece.fromCanonicalPosition(.{ .x = @intCast(x), .y = @intCast(y) });

            drawMatrixPiece(matrix_view, &row_occupancy, piece, pos.x, pos.y);
        }

        try nterm.render();
        // Pressing and releasing 'enter' generates 2 bytes to read.
        var b = [2]u8{ 0, 0 };
        _ = try std.io.getStdIn().readAll(&b);
    }
}

/// Get the positions of the minos of a piece relative to the bottom left corner.
fn getMinos(piece: Piece) [4]Position {
    const mask = piece.mask().rows;
    var minos: [4]Position = undefined;
    var i: usize = 0;

    // Make sure minos are sorted highest first
    var y: i8 = 3;
    while (y >= 0) : (y -= 1) {
        for (0..10) |x| {
            if ((mask[@intCast(y)] >> @intCast(10 - x)) & 1 == 1) {
                minos[i] = .{ .x = @intCast(x), .y = y };
                i += 1;
            }
        }
    }
    assert(i == 4);

    return minos;
}

fn drawSequence(pieces: []const PieceKind) void {
    assert(pieces.len <= MAX_SEQ_LEN);

    const WIDTH = 2 * 4 + 2;
    const box_view = View{
        .left = nterm.canvasSize().width - WIDTH,
        .top = 0,
        .width = WIDTH,
        .height = @intCast(pieces.len * 3 + 2),
    };
    box_view.drawBox(0, 0, box_view.width, box_view.height);

    const box = box_view.sub(1, 1, box_view.width - 2, box_view.height - 2);
    for (pieces, 0..) |p, i| {
        const piece = Piece{ .facing = .up, .kind = p };
        drawPiece(box, piece, 0, @intCast(i * 3));
    }
}

fn drawPiece(view: View, piece: Piece, x: i8, y: i8) void {
    const minos = getMinos(piece);
    const color = piece.kind.color();
    for (minos) |mino| {
        const mino_x = x + mino.x;
        // The y coordinate is flipped when converting to nterm coordinates.
        const mino_y = y + (3 - mino.y);
        _ = view.writeText(
            @intCast(mino_x * 2),
            @intCast(mino_y),
            color,
            color,
            "  ",
        );
    }
}

/// Draw a piece in the matrix view, and update the row occupancy.
fn drawMatrixPiece(view: View, row_occupancy: []u8, piece: Piece, x: i8, y: i8) void {
    const minos = getMinos(piece);
    const color = piece.kind.color();
    for (minos) |mino| {
        const cleared = blk: {
            var cleared: i8 = 0;
            var top = y + mino.y;
            var i: usize = 0;
            // Any clears below the mino will push it up.
            while (i <= top) : (i += 1) {
                if (row_occupancy[i] >= 10) {
                    cleared += 1;
                    top += 1;
                }
            }
            break :blk cleared;
        };

        const mino_x = x + mino.x;
        // The y coordinate is flipped when converting to nterm coordinates.
        const mino_y = 19 - y - mino.y - cleared;
        _ = view.writeText(
            @intCast(mino_x * 2),
            @intCast(mino_y),
            color,
            color,
            "  ",
        );

        row_occupancy[@intCast(19 - mino_y)] += 1;
    }
}
