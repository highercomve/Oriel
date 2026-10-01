//! Voice to text, tuned out of the box: live dictation from the microphone
//! and transcription of recordings, on whisper.cpp or the platform's own
//! recognizer.
//!
//! Engines (`Options.engine`):
//! - `.whisper`: whisper.cpp on every platform, ~99 languages, offline. The
//!   pipeline carries what makes it fast: Silero voice detection (silence
//!   never reaches whisper), whisper's window sized to the clip, a smaller
//!   "draft" model for the live text while the chosen model writes each
//!   phrase, and the CPU or the GPU per device and model: whichever
//!   `compare` found faster (remembered next to the models), else the GPU
//!   on desktops and the CPU on phones (ggml's ARM kernels beat mobile
//!   Vulkan drivers).
//! - `.system`: the platform's recognizer, no model to download. Android:
//!   SpeechRecognizer (Google's on-device model on a Pixel); iOS and macOS:
//!   Apple's Speech framework (SFSpeechRecognizer, on the device where it
//!   can). Elsewhere: `error.EngineUnavailable`.
//! - `.auto`: `.system` on Android and iOS when the recognizer runs on the
//!   device, else `.whisper`.
//!
//! Events (`Events`, for the app's own `Events` struct): "dictation:level"
//! while listening, "dictation:partial" (the phrase being spoken, "" once
//! final), "dictation:final" (a finished phrase), "dictation:download",
//! "dictation:compare", "dictation:error", "dictation:ended".
//!
//! The building blocks stay public for pipelines of your own:
//! `oriel.whisper` (contexts, transcribe, VAD), `oriel.audio_capture` and
//! `oriel.ggml_gpu` (whisper.Context.transcribe on samples of your own).
//!
//! Needs `-Dwhisper -Daudio_capture`, and the microphone permission
//! (`.permissions = .{ .microphone = "..." }` + `permissions.request`).

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("../oriel.zig");
const whisper = @import("whisper.zig");
const ggml_gpu = @import("ggml_gpu.zig");
const audio_capture = @import("audio_capture.zig");
const App = @import("../core/App.zig");
pub const wav = @import("dictation/wav.zig");
const model_download = @import("model_download.zig");

const is_android = builtin.abi.isAndroid();
const is_apple = builtin.os.tag == .ios or builtin.os.tag == .macos;
/// A platform recognizer to use (`.system`).
const has_system = is_android or is_apple;
/// Phones: `.auto` picks the system recognizer when it runs on the device.
const system_first = is_android or builtin.os.tag == .ios;
/// The platform recognizer, where there is one.
const system = if (is_android) @import("dictation/android.zig") else if (is_apple) @import("dictation/apple.zig") else struct {
    pub const name = "none";
    pub const Availability = struct { installed: bool, on_device: bool };
    pub fn available() Availability {
        return .{ .installed = false, .on_device = false };
    }
    pub fn isActive() bool {
        return false;
    }
};

const log = std.log.scoped(.dictation);

/// whisper.cpp's multilingual models, smallest first. q8_0: ggml repacks
/// it for ARM's dotprod/i8mm matmul kernels and it keeps whisper's
/// accuracy. `legacy`: files earlier Oriel versions downloaded, listed so
/// apps can offer to delete them.
pub const Model = struct { name: []const u8, file: []const u8, mb: u32, legacy: bool = false };
pub const models = [_]Model{
    .{ .name = "tiny", .file = "ggml-tiny-q8_0.bin", .mb = 42 },
    .{ .name = "base", .file = "ggml-base-q8_0.bin", .mb = 78 },
    .{ .name = "small", .file = "ggml-small-q8_0.bin", .mb = 252 },
    .{ .name = "tiny-q5_1", .file = "ggml-tiny-q5_1.bin", .mb = 31, .legacy = true },
    .{ .name = "base-q5_1", .file = "ggml-base-q5_1.bin", .mb = 57, .legacy = true },
    .{ .name = "small-q5_1", .file = "ggml-small-q5_1.bin", .mb = 181, .legacy = true },
    .{ .name = "tiny-f16", .file = "ggml-tiny.bin", .mb = 75, .legacy = true },
    .{ .name = "base-f16", .file = "ggml-base.bin", .mb = 142, .legacy = true },
    .{ .name = "small-f16", .file = "ggml-small.bin", .mb = 466, .legacy = true },
};
const url_base = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

pub const Engine = enum { auto, whisper, system };
pub const Backend = enum { auto, cpu, gpu };

