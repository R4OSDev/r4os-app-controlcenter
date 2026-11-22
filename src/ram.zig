const std = @import("std");
const r4os = @import("r4os");
const gui = r4os.gui;
const mb = 1024 * 1024;

// Values are rounded at display precision so a one-page change does not
// repaint the whole window. The two displayed parts always sum to the total.
pub const Belegung = struct {
    percent: u8,
    used_tenths: u64,
    total_tenths: u64,

    pub fn from(total: u64, free: u64) ?Belegung {
        if (total == 0 or free > total) return null;
        const used: u128 = total - free;
        return .{
            .percent = @intCast(used * 100 / total),
            .used_tenths = @intCast((used * 10 + mb / 2) / mb),
            .total_tenths = @intCast((@as(u128, total) * 10 + mb / 2) / mb),
        };
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
    if (percent < 40) return 0x55b96b;
    if (percent < 70) return 0xf0ca40;
    return 0xe95b56;
}

pub fn fillWidth(inner: i32, percent: u8) i32 {
    return @intCast(@divTrunc(@as(i64, @max(inner, 0)) * percent, 100));
}

pub fn amount(out: []u8, tenths: ?u64) []const u8 {
    const v = tenths orelse return "—";
    return std.fmt.bufPrint(out, "{d},{d} MB", .{ v / 10, v % 10 }) catch "—";
}

// Classic text commands paint an opaque glyph cell. The Alpha8 mask keeps
// the colour boundary visible even where it runs through a digit.
pub const Caption = struct {
    value: ?u8 = null,
    width: u32 = 0,
    mask: [64 * 16]u8 = @splat(0),

    pub fn draw(self: *Caption, canvas: gui.Canvas, area: gui.Rect, percent: ?u8, ink: u32) void {
        const v = percent orelse {
            _ = canvas.rect(.{ .x = area.x + @divTrunc(area.w - 8, 2), .y = area.y + @divTrunc(area.h, 2), .w = 8, .h = 1 }, ink);
            return;
        };
        if (self.value != v) {
            var buf: [5]u8 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d}%", .{v}) catch return;
            @memset(&self.mask, 0);
            for (digits, 0..) |ch, index| {
                var glyph: r4os.abi.GuiGlyphBitmap = .{};
                if (canvas.ctx.fontGlyphBitmap(r4os.abi.gui_font_builtin_id, ch, &glyph) != 0) return;
                for (glyph.rows[0..8], 0..) |row, y| {
                    for (0..8) |x| {
                        if ((row >> @intCast(x)) & 1 != 0) {
                            const start = y * 128 + index * 16 + x * 2;
                            @memset(self.mask[start..][0..2], 255);
                            @memset(self.mask[start + 64 ..][0..2], 255);
                        }
                    }
                }
            }
            self.width = @intCast(digits.len * 16);
            self.value = v;
        }
        _ = canvas.blendAlpha8(area.x + @divTrunc(area.w - @as(i32, @intCast(self.width)), 2), area.y + @divTrunc(area.h - 16, 2), self.width, 16, 64, ink, &self.mask);
    }
};

test "RAM colours, lengths and balances at the thresholds in both directions" {
    const expected = [_]u32{ 0x55b96b, 0x55b96b, 0xf0ca40, 0xf0ca40, 0xe95b56, 0xe95b56 };
    const percent = [_]u8{ 0, 39, 40, 69, 70, 100 };
    for (0..12) |n| {
        const i = if (n < 6) n else 11 - n;
        const v = Belegung.from(100 * mb, (100 - @as(u64, percent[i])) * mb).?;
        try std.testing.expectEqual(percent[i], v.percent);
        try std.testing.expectEqual(expected[i], fillColor(v.percent));
        try std.testing.expectEqual(@as(i32, percent[i]) * 3, fillWidth(300, v.percent));
        try std.testing.expectEqual(@as(u64, percent[i]) * 10, v.used_tenths);
    }
    try std.testing.expect(Belegung.from(0, 0) == null);
    try std.testing.expect(Belegung.from(5, 6) == null);
    try std.testing.expectEqual(@as(u8, 100), Belegung.from(std.math.maxInt(u64), 0).?.percent);
}
