//! Breakout's Zig mode (-Dnative_ui): web/physics.js's rules and
//! web/draw.js's drawing in Zig, drawn into the page's <canvas id="cv">
//! through oriel.canvas at the display's rate, with no JavaScript per
//! frame. The page keeps the HTML around it (HUD, overlays, settings) and
//! the input, and tells Zig what changed (main.zig's zig_* commands); Zig
//! tells the page the score, lives, level and its stats (events
//! "breakout:state", "breakout:stats").

const std = @import("std");
const oriel = @import("oriel");
const canvas = oriel.canvas;

// ---------------------------------------------------------------------------
// The rules (physics.js)

const row_colors = [_]canvas.Color{
    canvas.rgb(0xff5d73), canvas.rgb(0xff9f43), canvas.rgb(0xffd166), canvas.rgb(0x3ad07a),
    canvas.rgb(0x36c5f0), canvas.rgb(0x6d8bff), canvas.rgb(0xb18cff), canvas.rgb(0xf78fb3),
};

const max_particles = 1500;
const paddle_speed = 900; // px/s with the keys
const paddle_follow = 2400; // px/s at most toward a pointer
// Match physics.js: collision substeps must not grow forever in autoplay.
const max_speed_multiplier: f32 = 3;
const max_cols = 16;
const max_rows = 12;

const Ball = struct { x: f32, y: f32, vx: f32, vy: f32, r: f32, stuck: bool };
const Particle = struct { x: f32, y: f32, vx: f32, vy: f32, life: f32, t: f32, color: u8 };

const Bricks = struct {
    cols: usize = 0,
    rows: usize = 0,
    hits: [max_cols * max_rows]i8 = undefined,
    max: [max_cols * max_rows]i8 = undefined,
    left: usize = 0,
    x0: f32 = 0,
    y0: f32 = 0,
    bw: f32 = 0,
    bh: f32 = 0,
    gap: f32 = 0,
};

pub const Input = struct { target: ?f32 = null, dir: i32 = 0 };
const StepOpts = struct { particles: bool = true, endless: bool = false };
const Out = struct { broken: u32 = 0, lost: bool = false, cleared: bool = false };

