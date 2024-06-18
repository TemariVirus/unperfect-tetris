const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const AtomicInt = std.atomic.Value(i32);
const fs = std.fs;
const Mutex = Thread.Mutex;
const os = std.os;
const SIG = os.linux.SIG;
const Thread = std.Thread;
const Timer = std.time.Timer;

const engine = @import("engine");
const GameState = engine.GameState(SevenBag);
const PieceKind = engine.pieces.PieceKind;
const SevenBag = engine.bags.SevenBag;

const root = @import("root.zig");
const SequenceIterator = root.next.SequenceIterator;
const NN = root.NN;
const pc = root.pc;
const Placement = root.Placement;

const HEIGHT = 4;
const NEXT_LEN = HEIGHT * 5 / 2;
const THREADS = 6;

const SAVE_DIR = "pc-data/";
const PC_PATH = SAVE_DIR ++ "4.pc";
const COUNT_PATH = SAVE_DIR ++ "4.count";

var saving_threads = AtomicInt.init(0);

/// Thread-safe ring buffer for storing and writing solutions to disk.
const SolutionBuffer = struct {
    const CHUNK_SIZE = 64;
    const CHUNKS = THREADS * 4;
    pub const Iterator = SequenceIterator(NEXT_LEN + 1, @min(7, NEXT_LEN));
    pub const AtomicLength = std.atomic.Value(isize);

    mutex: Mutex = .{},
    solved: u64 = 0,
    count: u64 = 0,
    new_count: u64 = 0,
    timer: Timer,
    iter: Iterator,

    write_ptr: usize = 0,
    read_ptr: usize = 0,
    lengths: [CHUNKS]AtomicLength = [_]AtomicLength{AtomicLength.init(-1)} ** CHUNKS,
    sequences: [CHUNKS][CHUNK_SIZE]u48,
    solutions: [CHUNKS][CHUNK_SIZE][NEXT_LEN]Placement,

    pub fn init(allocator: Allocator) !SolutionBuffer {
        return .{
            .timer = try Timer.start(),
            .iter = Iterator.init(allocator),
            .sequences = undefined,
            .solutions = undefined,
        };
    }

    pub fn loadOrInit(allocator: Allocator, pc_path: []const u8, count_path: []const u8) !SolutionBuffer {
        var self = try init(allocator);

        // Get # of solves
        blk: {
            const file = fs.cwd().openFile(pc_path, .{}) catch |e| {
                if (e != fs.File.OpenError.FileNotFound) {
                    return e;
                }
                break :blk;
            };
            const stat = try file.stat();
            const SOLUTION_SIZE = 8 + NEXT_LEN;
            self.solved = @divExact(stat.size, SOLUTION_SIZE);
        }

        const file = fs.cwd().openFile(count_path, .{}) catch |e| {
            if (e != fs.File.OpenError.FileNotFound) {
                return e;
            }
            return self;
        };
        defer file.close();

        const max_len = comptime std.math.log10_int(@as(u64, std.math.maxInt(u64))) + 1;
        var buf = [_]u8{undefined} ** max_len;
        const len = try file.readAll(&buf);

        self.count = try std.fmt.parseInt(u64, buf[0..len], 10);
        for (0..self.count) |_| {
            _ = try self.iter.next();
        }

        return self;
    }

    pub fn deinit(self: *SolutionBuffer) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.iter.deinit();
    }

    fn mask(index: usize) usize {
        return index % CHUNKS;
    }

    fn mask2(index: usize) usize {
        return index % (2 * CHUNKS);
    }

    pub fn nextChunk(
        self: *SolutionBuffer,
    ) !?struct { *AtomicLength, []u48, [][NEXT_LEN]Placement } {
        // Wait for space to become available
        while (true) {
            self.mutex.lock();
            if (!self.isFull()) {
                break;
            }

            self.mutex.unlock();
            std.debug.print(
                "INFO: solution buffer is full. Consider increasing the number of chunks or the chunk size\n",
                .{},
            );
            std.time.sleep(std.time.ns_per_s);
        }
        defer self.mutex.unlock();

        if (self.iter.done()) {
            return null;
        }

        const index = mask(self.write_ptr);

        self.lengths[index].store(-1, .monotonic);

        var len: usize = 0;
        while (try self.iter.next()) |pieces| {
            self.sequences[index][len] = packSequence(&pieces);
            len += 1;
            if (len >= CHUNK_SIZE) {
                break;
            }
        }

        self.write_ptr = mask2(self.write_ptr + 1);
        return .{
            &self.lengths[index],
            self.sequences[index][0..len],
            self.solutions[index][0..len],
        };
    }

    pub fn writeDoneChunks(
        self: *SolutionBuffer,
        pc_path: []const u8,
        count_path: []const u8,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var wrote = false;
        while (!self.isEmpty() and self.lengths[mask(self.read_ptr)].load(.monotonic) >= 0) {
            const len: usize = @intCast(self.lengths[mask(self.read_ptr)].load(.monotonic));
            self.solved += len;
            self.new_count += CHUNK_SIZE;
            try saveAppend(
                pc_path,
                count_path,
                self.count + self.new_count,
                self.sequences[mask(self.read_ptr)][0..len],
                NEXT_LEN,
                self.solutions[mask(self.read_ptr)][0..len],
            );

            wrote = true;
            self.read_ptr = mask2(self.read_ptr + 1);
        }

        if (wrote) {
            std.debug.print(
                "Solved {} out of {}\n",
                .{ self.solved, self.count + self.new_count },
            );
            if (self.new_count >= THREADS * 256) {
                std.debug.print(
                    "Time per solve: {}\n\n",
                    .{std.fmt.fmtDuration(self.timer.lap() / self.new_count)},
                );
                self.count += self.new_count;
                self.new_count = 0;
            }
        }
    }

    fn isEmpty(self: SolutionBuffer) bool {
        return self.write_ptr == self.read_ptr;
    }

    fn isFull(self: SolutionBuffer) bool {
        return mask2(self.write_ptr + CHUNKS) == self.read_ptr;
    }
};

