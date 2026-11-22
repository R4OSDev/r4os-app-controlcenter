const std = @import("std");
const r = @import("r4os");
const font = @import("app_fonts");
const gui = r.gui;

pub const Style = enum { regular, semibold, mono };
pub const Text = struct {
    store: ?font.FaceStore = null,
    faces: [3]?font.FaceHandle = @splat(null),
    runs: gui.FontRuns(font),
    system: gui.FontSet,

    pub fn init(api: *r.App2, window: *r.Window, allocator: std.mem.Allocator) Text {
        var self = Text{ .runs = .{ .allocator = allocator }, .system = gui.FontSet.system(&window.draw) };
        const context = font.FontContext.init2(api.startContext()) orelse return self;
        self.store = font.FaceStore.init(context, allocator, .{ .max_cached_glyphs = 512, .max_cached_bytes = 512 * 1024 }) catch return self;
        const files = [_][]const u8{ @embedFile("fonts/Inter-Regular.woff2"), @embedFile("fonts/Inter-SemiBold.woff2"), @embedFile("fonts/IBMPlexMono-Regular.ttf") };
        for (files, &self.faces) |bytes, *face| face.* = self.store.?.openCopy(bytes, 0) catch null;
        return self;
    }

    pub fn deinit(self: *Text) void {
        self.runs.deinit();
        if (self.store) |*store| store.deinit();
    }

    pub fn draw(self: *Text, c: gui.Canvas, area: gui.Rect, size: u32, style: Style, alignment: gui.Align, value: []const u8, color: u32, background: u32) void {
        if (area.w <= 0 or area.y >= c.h or area.y + area.h <= 0 or value.len == 0) return;
        if (self.faces[@intFromEnum(style)]) |face| {
            if (self.runs.prepare(&self.store.?, face, size, area.w, value)) |run| {
                run.draw(c, area.x, area.y + @as(i32, @intCast(size)), area.w, alignment, color);
                return;
            } else |_| {}
        }
        const id = if (size >= 31) self.system.display else if (size >= 17) self.system.heading else self.system.body;
        var buffer: [512]u8 = undefined;
        _ = c.withFontId(id).label(.{ .rect = area, .text = value, .alignment = alignment, .fg = color, .bg = background }, &buffer);
    }
};
