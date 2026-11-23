const std = @import("std");
const mb = 1024 * 1024;
const gb = 1024 * mb;

const Sample = struct {
    bytes: u64 = 0,
    time_ns: u64 = 0,
    epoch: u64 = 0,
};

pub const Display = union(enum) {
    zero,
    below_mb,
    mb_s: u64,
    gb_tenths: u64,

    pub fn text(self: Display, buf: []u8) []const u8 {
        return switch (self) {
            .zero => "0 MB/s",
            .below_mb => "<1 MB/s",
            .mb_s => |n| std.fmt.bufPrint(buf, "{d} MB/s", .{n}) catch "",
            .gb_tenths => |n| std.fmt.bufPrint(buf, "{d},{d} GB/s", .{ n / 10, n % 10 }) catch "",
        };
    }
};

fn rate(old: ?Sample, current: Sample) ?Display {
    const first = old orelse return null;
    if (first.epoch == 0 or current.epoch != first.epoch or current.time_ns <= first.time_ns or current.bytes < first.bytes) return null;
    const amount = current.bytes - first.bytes;
    if (amount == 0) return .zero;
    const bytes_sec = @as(u128, amount) * std.time.ns_per_s / (current.time_ns - first.time_ns);
    if (bytes_sec < mb) return .below_mb;
    if (bytes_sec < gb) return .{ .mb_s = @intCast(bytes_sec / mb) };
    return .{ .gb_tenths = @intCast(@min((bytes_sec * 10 + gb / 2) / gb, std.math.maxInt(u64))) };
}

pub const Traffic = struct {
    previous: ?Sample = null,
    display: ?Display = null,
    attempted: bool = false,
    retry_in: u8 = 0,

    pub fn release(self: *Traffic, api: anytype) void {
        if (self.attempted) {
            if (api.devicesLowLevel()) |dev| {
                var s: Sample = .{};
                _ = dev.dramTraffic(1, &s.bytes, &s.time_ns, &s.epoch);
            }
        }
        self.* = .{};
    }

    pub fn refresh(self: *Traffic, api: anytype) bool {
        const before = self.display;
        // Revisit an absent provider every five visible ticks. Driver reloads
        // recover while the usage tab stays open.
        if (self.retry_in != 0) {
            self.retry_in -= 1;
            return false;
        }
        if (api.devicesLowLevel()) |dev| {
            var s: Sample = .{};
            self.attempted = true;
            const rc = dev.dramTraffic(0, &s.bytes, &s.time_ns, &s.epoch);
            if (rc == 0 and s.epoch != 0) {
                self.display = rate(self.previous, s);
                self.previous = s;
            } else {
                self.release(api);
                const abi = @import("r4os").abi;
                if (rc == -2 or rc == abi.err_no_fn or rc == abi.err_no_group) self.retry_in = 4;
            }
        } else {
            self.* = .{ .retry_in = 4 };
        }
        return !std.meta.eql(before, self.display);
    }
};

test "elapsed time, measured zero, rollover, fresh epoch and fractional units" {
    const expect = std.testing.expect;
    const s = Sample{ .epoch = 1, .time_ns = 125, .bytes = 100 };
    try expect(rate(null, s) == null);
    var next = s;
    next.time_ns += 2 * std.time.ns_per_s;
    try expect(rate(s, next).? == .zero);
    next.bytes += 1;
    try expect(rate(s, next).? == .below_mb);
    next.bytes = s.bytes + 6 * mb;
    try std.testing.expectEqual(@as(u64, 3), rate(s, next).?.mb_s);
    next.bytes = s.bytes + 3 * gb;
    try std.testing.expectEqual(@as(u64, 15), rate(s, next).?.gb_tenths);
    next.epoch += 1;
    try expect(rate(s, next) == null);
    next = s;
    next.bytes -= 1;
    next.time_ns += 1;
    try expect(rate(s, next) == null);
    try expect(rate(s, s) == null);
}

test "release and return to view rebase, busy retries and unavailable stays quiet" {
    const Fake = struct {
        sample: Sample = .{ .epoch = 1, .time_ns = 1 },
        status: i32 = 0,
        samples: usize = 0,
        releases: usize = 0,
        fn devicesLowLevel(self: *@This()) ?*@This() {
            return self;
        }
        fn dramTraffic(self: *@This(), op: u32, bytes: *u64, stamp: *u64, epoch: *u64) i32 {
            if (op == 1) {
                self.releases += 1;
                return 0;
            }
            self.samples += 1;
            bytes.* = self.sample.bytes;
            stamp.* = self.sample.time_ns;
            epoch.* = self.sample.epoch;
            return self.status;
        }
    };
    var fake: Fake = .{};
    var traffic: Traffic = .{};
    try std.testing.expect(!traffic.refresh(&fake));
    fake.sample.time_ns += 100;
    try std.testing.expect(traffic.refresh(&fake) and traffic.display.? == .zero);
    traffic.release(&fake);
    try std.testing.expect(traffic.display == null and fake.releases == 1);
    try std.testing.expect(!traffic.refresh(&fake));
    fake.status = -3;
    try std.testing.expect(!traffic.refresh(&fake));
    fake.status = 0;
    try std.testing.expect(!traffic.refresh(&fake));
    fake.status = -2;
    _ = traffic.refresh(&fake);
    const count = fake.samples;
    for (0..4) |_| _ = traffic.refresh(&fake);
    try std.testing.expectEqual(count, fake.samples);
    fake.status = 0;
    try std.testing.expect(!traffic.refresh(&fake) and traffic.display == null);
    try std.testing.expectEqual(count + 1, fake.samples);
    traffic.release(&fake);
    try std.testing.expect(!traffic.refresh(&fake) and traffic.display == null);
}
