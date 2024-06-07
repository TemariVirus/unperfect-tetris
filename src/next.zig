const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const PieceKind = @import("engine").pieces.PieceKind;

const MAX_BAG_LEN = 7;
const BagLenInt = std.math.Log2IntCeil(@Type(.{ .Int = .{
    .bits = MAX_BAG_LEN,
    .signedness = .unsigned,
} }));

/// Stores an immutable array of integers (std.PackedIntArray but with a single
/// backing integer).
pub fn PieceArray(comptime len: usize) type {
    assert(len > 0);
    assert(len <= 64 / 3);
    assert(@bitSizeOf(PieceKind) == 3);
    return struct {
        pub const item_size = @bitSizeOf(u3);
        pub const bits = item_size * len;
        pub const mask = @as(u64, (1 << bits) - 1);
        pub const item_mask = @as(u64, (1 << item_size) - 1);

        // There is one extra bit that may be used too indicate nullity but
        // doing so shows no visible performance improvement.
        items: u64,
        comptime len: usize = len,

        pub fn init(items: u64) @This() {
            assert(mask & items == items);
            return .{ .items = items };
        }

        pub fn get(self: @This(), index: usize) u3 {
            assert(index < self.len);
            return @truncate(item_mask & (self.items >> @intCast(index * item_size)));
        }

        pub fn set(self: @This(), index: usize, value: u3) @This() {
            assert(index < self.len);
            // Mask is not needed at the end as all out of bounds bits are already 0
            assert(~mask & self.items == 0);
            return .{
                .items = self.items &
                    // Write 0 at index
                    ~(item_mask << @intCast(index * item_size)) |
                    // Write value at index
                    (@as(u64, value) << @intCast(index * item_size)),
            };
        }

        pub fn shiftLeft(self: @This(), shift: usize) @This() {
            assert(shift <= self.len);
            return .{ .items = mask & (self.items << @intCast(shift * item_size)) };
        }

        pub fn shiftRight(self: @This(), shift: usize) @This() {
            assert(shift <= self.len);
            // Mask is not needed at the end as all out of bounds bits are already 0
            assert(~mask & self.items == 0);
            return .{ .items = self.items >> @intCast(shift * item_size) };
        }
    };
}