pub const Options = struct {
    engine: Engine = .auto,
    /// A `models` name, or "auto": the largest one on the device.
    model: []const u8 = "auto",
    /// "auto", or a language: "en", "de", "es"... (whisper), a BCP 47 tag
    /// like "de-DE" also works for the system engine.
    language: []const u8 = "auto",
    /// Skip silence: phrases without speech never reach whisper, and final
    /// passes use voice detection (no made-up "Thank you." over noise).
    vad: bool = true,
    backend: Backend = .auto,
    /// Live text from the next smaller model on the device (whisper).
    draft: bool = true,
    /// Whisper: an `audio_capture` source id (`sources()`), e.g. the
    /// system's output for captions of what the computer plays; null: the
    /// default microphone.
    source: ?[]const u8 = null,
};

/// Where whisper can listen (`Options.source`): microphones, and on the
/// desktop the system's output (loopback). Allocated with `a`.
pub fn sources(a: std.mem.Allocator) ![]audio_capture.Source {
    return audio_capture.listSources(a);
}

pub const Events = struct {
    @"dictation:download": struct { model: []const u8, done_mb: u32, total_mb: u32 },
    /// While listening, ~10 times a second: seconds so far and the input level (0-1).
    @"dictation:level": struct { seconds: f32, level: f32 },
    /// The phrase being spoken, as heard so far ("" when it was finalized).
    @"dictation:partial": Partial,
    /// A finished phrase.
    @"dictation:final": Final,
    /// `compare`: one backend's run finished.
    @"dictation:compare": struct { backend: []const u8, transcribe_ms: u64 },
    /// The recognizer failed (e.g. "LanguageUnavailable"); listening stops.
    @"dictation:error": struct { message: []const u8 },
    /// Listening stopped on its own (the system engine after an error).
    @"dictation:ended": struct { engine: []const u8 },
};
pub const Partial = struct { text: []const u8 };
pub const Final = struct {
    text: []const u8,
    audio_s: f32,
    transcribe_ms: u64,
    backend: []const u8,
    /// False when the phrase went to the platform's servers (Apple speech
    /// without the language's on-device model).
    on_device: bool = true,
};

fn emit(comptime name: []const u8, payload: @FieldType(Events, name)) void {
    App.emit(name, payload);
}

const rate = whisper.sample_rate;
/// Recording limit: 5 minutes (19 MB of samples).
const max_seconds = 300;

var io: std.Io = undefined;
/// Long-lived allocations (models, samples, text): the app's allocator.
var gpa: std.mem.Allocator = undefined;
var models_dir: []const u8 = "";
var initialized = false;

/// Guards everything below except the recording state.
var mutex: std.Io.Mutex = .init;
var gpu_loaded = false;
var backend_name: []const u8 = "CPU";
var gpu_name: ?[]const u8 = null;
const Loaded = struct { ctx: whisper.Context, model: *const Model, gpu: bool };
var loaded: ?Loaded = null;
/// Live partials: the next smaller model on the device, several times
/// faster, so the text keeps up with speech; finals come from `loaded`.
var draft: ?Loaded = null;
var downloading: ?*const Model = null;
/// The engine of the current (or last) session.
var session_engine: Engine = .whisper;

/// Recording: the capture thread appends to `samples` under `samples_mutex`.
var recording: std.atomic.Value(bool) = .init(false);
var thread: ?std.Thread = null;
var samples_mutex: std.Io.Mutex = .init;
var samples: std.ArrayList(f32) = .empty;

/// Call once at startup. `dir`: where the models live (created when
/// needed; e.g. `store.dataDir` + "models", on Android the external files
/// directory so `adb push` can reach it); must outlive the app.
pub fn init(app_io: std.Io, app_gpa: std.mem.Allocator, dir: []const u8) void {
    io = app_io;
    gpa = app_gpa;
    models_dir = dir;
    initialized = true;
    whisper.silenceLogs();
}

/// Load the GPU backend once (a Vulkan instance and a self-test: not at
/// startup). Caller holds `mutex`.
fn ensureGpu() void {
    if (gpu_loaded) return;
    gpu_loaded = true;
    if (ggml_gpu.load(io) > 0) {
        backend_name = ggml_gpu.backendName() orelse "GPU";
        gpu_name = ggml_gpu.gpuName();
    }
    log.info("whisper backend: {s}{s}{s}", .{ backend_name, if (gpu_name != null) " on " else "", gpu_name orelse "" });
}

pub fn find(name: []const u8) !*const Model {
    for (&models) |*m| if (std.mem.eql(u8, m.name, name)) return m;
    return error.UnknownModel;
}

fn modelPath(a: std.mem.Allocator, m: *const Model) ![:0]u8 {
    return std.fs.path.joinZ(a, &.{ models_dir, m.file });
}

