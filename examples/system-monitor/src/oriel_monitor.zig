//! Pure Zig system monitor, retaining the same sampler and command pool.
const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const ui = oriel.ui;
const tm = @import("telemetry.zig");
const model = @import("monitor_model.zig");
const fmt = @import("monitor_format.zig");
const charts = @import("monitor_charts.zig");
const Shell = ui.View(@embedFile("monitor.oriel"));
const Row = ui.View(@embedFile("process.oriel"));
const Disk = ui.View(@embedFile("disk.oriel"));
const Settings = ui.View(@embedFile("settings.oriel"));
const Actions = ui.View(@embedFile("actions.oriel"));
const Confirm = ui.View(@embedFile("confirm.oriel"));
const root_id: i64 = 10;
const settings_id: i64 = 1000;
const actions_id: i64 = 2000;
const confirm_id: i64 = 3000;
const rows_base: i64 = 10000;
const disk_base: i64 = 20000;
const row_capacity = 96;
const row_height = 34;
const sample_request = 1;
const info_request = 2;
const clipboard_request = 3;
const command_request = 4;
const end_request = 5;
const State = struct {
    io: std.Io = undefined,
    initialized: bool = false,
    settings: model.Settings = .{},
    settings_path: ?[]const u8 = null,
    sample: ?std.json.Parsed(tm.SystemSample) = null,
    info: ?std.json.Parsed(tm.SystemInfo) = null,
    history: model.Histories = .{},
    program: ui.Program = undefined,
    filter: [tm.max_filter]u8 = @splat(0),
    filter_len: usize = 0,
    order: model.Order = .{},
    selected: [tm.max_rows]tm.ProcessRow = undefined,
    selected_len: usize = 0,
    action_arena: std.heap.ArenaAllocator = undefined,
    action: ?tm.ProcessRow = null,
    disk_count: usize = 0,
    network_index: usize = 0,
    network_selected: bool = false,
    paused: bool = false,
    in_flight: bool = false,
    pending_refresh: bool = false,
    manual_refresh: bool = false,
    timer_id: u32 = 100,
    filter_timer: u32 = 0,
    notification_timer: u32 = 0,
    next_timer: u32 = 100,
    settings_open: bool = false,
    actions_open: bool = false,
    confirm_open: bool = false,
    command_in_flight: bool = false,
    copy_details: bool = false,
    copy_label: []const u8 = "process name",
    samples: u64 = 0,
};
const SavedSettings = struct { shown: [8]bool = @splat(true), interval_ms: u32 = 2000, interface: []const u8 = "" };
var s: State = .{};
pub fn configure(io: std.Io) void {
    s.io = io;
    ui.configure(.{ .boot = boot, .event = event, .timer = timer, .resolved = resolved, .resized = resized, .scrolled = scrolled, .shutdown = shutdown });
}
fn sid(comptime name: []const u8) i64 {
    return Shell.id(name, root_id);
}
fn text(e: *ui.Engine, id: i64, value: []const u8) !void {
    if (!try e.tree.updateText(id, value)) return error.InvalidTextNode;
}
fn label(e: *ui.Engine, id: i64, value: []const u8) !void {
    var props = e.tree.get(id).?.props;
    const runs = [_]@TypeOf(props.runs.?[0]){.{ .t = value, .sz = props.fz orelse 14, .c = props.col orelse .{ 230, 232, 236, 1 } }};
    props.runs = &runs;
    props.al = value;
    try e.tree.updateUiProps(id, props);
}
fn height(e: *ui.Engine, id: i64, px: f32) !void {
    var props = e.tree.get(id).?.props;
    if (props.h != null and props.h.? == .px and props.h.?.px == px) return;
    props.h = .{ .px = px };
    try e.tree.updateUiProps(id, props);
}
/// display: none or not (the web frontend's `hidden` class).
fn display(e: *ui.Engine, id: i64, on: bool) !void {
    var props = e.tree.get(id).?.props;
    if (props.none == !on) return;
    props.none = !on;
    try e.tree.updateUiProps(id, props);
}
fn boot(e: *ui.Engine) !void {
    s.program = .init(e.gpa);
    s.action_arena = .init(e.gpa);
    s.initialized = true;
    inline for (.{ .{ Shell, 10000 }, .{ Row, 11000 }, .{ Disk, 12000 }, .{ Settings, 13000 }, .{ Actions, 14000 }, .{ Confirm, 15000 } }) |v| try v[0].prepare(&e.tree, v[1]);
    _ = try Shell.mount(&e.tree, root_id, 10000, &.{});
    e.tree.root = e.tree.get(root_id);
    load_settings(e) catch |err| std.log.warn("monitor settings: {s}", .{@errorName(err)});
    // Retain hidden sections so changing settings keeps their node identity.
    inline for (model.sections) |name| e.tree.get(sid(name)).?.stamp_owned = false;
    e.tree.get(sid("panels-row")).?.stamp_owned = false;
    try visibility(e);
    try sort_labels(e);
    try ui.invoke(e, info_request, "system_info", .{});
    try request_sample(e);
}
fn shutdown(e: *ui.Engine) void {
    if (!s.initialized) return;
    s.initialized = false;
    if (s.sample) |v| v.deinit();
    if (s.info) |v| v.deinit();
    if (s.settings_path) |path| e.gpa.free(path);
    s.action_arena.deinit();
    s.program.deinit();
    s.sample = null;
    s.info = null;
    s.settings_path = null;
}
fn load_settings(e: *ui.Engine) !void {
    const dir = try oriel.paths.appConfig(e.gpa, .{ .name = "dev.oriel.SystemMonitor" });
    defer e.gpa.free(dir);
    s.settings_path = try std.fs.path.join(e.gpa, &.{ dir, "oriel-settings.json" });
    const bytes = std.Io.Dir.cwd().readFileAlloc(s.io, s.settings_path.?, e.gpa, .limited(8192)) catch return;
    defer e.gpa.free(bytes);
    const parsed = std.json.parseFromSlice(SavedSettings, e.gpa, bytes, .{ .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    s.settings.shown = parsed.value.shown;
    s.settings.interval_ms = parsed.value.interval_ms;
    const name = std.mem.trimEnd(u8, parsed.value.interface, "\x00");
    s.settings.interface_len = @min(name.len, s.settings.interface.len);
    @memcpy(s.settings.interface[0..s.settings.interface_len], name[0..s.settings.interface_len]);
    s.settings.validate();
}
fn save_settings(e: *ui.Engine) !void {
    const path = s.settings_path orelse return;
    const bytes = try std.json.Stringify.valueAlloc(e.gpa, SavedSettings{ .shown = s.settings.shown, .interval_ms = s.settings.interval_ms, .interface = s.settings.interface[0..s.settings.interface_len] }, .{});
    defer e.gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = path, .data = bytes });
}
fn visibility(e: *ui.Engine) !void {
    var ids: [5]i64 = undefined;
    var panels: [4]i64 = undefined;
    var count: usize = 0;
    var panel_count: usize = 0;
    inline for (model.sections, 0..) |name, i| {
        const supported = if (s.sample) |v| switch (i) {
            4 => v.value.disks.len > 0,
            5 => v.value.net.len > 0,
            6 => v.value.sensors.len > 0,
            else => true,
        } else true;
        if (s.settings.shown[i] and supported) {
            if (i >= 3 and i <= 6) {
                panels[panel_count] = sid(name);
                panel_count += 1;
            } else if (i < 3) {
                ids[count] = sid(name);
                count += 1;
            }
        }
    }
    if (!try e.tree.stampKids(sid("panels-row"), panels[0..panel_count])) return error.InvalidTemplate;
    if (panel_count > 0) {
        ids[count] = sid("panels-row");
        count += 1;
    }
    if (s.settings.shown[7]) {
        ids[count] = sid("proc");
        count += 1;
    }
    if (!try e.tree.stampKids(sid("body"), ids[0..count])) return error.InvalidTemplate;
    try responsive(e, panels[0..panel_count], count == 1 and s.settings.shown[7]);
    if (s.settings_open) try settings_state(e);
}

