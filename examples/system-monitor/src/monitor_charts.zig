//! Drawing translated directly from web/app.js; no continuous frame callback.
const std = @import("std");
const oriel = @import("oriel");
const ui = oriel.ui;
const model = @import("monitor_model.zig");
const tm = @import("telemetry.zig");
const fmt = @import("monitor_format.zig");
const rgb = oriel.canvas.rgb;
const Size = struct { w: f32, h: f32 };
const sans = "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto, Helvetica, Arial, sans-serif";
const mono = "ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace";
fn start(e: *ui.Engine, p: *ui.Program, id: i64, background: u24) ?Size {
    const n = e.tree.get(id) orelse return null;
    if (n.frame.w < 1 or n.frame.h < 1) return null;
    p.begin();
    p.fillStyle(rgb(background));
    p.fillRect(0, 0, n.frame.w, n.frame.h);
    return .{ .w = n.frame.w, .h = n.frame.h };
}
fn finish(e: *ui.Engine, p: *ui.Program, id: i64) !void {
    if (p.failed) return error.OutOfMemory;
    p.last_len = p.cmds.items.len;
    if (!e.tree.commitCanvas(id, p.cmds.items, &p.arena)) return error.MissingCanvas;
}
fn bars(p: *ui.Program, history: *const model.History, x: f32, y: f32, width: f32, height: f32, maximum: f64, color: u24) void {
    const step = width / 60;
    const start_x = x + width - @as(f32, @floatFromInt(history.len)) * step;
    p.fillStyle(rgb(color));
    for (0..history.len) |i| {
        const h = @max(1, @as(f32, @floatCast(std.math.clamp(history.at(i) / @max(1, maximum), 0, 1))) * (height - 2));
        p.fillRect(start_x + @as(f32, @floatFromInt(i)) * step, y + height - h, @max(1, step - 1), h);
    }
}
pub fn spark(e: *ui.Engine, p: *ui.Program, id: i64, hist: *const model.History, maximum: f64, color: u24) !void {
    const size = start(e, p, id, 0x161b22) orelse return;
    if (maximum == 100) bars(p, hist, 0, 0, size.w, size.h, maximum, color) else if (hist.len > 0) {
        var minimum = hist.at(0);
        for (0..hist.len) |i| minimum = @min(minimum, hist.at(i));
        minimum *= 0.9;
        const range = @max(1, maximum * 1.1 - minimum);
        const step = size.w / 60;
        const x0 = size.w - @as(f32, @floatFromInt(hist.len)) * step;
        p.beginPath();
        for (0..hist.len) |i| {
            const x = x0 + @as(f32, @floatFromInt(i)) * step;
            const y = size.h - @as(f32, @floatCast((hist.at(i) - minimum) / range)) * (size.h - 4) - 2;
            if (i == 0) p.moveTo(x, y) else p.lineTo(x, y);
        }
        p.strokeStyle(rgb(color));
        p.lineWidth(1.5);
        p.stroke();
        p.lineTo(x0 + @as(f32, @floatFromInt(hist.len - 1)) * step, size.h);
        p.lineTo(x0, size.h);
        p.closePath();
        p.fillStyle(oriel.canvas.rgba(color, 0.12));
        p.fill();
    }
    try finish(e, p, id);
}
pub fn cpu(e: *ui.Engine, p: *ui.Program, id: i64, h: *const model.Histories) !void {
    const size = start(e, p, id, 0x0e1117) orelse return;
    p.fillStyle(oriel.canvas.rgba(0x8b949e, 0.12));
    for ([_]f32{ 0.25, 0.5, 0.75 }) |q| p.fillRect(0, @round(size.h * q), size.w, 1);
    const colors = [_]u24{ 0x39c5bb, 0x58a6ff, 0xd29922 };
    const step = size.w / 60;
    for (0..h.cpu.len) |i| {
        const x = size.w - @as(f32, @floatFromInt(h.cpu.len - i)) * step;
        var bottom = size.h;
        for ([_]f64{ h.user.at(i), h.system.at(i), h.wait.at(i) }, colors) |value, color| {
            const height = (size.h - 2) * @as(f32, @floatCast(std.math.clamp(value / 100, 0, 1)));
            bottom -= height;
            p.fillStyle(rgb(color));
            p.fillRect(x, bottom, @max(1, step - 1), height);
        }
    }
    try finish(e, p, id);
}
pub fn legend(e: *ui.Engine, p: *ui.Program, id: i64, c: tm.CpuInfo) !void {
    _ = start(e, p, id, 0x161b22) orelse return;
    const names = [_][]const u8{ "user", "system", "iowait" };
    const values = [_]f64{ c.user_percent, c.system_percent, c.iowait_percent orelse 0 };
    const colors = [_]u24{ 0x39c5bb, 0x58a6ff, 0xd29922 };
    for (names, values, colors, 0..) |name, value, color, i| {
        const x = @as(f32, @floatFromInt(i)) * 124;
        var b: [64]u8 = undefined;
        p.fillStyle(rgb(color));
        p.fillRect(x, 4, 10, 10);
        p.font(11, 400, false, sans);
        p.fillStyle(rgb(0x8b949e));
        p.fillText(name, x + 16, 13);
        p.font(11, 600, false, mono);
        p.fillStyle(rgb(0xf0f6fc));
        p.fillText(try std.fmt.bufPrint(&b, "{d:.1}%", .{value}), x + if (i == 1) @as(f32, 62) else 48, 13);
    }
    try finish(e, p, id);
}
pub fn core_columns(width: f32, count: usize) usize {
    return if (width >= 1800) (if (count <= 8) 2 else 4) else if (count <= 8) 1 else if (count > 32) 4 else 2;
}
pub fn cores(e: *ui.Engine, p: *ui.Program, id: i64, h: *const model.Histories, sample: tm.SystemSample) !void {
    const size = start(e, p, id, 0x161b22) orelse return;
    const count = @min(sample.cpu.per_core.len, h.cores.len);
    const cols = core_columns(e.tree.width, count);
    const width = (size.w - @as(f32, @floatFromInt(cols - 1)) * 16) / @as(f32, @floatFromInt(cols));
    p.font(11, 400, false, mono);
    for (sample.cpu.per_core[0..count], 0..) |core, i| {
        const x = @as(f32, @floatFromInt(i % cols)) * (width + 16);
        const y = @as(f32, @floatFromInt(i / cols)) * 21;
        var b: [64]u8 = undefined;
        p.textAlign(.left);
        p.fillStyle(rgb(0x8b949e));
        p.fillText(try std.fmt.bufPrint(&b, "C{d}", .{i}), x, y + 13);
        const chart_w = @max(1, width - 30 - 38 - 46 - 24);
        p.fillStyle(oriel.canvas.rgba(0x8b949e, 0.08));
        p.fillRect(x + 38, y + 2, chart_w, 14);
        bars(p, &h.cores[i], x + 38, y + 2, chart_w, 14, 100, 0x39c5bb);
        p.textAlign(.right);
        p.fillStyle(rgb(0xf0f6fc));
        p.fillText(try std.fmt.bufPrint(&b, "{d:.0}%", .{core.percent}), x + width - 54, y + 13);
        p.fillStyle(rgb(0x6e7681));
        if (core.freq_mhz > 0) p.fillText(try std.fmt.bufPrint(&b, "{d:.1}G", .{core.freq_mhz / 1000}), x + width, y + 13);
    }
    try finish(e, p, id);
}
pub fn memory(e: *ui.Engine, p: *ui.Program, id: i64, m: tm.MemInfo) !void {
    const size = start(e, p, id, 0x161b22) orelse return;
    const names = [_][]const u8{ "Used", "Available", "Cached", "Free", "Swap" };
    const values = [_]u64{ m.used_bytes, m.available_bytes, m.cached_bytes, m.free_bytes, m.swap_used_bytes };
    const colors = [_]u24{ 0x58a6ff, 0x39c5bb, 0xa371f7, 0x3fb950, 0xd29922 };
    for (names, values, colors, 0..) |name, value, color, i| {
        const y = @as(f32, @floatFromInt(i)) * 35;
        var b: [96]u8 = undefined;
        var amount: [40]u8 = undefined;
        var total_b: [40]u8 = undefined;
        const total = if (i == 4) m.swap_total_bytes else m.total_bytes;
        const pct = tm.pct(value, total);
        p.font(12, 400, false, sans);
        p.textAlign(.left);
        p.fillStyle(rgb(0x8b949e));
        p.fillText(name, 0, y + 13);
        const label = if (i == 4) try std.fmt.bufPrint(&b, "{s} / {s}", .{ try fmt.bytes(&amount, @floatFromInt(value)), try fmt.bytes(&total_b, @floatFromInt(total)) }) else try std.fmt.bufPrint(&b, "{s} · {d:.0}%", .{ try fmt.bytes(&amount, @floatFromInt(value)), @round(pct) });
        p.font(12, 400, false, mono);
        p.textAlign(.right);
        p.fillStyle(rgb(0xf0f6fc));
        p.fillText(label, size.w, y + 13);
        p.fillStyle(rgb(0x0e1117));
        p.fillRect(0, y + 21, size.w, 6);
        p.fillStyle(rgb(color));
        p.fillRect(0, y + 21, size.w * @as(f32, @floatCast(std.math.clamp(pct / 100, 0, 1))), 6);
    }
    try finish(e, p, id);
}
pub fn disk(e: *ui.Engine, p: *ui.Program, id: i64, sample: tm.DiskSample) !void {
    const size = start(e, p, id, 0x0e1117) orelse return;
    p.fillStyle(rgb(0xa371f7));
    p.fillRect(0, 0, size.w * @as(f32, @floatCast(tm.pct(sample.used_bytes, sample.total_bytes) / 100)), size.h);
    try finish(e, p, id);
}
pub fn network(e: *ui.Engine, p: *ui.Program, id: i64, hist: *const model.NetHistory) !void {
    const size = start(e, p, id, 0x0e1117) orelse return;
    const max = @max(1024, @max(hist.rx.peak(), hist.tx.peak()));
    const mid = @round(size.h / 2);
    p.fillStyle(oriel.canvas.rgba(0x8b949e, 0.18));
    p.fillRect(0, mid, size.w, 1);
    const step = size.w / 60;
    for (0..hist.rx.len) |i| {
        const x = size.w - @as(f32, @floatFromInt(hist.rx.len - i)) * step;
        const rx = @as(f32, @floatCast(hist.rx.at(i) / max)) * (mid - 2);
        const tx = @as(f32, @floatCast(hist.tx.at(i) / max)) * (mid - 2);
        if (rx > 0.5) {
            p.fillStyle(rgb(0x39c5bb));
            p.fillRect(x, mid - rx, @max(1, step - 1), rx);
        }
        if (tx > 0.5) {
            p.fillStyle(rgb(0xa371f7));
            p.fillRect(x, mid + 1, @max(1, step - 1), tx);
        }
    }
    try finish(e, p, id);
}
pub fn net_stats(e: *ui.Engine, p: *ui.Program, id: i64, n: tm.NetSample, hist: *const model.NetHistory) !void {
    const size = start(e, p, id, 0x161b22) orelse return;
    for (0..2) |i| {
        const x = if (i == 0) @as(f32, 0) else (size.w + 12) / 2;
        var b: [90]u8 = undefined;
        var value: [40]u8 = undefined;
        p.font(11, 600, false, sans);
        p.fillStyle(rgb(if (i == 0) 0x39c5bb else 0xa371f7));
        p.fillText(if (i == 0) "▼ Download" else "▲ Upload", x, 12);
        p.font(16, 700, false, mono);
        p.fillStyle(rgb(0xf0f6fc));
        p.fillText(try fmt.rate(&b, if (i == 0) n.rx_bps else n.tx_bps), x, 35);
        p.font(11, 400, false, sans);
        p.fillStyle(rgb(0x6e7681));
        p.fillText(try std.fmt.bufPrint(&b, "Top {s}", .{try fmt.rate(&value, if (i == 0) hist.rx.peak() else hist.tx.peak())}), x, 53);
        p.fillText(try std.fmt.bufPrint(&b, "Total {s}", .{try fmt.bytes(&value, @floatFromInt(if (i == 0) n.rx_total else n.tx_total))}), x, 70);
    }
    try finish(e, p, id);
}
pub fn sensors(e: *ui.Engine, p: *ui.Program, id: i64, values: []const tm.SensorSample) !void {
    const size = start(e, p, id, 0x161b22) orelse return;
    for (values, 0..) |sensor, i| {
        const y = @as(f32, @floatFromInt(i)) * 22;
        var b: [40]u8 = undefined;
        p.font(12, 400, false, sans);
        p.textAlign(.left);
        p.fillStyle(rgb(0x8b949e));
        p.fillText(sensor.name, 0, y + 14);
        p.font(12, 400, false, mono);
        p.textAlign(.right);
        p.fillStyle(rgb(if (sensor.temp_c >= 90) 0xf85149 else if (sensor.temp_c >= 75) 0xd29922 else if (sensor.temp_c >= 55) 0xf0f6fc else 0x39c5bb));
        p.fillText(try std.fmt.bufPrint(&b, "{d:.0}°C", .{@round(sensor.temp_c)}), size.w, y + 14);
    }
    try finish(e, p, id);
}
pub fn system(e: *ui.Engine, p: *ui.Program, id: i64, info: tm.SystemInfo, boot: []const u8) !void {
    const size = start(e, p, id, 0x161b22) orelse return;
    const cols: usize = if (e.tree.width > 1400) 3 else if (e.tree.width > 1000) 2 else 1;
    const width = (size.w - @as(f32, @floatFromInt(cols - 1)) * 18) / @as(f32, @floatFromInt(cols));
    const keys = [_][]const u8{ "OS", "Kernel", "Board", "BIOS", "CPU", "Booted" };
    const values = [_][]const u8{ info.os, info.kernel, info.board, info.bios, info.cpu_model, boot };
    for (keys, values, 0..) |key, value, i| {
        const x = @as(f32, @floatFromInt(i % cols)) * (width + 18);
        const y = @as(f32, @floatFromInt(i / cols)) * 24 + 14;
        p.save();
        p.beginPath();
        p.rect(x, y - 14, width, 18);
        p.clip();
        p.font(12, 400, false, sans);
        p.fillStyle(rgb(0x6e7681));
        p.fillText(key, x, y);
        p.fillStyle(rgb(0xf0f6fc));
        p.fillText(value, x + 60, y);
        p.restore();
    }
    try finish(e, p, id);
}

pub fn toggle(e: *ui.Engine, p: *ui.Program, id: i64, on: bool) !void {
    _ = start(e, p, id, 0x1f242c) orelse return;
    // The track: one pill (a translucent color filled once, not a
    // rectangle and two ends whose overlaps would show darker).
    p.fillStyle(if (on) oriel.canvas.rgba(0x39c5bb, 0.45) else rgb(0x30363d));
    p.beginPath();
    p.arc(8, 8, 8, std.math.pi / 2.0, 3 * std.math.pi / 2.0, false);
    p.lineTo(22, 0);
    p.arc(22, 8, 8, -std.math.pi / 2.0, std.math.pi / 2.0, false);
    p.closePath();
    p.fill();
    p.fillStyle(rgb(if (on) 0x39c5bb else 0x8b949e));
    p.circle(if (on) 22 else 8, 8, 6);
    p.fill();
    try finish(e, p, id);
}
