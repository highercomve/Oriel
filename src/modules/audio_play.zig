//! The built-in voice's playback: the app plays the synthesis through the
//! vendored miniaudio (the C implementation itself compiles with llama.cpp's
//! mtmd, so this module only declares its API; the backend — PulseAudio,
//! ALSA, WASAPI, CoreAudio — is dlopen'd at runtime).
//!
//! One playing utterance at a time: `start` stops what's running. The audio
//! is mono f32 (Kokoro's output); progress and the finish go through
//! `on_progress`/`on_done`, on the device's own thread.

const std = @import("std");

pub const c = @cImport({
    @cInclude("miniaudio.h");
});

/// The engine (a gpa-owned device per utterance); its own thread only
/// touches the one global state through `mutex`.
const Session = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io = undefined,
    gpa: std.mem.Allocator = undefined,
    device: ?*c.ma_device = null,
    samples: []const f32 = &.{},
    pos: usize = 0,
    total: usize = 0,
    stopped: bool = false,
};

pub var session: Session = .{};

/// Played-so-far fraction (0–1), on the audio thread; may be null.
pub var on_progress: ?*const fn (fraction: f64) void = null;
/// The utterance finished (stopping or ending), on the audio thread; may be null.
pub var on_done: ?*const fn () void = null;

fn deviceDataCallback(dev: ?*c.ma_device, output: ?*anyopaque, input: ?*const anyopaque, frames: c.ma_uint32) callconv(.c) void {
    _ = dev;
    _ = input;
    const out: [*]f32 = @ptrCast(@alignCast(output orelse return));
    const n: usize = @intCast(frames);
    session.mutex.lockUncancelable(session.io);
    if (session.stopped or session.samples.len == 0 or session.pos >= session.samples.len) {
        session.mutex.unlock(session.io);
        return;
    }
    const remaining = session.samples[session.pos..];
    const take = @min(n, remaining.len);
    @memcpy(out[0..take], remaining[0..take]);
    @memset(out[take..n], 0);
    session.pos += take;
    const done = session.pos >= session.samples.len;
    const total = session.total;
    const pos = session.pos;
    session.mutex.unlock(session.io);

    if (on_progress) |f| {
        if (total > 0) f(@as(f64, @floatFromInt(pos)) / @as(f64, @floatFromInt(total)));
    }
    if (done) {
        if (on_done) |f| f();
    }
}

fn uninitDevice(dev: *c.ma_device, gpa: std.mem.Allocator) void {
    _ = c.ma_device_stop(dev);
    c.ma_device_uninit(dev);
    gpa.destroy(dev);
}

fn teardown(io: std.Io) void {
    if (session.device) |dev| {
        uninitDevice(dev, session.gpa);
        session.device = null;
    }
    session.stopped = true;
    session.samples = &.{};
    session.pos = 0;
    _ = io;
}

/// Stop the playing one (its device stops; the callback then goes silent).
pub fn stop() void {
    session.mutex.lockUncancelable(session.io);
    teardown(session.io);
    session.mutex.unlock(session.io);
}

/// Start playing `samples` (f32, `rate` Hz, mono). Stopping the previous
/// utterance frees its device. The gaf: samples must outlive the play
/// (the owner frees them after `on_done`).
pub fn start(io: std.Io, gpa: std.mem.Allocator, samples: []const f32, rate: u32) !void {
    const E = error{ DeviceInitFailed, DeviceStartFailed, OutOfMemory };

    session.mutex.lockUncancelable(io);
    teardown(session.io); // the running one (may be unset locals-wise)
    session.io = io;
    session.gpa = gpa;
    session.samples = samples;
    session.pos = 0;
    session.total = samples.len;
    session.stopped = false;

    const dev = gpa.create(c.ma_device) catch {
        session.mutex.unlock(io);
        return E.OutOfMemory;
    };
    var config = c.ma_device_config_init(c.ma_device_type_playback);
    config.playback.format = c.ma_format_f32;
    config.playback.channels = 1;
    config.sampleRate = rate;
    config.dataCallback = deviceDataCallback;
    if (c.ma_device_init(null, &config, dev) != c.MA_SUCCESS) {
        gpa.destroy(dev);
        session.stopped = true;
        session.mutex.unlock(io);
        return E.DeviceInitFailed;
    }
    session.device = dev;
    session.mutex.unlock(io);

    if (c.ma_device_start(dev) != c.MA_SUCCESS) {
        session.mutex.lockUncancelable(io);
        uninitDevice(dev, gpa);
        session.device = null;
        session.stopped = true;
        session.mutex.unlock(io);
        return E.DeviceStartFailed;
    }
}

/// For the app's exit paths.
pub fn shutdown() void {
    stop();
}