pub fn present(m: *const Model) bool {
    return model_download.present(io, models_dir, m.file);
}

/// "auto": the largest model on the device.
fn resolveModel(name: []const u8) !*const Model {
    if (!std.mem.eql(u8, name, "auto")) {
        const m = try find(name);
        if (m.legacy) return error.UnknownModel;
        return m;
    }
    var best: ?*const Model = null;
    for (&models) |*m| if (!m.legacy and present(m)) {
        best = m;
    };
    return best orelse error.NoModel;
}

// ---------------------------------------------------------------------------
// Status, download, delete

pub const ModelStatus = struct {
    name: []const u8,
    file: []const u8,
    mb: u32,
    present: bool,
    legacy: bool,
    /// What `compare` found faster on this device ("gpu"/"cpu"), if run.
    faster: ?[]const u8,
};
pub const Status = struct {
    /// The GPU backend ("Vulkan", "Metal", "CUDA"...) or "CPU", and the GPU's name.
    backend: []const u8,
    gpu: ?[]const u8,
    /// Engines on this platform: the system recognizer is installed / on-device.
    system: bool,
    system_on_device: bool,
    /// What `.auto` picks.
    auto_engine: Engine,
    models_dir: []const u8,
    models: [models.len]ModelStatus,
    loaded: ?[]const u8,
    downloading: ?[]const u8,
    recording: bool,
};

pub fn status() Status {
    const sys = system.available();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    ensureGpu();
    var list: [models.len]ModelStatus = undefined;
    for (&models, &list) |*m, *s| s.* = .{
        .name = m.name,
        .file = m.file,
        .mb = m.mb,
        .present = present(m),
        .legacy = m.legacy,
        .faster = if (preference(m)) |g| (if (g) "gpu" else "cpu") else null,
    };
    return .{
        .backend = backend_name,
        .gpu = gpu_name,
        .system = sys.installed,
        .system_on_device = sys.on_device,
        .auto_engine = if (system_first and sys.on_device) .system else .whisper,
        .models_dir = models_dir,
        .models = list,
        .loaded = if (loaded) |l| l.model.name else null,
        .downloading = if (downloading) |m| m.name else null,
        .recording = recording.load(.acquire) or system.isActive(),
    };
}

/// Fetch a model from Hugging Face into the models directory (to a .part
/// file, renamed when complete), emitting "dictation:download". Blocks:
/// call it from a worker (an async command).
pub fn download(name: []const u8) !void {
    const m = try find(name);
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (downloading != null) return error.AlreadyDownloading;
        downloading = m;
    }
    defer {
        mutex.lockUncancelable(io);
        downloading = null;
        mutex.unlock(io);
    }

    const url = try std.fmt.allocPrint(gpa, url_base ++ "{s}", .{m.file});
    defer gpa.free(url);
    try model_download.fetch(io, gpa, url, models_dir, m.file, m.mb, m, struct {
        fn f(model: *const Model, done_mb: u32, total_mb: u32) void {
            emit("dictation:download", .{ .model = model.name, .done_mb = done_mb, .total_mb = total_mb });
        }
    }.f);
}

/// Remove a model from the device (unloading it first), and a download
/// of it that stopped half way.
pub fn delete(name: []const u8) !void {
    const m = try find(name);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (downloading == m) return error.Downloading;
    const busy = recording.load(.acquire);
    if (loaded) |l| if (l.model == m) {
        if (busy) return error.Recording;
        l.ctx.deinit();
        loaded = null;
    };
    if (draft) |d| if (d.model == m) {
        if (busy) return error.Recording;
        dropDraft();
    };
    try model_download.remove(io, models_dir, m.file);
    log.info("deleted {s}", .{m.file});
}

/// Memory pressure (e.g. Android's trim-memory at 40, the app in the
/// background): free the models unless listening; the next session loads
/// them again. The last recording stays (`compare` reruns it). Returns at
/// once while a model is in use (safe to call on the main thread).
pub fn unloadIdle() void {
    if (recording.load(.acquire) or transcriber != null) return;
    if (!mutex.tryLock()) return;
    defer mutex.unlock(io);
    if (loaded) |l| {
        l.ctx.deinit();
        loaded = null;
        log.info("memory pressure: unloaded the whisper model", .{});
    }
    dropDraft();
}

// ---------------------------------------------------------------------------
// Models in memory, and the CPU/GPU choice

