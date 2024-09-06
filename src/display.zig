const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const File = std.fs.File;
const io = std.io;
const SolutionIndex = std.ArrayListUnmanaged(u64);

const engine = @import("engine");
const Facing = engine.pieces.Facing;
const Piece = engine.pieces.Piece;
const PieceKind = engine.pieces.PieceKind;
const Position = engine.pieces.Position;

const nterm = @import("nterm");
const Colors = nterm.Colors;
const View = nterm.View;

// Set max sequence length to 16 to handle up to 6-line PCs.
const MAX_SEQ_LEN = 16;
const INDEX_INTERVAL = 1 << 18;

pub fn main(allocator: Allocator, path: []const u8) !void {
    try nterm.init(
        allocator,
        io.getStdOut(),
        1,
        0,
        0,
        null,
        null,
    );
    defer nterm.deinit();

    const pc_file = try std.fs.cwd().openFile(path, .{});
    defer pc_file.close();
    const reader = pc_file.reader();

    var solution_count: ?u64 = null;
    const SOLUTION_MIN_SIZE = 8;
    var solution_index = try SolutionIndex.initCapacity(
        allocator,
        (try pc_file.getEndPos()) / SOLUTION_MIN_SIZE / INDEX_INTERVAL + 1,
    );
    defer solution_index.deinit(allocator);

    solution_index.appendAssumeCapacity(0);
    const index_thread = try std.Thread.spawn(
        .{ .allocator = allocator },
        indexThread,
        .{ path, &solution_count, &solution_index },
    );
    index_thread.detach();

    var i: u64 = 0;
    const stdin = io.getStdIn().reader();
    while (try pc_file.getPos() < try pc_file.getEndPos()) {
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
        matrix_box.drawBox(0, 0, matrix_box.height, matrix_box.width, Colors.WHITE, null);

        var row_occupancy = [_]u8{0} ** 20;
        const matrix_view = matrix_box.sub(
            1,
            1,
            matrix_box.width - 2,
            matrix_box.height - 2,
        );
        for (1..next_len) |j| {
            const placement = try reader.readByte();

            if ((holds >> @intCast(j - 1)) & 1 == 1) {
                std.mem.swap(PieceKind, &pieces[0], &pieces[j]);
            }
            const facing: Facing = @enumFromInt(@as(u2, @truncate(placement)));
            const piece = Piece{ .facing = facing, .kind = pieces[j] };

            const canon_pos = placement >> 2;
            const x = canon_pos % 10;
            const y = canon_pos / 10;
            const pos = piece.fromCanonicalPosition(.{ .x = @intCast(x), .y = @intCast(y) });

            drawMatrixPiece(matrix_view, &row_occupancy, piece, pos.x, pos.y);
        }

        printFooter(i, solution_count);
        nterm.render() catch |err| {
            // Trying to render after the terminal has been closed results
            // in an error, in which case stop the program gracefully.
            if (err == error.NotInitialized) {
                return;
            }
            return err;
        };

        // Read until enter is pressed
        const bytes = try stdin.readUntilDelimiterAlloc(
            allocator,
            '\n',
            std.math.maxInt(usize),
        );
        defer allocator.free(bytes);

        if (std.fmt.parseInt(u64, bytes[0 .. bytes.len - 1], 10)) |n| {
            if (try seekToSolution(pc_file, n, solution_index)) {
                i = n;
            }
        } else |_| {
            // Only go to next solution if the input is empty.
            if (bytes.len == 1) {
                i += 1;
            }
        }
    }
}

fn printFooter(pos: u64, end: ?u64) void {
    if (end) |e| {
        nterm.view().printAt(
            0,
            nterm.canvasSize().height - 1,
            Colors.WHITE,
            null,
            "Solution {} of {}",
            .{ pos, e },
        );
    } else {
        nterm.view().printAt(
            0,
            nterm.canvasSize().height - 1,
            Colors.WHITE,
            null,
            "Solution {} of ?",
            .{pos},
        );
    }
}

fn nextSolution(reader: anytype) u64 {
    const seq = reader.readInt(u48, .little) catch return 0;
    _ = reader.readInt(u16, .little) catch return 0;

    var next_len: usize = 0;
    while (next_len < MAX_SEQ_LEN) : (next_len += 1) {
        const p: u3 = @truncate(seq >> @intCast(3 * next_len));
        // 0b111 is the sentinel value for the end of the sequence.
        if (p == 0b111) {
            break;
        }
    }

    // Skip placement data
    reader.skipBytes(next_len - 1, .{
        .buf_size = MAX_SEQ_LEN,
    }) catch return 0;

    return 8 + next_len - 1;
}

// Get the index to the start of a solution at regular intervals.
// This greatly improves the performance of seeking to a solution.
// Due to the time needed to index the file, this is done in a separate thread.
fn indexThread(
    path: []const u8,
    solution_count: *?u64,
    solution_index: *SolutionIndex,
) !void {
    const pc_file = try std.fs.cwd().openFile(path, .{});
    defer pc_file.close();
    var bf = io.bufferedReader(pc_file.reader());
    const reader = bf.reader();

    var pos: u64 = 0;
    var count: u64 = 0;
    while (true) : (count += 1) {
        const len = nextSolution(reader);
        if (len == 0) {
            break;
        }

        if (count != 0 and count % INDEX_INTERVAL == 0) {
            solution_index.appendAssumeCapacity(pos);
        }

        pos += len;
    }

    solution_count.* = count;
}

fn seekToSolution(file: File, n: u64, solution_index: SolutionIndex) !bool {
    const old_pos = try file.getPos();
    try file.seekTo(0);

    var bf = io.bufferedReader(file.reader());
    const reader = bf.reader();

    const index = @min(solution_index.items.len - 1, n / INDEX_INTERVAL);
    var pos = solution_index.items[index];
    for (index * INDEX_INTERVAL..n) |_| {
        const len = nextSolution(reader);
        if (len == 0) {
            try file.seekTo(old_pos);
            return false;
        }
        pos += len;
    }

    try file.seekTo(pos);
    return true;
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
    box_view.drawBox(0, 0, box_view.width, box_view.height, Colors.WHITE, null);

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
