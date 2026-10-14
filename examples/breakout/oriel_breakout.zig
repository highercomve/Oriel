//! Breakout with the Oriel renderer (-Drenderer=oriel): views/breakout.oriel
//! is web/index.html and style.css as native views, and this is
//! web/game.js in Zig: the HUD, overlays, settings, stats and input. The
//! game itself (rules and drawing) is game.zig's, drawn into the view's
//! canvas each display frame. No JavaScript.

const std = @import("std");
const oriel = @import("oriel");
const ui = oriel.ui;
const game = @import("game.zig");

const View = ui.View(@embedFile("views/breakout.oriel"));
const base: i64 = 100;
const style_base: i64 = 10_000;
fn id(comptime name: []const u8) i64 {
    return View.id(name, base);
}

const builtin = @import("builtin");
const os_name = if (builtin.abi.isAndroid()) "android" else @tagName(builtin.os.tag);

/// The page's words for its input: a touch screen (game.js `coarse`) or a
/// mouse and keys.
fn hintText(e: *const ui.Engine) []const u8 {
    return if (e.coarse) "Tap to launch" else "Click or press Space to launch";
}
fn helpText(e: *const ui.Engine) []const u8 {
    return if (e.coarse) "Drag anywhere on the board to move · tap to launch" else "Mouse, ← → or A D to move · click or Space to launch · P or Esc to pause";
}

const Settings = struct { balls: u32 = 1, rows: u32 = 6, particles: bool = true, stats: bool = true, autoplay: bool = false };

/// The game.js state: the world, what the page shows, the input.
var s: struct {
    io: std.Io = undefined,
    world: ?game.World = null,
    program: ?ui.Program = null,
    settings: Settings = .{},
    paused: bool = false,
    paused_by_settings: bool = false,
    settings_open: bool = false,
    over_shown: bool = false,
    redraw: bool = true,
    // The pointer over the board (its x on the board, px) and held keys.
    target: ?f32 = null,
    left: bool = false,
    right: bool = false,
    // The loop's clock and the stats over half a second.
    started: std.Io.Clock.Timestamp = undefined,
    last_ms: ?f64 = null,
    acc: struct { n: u32 = 0, dt: f64 = 0, phys: f64 = 0, draw: f64 = 0, since: f64 = 0 } = .{},
    // The text the view shows (bindings point into these).
    hud: struct { score: [16]u8 = undefined, lives: [16]u8 = undefined, level: [16]u8 = undefined, final: [16]u8 = undefined, final_level: [16]u8 = undefined } = .{},
    texts: struct {
        score: []const u8 = "0",
        lives: []const u8 = "3",
        level: []const u8 = "1",
        final: []const u8 = "0",
        final_level: []const u8 = "1",
        balls: []const u8 = "1",
        rows: []const u8 = "6",
        balls_label: []const u8 = "Balls per launch 1 Up to 500: chaos mode",
        rows_label: []const u8 = "Brick rows 6 Rebuilds the bricks",
        stats_fps: []const u8 = "- fps · - ms/frame",
        stats_time: []const u8 = "Zig - ms (physics -, draw -)",
        stats_count: []const u8 = "1 balls · 0 particles",
    } = .{},
    bufs: struct { balls: [8]u8 = undefined, rows: [8]u8 = undefined, balls_label: [64]u8 = undefined, rows_label: [64]u8 = undefined, fps: [64]u8 = undefined, time: [80]u8 = undefined, count: [64]u8 = undefined } = .{},
} = .{};

pub fn configure(io: std.Io) void {
    s.io = io;
    ui.configure(.{ .boot = boot, .event = event, .resized = resized, .shutdown = shutdown });
}

fn nowMs() f64 {
    const ns = s.started.durationTo(std.Io.Clock.Timestamp.now(s.io, .awake)).raw.toNanoseconds();
    return @as(f64, @floatFromInt(ns)) / 1e6;
}

fn boot(e: *ui.Engine) !void {
    s.started = std.Io.Clock.Timestamp.now(s.io, .awake);
    try View.prepare(&e.tree, style_base);
    try updateView(e);
    e.tree.root = e.tree.get(base);
    e.tree.layout();
    const board = boardSize(e);
    const seed: u64 = @truncate(@as(u96, @bitCast(s.started.raw.toNanoseconds())));
    s.world = try game.World.init(e.gpa, board[0], board[1], s.settings.rows, seed);
    s.program = .init(e.gpa);
    try e.addFrameHook(.{ .ctx = @ptrCast(&s), .func = frame });
}

fn shutdown(e: *ui.Engine) void {
    e.removeFrameHooks(@ptrCast(&s));
    if (s.program) |*p| p.deinit();
    if (s.world) |*w| w.deinit();
    s.program = null;
    s.world = null;
}