fn new_timer() u32 {
    s.next_timer +%= 1;
    if (s.next_timer < 100 or s.next_timer >= std.math.maxInt(u32) - 10) s.next_timer = 100;
    return s.next_timer;
}
fn arm(e: *ui.Engine) void {
    s.timer_id = new_timer();
    if (!s.paused) e.backend.add_timer(e.backend.ctx, e, s.timer_id, s.settings.interval_ms);
}
fn request_sample(e: *ui.Engine) !void {
    if (s.in_flight) {
        s.pending_refresh = true;
        return;
    }
    s.in_flight = true;
    errdefer s.in_flight = false;
    try ui.invoke(e, sample_request, "sample", .{ .filter = s.filter[0..s.filter_len] });
}
fn timer(e: *ui.Engine, id: u32) !void {
    if (id == s.notification_timer) {
        s.notification_timer = 0;
        try display(e, sid("notification"), false);
    } else if (id == s.filter_timer) {
        s.filter_timer = 0;
        try request_sample(e);
    } else if (id == s.timer_id and !s.paused) try request_sample(e);
}
fn resolved(e: *ui.Engine, id: u32, ok: bool, json: []const u8) !void {
    switch (id) {
        sample_request => {
            s.in_flight = false;
            defer arm(e);
            errdefer if (s.manual_refresh) {
                s.manual_refresh = false;
                action_feedback(e, "Could not refresh the monitor. Try again.", false) catch {};
            };
            if (ok) {
                const sample = try std.json.parseFromSlice(tm.SystemSample, e.gpa, json, .{ .allocate = .alloc_always });
                if (s.sample) |old| old.deinit();
                s.sample = sample;
                s.samples += 1;
                s.history.push(sample.value);
                try visibility(e);
                try render_sample(e);
            } else try text(e, sid("status"), "Sampling failed. Refresh to retry.");
            if (s.manual_refresh and !s.pending_refresh) {
                s.manual_refresh = false;
                try action_feedback(e, if (ok) "Monitor refreshed." else "Refresh failed. Try again.", ok);
            }
            if (s.pending_refresh) {
                s.pending_refresh = false;
                try request_sample(e);
            }
        },
        info_request => {
            if (!ok) return;
            const info = try std.json.parseFromSlice(tm.SystemInfo, e.gpa, json, .{ .allocate = .alloc_always });
            if (s.info) |old| old.deinit();
            s.info = info;
            try render_system(e);
        },
        command_request => {
            s.command_in_flight = false;
            errdefer action_feedback(e, "Could not copy the command line. Try again.", false) catch {};
            if (!ok) {
                try action_feedback(e, "Could not read the full command line.", false);
                return;
            }
            const value = try std.json.parseFromSlice([]const u8, e.gpa, json, .{});
            defer value.deinit();
            if (value.value.len == 0 and !s.copy_details) {
                try action_feedback(e, "Command line unavailable; nothing copied.", false);
                return;
            }
            if (s.copy_details) try copy_row(e, value.value) else try copy(e, value.value, "command line");
        },
        clipboard_request => {
            const success = ok and std.mem.eql(u8, json, "true");
            var buf: [128]u8 = undefined;
            const message = if (success) try std.fmt.bufPrint(&buf, "Copied {s} to clipboard.", .{s.copy_label}) else "Clipboard copy failed. Try again.";
            try action_feedback(e, message, success);
        },
        end_request => {
            const success = ok and std.mem.eql(u8, json, "true");
            try action_feedback(e, if (success) "Process shutdown requested." else "Could not request shutdown. The process may have exited or require permission.", success);
            try request_sample(e);
        },
        else => {},
    }
}
fn render_system(e: *ui.Engine) !void {
    const info = if (s.info) |v| v.value else return;
    if (!s.settings.shown[1]) return;
    var buf: [600]u8 = undefined;
    var date: [40]u8 = undefined;
    var elapsed: [40]u8 = undefined;
    try text(e, sid("sys-host"), try std.fmt.bufPrint(&buf, "{s} · {s}", .{ info.hostname, info.arch }));
    const uptime = if (s.sample) |v| v.value.uptime_seconds else 0;
    const now = std.Io.Clock.Timestamp.now(s.io, .real).raw.toSeconds();
    const boot_text = try std.fmt.bufPrint(&buf, "{s} ({s} ago)", .{ fmt.clock(&date, now - @as(i64, @intCast(uptime)), "%Y-%m-%d %H:%M"), try fmt.uptime(&elapsed, uptime) });
    try charts.system(e, &s.program, sid("system-info"), info, boot_text);
}

