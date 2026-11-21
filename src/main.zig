const r4os = @import("r4os");

const gui = r4os.gui;
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
    var window = api.window(&.{}) orelse return r4os.abi.err_no_group;
    var app = App{ .window = &window, .fonts = gui.FontSet.system(&window.draw) };
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
    window: *r4os.Window,
    fonts: gui.FontSet,
    tab: Tab = .usage,
    pressed: ?Tab = null,

    fn run(self: *App) i32 {
        _ = self.window.setTitle("Control Center");
        _ = self.window.setMinimumSize(558, 332);
        self.paint();
        while (!self.window.sys.programShouldClose()) {
            switch (self.window.waitMessage(r4os.time_contract.timeoutForever())) {
                .message => |message| switch (message) {
                    .close => return 0,
                    .resize => self.paint(),
                    .font_changed => {
                        self.fonts = gui.FontSet.system(&self.window.draw);
                        self.paint();
                    },
                    .focus_lost, .input_reset => self.pressed = null,
                    .mouse => |mouse| switch (mouse.action) {
                        .down => self.pressed = tabAt(mouse.x, mouse.y),
                        .up => {
                            const tab = tabAt(mouse.x, mouse.y);
                            if (tab != null and tab == self.pressed) self.select(tab.?);
                            self.pressed = null;
                        },
                        .move => {},
                    },
                    .key => |key| switch (key.key) {
                        gui.Key.tab, gui.Key.shift_tab => self.select(if (self.tab == .usage) .tasks else .usage),
                        gui.Key.left => self.select(.usage),
                        gui.Key.right => self.select(.tasks),
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
        self.paint();
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
            _ = canvas.rect(box(sidebar, 99, canvas.w - sidebar, 1), line);
            _ = canvas.rect(box(sidebar + summary_width - 1, 0, 1, 99), line);
            label(canvas, box(sidebar + 8, 4, summary_width - 16, 23), "CPU", .left, ink, paper);
            label(canvas.withFontId(self.fonts.display), box(sidebar + 3, 25, summary_width - 6, 65), "40%", .center, ink, paper);
            for (0..12) |i| {
                const col: i32 = @intCast(i % 6);
                const row: i32 = @intCast(i / 6);
                const area = box(sidebar + summary_width + 5 + col * 52, 5 + row * 45, 48, 41);
                cell(canvas, area, paper);
                label(canvas, area.inset(2, 1), "20%", .center, ink, paper);
            }
        } else {
            label(canvas, box(sidebar + 12, 10, canvas.w - sidebar - 24, 30), "Tasks", .left, ink, paper);
        }
        _ = frame.present();
    }
};