/// The view with what it shows now (the HUD, the stats, the labels).
fn updateView(e: *ui.Engine) !void {
    const t = &s.texts;
    const bindings = [_]ui.Binding{
        .{ .name = "score", .value = t.score },
        .{ .name = "lives", .value = t.lives },
        .{ .name = "level", .value = t.level },
        .{ .name = "pause_label", .value = if (s.paused) "Resume" else "Pause" },
        .{ .name = "stats_fps", .value = t.stats_fps },
        .{ .name = "stats_time", .value = t.stats_time },
        .{ .name = "stats_count", .value = t.stats_count },
        .{ .name = "stats_renderer", .value = "oriel renderer · Zig mode · " ++ os_name },
        .{ .name = "final", .value = t.final },
        .{ .name = "final_level", .value = t.final_level },
        .{ .name = "balls", .value = t.balls },
        .{ .name = "rows", .value = t.rows },
        .{ .name = "balls_label", .value = t.balls_label },
        .{ .name = "rows_label", .value = t.rows_label },
        .{ .name = "help", .value = helpText(e) },
    };
    if (e.tree.get(base) == null) {
        _ = try View.mount(&e.tree, base, style_base, &bindings);
    } else try View.update(&e.tree, base, &bindings);
}

/// Show or hide a part of the view (game.js's `hidden`).
fn show(e: *ui.Engine, node: i64, on: bool) !void {
    const n = e.tree.get(node) orelse return;
    if ((n.props.vis orelse true) == on) return;
    try ui.setVisible(&e.tree, node, on);
}

fn boardSize(e: *ui.Engine) [2]f32 {
    const b = e.tree.get(id("board")).?;
    return .{ @max(120, @floor(b.frame.w)), @max(120, @floor(b.frame.h)) };
}

fn resized(e: *ui.Engine) !void {
    // style.css's @media (max-width: 520px) is the view's own <style>,
    // switched before this runs.
    e.tree.layout();
    const size = boardSize(e);
    if (s.world) |*w| w.resize(size[0], size[1]);
    s.redraw = true;
}

// ---------------------------------------------------------------------------
// The loop (game.js tick): a step by the time since the last frame, then
// the board drawn into the canvas.

fn frame(_: *anyopaque, e: *ui.Engine, _: f64) bool {
    step(e) catch |err| std.log.err("breakout: {s}", .{@errorName(err)});
    return true;
}

fn step(e: *ui.Engine) !void {
    const w = &(s.world orelse return);
    const t = nowMs();
    const prev = s.last_ms;
    s.last_ms = t;
    if (prev == null) {
        s.acc.since = t;
    }
    const real = if (prev) |p| (t - p) / 1000 else 0;
    const dt: f32 = @floatCast(@min(real, 1.0 / 20.0));
    const running = !s.paused and !w.over;
    const t0 = nowMs();
    if (running and prev != null) {
        var input: game.Input = .{ .dir = @as(i32, @intFromBool(s.right)) - @intFromBool(s.left), .target = s.target };
        if (s.settings.autoplay) input.target = w.autoTarget(t);
        const ev = try w.step(dt, input, .{ .particles = s.settings.particles, .endless = s.settings.autoplay });
        if (s.settings.autoplay) {
            var all_stuck = w.balls.items.len > 0;
            for (w.balls.items) |b| all_stuck = all_stuck and b.stuck;
            if (all_stuck) _ = try w.launch(s.settings.balls);
        }
        if (ev.broken > 0 or ev.lost or ev.cleared) try hud(e);
        if (w.over and !s.over_shown) try gameOver(e);
    }
    const t1 = nowMs();
    if (running or s.redraw) {
        s.redraw = false;
        try drawBoard(e, w);
    }
    const t2 = nowMs();
    if (prev != null) {
        s.acc.n += 1;
        s.acc.dt += real;
        s.acc.phys += t1 - t0;
        s.acc.draw += t2 - t1;
        if (t - s.acc.since >= 500) try stats(e, t, w);
    }
}

fn drawBoard(e: *ui.Engine, w: *const game.World) !void {
    const canvas = e.tree.get(id("cv")) orelse return;
    if (canvas.frame.w < 1 or canvas.frame.h < 1) return;
    var stuck = false;
    for (w.balls.items) |b| stuck = stuck or b.stuck;
    const hint: ?[]const u8 = if (!w.over and stuck and !s.settings.autoplay) hintText(e) else null;
    const p = &s.program.?;
    game.draw(p, w, canvas.frame.w, canvas.frame.h, 1, hint);
    if (p.failed) return error.OutOfMemory;
    p.last_len = p.cmds.items.len;
    if (!e.tree.commitCanvas(canvas.id, p.cmds.items, &p.arena)) return error.MissingCanvas;
}

