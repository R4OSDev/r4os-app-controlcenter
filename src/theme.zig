const std = @import("std");
const gui = @import("r4os").gui;
const typeface = @import("typography.zig");

pub const bg = 0x132027;
pub const rail_bg = 0x0e1920;
pub const ink = 0xeef4f3;
pub const sub = 0xa3b7bc;
pub const line = 0x395059;
pub const grid = 0x2a3d46;
pub const soft = 0x20333a;
pub const accent = 0x72dfbe;
pub const selection = 0x274b48;
pub const selected_text = 0xa7f2db;

pub fn box(x: i32, y: i32, w: i32, h: i32) gui.Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}
pub fn rail(width: i32) i32 {
    return 114 + @divTrunc(std.math.clamp(width - 558, 0, 194) * 9, 194);
}
pub fn labelWidth(width: i32) i32 {
    return 108 + @divTrunc(std.math.clamp(width - 558, 0, 194) * 42, 194);
}
pub fn fmt(buf: []u8, comptime pattern: []const u8, values: anytype) []const u8 {
    return std.fmt.bufPrint(buf, pattern, values) catch "–";
}

pub const Painter = struct {
    canvas: gui.Canvas,
    text: *typeface.Text,

    pub fn label(self: Painter, x: i32, y: i32, w: i32, size: u32, style: typeface.Style, alignment: gui.Align, value: []const u8, color: u32, background: u32) void {
        self.text.draw(self.canvas, box(x, y, w, @as(i32, @intCast(size)) + 7), size, style, alignment, value, color, background);
    }
    pub fn rect(self: Painter, area: gui.Rect, color: u32) void {
        const y0 = @max(0, area.y);
        const y1 = @min(self.canvas.h, area.y + area.h);
        if (y1 > y0 and area.w > 0) _ = self.canvas.rect(box(area.x, y0, area.w, y1 - y0), color);
    }
    pub fn rule(self: Painter, x: i32, y: i32, w: i32, color: u32) void {
        self.rect(box(x, y, w, 1), color);
    }
    pub fn tile(self: Painter, area: gui.Rect, color: u32) void {
        self.rect(box(area.x, area.y + 1, area.w, area.h - 2), color);
        self.rule(area.x + 1, area.y, area.w - 2, color);
        self.rule(area.x + 1, area.y + area.h - 1, area.w - 2, color);
    }
};