pub const World = struct {
    gpa: std.mem.Allocator,
    rng: std.Random.DefaultPrng,
    w: f32 = 0,
    h: f32 = 0,
    rows: usize = 6,
    balls: std.ArrayList(Ball) = .empty,
    particles: std.ArrayList(Particle) = .empty,
    bricks: Bricks = .{},
    have_bricks: bool = false,
    paddle: struct { x: f32, y: f32 = 0, w: f32 = 0, h: f32 = 12 },
    score: u32 = 0,
    lives: i32 = 3,
    level: u32 = 1,
    over: bool = false,

    pub fn init(gpa: std.mem.Allocator, w: f32, h: f32, rows: usize, seed: u64) !World {
        var world: World = .{ .gpa = gpa, .rng = .init(seed), .rows = std.math.clamp(rows, 2, max_rows), .paddle = .{ .x = w / 2 } };
        errdefer world.deinit();
        try world.particles.ensureTotalCapacity(gpa, max_particles);
        world.resize(w, h);
        try world.buildLevel();
        return world;
    }

    pub fn deinit(world: *World) void {
        world.balls.deinit(world.gpa);
        world.particles.deinit(world.gpa);
    }

    fn random(world: *World) f32 {
        return world.rng.random().float(f32);
    }

    /// The ball speed for the world's size and level (px/s).
    fn ballSpeed(world: *const World) f32 {
        const base = @min(720, @max(320, world.h * 0.8));
        return base * @min(max_speed_multiplier, 1 + 0.08 * @as(f32, @floatFromInt(world.level - 1)));
    }

    fn brickGeometry(world: *World) void {
        const b = &world.bricks;
        const margin: f32 = 12;
        const gap: f32 = 4;
        b.gap = gap;
        b.x0 = margin;
        b.y0 = if (world.h < 420) @max(36, world.h * 0.1) else @max(96, world.h * 0.14);
        const cols: f32 = @floatFromInt(b.cols);
        b.bw = (world.w - 2 * margin - gap * (cols - 1)) / cols;
        const fit = (world.h * 0.55 - b.y0) / @as(f32, @floatFromInt(b.rows)) - gap;
        b.bh = @max(4, @min(@min(24, world.h * 0.035), fit));
    }

    /// A new brick grid: the top rows take more hits as levels go by.
    pub fn buildLevel(world: *World) !void {
        const cols: usize = @intFromFloat(@max(6, @min(16, @floor(world.w / 56))));
        const rows = world.rows;
        const tough = @min(rows - 1, 1 + world.level / 2);
        var b: Bricks = .{ .cols = cols, .rows = rows, .left = cols * rows };
        for (0..rows) |r| {
            const n: i8 = if (r < tough) (if (r == 0 and world.level > 2) 3 else 2) else 1;
            for (0..cols) |c| b.hits[r * cols + c] = n;
        }
        b.max = b.hits;
        world.bricks = b;
        world.have_bricks = true;
        world.brickGeometry();
        world.balls.clearRetainingCapacity();
        try world.balls.append(world.gpa, world.stuckBall());
    }

    /// The board changed size: everything keeps its place in proportion.
    pub fn resize(world: *World, w: f32, h: f32) void {
        const sx = if (world.w != 0) w / world.w else 1;
        const sy = if (world.h != 0) h / world.h else 1;
        world.w = w;
        world.h = h;
        const p = &world.paddle;
        p.w = @min(160, @max(70, w * 0.16));
        p.y = h - 28;
        p.x = clamp(p.x * sx, p.w / 2, w - p.w / 2);
        for (world.balls.items) |*b| {
            b.x = clamp(b.x * sx, b.r, w - b.r);
            b.y = if (b.stuck) p.y - b.r - 1 else b.y * sy;
        }
        for (world.particles.items) |*q| {
            q.x *= sx;
            q.y *= sy;
        }
        if (world.have_bricks) world.brickGeometry();
    }

    fn stuckBall(world: *const World) Ball {
        const p = world.paddle;
        return .{ .x = p.x, .y = p.y - 7, .vx = 0, .vy = 0, .r = 6, .stuck = true };
    }

    /// Launch the ball on the paddle as `count` balls in a fan.
    pub fn launch(world: *World, count: u32) !bool {
        if (world.over) return false;
        var stuck: ?Ball = null;
        var n_kept: usize = 0;
        for (world.balls.items) |b| {
            if (b.stuck) {
                if (stuck == null) stuck = b;
                continue;
            }
            world.balls.items[n_kept] = b;
            n_kept += 1;
        }
        const s = stuck orelse return false;
        world.balls.shrinkRetainingCapacity(n_kept);
        const speed = world.ballSpeed();
        const n = std.math.clamp(count, 1, 500);
        try world.balls.ensureUnusedCapacity(world.gpa, n);
        for (0..n) |i| {
            // Up, spread over ±55° (one ball: a little to the right).
            const a: f32 = if (n == 1) 0.25 else ((@as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1))) * 2 - 1) * 0.96;
            world.balls.appendAssumeCapacity(.{ .x = s.x, .y = s.y, .vx = @sin(a) * speed, .vy = -@cos(a) * speed, .r = s.r, .stuck = false });
        }
        return true;
    }

    /// One step of `dt` seconds.
    pub fn step(world: *World, dt: f32, input: Input, opts: StepOpts) !Out {
        var out: Out = .{};
        if (world.over) return out;
        world.movePaddle(dt, input);
        const p = world.paddle;
        const speed = world.ballSpeed();
        const balls = world.balls.items;
        var alive: usize = 0;
        for (0..balls.len) |i| {
            var b = balls[i];
            if (b.stuck) {
                b.x = p.x;
                b.y = p.y - b.r - 1;
                balls[alive] = b;
                alive += 1;
                continue;
            }
            // Substeps so a fast ball can't pass through a brick.
            const dist = std.math.hypot(b.vx, b.vy) * dt;
            const n: usize = @intFromFloat(@max(1, @ceil(dist / (b.r * 0.9))));
            const h = dt / @as(f32, @floatFromInt(n));
            var gone = false;
            var s: usize = 0;
            while (s < n and !gone) : (s += 1) {
                b.x += b.vx * h;
                b.y += b.vy * h;
                if (b.x < b.r) {
                    b.x = b.r;
                    b.vx = @abs(b.vx);
                } else if (b.x > world.w - b.r) {
                    b.x = world.w - b.r;
                    b.vx = -@abs(b.vx);
                }
                if (b.y < b.r) {
                    b.y = b.r;
                    b.vy = @abs(b.vy);
                }
                if (b.vy > 0 and b.y + b.r >= p.y and b.y - b.r <= p.y + p.h and b.x >= p.x - p.w / 2 - b.r and b.x <= p.x + p.w / 2 + b.r) {
                    // The paddle sends it up at an angle from where it hit (±60°).
                    const rel = clamp((b.x - p.x) / (p.w / 2), -1, 1);
                    const a = rel * (std.math.pi / 3.0) + (world.random() - 0.5) * 0.06;
                    b.vx = @sin(a) * speed;
                    b.vy = -@cos(a) * speed;
                    b.y = p.y - b.r;
                }
                if (world.hitBrick(&b, &out, opts)) break;
                if (b.y - b.r > world.h) gone = true;
            }
            if (!gone) {
                balls[alive] = b;
                alive += 1;
            }
        }
        world.balls.shrinkRetainingCapacity(alive);
        world.stepParticles(dt);
        if (world.bricks.left == 0) {
            world.level += 1;
            try world.buildLevel();
            out.cleared = true;
        } else if (alive == 0) {
            out.lost = true;
            if (!opts.endless) world.lives -= 1;
            if (world.lives <= 0) {
                world.over = true;
            } else try world.balls.append(world.gpa, world.stuckBall());
        }
        return out;
    }

    fn movePaddle(world: *World, dt: f32, input: Input) void {
        const p = &world.paddle;
        if (input.target) |target| {
            const d = target - p.x;
            const max = paddle_follow * dt;
            p.x += if (@abs(d) <= max) d else std.math.sign(d) * max;
        } else if (input.dir != 0) {
            p.x += @as(f32, @floatFromInt(input.dir)) * paddle_speed * dt;
        }
        p.x = clamp(p.x, p.w / 2, world.w - p.w / 2);
    }

    // The brick under the ball, if any: it bounces off the side it went in
    // by least, and the brick loses a hit. One brick per substep.
    fn hitBrick(world: *World, b: *Ball, out: *Out, opts: StepOpts) bool {
        const g = &world.bricks;
        const cw = g.bw + g.gap;
        const ch = g.bh + g.gap;
        const c0: i64 = @intFromFloat(@floor((b.x - b.r - g.x0) / cw));
        const c1: i64 = @intFromFloat(@floor((b.x + b.r - g.x0) / cw));
        const r0: i64 = @intFromFloat(@floor((b.y - b.r - g.y0) / ch));
        const r1: i64 = @intFromFloat(@floor((b.y + b.r - g.y0) / ch));
        const rows: i64 = @intCast(g.rows);
        const cols: i64 = @intCast(g.cols);
        if (r1 < 0 or r0 >= rows or c1 < 0 or c0 >= cols) return false;
        var r = @max(0, r0);
        while (r <= @min(rows - 1, r1)) : (r += 1) {
            var c = @max(0, c0);
            while (c <= @min(cols - 1, c1)) : (c += 1) {
                const k: usize = @intCast(r * cols + c);
                if (g.hits[k] <= 0) continue;
                const x = g.x0 + @as(f32, @floatFromInt(c)) * cw;
                const y = g.y0 + @as(f32, @floatFromInt(r)) * ch;
                const nx = clamp(b.x, x, x + g.bw);
                const ny = clamp(b.y, y, y + g.bh);
                const dx = b.x - nx;
                const dy = b.y - ny;
                if (dx * dx + dy * dy > b.r * b.r) continue;
                // The face it went in by least: pushed back out of it, and a
                // hit only when it was moving into that face.
                const px = @min(b.x + b.r - x, x + g.bw - (b.x - b.r));
                const py = @min(b.y + b.r - y, y + g.bh - (b.y - b.r));
                var into: bool = undefined;
                if (px < py) {
                    const left = b.x < x + g.bw / 2;
                    into = if (left) b.vx > 0 else b.vx < 0;
                    b.x = if (left) x - b.r else x + g.bw + b.r;
                    if (into) b.vx = -b.vx;
                } else {
                    const above = b.y < y + g.bh / 2;
                    into = if (above) b.vy > 0 else b.vy < 0;
                    b.y = if (above) y - b.r else y + g.bh + b.r;
                    if (into) b.vy = -b.vy;
                }
                if (!into) return false; // pushed out; it keeps going
                g.hits[k] -= 1;
                world.score += 10;
                if (g.hits[k] == 0) {
                    g.left -= 1;
                    out.broken += 1;
                    world.score += 10 * @as(u32, @intCast(g.max[k]));
                    if (opts.particles) world.burst(x + g.bw / 2, y + g.bh / 2, @intCast(@mod(r, row_colors.len)));
                }
                return true;
            }
        }
        return false;
    }

    fn burst(world: *World, x: f32, y: f32, color: u8) void {
        var i: usize = 0;
        while (i < 10 and world.particles.items.len < max_particles) : (i += 1) {
            const a = world.random() * std.math.pi * 2;
            const v = 60 + world.random() * 220;
            world.particles.appendAssumeCapacity(.{ .x = x, .y = y, .vx = @cos(a) * v, .vy = @sin(a) * v - 80, .life = 0.5 + world.random() * 0.5, .t = 0, .color = color });
        }
    }

    fn stepParticles(world: *World, dt: f32) void {
        const ps = world.particles.items;
        var n: usize = 0;
        for (ps) |q0| {
            var q = q0;
            q.t += dt;
            if (q.t >= q.life) continue;
            q.vy += 600 * dt;
            q.x += q.vx * dt;
            q.y += q.vy * dt;
            ps[n] = q;
            n += 1;
        }
        world.particles.shrinkRetainingCapacity(n);
    }
};

