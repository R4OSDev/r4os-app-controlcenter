const std = @import("std");
const theme = @import("theme.zig");
const ram = @import("ram.zig");
const traffic = @import("traffic.zig");
const meters = @import("meters.zig");
const Painter = theme.Painter;
const fmt = theme.fmt;

pub const ram_height = 95;
pub const net_row = 52;
pub const disk_row = 26;
pub fn networkHeight(count: usize) i32 {
    return 67 + net_row * @as(i32, @intCast(@max(1, count)));
}
pub fn diskHeight(count: usize) i32 {
    return 73 + disk_row * @as(i32, @intCast(@max(1, count)));
}

pub fn memory(p: Painter, x: i32, y: i32, w: i32, summary: i32, reading: ?ram.Belegung, bandwidth: ?traffic.Display) void {
    const start = x + summary;
    const width = w - summary;
    var buf: [84]u8 = undefined;
    p.rule(x, y, w, theme.line);
    p.label(x, y + 12, summary - 5, 17, .semibold, .left, "RAM", theme.ink, theme.bg);
    p.label(x, y + 38, summary - 5, 12, .regular, .left, "Durchsatz", theme.sub, theme.bg);
    p.label(x, y + 56, summary - 5, 13, .mono, .left, if (bandwidth) |b| b.text(&buf) else "k. A.", theme.ink, theme.bg);
    const outline = 0x52686f;
    p.rule(start, y + 45, width, outline);
    p.rule(start, y + 54, width, outline);
    p.rect(theme.box(start, y + 46, 1, 8), outline);
    p.rect(theme.box(start + width - 1, y + 46, 1, 8), outline);
    var number: [36]u8 = undefined;
    var percent: []const u8 = "–";
    var color: u32 = theme.sub;
    if (reading) |m| {
        color = ram.fillColor(m.percent());
        p.rect(theme.box(start + 1, y + 46, ram.fillWidth(width - 2, m.basis_points), 8), color);
        percent = if (m.basis_points > 0 and m.percent() == 0) "<1 %" else fmt(&number, "{d} %", .{m.percent()});
    }
    p.label(start, y + 14, width, 18, .mono, .right, percent, color, theme.bg);
    var amount: [42]u8 = undefined;
    const used = ram.amount(&amount, if (reading) |m| m.used_tenths else null);
    p.label(start, y + 18, width - 67, 14, .semibold, .left, fmt(&buf, "{s} belegt", .{used}), theme.ink, theme.bg);
    const free = ram.amount(&amount, if (reading) |m| m.total_tenths - m.used_tenths else null);
    const half = @divTrunc(width, 2);
    p.label(start, y + 62, half, 12, .regular, .left, fmt(&buf, "{s} frei", .{free}), theme.sub, theme.bg);
    const total = ram.amount(&amount, if (reading) |m| m.total_tenths else null);
    p.label(start + half, y + 62, width - half, 12, .regular, .right, fmt(&buf, "{s} gesamt", .{total}), theme.sub, theme.bg);
}

