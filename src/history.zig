const std = @import("std");

const second = std.time.ns_per_s;
const span = 60 * second;
const capacity = 64;
const Sample = struct { time: u64, value: u8, starts: bool };
pub const Point = struct { x: i32, y: i32, starts: bool };

pub const History = struct {
    samples: [capacity]Sample = undefined,
    next: usize = 0,
    count: usize = 0,
    now: u64 = 0,
    interrupted: bool = true,
    current: bool = false,

    pub fn pause(self: *History) void {
        self.interrupted = true;
        self.current = false;
    }

    pub fn observe(self: *History, time: ?u64, value: ?u8, discontinuity: bool) bool {
        const stamp = time orelse {
            const changed = self.current;
            self.pause();
            return changed;
        };
        if (stamp < self.now) self.* = .{};
        self.now = stamp;
        if (discontinuity) self.pause();
        const percent = value orelse {
            self.pause();
            return self.count > 0;
        };
        const prev = if (self.count != 0) self.samples[(self.next + capacity - 1) % capacity] else null;
        const starts = self.interrupted or prev == null or stamp - prev.?.time > 2 * second;
        self.samples[self.next] = .{ .time = stamp, .value = percent, .starts = starts };
        self.next = (self.next + 1) % capacity;
        self.count = @min(capacity, self.count + 1);
        self.interrupted = false;
        self.current = true;
        return true;
    }

    /// Retain the left boundary of a continuous segment. Collinear samples
    /// share a line; interruptions create separate subpaths.
    pub fn points(self: *const History, width: i32, height: i32, out: *[capacity + 1]Point) []const Point {
        if (width < 2 or height < 2) return out[0..0];
        var used: usize = 0;
        var previous: ?Sample = null;
        for (0..self.count) |i| {
            const s = self.samples[(self.next + capacity - self.count + i) % capacity];
            const age = self.now - s.time;
            if (age <= span) {
                if (used == 0 and !s.starts and previous != null and self.now - previous.?.time > span) {
                    const old = previous.?;
                    const overlap: i64 = @intCast(self.now - span - old.time);
                    const delta: i64 = @as(i64, s.value) - old.value;
                    const at_edge = @as(i64, old.value) + @divTrunc(delta * overlap, @as(i64, @intCast(s.time - old.time)));
                    out[0] = .{ .x = 0, .y = ordinate(@intCast(at_edge), height), .starts = true };
                    used = 1;
                }
                const p = Point{ .x = width - 1 - @as(i32, @intCast((@as(u128, age) * @as(u32, @intCast(width - 1)) + span / 2) / span)), .y = ordinate(s.value, height), .starts = used == 0 or s.starts };
                if (!p.starts and used >= 2 and !out[used - 1].starts and out[used - 2].y == p.y and out[used - 1].y == p.y) {
                    out[used - 1] = p;
                } else {
                    out[used] = p;
                    used += 1;
                }
            }
            previous = s;
        }
        return out[0..used];
    }
    fn ordinate(percent: u8, height: i32) i32 {
        return height - 1 - @divTrunc((height - 1) * @as(i32, percent) + 50, 100);
    }
};

test "clock window, physical time gaps and wrap" {
    var h: History = .{};
    var buf: [65]Point = undefined;
    for (0..75) |i| _ = h.observe(@as(u64, i) * second, 40, false);
    const flat = h.points(601, 101, &buf);
    try std.testing.expectEqual(@as(usize, 2), flat.len);
    try std.testing.expectEqual(@as(i32, 0), flat[0].x);
    try std.testing.expectEqual(@as(i32, 600), flat[1].x);
    h.pause();
    _ = h.observe(79 * second, null, false);
    _ = h.observe(80 * second, 100, false);
    const gap = h.points(601, 101, &buf);
    try std.testing.expect(gap[gap.len - 1].starts and gap[gap.len - 1].y == 0);
    _ = h.observe(145 * second, 0, false);
    try std.testing.expectEqual(@as(usize, 1), h.points(601, 101, &buf).len);
    _ = h.observe(2 * second, 20, true);
    try std.testing.expectEqual(@as(usize, 1), h.count);
}
