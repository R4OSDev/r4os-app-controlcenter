const r = @import("r4os");
const std = @import("std");
const hist = @import("history.zig");
const theme = @import("theme.zig");
const curve_mask = @import("curve_mask.zig");

fn plot(x: i32, y: i32, w: i32) r.gui.Rect {
    return theme.box(x + 37, y + 40, w - 40, curve_mask.plot_height - 2);
}

pub fn damage(before: *const hist.History, after: *const hist.History, x: i32, y: i32, w: i32, client_h: i32) ?r.gui.Rect {
    const inner = plot(x, y, w);
    if (w < 68 or inner.y - 2 >= client_h or inner.y + inner.h + 2 <= 0) return null;
    var old_buf: [65]hist.Point = undefined;
    var new_buf: [65]hist.Point = undefined;
    const old = before.points(inner.w, inner.h - 1, &old_buf);
    const new = after.points(inner.w, inner.h - 1, &new_buf);
    if (old.len == new.len and before.current == after.current) {
        for (old, new) |a, b| {
            if (!std.meta.eql(a, b)) break;
        } else return null;
    }
    // Restore the previous line as well as drawing the new one. Fill runs to
    // the baseline, and either timeline can have an endpoint two pixels wide.
    var left = inner.w;
    var right: i32 = -1;
    var top = inner.h;
    for ([_][]const hist.Point{ old, new }) |points| {
        if (points.len == 0) continue;
        left = @min(left, points[0].x);
        right = @max(right, points[points.len - 1].x);
        for (points) |p| top = @min(top, p.y);
    }
    if (right < left) return null;
    return theme.box(inner.x + left - 2, inner.y + top - 2, right - left + 5, inner.h - top + 4);
}

pub fn draw(p: theme.Painter, history: *const hist.History, x: i32, y: i32, w: i32) void {
    if (y + 104 <= 0 or y + 16 >= p.canvas.h or w < 68) return;
    p.label(x, y + 16, w - 50, 12, .regular, .left, "Letzte 60 s", theme.sub, theme.bg);
    p.label(x + w - 50, y + 16, 50, 12, .regular, .right, "Jetzt", theme.sub, theme.bg);
    p.label(x, y + 36, 30, 10, .mono, .right, "100 %", theme.sub, theme.bg);
    p.label(x, y + 90, 30, 10, .mono, .right, "0 %", theme.sub, theme.bg);
    const area = theme.box(x + 36, y + 38, w - 36, curve_mask.plot_height);
    for ([_]i32{ 2, 31, 62 }) |offset| p.rule(area.x, area.y + offset, area.w, theme.grid);
    if (area.y + area.h <= 0 or area.y >= p.canvas.h) return;
    var positions: [65]hist.Point = undefined;
    const inner = plot(x, y, w);
    const points = history.points(inner.w, inner.h - 1, &positions);
    if (points.len == 0) return;
    curve_mask.paint(p.canvas, inner, points);
    for (points, 0..) |pt, i| {
        if ((pt.starts and (i + 1 == points.len or points[i + 1].starts)) or (i + 1 == points.len and history.current)) {
            p.tile(theme.box(inner.x + pt.x - 2, inner.y + pt.y - 2, 5, 5), theme.accent);
        }
    }
}
