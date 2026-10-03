//! Render bench: one page, timed in Oriel's WebView and native renderers.
//!
//!   oriel-render-bench                  GUI: run the tests, show the results
//!   RENDER_BENCH=1 oriel-render-bench   run them, print one JSON line, exit
//!   (an environment variable: GTK rejects command-line options it doesn't know)
//!
//! Build `zig build` (WebView) and `zig build -Dnative_ui` (native widgets)
//! and compare. The page (web/) measures; Zig gives it the time since the
//! process started (startup) and its resident memory.

const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

var io: std.Io = undefined;
var started: std.Io.Clock.Timestamp = undefined;
var bench_mode = false;

pub const Commands = struct {
    /// Milliseconds since main() began: the page's first script calls it.
    pub fn since_start(_: std.mem.Allocator) f64 {
        const ns = started.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toNanoseconds();
        return @as(f64, @floatFromInt(ns)) / 1e6;
    }

    /// Proportional memory (PSS: shared pages split between the processes
    /// using them) in MB of this process and its children, children's
    /// children…: a WebView's page runs in WebKit's own processes. Linux
    /// /proc; 0 elsewhere. It moves with what else on the desktop maps the
    /// same libraries (a GL driver's are tens of MB): private_mb doesn't.
    pub fn pss_mb(_: std.mem.Allocator) f64 {
        return treeMb("\nPss:");
    }

    /// The same processes' private memory (Pss_Anon: their heaps and other
    /// anonymous pages, not shared libraries' pages): what the app itself
    /// allocated, comparable from one day to the next.
    pub fn private_mb(_: std.mem.Allocator) f64 {
        return treeMb("\nPss_Anon:");
    }

    /// One smaps_rollup field, summed over this process's tree, in MB.
    fn treeMb(comptime key: []const u8) f64 {
        var pids: [512]u32 = undefined;
        var parents: [512]u32 = undefined;
        var pss_kb: [512]u64 = undefined;
        var n: usize = 0;
        var dir = std.Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return 0;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (n == pids.len) break;
            const pid = std.fmt.parseInt(u32, e.name, 10) catch continue;
            var path_buf: [64]u8 = undefined;
            var buf: [512]u8 = undefined;
            // ppid: the 4th field of stat, after the parenthesized name.
            const stat = std.Io.Dir.cwd().readFile(io, std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid}) catch continue, &buf) catch continue;
            const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
            var f = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
            _ = f.next(); // state
            const ppid = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue;
            var big: [2048]u8 = undefined;
            const rollup = std.Io.Dir.cwd().readFile(io, std.fmt.bufPrint(&path_buf, "/proc/{d}/smaps_rollup", .{pid}) catch continue, &big) catch continue;
            // "Pss:   12345 kB"
            const at = std.mem.indexOf(u8, rollup, key) orelse continue;
            var line = std.mem.tokenizeAny(u8, rollup[at + key.len ..], " \t\n");
            pids[n] = pid;
            parents[n] = ppid;
            pss_kb[n] = std.fmt.parseInt(u64, line.next() orelse continue, 10) catch continue;
            n += 1;
        }
        // Our tree: a process counts when its parent chain reaches us.
        const self: u32 = @intCast(std.os.linux.getpid());
        var total: u64 = 0;
        for (0..n) |i| {
            var p = pids[i];
            var depth: usize = 0;
            while (p != self and p > 1 and depth < 32) : (depth += 1) {
                p = for (0..n) |j| {
                    if (pids[j] == p) break parents[j];
                } else 0;
            }
            if (p == self) total += pss_kb[i];
        }
        return @as(f64, @floatFromInt(total)) / 1024;
    }

    /// Whether RENDER_BENCH is set (the page then reports and quits).
    pub fn bench_mode_on(_: std.mem.Allocator) bool {
        return bench_mode;
    }

    /// Whether ORIEL_NUI_TRACE is set (on Android: `debug.oriel.env`): the
    /// page then logs a line before each timed row change, and the native
    /// renderer one after each draw, so logcat's timestamps give the
    /// on-screen time.
    pub fn trace_on(_: std.mem.Allocator) bool {
        return std.c.getenv("ORIEL_NUI_TRACE") != null;
    }

    /// The canvas balls in Zig (zig_balls.zig): start `count` balls in
    /// <canvas id="zigballs"> for `ms`; false without the native renderer.
    pub fn zig_balls(_: std.mem.Allocator, args: struct { count: u32, ms: f64 }) bool {
        if (comptime !oriel.options.native_ui) return false else return zig_balls_mod.start(std.heap.smp_allocator, io, args.count, args.ms);
    }

    /// The Zig run's frame rate and per-frame cost (done: it ended; the
    /// run is freed then).
    pub fn zig_balls_result(_: std.mem.Allocator) ZigBallsResult {
        if (comptime !oriel.options.native_ui) return .{ .done = true, .fps = 0, .frames = 0, .frame_us = 0 } else {
            const r = zig_balls_mod.result();
            if (r.done) zig_balls_mod.stop();
            return .{ .done = r.done, .fps = r.fps, .frames = r.frames, .frame_us = r.frame_us };
        }
    }

    /// The results as JSON: printed on stdout; in bench mode the app quits.
    pub fn report(_: std.mem.Allocator, args: struct { json: []const u8 }) void {
        std.debug.print("{s}\n", .{args.json});
        if (bench_mode) oriel.App.quit(0);
    }
};

pub const ZigBallsResult = struct { done: bool, fps: f64, frames: u32, frame_us: f64 };
const zig_balls_mod = if (oriel.options.native_ui) @import("zig_balls.zig") else struct {};

pub const Events = struct {};

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    started = std.Io.Clock.Timestamp.now(io, .awake);
    bench_mode = init.environ_map.get("RENDER_BENCH") != null;
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.RenderBench",
        .title = "Oriel render bench",
        .width = 900,
        .height = 700,
        .assets = app.assets,
        .dev = app.dev,
    });
}