fn render_sample(e: *ui.Engine) !void {
    const sample = s.sample.?.value;
    var buf: [4096]u8 = undefined;
    if (s.settings.shown[0]) {
        var used: [40]u8 = undefined;
        var total: [40]u8 = undefined;
        try text(e, sid("cpu-value"), try std.fmt.bufPrint(&buf, "{d:.1}%", .{sample.cpu.percent}));
        var model_text: [512]u8 = undefined;
        try text(e, sid("cpu-tile-detail"), try std.fmt.bufPrint(&buf, "{d} cores · {s}", .{ sample.cpu.cores, clean_model(&model_text, sample.cpu.model) }));
        try text(e, sid("mem-value"), try std.fmt.bufPrint(&buf, "{d:.1}%", .{sample.mem.percent}));
        try text(e, sid("mem-tile-detail"), try std.fmt.bufPrint(&buf, "{s} / {s}", .{ try fmt.bytes(&used, @floatFromInt(sample.mem.used_bytes)), try fmt.bytes(&total, @floatFromInt(sample.mem.total_bytes)) }));
        try text(e, sid("proc-value"), try std.fmt.bufPrint(&buf, "{d}", .{sample.total_processes}));
        try text(e, sid("thread-value"), try std.fmt.bufPrint(&buf, "{d} threads", .{sample.threads_total}));
        try text(e, sid("uptime"), try fmt.uptime(&buf, sample.uptime_seconds));
        try text(e, sid("cadence"), try std.fmt.bufPrint(&buf, "60 samples kept · {d} s cadence", .{s.settings.interval_ms / 1000}));
    }
    try render_system(e);
    if (s.settings.shown[2]) {
        const c = sample.cpu;
        try text(e, sid("cpu-detail"), c.model);
        // Apple Silicon doesn't tell its frequency: no "0.0 GHz".
        try display(e, sid("cpu-freq"), c.freq_mhz > 0);
        if (c.freq_mhz > 0) try text(e, sid("cpu-freq"), try std.fmt.bufPrint(&buf, "{d:.1} GHz", .{c.freq_mhz / 1000}));
        try text(e, sid("cpu-temp"), if (c.temp_c) |temp| try std.fmt.bufPrint(&buf, "{d:.0}°C", .{@round(temp)}) else "--°C");
        try text(e, sid("cpu-load"), if (c.load_avg) |load| try std.fmt.bufPrint(&buf, "Load {d:.2} {d:.2} {d:.2}", .{ load[0], load[1], load[2] }) else "Load --");
        try text(e, sid("cpu-tasks"), try std.fmt.bufPrint(&buf, "{d} running · {d} threads", .{ sample.running, sample.threads_total }));
        try core_height(e);
    }
    if (s.settings.shown[3]) {
        var amount: [40]u8 = undefined;
        try text(e, sid("mem-detail"), try std.fmt.bufPrint(&buf, "{s} total", .{try fmt.bytes(&amount, @floatFromInt(sample.mem.total_bytes))}));
    }
    if (s.settings.shown[4]) try render_disks(e);
    if (s.settings.shown[5]) try render_network(e);
    if (s.settings.shown[6]) try render_sensors(e);
    if (s.settings.shown[7]) try render_processes(e, false);
    var clock: [32]u8 = undefined;
    try text(e, sid("perf"), try std.fmt.bufPrint(&buf, "⚡ {d:.2} ms", .{sample.sample_time_ms}));
    try text(e, sid("status"), try std.fmt.bufPrint(&buf, "Sampling {s} · Last sample at {s}", .{ if (s.paused) "paused" else try std.fmt.bufPrint(buf[3000..], "every {d}s", .{s.settings.interval_ms / 1000}), fmt.clock(&clock, std.Io.Clock.Timestamp.now(s.io, .real).raw.toSeconds(), "%H:%M:%S") }));
    layout(e);
    try redraw(e);
}
fn gib(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1073741824;
}
fn core_height(e: *ui.Engine) !void {
    const sample = s.sample.?.value;
    const count = @min(sample.cpu.per_core.len, s.history.cores.len);
    const cols = charts.core_columns(e.tree.width, count);
    const core_h: f32 = @floatFromInt(((count + cols - 1) / cols) * 21 -| 3);
    try height(e, sid("core-chart"), @max(18, core_h));
    try height(e, sid("cpu-chart"), if (e.tree.width <= 1000) 110 else @max(96, core_h - 25));
}

