const std = @import("std");
const meters = @import("meters.zig");
const r4os = @import("r4os");

const gui = r4os.gui;
const Traffic = @import("traffic.zig").Traffic;
const ram = @import("ram.zig");
const Usage = @import("usage.zig").Usage;
const Tasks = @import("tasks.zig").Tasks;
const TaskView = @import("task_view.zig").View;
const Scroll = @import("scroll.zig").Scroll;
const Rect = gui.Rect;
const Canvas = gui.Canvas;
const Tab = enum { usage, tasks };
const row_height = 72;
const sidebar = 112;
const summary_width = 110;
const paper = 0xffffff;
const ink = 0x17212b;
const line = 0x778895;
const selected = 0x0079a6;
const face = 0xe8ecee;

pub fn r4_app_main(api: *r4os.App2) i32 {
    var timers = [_]r4os.Timer{.{}};
    var window = api.window(&timers) orelse return r4os.abi.err_no_group;
    const allocator = api.allocator() orelse return r4os.abi.err_no_group;
    var app = App{ .api = api, .window = &window, .timer = &timers[0], .allocator = allocator, .fonts = gui.FontSet.system(&window.draw) };
    defer app.traffic.release(api);
    defer app.tasks.deinit(allocator);
    defer app.usage.deinit(allocator);
    defer app.network.deinit(allocator);
    return app.run();
}

