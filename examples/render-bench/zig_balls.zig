//! The canvas balls test in Zig (-Dnative_ui): the same physics and drawing
//! as web/app.js's timeCanvasBalls, through oriel.canvas, with no
//! JavaScript per frame. The page starts a run (zig_balls) and reads its
//! frame rate and per-frame cost when it ends (zig_balls_result).

const std = @import("std");
const oriel = @import("oriel");
const canvas = oriel.canvas;

const Ball = struct { x: f32, y: f32, dx: f32, dy: f32, c: canvas.Color };

const colors = [_]canvas.Color{ canvas.rgb(0x6d8bff), canvas.rgb(0xe8555a), canvas.rgb(0x3ad07a), canvas.rgb(0xe8c55a), canvas.rgb(0xe8eaee) };

pub const Run = struct {
    io: std.Io,
    target: canvas.Canvas,
    program: canvas.Program,
    balls: std.ArrayList(Ball) = .empty,
    gpa: std.mem.Allocator,
    w: f32,
    h: f32,
    ms: f64,
    t0: std.Io.Clock.Timestamp,
    last: std.Io.Clock.Timestamp,
    frames: u32 = 0,
    /// Time in the frame callback (physics, the program, its commit).
    busy_ns: u64 = 0,
    done: bool = false,
    elapsed_ms: f64 = 0,

    fn sinceMs(r: *const Run, from: std.Io.Clock.Timestamp) f64 {
        const now = std.Io.Clock.Timestamp.now(r.io, .awake);
        return @as(f64, @floatFromInt(from.durationTo(now).raw.toNanoseconds())) / 1e6;
    }

    fn frame(r: *Run, _: canvas.Frame) bool {
        const began = std.Io.Clock.Timestamp.now(r.io, .awake);
        const total = r.sinceMs(r.t0);
        const dt: f32 = @floatCast(@min(0.05, r.sinceMs(r.last) / 1000));
        r.last = began;
        const p = &r.program;
        p.begin();
        p.fillStyle(canvas.rgb(0x10141b));
        p.fillRect(0, 0, r.w, r.h);
        for (r.balls.items) |*b| {
            b.x += b.dx * dt;
            b.y += b.dy * dt;
            if (b.x < 6 or b.x > r.w - 6) b.dx = -b.dx;
            if (b.y < 6 or b.y > r.h - 6) b.dy = -b.dy;
            p.circle(b.x, b.y, 6);
            p.fillStyle(b.c);
            p.fill();
        }
        p.fillStyle(canvas.rgb(0xe8eaee));
        p.font(12, 400, false, "sans-serif");
        p.textBaseline(.top);
        var buf: [32]u8 = undefined;
        p.fillText(std.fmt.bufPrint(&buf, "{d} balls (Zig)", .{r.balls.items.len}) catch "", 8, 8);
        if (!r.target.commit(p)) {
            // The canvas or the window went.
            r.elapsed_ms = total;
            r.done = true;
            return false;
        }
        r.frames += 1;
        r.busy_ns += @intCast(began.durationTo(std.Io.Clock.Timestamp.now(r.io, .awake)).raw.toNanoseconds());
        // As the page's loop counts: this frame too, then stop when the
        // time is up (fps over the time until now).
        if (total >= r.ms) {
            r.elapsed_ms = r.sinceMs(r.t0);
            r.done = true;
            return false;
        }
        return true;
    }

    pub fn deinit(r: *Run) void {
        r.program.deinit();
        r.balls.deinit(r.gpa);
    }
};

var current: ?*Run = null;

/// Start `count` balls in <canvas id="zigballs"> for `ms`: false when there
/// is no such native canvas (the WebView, or not rendered yet).
pub fn start(gpa: std.mem.Allocator, io: std.Io, count: u32, ms: f64) bool {
    const window = oriel.App.getWindow("main") orelse return false;
    var target = canvas.Canvas.open(window, "zigballs") orelse return false;
    const size = target.size() orelse return false;
    stop();
    const r = gpa.create(Run) catch return false;
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    r.* = .{ .io = io, .target = target, .program = .init(gpa), .gpa = gpa, .w = size[0], .h = size[1], .ms = ms, .t0 = now, .last = now };
    const w = size[0];
    const h = size[1];
    for (0..count) |i| {
        const f: f32 = @floatFromInt(i);
        r.balls.append(gpa, .{
            .x = 10 + @mod(f * 37.13, w - 20),
            .y = 10 + @mod(f * 23.71, h - 20),
            .dx = 40 + @as(f32, @floatFromInt(i % 7)) * 17,
            .dy = 30 + @as(f32, @floatFromInt(i % 5)) * 23,
            .c = colors[i % colors.len],
        }) catch {
            r.deinit();
            gpa.destroy(r);
            return false;
        };
    }
    canvas.onFrame(window, r, Run.frame) catch {
        r.deinit();
        gpa.destroy(r);
        return false;
    };
    current = r;
    return true;
}

pub const Result = struct { done: bool, fps: f64, frames: u32, frame_us: f64 };

/// The current run's numbers (done: it ended).
pub fn result() Result {
    const r = current orelse return .{ .done = true, .fps = 0, .frames = 0, .frame_us = 0 };
    if (!r.done) return .{ .done = false, .fps = 0, .frames = r.frames, .frame_us = 0 };
    const fps = if (r.elapsed_ms > 0) @as(f64, @floatFromInt(r.frames)) / (r.elapsed_ms / 1000) else 0;
    const frame_us = if (r.frames > 0) @as(f64, @floatFromInt(r.busy_ns)) / 1e3 / @as(f64, @floatFromInt(r.frames)) else 0;
    return .{ .done = true, .fps = fps, .frames = r.frames, .frame_us = frame_us };
}

/// End the current run (if any) and free it.
pub fn stop() void {
    const r = current orelse return;
    current = null;
    if (oriel.App.getWindow("main")) |window| canvas.stopFrames(window, r);
    const gpa = r.gpa;
    r.deinit();
    gpa.destroy(r);
}