fn clamp(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

// ---------------------------------------------------------------------------
// The drawing (draw.js)

const bg = canvas.rgb(0x0d1119);

fn draw(p: *canvas.Program, world: *const World, cw: f32, ch: f32, dpr: f32, hint: ?[]const u8) void {
    p.begin();
    p.globalAlpha(1);
    p.fillStyle(bg);
    p.fillRect(0, 0, cw, ch);
    p.save();
    if (dpr != 1) p.scale(dpr, dpr);
    drawBricks(p, world);
    drawParticles(p, world);
    drawPaddle(p, world);
    drawBalls(p, world);
    if (hint) |text| {
        p.globalAlpha(0.8);
        p.fillStyle(canvas.rgb(0xc9d1e3));
        p.font(15, 400, false, "sans-serif");
        p.textAlign(.center);
        p.textBaseline(.middle);
        p.fillText(text, world.w / 2, world.h * 0.62);
        p.globalAlpha(1);
    }
    p.restore();
}

fn drawBricks(p: *canvas.Program, world: *const World) void {
    const g = &world.bricks;
    for (0..g.rows) |r| {
        const color = row_colors[r % row_colors.len];
        const y = g.y0 + @as(f32, @floatFromInt(r)) * (g.bh + g.gap);
        for (0..g.cols) |c| {
            const k = r * g.cols + c;
            const hits = g.hits[k];
            if (hits <= 0) continue;
            const x = g.x0 + @as(f32, @floatFromInt(c)) * (g.bw + g.gap);
            // Fainter as it takes hits; a light edge on top.
            p.globalAlpha(0.45 + 0.55 * (@as(f32, @floatFromInt(hits)) / @as(f32, @floatFromInt(g.max[k]))));
            p.fillStyle(color);
            p.fillRect(x, y, g.bw, g.bh);
            p.globalAlpha(0.35);
            p.fillStyle(canvas.rgb(0xffffff));
            p.fillRect(x, y, g.bw, 2);
            if (g.max[k] > 1) {
                // A dot per hit left.
                p.globalAlpha(0.8);
                p.fillStyle(bg);
                const n: f32 = @floatFromInt(hits);
                for (0..@intCast(hits)) |i| p.fillRect(x + g.bw / 2 - (n * 6) / 2 + @as(f32, @floatFromInt(i)) * 6 + 1, y + g.bh / 2 - 2, 4, 4);
            }
        }
    }
    p.globalAlpha(1);
}

fn drawParticles(p: *canvas.Program, world: *const World) void {
    for (world.particles.items) |q| {
        p.globalAlpha(1 - q.t / q.life);
        p.fillStyle(row_colors[q.color]);
        p.fillRect(q.x - 1.5, q.y - 1.5, 3, 3);
    }
    p.globalAlpha(1);
}

fn drawPaddle(p: *canvas.Program, world: *const World) void {
    const pd = world.paddle;
    const r = pd.h / 2;
    p.fillStyle(canvas.rgb(0xe8eaee));
    p.beginPath();
    p.arc(pd.x - pd.w / 2 + r, pd.y + r, r, std.math.pi / 2.0, std.math.pi * 1.5, false);
    p.lineTo(pd.x + pd.w / 2 - r, pd.y);
    p.arc(pd.x + pd.w / 2 - r, pd.y + r, r, -std.math.pi / 2.0, std.math.pi / 2.0, false);
    p.closePath();
    p.fill();
    p.fillStyle(canvas.rgb(0x6d8bff));
    p.fillRect(pd.x - pd.w / 2 + r, pd.y + pd.h - 3, pd.w - 2 * r, 3);
}

// Each ball a path of its own: the native backends fill a lone circle from
// a cached mask (GTK), where a path of many circles is rasterized whole.
fn drawBalls(p: *canvas.Program, world: *const World) void {
    p.fillStyle(canvas.rgb(0xffffff));
    for (world.balls.items) |b| {
        p.circle(b.x, b.y, b.r);
        p.fill();
    }
}

// ---------------------------------------------------------------------------
// The driver: a frame callback, the page's input, the HUD's numbers.

pub const Settings = struct {
    balls: u32 = 1,
    rows: u32 = 6,
    particles: bool = true,
    autoplay: bool = false,
    /// BREAKOUT_DEMO: autoplay with this many balls, the rates to the log.
    demo: u32 = 0,
    /// "Click or press Space to launch" (the page's words for its input).
    hint: []const u8 = "",
};

pub const Game = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: *oriel.App.Window,
    target: canvas.Canvas,
    program: canvas.Program,
    world: World,
    settings: Settings,
    hint_buf: [64]u8 = undefined,
    input: Input = .{},
    paused: bool = false,
    redraw: bool = true,
    dpr: f32 = 1,
    last: ?std.Io.Clock.Timestamp = null,
    started: std.Io.Clock.Timestamp,
    // Stats over half a second: frames, their interval, the Zig time.
    acc_n: u32 = 0,
    acc_dt: f64 = 0,
    acc_phys: f64 = 0,
    acc_draw: f64 = 0,
    acc_since: f64 = 0,
    demo_log: f64 = 0,
    shown: struct { score: u32 = std.math.maxInt(u32), lives: i32 = -1, level: u32 = 0, over: bool = false } = .{},

    fn nowMs(g: *const Game) f64 {
        const ns = g.started.durationTo(std.Io.Clock.Timestamp.now(g.io, .awake)).raw.toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / 1e6;
    }

    pub fn setSettings(g: *Game, s: Settings) void {
        const n = @min(s.hint.len, g.hint_buf.len);
        @memcpy(g.hint_buf[0..n], s.hint[0..n]);
        g.settings = s;
        g.settings.hint = g.hint_buf[0..n];
        if (!s.particles) g.world.particles.clearRetainingCapacity();
        g.redraw = true;
    }

    /// Autoplay: under the lowest ball coming down.
    fn autoTarget(g: *Game) ?f32 {
        var best: ?Ball = null;
        for (g.world.balls.items) |b| {
            if (!b.stuck and b.vy > 0 and (best == null or b.y > best.?.y)) best = b;
        }
        if (best == null and g.world.balls.items.len > 0) best = g.world.balls.items[0];
        const b = best orelse return null;
        return b.x + @as(f32, @floatCast(@sin(g.nowMs() / 700))) * g.world.paddle.w * 0.3;
    }

    pub fn frame(g: *Game, _: canvas.Frame) bool {
        const t = g.nowMs();
        const prev = g.last;
        g.last = std.Io.Clock.Timestamp.now(g.io, .awake);
        const first = prev == null;
        if (first) g.acc_since = t;
        const real: f64 = if (prev) |p| @as(f64, @floatFromInt(p.durationTo(g.last.?).raw.toNanoseconds())) / 1e9 else 0;
        const dt: f32 = @floatCast(@min(real, 1.0 / 20.0));

        const t0 = g.nowMs();
        const running = !g.paused and !g.world.over;
        if (running and !first) {
            const demo = g.settings.demo > 0;
            var input = g.input;
            if (g.settings.autoplay or demo) input.target = g.autoTarget();
            const ev = g.world.step(dt, input, .{ .particles = g.settings.particles, .endless = g.settings.autoplay or demo }) catch Out{};
            // Autoplay relaunches by itself.
            if (g.settings.autoplay or demo) {
                var all_stuck = g.world.balls.items.len > 0;
                for (g.world.balls.items) |b| all_stuck = all_stuck and b.stuck;
                // Demo chooses the initial setting; later slider edits use
                // the current count, as the page's JS mode does.
                if (all_stuck) _ = g.world.launch(g.settings.balls) catch {};
            }
            if (ev.broken > 0 or ev.lost or ev.cleared or g.world.over) g.sendState();
        }
        const t1 = g.nowMs();
        if (running or g.redraw) {
            g.redraw = false;
            const size = g.target.size() orelse return false; // the page replaced its canvas
            var stuck = false;
            for (g.world.balls.items) |b| stuck = stuck or b.stuck;
            const hint: ?[]const u8 = if (!g.world.over and stuck and !g.settings.autoplay and g.settings.demo == 0 and g.settings.hint.len > 0) g.settings.hint else null;
            draw(&g.program, &g.world, size[0], size[1], g.dpr, hint);
            if (!g.target.commit(&g.program)) return false;
        }
        const t2 = g.nowMs();
        if (!first) {
            g.acc_n += 1;
            g.acc_dt += real;
            g.acc_phys += t1 - t0;
            g.acc_draw += t2 - t1;
            if (t - g.acc_since >= 500) g.stats(t);
        }
        return true;
    }

    /// Score, lives, level and game over to the page (its HUD), when they
    /// change.
    pub fn sendState(g: *Game) void {
        const w = &g.world;
        if (g.shown.score == w.score and g.shown.lives == w.lives and g.shown.level == w.level and g.shown.over == w.over) return;
        g.shown = .{ .score = w.score, .lives = w.lives, .level = w.level, .over = w.over };
        g.window.emit("breakout:state", .{ .score = w.score, .lives = w.lives, .level = w.level, .over = w.over });
    }

    fn stats(g: *Game, t: f64) void {
        const n: f64 = @floatFromInt(g.acc_n);
        const fps = n * 1000 / (t - g.acc_since);
        const frame_ms = g.acc_dt * 1000 / n;
        const phys = g.acc_phys / n;
        const drw = g.acc_draw / n;
        g.window.emit("breakout:stats", .{
            .fps = fps,
            .frame = frame_ms,
            .phys = phys,
            .draw = drw,
            .balls = g.world.balls.items.len,
            .particles = g.world.particles.items.len,
        });
        if (g.settings.demo > 0) {
            g.demo_log += t - g.acc_since;
            if (g.demo_log >= 2000) {
                g.demo_log = 0;
                std.log.info("breakout: fps {d:.1} frame {d:.2} ms zig {d:.3} ms (physics {d:.3}, draw {d:.3}) balls {d} particles {d} renderer native mode zig", .{ fps, frame_ms, phys + drw, phys, drw, g.world.balls.items.len, g.world.particles.items.len });
            }
        }
        g.acc_n = 0;
        g.acc_dt = 0;
        g.acc_phys = 0;
        g.acc_draw = 0;
        g.acc_since = t;
    }

    /// A new game (the board's size and rows kept).
    pub fn restart(g: *Game) void {
        const seed: u64 = @truncate(@as(u96, @bitCast(std.Io.Clock.Timestamp.now(g.io, .awake).raw.toNanoseconds())));
        const world = World.init(g.gpa, g.world.w, g.world.h, g.settings.rows, seed) catch return;
        g.world.deinit();
        g.world = world;
        g.paused = false;
        g.redraw = true;
        g.sendState();
    }

    /// The bricks rebuilt with `rows` rows.
    pub fn setRows(g: *Game, rows: u32) void {
        g.settings.rows = rows;
        g.world.rows = std.math.clamp(rows, 2, max_rows);
        g.world.buildLevel() catch {};
        g.redraw = true;
    }

    /// The board is `w`×`h` CSS px, drawn at `dpr`.
    pub fn resize(g: *Game, w: f32, h: f32, dpr: f32) void {
        g.world.resize(w, h);
        g.dpr = dpr;
        g.redraw = true;
    }

    /// Launch, or a new game after game over.
    pub fn launchOrRestart(g: *Game) void {
        if (g.world.over) return g.restart();
        if (g.world.launch(g.settings.balls) catch false) g.redraw = true;
    }

    pub fn deinit(g: *Game) void {
        g.program.deinit();
        g.world.deinit();
    }
};

