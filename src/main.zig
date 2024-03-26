const std = @import("std");
const assert = std.debug.assert;

const MAX_BAG_LEN = 7;
const BagLenInt = std.math.Log2IntCeil(@Type(.{ .Int = .{
    .bits = MAX_BAG_LEN,
    .signedness = .unsigned,
} }));

/// Stores an immutable array of integers (std.PackedIntArray but with a single
/// backing integer).
fn PieceArray(comptime len: usize) type {
    assert(len > 0);
    assert(len <= 64 / 3);
    return struct {
        pub const item_size = @bitSizeOf(u3);
        pub const bits = item_size * len;
        pub const mask = @as(u64, (1 << bits) - 1);
        pub const item_mask = @as(u64, (1 << item_size) - 1);

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
                    ~(item_mask << @intCast(index * item_size)) | // Write 0 at index
                    (@as(u64, value) << @intCast(index * item_size)), // Write value at index
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

/// Iterates through all possible next pieces of length `len` assuming a 7-bag
/// randomiser.
fn NextIterator(comptime len: usize, comptime lock_len: usize) type {
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
                if (@popCount(frees[size - 1] ^ (iters[size - 1] & (~iters[size - 1] +% 1))) != 7 - @as(u8, size)) {
                    iters[0] = 0;
                }
                return .{ .frees = frees, .iters = iters };
            }

            pub fn next(self: *@This(), pieces: NextArray, offset: usize, size: BagLenInt) ?NextArray {
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

        sizes: [n_bags]BagLenInt, // Can be reduced to a single int but the logic becomes more complicated.
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
                // Iterator is exhausted
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
                    if (done(self.sizes)) {
                        return null;
                    }
                    nextSize(&self.sizes);
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

fn DigitsIterator(comptime len: usize) type {
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    inline for (2..16) |i| {
        const start = std.time.nanoTimestamp();
        const ExtendedArray = PieceArray(i + 1);
        var iter_count: usize = 0;
        var seen_count: usize = 0;

        const lock_len = @max(i, 7) - 6; // Adjust this number so that `seen` never
        // exceeds the L3 cache for best performance.
        var lock_iter = DigitsIterator(lock_len).init(0, 7);
        while (lock_iter.next()) |locks| {
            seen.clearRetainingCapacity();
            var next_iter = NextIterator(i, lock_len).init(locks);
            while (next_iter.next()) |pieces| {
                // TODO: write proof that this counts perfectly
                // Hold is smaller than current; place it in the back
                var p = ExtendedArray.init(pieces.items);
                for (0..p.get(i - 1)) |hold| {
                    try seen.put(p.set(i, @intCast(hold)).items, {});
                }
                // Hold is larger than current; swap with current to place current in the back
                p = p.set(i, p.get(i - 1));
                for (p.get(i)..7) |hold| {
                    try seen.put(p.set(i - 1, @intCast(hold)).items, {});
                }
                iter_count += 1;
            }
            seen_count += seen.count();
        }

        const t: u64 = @intCast(std.time.nanoTimestamp() - start);
        std.debug.print("{:2} | Iters: {:11} | Distinct: {:11} | Time: {}\n", .{ i, iter_count, seen_count * 7, std.fmt.fmtDuration(t) });
    }
}
