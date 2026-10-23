//! oriel.tts's `.system` engine on Android: the device's TextToSpeech
//! (OrielTts.kt), nothing to download. `speak` hands the text over and waits
//! for it to be read; the progress comes back as `NativeLib.onTtsEvent`.

const std = @import("std");
const runtime = @import("../../platform/android/runtime.zig");
const jni = @import("../../platform/android/jni.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

const log = std.log.scoped(.tts);

/// OrielTts's events.
pub const Event = enum(i32) { started = 0, finished = 1, failed = 2, stopped = 3 };

var next_id: std.atomic.Value(i64) = .init(1);
/// The utterance being read (0: none) and its last event (-1: none yet).
var current: std.atomic.Value(i64) = .init(0);
var last_event: std.atomic.Value(i32) = .init(-1);

/// Whether the device has a TextToSpeech engine. Any thread.
pub fn available() bool {
    const Ctx = struct {
        ok: bool = false,
        fn run(c: *@This()) void {
            c.ok = runtime.call(.boolean, "ttsAvailable", "()Z", .{}) orelse false;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return false;
    return ctx.ok;
}

/// Start reading `text` (BCP 47 `language`, "" = the device's) and return
/// its id; `wait` then blocks until it's read.
pub fn start(text: []const u8, language: []const u8, rate: f32) !i64 {
    const id = next_id.fetchAdd(1, .monotonic);
    current.store(id, .release);
    last_event.store(-1, .release);
    const Ctx = struct {
        id: i64,
        text: []const u8,
        language: []const u8,
        rate: f32,
        fn run(c: *@This()) void {
            _ = runtime.call(.void, "ttsSpeak", "(J[B[BI)V", .{ c.id, c.text, c.language, @as(i32, @intFromFloat(c.rate * 100)) });
        }
    };
    var ctx: Ctx = .{ .id = id, .text = text, .language = language, .rate = rate };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return error.Unsupported;
    return id;
}

/// The next event of utterance `id` from `after` on (blocks; polls).
pub fn next(id: i64, after: i32) Event {
    while (true) {
        if (current.load(.acquire) != id) return .stopped;
        const e = last_event.load(.acquire);
        if (e != after and e >= 0) return @enumFromInt(e);
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 20 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
}

/// Silence it now (any thread).
pub fn stop() void {
    const Ctx = struct {
        fn run(_: *@This()) void {
            _ = runtime.call(.void, "ttsStop", "()V", .{});
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
}

fn onTtsEvent(_: *jni.Env, _: jni.jclass, id: jni.jlong, kind: jni.jint) callconv(.c) void {
    if (current.load(.acquire) != id) return;
    last_event.store(kind, .release);
    if (kind != @intFromEnum(Event.started)) log.debug("system voice: {s}", .{@tagName(@as(Event, @enumFromInt(kind)))});
}

comptime {
    @export(&onTtsEvent, .{ .name = "Java_dev_oriel_NativeLib_onTtsEvent" });
}
