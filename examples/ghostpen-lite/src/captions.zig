//! Live captions: audio capture -> whisper -> `caption` events.
//!
//! Whisper runs on the GPU when libggml-cuda.so sits next to the executable
//! (`zig build -Dcuda`), else on the CPU. One session at a time; each session
//! has a capture thread (100 ms reads into a buffer) and a transcriber thread
//! that re-transcribes the current utterance every `step_ms` (a partial
//! caption) and finalizes it after a pause or `max_utterance_s`.

const std = @import("std");
const oriel = @import("oriel");
const whisper = oriel.whisper;
const audio = oriel.audio_capture;

const log = std.log.scoped(.captions);

const rate = whisper.sample_rate;
const chunk = rate / 10; // 100 ms reads
const step_ms = 500;
const min_utterance = rate; // 1 s before the first partial
const max_utterance_s = 8;
const pause_samples = rate * 6 / 10; // 600 ms of quiet ends an utterance
const max_buffer = rate * 30; // drop old audio if transcription falls behind
const silence_rms: f32 = 0.008;

pub const Status = struct {
    running: bool,
    gpu: ?[]const u8,
    model: []const u8,
    model_loaded: bool,
};

var io: std.Io = undefined;
var model_path: []const u8 = "";
var gpu_name: ?[:0]const u8 = null;
/// Test hook: when set, sessions stream these samples in real time instead of
/// capturing (see `useWavForTests`).
var test_audio: ?[]const f32 = null;

/// Guards `model` and `session` (start/stop come from IPC worker threads).
var state_mutex: std.Io.Mutex = .init;
var model: ?whisper.Context = null;
var session: ?*Session = null;

/// Call once at startup (before any other function): loads the GPU backend
/// if present. `path` must outlive the app.
pub fn init(app_io: std.Io, path: []const u8) void {
    io = app_io;
    model_path = path;
    whisper.silenceLogs();
    if (oriel.ggml_gpu.load(io) > 0) gpu_name = oriel.ggml_gpu.gpuName();
    log.info("whisper backend: {s}", .{gpu_name orelse "CPU"});
}

/// Stream `samples` (owned by the caller, must outlive the app) instead of
/// the sound server: headless tests without touching the user's audio.
pub fn useWavForTests(samples: []const f32) void {
    test_audio = samples;
}

pub fn gpu() ?[:0]const u8 {
    return gpu_name;
}

pub fn status() Status {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    const running = if (session) |s| s.running.load(.acquire) else false;
    return .{ .running = running, .gpu = gpu_name, .model = model_path, .model_loaded = model != null };
}

/// Load the model (once). Caller holds `state_mutex`.
fn ensureModel(gpa: std.mem.Allocator) !whisper.Context {
    if (model) |m| return m;
    const path_z = try gpa.dupeZ(u8, model_path);
    defer gpa.free(path_z);
    const m = whisper.loadModel(path_z, whisper.contextDefaultParams()) catch |err| {
        log.err("cannot load model {s}: {s}", .{ model_path, @errorName(err) });
        return err;
    };
    model = m;
    return m;
}

/// Transcribe a whole buffer (the `--transcribe` CLI).
pub fn transcribeOnce(gpa: std.mem.Allocator, samples: []const f32, language: [:0]const u8) ![]u8 {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    const m = try ensureModel(gpa);
    return m.transcribe(gpa, samples, .{ .language = language });
}

pub fn start(source: ?[]const u8, language: []const u8) !void {
    const gpa = std.heap.smp_allocator;
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    if (session != null) return error.AlreadyRunning;
    const m = try ensureModel(gpa);

    const s = try gpa.create(Session);
    errdefer gpa.destroy(s);
    s.* = .{ .ctx = m };
    s.source = if (source) |src| try gpa.dupeZ(u8, src) else null;
    errdefer if (s.source) |src| gpa.free(src);
    s.language = try gpa.dupeZ(u8, language);
    errdefer gpa.free(s.language);

    s.capture_thread = try std.Thread.spawn(.{}, Session.captureLoop, .{s});
    s.transcribe_thread = std.Thread.spawn(.{}, Session.transcribeLoop, .{s}) catch |err| {
        s.running.store(false, .release);
        s.capture_thread.join();
        s.samples.deinit(gpa);
        return err;
    };
    session = s;
}

