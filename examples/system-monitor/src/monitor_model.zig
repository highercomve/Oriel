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
pub const TreeInfo = struct { depth: u8 = 0, continuation: u64 = 0, last: bool = true };
const TreeFrame = struct { index: usize, info: TreeInfo };

fn parent_index(rows: []const tm.ProcessRow, index: usize) ?usize {
    const child = rows[index];
    if (child.parent_pid == child.pid) return null;
    for (rows, 0..) |parent, i| {
        if (parent.pid != child.parent_pid or parent.application_id != child.application_id) continue;
        if (child.start_time > 0 and parent.start_time > child.start_time) return null;
        return i;
    }
    return null;
}

/// Sorted input becomes a forest: roots and siblings keep the chosen order.
/// Missing/filtered parents become roots; a second pass retains cyclic rows.
pub fn process_tree(rows: []const tm.ProcessRow, out: *[tm.max_rows]tm.ProcessRow, info: *[tm.max_rows]TreeInfo) []tm.ProcessRow {
    std.debug.assert(rows.len <= tm.max_rows);
    var source: [tm.max_rows]tm.ProcessRow = undefined;
    @memcpy(source[0..rows.len], rows);
    const input = source[0..rows.len];
    var parents: [tm.max_rows]?usize = undefined;
    for (0..input.len) |i| parents[i] = parent_index(input, i);
    var seen: [tm.max_rows]bool = @splat(false);
    var len: usize = 0;
    for (0..2) |pass| {
        for (input, 0..) |_, root| {
            if (seen[root] or (pass == 0 and parents[root] != null)) continue;
            var stack: [tm.max_rows]TreeFrame = undefined;
            stack[0] = .{ .index = root, .info = .{} };
            var count: usize = 1;
            seen[root] = true;
            while (count > 0) {
                count -= 1;
                const frame = stack[count];
                out[len] = input[frame.index];
                info[len] = frame.info;
                len += 1;
                var last = true;
                var reverse = input.len;
                while (reverse > 0) {
                    reverse -= 1;
                    if (seen[reverse] or parents[reverse] != frame.index) continue;
                    seen[reverse] = true;
                    var continuation = frame.info.continuation;
                    if (frame.info.depth > 0 and !frame.info.last) continuation |= @as(u64, 1) << @intCast(frame.info.depth - 1);
                    std.debug.assert(count < stack.len);
                    stack[count] = .{ .index = reverse, .info = .{ .depth = @min(63, frame.info.depth + 1), .continuation = continuation, .last = last } };
                    count += 1;
                    last = false;
                }
            }
        }
    }
    std.debug.assert(len == rows.len);
    return out[0..len];
}