fn render_disks(e: *ui.Engine) !void {
    const disks = s.sample.?.value.disks;
    const count = @min(disks.len, 128);
    var ids: [128]i64 = undefined;
    var read: f64 = 0;
    var write: f64 = 0;
    for (disks[0..count], 0..) |disk, i| {
        const id = disk_base + @as(i64, @intCast(i)) * 10;
        var a: [40]u8 = undefined;
        var b: [40]u8 = undefined;
        var size: [100]u8 = undefined;
        var mount: [800]u8 = undefined;
        var rw: [140]u8 = undefined;
        const size_text = try std.fmt.bufPrint(&size, "{s} / {s}", .{ try fmt.bytes(&a, @floatFromInt(disk.used_bytes)), try fmt.bytes(&b, @floatFromInt(disk.total_bytes)) });
        const rw_text = try std.fmt.bufPrint(&rw, "R {s} · W {s}", .{ try fmt.rate(&a, disk.read_bps), try fmt.rate(&b, disk.write_bps) });
        const bindings = [_]ui.Binding{ .{ .name = "name", .value = disk.name }, .{ .name = "size", .value = size_text }, .{ .name = "mount", .value = try std.fmt.bufPrint(&mount, "{s} · {s}", .{ disk.mount, disk.fs }) }, .{ .name = "rw", .value = rw_text } };
        if (e.tree.get(id) == null) {
            _ = try Disk.mount(&e.tree, id, 12000, &bindings);
        } else try Disk.update(&e.tree, id, &bindings);
        ids[i] = id;
        read += disk.read_bps;
        write += disk.write_bps;
    }
    if (!try e.tree.stampKids(sid("disk-list"), ids[0..count])) return error.InvalidTemplate;
    var a: [40]u8 = undefined;
    var b: [40]u8 = undefined;
    var rw: [140]u8 = undefined;
    try text(e, sid("disk-io"), try std.fmt.bufPrint(&rw, "R {s} · W {s}", .{ try fmt.rate(&a, read), try fmt.rate(&b, write) }));
    s.disk_count = count;
}

fn render_network(e: *ui.Engine) !void {
    const interfaces = s.sample.?.value.net;
    if (interfaces.len == 0) return;
    if (!s.network_selected) {
        var best: f64 = -1;
        for (interfaces, 0..) |n, i| {
            if (std.mem.eql(u8, n.name, s.settings.interface[0..s.settings.interface_len])) {
                s.network_index = i;
                best = std.math.inf(f64);
            }
            if (n.rx_bps + n.tx_bps > best) {
                best = n.rx_bps + n.tx_bps;
                s.network_index = i;
            }
        }
        s.network_selected = true;
    } else for (interfaces, 0..) |n, i| if (std.mem.eql(u8, n.name, s.settings.interface[0..s.settings.interface_len])) {
        s.network_index = i;
        break;
    };
    s.network_index = @min(s.network_index, interfaces.len - 1);
    const n = interfaces[s.network_index];
    s.settings.interface_len = @min(n.name.len, s.settings.interface.len);
    @memcpy(s.settings.interface[0..s.settings.interface_len], n.name[0..s.settings.interface_len]);
    try text(e, sid("net-iface"), n.name);
}

fn render_sensors(e: *ui.Engine) !void {
    const sensors = s.sample.?.value.sensors;
    var b: [40]u8 = undefined;
    try text(e, sid("sensor-count"), try std.fmt.bufPrint(&b, "{d} sensors", .{sensors.len}));
    try height(e, sid("sensor-detail"), @floatFromInt(sensors.len * 22));
}

