//! The same render-bench workloads, driven by Zig and .oriel templates.
const std = @import("std");
const oriel = @import("oriel");
const ui = oriel.ui;
const host = @import("main.zig");
const balls_direct = @import("zig_balls.zig");
const Shell = ui.View(@embedFile("views/bench.oriel"));
const Row = ui.View(@embedFile("views/row.oriel"));
const ResultView = ui.View(@embedFile("views/result.oriel"));
const Box = ui.View(@embedFile("views/box.oriel"));
const Canvas = ui.View(@embedFile("views/canvas.oriel"));
const List = ui.View(@embedFile("views/list.oriel"));
const Engine = ui.Engine;
const root_id = 10;
const stage_id = Shell.id("stage", root_id);
const results_id = Shell.id("results", root_id);
const status_id = Shell.id("status", root_id);
const list_id = 100;
const canvas_id = 200;
const row_base = 10000;
const colors = [_]u24{ 0x6d8bff, 0xe8555a, 0x3ad07a, 0xe8c55a, 0xe8eaee };
const Step = enum { build1000, build3000, update1000, update3000, boxes, balls200, direct200, balls1000, direct1000, finish };
const Phase = enum { prepare, measure, loop, settle, idle, power };
const Result = struct { name: []const u8, values: [3]f64, len: usize, unit: []const u8 };
const Ball = struct { x: f64, y: f64, dx: f64, dy: f64, color: u24 };
const PowerResult = struct { name: []const u8, source: []const u8, @"error": ?[]const u8 = null, seconds: f64 = 0, mw: f64 = 0, joules: f64 = 0, samples: usize = 0, plugged: bool = false, fps: ?f64 = null, mj_per_frame: ?f64 = null, charge_uah: ?f64 = null };
const State = struct {
    io: std.Io = undefined,
    started: std.Io.Clock.Timestamp = undefined,
    bench_mode: bool = false,
    rows_only: bool = false,
    power_only: bool = false,
    power_stage_restore: ?[]u8 = null,
    power_seconds: u32 = 0,
    step: Step = .build1000,
    phase: Phase = .idle,
    trial: usize = 0,
    round: usize = 0,
    values: [3]f64 = @splat(0),
    costs: [3]f64 = @splat(0),
    results: [32]Result = undefined,
    result_len: usize = 0,
    visible_len: usize = 0,
    result_ids: [32]i64 = undefined,
    row_ids: [3000]i64 = undefined,
    boxes: [200]i64 = undefined,
    balls: [1000]Ball = undefined,
    program: ui.Program = undefined,
    loop_start: f64 = 0,
    last: f64 = 0,
    frames: u32 = 0,
    duration_ms: f64 = 2000,
    busy_ns: u64 = 0,
    first_pss: f64 = 0,
    first_private: f64 = 0,
    power_index: usize = 0,
    power_results: [4]PowerResult = undefined,
    power_len: usize = 0,
    power_first: host.Power = .{},
    power_last: host.Power = .{},
    power_last_time: f64 = 0,
    power_energy_mj: f64 = 0,
    power_samples: usize = 0,
    plugged: bool = false,
};
var s: State = .{};

