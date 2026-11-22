const std = @import("std");
const r = @import("r4os");
const theme = @import("theme.zig");
const tasks_model = @import("tasks.zig");
const Tasks = tasks_model.Tasks;
const P = theme.Painter;
const a = r.abi;
const fmt = theme.fmt;

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
const Sections = struct {
    programs: i32,
    desktop: i32,
    session: i32,
    total: i32,

    fn forData(t: *const Tasks) Sections {
        const window_count = if (t.windows) |*snap| snap.status.window_count else 0;
        const program_y: i32 = 77 + 26 * @as(i32, @intCast(@max(1, window_count)));
        const stale_height: i32 = if (!t.current and t.processes.items.len > 0) 22 else 0;
        const desktop_y = program_y + 115 + 33 * @as(i32, @intCast(@max(1, t.processes.items.len))) + stale_height;
        return .{ .programs = program_y, .desktop = desktop_y, .session = desktop_y + 142, .total = desktop_y + 275 };
    }
};
pub const View = struct {
    scroll: @import("scroll.zig").Scroll = .{ .compact = true, .stride = 26 },
    // Repaint a changing desktop counter only when its section is on screen.
    hashes: [4]u64 = @splat(0),
    extent: i32 = 0,

    fn field(h: *std.hash.Wyhash, value: anytype) void {
        h.update(std.mem.asBytes(&value));
    }
    pub fn showsRenderStats(self: *const View, t: *const Tasks, height: i32) bool {
        if (height <= 0) return false;
        const sections = Sections.forData(t);
        const top = @min(@as(i32, @intCast(self.scroll.first)), @max(0, sections.total - height));
        const bottom = top + height;
        return (top < sections.desktop + 124 and bottom > sections.desktop + 51) or
            (top < sections.session + 111 and bottom > sections.session + 93);
    }

    pub fn changed(self: *View, t: *const Tasks, height: i32) bool {
        var h = [_]std.hash.Wyhash{std.hash.Wyhash.init(0)} ** 4;
        field(&h[0], t.windows != null);
        if (t.windows) |*snap| field(&h[0], snap.status.focused_window);
        if (t.windows) |*snap| for (snap.records[0..snap.status.window_count]) |win| {
            field(&h[0], win.window_id);
            field(&h[0], win.instance_id);
            field(&h[0], win.flags);
            h[0].update(std.mem.sliceTo(&win.title, 0));
        };
        field(&h[1], t.current);
        for (t.processes.items) |row| {
            const info = row.info;
            field(&h[1], info.id);
            field(&h[1], info.role);
            field(&h[1], info.app_class);
            field(&h[1], info.state);
            field(&h[1], info.window_id);
            field(&h[1], info.exit_code);
        }
        field(&h[2], t.render_sampled);
        field(&h[2], t.render != null);
        field(&h[3], t.render != null);
        if (t.render) |stats| {
            field(&h[2], stats.redraws);
            field(&h[2], stats.full);
            field(&h[2], stats.last_damage);
            field(&h[3], stats.cursor_moves);
            field(&h[3], stats.cursor_presents);
        }
        field(&h[3], t.status.shell_running);
        field(&h[3], t.status.foreground_running);
        field(&h[3], t.status.display_used);
        field(&h[3], t.status.last_exit_code);
        field(&h[3], t.status.instance_count);
        const sections = Sections.forData(t);
        const edges = [_]i32{ 0, sections.programs, sections.desktop, sections.session, sections.total };
        const offset: i32 = @intCast(self.scroll.first);
        var visible = self.extent != sections.total;
        for (&h, 0..) |*hash, i| {
            const key = hash.final();
            if (key != self.hashes[i] and edges[i] < offset + height and edges[i + 1] > offset) visible = true;
            self.hashes[i] = key;
        }
        self.extent = sections.total;
        return visible;
    }

    pub fn paint(self: *View, p: P, left: i32, t: *const Tasks) void {
        const c = p.canvas;
        const sections = Sections.forData(t);
        const overflow = sections.total > c.h;
        self.scroll.layout(if (overflow) theme.box(c.w - 12, 5, 11, @max(1, c.h - 10)) else .{}, @intCast(sections.total), @intCast(c.h));
        const top = -@as(i32, @intCast(self.scroll.first));
        const x = left + 17;
        const w = c.w - x - 15 - @as(i32, if (overflow) 3 else 0);
        if (top + sections.programs > 0) windows(p, x, top, w, t);
        if (top + sections.programs < c.h and top + sections.desktop > 0) programs(p, x, top + sections.programs, w, t);
        if (top + sections.desktop < c.h and top + sections.session > 0) desktop(p, x, top + sections.desktop, w, t);
        if (top + sections.session < c.h) session(p, x, top + sections.session, w, t);
        if (overflow) {
            var scratch: [12]u8 = undefined;
            _ = self.scroll.bar.draw(c, &scratch);
        }
    }
};

