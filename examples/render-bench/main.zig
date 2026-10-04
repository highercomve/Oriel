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
/// RENDER_BENCH_POWER=<seconds>: the page measures power (each scenario
/// that long) after the tests, and reports it with them.
var power_seconds: u32 = 0;

pub const Power = struct {
    ok: bool = false,
    mw: f64 = 0,
    ua: f64 = 0,
    mv: f64 = 0,
    plugged: bool = false,
    charge_uah: f64 = -1,
    /// A cumulative energy counter in µJ (Linux RAPL: the CPU package's),
    /// -1 without one; the page takes differences.
    energy_uj: f64 = -1,
    /// What was read: "battery", "rapl", or why nothing ("rapl: no access").
    source: []const u8 = "",
};

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
    /// Windows: this process's private bytes (its committed heaps; a
    /// WebView's msedgewebview2 processes aren't counted).
    pub fn private_mb(_: std.mem.Allocator) f64 {
        if (@import("builtin").os.tag == .windows) return winPrivateMb();
        return treeMb("\nPss_Anon:");
    }

    const ProcessMemoryCountersEx = extern struct {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
        private_usage: usize,
    };
    extern "kernel32" fn K32GetProcessMemoryInfo(process: *anyopaque, counters: *ProcessMemoryCountersEx, cb: u32) callconv(.winapi) c_int;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) *anyopaque;

    fn winPrivateMb() f64 {
        var m: ProcessMemoryCountersEx = undefined;
        m.cb = @sizeOf(ProcessMemoryCountersEx);
        if (K32GetProcessMemoryInfo(GetCurrentProcess(), &m, m.cb) == 0) return 0;
        return @as(f64, @floatFromInt(m.private_usage)) / (1024 * 1024);
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

    /// The device's power draw now, for the page's power meter: the
    /// battery's current and voltage (Android's BatteryManager; Linux's
    /// /sys/class/power_supply), whether a charger is in (then the numbers
    /// say nothing of the app), and the battery's charge counter (µAh, or
    /// µWh on Linux batteries that count energy; -1 without one). `ok`
    /// false: no battery to read here.
    pub fn power_now(_: std.mem.Allocator) Power {
        if (comptime @import("builtin").abi.isAndroid()) return androidPower();
        if (comptime @import("builtin").os.tag == .linux) return linuxPower();
        return .{};
    }

    fn androidPower() Power {
        const rt = oriel.android.runtime;
        const v = rt.call(.long, "batteryNow", "()J", .{}) orelse return .{};
        if (v == 0) return .{};
        var ua: f64 = @floatFromInt(v >> 32);
        // A few devices report mA, not µA: no phone runs on under 10 mA.
        if (@abs(ua) > 0 and @abs(ua) < 10_000) ua *= 1000;
        const mv: f64 = @floatFromInt((v >> 1) & 0x7fffffff);
        const charge = rt.call(.long, "batteryCharge", "()J", .{}) orelse std.math.minInt(i64);
        return .{
            .ok = true,
            .source = "battery",
            .mw = @abs(ua) / 1000 * mv / 1000,
            .ua = ua,
            .mv = mv,
            .plugged = v & 1 != 0,
            .charge_uah = if (charge == std.math.minInt(i64)) -1 else @floatFromInt(charge),
        };
    }

    /// The first battery under /sys/class/power_supply: power_now (µW), or
    /// current_now (µA) times voltage_now (µV).
    fn linuxPower() Power {
        var dir = std.Io.Dir.cwd().openDir(io, "/sys/class/power_supply", .{ .iterate = true }) catch return .{};
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            var path: [128]u8 = undefined;
            var buf: [64]u8 = undefined;
            const kind = readSys(std.fmt.bufPrint(&path, "/sys/class/power_supply/{s}/type", .{e.name}) catch continue, &buf) orelse continue;
            if (!std.mem.eql(u8, kind, "Battery")) continue;
            const field = struct {
                fn get(name: []const u8, f: []const u8) ?f64 {
                    var p: [128]u8 = undefined;
                    var b: [64]u8 = undefined;
                    const t = readSys(std.fmt.bufPrint(&p, "/sys/class/power_supply/{s}/{s}", .{ name, f }) catch return null, &b) orelse return null;
                    return std.fmt.parseFloat(f64, t) catch null;
                }
            }.get;
            const mv = (field(e.name, "voltage_now") orelse 0) / 1000;
            const ua = field(e.name, "current_now") orelse 0;
            const uw = field(e.name, "power_now") orelse @abs(ua) * mv / 1000;
            const status = readSys(std.fmt.bufPrint(&path, "/sys/class/power_supply/{s}/status", .{e.name}) catch continue, &buf) orelse "";
            const counter = field(e.name, "charge_now") orelse field(e.name, "energy_now") orelse -1;
            return .{
                .ok = true,
                .source = "battery",
                .mw = uw / 1000,
                .ua = ua,
                .mv = mv,
                .plugged = std.mem.eql(u8, status, "Charging") or std.mem.eql(u8, status, "Full") or std.mem.eql(u8, status, "Not charging"),
                .charge_uah = counter,
            };
        }
        return raplPower();
    }

    /// No battery (a desktop): the CPU package's energy counter (Intel and
    /// AMD RAPL through powercap). Root-only by default since the Platypus
    /// fix; a udev rule (or chmod) on energy_uj opens it.
    fn raplPower() Power {
        var buf: [64]u8 = undefined;
        const name = readSys("/sys/class/powercap/intel-rapl:0/name", &buf) orelse return .{ .source = "none" };
        if (!std.mem.startsWith(u8, name, "package")) return .{ .source = "none" };
        var ebuf: [64]u8 = undefined;
        const t = readSys("/sys/class/powercap/intel-rapl:0/energy_uj", &ebuf) orelse return .{ .source = "rapl: no access (energy_uj is root-only)" };
        const uj = std.fmt.parseFloat(f64, t) catch return .{ .source = "rapl: unreadable" };
        return .{ .ok = true, .source = "rapl", .energy_uj = uj };
    }

    fn readSys(path: []const u8, buf: []u8) ?[]const u8 {
        const t = std.Io.Dir.cwd().readFile(io, path, buf) catch return null;
        return std.mem.trim(u8, t, " \n");
    }

    /// RENDER_BENCH_POWER's seconds per power scenario (0: not set).
    pub fn power_seconds_set(_: std.mem.Allocator) u32 {
        return power_seconds;
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
        if (@import("builtin").abi.isAndroid()) {
            // Android apps have no terminal stderr; keep the report in logcat.
            oriel.log.logFn(.info, .render_bench, "{s}", .{args.json});
        } else {
            std.debug.print("{s}\n", .{args.json});
        }
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
    if (init.environ_map.get("RENDER_BENCH_POWER")) |v| power_seconds = std.fmt.parseInt(u32, v, 10) catch 60;
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .id = "dev.oriel.RenderBench",
        .title = "Oriel render bench",
        .width = 900,
        .height = 700,
        .assets = app.assets,
        .dev = app.dev,
    });
}
