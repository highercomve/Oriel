//! `dictation`'s system engine on iOS and macOS: Apple's Speech framework
//! (`SFSpeechRecognizer`), on the device where it can (`requiresOnDevice-
//! Recognition` when `supportsOnDeviceRecognition`), else Apple's servers.
//!
//! Audio comes from an `AVAudioEngine` input tap (or, as a test hook for
//! devices without a microphone, `test.wav` from the models directory,
//! passed in by `dictation`). Apple's recognizer doesn't end utterances on
//! its own and stops a task after about a minute, so, like OrielSpeech.kt
//! on Android, each phrase is its own task: after a pause (or 50 s) the
//! request's audio is ended, its final result becomes "dictation:final",
//! and a new task takes the audio that follows, until `stop`.
//!
//! Events, as on Android: "dictation:partial", "dictation:final" (backend
//! "Apple"), "dictation:level", "dictation:error", "dictation:ended".
//!
//! Needs the microphone permission and speech recognition authorization
//! (asked on the first `start`); the bundle's Info.plist must carry
//! `NSSpeechRecognitionUsageDescription` (Oriel writes it with the
//! microphone's text), or iOS and macOS end the app when it asks: without
//! it the engine reports itself unavailable. Links the Speech framework.

const std = @import("std");
const builtin = @import("builtin");
const App = @import("../../core/App.zig");
const heap = @import("../../core/heap.zig");
const objc = @import("../../platform/apple/objc.zig");
const blocks = @import("../../platform/apple/blocks.zig");
const ShellMod = if (builtin.os.tag == .ios) @import("../../platform/ios/Shell.zig") else @import("../../platform/macos/Shell.zig");

const Object = objc.Object;
const id = objc.c.id;
const BOOL = objc.c.BOOL;
const log = std.log.scoped(.dictation);
const is_ios = builtin.os.tag == .ios;

pub const name = "Apple";

// ---------------------------------------------------------------------------
// Objective-C helpers

fn class(comptime n: [:0]const u8) ?objc.Class {
    return objc.getClass(n);
}

fn isTrue(v: BOOL) bool {
    return if (BOOL == bool) v else v != 0;
}

fn boolean(v: bool) BOOL {
    return if (BOOL == bool) v else @intFromBool(v);
}

const nil: Object = .{ .value = null };

/// An autoreleased NSString.
fn nsString(bytes: []const u8) Object {
    const s = class("NSString").?.msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithBytes:length:encoding:", .{ bytes.ptr, @as(c_ulong, bytes.len), @as(c_ulong, 4) });
    return s.msgSend(Object, "autorelease", .{});
}