pub fn configure(io: std.Io, started: std.Io.Clock.Timestamp, bench_mode: bool, power_seconds: u32) void {
    s.io = io;
    s.started = started;
    s.bench_mode = bench_mode;
    s.power_seconds = power_seconds;
    s.rows_only = std.c.getenv("RENDER_BENCH_ROWS_ONLY") != null;
    s.power_only = std.c.getenv("RENDER_BENCH_POWER_ONLY") != null and power_seconds > 0;
    ui.configure(.{ .boot = boot, .event = event, .timer = timer, .shutdown = shutdown });
}
fn now() f64 {
    return @as(f64, @floatFromInt(s.started.durationTo(std.Io.Clock.Timestamp.now(s.io, .awake)).raw.toNanoseconds())) / 1e6;
}
fn boot(e: *Engine) !void {
    inline for (.{ .{ Shell, 1000 }, .{ Row, 2000 }, .{ ResultView, 3000 }, .{ Box, 4000 }, .{ Canvas, 5000 }, .{ List, 6000 } }) |v| try v[0].prepare(&e.tree, v[1]);
    _ = try Shell.mount(&e.tree, root_id, 1000, &.{});
    e.tree.root = e.tree.get(root_id);
    s.program = .init(e.gpa);
    try addResult(e, "startup → Zig view", &.{now()}, "ms");
    s.phase = .prepare;
    s.step = .build1000;
    s.round = 0;
    if (s.power_only) try startPower(e);
    try e.addFrameHook(.{ .ctx = &s, .func = frame });
}
fn shutdown(e: *Engine) void {
    if (s.power_stage_restore) |bytes| e.gpa.free(bytes);
    s.power_stage_restore = null;
    balls_direct.stop();
    s.program.deinit();
}
const power_timer: u32 = 60000;
fn timer(e: *Engine, id: u32) !void {
    if (id != power_timer or s.phase != .power or s.power_index != 0) return;
    if (try powerTick(e)) {
        if (s.power_index == 0) e.backend.add_timer(e.backend.ctx, e, power_timer, 250) else try e.addFrameHook(.{ .ctx = &s, .func = frame });
    }
}
fn event(e: *Engine, id: i64, kind: []const u8, _: []const u8) bool {
    if (!std.mem.eql(u8, kind, "click") or s.phase != .idle) return false;
    var n = e.tree.get(id);
    while (n) |node| : (n = node.parent) {
        if (node.id == Shell.id("run", root_id)) {
            restart(e) catch return false;
            return true;
        }
        if (node.id == Shell.id("power", root_id)) {
            // Replace the previous power report when the button is reused.
            while (s.power_len > 0) {
                s.visible_len -= 1;
                e.tree.destroy(s.result_ids[s.visible_len]);
                s.result_len -= 1;
                s.power_len -= 1;
            }
            s.power_seconds = 60;
            s.power_index = 0;
            s.power_len = 0;
            startPower(e) catch return false;
            e.addFrameHook(.{ .ctx = &s, .func = frame }) catch return false;
            return true;
        }
    }
    return false;
}
fn restart(e: *Engine) !void {
    clearResults(e);
    s.power_seconds = 0;
    s.power_len = 0;
    s.duration_ms = 2000;
    s.step = .build1000;
    s.phase = .prepare;
    s.trial = 0;
    s.round = 0;
    try e.addFrameHook(.{ .ctx = &s, .func = frame });
}
fn status(e: *Engine, text: []const u8) void {
    _ = e.tree.updateText(status_id, text) catch {};
}
fn clearStage(e: *Engine) void {
    if (e.tree.get(stage_id)) |stage| while (stage.kids.items.len > 0) e.tree.destroy(stage.kids.items[stage.kids.items.len - 1].id);
}
fn clearResults(e: *Engine) void {
    if (e.tree.get(results_id)) |results| while (results.kids.items.len > 0) e.tree.destroy(results.kids.items[results.kids.items.len - 1].id);
    s.result_len = 0;
    s.visible_len = 0;
}
fn count() usize {
    return switch (s.step) {
        .build3000, .update3000 => 3000,
        .balls1000, .direct1000 => 1000,
        .balls200, .direct200, .boxes => 200,
        else => 1000,
    };
}
fn direct() bool {
    return s.step == .direct200 or s.step == .direct1000;
}
fn stepName() []const u8 {
    return switch (s.step) {
        .build1000 => "build 1000 rows",
        .build3000 => "build 3000 rows",
        .update1000 => "update 1000 rows",
        .update3000 => "update 3000 rows",
        .boxes => "animate 200 boxes",
        .balls200 => "canvas 200 balls",
        .direct200 => "canvas 200 balls (Zig)",
        .balls1000 => "canvas 1000 balls",
        .direct1000 => "canvas 1000 balls (Zig)",
        .finish => "Done.",
    };
}
fn buildRows(e: *Engine, n: usize) !void {
    _ = try List.mount(&e.tree, list_id, 6000, &.{});
    for (0..n) |i| {
        var index: [24]u8 = undefined;
        var label: [80]u8 = undefined;
        const id = row_base + @as(i64, @intCast(i * Row.node_count));
        s.row_ids[i] = try Row.mount(&e.tree, id, 2000, &.{ .{ .name = "index", .value = try std.fmt.bufPrint(&index, "{d}", .{i}) }, .{ .name = "label", .value = try std.fmt.bufPrint(&label, "Row {d}: the quick brown fox", .{i}) } });
    }
    if (!try e.tree.stampKids(list_id, s.row_ids[0..n])) return error.MissingList;
    if (!try e.tree.stampKids(stage_id, &.{list_id})) return error.MissingStage;
}
fn updateRows(e: *Engine, n: usize) !void {
    for (0..n) |i| {
        var buf: [80]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "Row {d}: updated {d}", .{ i, s.trial });
        if (!try e.tree.updateText(Row.id("label", s.row_ids[i]), text)) return error.MissingText;
    }
}
fn median(values: []const f64) f64 {
    var copy: [3]f64 = @splat(0);
    @memcpy(copy[0..values.len], values);
    std.mem.sort(f64, copy[0..values.len], {}, std.sort.asc(f64));
    return copy[values.len / 2];
}
fn rounded(value: f64) f64 {
    return @round(value * 100) / 100;
}
fn addResult(e: *Engine, name: []const u8, values: []const f64, unit: []const u8) !void {
    if (s.result_len == s.results.len or values.len == 0 or values.len > 3) return error.TooManyResults;
    const idx = s.result_len;
    s.results[idx] = .{ .name = name, .values = @splat(0), .len = values.len, .unit = unit };
    for (values, 0..) |v, i| s.results[idx].values[i] = rounded(v);
    s.result_len += 1;
    if (s.phase != .power) try showResult(e, idx);
}
fn showResult(e: *Engine, idx: usize) !void {
    const r = s.results[idx];
    const name = r.name;
    const values = r.values[0..r.len];
    const unit = r.unit;
    // The existing page keeps startup readings in JSON, then clears them
    // from the visible table before running. Preserve the stage's height.
    if (std.mem.startsWith(u8, name, "startup") or std.mem.startsWith(u8, name, "memory at start") or std.mem.startsWith(u8, name, "private memory at start")) return;
    var med: [64]u8 = undefined;
    var runs: [128]u8 = undefined;
    const med_text = try std.fmt.bufPrint(&med, "{d:.2} {s}", .{ median(values), unit });
    const run_text = if (values.len == 3) try std.fmt.bufPrint(&runs, "{d:.2} · {d:.2} · {d:.2}", .{ values[0], values[1], values[2] }) else try std.fmt.bufPrint(&runs, "{d:.2}", .{values[0]});
    const id: i64 = 200 + @as(i64, @intCast(idx * ResultView.node_count)) + 100000;
    s.result_ids[s.visible_len] = try ResultView.mount(&e.tree, id, 3000, &.{ .{ .name = "name", .value = name }, .{ .name = "median", .value = med_text }, .{ .name = "runs", .value = run_text } });
    s.visible_len += 1;
    if (!try e.tree.stampKids(results_id, s.result_ids[0..s.visible_len])) return error.MissingResults;
}
fn frame(_: *anyopaque, e: *Engine, _: f64) bool {
    return tick(e) catch |err| {
        std.log.err("oriel renderer benchmark failed: {s}", .{@errorName(err)});
        status(e, "Benchmark failed; see the application log.");
        s.phase = .idle;
        if (s.bench_mode) oriel.App.quit(1);
        return false;
    };
}
fn tick(e: *Engine) !bool {
    if (s.phase == .idle) return false;
    if (s.phase == .power) {
        // Match the existing idle scenario: only the 250 ms sampler wakes,
        // not a display-rate animation callback doing no visible work.
        if (s.power_index == 0 and s.power_first.ok) return false;
        return powerTick(e);
    }
    if (s.phase == .settle) {
        if (now() - s.loop_start < 2500) return true;
        return finishRound(e);
    }
    if (s.phase == .loop) return loopTick(e);
    if (s.phase == .prepare) {
        if (s.result_len == 1 and s.round == 0) {
            try addResult(e, "startup → first frame", &.{now()}, "ms");
            try addMemory(e, "at start");
        }
        status(e, stepName());
        if (@intFromEnum(s.step) >= @intFromEnum(Step.boxes)) {
            try startLoop(e);
            s.phase = .loop;
            return true;
        }
        clearStage(e);
        if (s.step == .update1000 or s.step == .update3000) try buildRows(e, count());
        e.paintNow();
        s.phase = .measure;
        return true;
    }
    // Same endpoint as offsetHeight: includes construction/text and layout,
    // leaves painting for after this display callback returns.
    const t0 = now();
    if (s.step == .build1000 or s.step == .build3000) try buildRows(e, count()) else try updateRows(e, count());
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    s.values[s.trial] = now() - t0;
    s.trial += 1;
    if (s.trial == 3) {
        try addResult(e, stepName(), &s.values, "ms");
        advance();
        if (s.step == .finish) {
            clearStage(e);
            e.paintNow();
        }
    } else if (s.step == .build1000 or s.step == .build3000) s.phase = .prepare;
    return true;
}
fn advance() void {
    s.trial = 0;
    s.step = @enumFromInt(@intFromEnum(s.step) + 1);
    if (s.rows_only and s.step == .boxes) s.step = .finish;
    s.phase = .prepare;
    if (s.step == .finish) {
        s.phase = .settle;
        s.loop_start = now();
    }
}
fn startLoop(e: *Engine) !void {
    clearStage(e);
    if (s.step == .boxes) {
        for (0..200) |i| s.boxes[i] = try Box.mount(&e.tree, row_base + @as(i64, @intCast(i)), 4000, &.{});
        if (!try e.tree.stampKids(stage_id, &s.boxes)) return error.MissingStage;
    } else {
        _ = try Canvas.mount(&e.tree, canvas_id, 5000, &.{});
        e.tree.noteCanvasEid(canvas_id, "zigballs");
        if (!try e.tree.stampKids(stage_id, &.{canvas_id})) return error.MissingStage;
    }
    e.paintNow();
    const size = stageSize(e);
    if (direct()) {
        if (!balls_direct.start(e.gpa, s.io, @intCast(count()), s.duration_ms)) return error.CannotStartDirectCanvas;
    } else if (s.step != .boxes) {
        for (s.balls[0..count()], 0..) |*b, i| {
            const f: f64 = @floatFromInt(i);
            b.* = .{ .x = 10 + @mod(f * 37.13, size[0] - 20), .y = 10 + @mod(f * 23.71, size[1] - 20), .dx = 40 + @as(f64, @floatFromInt(i % 7)) * 17, .dy = 30 + @as(f64, @floatFromInt(i % 5)) * 23, .color = colors[i % colors.len] };
        }
    }
    s.loop_start = now();
    s.last = s.loop_start;
    s.frames = 0;
    s.busy_ns = 0;
}
fn stageSize(e: *Engine) [2]f64 {
    const n = e.tree.get(stage_id).?;
    return .{ if (n.frame.w > 0) n.frame.w else 600, if (n.frame.h > 0) n.frame.h else 300 };
}
fn drawLoop(e: *Engine) !void {
    if (direct()) {
        s.frames = balls_direct.result().frames;
        return;
    }
    const began = std.Io.Clock.Timestamp.now(s.io, .awake);
    const t = now();
    const size = stageSize(e);
    if (s.step == .boxes) {
        for (s.boxes, 0..) |id, i| {
            const f: f64 = @floatFromInt(i);
            const seconds = (t - s.loop_start) / 1000;
            // Match the page's toFixed(1) transform coordinates.
            const x = @round((@sin(seconds * 2 + f * 0.3) * 0.45 + 0.5) * (size[0] - 14) * 10) / 10;
            const y = @round((@cos(seconds * 1.3 + f * 0.17) * 0.45 + 0.5) * (size[1] - 14) * 10) / 10;
            e.tree.applyPaint(&.{ 1, @floatFromInt(id), 5, x, y, 1, 0, 1 });
        }
    } else {
        const dt = @min(0.05, (t - s.last) / 1000);
        const p = &s.program;
        p.begin();
        p.fillStyle(oriel.canvas.rgb(0x10141b));
        p.fillRect(0, 0, @floatCast(size[0]), @floatCast(size[1]));
        for (s.balls[0..count()]) |*b| {
            b.x += b.dx * dt;
            b.y += b.dy * dt;
            if (b.x < 6 or b.x > size[0] - 6) b.dx = -b.dx;
            if (b.y < 6 or b.y > size[1] - 6) b.dy = -b.dy;
            p.circle(@floatCast(b.x), @floatCast(b.y), 6);
            p.fillStyle(oriel.canvas.rgb(b.color));
            p.fill();
        }
        p.fillStyle(oriel.canvas.rgb(0xe8eaee));
        p.font(12, 400, false, "sans-serif");
        p.textBaseline(.top);
        var buf: [32]u8 = undefined;
        p.fillText(try std.fmt.bufPrint(&buf, "{d} balls", .{count()}), 8, 8);
        p.last_len = p.cmds.items.len;
        if (!e.tree.commitCanvas(canvas_id, p.cmds.items, &p.arena)) return error.MissingCanvas;
        p.cmds = .empty;
    }
    s.last = t;
    s.frames += 1;
    s.busy_ns += @intCast(began.durationTo(std.Io.Clock.Timestamp.now(s.io, .awake)).raw.toNanoseconds());
}
fn loopTick(e: *Engine) !bool {
    try drawLoop(e);
    const elapsed = now() - s.loop_start;
    if (direct() and !balls_direct.result().done or !direct() and elapsed < s.duration_ms) return true;
    const r = if (direct()) balls_direct.result() else balls_direct.Result{ .done = true, .fps = @as(f64, @floatFromInt(s.frames)) * 1000 / elapsed, .frames = s.frames, .frame_us = @as(f64, @floatFromInt(s.busy_ns)) / 1000 / @as(f64, @floatFromInt(s.frames)) };
    s.values[s.trial] = r.fps;
    s.costs[s.trial] = r.frame_us;
    if (direct()) balls_direct.stop();
    s.trial += 1;
    if (s.trial < 3) {
        try startLoop(e);
        return true;
    }
    try addResult(e, stepName(), &s.values, "fps");
    if (direct()) try addResult(e, if (s.step == .direct200) "canvas 200 balls (Zig), Zig work per frame" else "canvas 1000 balls (Zig), Zig work per frame", &s.costs, "µs");
    advance();
    if (s.step == .finish) {
        clearStage(e);
        e.paintNow();
    }
    return true;
}
fn addMemory(e: *Engine, comptime when: []const u8) !void {
    const scope = if (oriel.target.is_android) "app process tree" else "all processes";
    try addResult(e, "memory " ++ when ++ " (PSS, " ++ scope ++ ")", &.{host.Commands.pss_mb(e.gpa)}, "MB");
    try addResult(e, "private memory " ++ when ++ " (" ++ scope ++ ")", &.{host.Commands.private_mb(e.gpa)}, "MB");
}
fn finishRound(e: *Engine) !bool {
    if (s.bench_mode and s.round == 0) {
        s.first_pss = host.Commands.pss_mb(e.gpa);
        s.first_private = host.Commands.private_mb(e.gpa);
        const startup = s.results[0..4].*;
        clearResults(e);
        for (startup) |r| try addResult(e, r.name, r.values[0..r.len], r.unit);
        s.round = 1;
        s.step = .build1000;
        s.trial = 0;
        s.phase = .prepare;
        return true;
    }
    if (s.bench_mode) {
        const scope = if (oriel.target.is_android) "app process tree" else "all processes";
        try addResult(e, "memory after the tests (PSS, " ++ scope ++ ")", &.{s.first_pss}, "MB");
        try addResult(e, "private memory after the tests (" ++ scope ++ ")", &.{s.first_private}, "MB");
        try addMemory(e, "after a second round");
    } else try addMemory(e, "after the tests");
    status(e, "Done.");
    if (s.power_seconds > 0) {
        s.power_index = 0;
        s.power_len = 0;
        try startPower(e);
        return true;
    }
    s.phase = .idle;
    if (s.bench_mode) try report(e);
    return false;
}
const ReportResults = struct {
    records: []const Result,
    power: []const PowerResult,
    pub fn jsonStringify(self: @This(), writer: anytype) !void {
        try writer.beginObject();
        for (self.records) |r| {
            try writer.objectField(r.name);
            try writer.write(.{ .median = median(r.values[0..r.len]), .runs = r.values[0..r.len], .unit = r.unit });
        }
        if (self.power.len > 0) {
            try writer.objectField("power");
            try writer.write(self.power);
        }
        try writer.endObject();
    }
};
fn report(e: *Engine) !void {
    const json = try std.json.Stringify.valueAlloc(e.gpa, .{
        .renderer = "oriel",
        .memory_scope = host.Commands.memory_scope(e.gpa),
        .workload = if (s.power_only) "power" else if (s.rows_only) "rows" else "full",
        .power_viewport = .{ .width = 320, .height = 240 },
        .canvas_implementation = "Zig f64 physics for standard canvas; existing Zig f32 implementation for (Zig) workloads",
        .results = ReportResults{ .records = s.results[0..s.result_len], .power = s.power_results[0..s.power_len] },
    }, .{ .emit_null_optional_fields = false });
    defer e.gpa.free(json);
    host.Commands.report(e.gpa, .{ .json = json });
}

