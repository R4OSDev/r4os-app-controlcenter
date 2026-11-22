// The CPU timeline is monotone in x. Rasterize each edge once on R4DRAW's
// four quarter-pixel samples and publish the translucent fill and the stroke.
const r = @import("r4os");
const hist = @import("history.zig");
const theme = @import("theme.zig");
const column_limit = 128;
pub const plot_height = 63;
const fill_opacity = 40;
const samples = [_][2]i32{ .{ 1, 1 }, .{ 3, 1 }, .{ 1, 3 }, .{ 3, 3 } };

const Edge = struct {
    dx: i64,
    dy: i64,
    squared: i64,

    fn init(a: hist.Point, b: hist.Point) Edge {
        const dx: i64 = b.x - a.x;
        const dy: i64 = b.y - a.y;
        return .{ .dx = dx, .dy = dy, .squared = dx * dx + dy * dy };
    }

    // A segment with round joins and caps is the set of points within
    // three quarters of a pixel of its finite centerline.
    fn stroke(self: Edge, qx: i64, qy: i64) bool {
        const dot = qx * self.dx + qy * self.dy;
        if (dot <= 0) return qx * qx + qy * qy <= 9;
        if (dot >= 4 * self.squared) {
            const x = qx - 4 * self.dx;
            const y = qy - 4 * self.dy;
            return x * x + y * y <= 9;
        }
        const cross = qy * self.dx - qx * self.dy;
        return cross * cross <= 9 * self.squared;
    }

    fn filled(self: Edge, qx: i64, qy: i64) bool {
        const cross = qy * self.dx - qx * self.dy;
        // Use the same half-open edge convention as native path filling.
        return cross > 0 or (cross == 0 and self.dy < 0);
    }
};

fn coverage(mask: u8) u8 {
    return @intCast((@as(u16, @popCount(mask)) * 255 + 2) / 4);
}

fn tile(canvas: r.gui.Canvas, area: r.gui.Rect, points: []const hist.Point, left: i32, right: i32) void {
    // Keep transparent rows above this tile out of the frame payload.
    var top = area.h;
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        if (!b.starts and a.x - 1 < right and b.x + 1 > left) top = @min(top, @min(a.y, b.y) - 1);
    }
    top = @max(top, @max(0, -area.y));
    const bottom = @min(area.h, canvas.h - area.y);
    if (top >= bottom) return;
    const width: usize = @intCast(right - left);
    const length = width * @as(usize, @intCast(bottom - top));
    var fill: [column_limit * plot_height]u8 = undefined;
    var line: [column_limit * plot_height]u8 = undefined;
    @memset(fill[0..length], 0);
    @memset(line[0..length], 0);
    for (points[0 .. points.len - 1], points[1..]) |a, b| {
        if (b.starts) continue;
        const edge = Edge.init(a, b);
        var x = @max(left, a.x - 1);
        const stop = @min(right, b.x + 1);
        const stroke_bottom = @min(bottom, @max(a.y, b.y) + 1);
        while (x < stop) : (x += 1) {
            const inside = x >= a.x and x < b.x;
            var y = @max(top, @min(a.y, b.y) - 1);
            const column: usize = @intCast(x - left);
            while (y < stroke_bottom) : (y += 1) {
                const index = @as(usize, @intCast(y - top)) * width + column;
                var fill_mask: u8 = 0;
                for (samples, 0..) |s, i| {
                    const qx: i64 = (x - a.x) * 4 + s[0];
                    const qy: i64 = (y - a.y) * 4 + s[1];
                    const bit = @as(u8, 1) << @as(u3, @intCast(i));
                    if (edge.stroke(qx, qy)) line[index] |= bit;
                    if (inside and y < area.h - 1 and edge.filled(qx, qy)) fill_mask |= bit;
                }
                if (inside) fill[index] = @intCast((@as(u16, coverage(fill_mask)) * fill_opacity + 127) / 255);
            }
            if (inside) {
                while (y < @min(bottom, area.h - 1)) : (y += 1) {
                    fill[@as(usize, @intCast(y - top)) * width + column] = fill_opacity;
                }
            }
        }
    }
    for (line[0..length]) |*v| v.* = coverage(v.*);
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(bottom - top);
    _ = canvas.blendAlpha8(area.x + left, area.y + top, w, h, w, theme.accent, fill[0..length]);
    _ = canvas.blendAlpha8(area.x + left, area.y + top, w, h, w, theme.accent, line[0..length]);
}

pub fn paint(canvas: r.gui.Canvas, area: r.gui.Rect, points: []const hist.Point) void {
    if (points.len < 2 or area.h > plot_height) return;
    var left: i32 = @max(0, points[0].x - 1);
    const limit = @min(area.w, points[points.len - 1].x + 1);
    while (left < limit) {
        const right = @min(left + column_limit, limit);
        tile(canvas, area, points, left, right);
        left = right;
    }
}