/// Load `m` into `slot` (on the GPU if asked and there is one), replacing
/// what was there. Caller holds `mutex`. Milliseconds spent, 0 if loaded.
fn loadInto(slot: *?Loaded, m: *const Model, use_gpu: bool) !u64 {
    ensureGpu();
    if (slot.*) |l| {
        if (l.model == m and l.gpu == use_gpu) return 0;
        l.ctx.deinit();
        slot.* = null;
    }
    const path = try modelPath(gpa, m);
    defer gpa.free(path);
    var params = whisper.contextDefaultParams();
    params.use_gpu = use_gpu;
    const t0 = std.Io.Clock.awake.now(io);
    const ctx = whisper.loadModel(path, params) catch |err| {
        log.err("cannot load {s}: {s}", .{ path, @errorName(err) });
        return if (err == error.CpuUnsupported) err else error.ModelNotFound;
    };
    slot.* = .{ .ctx = ctx, .model = m, .gpu = use_gpu };
    return elapsedMs(t0);
}

/// The draft model for `m`: the largest smaller one on the device.
fn draftFor(m: *const Model) ?*const Model {
    var best: ?*const Model = null;
    for (&models) |*d| {
        if (d == m) break; // `models` goes from small to large
        if (!d.legacy and present(d)) best = d;
    }
    return best;
}

fn dropDraft() void {
    if (draft) |d| d.ctx.deinit();
    draft = null;
}

/// Whether to use the GPU for `m`. Caller holds `mutex`.
fn useGpu(m: *const Model, b: Backend) bool {
    ensureGpu();
    if (gpu_name == null) return false;
    return switch (b) {
        .gpu => true,
        .cpu => false,
        // Measured on this device, else: phones' GPU drivers lose to ggml's
        // ARM kernels, desktop GPUs (CUDA, Metal, Vulkan) win.
        .auto => preference(m) orelse !(is_android or builtin.os.tag == .ios),
    };
}

/// `compare`'s verdicts, next to the models.
const prefs: model_download.Preferences = .{ .file = "backends.txt" };

fn preference(m: *const Model) ?bool {
    return prefs.get(io, models_dir, m.name);
}

fn savePreference(m: *const Model, gpu: bool) void {
    prefs.set(io, gpa, models_dir, m.name, gpu);
}

fn elapsedMs(since: std.Io.Timestamp) u64 {
    const ns = since.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    return @intCast(@divTrunc(@max(ns, 0), std.time.ns_per_ms));
}

// ---------------------------------------------------------------------------
// Live dictation: a capture thread fills `samples`; a transcriber thread
// re-transcribes the current phrase ("dictation:partial") and finalizes it
// after a pause or `max_phrase_s` ("dictation:final").

const step_ms = 600;
/// New audio needed before the next partial.
const min_new = rate * 4 / 10;
/// Quiet that ends a phrase.
const pause_samples = rate * 7 / 10;
const max_phrase_s = 8;
/// RMS below this (per 100 ms) is silence.
const silence_rms: f32 = 0.01;

var transcriber: ?std.Thread = null;
/// The session's options (copied at start: the transcriber outlives the command).
var session_lang_buf: [16]u8 = undefined;
var session_lang: [:0]const u8 = "auto";
var session_vad = true;
var session_source_buf: [512]u8 = undefined;
var session_source: ?[:0]const u8 = null;
/// The finalized text so far, and timing (transcriber thread; read after join).
var finals: std.ArrayList(u8) = .empty;
var stats: struct { updates: u32 = 0, total_ms: u64 = 0, last_final_ms: u64 = 0 } = .{};

pub const Started = struct {
    engine: Engine,
    /// Whisper: the model, its draft and where they run; the system
    /// engine: the recognizer ("Android").
    model: []const u8,
    draft: ?[]const u8,
    backend: []const u8,
    load_ms: u64,
};

fn pickEngine(e: Engine) !Engine {
    return switch (e) {
        .whisper => .whisper,
        .system => if (system.available().installed) .system else error.EngineUnavailable,
        .auto => if (system_first and system.available().on_device) .system else .whisper,
    };
}

