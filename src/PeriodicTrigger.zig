const std = @import("std");
const assert = std.debug.assert;
const nanoTimestamp = std.time.nanoTimestamp;

const PeriodicTrigger = @This();

period: u64,
allow_skip: bool,
last: i128,

pub fn init(period: u64, allow_skip: bool) PeriodicTrigger {
    assert(period > 0);
    return .{
        .period = period,
        .allow_skip = allow_skip,
        .last = nanoTimestamp(),
    };
}

pub fn trigger(self: *PeriodicTrigger) ?u64 {
    const now = nanoTimestamp();
    const elapsed: u128 = @intCast(now - self.last);
    if (elapsed < self.period) {
        return null;
    }

    if (self.allow_skip) {
        // Skip to the most recent complete frame
        const partial_frame_time = elapsed % self.period;
        const time_to_add: u64 = @intCast(elapsed - partial_frame_time);
        self.last += time_to_add;
        return time_to_add;
    } else {
        self.last += self.period;
        return self.period;
    }
}