var current: ?*Game = null;

pub fn game() ?*Game {
    return current;
}

/// Start the Zig mode on the main window's <canvas id="cv">: a new game
/// on a `w`×`h` board (CSS px) drawn at `dpr`. False when there's no
/// native canvas (the WebView).
pub fn start(gpa: std.mem.Allocator, io: std.Io, w: f32, h: f32, dpr: f32, s: Settings) bool {
    stop();
    const window = oriel.App.getWindow("main") orelse return false;
    const target = canvas.Canvas.open(window, "cv") orelse return false;
    const g = gpa.create(Game) catch return false;
    const now = std.Io.Clock.Timestamp.now(io, .awake);
    const seed: u64 = @truncate(@as(u96, @bitCast(now.raw.toNanoseconds())));
    var world = World.init(gpa, w, h, s.rows, seed) catch {
        gpa.destroy(g);
        return false;
    };
    _ = &world;
    g.* = .{ .gpa = gpa, .io = io, .window = window, .target = target, .program = .init(gpa), .world = world, .settings = .{}, .dpr = dpr, .started = now };
    g.setSettings(s);
    canvas.onFrame(window, g, Game.frame) catch {
        g.deinit();
        gpa.destroy(g);
        return false;
    };
    current = g;
    g.sendState();
    return true;
}