fn utf8(s: Object) []const u8 {
    if (s.value == null) return "";
    const p = s.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

// libdispatch (libSystem on both)
const DispatchFn = *const fn (ctx: ?*anyopaque) callconv(.c) void;
extern var _dispatch_main_q: u8;
extern "c" fn dispatch_after_f(when: u64, queue: *anyopaque, ctx: ?*anyopaque, work: DispatchFn) void;
extern "c" fn dispatch_time(when: u64, delta: i64) u64;
extern "c" fn dispatch_semaphore_create(value: isize) ?*anyopaque;
extern "c" fn dispatch_semaphore_wait(sema: *anyopaque, timeout: u64) isize;
extern "c" fn dispatch_semaphore_signal(sema: *anyopaque) isize;

fn afterMain(ms: u32, work: DispatchFn) void {
    dispatch_after_f(dispatch_time(0, @as(i64, ms) * std.time.ns_per_ms), @ptrCast(&_dispatch_main_q), null, work);
}

// Speech and AVFoundation constants
const auth_not_determined: isize = 0;
const auth_authorized: isize = 3;
const task_hint_dictation: isize = 1;
const pcm_float32: c_ulong = 1;
extern const AVAudioSessionCategoryPlayAndRecord: id;
const session_mix_with_others: c_ulong = 0x1;
const session_allow_bluetooth: c_ulong = 0x4;
const session_default_to_speaker: c_ulong = 0x8;

// ---------------------------------------------------------------------------
// State. Main thread, except `lock` (the current request, read by the
// audio tap and the test feeder), the atomics and the results.

var lock: std.c.pthread_mutex_t = .{};
var request: id = null; // +1, under `lock`
var recognizer: id = null; // +1
var audio_engine: id = null; // +1
var generation: usize = 0;
var on_device_now = false;
var partial_len: usize = 0;
var partial_hash: u64 = 0;
var last_change: std.Io.Timestamp = undefined;
var phrase_start: std.Io.Timestamp = undefined;

var active = std.atomic.Value(bool).init(false);
var ended = std.atomic.Value(bool).init(true);
var io: std.Io = undefined;
var t_start: std.Io.Timestamp = undefined;

/// Under `lock`.
var finals: std.ArrayList(u8) = .empty;
var updates: u32 = 0;
var last_error: ?[]const u8 = null;
var error_buf: [48]u8 = undefined;

var feeder: ?std.Thread = null;
var test_audio: ?[]f32 = null;
var test_audio_gpa: std.mem.Allocator = undefined;

/// A pause this long after the last change ends the phrase.
const pause_ms = 1200;
/// Apple stops a task after about a minute: end phrases before that.
const max_phrase_ms = 50_000;

// ---------------------------------------------------------------------------
// Availability

pub const Availability = struct { installed: bool, on_device: bool };

/// Without the usage description, asking for authorization ends the app.
fn hasUsageKey() bool {
    const bundle = (class("NSBundle") orelse return false).msgSend(Object, "mainBundle", .{});
    if (bundle.value == null) return false;
    const key = nsString("NSSpeechRecognitionUsageDescription");
    return bundle.msgSend(Object, "objectForInfoDictionaryKey:", .{key}).value != null;
}

/// Whether a recognizer exists for the device's language, and runs on
/// the device.
pub fn available() Availability {
    const Ctx = struct {
        out: Availability = .{ .installed = false, .on_device = false },
        fn run(self: *@This()) void {
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            if (class("SFSpeechRecognizer") == null or !hasUsageKey()) return;
            const r = makeRecognizer("auto") orelse return;
            defer r.release();
            self.out = .{ .installed = true, .on_device = isTrue(r.msgSend(BOOL, "supportsOnDeviceRecognition", .{})) };
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return ctx.out;
    return ctx.out;
}

pub fn isActive() bool {
    return active.load(.acquire);
}

/// Recognizers want a region ("es-ES", not "es"): the device's own if it
/// speaks that language, else the language's most common one (as
/// OrielSpeech.kt). Written into `buf`.
pub fn localeTag(buf: []u8, language: []const u8, device_language: []const u8, device_region: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, language, '-') != null or std.mem.indexOfScalar(u8, language, '_') != null) return language;
    if (std.mem.eql(u8, device_language, language) and device_region.len > 0)
        return std.fmt.bufPrint(buf, "{s}-{s}", .{ language, device_region }) catch language;
    const regions = [_]struct { []const u8, []const u8 }{
        .{ "en", "US" }, .{ "es", "ES" }, .{ "de", "DE" }, .{ "fr", "FR" }, .{ "it", "IT" }, .{ "pt", "BR" }, .{ "nl", "NL" },
        .{ "ja", "JP" }, .{ "ko", "KR" }, .{ "zh", "CN" }, .{ "ru", "RU" }, .{ "pl", "PL" }, .{ "tr", "TR" }, .{ "sv", "SE" },
    };
    for (regions) |r| if (std.mem.eql(u8, r[0], language))
        return std.fmt.bufPrint(buf, "{s}-{s}", .{ language, r[1] }) catch language;
    return language;
}

test localeTag {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("es-ES", localeTag(&buf, "es", "en", "US"));
    try std.testing.expectEqualStrings("es-MX", localeTag(&buf, "es", "es", "MX"));
    try std.testing.expectEqualStrings("en-US", localeTag(&buf, "en", "es", "ES"));
    try std.testing.expectEqualStrings("de-AT", localeTag(&buf, "de-AT", "en", "US"));
    try std.testing.expectEqualStrings("eu", localeTag(&buf, "eu", "en", "US"));
}

/// A recognizer (+1) for `language` ("auto": the device's), or null when
/// Apple has none for it.
fn makeRecognizer(language: []const u8) ?Object {
    const cls = class("SFSpeechRecognizer") orelse return null;
    if (language.len == 0 or std.mem.eql(u8, language, "auto")) {
        const r = cls.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
        return if (r.value != null) r else null;
    }
    const current = class("NSLocale").?.msgSend(Object, "currentLocale", .{});
    var buf: [32]u8 = undefined;
    const tag = localeTag(&buf, language, utf8(current.msgSend(Object, "languageCode", .{})), utf8(current.msgSend(Object, "countryCode", .{})));
    const locale = class("NSLocale").?.msgSend(Object, "localeWithLocaleIdentifier:", .{nsString(tag)});
    const r = cls.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithLocale:", .{locale});
    return if (r.value != null) r else null;
}

// ---------------------------------------------------------------------------
// Authorization

var auth_sem: ?*anyopaque = null;
var auth_status = std.atomic.Value(isize).init(auth_not_determined);

fn onAuthorization(_: *blocks.BlockLiteral, status: isize) callconv(.c) void {
    auth_status.store(status, .release);
    _ = dispatch_semaphore_signal(auth_sem.?);
}

/// Speech recognition authorization, asking the user the first time.
/// Waits for the answer: not on the main thread.
fn authorize() !void {
    const cls = class("SFSpeechRecognizer") orelse return error.EngineUnavailable;
    var st = cls.msgSend(isize, "authorizationStatus", .{});
    if (st == auth_not_determined) {
        if (auth_sem == null) auth_sem = dispatch_semaphore_create(0) orelse return error.EngineUnavailable;
        cls.msgSend(void, "requestAuthorization:", .{blocks.globalBlock(onAuthorization)});
        // The user answers a dialog: give them a minute.
        if (dispatch_semaphore_wait(auth_sem.?, dispatch_time(0, 60 * std.time.ns_per_s)) != 0) return error.SpeechNotAllowed;
        st = auth_status.load(.acquire);
    }
    if (st != auth_authorized) return error.SpeechNotAllowed;
}

// ---------------------------------------------------------------------------
// Start and stop

/// Start listening. `language`: a BCP 47 tag or "auto"; `on_device`: use
/// the on-device recognizer when there is one. `audio`: 16 kHz samples fed
/// instead of the microphone (the test hook; owned, allocated with
/// `audio_gpa`). Not on the main thread (authorization waits for the user).
pub fn start(app_io: std.Io, language: []const u8, on_device: bool, audio: ?[]f32, audio_gpa: std.mem.Allocator) !void {
    // `audio` is freed here until `test_audio` owns it.
    if (active.load(.acquire) or !ended.load(.acquire)) {
        if (audio) |a| audio_gpa.free(a);
        return error.AlreadyRecording;
    }
    authorize() catch |e| {
        if (audio) |a| audio_gpa.free(a);
        return e;
    };
    io = app_io;
    _ = std.c.pthread_mutex_lock(&lock);
    finals.clearRetainingCapacity();
    updates = 0;
    last_error = null;
    _ = std.c.pthread_mutex_unlock(&lock);

    const Ctx = struct {
        language: []const u8,
        on_device: bool,
        err: ?anyerror = null,
        fn run(self: *@This()) void {
            startMain(self.language, self.on_device) catch |e| {
                self.err = e;
            };
        }
    };
    var ctx: Ctx = .{ .language = language, .on_device = on_device };
    test_audio = audio;
    test_audio_gpa = audio_gpa;
    t_start = std.Io.Clock.awake.now(io);
    ended.store(false, .release);
    active.store(true, .release);
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch |e| {
        ctx.err = e;
    };
    if (ctx.err) |e| {
        active.store(false, .release);
        var none: void = {};
        ShellMod.runOnMainThread(void, &none, struct {
            fn run(_: *void) void {
                cleanup();
            }
        }.run) catch {};
        ended.store(true, .release);
        if (test_audio) |a| audio_gpa.free(a);
        test_audio = null;
        return e;
    }
    if (test_audio != null) feeder = std.Thread.spawn(.{}, feed, .{}) catch |e| {
        if (stop(heap.gpa)) |r| heap.gpa.free(r.text) else |_| {}
        return e;
    };
}

fn startMain(language: []const u8, on_device: bool) !void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const r = makeRecognizer(language) orelse return error.LanguageUnavailable;
    recognizer = r.value;
    if (!isTrue(r.msgSend(BOOL, "isAvailable", .{}))) return error.RecognizerUnavailable;
    on_device_now = on_device and isTrue(r.msgSend(BOOL, "supportsOnDeviceRecognition", .{}));
    try startTask();
    if (test_audio == null) try startMicrophone();
    afterMain(300, &watch);
    log.info("Apple speech: {s}, {s}", .{ language, if (on_device_now) "on the device" else "Apple's servers" });
}

