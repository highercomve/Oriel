//! Bounded histories and process selection, independent of the renderer.
const std = @import("std");
const tm = @import("telemetry.zig");
pub const sections = [_][]const u8{ "tiles", "system", "cpu", "mem", "disks", "net", "sensors", "proc" };
pub const section_labels = [_][]const u8{ "Summary tiles", "System", "CPU details", "Memory", "Disks", "Network", "Sensors", "Processes" };
pub const Settings = struct {
    shown: [8]bool = @splat(true),
    interval_ms: u32 = 2000,
    interface: [64]u8 = @splat(0),
    interface_len: usize = 0,
    pub fn validate(s: *Settings) void {
        if (s.interval_ms != 1000 and s.interval_ms != 2000 and s.interval_ms != 5000) s.interval_ms = 2000;
        s.interface_len = @min(s.interface_len, s.interface.len);
    }
};
pub const History = struct {
    values: [60]f64 = @splat(0),
    len: usize = 0,
    next: usize = 0,
    pub fn push(h: *History, value: f64) void {
        std.debug.assert(h.next < h.values.len);
        h.values[h.next] = if (std.math.isFinite(value)) @max(0, value) else 0;
        h.next = (h.next + 1) % h.values.len;
        h.len = @min(h.len + 1, h.values.len);
    }
    pub fn at(h: *const History, i: usize) f64 {
        std.debug.assert(i < h.len);
        return h.values[(h.next + h.values.len - h.len + i) % h.values.len];
    }
    pub fn peak(h: *const History) f64 {
        var result: f64 = 0;
        for (0..h.len) |i| result = @max(result, h.at(i));
        return result;
    }
};
pub const NetHistory = struct {
    name: [64]u8 = @splat(0),
    len: usize = 0,
    rx: History = .{},
    tx: History = .{},
};
pub const Histories = struct {
    cpu: History = .{},
    mem: History = .{},
    proc: History = .{},
    user: History = .{},
    system: History = .{},
    wait: History = .{},
    cores: [256]History = @splat(.{}),
    net: [32]NetHistory = @splat(.{}),
    net_len: usize = 0,
    pub fn network(h: *Histories, name: []const u8) ?*NetHistory {
        for (h.net[0..h.net_len]) |*n| if (std.mem.eql(u8, n.name[0..n.len], name)) return n;
        if (h.net_len == h.net.len or name.len > 64) return null;
        const n = &h.net[h.net_len];
        h.net_len += 1;
        @memcpy(n.name[0..name.len], name);
        n.len = name.len;
        return n;
    }
    pub fn push(h: *Histories, sample: tm.SystemSample) void {
        h.cpu.push(sample.cpu.percent);
        h.mem.push(sample.mem.percent);
        h.proc.push(@floatFromInt(sample.total_processes));
        h.user.push(sample.cpu.user_percent);
        h.system.push(sample.cpu.system_percent);
        h.wait.push(sample.cpu.iowait_percent orelse 0);
        for (sample.cpu.per_core[0..@min(sample.cpu.per_core.len, h.cores.len)], 0..) |core, i| h.cores[i].push(core.percent);
        for (sample.net) |n| if (h.network(n.name)) |hist| {
            hist.rx.push(n.rx_bps);
            hist.tx.push(n.tx_bps);
        };
    }
};
pub const Sort = enum { cpu, mem, threads, pid, name };
pub const Order = struct { field: Sort = .cpu, descending: bool = true };
pub fn select(rows: []const tm.ProcessRow, filter: []const u8, order: Order, out: *[tm.max_rows]tm.ProcessRow) []tm.ProcessRow {
    var len: usize = 0;
    for (rows) |row| {
        if (!tm.matches(row, filter)) continue;
        if (len == out.len) break;
        out[len] = row;
        len += 1;
    }
    std.mem.sort(tm.ProcessRow, out[0..len], order, struct {
        fn less(o: Order, a: tm.ProcessRow, b: tm.ProcessRow) bool {
            const cmp: std.math.Order = switch (o.field) {
                .cpu => std.math.order(a.cpu_percent, b.cpu_percent),
                .mem => std.math.order(a.mem_rss_bytes, b.mem_rss_bytes),
                .threads => std.math.order(a.threads, b.threads),
                .pid => std.math.order(a.pid, b.pid),
                .name => std.mem.order(u8, a.name, b.name),
            };
            if (cmp == .eq) return a.pid < b.pid;
            return cmp == if (o.descending) std.math.Order.gt else .lt;
        }
    }.less);
    return out[0..len];
}
test "history wraps chronologically and rejects non-finite samples" {
    var h: History = .{};
    for (0..75) |i| h.push(@floatFromInt(i));
    try std.testing.expectEqual(@as(usize, 60), h.len);
    try std.testing.expectEqual(@as(f64, 15), h.at(0));
    try std.testing.expectEqual(@as(f64, 74), h.at(59));
    h.push(std.math.nan(f64));
    try std.testing.expectEqual(@as(f64, 0), h.at(59));
}
test "selection filters before stable deterministic sorting" {
    const rows = [_]tm.ProcessRow{
        .{ .pid = 20, .name = "worker", .command = "job", .user = "test", .state = "S", .threads = 1, .cpu_percent = 2, .mem_rss_bytes = 10 },
        .{ .pid = 10, .name = "worker", .command = "job", .user = "test", .state = "S", .threads = 2, .cpu_percent = 2, .mem_rss_bytes = 20 },
        .{ .pid = 30, .name = "other", .command = "", .user = "root", .state = "R", .threads = 3, .cpu_percent = 9, .mem_rss_bytes = 30 },
    };
    var out: [tm.max_rows]tm.ProcessRow = undefined;
    const selected = select(&rows, "WORK", .{}, &out);
    try std.testing.expectEqual(@as(usize, 2), selected.len);
    try std.testing.expectEqual(@as(u32, 10), selected[0].pid);
    const by_mem = select(&rows, "", .{ .field = .mem, .descending = false }, &out);
    try std.testing.expectEqual(@as(u32, 20), by_mem[0].pid);
}
