const r = @import("r4os");
const hist = @import("history.zig");
const theme = @import("theme.zig");

fn submit(p: theme.Painter, area: r.gui.Rect, points: []const hist.Point, fill: bool) void {
    const shapes = r.gui_shapes;
    var bytes: [8192]u8 = undefined;
    var path = shapes.PathBuilder.init(&bytes, .{ .fill_argb = 0x2872dfbe, .stroke_argb = 0xff72dfbe, .stroke_width = 1.5, .line_join = .round, .line_cap = .round }) catch return;
    var first: usize = 0;
    while (first < points.len) {
        var end = first + 1;
        while (end < points.len and !points[end].starts) end += 1;
        const a = points[first];
        path.moveTo(.{ .x = @floatFromInt(a.x), .y = @floatFromInt(if (fill) area.h - 1 else a.y) }) catch return;
        for (points[if (fill) first else first + 1..end]) |pt| path.lineTo(.{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) }) catch return;
        if (fill) {
            path.lineTo(.{ .x = @floatFromInt(points[end - 1].x), .y = @floatFromInt(area.h - 1) }) catch return;
            path.close() catch return;
        }
        first = end;
    }
    const data = path.finish() catch return;
    const kind: u32 = if (fill) r.abi.gui_frame_command_kind_path_fill else r.abi.gui_frame_command_kind_path_stroke;
    const cmd = shapes.command(kind, area.x, area.y, @intCast(area.w), @intCast(area.h), 0, data.len) catch return;
    _ = p.canvas.frameCommand(cmd, data);
}

pub fn draw(p: theme.Painter, history: *const hist.History, x: i32, y: i32, w: i32) void {
    if (y + 104 <= 0 or y + 16 >= p.canvas.h or w < 68) return;
    p.label(x, y + 16, w - 50, 12, .regular, .left, "Letzte 60 s", theme.sub, theme.bg);
    p.label(x + w - 50, y + 16, 50, 12, .regular, .right, "Jetzt", theme.sub, theme.bg);
    p.label(x, y + 36, 30, 10, .mono, .right, "100 %", theme.sub, theme.bg);
    p.label(x, y + 90, 30, 10, .mono, .right, "0 %", theme.sub, theme.bg);
    const area = theme.box(x + 36, y + 38, w - 36, 63);
    for ([_]i32{ 2, 31, 62 }) |offset| p.rule(area.x, area.y + offset, area.w, theme.grid);
    if (area.y + area.h <= 0 or area.y >= p.canvas.h) return;
    var positions: [65]hist.Point = undefined;
    const points = history.points(area.w - 4, area.h - 3, &positions);
    if (points.len == 0) return;
    const inner = theme.box(area.x + 1, area.y + 2, area.w - 4, area.h - 2);
    if (points.len > 1) {
        submit(p, inner, points, true);
        submit(p, inner, points, false);
    }
    for (points, 0..) |pt, i| {
        if ((pt.starts and (i + 1 == points.len or points[i + 1].starts)) or (i + 1 == points.len and history.current)) {
            p.tile(theme.box(inner.x + pt.x - 2, inner.y + pt.y - 2, 5, 5), theme.accent);
        }
    }
}
