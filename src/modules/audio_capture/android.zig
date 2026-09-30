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
//! Sources: "default" (the default microphone) and the input devices
//! `AudioManager.getDevices` reports, as "device:<id>". Other apps' audio
//! (system audio) needs MediaProjection consent and is not a source here.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const runtime = @import("../../platform/android/runtime.zig");
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
        fn run(self: *@This()) void {
            const e = runtime.mainEnv() orelse return;
            const arr = runtime.call(.object, "audioInputs", "()[B", .{}) orelse null;
            self.text = runtime.takeBytes(e, heap.gpa, arr);
        }
    };
    var ctx: Ctx = .{};
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
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
    stream: *AAudioStream,
    /// The requested rate, and the stream's actual rate and channels.
    rate: u32,
    device_rate: u32,
    channels: u32,
    /// Device-rate mono frames not consumed yet (resampling).
    pending: std.ArrayList(f32) = .empty,
    /// Position of the next output sample in `pending`, in device frames.
    pos: f64 = 0,

    /// Open `source` (a `Source.name`; null = the default input).
    pub fn open(source: ?[:0]const u8, app_name: [:0]const u8, rate: u32) !Stream {
        _ = app_name; // Android shows the app itself as the recorder
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
        const gpa = heap.gpa;
        if (self.device_rate == self.rate and self.channels == 1) return self.readDevice(samples);
        const step = @as(f64, @floatFromInt(self.device_rate)) / @as(f64, @floatFromInt(self.rate));
        var out: usize = 0;
        var chunk: [1024]f32 = undefined;
        while (out < samples.len) {
            // Enough device frames for the next output sample?
            const need: usize = @as(usize, @intFromFloat(@floor(self.pos))) + 2;
            if (self.pending.items.len < need) {
                try self.readDevice(&chunk);
                try self.pending.appendSlice(gpa, &chunk);
                continue;
            }
            const i: usize = @intFromFloat(@floor(self.pos));
            const frac: f32 = @floatCast(self.pos - @floor(self.pos));
            samples[out] = self.pending.items[i] * (1 - frac) + self.pending.items[i + 1] * frac;
            out += 1;
            self.pos += step;
            // Drop consumed frames now and then.
            const consumed: usize = @intFromFloat(@floor(self.pos));
            if (consumed > 4096) {
                const rest = self.pending.items.len - consumed;
                std.mem.copyForwards(f32, self.pending.items[0..rest], self.pending.items[consumed..]);
                self.pending.shrinkRetainingCapacity(rest);
                self.pos -= @floatFromInt(consumed);
            }
        }
    }

    /// Mono device-rate frames (downmixed when the device gave more channels).
    fn readDevice(self: *Stream, frames: []f32) !void {
        var interleaved: [4096]f32 = undefined;
        var got: usize = 0;
        while (got < frames.len) {
            const want = @min(frames.len - got, interleaved.len / self.channels);
            const n = AAudioStream_read(self.stream, &interleaved, @intCast(want), 1_000_000_000);
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

    pub fn close(self: *Stream) void {
        _ = AAudioStream_requestStop(self.stream);
        _ = AAudioStream_close(self.stream);
        self.pending.deinit(heap.gpa);
    }
};

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const sources = try listSources(gpa);
    defer common.freeSources(gpa, sources);
    return .{
        .module = "audio_capture",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "AAudio: {d} inputs (system audio needs MediaProjection)", .{sources.len}),
    };
}
