//! Mono float32 playback through the vendored miniaudio device API: one-shot
//! (`start`/`stop`/`finished`, caller-owned PCM) and streaming (`Stream`, a
//! device fed chunk by chunk through a bounded ring, as `tts` does).
//! The caller owns PCM until playback finishes or control-thread stop returns.
//! Lifecycle operations are serialized separately from the audio callback:
//! never wait for a device thread while holding its sample-state lock.

const std = @import("std");
pub const c = @cImport({
    // Zig defines _FORTIFY_SOURCE in optimized builds; translate-c can't
    // read the NDK's fortified headers (as in kokoro.zig, whisper.zig).
    @cUndef("_FORTIFY_SOURCE");
    if (@import("builtin").abi.isAndroid()) {
        // NDK 28's <sys/time.h> (via miniaudio's pthread/time includes)
        // puts a nullability qualifier on an array parameter
        // (`utimes(..., const struct timeval __times[_Nullable 2])`), which
        // translate-c rejects. The qualifiers only annotate pointers: drop
        // them for this import (no layout depends on them; miniaudio's own
        // C is compiled by the build with the real headers).
        @cDefine("_Nullable", "");
        @cDefine("_Nonnull", "");
        @cDefine("_Null_unspecified", "");
    }
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

/// Streaming playback: one device for a whole utterance, fed chunk by chunk
/// while it plays (synthesis of the next sentence overlaps playback of the
/// last), so there is no gap and no false "finished" between chunks.
///
///     const s = try Stream.init(io, gpa, rate);
///     defer s.deinit();          // joins the device: never in its callback
///     try s.start();
///     try s.append(chunk1);      // blocks while the ring is full
///     try s.append(chunk2);      // error.Cancelled once stopped
///     s.seal();                  // no more audio: finished() after the drain
///     while (!s.finished()) try io.sleep(.fromMilliseconds(20), .awake);
///
/// `stop` may come from any other thread (a Stop button) while a worker
/// appends or drains: output turns silent at once, `append` returns
/// `error.Cancelled`, `finished` is true. The device itself is released by
/// `deinit`, on the thread that owns the stream. Independent of the
/// one-shot `start`/`stop` above.
pub const Stream = struct {
    /// The ring: how far appended audio may run ahead of playback. A chunk
    /// longer than this is fed as the device makes room.
    pub const buffer_seconds = 30;

    /// Guards everything below `device`; held only briefly (by the audio
    /// callback too), never while waiting or joining the device.
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    gpa: std.mem.Allocator,
    rate: u32,
    ring: []f32,
    head: usize = 0,
    count: usize = 0,
    /// Samples the device has taken so far.
    played: u64 = 0,
    /// Silence the device got because the ring ran dry before `seal`
    /// (after the first sample): gaps the listener heard.
    starved: u64 = 0,
    stopped: bool = false,
    sealed: bool = false,
    /// Set by start, cleared by deinit (the owning thread only).
    device: ?*c.ma_device = null,

    /// A stream of mono f32 audio at `rate`. Heap-allocated: the device's
    /// callback holds its address.
    pub fn init(io: std.Io, gpa: std.mem.Allocator, rate: u32) !*Stream {
        if (rate == 0 or rate > 384_000) return error.InvalidSampleRate;
        const self = try gpa.create(Stream);
        errdefer gpa.destroy(self);
        self.* = .{ .io = io, .gpa = gpa, .rate = rate, .ring = try gpa.alloc(f32, @as(usize, rate) * buffer_seconds) };
        return self;
    }

    /// Open the default output device and start pulling from the ring
    /// (silence until audio is appended).
    pub fn start(self: *Stream) !void {
        return self.startWithContext(null);
    }

    /// `start` on a miniaudio context of the caller's (e.g. the null
    /// backend, for tests and headless runs); it must outlive the stream.
    pub fn startWithContext(self: *Stream, context: ?*c.ma_context) !void {
        if (in_callback) return error.CallbackThread;
        if (self.device != null) return error.AlreadyStarted;
        const dev = try self.gpa.create(c.ma_device);
        errdefer self.gpa.destroy(dev);
        var config = c.ma_device_config_init(c.ma_device_type_playback);
        config.playback.format = c.ma_format_f32;
        config.playback.channels = 1;
        config.sampleRate = self.rate;
        config.dataCallback = streamCallback;
        config.pUserData = self;
        if (c.ma_device_init(context, &config, dev) != c.MA_SUCCESS) return error.DeviceInitFailed;
        errdefer c.ma_device_uninit(dev);
        if (c.ma_device_start(dev) != c.MA_SUCCESS) return error.DeviceStartFailed;
        self.device = dev;
    }

    /// Queue `samples` (copied). Blocks while the ring is full (the device
    /// drains it in real time); `error.Cancelled` after `stop`.
    pub fn append(self: *Stream, samples: []const f32) !void {
        var offset: usize = 0;
        while (offset < samples.len) {
            const n = blk: {
                std.Io.Threaded.mutexLock(&self.mutex);
                defer std.Io.Threaded.mutexUnlock(&self.mutex);
                if (self.stopped) return error.Cancelled;
                if (self.sealed) return error.Sealed;
                break :blk self.write(samples[offset..]);
            };
            offset += n;
            if (n == 0) {
                if (self.device == null) return error.NotStarted; // nothing would ever drain it
                try self.io.sleep(.fromMilliseconds(10), .awake);
            }
        }
    }

    /// No more audio: `finished` turns true once the ring has drained.
    pub fn seal(self: *Stream) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        self.sealed = true;
    }

    /// Stopped, or sealed and everything handed to the device. (The
    /// device's own buffer, a period or two, is still sounding then.)
    pub fn finished(self: *Stream) bool {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return self.stopped or (self.sealed and self.count == 0);
    }

    /// Silence at once and drop what is queued; `append` fails from now on.
    /// Any thread, the audio callback included; returns at once.
    pub fn stop(self: *Stream) void {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        self.stopped = true;
        self.count = 0;
    }

    /// Seconds of audio the device has taken.
    pub fn playedSeconds(self: *Stream) f32 {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return @as(f32, @floatFromInt(self.played)) / @as(f32, @floatFromInt(self.rate));
    }

    /// Seconds of audio queued and not yet taken by the device.
    pub fn queuedSeconds(self: *Stream) f32 {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return @as(f32, @floatFromInt(self.count)) / @as(f32, @floatFromInt(self.rate));
    }

    /// Seconds of silence inserted mid-utterance because appends fell
    /// behind playback (0 when the feed kept up).
    pub fn starvedSeconds(self: *Stream) f32 {
        std.Io.Threaded.mutexLock(&self.mutex);
        defer std.Io.Threaded.mutexUnlock(&self.mutex);
        return @as(f32, @floatFromInt(self.starved)) / @as(f32, @floatFromInt(self.rate));
    }

    /// Stop, release the device (joining its callback) and free the stream.
    /// On the owning thread, after other threads are done calling `stop`.
    pub fn deinit(self: *Stream) void {
        std.debug.assert(!in_callback);
        self.stop();
        // Never under self.mutex: uninit waits for an in-flight callback.
        if (self.device) |dev| {
            c.ma_device_uninit(dev);
            self.gpa.destroy(dev);
            self.device = null;
        }
        const gpa = self.gpa;
        gpa.free(self.ring);
        gpa.destroy(self);
    }

    /// Copy what fits; caller holds `mutex`.
    fn write(self: *Stream, samples: []const f32) usize {
        const cap = self.ring.len;
        const n = @min(samples.len, cap - self.count);
        const tail = (self.head + self.count) % cap;
        const first = @min(n, cap - tail);
        @memcpy(self.ring[tail..][0..first], samples[0..first]);
        @memcpy(self.ring[0 .. n - first], samples[first..n]);
        self.count += n;
        return n;
    }

    /// Fill `output`, silence past the end; caller holds `mutex`.
    fn read(self: *Stream, output: []f32) usize {
        const cap = self.ring.len;
        const n = @min(output.len, self.count);
        const first = @min(n, cap - self.head);
        @memcpy(output[0..first], self.ring[self.head..][0..first]);
        @memcpy(output[first..n], self.ring[0 .. n - first]);
        @memset(output[n..], 0); // an underrun is silence, never stale memory
        if (!self.sealed and self.played + n > 0) self.starved += output.len - n;
        self.head = (self.head + n) % cap;
        self.count -= n;
        self.played += n;
        return n;
    }
};

fn streamCallback(dev: ?*c.ma_device, output: ?*anyopaque, _: ?*const anyopaque, frames: c.ma_uint32) callconv(.c) void {
    const out: [*]f32 = @ptrCast(@alignCast(output orelse return));
    const samples = out[0..frames];
    const self: *Stream = @ptrCast(@alignCast((dev orelse return @memset(samples, 0)).pUserData orelse return @memset(samples, 0)));
    in_callback = true;
    defer in_callback = false;
    std.Io.Threaded.mutexLock(&self.mutex);
    defer std.Io.Threaded.mutexUnlock(&self.mutex);
    if (self.stopped) @memset(samples, 0) else _ = self.read(samples);
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

test "stream ring wraps, keeps order and fills underruns with silence" {
    const s = try Stream.init(std.testing.io, std.testing.allocator, 1);
    defer s.deinit();
    // A 4-sample ring (rate 1 is 30 s of it: shrink it for the test).
    std.testing.allocator.free(s.ring);
    s.ring = try std.testing.allocator.alloc(f32, 4);
    try std.testing.expectEqual(@as(usize, 3), s.write(&.{ 1, 2, 3 }));
    var first: [2]f32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), s.read(&first));
    try std.testing.expectEqualSlices(f32, &.{ 1, 2 }, &first);
    try std.testing.expectEqual(@as(usize, 3), s.write(&.{ 4, 5, 6, 7 }));
    var rest: [6]f32 = @splat(99);
    try std.testing.expectEqual(@as(usize, 4), s.read(&rest));
    try std.testing.expectEqualSlices(f32, &.{ 3, 4, 5, 6, 0, 0 }, &rest);
    try std.testing.expectEqual(@as(u64, 6), s.played);
    try std.testing.expectEqual(@as(u64, 2), s.starved); // ran dry, unsealed: a gap
    s.seal();
    _ = s.read(&rest);
    try std.testing.expectEqual(@as(u64, 2), s.starved); // the end is no gap
}