fn windows(p: P, x: i32, y: i32, w: i32, t: *const Tasks) void {
    var buf: [196]u8 = undefined;
    p.label(x, y + 24, w - 110, 18, .semibold, .left, "Desktop-Fenster", theme.ink, theme.bg);
    const n = if (t.windows) |*s| s.status.window_count else 0;
    p.label(x + w - 110, y + 29, 110, 12, .regular, .right, fmt(&buf, "{d} Fenster", .{n}), theme.sub, theme.bg);
    if (n == 0) {
        p.label(x, y + 61, w, 14, .regular, .left, if (t.windows == null) "Fensterdaten nicht verfügbar" else "Keine Fenster", theme.sub, theme.bg);
        return;
    }
    for (t.windows.?.records[0..n], 0..) |win, i| {
        const top = y + 61 + 26 * @as(i32, @intCast(i));
        if (top >= p.canvas.h) break;
        if (top + 24 < 0) continue;
        const split = @divTrunc(w * 57, 100);
        p.label(x, top, split - 9, 14, .regular, .left, fmt(&buf, "#{d}  {s}", .{ win.window_id, std.mem.sliceTo(&win.title, 0) }), theme.ink, theme.bg);
        const focus = win.window_id != 0 and win.window_id == t.windows.?.status.focused_window;
        const state = if (win.flags & a.window_service_flag_closing != 0) @as([]const u8, "Schließt") else if (win.flags & a.window_service_flag_minimized != 0) "Minimiert" else if (focus) "Fokus" else "Sichtbar";
        p.label(x + split, top, @divTrunc(w * 23, 100), 12, .regular, .left, state, if (focus) theme.accent else theme.sub, theme.bg);
        const last = @divTrunc(w * 80, 100);
        p.label(x + last, top, w - last, 12, .regular, .right, if (win.instance_id > 0) fmt(&buf, "Instanz {d}", .{win.instance_id}) else "Instanz –", theme.sub, theme.bg);
    }
}
fn programs(p: P, x: i32, y: i32, w: i32, t: *const Tasks) void {
    const rows = t.processes.items;
    var buf: [48]u8 = undefined;
    p.rule(x, y, w, theme.line);
    p.label(x, y + 14, w - 112, 18, .semibold, .left, "Programme", theme.ink, theme.bg);
    p.label(x + w - 112, y + 20, 112, 12, .regular, .right, if (rows.len == 1) "1 Instanz" else fmt(&buf, "{d} Instanzen", .{rows.len}), theme.sub, theme.bg);
    const compact = w < 490;
    const stops = if (compact) [_]i32{ 0, 16, 39, 60, 80, 92, 100 } else [_]i32{ 0, 15, 39, 58, 75, 91, 100 };
    p.rect(theme.box(x, y + 53, w, 25), theme.soft);
    const titles = [_][]const u8{ "R4X-ID", "Rolle", "Klasse", "Status", if (compact) "ID" else "Fenster", "Exit" };
    for (titles, 0..) |name, j| {
        const left = @divTrunc(w * stops[j], 100);
        p.label(x + left + 2, y + 59, @divTrunc(w * stops[j + 1], 100) - left - 3, 12, .regular, .left, name, theme.sub, theme.soft);
    }
    if (rows.len == 0) p.label(x + 2, y + 87, w - 4, 14, .regular, .left, if (t.current) "Keine Programme" else "Programmdaten nicht verfügbar", theme.sub, theme.bg);
    for (rows, 0..) |row, i| {
        const top = y + 87 + 33 * @as(i32, @intCast(i));
        if (top > p.canvas.h) break;
        if (top + 26 < 0) continue;
        const v = row.info;
        var fields: [3][32]u8 = undefined;
        const values = [_][]const u8{ fmt(&fields[0], "{d}", .{v.id}), tasks_model.role(v.role), tasks_model.class(v.app_class), tasks_model.state(v.state), if (v.window_id > 0) fmt(&fields[1], "{d}", .{v.window_id}) else "–", fmt(&fields[2], "{d}", .{v.exit_code}) };
        for (values, 0..) |value, j| {
            const start = @divTrunc(w * stops[j], 100);
            p.label(x + start + 2, top, @divTrunc(w * stops[j + 1], 100) - start - 4, if (compact) 12 else 13, if (j == 0 or j >= 4) .mono else .regular, .left, value, if (j == 3 and std.mem.eql(u8, value, "läuft")) theme.accent else theme.ink, theme.bg);
        }
        if (i + 1 < rows.len) p.rule(x, top + 24, w, theme.grid);
    }
    if (!t.current and rows.len > 0) p.label(x, y + 87 + 33 * @as(i32, @intCast(rows.len)), w, 12, .regular, .left, "Letzter vollständig gelesener Stand", theme.sub, theme.bg);
}
fn desktop(p: P, x: i32, y: i32, w: i32, t: *const Tasks) void {
    var buf: [100]u8 = undefined;
    p.rule(x, y, w, theme.line);
    p.label(x, y + 14, w, 18, .semibold, .left, "Desktop", theme.ink, theme.bg);
    if (t.render) |c| {
        const second = @divTrunc(w * 43, 100);
        p.label(x, y + 51, second - 8, 12, .regular, .left, "Neuzeichnungen", theme.sub, theme.bg);
        p.label(x + second, y + 51, w - second, 12, .regular, .left, "Vollbilder", theme.sub, theme.bg);
        p.label(x, y + 72, second - 8, 21, .mono, .left, fmt(&buf, "{d}", .{c.redraws}), theme.ink, theme.bg);
        p.label(x + second, y + 72, w - second, 21, .mono, .left, fmt(&buf, "{d}", .{c.full}), theme.ink, theme.bg);
        p.label(x, y + 105, w, 12, .regular, .left, fmt(&buf, "Letzter Bereich: {s}", .{damage(c.last_damage)}), theme.sub, theme.bg);
    } else p.label(x, y + 51, w, 14, .regular, .left, if (t.render_sampled) "Desktop-Renderdaten nicht verfügbar" else "Desktop-Daten werden geladen …", theme.sub, theme.bg);
}
fn session(p: P, x: i32, y: i32, w: i32, t: *const Tasks) void {
    var buf: [96]u8 = undefined;
    const s = t.status;
    const half = @divTrunc(w, 2);
    p.rule(x, y, w, theme.line);
    p.label(x, y + 12, half, 18, .semibold, .left, "Sitzung", theme.ink, theme.bg);
    p.label(x + half, y + 17, w - half, 12, .regular, .right, fmt(&buf, "{d} Instanzen", .{s.instance_count}), theme.sub, theme.bg);
    p.label(x, y + 42, half - 3, 12, .regular, .left, fmt(&buf, "Shell {s}", .{activity(s.shell_running)}), theme.ink, theme.bg);
    p.label(x + half, y + 42, w - half, 12, .regular, .left, fmt(&buf, "Vordergrund {s}", .{activity(s.foreground_running)}), theme.ink, theme.bg);
    p.label(x, y + 66, half - 3, 12, .regular, .left, if (s.display_used != 0) "Ausgabe: Framebuffer" else "Ausgabe: Konsole", theme.sub, theme.bg);
    p.label(x + half, y + 66, w - half, 12, .regular, .left, fmt(&buf, "Letzter Exit: {d}", .{s.last_exit_code}), theme.sub, theme.bg);
    if (t.render) |c| p.label(x, y + 93, w, 12, .regular, .left, fmt(&buf, "Cursor: {d} Bewegungen, {d} Ausgaben", .{ c.cursor_moves, c.cursor_presents }), theme.sub, theme.bg);
}