pub fn main() !void {
    setupExitHandler();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var buf = try SolutionBuffer.loadOrInit(allocator, PC_PATH, COUNT_PATH);
    defer buf.deinit();

    var threads = [_]Thread{undefined} ** THREADS;
    for (0..threads.len) |i| {
        threads[i] = try Thread.spawn(
            .{ .allocator = allocator },
            solveThread,
            .{&buf},
        );
    }
    for (threads) |thread| {
        thread.join();
    }
}

const handle_signals = [_]c_int{ SIG.ABRT, SIG.INT, SIG.QUIT, SIG.STOP, SIG.TERM };
fn setupExitHandler() void {
    if (@import("builtin").os.tag == .windows) {
        const signal = struct {
            extern "c" fn signal(
                sig: c_int,
                func: *const fn (c_int, c_int) callconv(os.windows.WINAPI) void,
            ) callconv(.C) *anyopaque;
        }.signal;
        for (handle_signals) |sig| {
            _ = signal(sig, handleExitWindows);
        }
    } else {
        const action = os.linux.Sigaction{
            .handler = .{ .handler = handleExit },
            .mask = os.linux.empty_sigset,
            .flags = 0,
        };
        for (handle_signals) |sig| {
            _ = os.linux.sigaction(sig, &action, null);
        }
    }
}

fn handleExit(sig: c_int) callconv(.C) void {
    if (std.mem.containsAtLeast(c_int, &handle_signals, 1, &.{sig})) {
        // Set to -1 to signal saves to stop and wait for saves to finish
        const saving_count = saving_threads.swap(-1, .monotonic);
        while (saving_threads.load(.monotonic) >= -saving_count) {
            std.time.sleep(std.time.ns_per_ms);
        }
        std.process.exit(0);
    }
}

fn handleExitWindows(sig: c_int, _: c_int) callconv(.C) void {
    handleExit(sig);
}

fn solveThread(buf: *SolutionBuffer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const nn = try NN.load(allocator, "NNs/Fast2.json");
    defer nn.deinit(allocator);

    while (try buf.nextChunk()) |tuple| {
        const sol_count, const sequences, const solutions = tuple;

        var solved: usize = 0;
        for (sequences) |seq| {
            _ = pc.findPc(
                allocator,
                gameWithPieces(&unpackSequence(seq, NEXT_LEN + 1)),
                nn,
                HEIGHT,
                &solutions[solved],
            ) catch |e| if (e == pc.FindPcError.SolutionTooLong) {
                continue;
            } else {
                return e;
            };

            sequences[solved] = seq;
            solved += 1;
        }

        sol_count.store(@intCast(solved), .monotonic);
        try buf.writeDoneChunks(PC_PATH, COUNT_PATH);
    }
}