/// Start listening. Blocks while models load: call it from a worker.
pub fn start(opts: Options) !Started {
    std.debug.assert(initialized);
    const engine = try pickEngine(opts.engine);
    if (engine == .system) {
        if (comptime !has_system) return error.EngineUnavailable;
        if (recording.load(.acquire) or transcriber != null) return error.AlreadyRecording;
        // Apple's engine takes its audio as buffers: test.wav can stand in
        // for the microphone there too (Android's recognizer opens it itself).
        if (is_apple) try system.start(io, opts.language, true, testAudio(), gpa) else try system.start(io, opts.language, true);
        session_engine = .system;
        return .{ .engine = .system, .model = system.name, .draft = null, .backend = system.name, .load_ms = 0 };
    }
    if (system.isActive()) return error.AlreadyRecording;
    const m = try resolveModel(opts.model);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (recording.load(.acquire) or transcriber != null) return error.AlreadyRecording;
    const gpu = useGpu(m, opts.backend);
    var load_ms = try loadInto(&loaded, m, gpu);
    const draft_model = if (opts.draft) draftFor(m) else null;
    if (draft_model) |d| {
        // The draft's own best processor: on a Pixel's Mali-G715, small ran
        // faster on the GPU and base on the CPU.
        load_ms += loadInto(&draft, d, useGpu(d, opts.backend)) catch |err| blk: {
            log.warn("no draft model: {s}", .{@errorName(err)});
            dropDraft();
            break :blk 0;
        };
    } else dropDraft();
    // A model freshly loaded on the GPU gets an untimed pass first, as in
    // compare(): Vulkan builds its pipelines on first use, which cost a
    // Pixel's first live update 11 s (the clip itself took 6).
    if (load_ms > 0 and gpu_name != null and (gpu or (if (draft) |d| d.gpu else false))) warmUp();
    samples_mutex.lockUncancelable(io);
    samples.clearRetainingCapacity();
    samples_mutex.unlock(io);
    finals.clearRetainingCapacity();
    stats = .{};
    const n = @min(opts.language.len, session_lang_buf.len - 1);
    @memcpy(session_lang_buf[0..n], opts.language[0..n]);
    session_lang_buf[n] = 0;
    session_lang = session_lang_buf[0..n :0];
    session_vad = opts.vad;
    session_source = if (opts.source) |src| blk: {
        if (src.len >= session_source_buf.len) return error.NameTooLong;
        @memcpy(session_source_buf[0..src.len], src);
        session_source_buf[src.len] = 0;
        break :blk session_source_buf[0..src.len :0];
    } else null;
    session_engine = .whisper;

    recording.store(true, .release);
    thread = std.Thread.spawn(.{}, record, .{}) catch |err| {
        recording.store(false, .release);
        return err;
    };
    transcriber = std.Thread.spawn(.{}, transcribeLoop, .{}) catch |err| {
        recording.store(false, .release);
        thread.?.join();
        thread = null;
        return err;
    };
    return .{
        .engine = .whisper,
        .model = m.name,
        .draft = if (draft) |d| d.model.name else null,
        .backend = if (gpu) backend_name else "CPU",
        .load_ms = load_ms,
    };
}

fn record() void {
    if (testAudio()) |audio| {
        defer gpa.free(audio);
        return feed(audio);
    }
    var stream = audio_capture.Stream.open(session_source, "dictation", rate) catch |err| {
        log.err("cannot open the microphone: {s}", .{@errorName(err)});
        emit("dictation:error", .{ .message = "MicrophoneUnavailable" });
        recording.store(false, .release);
        return;
    };
    defer stream.close();
    var buf: [rate / 10]f32 = undefined;
    while (recording.load(.acquire)) {
        stream.read(&buf) catch |err| {
            log.err("microphone: {s}", .{@errorName(err)});
            recording.store(false, .release);
            return;
        };
        const n = blk: {
            samples_mutex.lockUncancelable(io);
            defer samples_mutex.unlock(io);
            if (samples.items.len < max_seconds * rate) samples.appendSlice(gpa, &buf) catch {};
            break :blk samples.items.len;
        };
        emit("dictation:level", .{ .seconds = @as(f32, @floatFromInt(n)) / rate, .level = @min(1, rms(&buf) * 8) });
        if (n >= max_seconds * rate) recording.store(false, .release);
    }
}

/// Test hook (an emulator has no microphone): `test.wav` in the models
/// directory replaces the microphone while it is there.
fn testAudio() ?[]f32 {
    var dir = std.Io.Dir.cwd().openDir(io, models_dir, .{}) catch return null;
    defer dir.close(io);
    const data = dir.readFileAlloc(io, "test.wav", gpa, .limited(64 << 20)) catch return null;
    defer gpa.free(data);
    const out = wav.decode(gpa, data, rate) catch return null;
    log.info("test.wav instead of the microphone ({d:.1} s)", .{seconds(out)});
    return out;
}