fn stats(e: *ui.Engine, t: f64, w: *const game.World) !void {
    const n: f64 = @floatFromInt(@max(1, s.acc.n));
    const fps = n * 1000 / (t - s.acc.since);
    const frame_ms = s.acc.dt * 1000 / n;
    const phys = s.acc.phys / n;
    const drw = s.acc.draw / n;
    s.acc = .{ .since = t };
    if (!s.settings.stats) return;
    const b = &s.bufs;
    s.texts.stats_fps = try std.fmt.bufPrint(&b.fps, "{d:.0} fps · {d:.2} ms/frame", .{ fps, frame_ms });
    s.texts.stats_time = try std.fmt.bufPrint(&b.time, "Zig {d:.2} ms (physics {d:.2}, draw {d:.2})", .{ phys + drw, phys, drw });
    s.texts.stats_count = try std.fmt.bufPrint(&b.count, "{d} balls · {d} particles", .{ w.balls.items.len, w.particles.items.len });
    try updateView(e);
}

// ---------------------------------------------------------------------------
// Game state and the view around it (game.js)

fn hud(e: *ui.Engine) !void {
    const w = &(s.world orelse return);
    s.texts.score = try std.fmt.bufPrint(&s.hud.score, "{d}", .{w.score});
    s.texts.lives = try std.fmt.bufPrint(&s.hud.lives, "{d}", .{w.lives});
    s.texts.level = try std.fmt.bufPrint(&s.hud.level, "{d}", .{w.level});
    try updateView(e);
}

fn gameOver(e: *ui.Engine) !void {
    const w = &(s.world orelse return);
    s.texts.final = try std.fmt.bufPrint(&s.hud.final, "{d}", .{w.score});
    s.texts.final_level = try std.fmt.bufPrint(&s.hud.final_level, "{d}", .{w.level});
    s.over_shown = true;
    try updateView(e);
    try show(e, id("over"), true);
}

fn launchOrRestart(e: *ui.Engine) !void {
    const w = &(s.world orelse return);
    if (w.over) return restart(e);
    if (try w.launch(s.settings.balls)) s.redraw = true;
}

fn restart(e: *ui.Engine) !void {
    try show(e, id("over"), false);
    s.over_shown = false;
    const old = &(s.world orelse return);
    const seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(s.io, .awake).raw.toNanoseconds())));
    const fresh = try game.World.init(e.gpa, old.w, old.h, s.settings.rows, seed);
    old.deinit();
    s.world = fresh;
    try setPaused(e, false);
    try hud(e);
}

fn setPaused(e: *ui.Engine, on: bool) !void {
    s.paused = on;
    try show(e, id("pause"), on and !s.settings_open);
    try updateView(e); // the Pause button's label
    s.redraw = true;
}

fn openSettings(e: *ui.Engine) !void {
    s.settings_open = true;
    try show(e, id("settings"), true);
    if (!s.paused) {
        s.paused_by_settings = true;
        try setPaused(e, true);
    }
    try show(e, id("pause"), false);
}

fn closeSettings(e: *ui.Engine) !void {
    s.settings_open = false;
    try show(e, id("settings"), false);
    if (s.paused_by_settings) {
        s.paused_by_settings = false;
        try setPaused(e, false);
    } else try show(e, id("pause"), s.paused);
}

fn togglePause(e: *ui.Engine) !void {
    if (s.settings_open) return closeSettings(e);
    const w = &(s.world orelse return);
    if (w.over) return;
    s.paused_by_settings = false;
    try setPaused(e, !s.paused);
}

// ---------------------------------------------------------------------------
// Events: the pointer over the board, keys, buttons, the settings' controls.

fn event(e: *ui.Engine, node: i64, kind: []const u8, data: []const u8) bool {
    return handle(e, node, kind, data) catch |err| {
        std.log.err("breakout: {s}", .{@errorName(err)});
        return true;
    };
}

fn handle(e: *ui.Engine, node: i64, kind: []const u8, data: []const u8) !bool {
    const eq = std.mem.eql;
    if (eq(u8, kind, "pointer")) return pointer(e, data);
    if (eq(u8, kind, "key")) return key(e, data, true);
    if (eq(u8, kind, "keyup")) return key(e, data, false);
    if (eq(u8, kind, "click")) return click(e, node);
    if (eq(u8, kind, "change") or eq(u8, kind, "input")) return control(e, node, data);
    return false;
}

/// The board's pointer: the paddle follows a mouse over the board.
fn pointer(e: *ui.Engine, data: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, e.gpa, data, .{}) catch return false;
    defer parsed.deinit();
    const a = if (parsed.value == .array) parsed.value.array.items else return false;
    if (a.len < 3) return false;
    const x: f32 = @floatCast(numberOf(a[1]) orelse return false);
    const y: f32 = @floatCast(numberOf(a[2]) orelse return false);
    const b = e.tree.get(id("board")).?.frame;
    const inside = x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h;
    s.target = if (inside) x - b.x else null;
    return false;
}

