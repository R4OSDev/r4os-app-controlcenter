const std = @import("std");
const r = @import("r4os");
const Allocator = std.mem.Allocator;

pub const Rate = struct {
    unit: u8,
    tenths: u64,

    fn from(bytes: u64, elapsed_ns: u64) Rate {
        const per_s = (@as(u128, bytes) * std.time.ns_per_s) / elapsed_ns;
        var divisor: u64 = 1;
        var unit: u8 = 0;
        while (unit < 4 and per_s >= @as(u128, divisor) * 1024) : (unit += 1) divisor *= 1024;
        return .{ .unit = unit, .tenths = @intCast(@min((per_s * 10 + divisor / 2) / divisor, std.math.maxInt(u64))) };
    }

    pub fn write(rate: ?Rate, buf: []u8) []const u8 {
        const v = rate orelse return "--";
        const unit = ([_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s", "TB/s" })[v.unit];
        if (v.unit != 0 and v.tenths % 10 != 0) return std.fmt.bufPrint(buf, "{d},{d} {s}", .{ v.tenths / 10, v.tenths % 10, unit }) catch "--";
        return std.fmt.bufPrint(buf, "{d} {s}", .{ v.tenths / 10, unit }) catch "--";
    }
};

pub const Values = struct {
    first: ?Rate = null,
    second: ?Rate = null,
    first_pct: ?u32 = null,
    second_pct: ?u32 = null,
};

fn share(numerator: u128, denominator: u128) ?u32 {
    if (denominator == 0) return null;
    return @intCast(@min((numerator * 100 + denominator / 2) / denominator, std.math.maxInt(u32)));
}

pub const Network = struct {
    pub const Sample = r.abi.NetworkTrafficSample;

    pub fn fetch(api: *r.App2, names: bool, out: []Sample) i32 {
        const net = api.networkLowLevel() orelse return r.abi.err_no_group;
        return net.networkTraffic(names, out);
    }

    pub fn measure(old: Sample, new: Sample, elapsed: u64) Values {
        if (old.resets != new.resets or old.link != new.link or new.link == 1 or new.rx_bytes < old.rx_bytes or new.tx_bytes < old.tx_bytes) return .{};
        const rx = new.rx_bytes - old.rx_bytes;
        const tx = new.tx_bytes - old.tx_bytes;
        const scale = 8 * @as(u128, std.time.ns_per_s);
        return .{
            .first = Rate.from(rx, elapsed),
            .second = Rate.from(tx, elapsed),
            .first_pct = if (new.link == 2 and new.rx_bps == old.rx_bps)
                share(@as(u128, rx) * scale, @as(u128, elapsed) * new.rx_bps)
            else
                null,
            .second_pct = if (new.link == 2 and new.tx_bps == old.tx_bps)
                share(@as(u128, tx) * scale, @as(u128, elapsed) * new.tx_bps)
            else
                null,
        };
    }

    pub fn sameDevice(a: Sample, b: Sample) bool {
        return a.interface_id == b.interface_id;
    }
    pub fn retainNames(new: *Sample, old: Sample) void {
        new.name = old.name;
    }
    pub fn sameLabel(a: Sample, b: Sample) bool {
        return a.link == b.link and std.mem.eql(u8, &a.name, &b.name);
    }
};

pub fn Meter(comptime Source: type) type {
    return struct {
        const Self = @This();
        const Sample = Source.Sample;
        pub const Row = struct { sample: Sample, values: Values, changed: bool };
        rows: std.ArrayList(Row) = .empty,
        next: std.ArrayList(Row) = .empty,
        buffer: std.ArrayList(Sample) = .empty,
        available: bool = false,
        fresh: bool = true,
        layout_changed: bool = true,

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.buffer.deinit(allocator);
            self.rows.deinit(allocator);
            self.next.deinit(allocator);
        }
        fn find(self: *Self, sample: Sample) ?Row {
            for (self.rows.items) |old| if (Source.sameDevice(old.sample, sample)) return old;
            return null;
        }
        fn read(self: *Self, api: *r.App2, allocator: Allocator, names: bool) ?[]Sample {
            var n = Source.fetch(api, names, self.buffer.items);
            if (n < 0) return null;
            if (@as(usize, @intCast(n)) > self.buffer.items.len) {
                self.buffer.resize(allocator, @intCast(n)) catch return null;
                n = Source.fetch(api, true, self.buffer.items);
                if (n < 0 or @as(usize, @intCast(n)) > self.buffer.items.len) return null;
            }
            return self.buffer.items[0..@intCast(n)];
        }
        fn unavailable(self: *Self) void {
            self.layout_changed = self.available or self.rows.items.len != 0;
            self.available = false;
            self.fresh = true;
            self.rows.clearRetainingCapacity();
        }
        pub fn refresh(self: *Self, api: *r.App2, allocator: Allocator) void {
            var names = self.rows.items.len == 0;
            var incoming = self.read(api, allocator, names) orelse return self.unavailable();
            if (!names) for (incoming) |item| {
                if (self.find(item) == null) {
                    names = true;
                    incoming = self.read(api, allocator, true) orelse return self.unavailable();
                    break;
                }
            };
            self.next.clearRetainingCapacity();
            self.next.ensureTotalCapacity(allocator, incoming.len) catch return self.unavailable();
            self.layout_changed = !self.available or self.rows.items.len != incoming.len;
            for (incoming, 0..) |item, i| {
                var sample = item;
                var values: Values = .{};
                var changed = true;
                if (self.find(item)) |old| {
                    if (!names) Source.retainNames(&sample, old.sample);
                    if (!self.fresh and old.sample.generation == sample.generation and sample.clock_generation != 0 and old.sample.clock_generation == sample.clock_generation and sample.stamp_ns > old.sample.stamp_ns)
                        values = Source.measure(old.sample, sample, sample.stamp_ns - old.sample.stamp_ns);
                    changed = !Source.sameLabel(old.sample, sample) or !std.meta.eql(old.values, values);
                }
                if (i >= self.rows.items.len or !Source.sameDevice(self.rows.items[i].sample, sample)) self.layout_changed = true;
                self.next.appendAssumeCapacity(.{ .sample = sample, .values = values, .changed = changed });
            }
            std.mem.swap(std.ArrayList(Row), &self.rows, &self.next);
            self.available = true;
            self.fresh = false;
        }
    };
}
