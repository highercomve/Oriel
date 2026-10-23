//! Android backend: AAudio (NDK, `libaaudio.so`), microphone input as mono
//! f32. AAudio opens at the requested rate when the device can; otherwise the
//! stream runs at the device's rate and `read` resamples (linear), so callers
//! always get the rate they asked for (16 kHz for whisper).
//!
//! Needs the microphone permission (`.permissions = .{ .microphone = "..." }`
//! and `permissions.request(.microphone)`), and a foreground service of type
//! `microphone` to keep capturing while the app is in the background (the
//! Kotlin runtime's `OrielAudioService`, `OrielRuntime.startAudioService`).
//!
//! Sources: "default" (the default microphone), the input devices
//! `AudioManager.getDevices` reports, as "device:<id>", and on Android 10+
//! "system" (a monitor source): what other apps play, through
//! AudioPlaybackCapture. Opening "system" shows MediaProjection's consent
//! dialog (once per projection, from the window in front) and needs the
//! microphone permission and `.permissions.system_audio` (the foreground
//! service's mediaProjection type); Kotlin (OrielSystemAudio.kt) records and
//! writes the samples into a pipe that `read` reads. Apps that opt out of
//! capture, and calls (USAGE_VOICE_COMMUNICATION), stay silent.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const Resampler = @import("resample.zig");
const runtime = @import("../../platform/android/runtime.zig");
const jni = @import("../../platform/android/jni.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

const log = std.log.scoped(.audio_capture);

// <aaudio/AAudio.h>
const AAudioStreamBuilder = opaque {};
const AAudioStream = opaque {};
const aaudio_result_t = i32;
const AAUDIO_OK: aaudio_result_t = 0;
const AAUDIO_DIRECTION_INPUT: i32 = 1;
const AAUDIO_FORMAT_PCM_FLOAT: i32 = 2;
const AAUDIO_SHARING_MODE_SHARED: i32 = 1;
const AAUDIO_PERFORMANCE_MODE_NONE: i32 = 10;
const AAUDIO_INPUT_PRESET_VOICE_RECOGNITION: i32 = 6;

extern "aaudio" fn AAudio_createStreamBuilder(builder: *?*AAudioStreamBuilder) aaudio_result_t;
extern "aaudio" fn AAudio_convertResultToText(result: aaudio_result_t) [*:0]const u8;
extern "aaudio" fn AAudioStreamBuilder_setDirection(b: *AAudioStreamBuilder, direction: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setSampleRate(b: *AAudioStreamBuilder, rate: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setChannelCount(b: *AAudioStreamBuilder, count: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setFormat(b: *AAudioStreamBuilder, format: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setSharingMode(b: *AAudioStreamBuilder, mode: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setPerformanceMode(b: *AAudioStreamBuilder, mode: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setInputPreset(b: *AAudioStreamBuilder, preset: i32) void;
extern "aaudio" fn AAudioStreamBuilder_setDeviceId(b: *AAudioStreamBuilder, id: i32) void;
extern "aaudio" fn AAudioStreamBuilder_openStream(b: *AAudioStreamBuilder, stream: *?*AAudioStream) aaudio_result_t;
extern "aaudio" fn AAudioStreamBuilder_delete(b: *AAudioStreamBuilder) aaudio_result_t;
extern "aaudio" fn AAudioStream_requestStart(s: *AAudioStream) aaudio_result_t;
extern "aaudio" fn AAudioStream_requestStop(s: *AAudioStream) aaudio_result_t;
extern "aaudio" fn AAudioStream_close(s: *AAudioStream) aaudio_result_t;
extern "aaudio" fn AAudioStream_read(s: *AAudioStream, buffer: *anyopaque, frames: i32, timeout_ns: i64) aaudio_result_t;
extern "aaudio" fn AAudioStream_getSampleRate(s: *AAudioStream) i32;
extern "aaudio" fn AAudioStream_getChannelCount(s: *AAudioStream) i32;

fn resultText(r: aaudio_result_t) []const u8 {
    return std.mem.span(AAudio_convertResultToText(r));
}

/// "default", then the input devices from Kotlin ("device:<id>"). Free
/// with `freeSources`.
pub fn listSources(gpa: std.mem.Allocator) ![]common.Source {
    var list: std.ArrayList(common.Source) = .empty;
    errdefer {
        for (list.items) |s| {
            gpa.free(s.name);
            gpa.free(s.description);
        }
        list.deinit(gpa);
    }
    try appendSource(gpa, &list, "default", "Microphone");

    // "id\tname\n" lines from AudioManager.getDevices(GET_DEVICES_INPUTS).
    const Ctx = struct {
        text: ?[]u8 = null,
        system: bool = false,
        fn run(self: *@This()) void {
            const e = runtime.mainEnv() orelse return;
            const arr = runtime.call(.object, "audioInputs", "()[B", .{}) orelse null;
            self.text = runtime.takeBytes(e, heap.gpa, arr);
            self.system = runtime.call(.boolean, "systemAudioSupported", "()Z", .{}) orelse false;
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
    if (ctx.system) {
        const n = try gpa.dupeZ(u8, "system");
        errdefer gpa.free(n);
        const d = try gpa.dupe(u8, "What this device plays");
        errdefer gpa.free(d);
        try list.append(gpa, .{ .name = n, .description = d, .monitor = true });
    }
    if (ctx.text) |text| {
        defer heap.gpa.free(text);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            var name_buf: [32]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "device:{s}", .{line[0..tab]}) catch continue;
            try appendSource(gpa, &list, name, line[tab + 1 ..]);
        }
    }
    return list.toOwnedSlice(gpa);
}

fn appendSource(gpa: std.mem.Allocator, list: *std.ArrayList(common.Source), name: []const u8, description: []const u8) !void {
    const n = try gpa.dupeZ(u8, name);
    errdefer gpa.free(n);
    const d = try gpa.dupe(u8, description);
    errdefer gpa.free(d);
    try list.append(gpa, .{ .name = n, .description = d, .monitor = false });
}

/// A capture stream delivering mono f32 samples at the requested rate.
/// `read` blocks until the buffer is full. Use one thread per stream.
pub const Stream = struct {
    /// The microphone (AAudio), or null for "system" (`pipe`).
    stream: ?*AAudioStream,
    /// "system": the read end of OrielSystemAudio's pipe, and its request id.
    pipe: i32 = -1,
    system_id: i64 = 0,
    /// The requested rate, and the stream's actual rate and channels.
    rate: u32,
    device_rate: u32,
    channels: u32,
    resampler: Resampler = .{},

    /// Open `source` (a `Source.name`; null = the default input).
    pub fn open(source: ?[:0]const u8, app_name: [:0]const u8, rate: u32) !Stream {
        if (rate < 8000 or rate > 192000) return error.UnsupportedSampleRate;
        _ = app_name; // Android shows the app itself as the recorder
        if (source) |s| if (std.mem.eql(u8, s, "system")) return openSystem(rate);
        var builder: ?*AAudioStreamBuilder = null;
        var r = AAudio_createStreamBuilder(&builder);
        if (r != AAUDIO_OK or builder == null) return error.OpenFailed;
        defer _ = AAudioStreamBuilder_delete(builder.?);
        const b = builder.?;
        AAudioStreamBuilder_setDirection(b, AAUDIO_DIRECTION_INPUT);
        AAudioStreamBuilder_setFormat(b, AAUDIO_FORMAT_PCM_FLOAT);
        AAudioStreamBuilder_setChannelCount(b, 1);
        AAudioStreamBuilder_setSampleRate(b, @intCast(rate));
        AAudioStreamBuilder_setSharingMode(b, AAUDIO_SHARING_MODE_SHARED);
        AAudioStreamBuilder_setPerformanceMode(b, AAUDIO_PERFORMANCE_MODE_NONE);
        AAudioStreamBuilder_setInputPreset(b, AAUDIO_INPUT_PRESET_VOICE_RECOGNITION);
        if (source) |s| if (std.mem.startsWith(u8, s, "device:")) {
            const id = std.fmt.parseInt(i32, s["device:".len..], 10) catch return error.InvalidSource;
            AAudioStreamBuilder_setDeviceId(b, id);
        };
        var stream: ?*AAudioStream = null;
        r = AAudioStreamBuilder_openStream(b, &stream);
        if (r != AAUDIO_OK or stream == null) {
            log.warn("cannot open {s}: {s} (is the microphone permission granted?)", .{ source orelse "default input", resultText(r) });
            return error.OpenFailed;
        }
        errdefer _ = AAudioStream_close(stream.?);
        r = AAudioStream_requestStart(stream.?);
        if (r != AAUDIO_OK) {
            log.warn("cannot start capture: {s}", .{resultText(r)});
            return error.OpenFailed;
        }
        const device_rate: u32 = @intCast(@max(AAudioStream_getSampleRate(stream.?), 1));
        const channels: u32 = @intCast(@max(AAudioStream_getChannelCount(stream.?), 1));
        if (device_rate != rate) log.info("capturing at {d} Hz, resampling to {d} Hz", .{ device_rate, rate });
        return .{ .stream = stream.?, .rate = rate, .device_rate = device_rate, .channels = channels };
    }

    /// Fill `samples` completely (blocks).
    pub fn read(self: *Stream, samples: []f32) !void {
        if (self.pipe >= 0) return self.readPipe(samples);
        const gpa = heap.gpa;
        if (self.device_rate == self.rate and self.channels == 1) return self.readDevice(samples);
        try self.resampler.read(gpa, samples, self.device_rate, self.rate, self, readDevice);
    }

    /// Mono device-rate frames (downmixed when the device gave more channels).
    fn readDevice(self: *Stream, frames: []f32) !void {
        var interleaved: [4096]f32 = undefined;
        var got: usize = 0;
        while (got < frames.len) {
            const want = @min(frames.len - got, interleaved.len / self.channels);
            const n = AAudioStream_read(self.stream.?, &interleaved, @intCast(want), 1_000_000_000);
            if (n < 0) {
                log.warn("read failed: {s}", .{resultText(n)});
                return error.ReadFailed;
            }
            const count: usize = @intCast(n);
            for (0..count) |f| {
                var sum: f32 = 0;
                for (0..self.channels) |ch| sum += interleaved[f * self.channels + ch];
                frames[got + f] = sum / @as(f32, @floatFromInt(self.channels));
            }
            got += count;
        }
    }

    /// "system": the pipe's f32 samples (little-endian, the rate asked for).
    fn readPipe(self: *Stream, samples: []f32) !void {
        const bytes = std.mem.sliceAsBytes(samples);
        var got: usize = 0;
        while (got < bytes.len) {
            const n = std.c.read(self.pipe, bytes[got..].ptr, bytes.len - got);
            if (n < 0) {
                if (std.c._errno().* == @intFromEnum(std.c.E.INTR)) continue;
                return error.ReadFailed;
            }
            // The capture ended (closed, or the user stopped the projection).
            if (n == 0) return error.ReadFailed;
            got += @intCast(n);
        }
    }

    pub fn close(self: *Stream) void {
        if (self.pipe >= 0) {
            _ = std.c.close(self.pipe);
            self.pipe = -1;
            closeSystem(self.system_id);
            return;
        }
        _ = AAudioStream_requestStop(self.stream.?);
        _ = AAudioStream_close(self.stream.?);
        self.resampler.deinit(heap.gpa);
    }
};

// --------------------------------------------------------------- "system"

/// Requests waiting for OrielSystemAudio's answer (the consent dialog can
/// take a while): `id` 0 = free; `status` -1 until the answer is in.
const Slot = struct {
    id: std.atomic.Value(i64) = .init(0),
    fd: std.atomic.Value(i32) = .init(-1),
    status: std.atomic.Value(i32) = .init(-1),
};
var slots: [8]Slot = @splat(.{});
var next_id: std.atomic.Value(i64) = .init(1);

/// How long a request waits for the user's answer.
const consent_timeout_ms = 120_000;

fn openSystem(rate: u32) !Stream {
    const id = next_id.fetchAdd(1, .monotonic);
    const slot = for (&slots) |*sl| {
        if (sl.id.cmpxchgStrong(0, id, .acq_rel, .acquire) == null) break sl;
    } else return error.Busy;
    defer slot.id.store(0, .release);
    slot.fd.store(-1, .release);
    slot.status.store(-1, .release);

    const Call = struct {
        id: i64,
        rate: u32,
        fn run(c: *@This()) void {
            _ = runtime.call(.void, "systemAudioOpen", "(JI)V", .{ c.id, @as(i32, @intCast(c.rate)) });
        }
    };
    var call: Call = .{ .id = id, .rate = rate };
    ShellMod.runOnMainThread(Call, &call, Call.run) catch return error.OpenFailed;

    var waited: u32 = 0;
    while (slot.status.load(.acquire) < 0) : (waited += 20) {
        if (waited >= consent_timeout_ms) {
            log.warn("system audio: no answer to the capture request", .{});
            closeSystem(id);
            return error.Timeout;
        }
        sleepMs(20);
    }
    const status = slot.status.load(.acquire);
    const fd = slot.fd.load(.acquire);
    return switch (status) {
        0 => .{ .stream = null, .pipe = fd, .system_id = id, .rate = rate, .device_rate = rate, .channels = 1 },
        1 => error.Unsupported,
        2 => blk: {
            log.warn("system audio needs the microphone permission", .{});
            break :blk error.PermissionDenied;
        },
        3 => error.Denied,
        else => error.OpenFailed,
    };
}

fn closeSystem(id: i64) void {
    const Call = struct {
        id: i64,
        fn run(c: *@This()) void {
            _ = runtime.call(.void, "systemAudioClose", "(J)V", .{c.id});
        }
    };
    var call: Call = .{ .id = id };
    ShellMod.runOnMainThread(Call, &call, Call.run) catch {};
}

fn sleepMs(ms: u32) void {
    const ts: std.c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
    _ = std.c.nanosleep(&ts, null);
}

/// `NativeLib.onSystemAudio(id, fd, status)` (main thread): the answer to a
/// request; a late one (it timed out) has its pipe closed.
fn onSystemAudio(_: *jni.Env, _: jni.jclass, id: jni.jlong, fd: jni.jint, status: jni.jint) callconv(.c) void {
    for (&slots) |*sl| if (sl.id.load(.acquire) == id) {
        sl.fd.store(fd, .release);
        sl.status.store(status, .release);
        return;
    };
    if (fd >= 0) _ = std.c.close(fd);
}

comptime {
    @export(&onSystemAudio, .{ .name = "Java_dev_oriel_NativeLib_onSystemAudio" });
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const sources = try listSources(gpa);
    defer common.freeSources(gpa, sources);
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "AAudio: {d} sources (\"system\": AudioPlaybackCapture, with consent)", .{sources.len}),
    };
}