fn render_processes(e: *ui.Engine, reset_scroll: bool) !void {
    const rows = model.select(s.sample.?.value.processes, s.filter[0..s.filter_len], s.order, &s.selected);
    s.selected_len = rows.len;
    if (reset_scroll) e.tree.get(sid("proc-scroll")).?.scroll_y = 0;
    var buf: [180]u8 = undefined;
    try text(e, sid("proc-detail"), try std.fmt.bufPrint(&buf, "{d} of {d}", .{ rows.len, s.sample.?.value.total_processes }));
    try render_rows(e);
}
fn render_rows(e: *ui.Engine) !void {
    const scroll = e.tree.get(sid("proc-scroll")).?;
    const max_scroll = @max(0, @as(f32, @floatFromInt(s.selected_len * row_height)) - scroll.frame.h);
    scroll.scroll_y = std.math.clamp(scroll.scroll_y, 0, max_scroll);
    const start = @min(s.selected_len, @as(usize, @intFromFloat(scroll.scroll_y / row_height)));
    // The rows the viewport shows, and one partly scrolled in.
    const shown: usize = @intFromFloat(@ceil(scroll.frame.h / row_height) + 1);
    const count = @min(row_capacity, shown, s.selected_len - start);
    var ids: [row_capacity]i64 = undefined;
    for (s.selected[start..][0..count], 0..) |row, i| {
        var buf: [2000]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        const fields = .{ .{ "pid", row.pid }, .{ "threads", row.threads } };
        var bindings: [9]ui.Binding = undefined;
        var offset: usize = 0;
        inline for (fields, 0..) |field, j| {
            try writer.print("{d}", .{field[1]});
            bindings[j] = .{ .name = field[0], .value = buf[offset..writer.end] };
            offset = writer.end;
        }
        try writer.print("{d:.1}%", .{row.cpu_percent});
        bindings[2] = .{ .name = "cpu", .value = buf[offset..writer.end] };
        offset = writer.end;
        var amount: [40]u8 = undefined;
        try writer.writeAll(try fmt.bytes(&amount, @floatFromInt(row.mem_rss_bytes)));
        bindings[3] = .{ .name = "mem", .value = buf[offset..writer.end] };
        bindings[4] = .{ .name = "name", .value = row.name };
        bindings[5] = .{ .name = "user", .value = row.user };
        bindings[6] = .{ .name = "state", .value = row.state };
        bindings[7] = .{ .name = "command", .value = row.command };
        offset = writer.end;
        try writer.print("Send SIGTERM to {s} ({d})", .{ row.name, row.pid });
        bindings[8] = .{ .name = "kill_tip", .value = buf[offset..writer.end] };
        const id = rows_base + @as(i64, @intCast(i)) * 20;
        if (e.tree.get(id) == null) {
            _ = try Row.mount(&e.tree, id, 11000, &bindings);
        } else try Row.update(&e.tree, id, &bindings);
        ids[i] = id;
    }
    if (!try e.tree.stampKids(sid("rows"), ids[0..count])) return error.InvalidTemplate;
    try height(e, sid("before"), @floatFromInt(start * row_height));
    try height(e, sid("after"), @floatFromInt((s.selected_len - start - count) * row_height));
}
fn redraw(e: *ui.Engine) !void {
    const sample = if (s.sample) |v| v.value else return;
    if (s.settings.shown[0]) {
        try charts.spark(e, &s.program, sid("cpu-spark"), &s.history.cpu, 100, 0x39c5bb);
        try charts.spark(e, &s.program, sid("mem-spark"), &s.history.mem, 100, 0x58a6ff);
        try charts.spark(e, &s.program, sid("proc-spark"), &s.history.proc, s.history.proc.peak(), 0x39c5bb);
    }
    if (s.settings.shown[2]) {
        try charts.cpu(e, &s.program, sid("cpu-chart"), &s.history);
        try charts.legend(e, &s.program, sid("cpu-legend"), sample.cpu);
        try charts.cores(e, &s.program, sid("core-chart"), &s.history, sample);
    }
    if (s.settings.shown[3]) try charts.memory(e, &s.program, sid("mem-chart"), sample.mem);
    if (s.settings.shown[4]) for (sample.disks[0..s.disk_count], 0..) |disk, i| try charts.disk(e, &s.program, Disk.id("bar", disk_base + @as(i64, @intCast(i)) * 10), disk);
    if (s.settings.shown[5] and sample.net.len > 0) if (s.history.network(sample.net[s.network_index].name)) |h| {
        try charts.network(e, &s.program, sid("net-chart"), h);
        try charts.net_stats(e, &s.program, sid("net-detail"), sample.net[s.network_index], h);
    };
    if (s.settings.shown[6]) try charts.sensors(e, &s.program, sid("sensor-detail"), sample.sensors);
    try render_system(e);
}
fn resized(e: *ui.Engine) !void {
    if (s.sample == null) return;
    try visibility(e);
    if (s.settings_open) try cap_overlay(e, settings_id, 52);
    if (s.actions_open) try cap_overlay(e, actions_id, 130);
    try core_height(e);
    layout(e);
    try redraw(e);
}
fn scrolled(e: *ui.Engine, id: i64) !void {
    if (id == sid("proc-scroll") and s.sample != null) try render_rows(e);
}
fn overlay_children(e: *ui.Engine) !void {
    var ids: [7]i64 = .{ root_id + 1, sid("body"), sid("footer"), 0, 0, 0, 0 };
    var len: usize = 3;
    if (s.settings_open) {
        ids[len] = settings_id;
        len += 1;
    }
    if (s.actions_open) {
        ids[len] = actions_id;
        len += 1;
    }
    if (s.confirm_open) {
        ids[len] = confirm_id;
        len += 1;
    }
    ids[len] = sid("notification");
    len += 1;
    if (!try e.tree.stampKids(root_id, ids[0..len])) return error.InvalidTemplate;
}
fn close_overlays(e: *ui.Engine) !void {
    s.settings_open = false;
    s.actions_open = false;
    s.confirm_open = false;
    try overlay_children(e);
}
fn open_settings(e: *ui.Engine) !void {
    try close_overlays(e);
    _ = try Settings.mount(&e.tree, settings_id, 13000, &.{});
    s.settings_open = true;
    try cap_overlay(e, settings_id, 52);
    try overlay_children(e);
    try visibility(e);
    inline for (.{ 1, 2, 5 }) |seconds| {
        const id = Settings.id(std.fmt.comptimePrint("interval-{d}", .{seconds}), settings_id);
        // As the web page's .btn-toggle: the chosen one raised, in bright text.
        const chosen = s.settings.interval_ms == seconds * 1000;
        var props = e.tree.get(id).?.props;
        props.bg = .{ .color = if (chosen) oriel.canvas.rgb(0x21262d) else .{ 0, 0, 0, 0 } };
        const ink = oriel.canvas.rgb(if (chosen) 0xf0f6fc else 0x8b949e);
        props.col = ink;
        var run = props.runs.?[0];
        run.c = ink;
        props.runs = &.{run};
        try e.tree.updateUiProps(id, props);
    }
}
fn process_at(e: *ui.Engine, id: i64) ?tm.ProcessRow {
    var node = e.tree.get(id);
    var depth: usize = 0;
    while (node != null and depth < 32) : (depth += 1) {
        const n = node.?;
        if (n.id >= rows_base and n.id < rows_base + row_capacity * 20 and @mod(n.id - rows_base, 20) == 0) {
            const start: usize = @intFromFloat(e.tree.get(sid("proc-scroll")).?.scroll_y / row_height);
            const index = start + @as(usize, @intCast(@divTrunc(n.id - rows_base, 20)));
            return if (index < s.selected_len) s.selected[index] else null;
        }
        node = n.parent;
    }
    return null;
}
fn open_actions(e: *ui.Engine, row: tm.ProcessRow) !void {
    if (s.command_in_flight) return;
    try close_overlays(e);
    s.action = null;
    _ = s.action_arena.reset(.retain_capacity);
    const a = s.action_arena.allocator();
    var owned = row;
    owned.name = try a.dupe(u8, row.name);
    owned.command = try a.dupe(u8, row.command);
    owned.user = try a.dupe(u8, row.user);
    owned.state = try a.dupe(u8, row.state);
    s.action = owned;
    _ = try Actions.mount(&e.tree, actions_id, 14000, &.{});
    s.actions_open = true;
    try cap_overlay(e, actions_id, 130);
    if (builtin.os.tag == .windows) try label(e, Actions.id("end", actions_id), "Close windows…");
    try overlay_children(e);
    layout(e);
    e.paintNow();
    e.backend.focus(e.backend.ctx, e.tree.get(Actions.id("end", actions_id)).?);
}
fn confirm(e: *ui.Engine) !void {
    const row = s.action orelse return;
    try close_overlays(e);
    _ = try Confirm.mount(&e.tree, confirm_id, 15000, &.{});
    s.confirm_open = true;
    var buf: [600]u8 = undefined;
    try text(e, Confirm.id("description", confirm_id), try std.fmt.bufPrint(&buf, "{s} · PID {d}\n{s}", .{ row.name, row.pid, if (builtin.os.tag == .windows) "Sends WM_CLOSE to its windows." else "Sends SIGTERM. The process can handle this request." }));
    if (builtin.os.tag == .windows) try label(e, Confirm.id("confirm", confirm_id), "Close windows");
    try overlay_children(e);
    layout(e);
    e.paintNow();
    e.backend.focus(e.backend.ctx, e.tree.get(Confirm.id("cancel", confirm_id)).?);
}
fn action_feedback(e: *ui.Engine, message: []const u8, success: bool) !void {
    try text(e, sid("footer-status"), message);
    var props = e.tree.get(sid("footer-status")).?.props;
    props.col = oriel.canvas.rgb(if (success) 0x7ee787 else 0xff7b72);
    try e.tree.updateUiProps(sid("footer-status"), props);
    try text(e, sid("notification-message"), message);
    try display(e, sid("notification-success"), success);
    try display(e, sid("notification-failure"), !success);
    var notification = e.tree.get(sid("notification")).?.props;
    notification.none = false;
    notification.bg = .{ .color = oriel.canvas.rgb(if (success) 0x163022 else 0x3d1f24) };
    const border = oriel.canvas.rgb(if (success) 0x3fb950 else 0xff7b72);
    notification.bc = .{ border, border, border, border };
    try e.tree.updateUiProps(sid("notification"), notification);
    s.notification_timer = new_timer();
    e.backend.add_timer(e.backend.ctx, e, s.notification_timer, if (success) 4000 else 8000);
}
fn copy(e: *ui.Engine, value: []const u8, label_text: []const u8) !void {
    s.copy_label = label_text;
    try close_overlays(e);
    try text(e, sid("footer-status"), "Copying to clipboard…");
    try ui.invoke(e, clipboard_request, "copy_to_clipboard", .{ .text = value });
}
fn manual_refresh(e: *ui.Engine) !void {
    s.manual_refresh = true;
    errdefer s.manual_refresh = false;
    try close_overlays(e);
    try text(e, sid("footer-status"), "Refreshing monitor…");
    try request_sample(e);
}
fn copy_row(e: *ui.Engine, command: []const u8) !void {
    const row = s.action orelse return;
    const value = try std.fmt.allocPrint(e.gpa, "PID {d}\nName {s}\nUser {s}\nState {s}\nThreads {d}\nCPU {d:.1}%\nRSS {d} bytes\nCommand {s}", .{ row.pid, row.name, row.user, row.state, row.threads, row.cpu_percent, row.mem_rss_bytes, command });
    defer e.gpa.free(value);
    try copy(e, value, "full process row");
}
fn set_filter(e: *ui.Engine, value: []const u8, echo: bool) !void {
    s.filter_len = @min(value.len, s.filter.len);
    @memcpy(s.filter[0..s.filter_len], value[0..s.filter_len]);
    if (echo) {
        var props = e.tree.get(sid("search")).?.props;
        props.val = s.filter[0..s.filter_len];
        try e.tree.updateUiProps(sid("search"), props);
    } else try e.tree.acceptUiValue(sid("search"), s.filter[0..s.filter_len]);
    var clear = e.tree.get(sid("clear")).?.props;
    if (clear.vis != (s.filter_len > 0)) {
        clear.vis = s.filter_len > 0;
        try e.tree.updateUiProps(sid("clear"), clear);
    }
    if (s.sample != null) try render_processes(e, true);
    s.filter_timer = new_timer();
    e.backend.add_timer(e.backend.ctx, e, s.filter_timer, 250);
}
fn event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) bool {
    return handle_event(e, id, kind, data) catch |err| {
        std.log.err("monitor UI: {s}", .{@errorName(err)});
        action_feedback(e, "Could not complete the action.", false) catch {};
        return true;
    };
}
fn handle_event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) !bool {
    if (id == sid("notification-dismiss") and std.mem.eql(u8, kind, "click")) {
        s.notification_timer = 0;
        try display(e, sid("notification"), false);
        return true;
    }
    if (std.mem.eql(u8, kind, "key") and std.mem.indexOf(u8, data, "Escape") != null) {
        try close_overlays(e);
        return true;
    }
    if (std.mem.eql(u8, kind, "input") and id == sid("search")) {
        if (s.confirm_open) return true;
        const value = try std.json.parseFromSlice([]const u8, e.gpa, data, .{});
        defer value.deinit();
        try set_filter(e, value.value, false);
        return true;
    }
    if (s.actions_open and std.mem.eql(u8, kind, "hover")) {
        var node = e.tree.get(id);
        var inside = id == Actions.id("copy", actions_id);
        var depth: usize = 0;
        while (node != null and depth < 32) : (depth += 1) {
            if (node.?.id == Actions.id("copy-menu", actions_id)) {
                inside = true;
                break;
            }
            node = node.?.parent;
        }
        try copy_menu(e, inside);
        try action_hover(e, id);
        return false;
    }
    const click = std.mem.eql(u8, kind, "click");
    const context = std.mem.eql(u8, kind, "contextmenu");
    if (!click and !context) return false;
    if (s.confirm_open) {
        if (id == Confirm.id("cancel", confirm_id)) {
            try close_overlays(e);
            try action_feedback(e, "Process shutdown cancelled.", true);
        }
        if (id == Confirm.id("confirm", confirm_id)) {
            const row = s.action orelse return true;
            try close_overlays(e);
            if (row.pid <= std.math.maxInt(i32)) {
                try text(e, sid("footer-status"), "Requesting process shutdown…");
                try ui.invoke(e, end_request, "terminate_process", .{ .pid = @as(i32, @intCast(row.pid)) });
            } else try action_feedback(e, "Could not request shutdown: invalid process ID.", false);
        }
        return true;
    }
    if (s.actions_open and try action_click(e, id)) return true;
    if (s.settings_open and try settings_click(e, id)) return true;
    if (process_at(e, id)) |row| {
        if (id == Row.id("copy", rows_base + @divTrunc(id - rows_base, 20) * 20)) {
            try copy(e, row.name, "process name");
            return true;
        }
        if (context or id == Row.id("actions", rows_base + @divTrunc(id - rows_base, 20) * 20)) {
            try open_actions(e, row);
            if (!context) try confirm(e) else {
                const point = std.json.parseFromSlice([2]f32, e.gpa, data, .{}) catch return true;
                defer point.deinit();
                var props = e.tree.get(actions_id).?.props;
                props.ins = .{ .{ .px = std.math.clamp(point.value[1], 0, @max(0, e.tree.height - 165)) }, null, null, .{ .px = std.math.clamp(point.value[0], 0, @max(0, e.tree.width - 210)) } };
                try e.tree.updateUiProps(actions_id, props);
            }
            return true;
        }
    }
    if (try toolbar_click(e, id)) return true;
    var node = e.tree.get(id);
    var depth: usize = 0;
    while (node != null and depth < 32) : (depth += 1) {
        if (node.?.id == sid("cpu-tile")) {
            s.settings.shown[2] = !s.settings.shown[2];
            try visibility(e);
            try save_settings(e);
            if (s.sample != null) try render_sample(e);
            try action_feedback(e, if (s.settings.shown[2]) "CPU chart shown." else "CPU chart hidden.", true);
            return true;
        }
        node = node.?.parent;
    }
    if (s.settings_open or s.actions_open) try close_overlays(e);
    return false;
}
fn settings_click(e: *ui.Engine, id: i64) !bool {
    inline for (model.sections, 0..) |name, i| if (id == Settings.id(name, settings_id)) {
        s.settings.shown[i] = !s.settings.shown[i];
        try visibility(e);
        try save_settings(e);
        if (s.sample != null) try render_sample(e);
        try action_feedback(e, "Display settings saved.", true);
        return true;
    };
    inline for (.{ 1, 2, 5 }) |seconds| if (id == Settings.id(std.fmt.comptimePrint("interval-{d}", .{seconds}), settings_id)) {
        s.settings.interval_ms = seconds * 1000;
        arm(e);
        try save_settings(e);
        try open_settings(e);
        try action_feedback(e, std.fmt.comptimePrint("Refresh interval set to {d} seconds.", .{seconds}), true);
        return true;
    };
    return false;
}
fn action_click(e: *ui.Engine, id: i64) !bool {
    const row = s.action orelse return false;
    if (id == Actions.id("end", actions_id)) {
        try confirm(e);
        return true;
    }
    if (id == Actions.id("copy", actions_id)) {
        try copy_menu(e, true);
        return true;
    }
    if (id == Actions.id("name", actions_id)) {
        try copy(e, row.name, "process name");
        return true;
    }
    if (id == Actions.id("pid", actions_id)) {
        var buf: [20]u8 = undefined;
        try copy(e, try std.fmt.bufPrint(&buf, "{d}", .{row.pid}), "PID");
        return true;
    }
    if (id == Actions.id("command", actions_id) or id == Actions.id("details", actions_id)) {
        if (s.command_in_flight) return true;
        s.command_in_flight = true;
        errdefer s.command_in_flight = false;
        s.copy_details = id == Actions.id("details", actions_id);
        try close_overlays(e);
        try text(e, sid("footer-status"), "Reading command line…");
        try ui.invoke(e, command_request, "command_line", .{ .pid = row.pid });
        return true;
    }
    if (id == Actions.id("filter", actions_id)) {
        try set_filter(e, row.name, true);
        try close_overlays(e);
        try action_feedback(e, "Process filter applied.", true);
        return true;
    }
    if (id == Actions.id("refresh", actions_id)) {
        try manual_refresh(e);
        return true;
    }
    return false;
}
fn switch_network(e: *ui.Engine, forward: bool) !void {
    const sample = if (s.sample) |v| v.value else return;
    if (sample.net.len == 0) return;
    s.network_index = (s.network_index + if (forward) @as(usize, 1) else sample.net.len - 1) % sample.net.len;
    s.settings.interface_len = 0;
    try render_network(e);
    try save_settings(e);
    try redraw(e);
    try action_feedback(e, "Network interface changed.", true);
}

