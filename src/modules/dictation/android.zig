//! `dictation`'s system engine on Android: the platform's SpeechRecognizer
//! (OrielSpeech.kt): Google's on-device model on a Pixel, the maker's
//! recognition service elsewhere. It opens the microphone itself (needs
//! the microphone permission) and streams partial results; Android stops
//! it after each utterance and OrielSpeech restarts it until `stop`.

const std = @import("std");
const App = @import("../../core/App.zig");
const heap = @import("../../core/heap.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const runtime = @import("../../platform/android/runtime.zig");
const jni = @import("../../platform/android/jni.zig");

const log = std.log.scoped(.dictation);

pub const name = "Android";

pub const Availability = struct { installed: bool, on_device: bool };

/// Whether a recognizer is installed, and runs on the device (API 31+).
pub fn available() Availability {
    const Ctx = struct {
        bits: i32 = 0,
        fn run(self: *@This()) void {
            self.bits = runtime.call(.int, "speechAvailable", "()I", .{}) orelse 0;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return .{ .installed = false, .on_device = false };
    return .{ .installed = ctx.bits & 1 != 0, .on_device = ctx.bits & 2 != 0 };
}

var mutex: ShellMod.Mutex = .{};
var finals: std.ArrayList(u8) = .empty;
var active = std.atomic.Value(bool).init(false);
var ended = std.atomic.Value(bool).init(true);
/// Set while the app is shutting down: callbacks dispatched before the
/// cancel but delivered after it must not touch the stale `io` or emit
/// events from it.
var shut = std.atomic.Value(bool).init(false);
var io: std.Io = undefined;
var t_start: std.Io.Timestamp = undefined;
var updates: u32 = 0;
var last_error: ?[]const u8 = null;

/// Start listening. `language`: a BCP 47 tag ("de-DE", "es") or "auto"
/// (the device's language). `on_device`: prefer the on-device recognizer.
pub fn start(app_io: std.Io, language: []const u8, on_device: bool) !void {
    io = app_io;
    shut.store(false, .release);
    if (active.load(.acquire)) return error.AlreadyRecording;
    mutex.lock();
    finals.clearRetainingCapacity();
    updates = 0;
    last_error = null;
    mutex.unlock();
    const Ctx = struct {
        language: []const u8,
        on_device: bool,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "speechStart", "([BZ)Z", .{ self.language, self.on_device }) orelse false;
        }
    };
    var ctx: Ctx = .{ .language = language, .on_device = on_device };
    ended.store(false, .release);
    active.store(true, .release);
    t_start = std.Io.Clock.awake.now(io);
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) {
        active.store(false, .release);
        ended.store(true, .release);
        return error.RecognizerUnavailable;
    }
}

pub fn isActive() bool {
    return active.load(.acquire);
}

pub const Result = struct { text: []const u8, audio_s: f32, updates: u32, error_code: ?[]const u8 };

/// Stop listening and wait (up to 5 s) for the last results. Any thread
/// but the UI thread (the results arrive there).
pub fn stop(a: std.mem.Allocator) !Result {
    const Ctx = struct {
        fn run(_: *@This()) void {
            _ = runtime.call(.void, "speechStop", "()V", .{});
        }
    };
    var ctx: Ctx = .{};
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    var waited: u32 = 0;
    while (!ended.load(.acquire) and waited < 100) : (waited += 1) io.sleep(.fromMilliseconds(50), .awake) catch break;
    active.store(false, .release);
    mutex.lock();
    defer mutex.unlock();
    return .{
        .text = try a.dupe(u8, finals.items),
        .audio_s = elapsed(),
        .updates = updates,
        .error_code = last_error,
    };
}

fn elapsed() f32 {
    const ns = t_start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    return @as(f32, @floatFromInt(@max(ns, 0))) / std.time.ns_per_s;
}

/// Shell shutdown hook (registered by `dictation.init`, runs on the UI
/// thread while its queue still works): cancels the recognizer and marks
/// the session dead so late callbacks can't use the old `io` or emit
/// events from it. Does not wait for the recognizer: the shutdown call is
/// synchronous on the Kotlin side.
pub fn shutDown() void {
    if (!active.load(.acquire)) return;
    shut.store(true, .release);
    _ = runtime.call(.void, "speechStop", "()V", .{});
    active.store(false, .release);
    ended.store(true, .release);
}

/// SpeechRecognizer.ERROR_* names, for the "dictation:error" event.
fn errorName(code: i32) []const u8 {
    return switch (code) {
        1 => "NetworkTimeout",
        2 => "Network",
        3 => "Audio",
        4 => "Server",
        5 => "Client",
        6 => "SpeechTimeout",
        7 => "NoMatch",
        8 => "RecognizerBusy",
        9 => "InsufficientPermissions",
        10 => "TooManyRequests",
        11 => "ServerDisconnected",
        12 => "LanguageNotSupported",
        13 => "LanguageUnavailable",
        14 => "CannotCheckSupport",
        15 => "CannotListenToDownloadEvents",
        else => "Unknown",
    };
}

/// NativeLib.onSpeech (UI thread).
fn nativeSpeech(env: *jni.Env, _: jni.jclass, kind: jni.jint, text_arr: jni.jobject) callconv(.c) void {
    // The app is going away (Shell teardown): drop the result instead of
    // using the stale `io` (elapsed(), App.emit from it).
    if (shut.load(.acquire)) return;
    const text = (env.bytesAlloc(heap.gpa, text_arr) catch return) orelse &.{};
    defer if (text.len > 0) heap.gpa.free(text);
    const seconds = elapsed();
    switch (kind) {
        0 => {
            mutex.lock();
            updates += 1;
            mutex.unlock();
            App.emit("dictation:partial", .{ .text = text });
        },
        1 => {
            mutex.lock();
            if (finals.items.len > 0) finals.append(heap.gpa, ' ') catch {};
            finals.appendSlice(heap.gpa, text) catch {};
            mutex.unlock();
            App.emit("dictation:final", .{ .text = text, .audio_s = seconds, .transcribe_ms = @as(u64, 0), .backend = name });
            App.emit("dictation:partial", .{ .text = "" });
        },
        2 => {
            const level = std.fmt.parseInt(u8, text, 10) catch 0;
            App.emit("dictation:level", .{ .seconds = seconds, .level = @as(f32, @floatFromInt(level)) / 100 });
        },
        3 => {
            // "download": the language pack is being fetched (Android 13+).
            const e = if (std.mem.eql(u8, text, "download")) "LanguageDownloading" else errorName(std.fmt.parseInt(i32, text, 10) catch 0);
            log.warn("speech recognizer: {s}", .{e});
            mutex.lock();
            last_error = e;
            mutex.unlock();
            App.emit("dictation:error", .{ .message = e });
        },
        4 => {
            active.store(false, .release);
            ended.store(true, .release);
            App.emit("dictation:ended", .{ .engine = "system" });
        },
        else => {},
    }
}

comptime {
    @export(&nativeSpeech, .{ .name = "Java_dev_oriel_NativeLib_onSpeech" });
}