fn linkRate(out: []u8, bps: u64) []const u8 {
    if (bps >= 1_000_000_000 and bps % 1_000_000_000 == 0) return fmt(out, "{d} Gbit/s", .{bps / 1_000_000_000});
    if (bps >= 1_000_000 and bps % 1_000_000 == 0) return fmt(out, "{d} Mbit/s", .{bps / 1_000_000});
    return fmt(out, "{d} bit/s", .{bps});
}
fn link(out: []u8, sample: meters.Network.Sample) []const u8 {
    if (sample.link != 2) return if (sample.link == 1) "Getrennt" else "Link unbekannt";
    var a: [28]u8 = undefined;
    var b: [28]u8 = undefined;
    if (sample.rx_bps == sample.tx_bps) {
        return if (sample.rx_bps == 0) "Verbunden" else fmt(out, "Verbunden · {s}", .{linkRate(&a, sample.rx_bps)});
    }
    return fmt(out, "RX {s} · TX {s}", .{ if (sample.rx_bps > 0) linkRate(&a, sample.rx_bps) else "–", if (sample.tx_bps > 0) linkRate(&b, sample.tx_bps) else "–" });
}
fn rate(p: Painter, x: i32, y: i32, w: i32, value: ?meters.Rate, percent: ?u32) void {
    var buf: [40]u8 = undefined;
    p.label(x, y, w, 14, .mono, .left, if (value != null) meters.Rate.write(value, &buf) else "–", theme.ink, theme.bg);
    if (percent) |v| {
        const text = if (v == 0 and value != null and value.?.tenths > 0) "<1 %" else fmt(&buf, "{d} %", .{v});
        p.label(x, y + 21, w, 12, .mono, .left, text, theme.accent, theme.bg);
    }
}
pub fn network(p: Painter, x: i32, y: i32, w: i32, meter: *const meters.Meter(meters.Network)) void {
    const items = meter.rows.items;
    var buf: [132]u8 = undefined;
    p.rule(x, y, w, theme.line);
    p.label(x, y + 12, 116, 17, .semibold, .left, "Netzwerk", theme.ink, theme.bg);
    const summary = if (items.len == 1) link(&buf, items[0].sample) else fmt(&buf, "{d} Adapter", .{items.len});
    p.label(x + 121, y + 18, w - 121, 12, .regular, .right, summary, theme.sub, theme.bg);
    const rx = @divTrunc(w * 39, 100);
    const tx = @divTrunc(w * 72, 100);
    p.label(x + 4, y + 46, rx - 8, 12, .regular, .left, "Adapter", theme.sub, theme.bg);
    p.label(x + rx, y + 46, tx - rx - 6, 12, .regular, .left, "Empfang", theme.sub, theme.bg);
    p.label(x + tx, y + 46, w - tx, 12, .regular, .left, "Senden", theme.sub, theme.bg);
    if (items.len == 0) p.label(x + 4, y + 69, w - 5, 14, .regular, .left, if (meter.available) "Kein Adapter" else "Nicht verfügbar", theme.sub, theme.bg);
    for (items, 0..) |row, i| {
        const top = y + 69 + @as(i32, @intCast(i)) * net_row;
        if (top > p.canvas.h) break;
        if (top + net_row < 0) continue;
        const id = fmt(&buf, "{s} #{d}", .{ std.mem.sliceTo(&row.sample.name, 0), row.sample.interface_id });
        p.label(x + 4, top, rx - 8, 14, .mono, .left, id, theme.ink, theme.bg);
        if (items.len > 1) p.label(x + 4, top + 21, rx - 8, 12, .regular, .left, link(&buf, row.sample), theme.sub, theme.bg);
        rate(p, x + rx, top, tx - rx - 5, row.values.first, row.values.first_pct);
        rate(p, x + tx, top, w - tx, row.values.second, row.values.second_pct);
    }
}

pub fn disks(p: Painter, x: i32, y: i32, w: i32, meter: *const meters.Meter(meters.Disk)) void {
    const rows = meter.rows.items;
    var buf: [132]u8 = undefined;
    p.rule(x, y, w, theme.line);
    p.label(x, y + 11, 160, 17, .semibold, .left, "Datenträger", theme.ink, theme.bg);
    p.label(x + 164, y + 16, w - 164, 12, .regular, .right, if (rows.len == 1) "1 Gerät" else fmt(&buf, "{d} Geräte", .{rows.len}), theme.sub, theme.bg);
    const cols = [_]i32{ 4, @divTrunc(w * 32, 100), @divTrunc(w * 565, 1000), @divTrunc(w * 84, 100), w };
    for ([_][]const u8{ "Gerät", "Lesen", "Schreiben", "Aktiv" }, 0..) |name, i| p.label(x + cols[i], y + 41, cols[i + 1] - cols[i] - 3, 12, .regular, .left, name, theme.sub, theme.bg);
    if (rows.len == 0) p.label(x + 4, y + 65, w - 5, 14, .regular, .left, if (meter.available) "Kein Datenträger" else "Nicht verfügbar", theme.sub, theme.bg);
    for (rows, 0..) |row, i| {
        const top = y + 65 + @as(i32, @intCast(i)) * disk_row;
        if (top - 4 >= p.canvas.h) break;
        if (top + disk_row <= 0) continue;
        const model = std.mem.sliceTo(&row.sample.model, 0);
        const name = fmt(&buf, "#{d} {s}", .{ row.sample.slot, if (model.len > 0) model else std.mem.sliceTo(&row.sample.name, 0) });
        p.rule(x, top - 4, w, theme.grid);
        p.label(x + cols[0], top, cols[1] - cols[0] - 5, 14, .mono, .left, name, theme.ink, theme.bg);
        rate(p, x + cols[1], top, cols[2] - cols[1] - 5, row.values.first, null);
        rate(p, x + cols[2], top, cols[3] - cols[2] - 5, row.values.second, null);
        p.label(x + cols[3], top, w - cols[3], 14, .mono, .left, if (row.values.active_pct) |v| fmt(&buf, "{d} %", .{v}) else "–", theme.accent, theme.bg);
    }
}