/// Leave the Zig mode: the page draws its canvas again.
pub fn stop() void {
    const g = current orelse return;
    current = null;
    canvas.stopFrames(g.window, g);
    g.target.release();
    const gpa = g.gpa;
    g.deinit();
    gpa.destroy(g);
}

test "the rules: a launched ball breaks bricks and the score goes up" {
    var world = try World.init(std.testing.allocator, 800, 600, 6, 1);
    defer world.deinit();
    try std.testing.expect(try world.launch(5));
    try std.testing.expectEqual(@as(usize, 5), world.balls.items.len);
    var broken: u32 = 0;
    for (0..2000) |_| {
        const out = try world.step(1.0 / 120.0, .{ .target = world.balls.items[0].x }, .{ .endless = true });
        broken += out.broken;
        if (world.balls.items.len == 0) break;
    }
    try std.testing.expect(broken > 0);
    try std.testing.expect(world.score > 0);
}

test "extended autoplay keeps ball speed bounded" {
    var world = try World.init(std.testing.allocator, 412, 850, 12, 1);
    defer world.deinit();
    const base = world.ballSpeed();
    world.level = 2;
    try std.testing.expectApproxEqAbs(base * 1.08, world.ballSpeed(), 0.001);
    for ([_]u32{ 26, 100, 4000, 39222, std.math.maxInt(u32) }) |level| {
        world.level = level;
        try std.testing.expectEqual(base * max_speed_multiplier, world.ballSpeed());
    }
}