fn startMicrophone() !void {
    if (is_ios) {
        const session = class("AVAudioSession").?.msgSend(Object, "sharedInstance", .{});
        _ = session.msgSend(BOOL, "setCategory:withOptions:error:", .{ AVAudioSessionCategoryPlayAndRecord, session_mix_with_others | session_allow_bluetooth | session_default_to_speaker, @as(?*anyopaque, null) });
        _ = session.msgSend(BOOL, "setActive:error:", .{ boolean(true), @as(?*anyopaque, null) });
    }
    const engine = class("AVAudioEngine").?.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
    audio_engine = engine.value;
    const input = engine.msgSend(Object, "inputNode", .{});
    const format = input.msgSend(Object, "outputFormatForBus:", .{@as(c_ulong, 0)});
    // No input device (a simulator on a Mac without one): a 0 Hz format,
    // which a tap would crash on.
    if (format.value == null or format.msgSend(f64, "sampleRate", .{}) <= 0 or format.msgSend(u32, "channelCount", .{}) == 0)
        return error.MicrophoneUnavailable;
    input.msgSend(void, "installTapOnBus:bufferSize:format:block:", .{ @as(c_ulong, 0), @as(u32, 4096), format, blocks.globalBlock(onTap) });
    engine.msgSend(void, "prepare", .{});
    if (!isTrue(engine.msgSend(BOOL, "startAndReturnError:", .{@as(?*anyopaque, null)}))) return error.MicrophoneUnavailable;
}

