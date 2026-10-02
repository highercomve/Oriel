//! Timings of the native renderer's stages, for finding where a frame's
//! time goes: `zig build -Dnative_ui -Dnative_ui_prof`. Built without the
//! flag, every call here is compiled out (`enabled` is comptime false).
//!
//! Each stage logs one line, `PROF <stage> <ms> …` (info level, scope
//! native_ui), and the JS side adds `PROF render …` lines (render.js,
//! `__host.prof`). Stages: call (a call into the page), render (the JS
//! render: style + flatten, emit, apply), apply (the ops: JSON parse, props),
//! layout / flayout (Yoga, after a render / for a layout read), yoga (with
//! its text measures), draw (GTK paint).

const std = @import("std");

pub const enabled = @import("build_options").native_ui_prof;

const log = std.log.scoped(.native_ui);

/// A monotonic clock in ms (0 when profiling is off).
pub inline fn now() f64 {
    if (comptime !enabled) return 0;
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(f64, @floatFromInt(ts.sec)) * 1e3 + @as(f64, @floatFromInt(ts.nsec)) / 1e6;
}

/// Log `PROF <fmt>` (nothing when profiling is off).
pub inline fn report(comptime fmt: []const u8, args: anytype) void {
    if (comptime !enabled) return;
    log.info("PROF " ++ fmt, args);
}

/// Time spent in text measures during the current layout (yoga).
pub var measures: usize = 0;
pub var measure_ms: f64 = 0;
/// Time spent in setProps during the current apply.
pub var props_ms: f64 = 0;