fn toolbar_click(e: *ui.Engine, id: i64) !bool {
    if (id == sid("settings")) {
        if (s.settings_open) try close_overlays(e) else try open_settings(e);
        return true;
    }
    if (id == sid("pause")) {
        s.paused = !s.paused;
        s.timer_id = new_timer();
        try label(e, sid("pause"), if (s.paused) "▶ Resume" else "⏸ Pause");
        if (!s.paused) try request_sample(e);
        try action_feedback(e, if (s.paused) "Sampling paused. Manual refresh is still available." else "Sampling resumed.", true);
        return true;
    }
    if (id == sid("refresh")) {
        try manual_refresh(e);
        return true;
    }
    if (id == sid("sort-dir")) {
        s.order.descending = !s.order.descending;
        try label(e, sid("sort-dir"), if (s.order.descending) "▼" else "▲");
        if (s.sample != null) try render_processes(e, false);
        try action_feedback(e, if (s.order.descending) "Processes sorted in descending order." else "Processes sorted in ascending order.", true);
        return true;
    }
    if (id == sid("clear")) {
        try set_filter(e, "", true);
        try action_feedback(e, "Process filter cleared.", true);
        return true;
    }
    inline for (.{ "cpu", "mem", "threads", "pid", "name" }) |field| if (id == sid("sort-" ++ field)) {
        const sort: model.Sort = @field(model.Sort, field);
        s.order = .{ .field = sort, .descending = if (s.order.field == sort) !s.order.descending else sort != .name and sort != .pid };
        try sort_labels(e);
        if (s.sample != null) try render_processes(e, true);
        try action_feedback(e, "Process sort updated.", true);
        return true;
    };
    if (id == sid("net-prev") or id == sid("net-next")) {
        try switch_network(e, id == sid("net-next"));
        return true;
    }
    return false;
}

