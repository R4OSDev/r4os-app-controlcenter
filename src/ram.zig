const std = @import("std");
const r4os = @import("r4os");
const mb = 1024 * 1024;

// Values are rounded at display precision so a one-page change does not
// repaint the whole window. The two displayed parts always sum to the total.
pub const Belegung = struct {
    basis_points: u16,
    used_tenths: u64,
    total_tenths: u64,

    pub fn from(total: u64, free: u64) ?Belegung {
        if (total == 0 or free > total) return null;
        const used: u128 = total - free;
        return .{
            .basis_points = if (used == 0) 0 else @intCast(@max(1, used * 10_000 / total)),
            .used_tenths = @intCast((used * 10 + mb / 2) / mb),
            .total_tenths = @intCast((@as(u128, total) * 10 + mb / 2) / mb),
        };
    }

    pub fn percent(self: Belegung) u8 {
        return @intCast(self.basis_points / 100);
    }

    pub fn read(api: *const r4os.App2) ?Belegung {
        const dev = api.devicesLowLevel() orelse return null;
        var total: u64 = 0;
        var free: u64 = 0;
        if (dev.physicalMemoryUsage(&total, &free) != 0) return null;
        return from(total, free);
    }
};

pub fn fillColor(percent: u8) u32 {
    if (percent < 40) return 0x62bd83;
    if (percent < 70) return 0xf0ca40;
    return 0xe95b56;
}

pub fn fillWidth(inner: i32, basis_points: u16) i32 {
    if (inner <= 0 or basis_points == 0) return 0;
    return @intCast(@max(1, @divTrunc(@as(i64, inner) * basis_points, 10_000)));
}

pub fn amount(out: []u8, tenths: ?u64) []const u8 {
    var rounded = tenths orelse return "–";
    const units = [_][]const u8{ "MB", "GB", "TB", "PB" };
    var unit: usize = 0;
    while (rounded >= 10 * 1024 and unit + 1 < units.len) : (unit += 1)
        rounded = rounded / 1024 + @intFromBool(rounded % 1024 >= 512);
    return std.fmt.bufPrint(out, "{d},{d} {s}", .{ rounded / 10, rounded % 10, units[unit] }) catch "–";
}

test "RAM colours, lengths and balances at the thresholds in both directions" {
    const expected = [_]u32{ 0x62bd83, 0x62bd83, 0xf0ca40, 0xf0ca40, 0xe95b56, 0xe95b56 };
    const percent = [_]u8{ 0, 39, 40, 69, 70, 100 };
    for (0..12) |n| {
        const i = if (n < 6) n else 11 - n;
        const v = Belegung.from(100 * mb, (100 - @as(u64, percent[i])) * mb).?;
        try std.testing.expectEqual(percent[i], v.percent());
        try std.testing.expectEqual(expected[i], fillColor(v.percent()));
        try std.testing.expectEqual(@as(i32, percent[i]) * 3, fillWidth(300, v.basis_points));
        try std.testing.expectEqual(@as(u64, percent[i]) * 10, v.used_tenths);
    }
    try std.testing.expect(Belegung.from(0, 0) == null);
    try std.testing.expect(Belegung.from(5, 6) == null);
    try std.testing.expectEqual(@as(u8, 100), Belegung.from(std.math.maxInt(u64), 0).?.percent());
}

test "small resident allocations stay visible at the actual bar width" {
    const idle = Belegung.from(25_455_759_360, 25_273_973_760).?;
    try std.testing.expectEqual(@as(u8, 0), idle.percent());
    try std.testing.expect(idle.basis_points > 0);
    try std.testing.expectEqual(@as(i32, 2), fillWidth(308, idle.basis_points));
    try std.testing.expectEqual(@as(i32, 1), fillWidth(308, Belegung.from(1 << 40, (1 << 40) - 4096).?.basis_points));
    try std.testing.expectEqual(@as(i32, 0), fillWidth(308, Belegung.from(4096, 4096).?.basis_points));
}