/// A new recognition task for the audio from here on (main thread).
fn startTask() !void {
    const req = class("SFSpeechAudioBufferRecognitionRequest").?.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
    if (req.value == null) return error.RecognizerUnavailable;
    req.msgSend(void, "setShouldReportPartialResults:", .{boolean(true)});
    req.msgSend(void, "setTaskHint:", .{task_hint_dictation});
    req.msgSend(void, "setRequiresOnDeviceRecognition:", .{boolean(on_device_now)});
    // iOS 16 / macOS 13: punctuation, as Android's formatting.
    if (req.getClass().?.respondsToSelector(objc.sel("setAddsPunctuation:"))) req.msgSend(void, "setAddsPunctuation:", .{boolean(true)});
    generation += 1;
    var handler = blocks.contextBlock(onResult, @ptrFromInt(generation));
    // The recognizer keeps the task (and copies the block) while it runs.
    _ = (Object{ .value = recognizer }).msgSend(Object, "recognitionTaskWithRequest:resultHandler:", .{ req, handler.ptr() });
    _ = std.c.pthread_mutex_lock(&lock);
    const old = request;
    request = req.value;
    _ = std.c.pthread_mutex_unlock(&lock);
    if (old != null) (Object{ .value = old }).release();
    partial_len = 0;
    partial_hash = 0;
    last_change = std.Io.Clock.awake.now(io);
    phrase_start = last_change;
}

/// End the current phrase: its request gets no more audio (its final
/// result follows), and a new task takes over.
fn nextPhrase() void {
    _ = std.c.pthread_mutex_lock(&lock);
    const req = request;
    _ = std.c.pthread_mutex_unlock(&lock);
    if (req != null) (Object{ .value = req }).msgSend(void, "endAudio", .{});
    startTask() catch |e| fail(@errorName(e));
}

/// Every 300 ms while listening: a pause after some text, or a phrase
/// running into Apple's one-minute limit, ends the phrase.
fn watch(_: ?*anyopaque) callconv(.c) void {
    if (!active.load(.acquire)) return;
    const now = std.Io.Clock.awake.now(io);
    const quiet = @divTrunc(last_change.durationTo(now).toNanoseconds(), std.time.ns_per_ms);
    const long = @divTrunc(phrase_start.durationTo(now).toNanoseconds(), std.time.ns_per_ms);
    if ((partial_len > 0 and quiet >= pause_ms) or long >= max_phrase_ms) nextPhrase();
    afterMain(300, &watch);
}