fn layout(e: *ui.Engine) void {
    e.tree.layout();
    e.relaid = true;
}

fn cap_overlay(e: *ui.Engine, id: i64, top: f32) !void {
    var props = e.tree.get(id).?.props;
    props.maxh = .{ .px = @max(180, e.tree.height - top - 20) };
    try e.tree.updateUiProps(id, props);
}

fn sort_labels(e: *ui.Engine) !void {
    inline for (.{ .{ "cpu", "CPU" }, .{ "mem", "Memory" }, .{ "threads", "Threads" }, .{ "pid", "PID" }, .{ "name", "Name" } }) |chip| {
        const id = sid("sort-" ++ chip[0]);
        const active = s.order.field == @field(model.Sort, chip[0]);
        var props = e.tree.get(id).?.props;
        props.bg = .{ .color = oriel.canvas.rgb(if (active) 0x21262d else 0x0e1117) };
        props.col = oriel.canvas.rgb(if (active) 0xf0f6fc else 0x8b949e);
        try e.tree.updateUiProps(id, props);
        // The label's run carries the color.
        try label(e, id, chip[1]);
    }
    try label(e, sid("sort-dir"), if (s.order.descending) "▼" else "▲");
}

fn width(e: *ui.Engine, id: i64, px: f32) !void {
    var props = e.tree.get(id).?.props;
    if (props.w != null and props.w.? == .px and props.w.?.px == px) return;
    props.w = .{ .px = px };
    try e.tree.updateUiProps(id, props);
}
fn responsive(e: *ui.Engine, panels: []const i64, processes_only: bool) !void {
    const body = e.tree.get(sid("body")).?;
    const available = @max(100, e.tree.width - 32 - body.gutter);
    const tile_cols: usize = if (e.tree.width > 1000) 4 else 2;
    const tile_w = (available - @as(f32, @floatFromInt(tile_cols - 1)) * 12) / @as(f32, @floatFromInt(tile_cols));
    inline for (.{ "cpu-tile", "mem-tile", "proc-tile", "uptime-tile" }) |id| try width(e, sid(id), tile_w);
    const cols: usize = if (e.tree.width <= 1000) 1 else if (panels.len == 3) 4 else if (e.tree.width <= 1400) @min(2, panels.len) else panels.len;
    if (cols > 0) for (panels, 0..) |id, i| {
        const unit = (available - @as(f32, @floatFromInt(cols - 1)) * 12) / @as(f32, @floatFromInt(cols));
        const span: f32 = if (panels.len == 3 and cols == 4 and i == 1) 2 else 1;
        try width(e, id, unit * span + (span - 1) * 12);
    };
    var axis = e.tree.get(sid("cpu-body")).?.props;
    const direction = if (e.tree.width <= 1000) "column" else "row";
    if (!std.mem.eql(u8, axis.fd orelse "column", direction)) {
        axis.fd = direction;
        try e.tree.updateUiProps(sid("cpu-body"), axis);
    }
    inline for (.{ "cpu-graph", "core-chart" }) |id| {
        var props = e.tree.get(sid(id)).?.props;
        const grow: f32 = if (e.tree.width <= 1000) 0 else 1;
        if (props.fg != grow) {
            props.fg = grow;
            props.fb = if (grow == 0) null else .{ .px = 0 };
            try e.tree.updateUiProps(sid(id), props);
        }
    }
    const system_cols: usize = if (e.tree.width > 1400) 3 else if (e.tree.width > 1000) 2 else 1;
    try height(e, sid("system-info"), @floatFromInt(6 / system_cols * 24 - 6));
    // Processes alone: the list fills the window (#body stops scrolling, so
    // flex bounds it); else a fixed list in the scrolling page.
    var page = e.tree.get(sid("body")).?.props;
    if (page.scroll == processes_only) {
        page.scroll = !processes_only;
        try e.tree.updateUiProps(sid("body"), page);
    }
    var list = e.tree.get(sid("proc-scroll")).?.props;
    list.h = if (processes_only) null else .{ .px = 329 };
    try e.tree.updateUiProps(sid("proc-scroll"), list);
}
fn settings_state(e: *ui.Engine) !void {
    layout(e);
    inline for (model.sections, 0..) |name, i| try charts.toggle(e, &s.program, Settings.id(name ++ "-switch", settings_id), s.settings.shown[i]);
}