/// `audio` at real-time pace, then silence, as the microphone would.
fn feed(audio: []const f32) void {
    var pos: usize = 0;
    const silence = [_]f32{0} ** (rate / 10);
    while (recording.load(.acquire)) {
        io.sleep(.fromMilliseconds(100), .awake) catch return;
        const part = if (pos < audio.len) audio[pos..@min(pos + rate / 10, audio.len)] else &silence;
        pos += part.len;
        const n = blk: {
            samples_mutex.lockUncancelable(io);
            defer samples_mutex.unlock(io);
            samples.appendSlice(gpa, part) catch {};
            break :blk samples.items.len;
        };
        emit("dictation:level", .{ .seconds = @as(f32, @floatFromInt(n)) / rate, .level = @min(1, rms(part) * 8) });
    }
}

fn rms(audio: []const f32) f32 {
    if (audio.len == 0) return 0;
    var sum: f32 = 0;
    for (audio) |x| sum += x * x;
    return @sqrt(sum / @as(f32, @floatFromInt(audio.len)));
}

/// Any 100 ms of `audio` above the silence level.
fn hasSpeech(audio: []const f32) bool {
    var i: usize = 0;
    while (i < audio.len) : (i += rate / 10) {
        if (rms(audio[i..@min(i + rate / 10, audio.len)]) > silence_rms) return true;
    }
    return false;
}

fn transcribeLoop() void {
    var phrase_start: usize = 0; // index in `samples` where the current phrase starts
    var last_end: usize = 0; // samples covered by the last update
    // New audio needed before the next partial: at least what the last
    // update took, so a slow device updates less often instead of falling
    // behind.
    var need: usize = min_new;
    var phrase: std.ArrayList(f32) = .empty; // a copy: capture keeps appending meanwhile
    defer phrase.deinit(gpa);
    while (true) {
        const live = recording.load(.acquire);
        if (live) io.sleep(.fromMilliseconds(step_ms), .awake) catch {};
        const end = blk: {
            samples_mutex.lockUncancelable(io);
            defer samples_mutex.unlock(io);
            phrase.clearRetainingCapacity();
            phrase.appendSlice(gpa, samples.items[@min(phrase_start, samples.items.len)..]) catch {};
            break :blk samples.items.len;
        };
        const audio = phrase.items;
        if (!recording.load(.acquire)) {
            // Stopped: the rest becomes the last phrase.
            if (audio.len >= rate / 4 and (!session_vad or hasSpeech(audio))) finish(audio);
            emit("dictation:partial", .{ .text = "" });
            return;
        }
        if (audio.len < rate / 2 or end - last_end < need) continue;
        const paused = audio.len > pause_samples and rms(audio[audio.len - pause_samples ..]) < silence_rms;
        if (session_vad and !hasSpeech(audio)) {
            // Only silence so far: nothing to transcribe; start over after a pause.
            if (paused) phrase_start = end;
            last_end = end;
            continue;
        }
        if (paused or audio.len >= max_phrase_s * rate) {
            finish(audio);
            emit("dictation:partial", .{ .text = "" });
            phrase_start = end;
        } else if (runLive(audio, .partial)) |r| {
            defer gpa.free(r.text);
            need = @max(min_new, r.transcribe_ms * rate / 1000);
            emit("dictation:partial", .{ .text = std.mem.trim(u8, r.text, " \t\r\n") });
        }
        last_end = end;
    }
}

fn finish(audio: []const f32) void {
    const r = runLive(audio, .final) orelse return;
    defer gpa.free(r.text);
    const text = std.mem.trim(u8, r.text, " \t\r\n");
    if (text.len == 0) return;
    if (finals.items.len > 0) finals.append(gpa, ' ') catch {};
    finals.appendSlice(gpa, text) catch {};
    stats.last_final_ms = r.transcribe_ms;
    emit("dictation:final", .{ .text = text, .audio_s = seconds(audio), .transcribe_ms = r.transcribe_ms, .backend = r.backend });
}

/// Transcribe on the transcriber thread; errors are logged (the loop goes on).
fn runLive(audio: []const f32, kind: enum { partial, final }) ?Run {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const r = transcribe(gpa, audio, session_lang, .{
        // Partials: the draft model, one segment and no voice detection, for speed.
        .vad = kind == .final and session_vad,
        .single_segment = kind == .partial,
        .draft = kind == .partial,
    }) catch |err| {
        log.err("transcription failed: {s}", .{@errorName(err)});
        return null;
    };
    if (kind == .partial) {
        stats.updates += 1;
        stats.total_ms += r.transcribe_ms;
    }
    return r;
}

pub const Run = struct {
    text: []const u8,
    backend: []const u8,
    transcribe_ms: u64,
};