test "a drained stream is not finished until sealed, and stop cancels appends" {
    const s = try Stream.init(std.testing.io, std.testing.allocator, 24_000);
    defer s.deinit();
    try s.append(&.{ 1, 2 });
    var output: [3]f32 = undefined;
    _ = s.read(&output);
    try std.testing.expect(!s.finished()); // between chunks: more may come
    s.seal();
    try std.testing.expect(s.finished());
    try std.testing.expectError(error.Sealed, s.append(&.{1}));
    s.stop();
    try std.testing.expectError(error.Cancelled, s.append(&.{1}));
}

test "a stream's append blocked on a full ring returns Cancelled when another thread stops it" {
    var context: c.ma_context = undefined;
    var backend: c.ma_backend = c.ma_backend_null;
    try std.testing.expectEqual(c.MA_SUCCESS, c.ma_context_init(&backend, 1, null, &context));
    defer _ = c.ma_context_uninit(&context);
    const s = try Stream.init(std.testing.io, std.testing.allocator, 8_000);
    defer s.deinit();
    try s.startWithContext(&context);
    // More than the ring holds: append waits for the device to drain.
    const big = try std.testing.allocator.alloc(f32, s.ring.len * 2);
    defer std.testing.allocator.free(big);
    @memset(big, 0);
    const stopper = try std.Thread.spawn(.{}, struct {
        fn f(st: *Stream) void {
            std.testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
            st.stop();
        }
    }.f, .{s});
    defer stopper.join();
    try std.testing.expectError(error.Cancelled, s.append(big));
    try std.testing.expect(s.finished());
}