pub fn tree_name(buf: []u8, name: []const u8, info: TreeInfo) ![]const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    if (info.depth > 0) {
        for (0..info.depth - 1) |level| try writer.writeAll(if (info.continuation & (@as(u64, 1) << @intCast(level)) != 0) "│  " else "   ");
        try writer.writeAll(if (info.last) "└─ " else "├─ ");
    }
    try writer.writeAll(name);
    return writer.buffered();
}
pub fn select(rows: []const tm.ProcessRow, filter: []const u8, order: Order, out: *[tm.max_rows]tm.ProcessRow) []tm.ProcessRow {
    return select_members(rows, filter, order, 0, out);
}
pub fn select_members(rows: []const tm.ProcessRow, filter: []const u8, order: Order, application_id: u64, out: *[tm.max_rows]tm.ProcessRow) []tm.ProcessRow {
    var len: usize = 0;
    for (rows) |row| {
        if (application_id != 0 and row.application_id != application_id) continue;
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

pub fn select_applications(rows: []const tm.ApplicationRow, filter: []const u8, order: Order, out: *[tm.max_rows]tm.ApplicationRow) []tm.ApplicationRow {
    var len: usize = 0;
    for (rows) |row| {
        if (!@import("applications.zig").matches(row, filter)) continue;
        if (len == out.len) break;
        out[len] = row;
        len += 1;
    }
    std.mem.sort(tm.ApplicationRow, out[0..len], order, struct {
        fn less(o: Order, a: tm.ApplicationRow, b: tm.ApplicationRow) bool {
            const cmp = switch (o.field) {
                .cpu => std.math.order(a.cpu_percent, b.cpu_percent),
                .mem => std.math.order(a.mem_rss_bytes, b.mem_rss_bytes),
                .threads => std.math.order(a.threads, b.threads),
                .pid => std.math.order(a.process_count, b.process_count),
                .name => std.mem.order(u8, a.name, b.name),
            };
            if (cmp == .eq) return a.id < b.id;
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

test "application search and sorting preserve whole-app totals and member isolation" {
    const apps = [_]tm.ApplicationRow{
        .{ .id = 1, .name = "Browser", .user = "alice", .process_count = 12, .cpu_percent = 7, .mem_rss_bytes = 1000 },
        .{ .id = 2, .name = "Editor", .user = "alice", .process_count = 3, .cpu_percent = 9, .mem_rss_bytes = 500 },
    };
    var out: [tm.max_rows]tm.ApplicationRow = undefined;
    const found = select_applications(&apps, "BROW", .{}, &out);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(u32, 12), found[0].process_count);
    try std.testing.expectEqual(@as(u64, 1000), found[0].mem_rss_bytes);
    try std.testing.expectEqual(@as(u64, 1), select_applications(&apps, "", .{ .field = .pid }, &out)[0].id);
    const rows = [_]tm.ProcessRow{
        .{ .pid = 1, .application_id = 1, .name = "helper", .command = "", .user = "alice", .state = "S", .threads = 1, .cpu_percent = 0, .mem_rss_bytes = 100 },
        .{ .pid = 2, .application_id = 2, .name = "helper", .command = "", .user = "alice", .state = "S", .threads = 1, .cpu_percent = 90, .mem_rss_bytes = 100 },
    };
    var members: [tm.max_rows]tm.ProcessRow = undefined;
    const selected = select_members(&rows, "helper", .{}, 1, &members);
    try std.testing.expectEqual(@as(usize, 1), selected.len);
    try std.testing.expectEqual(@as(u32, 1), selected[0].pid);
}

test "application process tree keeps children under parents and sorts siblings" {
    const a = std.testing.allocator;
    var rows: [tm.max_rows]tm.ProcessRow = undefined;
    for (0..5) |i| rows[i] = .{ .pid = @intCast(i + 1), .application_id = 9, .name = "worker", .user = "a", .command = "", .state = "S", .threads = 1, .cpu_percent = 0, .mem_rss_bytes = 0 };
    rows[0].pid = 3;
    rows[0].parent_pid = 1; // higher-sorted sibling
    rows[1].pid = 2;
    rows[1].parent_pid = 1;
    rows[2].pid = 4;
    rows[2].parent_pid = 3;
    rows[3].pid = 1;
    rows[3].parent_pid = 0;
    rows[4].pid = 5;
    rows[4].parent_pid = 99; // orphan remains visible
    var tree: [tm.max_rows]TreeInfo = undefined;
    const result = process_tree(rows[0..5], &rows, &tree);
    const pids = try a.alloc(u32, result.len);
    defer a.free(pids);
    for (result, pids) |row, *pid| pid.* = row.pid;
    try std.testing.expectEqualSlices(u32, &.{ 1, 3, 4, 2, 5 }, pids);
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("├─ worker", try tree_name(&buf, "worker", tree[1]));
    try std.testing.expectEqualStrings("│  └─ worker", try tree_name(&buf, "worker", tree[2]));
    try std.testing.expectEqualStrings("└─ worker", try tree_name(&buf, "worker", tree[3]));
    rows[0].parent_pid = rows[1].pid;
    rows[1].parent_pid = rows[0].pid;
    try std.testing.expectEqual(@as(usize, 5), process_tree(rows[0..5], &rows, &tree).len);
}

test {
    _ = @import("applications.zig");
    _ = @import("desktop_apps.zig");
}