fn onTap(_: *blocks.BlockLiteral, buffer: id, _: id) callconv(.c) void {
    _ = std.c.pthread_mutex_lock(&lock);
    const req = request;
    if (req != null) _ = objc.c.objc_retain(req);
    _ = std.c.pthread_mutex_unlock(&lock);
    const b: Object = .{ .value = buffer };
    if (req != null) {
        (Object{ .value = req }).msgSend(void, "appendAudioPCMBuffer:", .{b});
        objc.c.objc_release(req);
    }
    const frames = b.msgSend(u32, "frameLength", .{});
    const channels = b.msgSend(?[*]const [*]const f32, "floatChannelData", .{}) orelse return;
    emitLevel(channels[0][0..frames]);
}

fn emitLevel(samples: []const f32) void {
    var sum: f32 = 0;
    for (samples) |s| sum += s * s;
    const rms = if (samples.len > 0) @sqrt(sum / @as(f32, @floatFromInt(samples.len))) else 0;
    App.emit("dictation:level", .{ .seconds = elapsed(), .level = @min(1, rms * 8) });
}

/// The test hook: `test_audio` at real-time pace, then silence, as a
/// microphone would (a feeder thread).
fn feed() void {
    const audio = test_audio.?;
    const rate = 16000;
    const chunk = rate / 10;
    const format = class("AVAudioFormat").?.msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithCommonFormat:sampleRate:channels:interleaved:", .{ pcm_float32, @as(f64, rate), @as(u32, 1), boolean(false) });
    defer format.release();
    const silence = [_]f32{0} ** chunk;
    var pos: usize = 0;
    while (active.load(.acquire)) {
        io.sleep(.fromMilliseconds(100), .awake) catch break;
        const part = if (pos < audio.len) audio[pos..@min(pos + chunk, audio.len)] else &silence;
        pos += part.len;
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        const buf = class("AVAudioPCMBuffer").?.msgSend(Object, "alloc", .{})
            .msgSend(Object, "initWithPCMFormat:frameCapacity:", .{ format, @as(u32, @intCast(part.len)) });
        if (buf.value == null) continue;
        defer buf.release();
        buf.msgSend(void, "setFrameLength:", .{@as(u32, @intCast(part.len))});
        const channels = buf.msgSend(?[*]const [*]f32, "floatChannelData", .{}) orelse continue;
        @memcpy(channels[0][0..part.len], part);
        _ = std.c.pthread_mutex_lock(&lock);
        const req = request;
        if (req != null) _ = objc.c.objc_retain(req);
        _ = std.c.pthread_mutex_unlock(&lock);
        if (req != null) {
            (Object{ .value = req }).msgSend(void, "appendAudioPCMBuffer:", .{buf});
            objc.c.objc_release(req);
        }
        emitLevel(part);
    }
}

// ---------------------------------------------------------------------------
// Results

/// Errors that only mean "nothing was said" (kAFAssistantErrorDomain
/// 1110), or a task we ended (216, 301): the session goes on.
fn isQuiet(code: isize) bool {
    return code == 1110 or code == 216 or code == 301 or code == 203;
}

