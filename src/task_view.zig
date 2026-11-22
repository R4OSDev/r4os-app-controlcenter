const std = @import("std");
const r4os = @import("r4os");
const gui = r4os.gui;
const a = r4os.abi;
const model = @import("tasks.zig");
const Tasks = model.Tasks;
const ink = 0x17212b;
const paper = 0xffffff;
const muted = 0x496173;
const selected = 0xd9ecf4;
const line_h = 19;

fn text(c: gui.Canvas, x: i32, y: i32, w: i32, value: []const u8, fg: u32, bg: u32) void {
    var scratch: [192]u8 = undefined;
    _ = c.textClipped(x, y, @max(0, w), &scratch, value, fg, bg);
}
fn formatted(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buffer, format, args) catch "?";
}
fn activity(active: u8) []const u8 {
    return if (active != 0) "aktiv" else "inaktiv";
}
fn damage(kind: u8) []const u8 {
    return switch (kind) {
        1 => "Cursor",
        2 => "gemischt",
        3 => "Vollbild",
        else => "keiner",
    };
}
pub const View = struct {
    scroll: @import("scroll.zig").Scroll = .{},

    pub fn paint(self: *View, canvas: gui.Canvas, left: i32, tasks: *const Tasks) void {
        const x = left + 9;
        const w = canvas.w - x - 8;
        var buf: [180]u8 = undefined;
        const status = tasks.status;
        text(canvas, x, 8, w, formatted(&buf, "Shell {s}    Vordergrund {s}    Instanzen {d}", .{
            activity(status.shell_running), activity(status.foreground_running), status.instance_count,
        }), ink, paper);
        text(canvas, x, 28, w, formatted(&buf, "Letzte Ausgabe: {s}    Letzter Exit: {d}", .{
            if (status.display_used != 0) @as([]const u8, "Framebuffer") else "Konsole", status.last_exit_code,
        }), muted, paper);
        const footer = canvas.h - 78;
        const visible: usize = @intCast(@max(1, @divTrunc(footer - 51, line_h)));
        const window_count: usize = if (tasks.windows) |*s| s.status.window_count else 0;
        const window_lines = @max(window_count, 1);
        const proc_lines = @max(tasks.processes.items.len, 1);
        self.scroll.layout(.{ .x = canvas.w - 17, .y = 47, .w = 15, .h = @max(1, footer - 47) }, 2 + window_lines + proc_lines, visible);
        const content = w - 16;
        for (0..@min(visible, self.scroll.bar.total_items - self.scroll.first)) |screen_row| {
            const row = screen_row + self.scroll.first;
            const y = 51 + @as(i32, @intCast(screen_row)) * line_h;
            if (row == 0) {
                _ = canvas.rect(.{ .x = x - 2, .y = y - 2, .w = content, .h = line_h }, selected);
                text(canvas, x, y, content - 163, "Desktop-Fenster", ink, selected);
                text(canvas, x + content - 159, y, 90, "Status", ink, selected);
                text(canvas, x + content - 62, y, 62, "Instanz", ink, selected);
            } else if (row <= window_lines) {
                if (window_count == 0) {
                    text(canvas, x, y, content, if (tasks.windows == null) "Fensterdaten nicht verfügbar" else "Keine Fenster", muted, paper);
                    continue;
                }
                const s = &tasks.windows.?;
                const win = s.records[row - 1];
                const active = win.flags & a.window_service_flag_focused != 0;
                if (active) text(canvas, x, y, 13, "*", ink, paper);
                text(canvas, x + 15, y, content - 179, std.mem.sliceTo(&win.title, 0), ink, paper);
                const state: []const u8 = if (win.flags & a.window_service_flag_closing != 0) "schließt" else if (win.flags & a.window_service_flag_minimized != 0) "minimiert" else "sichtbar";
                text(canvas, x + content - 159, y, 94, state, ink, paper);
                text(canvas, x + content - 62, y, 62, if (win.instance_id == 0) "–" else formatted(&buf, "{d}", .{win.instance_id}), ink, paper);
            } else if (row == window_lines + 1) {
                _ = canvas.rect(.{ .x = x - 2, .y = y - 2, .w = content, .h = line_h }, selected);
                const headings = [_][]const u8{ "R4X-ID", "Rolle", "Klasse", "Status", "Fenster", "Exit" };
                columns(canvas, x, y, content, &headings, selected);
            } else if (tasks.processes.items.len != 0) {
                const process = tasks.processes.items[row - window_lines - 2].info;
                var fields: [3][24]u8 = undefined;
                const cells = [_][]const u8{
                    formatted(&fields[0], "{d}", .{process.id}), model.role(process.role),                           model.class(process.app_class),
                    model.state(process.state),                  formatted(&fields[1], "{d}", .{process.window_id}), formatted(&fields[2], "{d}", .{process.exit_code}),
                };
                columns(canvas, x, y, content, &cells, paper);
            } else text(canvas, x, y, content, if (tasks.current) "Keine Programme" else "Programmdaten nicht verfügbar", muted, paper);
        }
        var scratch: [64]u8 = undefined;
        _ = canvas.scrollbar(self.scroll.bar, &scratch);
        _ = canvas.rect(.{ .x = left, .y = footer, .w = canvas.w - left, .h = 1 }, muted);
        if (tasks.render) |c| {
            text(canvas, x, footer + 6, w, formatted(&buf, "Desktop: {d} Neuzeichnungen    {d} Vollbilder", .{ c.redraws, c.full }), ink, paper);
            text(canvas, x, footer + 25, w, formatted(&buf, "Cursor: {d} Bewegungen, {d} Ausgaben", .{
                c.cursor_moves, c.cursor_presents,
            }), muted, paper);
            text(canvas, x, footer + 44, w, formatted(&buf, "Letzter Bereich: {s}", .{damage(c.last_damage)}), muted, paper);
        } else text(canvas, x, footer + 6, w, "Desktop-Renderdaten nicht verfügbar", muted, paper);
        if (!tasks.current and tasks.processes.items.len != 0) text(canvas, x, footer + 61, w, "Programme: letzter vollständiger Stand", muted, paper);
    }

    fn columns(canvas: gui.Canvas, x: i32, y: i32, width: i32, cells: *const [6][]const u8, bg: u32) void {
        const stops = [_]i32{ 0, 14, 34, 51, 71, 88, 100 };
        for (cells, 0..) |v, i| {
            const start = @divTrunc(width * stops[i], 100);
            const end = @divTrunc(width * stops[i + 1], 100);
            text(canvas, x + start, y, end - start - 2, v, ink, bg);
        }
    }
};
