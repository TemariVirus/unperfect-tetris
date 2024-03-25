const std = @import("std");
const assert = std.debug.assert;

const MAX_BAG_LEN = 7;
const BagLenInt = std.math.Log2IntCeil(@Type(.{ .Int = .{
    .bits = MAX_BAG_LEN,
    .signedness = .unsigned,
} }));

/// Stores an immutable array of integers (std.PackedIntArray but with a single
/// backing integer).
fn FixedPackedIntArray(comptime Int: type, comptime size: usize) type {
    assert(@bitSizeOf(Int) > 0);
    assert(size > 0);
    return struct {
        pub const item_size = @bitSizeOf(Int);
        pub const bits = item_size * size;
        pub const BackingInt = switch (bits) {
            0...32 => u32,
            33...64 => u64,
            else => @compileError("Total bit size must not exceed 64"),
        };
        pub const mask = @as(BackingInt, (1 << bits) - 1);
        pub const item_mask = @as(BackingInt, (1 << item_size) - 1);

        items: BackingInt,
        comptime len: usize = size,

        pub fn init(items: BackingInt) @This() {
            assert(mask & items == items);
            return .{ .items = items };
        }

        pub fn get(self: @This(), index: usize) Int {
            assert(index < self.len);
            return @truncate(item_mask & (self.items >> @intCast(index * item_size)));
        }

        pub fn set(self: @This(), index: usize, value: Int) @This() {
            assert(index < self.len);
            // Mask is not needed at the end as all out of bounds bits are already 0
            assert(~mask & self.items == 0);
            return .{
                .items = self.items &
                    ~(item_mask << @intCast(index * item_size)) | // Write 0 at index
                    (@as(BackingInt, value) << @intCast(index * item_size)), // Write value at index
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
fn NextIterator(comptime len: usize) type {
    assert(len > 0);
    return struct {
        pub const n_bags = if (len == 1) 1 else (len - 2) / MAX_BAG_LEN + 2;
        pub const PieceArray = FixedPackedIntArray(u3, len);

        /// Iterates through a truncated 7-bag of length `size`.
        pub const BagIterator = struct {
            iters: [MAX_BAG_LEN]u7,
            frees: [MAX_BAG_LEN]u7,

            pub fn init(size: BagLenInt) @This() {
                assert(size > 0 and size <= MAX_BAG_LEN);
                var values = [_]u7{undefined} ** MAX_BAG_LEN;
                for (0..size) |i| {
                    values[i] = ~@as(u7, 0) << @intCast(i);
                }
                return .{ .iters = values, .frees = values };
            }

            pub fn next(self: *@This(), pieces: PieceArray, offset: usize, size: BagLenInt) ?PieceArray {
                if (self.iters[0] == 0) {
                    return null;
                }

                var p = pieces.shiftRight(offset);
                for (0..size) |i| {
                    p = p.set(i, @ctz(self.iters[i]));
                }
                p = p.shiftLeft(offset);
                const lower = pieces.items & ~(PieceArray.mask << @intCast(offset * 3));
                p = PieceArray.init(p.items | lower);

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
        pieces: PieceArray,

        pub fn init() @This() {
            var left = len;
            var sizes = [_]BagLenInt{undefined} ** n_bags;
            for (0..n_bags) |i| {
                sizes[i] = @min(left, MAX_BAG_LEN);
                left -= sizes[i];
            }

            var bags = [_]BagIterator{undefined} ** n_bags;
            var start: usize = len;
            var pieces = PieceArray.init(0);

            for (0..n_bags) |i| {
                if (sizes[i] == 0) {
                    break;
                }
                bags[i] = BagIterator.init(sizes[i]);
                start -= sizes[i];
                if (i > 0) {
                    if (bags[i].next(pieces, start, sizes[i])) |p| {
                        pieces = p;
                    } else unreachable;
                }
            }

            return .{ .sizes = sizes, .bags = bags, .pieces = pieces };
        }

        pub fn next(self: *@This()) ?PieceArray {
            if (self.sizes[0] == 0) {
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
                self.sizes[0] -= 1;
                // Iterator is exhausted
                if (self.sizes[0] == 0) {
                    return null;
                }
                if (n_bags > 2 and self.sizes[n_bags - 2] < MAX_BAG_LEN) {
                    self.sizes[n_bags - 2] += 1;
                } else {
                    self.sizes[n_bags - 1] += 1;
                }
            }

            while (i > 0) {
                i -= 1;
                if (self.sizes[i] == 0) {
                    continue;
                }
                self.bags[i] = BagIterator.init(self.sizes[i]);
                if (i < n_bags - 1) {
                    start += self.sizes[i + 1];
                }
                if (self.bags[i].next(self.pieces, start, self.sizes[i])) |p| {
                    self.pieces = p;
                } else unreachable;
            }
            assert(start + self.sizes[0] == len);

            return self.pieces;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    // const allocator = std.heap.c_allocator;

    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();

    inline for (1..16) |i| {
        const start = std.time.nanoTimestamp();
        seen.clearRetainingCapacity();
        const PieceArray = FixedPackedIntArray(u3, i + 1);

        // TODO: Spilt into multiple passes grouped by starting pieces to
        // reduce ram usage
        var iter = NextIterator(i).init();
        var iter_count: usize = 0;
        while (iter.next()) |pieces| {
            // TODO: write proof that this counts perfectly
            // No hold piece (hold piece can be any value, so this is not needed)
            // var p = pieces;
            // if (p.get(0) > p.get(1)) {
            //     const temp = p.get(0);
            //     p = p.set(0, p.get(1));
            //     p = p.set(1, temp);
            // }
            // try seen.put(p.items, {});
            // Hold is smaller than current; place it in front
            var p = PieceArray.init(pieces.items).shiftLeft(1);
            for (0..p.get(1)) |hold| {
                try seen.put(p.set(0, @intCast(hold)).items, {});
            }
            // Hold is larger than current; place it in the back
            p = p.set(0, p.get(1));
            for (p.get(0)..7) |hold| {
                try seen.put(p.set(1, @intCast(hold)).items, {});
            }

            iter_count += 1;
        }

        const t: u64 = @intCast(std.time.nanoTimestamp() - start);
        std.debug.print("{:2} | Iters: {:12} | Distinct: {:12} | Time: {}\n", .{ i, iter_count, seen.count(), std.fmt.fmtDuration(t) });
    }
}
