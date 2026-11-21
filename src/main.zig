const r4os = @import("r4os");

const gui = r4os.gui;
const Usage = @import("usage.zig").Usage;
const Tasks = @import("tasks.zig").Tasks;
const TaskView = @import("task_view.zig").View;
const Rect = gui.Rect;
const Canvas = gui.Canvas;
const Tab = enum { usage, tasks };
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
    defer app.tasks.deinit(allocator);
    defer app.usage.deinit(allocator);
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
    tasks: Tasks = .{},
    task_view: TaskView = .{},
    focused: bool = true,
    fonts: gui.FontSet,
    tab: Tab = .usage,
    pressed: ?Tab = null,

    fn run(self: *App) i32 {
        _ = self.window.setTitle("Control Center");
        _ = self.window.setMinimumSize(558, 332);
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
                        self.focused = true;
                        self.updateTimer();
                    },
                    .focus_lost => {
                        self.focused = false;
                        self.timer.cancel();
                        self.pressed = null;
                        self.task_view.thumb_y = null;
                    },
                    .input_reset => {
                        self.pressed = null;
                        self.task_view.thumb_y = null;
                    },
                    .timer => {
                        if (self.focused) self.refresh(false);
                    },
                    .wheel => |wheel| {
                        if (self.tab == .tasks) {
                            self.task_view.first = self.task_view.bar.wheel(wheel.delta).first_index;
                            self.paint();
                        }
                    },
                    .mouse => |mouse| switch (mouse.action) {
                        .down => {
                            self.pressed = tabAt(mouse.x, mouse.y);
                            if (self.pressed == null and self.tab == .tasks) {
                                self.task_view.mouseDown(mouse.x, mouse.y);
                                self.paint();
                            }
                        },
                        .up => {
                            const tab = tabAt(mouse.x, mouse.y);
                            if (tab != null and tab == self.pressed) self.select(tab.?);
                            self.pressed = null;
                            self.task_view.thumb_y = null;
                        },
                        .move => if (self.tab == .tasks and self.task_view.thumb_y != null) {
                            self.task_view.drag(mouse.y);
                            self.paint();
                        },
                    },
                    .key => |key| switch (key.key) {
                        gui.Key.tab, gui.Key.shift_tab => self.select(if (self.tab == .usage) .tasks else .usage),
                        gui.Key.left => self.select(.usage),
                        gui.Key.right => self.select(.tasks),
                        gui.Key.up, gui.Key.down, gui.Key.home, gui.Key.end, gui.Key.page_up, gui.Key.page_down => {
                            if (self.tab == .tasks) {
                                self.task_view.key(key.key);
                                self.paint();
                            }
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

    fn select(self: *App, tab: Tab) void {
        if (self.tab == tab) return;
        self.tab = tab;
        self.updateTimer();
    }

    fn refresh(self: *App, force: bool) void {
        if (self.tab == .usage) {
            const changed = self.usage.refresh(self.api, self.allocator);
            if (changed or force) self.paint();
        } else {
            self.tasks.refresh(self.api, self.allocator);
            self.paint();
        }
    }

    fn updateTimer(self: *App) void {
        self.timer.cancel();
        self.usage.reset();
        if (!self.focused) return;
        self.refresh(true);
        _ = self.timer.start(&self.window.sys, r4os.TimerId.init(1), .{ .nanoseconds = 1_000_000_000 }, true);
    }

    fn percentText(value: ?u8, buf: *[5]u8) [:0]const u8 {
        return if (value) |v| @import("std").fmt.bufPrintZ(buf, "{d}%", .{v}) catch "--" else "--";
    }

    fn paintUsage(self: *App, canvas: Canvas) void {
        const x = sidebar + summary_width;
        const width = canvas.w - x - 8;
        const n: i32 = @intCast(self.usage.cores.items.len);
        const columns = @max(1, @min(@divTrunc(width, 48), @divTrunc(n + 1, 2)));
        const rows = @max(1, @divTrunc(n + columns - 1, columns));
        const tile_w = @min(52, @divTrunc(width, columns));
        const note_h: i32 = if (self.usage.unknown_topology) 22 else 0;
        const tile_h = @min(45, @divTrunc(canvas.h - 12 - note_h, rows));
        const height = @max(98, rows * tile_h + note_h + 8);
        _ = canvas.rect(box(sidebar, height, canvas.w - sidebar, 1), line);
        _ = canvas.rect(box(x - 1, 0, 1, height), line);
        label(canvas, box(sidebar + 8, 4, summary_width - 16, 23), "CPU", .left, ink, paper);
        var buf: [5]u8 = undefined;
        const caption = percentText(self.usage.percent, &buf);
        const summary = box(sidebar + 3, 25, summary_width - 6, 65);
        const display = canvas.withFontId(self.fonts.display);
        const large = if (display.textWidthZ(caption.ptr) + 4 <= summary.w) display else canvas.withFontId(self.fonts.heading);
        label(large, summary, caption, .center, ink, paper);
        for (self.usage.cores.items, 0..) |core, index| {
            const i: i32 = @intCast(index);
            const area = box(x + 5 + @mod(i, columns) * tile_w, 5 + @divTrunc(i, columns) * tile_h, tile_w - 4, tile_h - 4);
            cell(canvas, area, paper);
            label(canvas.withFontId(r4os.abi.gui_font_builtin_id), area.inset(1, 1), percentText(core.percent, &buf), .center, ink, paper);
        }
        if (self.usage.unknown_topology or n == 0) {
            const message = if (self.usage.unknown_topology) "Kernzuordnung unbekannt" else "Keine CPU-Zeitdaten";
            label(canvas, box(x + 6, if (n == 0) 8 else rows * tile_h + 5, width, 23), message, .left, ink, paper);
        }
    }

    fn paint(self: *App) void {
        var frame = switch (self.window.beginPaint()) {
            .paint => |value| value,
            .failure => return,
        };
        defer frame.discard();
        const canvas = frame.canvas.withFontId(self.fonts.body);
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
