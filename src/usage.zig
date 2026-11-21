const std = @import("std");
const r4os = @import("r4os");
const abi = r4os.abi;
const Allocator = std.mem.Allocator;

const Totals = struct {
    online: u128 = 0,
    busy: u128 = 0,

    fn add(self: *Totals, value: Totals) void {
        self.online += value.online;
        self.busy += value.busy;
    }
    fn percent(self: Totals) ?u8 {
        if (self.online == 0) return null;
        return @intCast((self.busy * 100 + self.online / 2) / self.online);
    }
};

const CoreId = struct { package: u32, core: u32 };
const Slot = struct {
    previous: ?abi.CpuTimeInfo = null,
    topology_epoch: ?u64 = null,
    core: ?CoreId = null,
};
pub const Core = struct {
    id: CoreId,
    percent: ?u8 = null,
    times: Totals = .{},
};

fn delta(old: abi.CpuTimeInfo, new: abi.CpuTimeInfo) ?Totals {
    const valid = abi.cpu_time_flag_available | abi.cpu_time_flag_online;
    if ((new.flags & old.flags & valid) != valid or new.cpu_index != old.cpu_index or
        new.epoch != old.epoch or new.clock_generation != old.clock_generation or
        new.online_ns <= old.online_ns or new.idle_ns < old.idle_ns) return null;
    const online = new.online_ns - old.online_ns;
    const idle = new.idle_ns - old.idle_ns;
    if (idle > online) return null;
    return .{ .online = online, .busy = online - idle };
}

pub const Usage = struct {
    slots: std.ArrayList(Slot) = .empty,
    cores: std.ArrayList(Core) = .empty,
    next: std.ArrayList(Core) = .empty,
    percent: ?u8 = null,
    unknown_topology: bool = false,

    pub fn deinit(self: *Usage, allocator: Allocator) void {
        self.slots.deinit(allocator);
        self.cores.deinit(allocator);
        self.next.deinit(allocator);
    }

    /// Resume with two fresh observations. Hidden time never enters the first interval.
    pub fn reset(self: *Usage) void {
        for (self.slots.items) |*slot| slot.previous = null;
        for (self.cores.items) |*core| core.percent = null;
        self.percent = null;
    }

    pub fn refresh(self: *Usage, app: *const r4os.App2, allocator: Allocator) bool {
        return self.sample(app, allocator) catch {
            const changed = self.cores.items.len != 0 or self.percent != null or self.unknown_topology;
            self.reset();
            self.cores.clearRetainingCapacity();
            self.unknown_topology = false;
            return changed;
        };
    }

    fn sample(self: *Usage, app: *const r4os.App2, allocator: Allocator) !bool {
        const dev = app.devicesLowLevel() orelse return error.Unavailable;
        var first: abi.CpuTimeInfo = .{};
        if (dev.cpuTimeInfo(0, &first) != abi.cpu_capabilities_ok or first.configured_cpus == 0) return error.Unavailable;
        const count = first.configured_cpus;
        const had = self.slots.items.len;
        try self.slots.resize(allocator, count);
        if (count > had) @memset(self.slots.items[had..], .{});
        self.next.clearRetainingCapacity();
        try self.next.ensureTotalCapacity(allocator, count);
        var total: Totals = .{};
        var unknown = false;
        for (self.slots.items, 0..) |*slot, i| {
            var sample_now: abi.CpuTimeInfo = .{};
            if (i == 0) {
                sample_now = first;
            } else if (dev.cpuTimeInfo(@intCast(i), &sample_now) != abi.cpu_capabilities_ok or sample_now.cpu_index != i or sample_now.configured_cpus != count) {
                slot.previous = null;
                continue;
            }
            if (slot.topology_epoch != sample_now.epoch) {
                slot.core = null;
                var topology: abi.CpuTopologyInfo = .{};
                if (dev.cpuTopology(@intCast(i), &topology) == abi.cpu_topology_result_ok) {
                    slot.topology_epoch = sample_now.epoch;
                    slot.core = if (topology.flags & abi.cpu_topology_flag_geometry != 0)
                        .{ .package = topology.package_id, .core = topology.core_id }
                    else
                        null;
                }
            }
            const times = if (slot.previous) |prev| delta(prev, sample_now) else null;
            slot.previous = sample_now;
            if (times) |value| total.add(value);
            if (slot.core) |id| {
                const group = for (self.next.items) |*core| {
                    if (std.meta.eql(core.id, id)) break core;
                } else group: {
                    const core = self.next.addOneAssumeCapacity();
                    core.* = .{ .id = id };
                    break :group core;
                };
                if (times) |value| group.times.add(value);
            } else if (sample_now.flags & abi.cpu_time_flag_online != 0) unknown = true;
        }
        for (self.next.items) |*core| core.percent = core.times.percent();
        const percent = total.percent();
        var changed = self.percent != percent or self.unknown_topology != unknown or self.cores.items.len != self.next.items.len;
        if (!changed) for (self.cores.items, self.next.items) |old, new| {
            if (!std.meta.eql(old.id, new.id) or old.percent != new.percent) {
                changed = true;
                break;
            }
        };
        self.percent = percent;
        self.unknown_topology = unknown;
        std.mem.swap(std.ArrayList(Core), &self.cores, &self.next);
        return changed;
    }
};