pub const Result = struct {
    engine: Engine,
    model: []const u8,
    backend: []const u8,
    audio_s: f32,
    /// Everything said (the finals, joined).
    text: []const u8,
    /// The model that wrote the partials (null: `model` itself).
    draft: ?[]const u8,
    /// Live updates (partials), their mean time, and the time of the last
    /// final (the wait after stop).
    updates: u32,
    mean_ms: u64,
    last_ms: u64,
};

/// Stop listening: the last phrase is finalized, then the session's text
/// (allocated with `a`). Blocks until then: call it from a worker.
pub fn stop(a: std.mem.Allocator) !Result {
    if (has_system and session_engine == .system) {
        const r = try system.stop(a);
        return .{
            .engine = .system,
            .model = system.name,
            .backend = system.name,
            .audio_s = r.audio_s,
            .text = r.text,
            .draft = null,
            .updates = r.updates,
            .mean_ms = 0,
            .last_ms = 0,
        };
    }
    recording.store(false, .release);
    if (thread) |t| t.join();
    thread = null;
    if (transcriber) |t| t.join();
    transcriber = null;

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const l = loaded orelse return error.NoModel;
    samples_mutex.lockUncancelable(io);
    defer samples_mutex.unlock(io);
    return .{
        .engine = .whisper,
        .model = l.model.name,
        .backend = if (l.gpu and gpu_name != null) backend_name else "CPU",
        .audio_s = seconds(samples.items),
        .text = try a.dupe(u8, finals.items),
        .draft = if (draft) |d| d.model.name else null,
        .updates = stats.updates,
        .mean_ms = if (stats.updates > 0) stats.total_ms / stats.updates else 0,
        .last_ms = stats.last_final_ms,
    };
}

// ---------------------------------------------------------------------------
// Compare: the GPU against the CPU on this device

pub const Comparison = struct {
    model: []const u8,
    audio_s: f32,
    vad: bool,
    /// The GPU first (null without one), then the CPU.
    gpu: ?Run,
    cpu: Run,
    /// What `.auto` uses for this model from now on.
    faster: []const u8,
};

/// Compare times at most this much of the recording: the ratio is the
/// same as for the whole recording, in a fraction of the time.
const compare_max = 8 * rate;

/// Part of the last whisper recording (up to 8 s, from where the speech
/// starts) on the GPU and then on the CPU, same model and options:
/// "dictation:compare" reports each run as it ends, and the faster one is
/// remembered for `Backend.auto`. A freshly loaded GPU model gets one
/// untimed pass first: ggml's Vulkan backend builds its pipelines on first
/// use, which would count against it.
pub fn compare(a: std.mem.Allocator, opts: Options) !Comparison {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    const m = if (std.mem.eql(u8, opts.model, "auto")) (if (loaded) |l| l.model else try resolveModel("auto")) else try resolveModel(opts.model);
    if (recording.load(.acquire)) return error.Recording;
    samples_mutex.lockUncancelable(io);
    defer samples_mutex.unlock(io);
    if (samples.items.len < rate / 2) return error.NothingRecorded;
    const audio = clip(samples.items);
    const lang = try a.dupeZ(u8, opts.language);
    const t: TranscribeOptions = .{ .vad = opts.vad };

    ensureGpu();
    var gpu_run: ?Run = null;
    if (gpu_name != null) {
        if (try loadInto(&loaded, m, true) > 0) _ = try transcribe(a, audio[0..@min(audio.len, 2 * rate)], lang, t);
        gpu_run = try transcribe(a, audio, lang, t);
        emit("dictation:compare", .{ .backend = "GPU", .transcribe_ms = gpu_run.?.transcribe_ms });
    }
    _ = try loadInto(&loaded, m, false);
    const cpu_run = try transcribe(a, audio, lang, t);
    emit("dictation:compare", .{ .backend = "CPU", .transcribe_ms = cpu_run.transcribe_ms });
    // Phones: the GPU only when clearly faster. Their CPUs vary with heat
    // (a Pixel's CPU run took 2.5 s cool and 6.8 s warm on the same clip),
    // and Vulkan's first run per model builds its pipelines, a multi-second
    // stall that live dictation feels.
    const margin: u64 = if (is_android or builtin.os.tag == .ios) 130 else 100;
    const gpu_wins = if (gpu_run) |g| g.transcribe_ms * margin <= cpu_run.transcribe_ms * 100 else false;
    if (gpu_run != null) savePreference(m, gpu_wins);
    return .{ .model = m.name, .audio_s = seconds(audio), .vad = opts.vad, .gpu = gpu_run, .cpu = cpu_run, .faster = if (gpu_wins) "gpu" else "cpu" };
}

