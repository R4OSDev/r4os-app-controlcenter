const std = @import("std");
const meters = @import("meters.zig");
const r4os = @import("r4os");

const gui = r4os.gui;
const Traffic = @import("traffic.zig").Traffic;
const ram = @import("ram.zig");
const chart = @import("chart.zig");
const History = @import("history.zig").History;
const Usage = @import("usage.zig").Usage;
const Tasks = @import("tasks.zig").Tasks;
const TaskView = @import("task_view.zig").View;
const resources = @import("resources.zig");
const theme = @import("theme.zig");
const Text = @import("typography.zig").Text;
const Scroll = @import("scroll.zig").Scroll;
const Rect = gui.Rect;
const Canvas = gui.Canvas;
const Tab = enum { usage, tasks };

const paper = theme.bg;
const ink = theme.ink;
const line = theme.line;

pub fn r4_app_main(api: *r4os.App2) i32 {
    var timers = [_]r4os.Timer{.{}};
    var window = api.window(&timers) orelse return r4os.abi.err_no_group;
    const allocator = api.allocator() orelse return r4os.abi.err_no_group;
    var text = Text.init(api, &window, allocator);
    defer text.deinit();
    var app = App{ .text = &text, .api = api, .window = &window, .timer = &timers[0], .allocator = allocator };
    defer app.traffic.release(api);
    defer app.tasks.deinit(allocator);
    defer app.usage.deinit(allocator);
    defer app.network.deinit(allocator);
    defer app.disks.deinit(allocator);
    return app.run();
}

fn box(x: i32, y: i32, w: i32, h: i32) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h };
}

fn navRect(width: i32, tab: Tab) Rect {
    return box(7, if (tab == .usage) 19 else 62, theme.rail(width) - 14, 36);
}

fn tabAt(width: i32, x: i32, y: i32) ?Tab {
    for ([_]Tab{ .usage, .tasks }) |tab| if (navRect(width, tab).contains(x, y)) return tab;
    return null;
}