fn box(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn navRect(tab: Tab) Rect {
    return box(5, if (tab == .usage) 7 else 39, sidebar - 10, 29);
}

fn tabAt(x: i32, y: i32) ?Tab {
    for ([_]Tab{ .usage, .tasks }) |tab| {
        if (navRect(tab).contains(x, y)) return tab;
    }
    return null;
}

fn label(canvas: Canvas, area: Rect, value: []const u8, alignment: gui.Align, fg: u32, bg: u32) void {
    if (area.y + area.h <= 0 or area.y >= canvas.h) return;
    var scratch: [160]u8 = undefined;
    _ = canvas.label(.{ .rect = area, .text = value, .alignment = alignment, .fg = fg, .bg = bg }, &scratch);
}

fn cell(canvas: Canvas, area: Rect, bg: u32) void {
    _ = canvas.rect(area, line);
    _ = canvas.rect(area.inset(1, 1), bg);
}

const App = struct {
    api: *r4os.App2,
    window: *r4os.Window,
    timer: *r4os.Timer,
    allocator: @import("std").mem.Allocator,
    usage: Usage = .{},
    network: meters.Meter(meters.Network) = .{},
    client_w: i32 = 0,
    client_h: i32 = 0,
    memory: ?ram.Belegung = null,
    traffic: Traffic = .{},
    bar_caption: ram.Caption = .{},
    tasks: Tasks = .{},
    task_view: TaskView = .{},
    usage_scroll: Scroll = .{ .stride = 18 },
    focused: bool = true,
    fonts: gui.FontSet,
    tab: Tab = .usage,
    pressed: ?Tab = null,

    fn run(self: *App) i32 {
        _ = self.window.setTitle("Control Center");
        _ = self.window.setMinimumSize(558, 172);
        self.updateTimer();
        while (!self.window.sys.programShouldClose()) {
            switch (self.window.waitMessage(r4os.time_contract.timeoutForever())) {
                .message => |message| switch (message) {
                    .close => return 0,
                    .resize => self.paint(),
                    .font_changed => {
                        self.fonts = gui.FontSet.system(&self.window.draw);
                        self.paint();
                    },
                    .focus_gained => {
                        if (!self.focused) {
                            self.focused = true;
                            self.updateTimer();
                        }
                    },
                    .focus_lost => {
                        self.traffic.release(self.api);
                        self.focused = false;
                        self.timer.cancel();
                        self.pressed = null;
                        self.scroller().thumb_y = null;
                    },
                    .input_reset => {
                        self.pressed = null;
                        self.scroller().thumb_y = null;
                    },
                    .timer => {
                        if (self.focused) self.refresh(false);
                    },
                    .wheel => |wheel| {
                        if (wheel.x >= sidebar and wheel.delta != 0)
                            self.scrollKey(if (wheel.delta > 0) gui.Key.up else gui.Key.down);
                    },
                    .mouse => |mouse| switch (mouse.action) {
                        .down => {
                            self.pressed = tabAt(mouse.x, mouse.y);
                            if (self.pressed == null and self.scroller().bar.rect.contains(mouse.x, mouse.y)) {
                                const old = self.scroller().first;
                                self.scroller().mouseDown(mouse.x, mouse.y);
                                if (old != self.scroller().first) self.paint();
                            }
                        },
                        .up => {
                            const tab = tabAt(mouse.x, mouse.y);
                            if (tab != null and tab == self.pressed) self.select(tab.?);
                            self.pressed = null;
                            self.scroller().thumb_y = null;
                        },
                        .move => if (self.scroller().thumb_y != null) {
                            const old = self.scroller().first;
                            self.scroller().drag(mouse.y);
                            if (old != self.scroller().first) self.paint();
                        },
                    },
                    .key => |key| switch (key.key) {
                        gui.Key.tab, gui.Key.shift_tab => self.select(if (self.tab == .usage) .tasks else .usage),
                        gui.Key.left => self.select(.usage),
                        gui.Key.right => self.select(.tasks),
                        gui.Key.up, gui.Key.down, gui.Key.home, gui.Key.end, gui.Key.page_up, gui.Key.page_down => {
                            self.scrollKey(key.key);
                        },
                        else => {},
                    },
                    else => {},
                },
                .failure => |err| return err,
                .timed_out => {},
            }
        }
        return 0;
    }

    fn scroller(self: *App) *Scroll {
        return if (self.tab == .usage) &self.usage_scroll else &self.task_view.scroll;
    }

    fn scrollKey(self: *App, key: u8) void {
        const scroll = self.scroller();
        const old = scroll.first;
        scroll.key(key);
        if (old != scroll.first) self.paint();
    }

    fn select(self: *App, tab: Tab) void {
        if (self.tab == tab) return;
        if (self.tab == .usage) self.traffic.release(self.api);
        self.scroller().thumb_y = null;
        self.tab = tab;
        self.updateTimer();
    }

    fn refresh(self: *App, force: bool) void {
        if (self.tab == .usage) {
            const changed = self.usage.refresh(self.api, self.allocator);
            const latest = ram.Belegung.read(self.api);
            const memory_changed = !@import("std").meta.eql(self.memory, latest);
            self.memory = latest;
            const traffic_changed = self.traffic.refresh(self.api);
            self.network.refresh(self.api, self.allocator);
            if (force or self.network.layout_changed or self.client_h == 0) {
                self.paint();
            } else {
                self.paintChanges(changed, memory_changed or traffic_changed);
            }
        } else {
            self.tasks.refresh(self.api, self.allocator);
            self.paint();
        }
    }

    fn updateTimer(self: *App) void {
        self.timer.cancel();
        self.usage.reset();
        self.network.fresh = true;
        if (!self.focused) return;
        self.refresh(true);
        _ = self.timer.start(&self.window.sys, r4os.TimerId.init(1), .{ .nanoseconds = 1_000_000_000 }, true);
    }

    fn percentText(value: ?u8, buf: *[5]u8) [:0]const u8 {
        return if (value) |v| @import("std").fmt.bufPrintZ(buf, "{d}%", .{v}) catch "--" else "--";
    }

    const Layout = struct {
        columns: i32,
        rows: i32,
        tile_w: i32,
        cpu_h: i32,
        content_h: i32,
    };

    fn sectionHeight(count: usize) i32 {
        return @as(i32, @intCast(@max(1, count))) * row_height;
    }

    fn layout(self: *const App, client_w: i32) Layout {
        const width = @max(1, client_w - sidebar - summary_width - 8);
        const n: i32 = @intCast(self.usage.cores.items.len);
        const columns = @max(1, @min(@divTrunc(width, 48), @divTrunc(n + 1, 2)));
        const rows = @max(1, @divTrunc(n + columns - 1, columns));
        const note_h: i32 = if (self.usage.unknown_topology) 22 else 0;
        const cpu_h = @max(98, rows * 45 + note_h + 8);
        return .{
            .columns = columns,
            .rows = rows,
            .tile_w = @min(52, @divTrunc(width, columns)),
            .cpu_h = cpu_h,
            .content_h = cpu_h + 124 + sectionHeight(self.network.rows.items.len),
        };
    }

    fn paintUsage(self: *App, frame_canvas: Canvas) void {
        var canvas = frame_canvas;
        var layout_ = self.layout(canvas.w);
        const overflow = layout_.content_h > canvas.h;
        if (overflow) {
            canvas.w -= 17;
            layout_ = self.layout(canvas.w);
        }
        self.usage_scroll.layout(if (overflow) box(canvas.w + 1, 0, 15, canvas.h) else .{}, @intCast(layout_.content_h), @intCast(canvas.h));
        const top = -@as(i32, @intCast(self.usage_scroll.first));
        if (top + layout_.cpu_h >= 0) self.paintCpu(canvas, layout_, top);
        const ram_top = top + layout_.cpu_h;
        if (ram_top < canvas.h and ram_top + 124 > 0) self.paintRam(canvas, ram_top);
        self.paintNetwork(canvas, ram_top + 124);
        if (overflow) {
            var scratch: [20]u8 = undefined;
            _ = self.usage_scroll.bar.draw(frame_canvas, &scratch);
        }
    }

    fn paintCpu(self: *App, canvas: Canvas, geometry: Layout, y: i32) void {
        const x = sidebar + summary_width;
        const width = canvas.w - x - 8;
        const n = self.usage.cores.items.len;
        const columns = geometry.columns;
        const rows = geometry.rows;
        const tile_w = geometry.tile_w;
        const tile_h = 45;
        const height = geometry.cpu_h;
        _ = canvas.rect(box(sidebar, y + height, canvas.w - sidebar, 1), line);
        _ = canvas.rect(box(x - 1, y, 1, height), line);
        label(canvas, box(sidebar + 8, y + 4, summary_width - 16, 23), "CPU", .left, ink, paper);
        var buf: [5]u8 = undefined;
        const caption = percentText(self.usage.percent, &buf);
        const summary = box(sidebar + 3, y + 25, summary_width - 6, 65);
        const display = canvas.withFontId(self.fonts.display);
        const large = if (display.textWidthZ(caption.ptr) + 4 <= summary.w) display else canvas.withFontId(self.fonts.heading);
        label(large, summary, caption, .center, ink, paper);
        for (self.usage.cores.items, 0..) |core, index| {
            const i: i32 = @intCast(index);
            const area = box(x + 5 + @mod(i, columns) * tile_w, y + 5 + @divTrunc(i, columns) * tile_h, tile_w - 4, tile_h - 4);
            if (area.y >= canvas.h or area.y + area.h <= 0) continue;
            cell(canvas, area, paper);
            if (area.h < 10) continue;
            label(canvas.withFontId(r4os.abi.gui_font_builtin_id), area.inset(1, 1), percentText(core.percent, &buf), .center, ink, paper);
        }
        if (self.usage.unknown_topology or n == 0) {
            const message = if (self.usage.unknown_topology) "Kernzuordnung unbekannt" else "Keine CPU-Zeitdaten";
            label(canvas, box(x + 6, y + (if (n == 0) @as(i32, 8) else rows * tile_h + 5), width, 23), message, .left, ink, paper);
        }
    }

    fn paintRam(self: *App, canvas: Canvas, y: i32) void {
        const x = sidebar + summary_width;
        const left = sidebar + 8;
        const narrow = summary_width - 16;
        _ = canvas.rect(box(x - 1, y + 1, 1, 122), line);
        label(canvas, box(left, y + 6, narrow, 23), "RAM", .left, ink, paper);
        label(canvas.withFontId(r4os.abi.gui_font_builtin_id), box(left, y + 34, narrow, 21), "Durchsatz", .left, ink, paper);
        if (self.traffic.display) |rate| {
            var buf: [24]u8 = undefined;
            label(canvas.withFontId(r4os.abi.gui_font_builtin_id), box(left, y + 54, narrow, 23), rate.text(&buf), .left, ink, paper);
        } else {
            _ = canvas.rect(box(left + 2, y + 65, 10, 1), ink);
        }

        const bar = box(x + 12, y + 12, canvas.w - x - 26, 29);
        if (bar.w < 3) return;
        _ = canvas.rect(box(bar.x, bar.y, bar.w, 1), line);
        _ = canvas.rect(box(bar.x, bar.y + bar.h - 1, bar.w, 1), line);
        _ = canvas.rect(box(bar.x, bar.y + 1, 1, bar.h - 2), line);
        _ = canvas.rect(box(bar.x + bar.w - 1, bar.y + 1, 1, bar.h - 2), line);
        const inner = bar.inset(1, 1);
        if (self.memory) |m| {
            _ = canvas.rect(box(inner.x, inner.y, ram.fillWidth(inner.w, m.basis_points), inner.h), ram.fillColor(m.percent()));
        }
        self.bar_caption.draw(canvas, inner, self.memory, ink);
        const names = [_][]const u8{ "Belegt", "Frei", "Gesamt" };
        const values: [3]?u64 = if (self.memory) |m| .{ m.used_tenths, m.total_tenths - m.used_tenths, m.total_tenths } else @splat(null);
        for (names, values, 0..) |name, value, i| {
            const row = y + 49 + @as(i32, @intCast(i)) * 22;
            var buf: [36]u8 = undefined;
            label(canvas, box(bar.x, row, 74, 21), name, .left, ink, paper);
            if (value != null) {
                label(canvas, box(bar.x + 78, row, bar.w - 78, 21), ram.amount(&buf, value), .left, ink, paper);
            } else {
                _ = canvas.rect(box(bar.x + 80, row + 10, 10, 1), ink);
            }
        }
    }

    fn deviceHeader(self: *App, c: Canvas, y: i32, section: []const u8, first: bool, name: []const u8, status: []const u8) void {
        const x = sidebar + summary_width;
        _ = c.rect(box(sidebar, y, c.w - sidebar, 1), line);
        _ = c.rect(box(x - 1, y, 1, row_height), line);
        if (first) label(c, box(sidebar + 8, y + 3, summary_width - 14, 24), section, .left, ink, paper);
        const small = c.withFontId(r4os.abi.gui_font_builtin_id);
        const status_w = if (status.len == 0) @as(i32, 0) else @as(i32, @intCast(status.len)) * 8 + 8;
        label(c.withFontId(self.fonts.body), box(x + 8, y + 3, c.w - x - 16 - status_w, 22), name, .left, ink, paper);
        label(small, box(c.w - 8 - status_w, y + 3, status_w, 22), status, .right, ink, paper);
    }

    fn deviceRate(c: Canvas, y: i32, name: []const u8, rate: ?meters.Rate, percent: ?u32) void {
        const x = sidebar + summary_width + 8;
        const small = c.withFontId(r4os.abi.gui_font_builtin_id);
        var buf: [32]u8 = undefined;
        label(small, box(x, y, 80, 19), name, .left, ink, paper);
        label(small, box(x + 84, y, c.w - x - 150, 19), meters.Rate.write(rate, &buf), .left, ink, paper);
        if (percent) |v| {
            const text = if (v == 0 and rate != null and rate.?.tenths != 0) "<1 %" else std.fmt.bufPrint(&buf, "{d} %", .{v}) catch "--";
            label(small, box(c.w - 72, y, 64, 19), text, .right, ink, paper);
        }
    }

    fn paintNetwork(self: *App, c: Canvas, top: i32) void {
        if (self.network.rows.items.len == 0 and top < c.h and top + row_height > 0)
            self.deviceHeader(c, top, "Netzwerk", true, if (self.network.available) "Kein Adapter" else "Nicht verfügbar", "");
        for (self.network.rows.items, 0..) |row, i| {
            const y = top + @as(i32, @intCast(i)) * row_height;
            if (y >= c.h) break;
            if (y + row_height <= 0) continue;
            const sample = row.sample;
            var buf: [72]u8 = undefined;
            const name = std.fmt.bufPrint(&buf, "{s}  #{d}", .{ std.mem.sliceTo(&sample.name, 0), sample.interface_id }) catch "Adapter";
            self.deviceHeader(c, y, "Netzwerk", i == 0, name, switch (sample.link) {
                1 => "Getrennt",
                2 => "Verbunden",
                else => "Link unbekannt",
            });
            deviceRate(c, y + 25, "Empfang", row.values.first, row.values.first_pct);
            deviceRate(c, y + 46, "Senden", row.values.second, row.values.second_pct);
        }
    }

    const Damage = struct {
        lo: i32,
        hi: i32 = 0,
        fn add(self: *Damage, top: i32, bottom: i32, h: i32) void {
            if (top >= h or bottom <= 0) return;
            self.lo = @min(self.lo, @max(0, top));
            self.hi = @max(self.hi, @min(h, bottom));
        }
    };
    fn paintChanges(self: *App, cpu: bool, memory: bool) void {
        const g = self.layout(if (self.usage_scroll.bar.maxFirst() != 0) self.client_w - 17 else self.client_w);
        const top = -@as(i32, @intCast(self.usage_scroll.first));
        var damage = Damage{ .lo = self.client_h };
        if (cpu) damage.add(top, top + g.cpu_h + 1, self.client_h);
        if (memory) damage.add(top + g.cpu_h, top + g.cpu_h + 124, self.client_h);
        const network_top = top + g.cpu_h + 124;
        for (self.network.rows.items, 0..) |row, i| {
            if (row.changed) {
                const y = network_top + @as(i32, @intCast(i)) * row_height;
                damage.add(y, y + row_height, self.client_h);
            }
        }
        if (damage.hi > damage.lo) self.paintRegion(.{ .x = sidebar, .y = damage.lo, .w = @intCast(self.client_w - sidebar), .h = @intCast(damage.hi - damage.lo) });
    }

    fn paint(self: *App) void {
        self.paintRegion(null);
    }

    fn paintRegion(self: *App, region: ?r4os.abi.DisplayDamageRect) void {
        const open = if (region) |area| switch (self.window.beginPaintReplace(self.client_w, self.client_h, &.{area})) {
            .paint => |frame| @as(@TypeOf(self.window.beginPaint()), .{ .paint = frame }),
            .failure => self.window.beginPaint(),
        } else self.window.beginPaint();
        var frame = switch (open) {
            .paint => |value| value,
            .failure => return,
        };
        defer frame.discard();
        const canvas = frame.canvas.withFontId(self.fonts.body);
        self.client_w = canvas.w;
        self.client_h = canvas.h;
        _ = canvas.clear(paper);
        _ = canvas.rect(box(0, 0, sidebar, canvas.h), face);
        _ = canvas.rect(box(sidebar - 1, 0, 1, canvas.h), line);
        for ([_]Tab{ .usage, .tasks }) |tab| {
            const area = navRect(tab);
            const bg: u32 = if (tab == self.tab) selected else face;
            cell(canvas, area, bg);
            label(frame.canvas.withFontId(r4os.abi.gui_font_builtin_id), area.inset(2, 1), if (tab == .usage) "Auslastung" else "Tasks", .center, if (tab == self.tab) paper else ink, bg);
        }
        if (self.tab == .usage) {
            self.paintUsage(canvas);
        } else {
            self.task_view.paint(frame.canvas.withFontId(r4os.abi.gui_font_builtin_id), sidebar, &self.tasks);
        }
        _ = frame.present();
    }
};