/// One untimed pass of 2 s of quiet noise through each model loaded on
/// the GPU (the chosen one and the draft). Caller holds `mutex`.
fn warmUp() void {
    const audio = gpa.alloc(f32, 2 * rate) catch return;
    defer gpa.free(audio);
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    for (audio) |*x| x.* = (prng.random().float(f32) - 0.5) * 0.002;
    const t0 = std.Io.Clock.awake.now(io);
    inline for (.{ false, true }) |use_draft| {
        const slot = if (use_draft) draft else loaded;
        if (slot != null and slot.?.gpu) {
            if (transcribe(gpa, audio, "en", .{ .vad = false, .single_segment = true, .draft = use_draft })) |r| gpa.free(r.text) else |_| {}
        }
    }
    log.info("GPU warm-up: {d} ms", .{elapsedMs(t0)});
}

/// Up to `compare_max` of `audio`, from shortly before the speech starts.
fn clip(audio: []const f32) []const f32 {
    var from: usize = 0;
    while (from + rate / 10 <= audio.len) : (from += rate / 10) {
        if (rms(audio[from .. from + rate / 10]) > silence_rms) break;
    }
    from -|= rate / 5;
    if (from + compare_max > audio.len) from = audio.len -| compare_max;
    return audio[from..@min(audio.len, from + compare_max)];
}

// ---------------------------------------------------------------------------
// Recordings: files and samples

pub const Transcript = struct {
    text: []const u8,
    model: []const u8,
    backend: []const u8,
    audio_s: f32,
    transcribe_ms: u64,
};

/// Transcribe a WAV file (see `wav`; other formats: decode them and use
/// `transcribeSamples`) with whisper. Blocks: call it from a worker.
pub fn transcribeFile(a: std.mem.Allocator, path: []const u8, opts: Options) !Transcript {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 30));
    defer gpa.free(data);
    const audio = try wav.decode(gpa, data, rate);
    defer gpa.free(audio);
    return transcribeSamples(a, audio, opts);
}

/// Transcribe mono 16 kHz samples (`whisper.sample_rate`) with whisper:
/// the chosen model (not the draft), voice detection per `opts.vad`.
pub fn transcribeSamples(a: std.mem.Allocator, audio: []const f32, opts: Options) !Transcript {
    if (audio.len == 0) return error.NothingRecorded;
    const m = try resolveModel(opts.model);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (recording.load(.acquire)) return error.Recording;
    _ = try loadInto(&loaded, m, useGpu(m, opts.backend));
    const lang = try a.dupeZ(u8, opts.language);
    defer a.free(lang);
    const r = try transcribe(a, audio, lang, .{ .vad = opts.vad });
    return .{
        .text = r.text,
        .model = m.name,
        .backend = r.backend,
        .audio_s = seconds(audio),
        .transcribe_ms = r.transcribe_ms,
    };
}

fn seconds(audio: []const f32) f32 {
    return @as(f32, @floatFromInt(audio.len)) / rate;
}

/// `draft`: with the draft model when one is loaded.
const TranscribeOptions = struct { vad: bool, single_segment: bool = false, draft: bool = false };

/// With the loaded model; the text is allocated with `a`. Caller holds
/// `mutex` (and whatever guards `audio`).
fn transcribe(a: std.mem.Allocator, audio: []const f32, lang: [:0]const u8, opts: TranscribeOptions) !Run {
    const l = (if (opts.draft) draft else null) orelse loaded orelse return error.NoModel;
    const vad_model = if (opts.vad) try vadPath() else null;
    const t0 = std.Io.Clock.awake.now(io);
    const text = try l.ctx.transcribe(a, audio, .{
        .language = lang,
        // The phone's big cores: more threads land on the little ones and
        // slow whisper down. (With the GPU, the CPU does little.)
        .threads = @intCast(@min(std.Thread.getCpuCount() catch 4, 4)),
        .vad_model = vad_model,
        .single_segment = opts.single_segment,
        // Sized to the clip instead of whisper's fixed 30 s window.
        .audio_ctx = whisper.audioCtxFor(audio.len),
    });
    const ms = elapsedMs(t0);
    const where = if (l.gpu and gpu_name != null) backend_name else "CPU";
    log.debug("{s} on {s}: {d:.1} s of audio in {d} ms", .{ l.model.name, where, seconds(audio), ms });
    return .{ .text = text, .backend = where, .transcribe_ms = ms };
}

/// Silero VAD (built into Oriel), written next to the models once.
var vad_path: ?[:0]u8 = null;
fn vadPath() ![:0]const u8 {
    if (vad_path) |p| return p;
    vad_path = try whisper.VadModel.install(io, gpa, models_dir);
    return vad_path.?;
}

test {
    _ = wav;
}