fn numberOf(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// ← → / A D held move the paddle; Space launches; P or Esc pauses.
fn key(e: *ui.Engine, data: []const u8, down: bool) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, e.gpa, data, .{}) catch return false;
    defer parsed.deinit();
    const a = if (parsed.value == .array) parsed.value.array.items else return false;
    if (a.len == 0 or a[0] != .string) return false;
    const k = a[0].string;
    const eq = std.mem.eql;
    if (eq(u8, k, "ArrowLeft") or eq(u8, k, "a") or eq(u8, k, "A")) {
        s.left = down;
        if (down) s.target = null;
        return true;
    }
    if (eq(u8, k, "ArrowRight") or eq(u8, k, "d") or eq(u8, k, "D")) {
        s.right = down;
        if (down) s.target = null;
        return true;
    }
    if (!down) return false;
    if (eq(u8, k, " ")) {
        if (!s.paused) try launchOrRestart(e);
        return true;
    }
    if (eq(u8, k, "p") or eq(u8, k, "P") or eq(u8, k, "Escape")) {
        try togglePause(e);
        return true;
    }
    return false;
}

fn click(e: *ui.Engine, node: i64) !bool {
    if (node == id("board") or node == id("cv")) {
        if (!s.paused) try launchOrRestart(e);
    } else if (node == id("pause-btn") or node == id("pause-btn-label")) {
        try togglePause(e);
    } else if (node == id("settings-btn") or node == id("settings-btn-label")) {
        if (s.settings_open) try closeSettings(e) else try openSettings(e);
    } else if (node == id("resume") or node == id("resume-label")) {
        try setPaused(e, false);
    } else if (node == id("restart") or node == id("restart-label") or node == id("again") or node == id("again-label")) {
        try restart(e);
    } else if (node == id("close-settings") or node == id("close-settings-label")) {
        try closeSettings(e);
    } else if (checkOfRow(e, node)) |check| {
        // A click on a check's label row: the check's own click (it
        // toggles, and "change" comes back here).
        _ = e.event(check, "click", "0");
    } else return false;
    return true;
}

/// The checkbox whose row (or the row's text) `node` is.
fn checkOfRow(e: *ui.Engine, node: i64) ?i64 {
    const rows = [_][2]i64{ .{ id("particles-row"), id("particles") }, .{ id("show-stats-row"), id("show-stats") }, .{ id("autoplay-row"), id("autoplay") } };
    var at = e.tree.get(node);
    var depth: usize = 0;
    while (at) |n| : (at = n.parent) {
        for (rows) |r| if (n.id == r[0]) return r[1];
        depth += 1;
        if (depth > 4) break;
    }
    return null;
}

/// The settings' controls (and their labels: a click on a check's row
/// toggles it, as a <label> does).
fn control(e: *ui.Engine, node: i64, data: []const u8) !bool {
    const w = &(s.world orelse return false);
    if (node == id("balls") or node == id("rows")) {
        const parsed = std.json.parseFromSlice(std.json.Value, e.gpa, data, .{}) catch return false;
        defer parsed.deinit();
        const text = switch (parsed.value) {
            .string => |t| t,
            .array => |a| if (a.items.len > 0 and a.items[0] == .string) a.items[0].string else return false,
            else => return false,
        };
        const value = std.fmt.parseFloat(f64, text) catch return false;
        const b = &s.bufs;
        if (node == id("balls")) {
            s.settings.balls = @intFromFloat(std.math.clamp(@round(value), 1, 500));
            s.texts.balls = try std.fmt.bufPrint(&b.balls, "{d}", .{s.settings.balls});
            s.texts.balls_label = try std.fmt.bufPrint(&b.balls_label, "Balls per launch {d} Up to 500: chaos mode", .{s.settings.balls});
        } else {
            s.settings.rows = @intFromFloat(std.math.clamp(@round(value), 2, 12));
            s.texts.rows = try std.fmt.bufPrint(&b.rows, "{d}", .{s.settings.rows});
            s.texts.rows_label = try std.fmt.bufPrint(&b.rows_label, "Brick rows {d} Rebuilds the bricks", .{s.settings.rows});
            w.rows = s.settings.rows;
            try w.buildLevel();
            s.redraw = true;
        }
        try updateView(e);
        return true;
    }
    const on = std.mem.eql(u8, data, "true");
    if (node == id("particles")) {
        s.settings.particles = on;
        if (!on) w.particles.clearRetainingCapacity();
    } else if (node == id("show-stats")) {
        s.settings.stats = on;
        try show(e, id("stats"), on);
    } else if (node == id("autoplay")) {
        s.settings.autoplay = on;
    } else return false;
    return true;
}