test "a stream plays to the end on a null-backend context and can start and stop repeatedly" {
    var context: c.ma_context = undefined;
    var backend: c.ma_backend = c.ma_backend_null;
    try std.testing.expectEqual(c.MA_SUCCESS, c.ma_context_init(&backend, 1, null, &context));
    defer _ = c.ma_context_uninit(&context);
    // Drains in real time: 50 ms of audio, sealed, then finished.
    {
        const s = try Stream.init(std.testing.io, std.testing.allocator, 24_000);
        defer s.deinit();
        try s.startWithContext(&context);
        const samples: [1200]f32 = @splat(0.25);
        try s.append(&samples);
        s.seal();
        var waited: u32 = 0;
        while (!s.finished()) : (waited += 1) {
            if (waited > 200) return error.TestTimedOut;
            try std.testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        try std.testing.expect(s.playedSeconds() >= 0.05);
    }
    // Stopped mid-utterance, joined, again.
    for (0..3) |_| {
        const s = try Stream.init(std.testing.io, std.testing.allocator, 24_000);
        defer s.deinit();
        try s.startWithContext(&context);
        try std.testing.expectError(error.AlreadyStarted, s.startWithContext(&context));
        const samples: [2400]f32 = @splat(0.25);
        try s.append(&samples);
        try std.testing.io.sleep(.fromMilliseconds(20), .awake);
        s.stop();
        try std.testing.expect(s.finished());
    }
}
