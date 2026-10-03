const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

/// BREAKOUT_DEMO=<balls>: the page plays itself with that many balls and
/// logs its frame rate (for comparing the renderers). BREAKOUT_MODE=zig:
/// in the Zig mode (native renderer).
var demo_balls: ?[]const u8 = null;
var demo_mode_env: ?[]const u8 = null;
var io: std.Io = undefined;

/// The Zig mode (game.zig): only with the native renderer.
const zig = if (oriel.options.native_ui) @import("game.zig") else struct {};
const native = oriel.options.native_ui;

const ZigSettings = struct { balls: u32 = 1, rows: u32 = 6, particles: bool = true, autoplay: bool = false, demo: u32 = 0, hint: []const u8 = "" };

pub const Commands = struct {
    /// The demo's ball count, or null to play.
    pub fn demo(_: std.mem.Allocator) ?[]const u8 {
        return demo_balls;
    }

    /// BREAKOUT_MODE (the demo's mode: "js" or "zig"), or null.
    pub fn demo_mode(_: std.mem.Allocator) ?[]const u8 {
        return demo_mode_env;
    }

    /// A line from the page to the app's log (the demo's frame rates).
    pub fn log(_: std.mem.Allocator, args: struct { line: []const u8 }) void {
        std.log.info("breakout: {s}", .{args.line});
    }

    // The Zig mode (game.zig). The page keeps its HTML and input and tells
    // the game what changed; the game draws the canvas each frame and sends
    // its numbers back ("breakout:state", "breakout:stats").

    /// Start a new game in Zig on the `w`×`h` board at `dpr`; false
    /// without the native renderer (the page then stays in JS).
    pub fn zig_start(_: std.mem.Allocator, args: struct { w: f32, h: f32, dpr: f32, settings: ZigSettings }) bool {
        if (comptime !native) return false else return zig.start(std.heap.smp_allocator, io, args.w, args.h, args.dpr, zigSettings(args.settings));
    }

    /// Back to the page's JS (it draws its canvas again).
    pub fn zig_stop(_: std.mem.Allocator) void {
        if (comptime native) zig.stop();
    }

    /// The paddle's target (a pointer, CSS px; null: none) and the keys'
    /// direction (-1, 0, 1).
    pub fn zig_input(_: std.mem.Allocator, args: struct { target: ?f32 = null, dir: i32 = 0 }) void {
        if (comptime native) if (zig.game()) |g| {
            g.input = .{ .target = args.target, .dir = std.math.clamp(args.dir, -1, 1) };
        };
    }

    /// Launch (a new game after game over).
    pub fn zig_launch(_: std.mem.Allocator) void {
        if (comptime native) if (zig.game()) |g| g.launchOrRestart();
    }

    pub fn zig_restart(_: std.mem.Allocator) void {
        if (comptime native) if (zig.game()) |g| g.restart();
    }

    pub fn zig_pause(_: std.mem.Allocator, args: struct { on: bool }) void {
        if (comptime native) if (zig.game()) |g| {
            g.paused = args.on;
            g.redraw = true;
        };
    }

    /// The settings panel changed (rows rebuild the bricks).
    pub fn zig_settings(_: std.mem.Allocator, args: struct { settings: ZigSettings }) void {
        if (comptime native) if (zig.game()) |g| {
            const rows = args.settings.rows;
            const was = g.settings.rows;
            g.setSettings(zigSettings(args.settings));
            g.settings.rows = was;
            if (rows != was) g.setRows(rows);
        };
    }

    pub fn zig_resize(_: std.mem.Allocator, args: struct { w: f32, h: f32, dpr: f32 }) void {
        if (comptime native) if (zig.game()) |g| g.resize(args.w, args.h, args.dpr);
    }
};
fn zigSettings(s: ZigSettings) if (native) zig.Settings else void {
    if (comptime !native) return;
    return .{ .balls = s.balls, .rows = s.rows, .particles = s.particles, .autoplay = s.autoplay, .demo = s.demo, .hint = s.hint };
}

pub const Events = struct {};

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    if (init.environ_map.get("BREAKOUT_DEMO")) |n| {
        if (n.len > 0) demo_balls = try init.arena.allocator().dupe(u8, n);
    }
    if (init.environ_map.get("BREAKOUT_MODE")) |m| {
        if (m.len > 0) demo_mode_env = try init.arena.allocator().dupe(u8, m);
    }
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.Breakout",
        .title = "Breakout",
        .width = 900,
        .height = 700,
        .assets = app.assets,
        .dev = app.dev,
    });
}