fn onResult(block: *blocks.ContextBlock, result: id, err: id) callconv(.c) void {
    const gen = @intFromPtr(block.ctx);
    const current = gen == generation;
    if (result != null) {
        const r: Object = .{ .value = result };
        const text = utf8(r.msgSend(Object, "bestTranscription", .{}).msgSend(Object, "formattedString", .{}));
        if (isTrue(r.msgSend(BOOL, "isFinal", .{}))) {
            if (text.len > 0) {
                _ = std.c.pthread_mutex_lock(&lock);
                if (finals.items.len > 0) finals.append(heap.gpa, ' ') catch {};
                finals.appendSlice(heap.gpa, text) catch {};
                _ = std.c.pthread_mutex_unlock(&lock);
                App.emit("dictation:final", .{ .text = text, .audio_s = elapsed(), .transcribe_ms = @as(u64, 0), .backend = name });
            }
            if (current) {
                App.emit("dictation:partial", .{ .text = "" });
                taskEnded();
            }
            return;
        }
        if (!current) return;
        const h = std.hash.Wyhash.hash(0, text);
        if (h != partial_hash) {
            partial_hash = h;
            partial_len = text.len;
            last_change = std.Io.Clock.awake.now(io);
            _ = std.c.pthread_mutex_lock(&lock);
            updates += 1;
            _ = std.c.pthread_mutex_unlock(&lock);
            App.emit("dictation:partial", .{ .text = text });
        }
        return;
    }
    if (err == null or !current) return;
    const code = (Object{ .value = err }).msgSend(isize, "code", .{});
    if (isQuiet(code)) return taskEnded();
    const domain = utf8((Object{ .value = err }).msgSend(Object, "domain", .{}));
    log.warn("speech recognizer: {s} {d}", .{ domain, code });
    fail(std.fmt.bufPrint(&error_buf, "SpeechError{d}", .{code}) catch "SpeechError");
}

/// The current task finished (its final, or nothing heard): the next
/// phrase while listening, else the end.
fn taskEnded() void {
    if (active.load(.acquire)) startTask() catch |e| fail(@errorName(e)) else finish();
}

fn fail(message: []const u8) void {
    _ = std.c.pthread_mutex_lock(&lock);
    last_error = message;
    _ = std.c.pthread_mutex_unlock(&lock);
    App.emit("dictation:error", .{ .message = message });
    active.store(false, .release);
    finish();
}

/// Stop the audio and let the recognizer go (main thread).
fn cleanup() void {
    if (audio_engine != null) {
        const engine: Object = .{ .value = audio_engine };
        engine.msgSend(Object, "inputNode", .{}).msgSend(void, "removeTapOnBus:", .{@as(c_ulong, 0)});
        engine.msgSend(void, "stop", .{});
        engine.release();
        audio_engine = null;
    }
    _ = std.c.pthread_mutex_lock(&lock);
    const req = request;
    request = null;
    _ = std.c.pthread_mutex_unlock(&lock);
    if (req != null) (Object{ .value = req }).release();
    if (recognizer != null) (Object{ .value = recognizer }).release();
    recognizer = null;
    generation += 1; // late results are for no one
}

/// Listening is over (main thread): "dictation:ended".
fn finish() void {
    if (ended.load(.acquire)) return;
    active.store(false, .release);
    cleanup();
    ended.store(true, .release);
    App.emit("dictation:ended", .{ .engine = "system" });
}

pub const Result = struct { text: []const u8, audio_s: f32, updates: u32, error_code: ?[]const u8 };

/// Stop listening and wait (up to 5 s) for the last phrase's result. Not
/// on the main thread (the results arrive there).
pub fn stop(a: std.mem.Allocator) !Result {
    const Stop = struct {
        fn run(_: *void) void {
            if (ended.load(.acquire)) return;
            active.store(false, .release);
            if (audio_engine != null) {
                const engine: Object = .{ .value = audio_engine };
                engine.msgSend(Object, "inputNode", .{}).msgSend(void, "removeTapOnBus:", .{@as(c_ulong, 0)});
                engine.msgSend(void, "stop", .{});
            }
            _ = std.c.pthread_mutex_lock(&lock);
            const req = request;
            _ = std.c.pthread_mutex_unlock(&lock);
            // The last phrase's final result, then the end (taskEnded).
            if (req != null) (Object{ .value = req }).msgSend(void, "endAudio", .{}) else finish();
        }
        fn force(_: *void) void {
            finish();
        }
    };
    var none: void = {};
    active.store(false, .release);
    if (feeder) |t| t.join();
    feeder = null;
    try ShellMod.runOnMainThread(void, &none, Stop.run);
    var waited: u32 = 0;
    while (!ended.load(.acquire) and waited < 100) : (waited += 1) io.sleep(.fromMilliseconds(50), .awake) catch break;
    if (!ended.load(.acquire)) ShellMod.runOnMainThread(void, &none, Stop.force) catch {};
    if (test_audio) |t| test_audio_gpa.free(t);
    test_audio = null;
    _ = std.c.pthread_mutex_lock(&lock);
    defer _ = std.c.pthread_mutex_unlock(&lock);
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