const App = struct {
    api: *r4os.App2,
    window: *r4os.Window,
    timer: *r4os.Timer,
    allocator: @import("std").mem.Allocator,
    usage: Usage = .{},
    history: History = .{},
    network: meters.Meter(meters.Network) = .{},
    disks: meters.Meter(meters.Disk) = .{},
    client_w: i32 = 0,
    client_h: i32 = 0,
    memory: ?ram.Belegung = null,
    traffic: Traffic = .{},
    tasks: Tasks = .{},
    task_view: TaskView = .{},
    usage_scroll: Scroll = .{ .stride = 18, .compact = true },
    focused: bool = true,
    text: *Text,
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
                        self.text.system = gui.FontSet.system(&self.window.draw);
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
                        self.paint();
                    },
                    .input_reset => {
                        self.pressed = null;
                        self.scroller().thumb_y = null;
                    },
                    .timer => {
                        if (self.focused) self.refresh(false);
                    },
                    .wheel => |wheel| {
                        if (wheel.x >= theme.rail(self.client_w) and wheel.delta != 0)
                            self.scrollKey(if (wheel.delta > 0) gui.Key.up else gui.Key.down);
                    },
                    .mouse => |mouse| switch (mouse.action) {
                        .down => {
                            self.pressed = tabAt(self.client_w, mouse.x, mouse.y);
                            if (self.pressed == null and self.scroller().bar.rect.contains(mouse.x, mouse.y)) {
                                const old = self.scroller().first;
                                self.scroller().mouseDown(mouse.x, mouse.y);
                                if (old != self.scroller().first) self.paint();
                            }
                        },
                        .up => {
                            const tab = tabAt(self.client_w, mouse.x, mouse.y);
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
            const old_cores = self.usage.cores.items.len;
            const old_unknown = self.usage.unknown_topology;
            const old_percent = self.usage.percent;
            const changed = self.usage.refresh(self.api, self.allocator);
            const prior_history = self.history;
            const trend = self.history.observe(self.window.sys.monotonicNanoseconds(), self.usage.percent, self.usage.discontinuity);
            const latest = ram.Belegung.read(self.api);
            const memory_changed = !@import("std").meta.eql(self.memory, latest);
            self.memory = latest;
            const traffic_changed = self.traffic.refresh(self.api);
            self.network.refresh(self.api, self.allocator);
            self.disks.refresh(self.api, self.allocator);
            if (force or old_cores != self.usage.cores.items.len or old_unknown != self.usage.unknown_topology or self.disks.layout_changed or self.network.layout_changed or self.client_h == 0) {
                self.paint();
            } else {
                self.paintChanges(changed, old_percent != self.usage.percent, memory_changed or traffic_changed, if (trend) &prior_history else null);
            }
        } else {
            self.tasks.refresh(self.api, self.allocator);
            if (self.task_view.showsRenderStats(&self.tasks, self.client_h)) self.tasks.refreshRender(self.api);
            const changed = self.task_view.changed(&self.tasks, self.client_h);
            if (force or changed) self.paint();
        }
    }

    fn updateTimer(self: *App) void {
        self.timer.cancel();
        self.usage.reset();
        self.history.pause();
        self.network.fresh = true;
        self.disks.fresh = true;
        if (!self.focused) return;
        self.refresh(true);
        _ = self.timer.start(&self.window.sys, r4os.TimerId.init(1), .{ .nanoseconds = 1_000_000_000 }, true);
    }

    const Layout = struct {
        columns: i32,
        rows: i32,
        tile_w: i32,
        cpu_h: i32,
        content_h: i32,
    };

    fn layout(self: *const App, client_w: i32) Layout {
        const width = @max(1, client_w - theme.rail(self.client_w) - 33);
        const n: i32 = @intCast(self.usage.cores.items.len);
        const tile_min = 48 + @divTrunc(std.math.clamp(client_w - 558, 0, 194) * 22, 194);
        const columns = @max(1, @divTrunc(width + 4, tile_min));
        const rows = @max(1, @divTrunc(n + columns - 1, columns));
        const note_h: i32 = if (self.usage.unknown_topology or n == 0) 20 else 0;
        const cpu_h = 134 + rows * 46 + note_h;
        return .{
            .columns = columns,
            .rows = rows,
            .tile_w = @divTrunc(width + 4, columns),
            .cpu_h = cpu_h,
            .content_h = cpu_h + resources.ram_height + resources.networkHeight(self.network.rows.items.len) + resources.diskHeight(self.disks.rows.items.len),
        };
    }

    fn paintUsage(self: *App, frame_canvas: Canvas) void {
        var canvas = frame_canvas;
        var layout_ = self.layout(canvas.w);
        const overflow = layout_.content_h > canvas.h;
        if (overflow) {
            canvas.w -= 3;
            layout_ = self.layout(canvas.w);
        }
        self.usage_scroll.layout(if (overflow) box(frame_canvas.w - 12, 5, 11, @max(1, canvas.h - 10)) else .{}, @intCast(layout_.content_h), @intCast(canvas.h));
        const top = -@as(i32, @intCast(self.usage_scroll.first));
        if (top + layout_.cpu_h >= 0) self.paintCpu(canvas, layout_, top);
        const x = theme.rail(self.client_w) + 17;
        const w = canvas.w - x - 16;
        const p = theme.Painter{ .canvas = canvas, .text = self.text };
        const ram_top = top + layout_.cpu_h;
        const net_top = ram_top + resources.ram_height;
        const disk_top = net_top + resources.networkHeight(self.network.rows.items.len);
        if (ram_top < canvas.h and net_top > 0) resources.memory(p, x, ram_top, w, theme.labelWidth(self.client_w), self.memory, self.traffic.display);
        if (net_top < canvas.h and disk_top > 0) resources.network(p, x, net_top, w, &self.network);
        if (disk_top < canvas.h) resources.disks(p, x, disk_top, w, &self.disks);
        if (overflow) {
            var scratch: [20]u8 = undefined;
            _ = self.usage_scroll.bar.draw(frame_canvas, &scratch);
        }
    }

    fn paintCpu(self: *App, canvas: Canvas, geometry: Layout, y: i32) void {
        const p = theme.Painter{ .canvas = canvas, .text = self.text };
        const x = theme.rail(self.client_w) + 17;
        const w = canvas.w - x - 16;
        const summary = theme.labelWidth(self.client_w);
        p.label(x, y + 15, summary - 6, 18, .semibold, .left, "CPU", ink, paper);
        var buffer: [64]u8 = undefined;
        const caption = if (self.usage.percent) |v| theme.fmt(&buffer, "{d} %", .{v}) else "–";
        p.label(x, y + 40, summary - 2, if (self.client_w < 650) 33 else 39, .mono, .left, caption, ink, paper);
        chart.draw(p, &self.history, x + summary, y, w - summary);
        const n = self.usage.cores.items.len;
        p.label(x, y + 93, summary - 2, 13, .regular, .left, if (n == 1) "1 Kern" else theme.fmt(&buffer, "{d} Kerne", .{n}), theme.sub, paper);
        for (self.usage.cores.items, 0..) |core, index| {
            const i: i32 = @intCast(index);
            const area = box(x + @mod(i, geometry.columns) * geometry.tile_w, y + 121 + @divTrunc(i, geometry.columns) * 46, geometry.tile_w - 4, 42);
            if (area.y >= canvas.h or area.y + area.h <= 0) continue;
            p.tile(area, theme.soft);
            p.label(area.x, area.y + 3, area.w, 11, .regular, .center, theme.fmt(&buffer, "K{d}", .{index + 1}), theme.sub, theme.soft);
            const value = if (core.percent) |v| theme.fmt(&buffer, "{d} %", .{v}) else "–";
            p.label(area.x, area.y + 18, area.w, 13, .mono, .center, value, ink, theme.soft);
        }
        if (self.usage.unknown_topology or n == 0) {
            p.label(x, y + 121 + geometry.rows * 46, w, 13, .regular, .left, if (self.usage.unknown_topology) "Kernzuordnung unbekannt" else "Keine CPU-Zeitdaten", theme.sub, paper);
        }
        p.rule(x, y + geometry.cpu_h, w, line);
    }

    const Damage = struct {
        areas: [r4os.abi.gui_frame_max_damage_regions]r4os.abi.DisplayDamageRect = undefined,
        count: usize = 0,

        fn add(self: *Damage, x: i32, y: i32, w: i32, h: i32, client_h: i32) void {
            const top = @max(0, y);
            const bottom = @min(client_h, y + h);
            if (bottom <= top or w <= 0) return;
            if (self.count == self.areas.len) {
                // The final slot absorbs any extra visible device rows.
                const last = &self.areas[self.count - 1];
                const left = @min(last.x, x);
                const right = @max(last.x + @as(i32, @intCast(last.w)), x + w);
                const lo = @min(last.y, top);
                const hi = @max(last.y + @as(i32, @intCast(last.h)), bottom);
                last.* = .{ .x = left, .y = lo, .w = @intCast(right - left), .h = @intCast(hi - lo) };
                return;
            }
            self.areas[self.count] = .{ .x = x, .y = top, .w = @intCast(w), .h = @intCast(bottom - top) };
            self.count += 1;
        }
    };

    fn paintChanges(self: *App, cores: bool, total: bool, memory: bool, prior_history: ?*const History) void {
        const client_w = if (self.usage_scroll.bar.maxFirst() != 0) self.client_w - 3 else self.client_w;
        const g = self.layout(client_w);
        const top = -@as(i32, @intCast(self.usage_scroll.first));
        const x = theme.rail(self.client_w) + 17;
        const w = client_w - x - 16;
        const summary = theme.labelWidth(self.client_w);
        var damage: Damage = .{};
        if (total) damage.add(x, top + 37, summary, 53, self.client_h);
        if (prior_history) |prior| {
            if (chart.damage(prior, &self.history, x + summary, top, w - summary, self.client_h)) |area|
                damage.add(area.x, area.y, area.w, area.h, self.client_h);
        }
        // After sampling, next retains the previous core snapshot. Only the
        // number in a changed tile needs a new set of pixels.
        if (cores) for (self.usage.cores.items, 0..) |core, index| {
            if (index < self.usage.next.items.len and self.usage.next.items[index].percent == core.percent) continue;
            const i: i32 = @intCast(index);
            damage.add(x + @mod(i, g.columns) * g.tile_w, top + 138 + @divTrunc(i, g.columns) * 46, g.tile_w - 4, 24, self.client_h);
        };
        const ram_top = top + g.cpu_h;
        if (memory) damage.add(x, ram_top + 12, w, 76, self.client_h);
        const net_top = ram_top + resources.ram_height;
        for (self.network.rows.items, 0..) |row, i| if (row.changed) {
            if (self.network.rows.items.len == 1 and row.label_changed)
                damage.add(x, net_top + 12, w, 28, self.client_h);
            damage.add(x, net_top + 66 + @as(i32, @intCast(i)) * resources.net_row, w, resources.net_row, self.client_h);
        };
        const disk_top = net_top + resources.networkHeight(self.network.rows.items.len);
        for (self.disks.rows.items, 0..) |row, i| if (row.changed) {
            damage.add(x, disk_top + 61 + @as(i32, @intCast(i)) * resources.disk_row, w, resources.disk_row, self.client_h);
        };
        if (damage.count != 0) self.paintRegion(damage.areas[0..damage.count]);
    }

    fn paint(self: *App) void {
        self.paintRegion(null);
    }

    fn paintRegion(self: *App, region: ?[]const r4os.abi.DisplayDamageRect) void {
        const open = if (region) |area| switch (self.window.beginPaintReplace(self.client_w, self.client_h, area)) {
            .paint => |frame| @as(@TypeOf(self.window.beginPaint()), .{ .paint = frame }),
            .failure => self.window.beginPaint(),
        } else self.window.beginPaint();
        var frame = switch (open) {
            .paint => |value| value,
            .failure => return,
        };
        defer frame.discard();
        const canvas = frame.canvas;
        self.client_w = canvas.w;
        self.client_h = canvas.h;
        _ = canvas.clear(paper);
        const sidebar = theme.rail(canvas.w);
        const p = theme.Painter{ .canvas = canvas, .text = self.text };
        p.rect(box(0, 0, sidebar, canvas.h), theme.rail_bg);
        for ([_]Tab{ .usage, .tasks }) |tab| {
            const area = navRect(canvas.w, tab);
            const active = tab == self.tab;
            const background = if (active) @as(u32, theme.selection) else theme.rail_bg;
            if (active) p.tile(area, background);
            const color = if (active and self.focused) @as(u32, theme.selected_text) else theme.sub;
            const compact = canvas.w < 650;
            _ = canvas.blendAlpha8(if (compact) 12 else 15, area.y + 8, 18, 18, 18, color, if (tab == .usage) @embedFile("icons/pulse.a8") else @embedFile("icons/list.a8"));
            const x: i32 = if (compact) 33 else 37;
            p.label(x, area.y + 7, sidebar - x - 7, if (compact) 12 else 13, if (active) .semibold else .regular, .left, if (tab == .usage) "Auslastung" else "Tasks", color, background);
        }
        if (self.tab == .usage) {
            self.paintUsage(canvas);
        } else {
            self.task_view.paint(p, sidebar, &self.tasks);
        }
        _ = frame.present();
    }
};