/// Iterates through all possible sequences of next pieces of length `len` assuming
/// a 7-bag randomiser. Due to the possibility of partial bags, this iterator often
/// produces duplicate sequences.
pub fn NextIterator(comptime len: usize, comptime lock_len: usize) type {
    assert(len > 1);
    assert(len >= lock_len);
    return struct {
        pub const n_bags = (len - 2) / MAX_BAG_LEN + 2;
        pub const NextArray = PieceArray(len);

        /// Iterates through a truncated 7-bag of length `size`.
        pub const BagIterator = struct {
            frees: [MAX_BAG_LEN]u7,
            iters: [MAX_BAG_LEN]u7,

            pub fn init(size: BagLenInt, locks: []const u3) @This() {
                assert(size > 0 and size <= MAX_BAG_LEN);
                var frees = [_]u7{undefined} ** MAX_BAG_LEN;
                frees[0] = std.math.maxInt(u7);
                var iters = [_]u7{undefined} ** MAX_BAG_LEN;
                iters[0] = if (0 < locks.len) @as(u7, 1) << locks[0] else frees[0];
                for (1..size) |i| {
                    const active_bit = iters[i - 1] & (~iters[i - 1] +% 1);
                    frees[i] = frees[i - 1] ^ active_bit;
                    iters[i] = if (i < locks.len) @as(u7, 1) << locks[i] else frees[i];
                }
                // If locks are impossible to satisfy, return an empty iterator
                if (@popCount(frees[size - 1] ^ (iters[size - 1] & (~iters[size - 1] +% 1))) !=
                    7 - @as(u8, size))
                {
                    iters[0] = 0;
                }
                return .{ .frees = frees, .iters = iters };
            }

            pub fn next(
                self: *@This(),
                pieces: NextArray,
                offset: usize,
                size: BagLenInt,
            ) ?NextArray {
                if (self.iters[0] == 0) {
                    return null;
                }

                var p = pieces.shiftRight(offset);
                for (0..size) |i| {
                    p = p.set(i, @ctz(self.iters[i]));
                }
                p = p.shiftLeft(offset);
                const lower = pieces.items & ~(NextArray.mask << @intCast(offset * 3));
                p = NextArray.init(p.items | lower);

                var i = size - 1;
                self.iters[i] &= self.iters[i] - 1;
                while (i > 0) : (i -= 1) {
                    if (self.iters[i] != 0) {
                        break;
                    }
                    self.iters[i - 1] &= self.iters[i - 1] - 1;
                } else if (self.iters[0] == 0) {
                    return p;
                }

                while (i < size - 1) : (i += 1) {
                    // Select least significant bit
                    const active_bit = self.iters[i] & (~self.iters[i] +% 1);
                    self.frees[i + 1] = self.frees[i] ^ active_bit;
                    self.iters[i + 1] = self.frees[i + 1];
                }

                return p;
            }
        };

        // Can be reduced to a single int but the logic becomes more complicated.
        sizes: [n_bags]BagLenInt,
        bags: [n_bags]BagIterator,
        locks: [lock_len]u3,
        pieces: NextArray,

        pub fn init(locks: [lock_len]u3) @This() {
            var left = len;
            var sizes = [_]BagLenInt{undefined} ** n_bags;
            for (0..n_bags) |i| {
                sizes[i] = @min(left, MAX_BAG_LEN);
                left -= sizes[i];
            }

            var bags = [_]BagIterator{undefined} ** n_bags;
            var start: usize = len;
            var pieces = NextArray.init(0);

            outer: while (!done(sizes)) {
                for (0..n_bags) |i| {
                    if (sizes[i] == 0) {
                        break;
                    }
                    start -= sizes[i];
                    bags[i] = BagIterator.init(
                        sizes[i],
                        locks[@min(lock_len, start)..@min(lock_len, start + sizes[i])],
                    );
                    if (i == 0) {
                        continue;
                    }

                    if (bags[i].next(pieces, start, sizes[i])) |p| {
                        pieces = p;
                    } else {
                        nextSize(&sizes);
                        start = len;
                        continue :outer;
                    }
                }
                break;
            }

            return .{
                .sizes = sizes,
                .bags = bags,
                .locks = locks,
                .pieces = pieces,
            };
        }

        fn done(sizes: [n_bags]BagLenInt) bool {
            return sizes[0] == 0 or sizes[sizes.len - 1] == MAX_BAG_LEN;
        }

        pub fn next(self: *@This()) ?NextArray {
            if (done(self.sizes)) {
                return null;
            }

            var i: usize = 0;
            var start: usize = len;
            while (i < n_bags) : (i += 1) {
                if (self.sizes[i] == 0) {
                    continue;
                }
                start -= self.sizes[i];
                if (self.bags[i].next(self.pieces, start, self.sizes[i])) |p| {
                    self.pieces = p;
                    break;
                }
            } else {
                assert(start == 0);
                nextSize(&self.sizes);
                if (done(self.sizes)) {
                    return null;
                }
            }

            while (i > 0) {
                i -= 1;
                if (self.sizes[i] == 0) {
                    continue;
                }
                if (i < n_bags - 1) {
                    start += self.sizes[i + 1];
                }

                self.bags[i] = BagIterator.init(
                    self.sizes[i],
                    self.locks[@min(lock_len, start)..@min(lock_len, start + self.sizes[i])],
                );
                if (self.bags[i].next(self.pieces, start, self.sizes[i])) |p| {
                    self.pieces = p;
                } else {
                    nextSize(&self.sizes);
                    if (done(self.sizes)) {
                        return null;
                    }
                    i = n_bags;
                    start = 0;
                }
            }
            assert(start + self.sizes[0] == len);

            return self.pieces;
        }

        inline fn nextSize(sizes: []BagLenInt) void {
            sizes[0] -= 1;
            if (sizes.len > 2 and sizes[sizes.len - 2] < MAX_BAG_LEN) {
                sizes[sizes.len - 2] += 1;
            } else {
                sizes[sizes.len - 1] += 1;
            }
        }
    };
}