fn action_hover(e: *ui.Engine, hovered: i64) !void {
    const ids = comptime blk: {
        const names = .{ "end", "copy", "name", "pid", "command", "details", "filter", "refresh" };
        var ids: [names.len]i64 = undefined;
        for (names, 0..) |name, i| ids[i] = Actions.id(name, actions_id);
        break :blk ids;
    };
    for (ids) |id| {
        const node = e.tree.get(id) orelse continue;
        const color = oriel.canvas.rgb(if (id == hovered) 0x30363d else 0x1f242c);
        if (node.props.bg) |bg| if (bg.color) |current| {
            if (std.mem.eql(f32, &current, &color)) continue;
        };
        var props = node.props;
        props.bg = .{ .color = color };
        try e.tree.updateUiProps(id, props);
    }
}

fn copy_menu(e: *ui.Engine, show: bool) !void {
    const id = Actions.id("copy-menu", actions_id);
    var props = e.tree.get(id).?.props;
    if (props.vis == show) return;
    // Markup propagates the initial hidden state to the menu's controls.
    try ui.setVisible(&e.tree, id, show);
    props.vis = show;
    props.h = if (show) null else .{ .px = 0 };
    try e.tree.updateUiProps(id, props);
}

fn clean_model(buffer: []u8, value: []const u8) []const u8 {
    var words = std.mem.tokenizeScalar(u8, value, ' ');
    var written: usize = 0;
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "Processor") or std.mem.endsWith(u8, word, "-Core")) continue;
        if (written + word.len + 1 > buffer.len) break;
        if (written > 0) {
            buffer[written] = ' ';
            written += 1;
        }
        @memcpy(buffer[written..][0..word.len], word);
        written += word.len;
    }
    return buffer[0..written];
}