fn packSequence(pieces: []const PieceKind) u48 {
    assert(pieces.len <= 48 / 3);

    var seq: u48 = 0;
    for (pieces, 0..) |piece, i| {
        seq |= @as(u48, @intFromEnum(piece)) << @intCast(3 * i);
    }
    // Fill remaining bits with 1s
    seq |= ~@as(u48, 0) << @intCast(3 * pieces.len);
    return seq;
}

fn unpackSequence(seq: u48, comptime len: usize) [len]PieceKind {
    var pieces = [_]PieceKind{undefined} ** len;
    for (0..pieces.len) |i| {
        pieces[i] = @enumFromInt(@as(u3, @truncate(seq >> @intCast(3 * i))));
    }
    return pieces;
}

fn saveAppend(
    pc_path: []const u8,
    count_path: []const u8,
    count: u64,
    sequences: []const u48,
    comptime solution_len: usize,
    solutions: []const [solution_len]Placement,
) !void {
    assert(solution_len <= 16);
    assert(sequences.len == solutions.len);

    // Multiple threads can save at the same time, but no threads should start
    // saving when we are exiting
    if (saving_threads.load(.monotonic) < 0) {
        return;
    }

    _ = saving_threads.fetchAdd(1, .monotonic);
    defer _ = saving_threads.fetchSub(1, .monotonic);

    // Write PC solutions
    {
        const file = fs.cwd().openFile(
            pc_path,
            .{ .mode = .write_only },
        ) catch |e| blk: {
            // Create file if it doesn't exist
            if (e != fs.File.OpenError.FileNotFound) {
                return e;
            }
            try fs.cwd().makePath(std.fs.path.dirname(pc_path) orelse return error.InvalidPath);
            break :blk try fs.cwd().createFile(pc_path, .{});
        };
        defer file.close();

        // Seek to end to append to file
        try file.seekFromEnd(0);
        var buf_writer = std.io.bufferedWriter(file.writer());
        const writer = buf_writer.writer();

        for (sequences, solutions) |seq, sol| {
            var holds: u16 = 0;
            var placements = [_]u8{0} ** solution_len;

            var hold: PieceKind = @enumFromInt(@as(u3, @truncate(seq)));
            var current: PieceKind = @enumFromInt(@as(u3, @truncate(seq >> 3)));
            for (sol, 0..) |placement, i| {
                const canon_pos = placement.piece.canonicalPosition(placement.pos);
                const pos = canon_pos.y * 10 + canon_pos.x;
                assert(pos < 60);
                placements[i] = @intFromEnum(placement.piece.facing) | (@as(u8, pos) << 2);

                if (current != placement.piece.kind) {
                    holds |= @as(u16, 1) << @intCast(i);
                    hold = current;
                }
                // Only update current if it's not the last piece
                if (i < sol.len - 1) {
                    current = @enumFromInt(@as(u3, @truncate(seq >> @intCast(3 * i + 6))));
                }
            }

            try writer.writeInt(u48, seq, .little);
            try writer.writeInt(u16, holds, .little);
            try writer.writeAll(&placements);
        }
        try buf_writer.flush();
    }

    // Write new count
    {
        try fs.cwd().makePath(std.fs.path.dirname(pc_path) orelse return error.InvalidPath);
        const file = try fs.cwd().createFile(count_path, .{});
        defer file.close();

        try file.writer().print("{}", .{count});
    }
}

fn gameWithPieces(pieces: []const PieceKind) GameState {
    var game = GameState.init(SevenBag.init(0), engine.kicks.srs);
    game.hold_kind = pieces[0];
    game.current.kind = pieces[1];

    for (0..@min(pieces.len - 2, game.next_pieces.len)) |i| {
        game.next_pieces[i] = pieces[i + 2];
    }
    game.bag.context.index = 0;
    for (0..pieces.len -| 9) |i| {
        game.bag.context.pieces[i] = pieces[i + 9];
    }

    return game;
}