pub fn DigitsIterator(comptime len: usize) type {
    return struct {
        pub const base = 7;
        pub const end = std.math.powi(u64, base, len) catch @compileError("len too large");

        value: u64,
        step: u64,
        comptime len: usize = len,

        pub fn init(start: u64, step: u64) @This() {
            return .{ .value = start, .step = step };
        }

        pub fn next(self: *@This()) ?[len]u3 {
            if (self.value >= end) {
                return null;
            }

            var digits = [_]u3{undefined} ** len;
            var value = self.value;
            for (0..len) |i| {
                digits[i] = @intCast(value % base);
                value /= base;
            }

            self.value +|= self.step;
            return digits;
        }
    };
}

/// Iterates through all non-equivalent next sequences (including the hold) of length
/// `len`. 'unlocked' is used to control the way iterations are chunked. A higher
/// value uses more memory but runs faster.
pub fn SequenceIterator(comptime len: usize, comptime unlocked: usize) type {
    assert(len > 2);
    assert(unlocked <= len - 1);
    assert(len <= 64 / 3);
    return struct {
        pub const lock_len = @max(1, len - unlocked - 1);
        pub const LockIter = DigitsIterator(lock_len);
        pub const NextIter = NextIterator(len - 1, lock_len);
        pub const SequenceSet = std.AutoHashMap(u64, void);

        swap: u3 = 6,
        current: PieceArray(len),
        lock_iter: LockIter,
        next_iter: NextIter,
        seen: SequenceSet,

        pub fn init(allocator: Allocator) @This() {
            var self = @This(){
                .current = PieceArray(len).init(0),
                .lock_iter = LockIter.init(0, 7),
                .next_iter = undefined,
                .seen = SequenceSet.init(allocator),
            };
            self.current = self.current.set(len - 1, 6);
            self.next_iter = NextIter.init(self.lock_iter.next().?);
            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.seen.deinit();
        }

        pub fn next(self: *@This()) !?[len]PieceKind {
            if (self.swap == 7) {
                return null;
            }

            self.swap += 1;
            if (self.swap < 7) {
                return unpack(self.current, self.swap);
            }

            while (true) {
                self.current = self.current.set(len - 1, self.current.get(len - 1) + 1);
                if (self.current.get(len - 1) == 7) {
                    if (self.nextCurrent()) |pieces| {
                        self.current = PieceArray(len).init(pieces.items);
                        // No need to set the last piece as it is already 0
                        // self.current = self.current.set(len - 1, 0);
                    } else {
                        // Iterator is exhausted
                        return null;
                    }
                }

                const result = try self.seen.getOrPut(canonical(self.current).items);
                if (result.found_existing) {
                    continue;
                }

                self.swap = 0;
                return unpack(self.current, self.swap);
            }
        }

        fn nextCurrent(self: *@This()) ?NextIter.NextArray {
            while (true) {
                if (self.next_iter.next()) |pieces| {
                    return pieces;
                }

                if (self.lock_iter.next()) |locks| {
                    self.seen.clearRetainingCapacity();
                    self.next_iter = NextIter.init(locks);
                } else {
                    self.seen.clearAndFree();
                    return null;
                }
            }
        }

        fn canonical(current: PieceArray(len)) PieceArray(len) {
            if (current.get(len - 1) <= current.get(len - 2)) {
                return current;
            }
            return current
                .set(len - 2, current.get(len - 1))
                .set(len - 1, current.get(len - 2));
        }

        fn unpack(arr: PieceArray(len), swap: u3) [len]PieceKind {
            var pieces = [_]PieceKind{undefined} ** len;
            for (0..len) |i| {
                // Reverse order
                const index = arr.get(len - i - 1);
                // Swap 0 and `swap` values
                const mapped = if (index == 0)
                    swap
                else if (index == swap)
                    0
                else
                    index;
                pieces[i] = @enumFromInt(mapped);
            }
            return pieces;
        }
    };
}