pub fn stop() void {
    state_mutex.lockUncancelable(io);
    const s = session orelse {
        state_mutex.unlock(io);
        return;
    };
    session = null;
    state_mutex.unlock(io);
    s.destroy();
}

/// Stop and free the model (app shutdown).
pub fn deinit() void {
    stop();
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    if (model) |m| m.deinit();
    model = null;
}

const Session = struct {
    ctx: whisper.Context,
    source: ?[:0]u8 = null,
    language: [:0]u8 = undefined,
    running: std.atomic.Value(bool) = .init(true),
    capture_thread: std.Thread = undefined,
    transcribe_thread: std.Thread = undefined,
    /// Audio of the current utterance (guarded by `mutex`).
    mutex: std.Io.Mutex = .init,
    samples: std.ArrayList(f32) = .empty,

    fn destroy(s: *Session) void {
        const gpa = std.heap.smp_allocator;
        s.running.store(false, .release);
        s.capture_thread.join();
        s.transcribe_thread.join();
        s.samples.deinit(gpa);
        if (s.source) |src| gpa.free(src);
        gpa.free(s.language);
        gpa.destroy(s);
    }

    /// Test hook: feed `samples` at real-time pace, then silence.
    fn feedLoop(s: *Session, samples: []const f32) void {
        var pos: usize = 0;
        const silence = [_]f32{0} ** chunk;
        while (s.running.load(.acquire)) {
            io.sleep(.fromMilliseconds(100), .awake) catch return;
            const end = @min(pos + chunk, samples.len);
            const part = if (pos < samples.len) samples[pos..end] else &silence;
            pos = end;
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            s.samples.appendSlice(std.heap.smp_allocator, part) catch continue;
        }
    }

    /// Owns the audio stream: opened, read and closed on this thread.
    fn captureLoop(s: *Session) void {
        if (test_audio) |samples| return feedLoop(s, samples);
        var stream = audio.Stream.open(s.source, "GhostPen Lite captions", rate) catch |err| {
            fail("cannot open the audio source", err);
            s.running.store(false, .release);
            return;
        };
        defer stream.close();
        var buf: [chunk]f32 = undefined;
        while (s.running.load(.acquire)) {
            stream.read(&buf) catch |err| {
                fail("audio capture stopped", err);
                s.running.store(false, .release);
                return;
            };
            s.mutex.lockUncancelable(io);
            defer s.mutex.unlock(io);
            s.samples.appendSlice(std.heap.smp_allocator, &buf) catch {
                log.warn("out of memory; dropping audio", .{});
                continue;
            };
            if (s.samples.items.len > max_buffer) {
                const drop = s.samples.items.len - max_buffer;
                s.samples.replaceRangeAssumeCapacity(0, drop, &.{});
            }
        }
    }

    fn transcribeLoop(s: *Session) void {
        const gpa = std.heap.smp_allocator;
        var last_len: usize = 0;
        while (s.running.load(.acquire)) {
            io.sleep(.fromMilliseconds(step_ms), .awake) catch return;

            // Snapshot the utterance so capture keeps going while whisper runs.
            s.mutex.lockUncancelable(io);
            const snapshot = gpa.dupe(f32, s.samples.items) catch {
                s.mutex.unlock(io);
                continue;
            };
            s.mutex.unlock(io);
            defer gpa.free(snapshot);

            if (snapshot.len < min_utterance or snapshot.len == last_len) continue;
            last_len = snapshot.len;

            const long = snapshot.len >= max_utterance_s * rate;
            const paused = rms(snapshot[snapshot.len - pause_samples ..]) < silence_rms;
            const final = long or paused;

            if (rms(snapshot) < silence_rms) {
                // Nothing but quiet: drop it (whisper invents text for silence).
                if (final) consume(s, snapshot.len);
                last_len = 0;
                continue;
            }

            const t0 = std.Io.Timestamp.now(io, .awake);
            const text = s.ctx.transcribe(gpa, snapshot, .{
                .language = s.language,
                .single_segment = !final,
            }) catch |err| {
                fail("transcription failed", err);
                continue;
            };
            defer gpa.free(text);
            const ms = @divTrunc(t0.durationTo(std.Io.Timestamp.now(io, .awake)).nanoseconds, std.time.ns_per_ms);

            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0 and !isNoise(trimmed)) {
                oriel.App.emit("caption", .{
                    .text = trimmed,
                    .final = final,
                    .audio_ms = snapshot.len * 1000 / rate,
                    .whisper_ms = @as(i64, @intCast(ms)),
                });
            }
            if (final) {
                consume(s, snapshot.len);
                last_len = 0;
            }
        }
    }

    /// Remove the first `n` samples (the finalized utterance).
    fn consume(s: *Session, n: usize) void {
        s.mutex.lockUncancelable(io);
        defer s.mutex.unlock(io);
        s.samples.replaceRangeAssumeCapacity(0, @min(n, s.samples.items.len), &.{});
    }
};