const power_names = [_][]const u8{ "idle (nothing moving)", "animate 200 boxes", "canvas 1000 balls", "canvas 1000 balls (Zig)" };
const power_row_names = [_][]const u8{ "power: idle (nothing moving)", "power: animate 200 boxes", "power: canvas 1000 balls", "power: canvas 1000 balls (Zig)" };
fn stageProps(e: *Engine, json: []const u8) !void {
    const ops = try std.fmt.allocPrint(e.gpa, "[[\"p\",{d},{s}]]", .{ stage_id, json });
    defer e.gpa.free(ops);
    try e.tree.apply(ops);
}
fn startPower(e: *Engine) !void {
    if (s.power_index == 0) {
        s.power_stage_restore = try std.json.Stringify.valueAlloc(e.gpa, e.tree.get(stage_id).?.props, .{ .emit_null_optional_fields = false });
        while (e.tree.get(results_id).?.kids.items.len > 0) e.tree.destroy(e.tree.get(results_id).?.kids.items[0].id);
        s.visible_len = 0;
        try stageProps(e, "{\"w\":320,\"h\":240,\"minh\":240,\"fg\":0,\"fs\":0,\"clip\":true,\"br\":[10,10,10,10],\"bg\":{\"color\":[29,32,38,1]}}");
        e.paintNow();
    }
    clearStage(e);
    s.power_first = host.Commands.power_now(e.gpa);
    s.power_last = s.power_first;
    s.plugged = s.power_first.plugged;
    s.power_samples = 0;
    s.power_energy_mj = 0;
    s.step = switch (s.power_index) {
        0 => .finish,
        1 => .boxes,
        2 => .balls1000,
        else => .direct1000,
    };
    s.duration_ms = @as(f64, @floatFromInt(s.power_seconds)) * 1000;
    if (s.power_first.ok and s.power_index > 0) try startLoop(e) else {
        s.loop_start = now();
        s.frames = 0;
    }
    s.power_last_time = s.loop_start;
    s.phase = .power;
    if (s.power_index == 0 and s.power_first.ok) e.backend.add_timer(e.backend.ctx, e, power_timer, 250);
    var buf: [128]u8 = undefined;
    status(e, try std.fmt.bufPrint(&buf, "Power {d} of 4: {s} ({d} s)…", .{ s.power_index + 1, power_names[s.power_index], s.power_seconds }));
}
fn powerTick(e: *Engine) !bool {
    if (s.power_first.ok and s.power_index > 0) try drawLoop(e);
    const t = now();
    if (s.power_first.ok and t - s.power_last_time >= 250) {
        const p = host.Commands.power_now(e.gpa);
        if (p.ok) {
            s.power_energy_mj += (s.power_last.mw + p.mw) / 2 * ((t - s.power_last_time) / 1000);
            s.power_samples += 1;
            s.plugged = s.plugged or p.plugged;
            s.power_last = p;
            s.power_last_time = t;
        }
    }
    if (s.power_first.ok and (t - s.loop_start < s.duration_ms or direct() and !balls_direct.result().done)) return true;
    const end = host.Commands.power_now(e.gpa);
    const seconds = @max(0.001, (t - s.loop_start) / 1000);
    s.power_energy_mj += (s.power_last.mw + end.mw) / 2 * ((t - s.power_last_time) / 1000);
    if (end.energy_uj >= 0 and s.power_first.energy_uj >= 0) s.power_energy_mj = (end.energy_uj - s.power_first.energy_uj) / 1000;
    const r = &s.power_results[s.power_index];
    r.* = .{ .name = power_names[s.power_index], .source = s.power_first.source, .@"error" = if (s.power_first.ok) null else s.power_first.source, .seconds = seconds, .mw = s.power_energy_mj / seconds, .joules = s.power_energy_mj / 1000, .samples = s.power_samples, .plugged = s.plugged or end.plugged };
    if (s.frames > 0) {
        r.fps = @as(f64, @floatFromInt(s.frames)) / seconds;
        r.mj_per_frame = s.power_energy_mj / @as(f64, @floatFromInt(s.frames));
    }
    if (s.power_first.charge_uah > 0 and end.charge_uah > 0) r.charge_uah = s.power_first.charge_uah - end.charge_uah;
    if (direct()) balls_direct.stop();
    try addResult(e, power_row_names[s.power_index], &.{if (s.power_first.ok) r.mw else 0}, if (s.power_first.ok) "mW" else "unavailable");
    s.power_index += 1;
    s.power_len = s.power_index;
    if (s.power_index < 4) {
        try startPower(e);
        return true;
    }
    clearStage(e);
    status(e, "Power done.");
    s.duration_ms = 2000;
    s.phase = .idle;
    if (s.power_stage_restore) |bytes| {
        try stageProps(e, bytes);
        e.gpa.free(bytes);
        s.power_stage_restore = null;
    }
    for (0..s.result_len) |i| try showResult(e, i);
    for (s.power_results[0..s.power_len], 0..) |result, i| {
        var detail: [256]u8 = undefined;
        const text = if (result.@"error") |err| err else try std.fmt.bufPrint(&detail, "{d:.2} J in {d:.1} s · {d:.1} fps · {s}{s}", .{ result.joules, result.seconds, result.fps orelse 0, result.source, if (result.plugged) " · ON A CHARGER: not meaningful" else "" });
        _ = try e.tree.updateText(ResultView.id("runs", s.result_ids[s.visible_len - s.power_len + i]), text);
    }
    if (s.bench_mode) try report(e);
    return false;
}
