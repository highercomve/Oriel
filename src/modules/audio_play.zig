//! Mono float32 playback through the vendored miniaudio device API.
//! The caller owns PCM until playback finishes or control-thread stop returns.
//! Lifecycle operations are serialized separately from the audio callback:
//! never wait for a device thread while holding its sample-state lock.

const std = @import("std");
pub const c = @cImport({
    @cInclude("miniaudio.h");
});

const Session = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io = undefined,
    gpa: std.mem.Allocator = undefined,
    device: ?*c.ma_device = null,
    samples: []const f32 = &.{},
    pos: usize = 0,
    total: usize = 0,
    stopped: bool = true,
};
pub var session: Session = .{};
var control_mutex: std.Io.Mutex = .init;
threadlocal var in_callback = false;

/// Set callbacks before start; change them only after control-thread stop.
/// Callbacks run on the audio thread. Queue lifecycle work to another thread.
pub var on_progress: ?*const fn (fraction: f64) void = null;
/// Natural completion, once per utterance; stop does not call this callback.
pub var on_done: ?*const fn () void = null;

const Progress = struct { fraction: f64, done: bool };
fn mix(output: []f32) ?Progress {
    @memset(output, 0);
    std.Io.Threaded.mutexLock(&session.mutex);
    defer std.Io.Threaded.mutexUnlock(&session.mutex);
    if (session.stopped or session.pos >= session.samples.len) return null;
    const take = @min(output.len, session.samples.len - session.pos);
    if (take == 0) return null;
    @memcpy(output[0..take], session.samples[session.pos..][0..take]);
    session.pos += take;
    return .{
        .fraction = @as(f64, @floatFromInt(session.pos)) / @as(f64, @floatFromInt(session.total)),
        .done = session.pos == session.samples.len,
    };
}

fn deviceDataCallback(_: ?*c.ma_device, output: ?*anyopaque, _: ?*const anyopaque, frames: c.ma_uint32) callconv(.c) void {
    const out: [*]f32 = @ptrCast(@alignCast(output orelse return));
    const progress = mix(out[0..frames]) orelse return;
    in_callback = true;
    defer in_callback = false;
    if (on_progress) |f| f(progress.fraction);
    if (progress.done) if (on_done) |f| f();
}

fn clearSamples() void {
    session.stopped = true;
    session.samples = &.{};
    session.pos = 0;
    session.total = 0;
}

/// Caller holds control_mutex. Detach while locked, then join without the
/// sample lock, allowing an in-flight callback to finish.
fn teardown() void {
    std.Io.Threaded.mutexLock(&session.mutex);
    const dev = session.device;
    session.device = null;
    clearSamples();
    std.Io.Threaded.mutexUnlock(&session.mutex);
    if (dev) |d| {
        c.ma_device_uninit(d);
        session.gpa.destroy(d);
    }
}

/// Control thread: stop and join callbacks before returning. In a callback
/// this only silences playback; call stop/shutdown on a control thread later
/// to release the device. Safe before the first start and after shutdown.
pub fn stop() void {
    if (in_callback) {
        std.Io.Threaded.mutexLock(&session.mutex);
        clearSamples();
        std.Io.Threaded.mutexUnlock(&session.mutex);
        return;
    }
    std.Io.Threaded.mutexLock(&control_mutex);
    defer std.Io.Threaded.mutexUnlock(&control_mutex);
    teardown();
}

/// Start mono f32 playback; PCM remains caller-owned. An empty buffer stops
/// the preceding utterance. start cannot run inside an audio callback.
pub fn start(io: std.Io, gpa: std.mem.Allocator, samples: []const f32, rate: u32) !void {
    return startWithContext(io, gpa, samples, rate, null);
}

fn startWithContext(io: std.Io, gpa: std.mem.Allocator, samples: []const f32, rate: u32, context: ?*c.ma_context) !void {
    if (in_callback) return error.CallbackThread;
    if (rate == 0) return error.InvalidSampleRate;
    std.Io.Threaded.mutexLock(&control_mutex);
    defer std.Io.Threaded.mutexUnlock(&control_mutex);
    teardown();
    if (samples.len == 0) return;
    const dev = try gpa.create(c.ma_device);
    errdefer gpa.destroy(dev);
    var config = c.ma_device_config_init(c.ma_device_type_playback);
    config.playback.format = c.ma_format_f32;
    config.playback.channels = 1;
    config.sampleRate = rate;
    config.dataCallback = deviceDataCallback;
    if (c.ma_device_init(context, &config, dev) != c.MA_SUCCESS) return error.DeviceInitFailed;
    errdefer c.ma_device_uninit(dev);
    std.Io.Threaded.mutexLock(&session.mutex);
    session.io = io;
    session.gpa = gpa;
    session.device = dev;
    session.samples = samples;
    session.pos = 0;
    session.total = samples.len;
    session.stopped = false;
    std.Io.Threaded.mutexUnlock(&session.mutex);
    errdefer {
        std.Io.Threaded.mutexLock(&session.mutex);
        session.device = null;
        clearSamples();
        std.Io.Threaded.mutexUnlock(&session.mutex);
    }
    if (c.ma_device_start(dev) != c.MA_SUCCESS) return error.DeviceStartFailed;
}

/// Safe to poll before initialization, while playing, and after stop.
pub fn finished() bool {
    std.Io.Threaded.mutexLock(&session.mutex);
    defer std.Io.Threaded.mutexUnlock(&session.mutex);
    return session.stopped or session.pos >= session.samples.len;
}
pub fn shutdown() void {
    stop();
}

test "playback fills the final buffer and EOF with silence" {
    stop();
    try std.testing.expect(finished());
    const samples = [_]f32{ 0.25, -0.5, 0.75 };
    session.samples = &samples;
    session.pos = 0;
    session.total = samples.len;
    session.stopped = false;
    defer stop();
    var output: [5]f32 = @splat(99);
    const p = mix(&output).?;
    try std.testing.expect(p.done and p.fraction == 1);
    try std.testing.expectEqualSlices(f32, &.{ 0.25, -0.5, 0.75, 0, 0 }, &output);
    @memset(&output, 99);
    try std.testing.expect(mix(&output) == null);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0 }, &output);
}

test "playback can repeatedly start and stop with a running null device" {
    var context: c.ma_context = undefined;
    var backend: c.ma_backend = c.ma_backend_null;
    try std.testing.expectEqual(c.MA_SUCCESS, c.ma_context_init(&backend, 1, null, &context));
    defer _ = c.ma_context_uninit(&context);
    defer stop();
    const samples: [2400]f32 = @splat(0);
    for (0..3) |_| {
        try startWithContext(std.testing.io, std.testing.allocator, &samples, 24_000, &context);
        try std.testing.io.sleep(.fromMilliseconds(20), .awake);
        stop();
        try std.testing.expect(finished());
    }
}