fn fail(what: []const u8, err: anyerror) void {
    log.err("{s}: {s}", .{ what, @errorName(err) });
    oriel.App.emit("captions_error", .{ .message = what, .error_name = @errorName(err) });
}

fn rms(samples: []const f32) f32 {
    if (samples.len == 0) return 0;
    var sum: f64 = 0;
    for (samples) |x| sum += @as(f64, x) * x;
    return @floatCast(@sqrt(sum / @as(f64, @floatFromInt(samples.len))));
}

/// Whisper's markers for non-speech ("[BLANK_AUDIO]", "(music)").
fn isNoise(text: []const u8) bool {
    return (text[0] == '[' and text[text.len - 1] == ']') or (text[0] == '(' and text[text.len - 1] == ')');
}

/// Decode a 16-bit PCM mono WAV at `whisper.sample_rate` into floats.
pub fn decodeWav(gpa: std.mem.Allocator, data: []const u8) ![]f32 {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.NotWav;
    var pos: usize = 12;
    var fmt_ok = false;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const body_start = pos + 8;
        const body_end = std.math.add(usize, body_start, size) catch return error.BadWav;
        if (body_end > data.len) return error.BadWav;
        const body = data[body_start..body_end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.BadWav;
            const format = std.mem.readInt(u16, body[0..2], .little);
            const channels = std.mem.readInt(u16, body[2..4], .little);
            const sr = std.mem.readInt(u32, body[4..8], .little);
            const bits = std.mem.readInt(u16, body[14..16], .little);
            if (format != 1 or channels != 1 or sr != rate or bits != 16) return error.UnsupportedWav;
            fmt_ok = true;
        } else if (std.mem.eql(u8, id, "data")) {
            if (!fmt_ok) return error.BadWav;
            const out = try gpa.alloc(f32, body.len / 2);
            for (out, 0..) |*o, i| {
                o.* = @as(f32, @floatFromInt(std.mem.readInt(i16, body[i * 2 ..][0..2], .little))) / 32768.0;
            }
            return out;
        }
        pos = body_end + (size & 1); // chunks are word-aligned
    }
    return error.BadWav;
}

test "decodeWav rejects non-wav and decodes pcm16" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotWav, decodeWav(gpa, "nope"));
    var wav: [44 + 4]u8 = undefined;
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 40, .little);
    @memcpy(wav[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], rate, .little);
    std.mem.writeInt(u32, wav[28..32], rate * 2, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 4, .little);
    std.mem.writeInt(i16, wav[44..46], 16384, .little);
    std.mem.writeInt(i16, wav[46..48], -32768, .little);
    const out = try decodeWav(gpa, &wav);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(f32, 0.5), out[0]);
    try std.testing.expectEqual(@as(f32, -1.0), out[1]);
}
