const std = @import("std");
const gui = @import("r4os").gui;

pub const Scroll = struct {
    stride: usize = 1,
    compact: bool = false,
    first: usize = 0,
    bar: gui.Scrollbar = .{ .rect = .{} },
    thumb_y: ?i32 = null,

    pub fn key(self: *Scroll, k: u8) void {
        self.first = switch (k) {
            gui.Key.up => self.first -| self.stride,
            gui.Key.down => self.first +| self.stride,
            gui.Key.page_up => self.first -| self.bar.visible_items,
            gui.Key.page_down => self.first +| self.bar.visible_items,
            gui.Key.home => 0,
            gui.Key.end => self.bar.maxFirst(),
            else => self.first,
        };
        self.first = @min(self.first, self.bar.maxFirst());
    }

    pub fn mouseDown(self: *Scroll, x: i32, y: i32) void {
        if (!self.bar.rect.contains(x, y)) return;
        const part = self.bar.partAt(x, y);
        if (part == .thumb) {
            self.thumb_y = y - self.bar.thumbRect().y;
        } else switch (part) {
            .decrement => self.key(gui.Key.up),
            .increment => self.key(gui.Key.down),
            else => self.first = self.bar.step(part).first_index,
        }
    }
    pub fn drag(self: *Scroll, y: i32) void {
        const offset = self.thumb_y orelse return;
        const track = self.bar.trackRect();
        const travel = track.h - self.bar.thumbRect().h;
        if (travel <= 0) return;
        const position: usize = @intCast(std.math.clamp(y - offset - track.y, 0, travel));
        self.first = position * self.bar.maxFirst() / @as(usize, @intCast(travel));
    }

    pub fn layout(self: *Scroll, rect: gui.Rect, total: usize, visible: usize) void {
        self.bar = .{ .compact = self.compact, .palette = .{ .face = 0x2a3d46, .text = 0xa3b7bc }, .rect = rect, .first_index = self.first, .total_items = total, .visible_items = visible };
        self.first = self.bar.clampedFirst();
        self.bar.first_index = self.first;
        if (self.bar.maxFirst() == 0) self.thumb_y = null;
    }
};
