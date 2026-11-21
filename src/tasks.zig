//! Complete process generations and read-only Desktop data for the Tasks view.
const std = @import("std");
const r4os = @import("r4os");
const wire = @import("desktop_check");
const a = r4os.abi;
const rows = r4os.inventory_reader;
const Allocator = std.mem.Allocator;

pub const Tasks = struct {
    windows: ?a.WindowServiceSnapshot = null,
    render: ?wire.RenderStats = null,
    status: a.ProgramStatus = .{},
    processes: std.ArrayList(a.ProgramInstanceSnapshot) = .empty,
    staging: std.ArrayList(a.ProgramInstanceSnapshot) = .empty,
    current: bool = false,

    pub fn deinit(self: *Tasks, allocator: Allocator) void {
        self.processes.deinit(allocator);
        self.staging.deinit(allocator);
    }

    pub fn refresh(self: *Tasks, app: *r4os.App2, allocator: Allocator) void {
        const sys = app.system();
        sys.programStatus(&self.status);
        self.current = if (self.collect(app, allocator)) true else |_| false;
        self.windows = null;
        self.render = null;
        var service: a.ServiceInfo = .{};
        if (sys.serviceOpen(wire.service, &service) != 0) return;
        defer _ = sys.serviceClose(service.handle);
        const timeout = sys.ticksFromMilliseconds(350);
        var header: a.ServiceMessageHeader = .{};
        var snapshot: a.WindowServiceSnapshot = .{};
        const got = sys.serviceCall(service.handle, a.window_service_op_snapshot, "", &header, std.mem.asBytes(&snapshot), timeout);
        if (got == @sizeOf(a.WindowServiceSnapshot) and header.status == 0 and
            snapshot.magic == a.window_service_snapshot_magic and snapshot.version == a.window_service_snapshot_version and
            snapshot.status.magic == a.window_service_status_magic and snapshot.status.version == a.window_service_status_version and
            snapshot.status.window_count <= snapshot.records.len)
        {
            self.windows = snapshot;
        }
        var caller: a.ProgramProcessHandle = .{};
        if (sys.programOpenHandle(@intCast(app.raw.instance_id), &caller) != 0) return;
        var request: [wire.request_size]u8 = undefined;
        wire.encodeRequest(&request, .{
            .op = .render_status,
            .caller = .{ .instance = caller.instance_id, .generation = caller.generation },
            .deadline_tick = sys.ticks() +| timeout,
        });
        var response: [wire.response_size]u8 = undefined;
        if (sys.serviceCall(service.handle, wire.operation, &request, &header, &response, timeout) != response.len or header.status != 0) return;
        const value = wire.decodeResponse(&response) catch return;
        if (value.op == .render_status and value.result == 0) self.render = value.render;
    }

    fn collect(self: *Tasks, app: *r4os.App2, allocator: Allocator) !void {
        const provider = try app.inventoryProvider(.full);
        var clock = try app.clock();
        var budget = try r4os.rpc_budget.Budget.fromTimeout(clock.read, r4os.time_contract.timeoutFinite(.{ .nanoseconds = 250 * std.time.ns_per_ms }));
        try self.staging.ensureTotalCapacity(allocator, a.program_inventory_page_max);
        grow: while (true) {
            _ = try budget.remainingTicks();
            const memory = self.staging.allocatedSlice();
            var reader = try rows.Reader.initAbsolute(.full, .{
                .address = @intFromPtr(memory.ptr),
                .length = std.mem.sliceAsBytes(memory).len,
            }, @intCast(memory.len), a.program_inventory_page_max, provider, budget.deadline);
            while (true) {
                const progress = try reader.step(app.shouldClose(), rows.PlatformClock.sample, &clock);
                switch (@as(rows.Status, @enumFromInt(progress.status))) {
                    .complete => {
                        self.staging.items.len = (try reader.fullView()).len;
                        std.mem.swap(std.ArrayList(a.ProgramInstanceSnapshot), &self.processes, &self.staging);
                        self.staging.clearRetainingCapacity();
                        return;
                    },
                    .initial, .more => {},
                    .restart => _ = try reader.restart(),
                    .capacity => {
                        if (progress.total <= memory.len) return error.InconsistentCount;
                        try self.staging.ensureTotalCapacity(allocator, progress.total);
                        continue :grow;
                    },
                    else => return error.Unavailable,
                }
            }
        }
    }
};

pub fn role(value: u8) []const u8 {
    return switch (value) {
        @intFromEnum(a.ProgramInstanceRole.foreground) => "Vordergr.",
        @intFromEnum(a.ProgramInstanceRole.shell) => "Shell",
        @intFromEnum(a.ProgramInstanceRole.background) => "Hintergr.",
        else => "?",
    };
}

pub fn class(value: u8) []const u8 {
    return switch (value) {
        @intFromEnum(a.ProgramInstanceClass.console) => "Konsole",
        @intFromEnum(a.ProgramInstanceClass.gui) => "GUI",
        @intFromEnum(a.ProgramInstanceClass.service) => "Dienst",
        else => "?",
    };
}

pub fn state(value: u8) []const u8 {
    return switch (value) {
        @intFromEnum(a.ProgramInstanceState.running) => "läuft",
        @intFromEnum(a.ProgramInstanceState.close_requested) => "schließt",
        @intFromEnum(a.ProgramInstanceState.done) => "beendet",
        else => "?",
    };
}
