//! Text to speech, tuned out of the box: the Kokoro-82M counterpart of
//! `chat` and `dictation`, offline on every platform.
//!
//! - Models and voices: Kokoro 82M (q8_0 by default, f16) and a curated set
//!   of voice packs for English, Spanish, French, Portuguese, Italian,
//!   Japanese, Chinese and Hindi, downloaded from Hugging Face and checked
//!   against their SHA-256 (`download`, `delete`, `status`). Phones get the
//!   same catalog (the model is 135 MB, a voice 0.5 MB).
//! - Streaming: the text is cut into chunks (a short first one, then up to
//!   ~220 bytes at sentence, clause or word boundaries) and playback starts
//!   as soon as the first chunk is synthesized; the next chunk is made
//!   while the device plays. One device per utterance with a bounded ring
//!   (`audio_play.Stream`): no gaps and no false "finished" between chunks.
//! - The Kokoro context stays loaded between utterances: another voice or
//!   language reuses it, another model or backend reloads it, `unloadIdle`
//!   frees it under memory pressure.
//! - The GPU through ggml's backends where one loads (`ggml_gpu.load`,
//!   Kokoro's AUTO backend: Metal, CUDA, Vulkan; ~15x the CPU on an RTX
//!   4070), else the CPU with up to 8 threads (phones: their fast cores,
//!   `defaultThreads`); a model the GPU can't take falls back to the CPU.
//!   `warmUp` loads the model ahead of the first utterance.
//! - Markdown is read as prose (`Options.markdown`, `prepareText`), and
//!   `lang = "auto"` guesses the language (`guessLanguage`) and, with
//!   `voice = "auto"`, picks a voice of that language that is on the device.
//! - One utterance at a time: a new `speak` or a `stop` (from any thread)
//!   silences the current one at once and its worker returns promptly.
//! - `synthesize` makes the same speech without playing it: the PCM comes
//!   back in memory (an HTTP endpoint, a voice note, a file). It waits its
//!   turn behind a `speak` and never interrupts one.
//!
//! Events (`Events`, for the app's own `Events` struct): "tts:download"
//! and "tts:state" (phase "loading", "generating", "playing", "idle" or
//! "error").
//!
//! espeak-ng's phoneme data (kokoro.cpp phonemizes with it) is looked up
//! once, before the first engine init: `$KOKORO_ESPEAK_DATA_PATH`, then
//! `<models_dir>/espeak-ng-data`, then the copy bundled with the app, then
//! the system's (Linux packages, Homebrew). Without it `speak` returns
//! `error.EspeakDataMissing`.
//!
//! `Options.engine = .system` reads with the platform's own voices instead,
//! nothing to download: Android's TextToSpeech (`systemAvailable()` says
//! whether the device has an engine); elsewhere `error.EngineUnavailable`.
//! The same "tts:state" phases and `stop`; `voice` and `model` don't apply.
//!
//! The building blocks stay public: `oriel.kokoro` (contexts, synthesis),
//! `oriel.audio_play` (one-shot and streaming playback). Needs `-Dkokoro`.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const builtin = @import("builtin");
const kokoro = @import("kokoro.zig");
const audio_play = @import("audio_play.zig");
const ggml_gpu = @import("ggml_gpu.zig");
const App = @import("../core/App.zig");
const internal = @import("../core/internal.zig");
const model_download = @import("model_download.zig");
const lifecycle = @import("../core/lifecycle.zig");
const espeak_data = @import("tts/espeak_data.zig");
const text = @import("tts/text.zig");
const lang_guess = @import("tts/lang.zig");
pub const chunks = @import("tts/chunks.zig");

const log = std.log.scoped(.tts);
const system_voice = if (builtin.abi.isAndroid()) @import("tts/android.zig") else struct {};

const build_options = @import("build_options");
/// Cloned voices (Qwen3-TTS through `oriel.qwen3tts`) are built in:
/// `-Dllama -Dllama_mtmd` next to `-Dkokoro`.
pub const clones_available = build_options.llama and build_options.llama_mtmd;
const qwen3tts = if (clones_available) @import("qwen3tts.zig") else struct {};

// ---------------------------------------------------------------------------
// The catalog (simonfxr/kokoro.cpp-GGUF; SHA-256s from its manifest.json)

pub const Model = struct {
    id: []const u8,
    /// For people: "Kokoro 82M (Q8_0)".
    label: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,

    pub fn mb(self: *const Model) u32 {
        return @intCast((self.size + (1 << 19)) >> 20);
    }
};

pub const Voice = struct {
    /// Kokoro's voice id: "af_heart" (American female, Heart).
    id: []const u8,
    /// The espeak-ng language it reads: "en-us", "es", "fr"...
    lang: []const u8,
    label: []const u8,
    file: []const u8,
    size: u64 = 522_560,
    sha256: []const u8,
};

fn voice(comptime id: []const u8, comptime lang: []const u8, comptime label: []const u8, comptime sha256: []const u8) Voice {
    return .{ .id = id, .lang = lang, .label = label, .file = "kokoro-voice-" ++ id ++ ".gguf", .sha256 = sha256 };
}

/// The default first.
pub const models = [_]Model{
    .{ .id = "kokoro-82m-q8_0", .label = "Kokoro 82M (Q8_0)", .file = "kokoro-82m-q8_0.gguf", .size = 141_322_752, .sha256 = "61cc0186b3a761bdc31ba5d83b9228e4a72bf974cc5b94c281a5f450e683d2cc" },
    .{ .id = "kokoro-82m-f16", .label = "Kokoro 82M (F16)", .file = "kokoro-82m-f16.gguf", .size = 163_728_096, .sha256 = "597926de84f5550e1526ce0abde4e496209d464afc9274d8603d14f3c04d1f67" },
};

/// A curated set of Kokoro's 54 voice packs; the first of a language is
/// what `voice = "auto"` prefers for it.
pub const voices = [_]Voice{
    voice("af_heart", "en-us", "English (US) · Heart", "c2f44076dfb8f9c098a85d634f6d6b46b038f80e3afdf695ff3b90f6d9ef473f"),
    voice("af_bella", "en-us", "English (US) · Bella", "63d24d0e5d91cb6cf3bca294a3b8c0b4428aa54ac9b5de42e5ba07f6bd110ea8"),
    voice("af_nicole", "en-us", "English (US) · Nicole", "04bee67dd22b1eb687e50187c6851db96b6a1ebeee96daf5ec9448427a1bce42"),
    voice("am_michael", "en-us", "English (US) · Michael", "a2b71b49dd6320a2e235f8dfd176b197a2f76d5b32c1e3222efb08f117e78335"),
    voice("am_fenrir", "en-us", "English (US) · Fenrir", "3983d48599b5e219f581ea4fbc186d9181101d282cd2715d521775ba8a6ba882"),
    voice("bf_emma", "en-gb", "English (UK) · Emma", "78d519c9bfd34b5e15475169d0757cc77a8a3053d05dce65d3fcb77bf6743448"),
    voice("ef_dora", "es", "Español · Dora", "7fa2a87038c41301363e8e7d97bad2260c20da1a786ec22e0ea954d67dc4c412"),
    voice("em_alex", "es", "Español · Alex", "bf44594da819e77b4575d9912b8d4b2ab73d67a6a2b17031412a826b98db2b6f"),
    voice("ff_siwis", "fr", "Français · Siwis", "ebeb2847f5a56301af4d61fd31e5c568dfc05b4017694784e86eff9b17d08296"),
    voice("pf_dora", "pt-br", "Português · Dora", "a08314e467100dcb995d520ac0ccc52860d3b0484df7be1a51308a26127e72bd"),
    voice("if_sara", "it", "Italiano · Sara", "cfc7d3a2ab08df1791ea0e4518c66d0191e91376b1ae437adea826d9556b7b70"),
    voice("jf_alpha", "ja", "日本語 · Alpha", "482bf66e90ff6f42c0edf30ec4fb7f7d840347d4b76e8c3ea2bb59932c29f441"),
    voice("zf_xiaobei", "zh", "中文 · Xiaobei", "9d6ab39cba27274ace22170c47e1c4bafe556d95413fd2fe3b8d5be1f37c2fbb"),
    voice("hf_alpha", "hi", "हिन्दी · Alpha", "e1948214324b9af419ab10053caeb303752f4feee6e641d1dae9a04cdcd57036"),
};

const repo_url = "https://huggingface.co/simonfxr/kokoro.cpp-GGUF/resolve/main/";

pub fn findModel(id: []const u8) ?*const Model {
    for (&models) |*m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

pub fn findVoice(id: []const u8) ?*const Voice {
    for (&voices) |*v| if (std.mem.eql(u8, v.id, id)) return v;
    return null;
}

// ---------------------------------------------------------------------------
// Cloned voices: Qwen3-TTS (ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF) reads in
// the voice of a short reference recording (`clonePath`). Two files: the
// backbone and its mmproj (speaker encoder, code predictor, vocoder).

pub const CloneModel = struct {
    id: []const u8,
    label: []const u8,
    file: []const u8,
    size: u64,
    sha256: []const u8,
    mmproj_file: []const u8,
    mmproj_size: u64,
    mmproj_sha256: []const u8,

    pub fn mb(self: *const CloneModel) u32 {
        return @intCast((self.size + self.mmproj_size + (1 << 19)) >> 20);
    }
};

pub const clone_models = [_]CloneModel{.{
    .id = "qwen3-tts-1.7b-q8_0",
    .label = "Qwen3-TTS 1.7B (Q8_0)",
    .file = "Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf",
    .size = 1_847_874_400,
    .sha256 = "ac7931aeb2e7aad1a6ed6602d353a5679c9d096b18ce8204ac730a8408d572e1",
    .mmproj_file = "mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf",
    .mmproj_size = 446_422_912,
    .mmproj_sha256 = "6fd65188839bcd6ecc91b277ad471e22a0edfada4699a0fe82f1165c18cfcce2",
}};

const clone_repo_url = "https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/main/";

pub fn findCloneModel(id: []const u8) ?*const CloneModel {
    for (&clone_models) |*m| if (std.mem.eql(u8, m.id, id)) return m;
    return null;
}

/// Cloned voices live in `<models dir>/voices/`: one reference recording
/// each (10-15 s of one person speaking clearly), named after the voice
/// ("lucia.wav" is the voice "lucia"; .wav, .mp3 or .flac).
pub const clone_dir_name = "voices";
const clone_exts = [_][]const u8{ ".wav", ".mp3", ".flac" };

/// A cloned voice's id: 1-64 letters, digits, '-' or '_', and not "auto"
/// or a Kokoro voice's id (those always mean Kokoro).
pub fn validCloneId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64 or std.mem.eql(u8, id, "auto") or findVoice(id) != null) return false;
    for (id) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

// ---------------------------------------------------------------------------
// Options, events, state

pub const Backend = enum { auto, cpu };

/// Who reads: Kokoro (offline, the voices downloaded here), or the
/// platform's own voices (Android's TextToSpeech).
pub const EngineKind = enum { kokoro, system };

/// Whether `.system` works here: Android with a TextToSpeech engine.
pub fn systemAvailable() bool {
    if (comptime !builtin.abi.isAndroid()) return false;
    return system_voice.available();
}

pub const Options = struct {
    engine: EngineKind = .kokoro,
    /// A `models` id, or "auto": the default one if downloaded, else any.
    model: []const u8 = "auto",
    /// A `voices` id, or "auto": one for the language on the device.
    voice: []const u8 = "auto",
    /// An espeak-ng language ("en-us", "es", "fr"...) or "auto": guessed
    /// from the text (`guessLanguage`).
    lang: []const u8 = "auto",
    /// 1 = normal, 2 = twice as fast (0.25-4).
    speed: f32 = 1.0,
    /// Read Markdown as prose (`prepareText`).
    markdown: bool = true,
    /// `.auto`: the GPU when ggml has one (Vulkan, Metal, CUDA), else the CPU.
    backend: Backend = .auto,
    /// CPU threads; 0: chosen for the device (`defaultThreads`).
    threads: u16 = 0,
};

pub const Events = struct {
    /// A model or voice download progressed (`done_mb == total_mb` at the end).
    @"tts:download": struct { id: []const u8, done_mb: u32, total_mb: u32 },
    /// What the current utterance is doing.
    @"tts:state": State,
};
pub const State = struct {
    /// "loading", "generating", "playing", "idle" or "error".
    phase: []const u8,
    /// The error's name in "error", "Stopped"/"Finished" in "idle", else "".
    message: []const u8,
    /// The voice id ("" when not known yet).
    voice: []const u8,
};

const Phase = enum { loading, generating, playing, idle, @"error" };

fn emit(comptime name: []const u8, payload: @FieldType(Events, name)) void {
    if (builtin.is_test) return; // no window to reach
    internal.emit(name, payload);
}

/// Miniaudio context for playback (null: the default device). Tests and
/// headless runs point it at a null-backend context; it must outlive every
/// `speak`. Set it before speaking.
pub var audio_context: ?*audio_play.c.ma_context = null;

var io: std.Io = undefined;
var gpa: std.mem.Allocator = undefined;
var models_dir: []const u8 = "";
/// True from `init` to `deinit`; nothing touches `io` before.
var ever_init: std.atomic.Value(bool) = .init(false);

/// Guards the fields below up to `state_mutex` (briefly held; never while
/// taking `engine_mutex`).
var mutex: std.Io.Mutex = .init;
var gpu_loaded = false;
var backend_name: []const u8 = "CPU";
var gpu_name: ?[]const u8 = null;
var downloading: ?[]const u8 = null;
/// The espeak-ng data directory once found (gpa).
var espeak_dir: ?[]u8 = null;
/// What `engine` holds, for `status` (which must not wait for synthesis).
var loaded_model: ?*const Model = null;
var loaded_backend_buf: [32]u8 = undefined;
var loaded_backend: []const u8 = "";

/// Guards `phase` and orders "tts:state" events.
var state_mutex: std.Io.Mutex = .init;
var phase: Phase = .idle;

/// One utterance at a time; held by `speak` throughout.
var speak_mutex: std.Io.Mutex = .init;
var speaking: std.atomic.Value(bool) = .init(false);
/// Bumped by every `speak` and `stop`: an utterance whose generation is
/// no longer current stops at its next check and emits nothing more.
var generation: std.atomic.Value(u64) = .init(0);
/// The playing utterance's stream, for `stop` from other threads.
var stream_mutex: std.Io.Mutex = .init;
var active_stream: ?*audio_play.Stream = null;

/// The Kokoro context. Not thread-safe: every call on it holds this.
var engine_mutex: std.Io.Mutex = .init;
const Engine = struct {
    ctx: *kokoro.Context,
    model: *const Model,
    backend: Backend,
    threads: c_int,
    voice: ?*const Voice = null,
    lang_buf: [16]u8 = undefined,
    lang_len: usize = 0,
    backend_buf: [32]u8 = undefined,
    backend_len: usize = 0,
    /// Synthesis speed measured on this context (text bytes per second,
    /// 0 until the first chunk): sizes the next utterance's first chunk.
    bytes_per_s: f32 = 0,

    fn lang(self: *const Engine) []const u8 {
        return self.lang_buf[0..self.lang_len];
    }
    fn backendName(self: *const Engine) []const u8 {
        return self.backend_buf[0..self.backend_len];
    }
};
var engine: ?Engine = null;

/// The Qwen3-TTS context for cloned voices and the speaker it holds; under
/// `engine_mutex` like the Kokoro context. Loaded by the first cloned voice.
const CloneEngine = if (clones_available) struct {
    ctx: *qwen3tts.Context,
    model: *const CloneModel,
    speaker: ?qwen3tts.Speaker = null,
    /// The reference recording `speaker` was read from (gpa).
    speaker_path: ?[:0]u8 = null,
} else struct {};
var clone_engine: ?CloneEngine = null;
var llama_backend_ready = false;

/// Call once at startup. `dir`: where the models and voices live (created
/// when needed; e.g. `oriel.paths.appData` + "tts"); must outlive the app.
pub fn init(app_io: std.Io, app_gpa: std.mem.Allocator, dir: []const u8) void {
    io = app_io;
    gpa = app_gpa;
    models_dir = dir;
    ever_init.store(true, .release);
    subscribeLifecycle();
}

/// Load the GPU backends once (a Vulkan instance and a self-test: not at
/// startup). Caller holds `mutex`.
fn ensureGpu() void {
    if (gpu_loaded) return;
    gpu_loaded = true;
    if (ggml_gpu.load(io) > 0) {
        backend_name = ggml_gpu.backendName() orelse "GPU";
        gpu_name = ggml_gpu.gpuName();
    }
    log.info("tts backend: {s}{s}{s}", .{ backend_name, if (gpu_name != null) " on " else "", gpu_name orelse "" });
}

// ---------------------------------------------------------------------------
// Files

fn fileSize(file: []const u8) ?u64 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const path = std.fs.path.join(fba.allocator(), &.{ models_dir, file }) catch return null;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return st.size;
}

/// Downloaded and complete (the size the catalog says; the SHA-256 was
/// checked when it arrived).
fn presentFile(file: []const u8, size: u64) bool {
    return fileSize(file) == size;
}

pub fn modelPresent(m: *const Model) bool {
    return presentFile(m.file, m.size);
}

pub fn voicePresent(v: *const Voice) bool {
    return presentFile(v.file, v.size);
}

/// Whether a cloned voice can read `lang` (an espeak-ng or BCP 47 tag):
/// clones are built in and Qwen3-TTS reads that language.
pub fn cloneReads(lang: []const u8) bool {
    if (!clones_available) return false;
    return qwen3tts.languageOf(lang) != null;
}

pub fn cloneModelPresent(m: *const CloneModel) bool {
    return presentFile(m.file, m.size) and presentFile(m.mmproj_file, m.mmproj_size);
}

/// The reference recording of the cloned voice `id`, allocated with `a`;
/// null when there is none (or `id` is not a clone id).
pub fn clonePath(a: std.mem.Allocator, id: []const u8) !?[:0]u8 {
    if (!ever_init.load(.acquire) or !validCloneId(id)) return null;
    for (clone_exts) |ext| {
        const name = try std.mem.concat(a, u8, &.{ id, ext });
        defer a.free(name);
        const p = try std.fs.path.joinZ(a, &.{ models_dir, clone_dir_name, name });
        if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| return p else |_| a.free(p);
    }
    return null;
}

/// The cloned voices on the device (their ids, sorted), allocated with
/// `a`: free each id, then the slice.
pub fn cloneVoices(a: std.mem.Allocator) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |x| a.free(x);
        list.deinit(a);
    }
    if (!ever_init.load(.acquire)) return list.toOwnedSlice(a);
    const path = try std.fs.path.join(a, &.{ models_dir, clone_dir_name });
    defer a.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return list.toOwnedSlice(a),
        else => return err,
    };
    defer dir.close(io);
    var it = dir.iterate();
    entries: while (try it.next(io)) |e| {
        if (e.kind != .file and e.kind != .sym_link) continue;
        const ext = std.fs.path.extension(e.name);
        for (clone_exts) |x| {
            if (std.ascii.eqlIgnoreCase(ext, x)) break;
        } else continue;
        const id = e.name[0 .. e.name.len - ext.len];
        if (!validCloneId(id)) continue;
        for (list.items) |x| if (std.mem.eql(u8, x, id)) continue :entries; // lucia.wav + lucia.mp3
        try list.ensureUnusedCapacity(a, 1);
        list.appendAssumeCapacity(try a.dupe(u8, id));
    }
    std.mem.sort([]u8, list.items, {}, struct {
        fn lt(_: void, x: []u8, y: []u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return list.toOwnedSlice(a);
}

fn resolveCloneModel() !*const CloneModel {
    for (&clone_models) |*m| if (cloneModelPresent(m)) return m;
    return error.NoCloneModel;
}

fn resolveModel(id: []const u8) !*const Model {
    if (!std.mem.eql(u8, id, "auto")) {
        const m = findModel(id) orelse return error.UnknownModel;
        return if (modelPresent(m)) m else error.NoModel;
    }
    for (&models) |*m| if (modelPresent(m)) return m;
    return error.NoModel;
}

/// "auto": a voice of `lang` on the device, else one of the same language
/// family ("en-gb" for "en-us"), else any voice on the device.
fn resolveVoice(id: []const u8, lang: []const u8) !*const Voice {
    if (!std.mem.eql(u8, id, "auto")) {
        const v = findVoice(id) orelse return error.UnknownVoice;
        return if (voicePresent(v)) v else error.NoVoice;
    }
    for (&voices) |*v| if (std.mem.eql(u8, v.lang, lang) and voicePresent(v)) return v;
    const family = lang[0 .. std.mem.indexOfScalar(u8, lang, '-') orelse lang.len];
    for (&voices) |*v| if (std.mem.startsWith(u8, v.lang, family) and voicePresent(v)) return v;
    for (&voices) |*v| if (voicePresent(v)) return v;
    return error.NoVoice;
}

// ---------------------------------------------------------------------------
// espeak-ng data

fn hasPhondata(dir: []const u8) bool {
    if (dir.len == 0) return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const probe = std.fs.path.join(fba.allocator(), &.{ dir, "phondata" }) catch return false;
    _ = std.Io.Dir.cwd().statFile(io, probe, .{}) catch return false;
    return true;
}

const system_espeak_dirs: []const []const u8 = switch (builtin.os.tag) {
    .macos => &.{ "/opt/homebrew/share/espeak-ng-data", "/usr/local/share/espeak-ng-data", "/usr/share/espeak-ng-data" },
    .linux => if (builtin.abi.isAndroid()) &.{} else &.{
        "/usr/share/espeak-ng-data",
        "/usr/local/share/espeak-ng-data",
        "/usr/lib/x86_64-linux-gnu/espeak-ng-data",
        "/usr/lib/aarch64-linux-gnu/espeak-ng-data",
    },
    .freebsd, .openbsd, .netbsd => &.{"/usr/local/share/espeak-ng-data"},
    else => &.{},
};

fn envEspeakDir() ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const p = getenv(espeak_data.env_var) orelse return null;
        return std.mem.span(p);
    }
    const p = std.c.getenv(espeak_data.env_var) orelse return null;
    return std.mem.span(p);
}
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// The phoneme data directory (found once, then fixed: kokoro.cpp reads
/// the variable once). Caller holds `mutex`.
fn resolveEspeak() ?[]const u8 {
    if (espeak_dir) |d| return d;
    if (envEspeakDir()) |d| if (hasPhondata(d)) {
        espeak_dir = gpa.dupe(u8, d) catch return null;
        log.info("espeak-ng data: {s} (from ${s})", .{ d, espeak_data.env_var });
        return espeak_dir;
    };
    const found: ?[]u8 = blk: {
        if (std.fs.path.join(gpa, &.{ models_dir, espeak_data.dir_name })) |own| {
            if (hasPhondata(own)) break :blk own;
            gpa.free(own);
        } else |_| {}
        if (espeak_data.bundledDir(gpa, io)) |bundled| {
            if (hasPhondata(bundled)) break :blk bundled;
            gpa.free(bundled);
        }
        for (system_espeak_dirs) |d| if (hasPhondata(d)) break :blk gpa.dupe(u8, d) catch null;
        break :blk null;
    };
    const dir = found orelse return null;
    espeak_data.setEnv(gpa, dir) catch |err| {
        log.err("cannot set ${s}: {s}", .{ espeak_data.env_var, @errorName(err) });
        gpa.free(dir);
        return null;
    };
    log.info("espeak-ng data: {s}", .{dir});
    espeak_dir = dir;
    return dir;
}

// ---------------------------------------------------------------------------
// Status, download, delete

pub const ModelStatus = struct { id: []const u8, label: []const u8, mb: u32, present: bool };
/// The cloned voices themselves are files: `cloneVoices`.
pub const VoiceStatus = struct { id: []const u8, label: []const u8, lang: []const u8, present: bool };

pub const Status = struct {
    /// Where the loaded model runs ("CPU", "Vulkan0"...), else the GPU
    /// backend ggml found ("Vulkan", "Metal", "CUDA") or "CPU".
    backend: []const u8,
    gpu: ?[]const u8,
    models_dir: []const u8,
    /// The phoneme data directory, null when there is none (speak fails).
    espeak_data: ?[]const u8,
    models: [models.len]ModelStatus,
    voices: [voices.len]VoiceStatus,
    /// The models that read cloned voices (empty without `clones_available`).
    clone_models: [if (clones_available) clone_models.len else 0]ModelStatus,
    /// The model in memory.
    loaded: ?[]const u8,
    /// The model or voice being downloaded.
    downloading: ?[]const u8,
    speaking: bool,
    /// The current phase ("idle", "loading", "generating", "playing", "error").
    phase: []const u8,
};

pub fn status() Status {
    var s: Status = .{
        .backend = "CPU",
        .gpu = null,
        .models_dir = "",
        .espeak_data = null,
        .models = undefined,
        .voices = undefined,
        .clone_models = undefined,
        .loaded = null,
        .downloading = null,
        .speaking = false,
        .phase = "idle",
    };
    const ready = ever_init.load(.acquire);
    for (&models, &s.models) |*m, *ms| ms.* = .{ .id = m.id, .label = m.label, .mb = m.mb(), .present = ready and modelPresent(m) };
    for (&voices, &s.voices) |*v, *vs| vs.* = .{ .id = v.id, .label = v.label, .lang = v.lang, .present = ready and voicePresent(v) };
    if (comptime clones_available) for (&clone_models, &s.clone_models) |*m, *ms| {
        ms.* = .{ .id = m.id, .label = m.label, .mb = m.mb(), .present = ready and cloneModelPresent(m) };
    };
    if (!ready) return s;
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        ensureGpu();
        s.backend = if (loaded_model != null) loaded_backend else backend_name;
        s.gpu = gpu_name;
        s.models_dir = models_dir;
        s.espeak_data = resolveEspeak();
        s.loaded = if (loaded_model) |m| m.id else null;
        s.downloading = downloading;
    }
    s.speaking = speaking.load(.acquire);
    state_mutex.lockUncancelable(io);
    s.phase = @tagName(phase);
    state_mutex.unlock(io);
    return s;
}

const Item = struct { id: []const u8, file: []const u8, size: u64, sha256: []const u8, url_path: []const u8 };

fn findItem(id: []const u8) !Item {
    if (findModel(id)) |m| return .{ .id = m.id, .file = m.file, .size = m.size, .sha256 = m.sha256, .url_path = "" };
    if (findVoice(id)) |v| return .{ .id = v.id, .file = v.file, .size = v.size, .sha256 = v.sha256, .url_path = "voices/" };
    return error.UnknownModel;
}

/// Fetch a model or voice (an id from `models` or `voices`) from Hugging
/// Face into the models directory, check its SHA-256 (a mismatching file
/// is deleted: `error.ChecksumMismatch`), emitting "tts:download". Returns
/// at once when it is already there. Blocks: call it from a worker.
pub fn download(id: []const u8) !void {
    if (!ever_init.load(.acquire)) return error.NotInitialized;
    if (findCloneModel(id)) |cm| return downloadClone(cm);
    const item = try findItem(id);
    if (presentFile(item.file, item.size)) return;
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (downloading != null) return error.AlreadyDownloading;
        downloading = item.id;
    }
    defer {
        mutex.lockUncancelable(io);
        downloading = null;
        mutex.unlock(io);
    }
    const url = try std.fmt.allocPrint(gpa, repo_url ++ "{s}{s}", .{ item.url_path, item.file });
    defer gpa.free(url);
    const total_mb: u32 = @intCast(@max(1, (item.size + (1 << 19)) >> 20));
    try model_download.fetchVerified(io, gpa, url, models_dir, item.file, total_mb, item.sha256, item.id, struct {
        fn f(item_id: []const u8, done_mb: u32, total: u32) void {
            emit("tts:download", .{ .id = item_id, .done_mb = done_mb, .total_mb = total });
        }
    }.f);
    if (!presentFile(item.file, item.size)) return error.SizeMismatch;
    emit("tts:download", .{ .id = item.id, .done_mb = total_mb, .total_mb = total_mb });
}

/// A clone model's two files (backbone, then mmproj), "tts:download"
/// reporting each under the model's id.
fn downloadClone(cm: *const CloneModel) !void {
    if (comptime !clones_available) return error.EngineUnavailable;
    if (cloneModelPresent(cm)) return;
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (downloading != null) return error.AlreadyDownloading;
        downloading = cm.id;
    }
    defer {
        mutex.lockUncancelable(io);
        downloading = null;
        mutex.unlock(io);
    }
    const parts = [_]struct { file: []const u8, size: u64, sha256: []const u8 }{
        .{ .file = cm.file, .size = cm.size, .sha256 = cm.sha256 },
        .{ .file = cm.mmproj_file, .size = cm.mmproj_size, .sha256 = cm.mmproj_sha256 },
    };
    for (parts) |p| {
        if (presentFile(p.file, p.size)) continue;
        const url = try std.fmt.allocPrint(gpa, clone_repo_url ++ "{s}", .{p.file});
        defer gpa.free(url);
        const total_mb: u32 = @intCast(@max(1, (p.size + (1 << 19)) >> 20));
        try model_download.fetchVerified(io, gpa, url, models_dir, p.file, total_mb, p.sha256, cm.id, struct {
            fn f(item_id: []const u8, done_mb: u32, total: u32) void {
                emit("tts:download", .{ .id = item_id, .done_mb = done_mb, .total_mb = total });
            }
        }.f);
        if (!presentFile(p.file, p.size)) return error.SizeMismatch;
    }
    const mb_total = cm.mb();
    emit("tts:download", .{ .id = cm.id, .done_mb = mb_total, .total_mb = mb_total });
}

/// Remove a model or voice from the device (a model is unloaded first;
/// `error.Speaking` while it is in use), and a download of it that
/// stopped half way. A clone model's id removes both of its files; a
/// cloned voice's recording is the app's to delete (`clonePath`).
pub fn delete(id: []const u8) !void {
    if (!ever_init.load(.acquire)) return error.NotInitialized;
    if (findCloneModel(id)) |cm| {
        {
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            if (downloading) |d| if (std.mem.eql(u8, d, cm.id)) return error.Downloading;
        }
        {
            engine_mutex.lockUncancelable(io);
            defer engine_mutex.unlock(io);
            if (clone_engine != null) {
                if (speaking.load(.acquire)) return error.Speaking;
                freeCloneEngine();
            }
        }
        try model_download.remove(io, models_dir, cm.file);
        try model_download.remove(io, models_dir, cm.mmproj_file);
        log.info("deleted {s}", .{cm.id});
        return;
    }
    const item = try findItem(id);
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (downloading) |d| if (std.mem.eql(u8, d, item.id)) return error.Downloading;
    }
    {
        engine_mutex.lockUncancelable(io);
        defer engine_mutex.unlock(io);
        if (engine) |*e| {
            if (findModel(id) == e.model) {
                if (speaking.load(.acquire)) return error.Speaking;
                freeEngine();
            } else if (e.voice != null and std.mem.eql(u8, e.voice.?.id, id)) {
                // Reloaded (and found missing) by the next utterance.
                e.voice = null;
            }
        }
    }
    try model_download.remove(io, models_dir, item.file);
    log.info("deleted {s}", .{item.file});
}

/// When the module frees its voice model by itself (`unloadIdle` on an
/// `oriel.lifecycle` event): critical memory pressure by default. Set it any
/// time; `.{ .memory_pressure = null }` turns it off.
pub var unload_on: lifecycle.UnloadOn = .{};
var lifecycle_subscribed = false;

fn subscribeLifecycle() void {
    if (lifecycle_subscribed) return;
    lifecycle_subscribed = true;
    lifecycle.subscribe(&onLifecycle) catch log.warn("lifecycle: no room to unload on memory pressure", .{});
}

fn onLifecycle(event: lifecycle.Event) void {
    if (unload_on.wants(event)) unloadIdle();
}

/// Memory pressure (`unload_on`): free the Kokoro context unless speaking
/// (then it returns at once: safe on the main thread); the next utterance
/// loads it again.
pub fn unloadIdle() void {
    if (!ever_init.load(.acquire)) return;
    if (speaking.load(.acquire)) return;
    if (!engine_mutex.tryLock()) return;
    defer engine_mutex.unlock(io);
    // `speak` marks itself speaking before it takes the engine.
    if (speaking.load(.acquire) or (engine == null and clone_engine == null)) return;
    freeEngine();
    freeCloneEngine();
    log.info("memory pressure: unloaded the voice model", .{});
}

/// Caller holds `engine_mutex`.
fn freeEngine() void {
    if (engine) |e| kokoro.free(e.ctx);
    engine = null;
    mutex.lockUncancelable(io);
    loaded_model = null;
    mutex.unlock(io);
}

/// The Qwen3-TTS context and its speaker. Caller holds `engine_mutex`.
fn freeCloneEngine() void {
    if (comptime clones_available) if (clone_engine) |*e| {
        if (e.speaker) |s| s.deinit();
        if (e.speaker_path) |p| gpa.free(p);
        e.ctx.deinit();
    };
    clone_engine = null;
}

/// Release the Kokoro context, after the current utterance (stopped)
/// returns. internal.run calls it after draining its command pool. Safe before
/// `init` and twice.
pub fn deinit() void {
    if (!ever_init.load(.acquire)) return;
    stop();
    speak_mutex.lockUncancelable(io);
    defer speak_mutex.unlock(io);
    engine_mutex.lockUncancelable(io);
    freeEngine();
    freeCloneEngine();
    engine_mutex.unlock(io);
    mutex.lockUncancelable(io);
    // The variable stays set (kokoro.cpp read it); keep the name for a restart.
    if (espeak_dir) |d| gpa.free(d);
    espeak_dir = null;
    mutex.unlock(io);
    ever_init.store(false, .release);
}

// ---------------------------------------------------------------------------
// Text

/// `text` with its Markdown markup removed (headings, lists, emphasis, code
/// fences, link targets), allocated with `a`.
pub fn prepareText(a: std.mem.Allocator, input: []const u8) ![]u8 {
    return text.prepare(a, input);
}

/// The espeak-ng language `text` is most likely in: "en-us", "es", "fr",
/// "it", "pt-br", "ja", "zh", "hi" or "ru" (a static string; "en-us" when
/// unsure).
pub fn guessLanguage(input: []const u8) []const u8 {
    return lang_guess.guess(input);
}

// ---------------------------------------------------------------------------
// The engine

const is_phone = builtin.abi.isAndroid() or builtin.os.tag == .ios;

/// The CPU threads Kokoro uses unless `Options.threads` says otherwise: up
/// to 8 on desktops; on phones, their fast cores (`fastCores`), 2 to 4: a
/// thread on a little core holds every step back.
pub fn defaultThreads() c_int {
    const cpus = std.Thread.getCpuCount() catch 4;
    if (!is_phone) return @intCast(@min(cpus, 8));
    const fast = fastCores() orelse 4;
    return @intCast(std.math.clamp(@min(fast, cpus), 2, 4));
}

/// Linux and Android: how many CPUs are clearly faster than the slowest
/// cluster (top frequency over 1.15x the little cores'), e.g. 2 on a
/// Snapdragon 732G (2 x 2.3 + 6 x 1.8 GHz), 4 on a 1+3+4 SoC. Null when
/// all cores are alike or the frequencies can't be read.
fn fastCores() ?usize {
    if (builtin.os.tag != .linux) return null;
    var freqs: [64]u64 = undefined;
    var n: usize = 0;
    while (n < freqs.len) : (n += 1) {
        var path_buf: [80]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/sys/devices/system/cpu/cpu{d}/cpufreq/cpuinfo_max_freq", .{n}) catch break;
        var buf: [32]u8 = undefined;
        const data = std.Io.Dir.cwd().readFile(io, path, &buf) catch break;
        freqs[n] = std.fmt.parseInt(u64, std.mem.trim(u8, data, " \n"), 10) catch break;
    }
    return countFast(freqs[0..n]);
}

fn countFast(freqs: []const u64) ?usize {
    if (freqs.len == 0) return null;
    const slowest = std.mem.min(u64, freqs);
    var fast: usize = 0;
    for (freqs) |f| {
        if (f * 100 > slowest * 115) fast += 1;
    }
    return if (fast == 0) null else fast;
}

test countFast {
    try std.testing.expectEqual(@as(?usize, 2), countFast(&.{ 1804800, 1804800, 1804800, 1804800, 1804800, 1804800, 2304000, 2304000 }));
    try std.testing.expectEqual(@as(?usize, 4), countFast(&.{ 1785600, 1785600, 1785600, 1785600, 2419200, 2419200, 2419200, 2841600 }));
    try std.testing.expectEqual(@as(?usize, null), countFast(&.{ 5053377, 5053377 }));
    try std.testing.expectEqual(@as(?usize, null), countFast(&.{}));
}

/// The context for `m` on `backend`, voiced `v` in `lang` at `speed`
/// (loading or re-voicing only what changed). Caller holds `engine_mutex`.
/// Milliseconds spent loading the model, 0 if it was loaded.
fn ensureEngine(m: *const Model, backend: Backend, n_threads: c_int, v: *const Voice, lang: []const u8, speed: f32) !u32 {
    var load_ms: u32 = 0;
    if (engine) |e| if (e.model != m or e.backend != backend) freeEngine();
    if (engine == null) {
        const gpu = blk: {
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            ensureGpu();
            break :blk gpu_name != null;
        };
        const path = try std.fs.path.joinZ(gpa, &.{ models_dir, m.file });
        defer gpa.free(path);
        const t0 = std.Io.Clock.awake.now(io);
        var params = kokoro.defaultParams();
        params.n_threads = n_threads;
        params.verbosity = 0;
        params.backend = if (backend == .cpu) kokoro.c.KOKORO_BACKEND_CPU else kokoro.c.KOKORO_BACKEND_AUTO;
        const ctx = kokoro.init(path, params) orelse retry: {
            if (backend == .cpu) break :retry null;
            log.warn("cannot load {s} on the GPU ({s}): on the CPU", .{ m.file, kokoro.lastError() });
            params.backend = kokoro.c.KOKORO_BACKEND_CPU;
            break :retry kokoro.init(path, params);
        } orelse {
            log.err("cannot load {s}: {s}", .{ path, kokoro.lastError() });
            return error.ModelLoadFailed;
        };
        var e: Engine = .{ .ctx = ctx, .model = m, .backend = backend, .threads = n_threads };
        const name = kokoro.backendName(ctx);
        e.backend_len = @min(name.len, e.backend_buf.len);
        @memcpy(e.backend_buf[0..e.backend_len], name[0..e.backend_len]);
        if (backend == .auto and gpu and std.mem.eql(u8, name, "CPU"))
            log.warn("the GPU took no Kokoro backend (not CUDA, Vulkan or Metal, or it failed): on the CPU", .{});
        engine = e;
        load_ms = msSince(t0);
        log.info("loaded {s} on {s} in {d} ms ({d} threads)", .{ m.id, e.backendName(), load_ms, params.n_threads });
        mutex.lockUncancelable(io);
        loaded_model = m;
        loaded_backend_buf = e.backend_buf;
        loaded_backend = loaded_backend_buf[0..e.backend_len];
        mutex.unlock(io);
    }
    const e = &engine.?;
    if (e.threads != n_threads) {
        kokoro.setThreads(e.ctx, n_threads);
        e.threads = n_threads;
    }
    if (e.voice != v) {
        e.voice = null;
        const path = try std.fs.path.joinZ(gpa, &.{ models_dir, v.file });
        defer gpa.free(path);
        kokoro.loadVoice(e.ctx, path) catch {
            log.err("cannot load the voice {s}: {s}", .{ v.id, kokoro.lastError() });
            return error.VoiceFailed;
        };
        e.voice = v;
        e.lang_len = 0; // set it again for the new voice
    }
    if (!std.mem.eql(u8, e.lang(), lang)) {
        if (lang.len > e.lang_buf.len) return error.LanguageFailed;
        e.lang_len = 0;
        kokoro.setLanguage(e.ctx, lang) catch {
            log.err("cannot set the language {s}: {s}", .{ lang, kokoro.lastError() });
            return error.LanguageFailed;
        };
        @memcpy(e.lang_buf[0..lang.len], lang);
        e.lang_len = lang.len;
    }
    kokoro.setLengthScale(e.ctx, 1.0 / std.math.clamp(speed, 0.25, 4.0));
    return load_ms;
}

/// The first chunk's limit: about 1.5 s of synthesis at the speed measured
/// on this context, so a slow device (a phone's CPU: ~7 bytes/s) speaks
/// sooner with a shorter first chunk. Before any measurement: the shortest
/// on a phone's CPU, else `chunks.first_max`.
/// One chunk on the loaded engine. A GPU that cannot run it (out of memory
/// for the larger graph a longer chunk needs, e.g. with an LLM holding the
/// rest of the card) moves the engine to the CPU and retries the chunk
/// there instead of leaving it unsaid; `fell_back` is set then. The next
/// utterance (`.backend = .auto`) loads on the GPU again.
fn synthChunk(chunk: []const u8, m: *const Model, v: *const Voice, lang: []const u8, opts: Options, fell_back: *bool) !kokoro.Audio {
    engine_mutex.lockUncancelable(io);
    defer engine_mutex.unlock(io);
    const e = engine orelse return error.NoModel;
    if (kokoro.synthesize(e.ctx, chunk)) |audio| return audio else |err| {
        if (err != error.BackendFailed or std.mem.eql(u8, e.backendName(), "CPU")) return err;
    }
    log.warn("{s} could not synthesize a chunk (out of GPU memory?): on the CPU", .{e.backendName()});
    _ = try ensureEngine(m, .cpu, if (opts.threads > 0) opts.threads else defaultThreads(), v, lang, opts.speed);
    fell_back.* = true;
    return kokoro.synthesize(engine.?.ctx, chunk);
}

/// The Qwen3-TTS context for `m` holding the speaker read from
/// `speaker_path` (loading only what changed): on the GPU when ggml has one,
/// else (or when the GPU can't take it) the CPU. Caller holds
/// `engine_mutex`. Milliseconds spent loading the model, 0 if it was loaded.
fn ensureClone(m: *const CloneModel, speaker_path: [:0]const u8) !u32 {
    if (comptime clones_available) return ensureCloneLoaded(m, speaker_path) else return error.EngineUnavailable;
}

fn ensureCloneLoaded(m: *const CloneModel, speaker_path: [:0]const u8) !u32 {
    var load_ms: u32 = 0;
    if (clone_engine) |e| if (e.model != m) freeCloneEngine();
    if (clone_engine == null) {
        const gpu = blk: {
            mutex.lockUncancelable(io);
            defer mutex.unlock(io);
            ensureGpu();
            break :blk gpu_name != null;
        };
        if (!llama_backend_ready) {
            @import("llama.zig").initBackend();
            llama_backend_ready = true;
        }
        const mp = try std.fs.path.joinZ(gpa, &.{ models_dir, m.file });
        defer gpa.free(mp);
        const pp = try std.fs.path.joinZ(gpa, &.{ models_dir, m.mmproj_file });
        defer gpa.free(pp);
        const t0 = std.Io.Clock.awake.now(io);
        const params: qwen3tts.Params = .{ .gpu = gpu, .threads = defaultThreads() };
        const ctx = qwen3tts.Context.init(mp, pp, params) catch |err| retry: {
            if (!gpu or err == error.CpuUnsupported) return err;
            log.warn("cannot load {s} on the GPU ({s}): on the CPU", .{ m.id, @errorName(err) });
            var cpu = params;
            cpu.gpu = false;
            break :retry try qwen3tts.Context.init(mp, pp, cpu);
        };
        clone_engine = .{ .ctx = ctx, .model = m };
        load_ms = msSince(t0);
        log.info("loaded {s} on {s} in {d} ms", .{ m.id, ctx.backendName(), load_ms });
    }
    const e = &clone_engine.?;
    if (e.speaker_path == null or !std.mem.eql(u8, e.speaker_path.?, speaker_path)) {
        if (e.speaker) |s| s.deinit();
        e.speaker = null;
        if (e.speaker_path) |p| gpa.free(p);
        e.speaker_path = null;
        e.speaker = e.ctx.loadSpeaker(speaker_path) catch |err| {
            log.err("cannot read the voice recording {s}: {s}", .{ speaker_path, @errorName(err) });
            return err;
        };
        e.speaker_path = try gpa.dupeZ(u8, speaker_path);
    }
    return load_ms;
}

/// Where the clone engine runs. Caller holds `engine_mutex`.
fn cloneBackendName() []const u8 {
    if (comptime clones_available) return if (clone_engine) |e| e.ctx.backendName() else "" else return "";
}

/// One chunk's speech, from either engine: Kokoro's buffer is kokoro.cpp's,
/// a cloned voice's is `gpa`'s; `deinit` frees whichever it is.
const ChunkAudio = struct {
    samples: []f32,
    rate: u32,
    from_kokoro: bool,

    fn deinit(self: ChunkAudio) void {
        if (self.from_kokoro) kokoro.freePcm(self.samples) else gpa.free(self.samples);
    }
};

fn synthAny(chunk: []const u8, p: *const Prepared, opts: Options, fell_back: *bool) !ChunkAudio {
    if (p.engine == .clone) {
        if (comptime clones_available) {
            engine_mutex.lockUncancelable(io);
            defer engine_mutex.unlock(io);
            const e = &(clone_engine orelse return error.NoModel);
            const sp: ?*const qwen3tts.Speaker = if (e.speaker) |*s| s else null;
            const samples = try e.ctx.synthesize(gpa, chunk, sp, .{ .lang = p.lang });
            return .{ .samples = samples, .rate = qwen3tts.sample_rate, .from_kokoro = false };
        } else return error.EngineUnavailable;
    }
    const audio = try synthChunk(chunk, p.model, p.voice, p.lang, opts, fell_back);
    return .{ .samples = audio.samples, .rate = audio.rate, .from_kokoro = true };
}

fn lastErrorOf(p: *const Prepared) []const u8 {
    return if (p.engine == .kokoro) kokoro.lastError() else "";
}

fn firstLimit(e: *const Engine) usize {
    if (e.bytes_per_s > 0) return @intFromFloat(std.math.clamp(e.bytes_per_s * 1.5, chunks.min, chunks.first_max));
    const on_cpu = std.mem.eql(u8, e.backendName(), "CPU");
    return if (is_phone and on_cpu) chunks.min else chunks.first_max;
}

/// Load the model and voice `speak` would use with `opts` without speaking,
/// so the first utterance starts sooner: call it when a reading screen
/// opens. `lang = "auto"`: English's voice (else any voice on the device)
/// in its own language. On a GPU it also synthesizes a word (the GPU
/// compiles its kernels on first use). Returns at once while speaking.
/// Blocks for the load (0.2 s on a desktop, ~1 s on a phone): call it from
/// a worker. `speak` waits for a warm-up in progress.
pub fn warmUp(opts: Options) !void {
    if (!ever_init.load(.acquire)) return error.NotInitialized;
    if (speaking.load(.acquire)) return;
    const auto_lang = std.mem.eql(u8, opts.lang, "auto");
    const m = try resolveModel(opts.model);
    const v = try resolveVoice(opts.voice, if (auto_lang) "en-us" else opts.lang);
    {
        mutex.lockUncancelable(io);
        defer mutex.unlock(io);
        if (resolveEspeak() == null) return error.EspeakDataMissing;
    }
    engine_mutex.lockUncancelable(io);
    defer engine_mutex.unlock(io);
    if (speaking.load(.acquire)) return;
    const n_threads = if (opts.threads > 0) opts.threads else defaultThreads();
    const was_loaded = engine != null;
    const load_ms = try ensureEngine(m, opts.backend, n_threads, v, if (auto_lang) v.lang else opts.lang, opts.speed);
    const e = &engine.?;
    if (was_loaded and load_ms == 0) return;
    if (std.mem.eql(u8, e.backendName(), "CPU")) return;
    const t0 = std.Io.Clock.awake.now(io);
    const audio = kokoro.synthesize(e.ctx, "Hello.") catch |err| {
        log.warn("warm-up synthesis failed ({s}): {s}", .{ @errorName(err), kokoro.lastError() });
        return;
    };
    kokoro.freePcm(audio.samples);
    log.info("warmed up on {s} in {d} ms", .{ e.backendName(), msSince(t0) });
}

fn msSince(t0: std.Io.Timestamp) u32 {
    const ns = t0.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds();
    return std.math.lossyCast(u32, @divTrunc(@max(ns, 0), std.time.ns_per_ms));
}

// ---------------------------------------------------------------------------
// Speaking

/// Set the phase and emit "tts:state", unless `gen` (an utterance's
/// generation) is no longer current: a replaced or stopped utterance never
/// overwrites a newer one's state.
fn setState(gen: ?u64, p: Phase, message: []const u8, voice_id: []const u8) void {
    state_mutex.lockUncancelable(io);
    defer state_mutex.unlock(io);
    if (gen) |g| if (generation.load(.acquire) != g) return;
    phase = p;
    emit("tts:state", .{ .phase = @tagName(p), .message = message, .voice = voice_id });
}

fn current(gen: u64) bool {
    return generation.load(.acquire) == gen;
}

/// Publish `s` for `stop`, unless the utterance was already replaced.
fn register(s: *audio_play.Stream, gen: u64) bool {
    stream_mutex.lockUncancelable(io);
    defer stream_mutex.unlock(io);
    // `stop` bumps the generation before it looks here: either it sees
    // `s`, or this sees its generation.
    if (!current(gen)) return false;
    active_stream = s;
    return true;
}

fn unregister(s: *audio_play.Stream) void {
    stream_mutex.lockUncancelable(io);
    defer stream_mutex.unlock(io);
    if (active_stream == s) active_stream = null;
}

/// Append to the utterance's stream; false once it was stopped.
fn feed(s: *audio_play.Stream, samples: []const f32) !bool {
    s.append(samples) catch |err| {
        if (err == error.Cancelled) return false;
        return err;
    };
    return true;
}

fn silence() void {
    stream_mutex.lockUncancelable(io);
    defer stream_mutex.unlock(io);
    if (active_stream) |s| s.stop();
}

pub const Result = struct {
    /// The voice and language it was read with, and where Kokoro ran.
    voice: []const u8,
    lang: []const u8,
    backend: []const u8,
    /// Chunks synthesized.
    chunks: u32,
    /// From the call to the first sound (model loading included).
    first_audio_ms: u32,
    /// Synthesis time of all chunks, and the model's load time (0 if it
    /// was loaded).
    synth_ms: u32,
    load_ms: u32,
    /// Audio synthesized, in seconds (synth_ms / 1000 / audio_s: the
    /// real-time factor).
    audio_s: f32,
    /// Silence heard mid-utterance because synthesis fell behind playback.
    gap_ms: u32 = 0,
    /// A newer `speak` or a `stop` cut it short.
    stopped: bool,
};

/// What `speak` and `synthesize` settle before they touch the engine.
const Prepared = struct {
    /// The text to read, Markdown removed when asked.
    readable: []const u8,
    /// Kokoro: an espeak-ng language (static, or `opts.lang`); a cloned
    /// voice: Qwen3-TTS's ("en", "es"...).
    lang: []const u8,
    engine: enum { kokoro, clone } = .kokoro,
    /// Kokoro's model and voice (`.kokoro` only).
    model: *const Model = undefined,
    voice: *const Voice = undefined,
    /// A cloned voice: its id, recording (in the arena) and model (`.clone` only).
    clone_id: []const u8 = "",
    clone_path: [:0]const u8 = "",
    clone_model: *const CloneModel = undefined,

    fn voiceId(self: *const Prepared) []const u8 {
        return if (self.engine == .clone) self.clone_id else self.voice.id;
    }
};

/// Markdown to prose, the language, the model and voice on the device, and
/// the phoneme data. `readable` is allocated with `arena`. A voice that is
/// not Kokoro's but has a recording in the voices directory is cloned
/// (Qwen3-TTS): `error.NoCloneModel` until its model is downloaded,
/// `error.UnsupportedLanguage` for a language it doesn't read.
fn prepare(arena: std.mem.Allocator, input: []const u8, opts: Options) !Prepared {
    const readable = if (opts.markdown) try text.prepare(arena, input) else input;
    const lang = if (std.mem.eql(u8, opts.lang, "auto")) lang_guess.guess(readable) else opts.lang;
    if (try clonePath(arena, opts.voice)) |path| {
        if (comptime clones_available) {
            const cm = try resolveCloneModel();
            const ql = qwen3tts.languageOf(lang) orelse return error.UnsupportedLanguage;
            return .{ .readable = readable, .lang = ql, .engine = .clone, .clone_id = opts.voice, .clone_path = path, .clone_model = cm };
        } else return error.EngineUnavailable;
    }
    const m = try resolveModel(opts.model);
    const v = try resolveVoice(opts.voice, lang);
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (resolveEspeak() == null) return error.EspeakDataMissing;
    return .{ .readable = readable, .lang = lang, .model = m, .voice = v };
}

/// Read `input` aloud and return when it has been played (or stopped). A
/// running utterance is stopped first. The strings in the result are
/// allocated with `a`. Blocks: call it from a worker (an async command).
pub fn speak(a: std.mem.Allocator, input: []const u8, opts: Options) !Result {
    if (opts.engine == .system) return speakSystem(a, input, opts);
    if (!ever_init.load(.acquire)) return error.NotInitialized;
    const t0 = std.Io.Clock.awake.now(io);
    // Cut the current utterance short now; it returns at its next check.
    const gen = generation.fetchAdd(1, .acq_rel) + 1;
    silence();
    speak_mutex.lockUncancelable(io);
    defer speak_mutex.unlock(io);
    var result: Result = .{ .voice = "", .lang = "", .backend = "", .chunks = 0, .first_audio_ms = 0, .synth_ms = 0, .load_ms = 0, .audio_s = 0, .stopped = true };
    if (!current(gen)) return result; // replaced while waiting its turn
    speaking.store(true, .release);
    defer speaking.store(false, .release);
    errdefer |err| setState(gen, .@"error", @errorName(err), "");

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prepared = try prepare(arena, input, opts);
    const readable = prepared.readable;
    const lang = prepared.lang;
    const vid = prepared.voiceId();
    result.voice = try a.dupe(u8, vid);
    result.lang = try a.dupe(u8, lang);
    setState(gen, .loading, "", vid);
    var bytes_per_s: f32 = 0; // synthesis speed, text bytes per second
    var limit: usize = chunks.first_max;
    {
        engine_mutex.lockUncancelable(io);
        defer engine_mutex.unlock(io);
        if (prepared.engine == .clone) {
            result.load_ms = try ensureClone(prepared.clone_model, prepared.clone_path);
            result.backend = try a.dupe(u8, cloneBackendName());
        } else {
            result.load_ms = try ensureEngine(prepared.model, opts.backend, if (opts.threads > 0) opts.threads else defaultThreads(), prepared.voice, lang, opts.speed);
            result.backend = try a.dupe(u8, engine.?.backendName());
            bytes_per_s = engine.?.bytes_per_s;
            limit = firstLimit(&engine.?);
        }
    }
    setState(gen, .generating, "", vid);

    var stream: ?*audio_play.Stream = null;
    defer if (stream) |s| {
        unregister(s);
        s.deinit(); // joins the device; no lock held here
    };
    var samples: u64 = 0;
    var rate: u32 = kokoro.sample_rate;
    var stopped = false;
    var failed: u32 = 0;
    // Chunk sizes follow the audio queued ahead: each chunk must be ready
    // before the device runs out, so a slow CPU starts small and grows
    // (a short heading first must not be followed by a long paragraph),
    // a GPU goes to the largest chunks at once.
    var pos: usize = 0;
    while (chunks.next(readable, &pos, limit)) |chunk| {
        if (!current(gen)) {
            stopped = true;
            break;
        }
        const ts = std.Io.Clock.awake.now(io);
        var fell_back = false;
        const synth = synthAny(chunk, &prepared, opts, &fell_back);
        if (fell_back) {
            const cpu = try a.dupe(u8, "CPU");
            a.free(result.backend);
            result.backend = cpu;
            bytes_per_s = 0; // the GPU's speed would size the CPU's chunks
        }
        const chunk_ms = msSince(ts);
        result.synth_ms += chunk_ms;
        // A chunk with nothing to say ("…", "—") is skipped, not fatal.
        const audio = synth catch |err| {
            log.warn("chunk not synthesized ({s}): {s}", .{ @errorName(err), lastErrorOf(&prepared) });
            failed += 1;
            continue;
        };
        defer audio.deinit();
        result.chunks += 1;
        const speed: f32 = @as(f32, @floatFromInt(chunk.len)) * 1000 / @as(f32, @floatFromInt(@max(chunk_ms, 1)));
        bytes_per_s = if (bytes_per_s == 0) speed else (bytes_per_s + speed) / 2;
        if (prepared.engine == .kokoro) {
            engine_mutex.lockUncancelable(io);
            defer engine_mutex.unlock(io);
            if (engine) |*e| e.bytes_per_s = bytes_per_s;
        }
        log.debug("chunk {d}: {d} bytes, {d:.1} s of audio in {d} ms", .{ result.chunks, chunk.len, @as(f32, @floatFromInt(audio.samples.len)) / @as(f32, @floatFromInt(audio.rate)), chunk_ms });
        samples += audio.samples.len;
        rate = audio.rate;
        if (!current(gen)) {
            stopped = true;
            break;
        }
        if (stream == null) {
            const s = try audio_play.Stream.init(io, gpa, audio.rate);
            if (!register(s, gen)) {
                s.deinit();
                stopped = true;
                break;
            }
            stream = s;
            try s.startWithContext(audio_context);
        }
        // Blocks while the ring is full; the device plays meanwhile.
        if (!try feed(stream.?, audio.samples)) {
            stopped = true;
            break;
        }
        if (result.chunks == 1) {
            result.first_audio_ms = msSince(t0);
            log.info("first audio in {d} ms", .{result.first_audio_ms});
            setState(gen, .playing, "", vid);
        }
        // What can be made in 70% of the time the queued audio lasts.
        limit = @intFromFloat(@min(@as(f32, chunks.max), stream.?.queuedSeconds() * bytes_per_s * 0.7));
    }
    if (result.chunks == 0 and failed > 0 and !stopped) return error.SynthesisFailed;
    result.audio_s = @as(f32, @floatFromInt(samples)) / @as(f32, @floatFromInt(rate));
    if (stream) |s| {
        if (!stopped) {
            s.seal();
            while (!s.finished()) try io.sleep(.fromMilliseconds(20), .awake);
            stopped = !current(gen);
            // The device's own buffer still sounds after the ring drained.
            if (!stopped) io.sleep(.fromMilliseconds(100), .awake) catch {};
        }
        result.gap_ms = @intFromFloat(s.starvedSeconds() * 1000);
    }
    result.stopped = stopped or !current(gen);
    setState(gen, .idle, if (result.stopped) "Stopped" else "Finished", vid);
    log.info("{d} chunks, {d:.1} s of audio in {d} ms on {s}, {d} ms of gaps", .{ result.chunks, result.audio_s, result.synth_ms, result.backend, result.gap_ms });
    return result;
}

/// Speech as samples in memory, from `synthesize`.
pub const Audio = struct {
    /// Mono, -1 to 1, allocated with the allocator given to `synthesize`.
    samples: []f32,
    /// Samples per second (24 000 for Kokoro).
    rate: u32,
    /// The voice and language it was read with, and where Kokoro ran
    /// (allocated with the same allocator).
    voice: []const u8,
    lang: []const u8,
    backend: []const u8,
    /// Chunks synthesized.
    chunks: u32,
    /// Synthesis time of all chunks, and the model's load time (0 if it
    /// was loaded).
    synth_ms: u32,
    load_ms: u32,
    /// Audio synthesized, in seconds.
    audio_s: f32,

    /// Free everything with the allocator `synthesize` was given.
    pub fn deinit(self: Audio, a: std.mem.Allocator) void {
        a.free(self.samples);
        a.free(self.voice);
        a.free(self.lang);
        a.free(self.backend);
    }
};

/// Read `input` like `speak` (same `Options`, text preparation, voice and
/// language choice) but return the speech instead of playing it: nothing
/// reaches the speakers and no "tts:state" is emitted. A `speak` in
/// progress is not interrupted: this waits for it, and a `speak` that
/// arrives meanwhile waits for this (the engine holds one voice and
/// language at a time, and `speak` sets them once per utterance). `stop`
/// does not cut it short. The whole text is synthesized before it returns,
/// so long inputs take as long as they take: block on a worker.
///
/// Errors as `speak`, plus `NothingToSay` (no speakable text; a chunk with
/// nothing to say is skipped, as in `speak`) and `EngineUnavailable` for
/// `.engine = .system`: the platform's voices cannot hand over samples.
pub fn synthesize(a: std.mem.Allocator, input: []const u8, opts: Options) !Audio {
    if (opts.engine == .system) return error.EngineUnavailable;
    if (!ever_init.load(.acquire)) return error.NotInitialized;
    speak_mutex.lockUncancelable(io);
    defer speak_mutex.unlock(io);
    // Keeps `delete` and `unloadIdle` away from the context between chunks.
    speaking.store(true, .release);
    defer speaking.store(false, .release);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const prepared = try prepare(arena_state.allocator(), input, opts);

    const voice_id = try a.dupe(u8, prepared.voiceId());
    errdefer a.free(voice_id);
    const lang_id = try a.dupe(u8, prepared.lang);
    errdefer a.free(lang_id);
    var load_ms: u32 = 0;
    var backend_copy = blk: {
        engine_mutex.lockUncancelable(io);
        defer engine_mutex.unlock(io);
        if (prepared.engine == .clone) {
            load_ms = try ensureClone(prepared.clone_model, prepared.clone_path);
            break :blk try a.dupe(u8, cloneBackendName());
        }
        load_ms = try ensureEngine(prepared.model, opts.backend, if (opts.threads > 0) opts.threads else defaultThreads(), prepared.voice, prepared.lang, opts.speed);
        break :blk try a.dupe(u8, engine.?.backendName());
    };
    errdefer a.free(backend_copy);

    var pcm: std.ArrayList(f32) = .empty;
    errdefer pcm.deinit(a);
    var rate: u32 = kokoro.sample_rate;
    var n_chunks: u32 = 0;
    var failed: u32 = 0;
    var synth_ms: u32 = 0;
    var pos: usize = 0;
    // No first sound to hurry for: the largest chunks.
    while (chunks.next(prepared.readable, &pos, chunks.max)) |chunk| {
        const ts = std.Io.Clock.awake.now(io);
        var fell_back = false;
        const synth = synthAny(chunk, &prepared, opts, &fell_back);
        if (fell_back) {
            const cpu = try a.dupe(u8, "CPU");
            a.free(backend_copy);
            backend_copy = cpu;
        }
        synth_ms += msSince(ts);
        const audio = synth catch |err| {
            log.warn("chunk not synthesized ({s}): {s}", .{ @errorName(err), lastErrorOf(&prepared) });
            failed += 1;
            continue;
        };
        defer audio.deinit();
        try pcm.appendSlice(a, audio.samples);
        rate = audio.rate;
        n_chunks += 1;
    }
    if (n_chunks == 0) return if (failed > 0) error.SynthesisFailed else error.NothingToSay;
    const audio_s = @as(f32, @floatFromInt(pcm.items.len)) / @as(f32, @floatFromInt(rate));
    log.info("synthesized {d} chunks, {d:.1} s of audio in {d} ms on {s}", .{ n_chunks, audio_s, synth_ms, backend_copy });
    return .{
        .samples = try pcm.toOwnedSlice(a),
        .rate = rate,
        .voice = voice_id,
        .lang = lang_id,
        .backend = backend_copy,
        .chunks = n_chunks,
        .synth_ms = synth_ms,
        .load_ms = load_ms,
        .audio_s = audio_s,
    };
}

/// `.system`: the platform reads it; blocks until it's done (or stopped).
fn speakSystem(a: std.mem.Allocator, input: []const u8, opts: Options) !Result {
    if (comptime !builtin.abi.isAndroid()) return error.EngineUnavailable;
    if (!system_voice.available()) return error.EngineUnavailable;
    const prepared = if (opts.markdown) try prepareText(a, input) else input;
    const espeak_lang = if (std.mem.eql(u8, opts.lang, "auto")) guessLanguage(prepared) else opts.lang;
    const bcp47 = try bcp47Of(a, espeak_lang);
    _ = generation.fetchAdd(1, .acq_rel);
    silence(); // a Kokoro utterance stops for this one
    system_speaking.store(true, .release);
    defer system_speaking.store(false, .release);
    setState(null, .generating, "", "system");
    const t0 = std.Io.Clock.awake.now(io);
    const id = try system_voice.start(prepared, bcp47, std.math.clamp(opts.speed, 0.25, 4.0));
    var result: Result = .{ .voice = "system", .lang = espeak_lang, .backend = "system", .chunks = 1, .first_audio_ms = 0, .synth_ms = 0, .load_ms = 0, .audio_s = 0, .stopped = false };
    var e = system_voice.next(id, -1);
    if (e == .started) {
        result.first_audio_ms = msSince(t0);
        setState(null, .playing, "", "system");
        e = system_voice.next(id, @intFromEnum(e));
    }
    switch (e) {
        .finished => setState(null, .idle, "Finished", "system"),
        .failed => {
            setState(null, .@"error", "SystemVoiceFailed", "system");
            return error.SystemVoiceFailed;
        },
        else => {
            result.stopped = true;
            setState(null, .idle, "Stopped", "system");
        },
    }
    return result;
}

var system_speaking: std.atomic.Value(bool) = .init(false);

/// An espeak-ng language ("en-us", "pt-br", "es") as BCP 47 ("en-US").
fn bcp47Of(a: std.mem.Allocator, espeak: []const u8) ![]const u8 {
    const dash = std.mem.indexOfScalar(u8, espeak, '-') orelse return a.dupe(u8, espeak);
    const out = try a.dupe(u8, espeak);
    for (out[dash + 1 ..]) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
}

test bcp47Of {
    const a = std.testing.allocator;
    const x = try bcp47Of(a, "en-us");
    defer a.free(x);
    try std.testing.expectEqualStrings("en-US", x);
}

/// Stop the current utterance: silent at once, `speak` returns with
/// `stopped`. Any thread (the UI's), returns at once.
pub fn stop() void {
    if (comptime builtin.abi.isAndroid()) if (system_speaking.load(.acquire)) system_voice.stop();
    if (!ever_init.load(.acquire)) return;
    _ = generation.fetchAdd(1, .acq_rel);
    silence();
    if (speaking.load(.acquire)) setState(null, .idle, "Stopped", "");
}

// ---------------------------------------------------------------------------
// Tests

test {
    _ = chunks;
    _ = text;
    _ = lang_guess;
}

test "the catalog: unique ids, well-formed checksums, voices of known languages" {
    for (models, 0..) |m, i| {
        try std.testing.expectEqual(@as(usize, 64), m.sha256.len);
        for (models[i + 1 ..]) |o| try std.testing.expect(!std.mem.eql(u8, m.id, o.id));
    }
    try std.testing.expectEqual(@as(u32, 135), models[0].mb());
    for (voices, 0..) |v, i| {
        try std.testing.expectEqual(@as(usize, 64), v.sha256.len);
        try std.testing.expect(std.mem.startsWith(u8, v.file, "kokoro-voice-"));
        for (voices[i + 1 ..]) |o| try std.testing.expect(!std.mem.eql(u8, v.id, o.id));
    }
    // Every language the guesser names but Russian has a voice.
    for ([_][]const u8{ "en-us", "es", "fr", "it", "pt-br", "ja", "zh", "hi" }) |l| {
        for (voices) |v| {
            if (std.mem.eql(u8, v.lang, l)) break;
        } else return error.NoVoiceForLanguage;
    }
}

test "lifecycle APIs are safe before init and after teardown" {
    stop();
    unloadIdle();
    deinit();
    try std.testing.expectError(error.NotInitialized, speak(std.testing.allocator, "Hi.", .{}));
    try std.testing.expectError(error.NotInitialized, synthesize(std.testing.allocator, "Hi.", .{}));
    try std.testing.expectError(error.EngineUnavailable, synthesize(std.testing.allocator, "Hi.", .{ .engine = .system }));
    try std.testing.expectError(error.NotInitialized, download("af_heart"));
    try std.testing.expect(!status().speaking);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    init(std.testing.io, std.testing.allocator, dir);
    defer deinit();
    try std.testing.expectError(error.UnknownModel, download("nope"));
    try std.testing.expectError(error.UnknownModel, delete("nope"));
    try delete("af_heart"); // not there: nothing to do
    try std.testing.expectError(error.NoModel, speak(std.testing.allocator, "Hello there.", .{}));
    try std.testing.expectError(error.NoModel, synthesize(std.testing.allocator, "Hello there.", .{}));
    try std.testing.expect(!status().speaking); // synthesize let go of the flag
    try std.testing.expectError(error.UnknownVoice, resolveVoice("nope", "en-us"));
    const s = status();
    try std.testing.expect(!s.models[0].present and s.loaded == null and !s.speaking);
    try std.testing.expectEqualStrings("error", s.phase); // the failed speak
    stop();
    unloadIdle();
}

test "a replaced or stopped utterance can't overwrite a newer one's state" {
    ever_init.store(true, .release);
    defer ever_init.store(false, .release);
    io = std.testing.io;
    const old = generation.fetchAdd(1, .acq_rel) + 1;
    const newer = generation.fetchAdd(1, .acq_rel) + 1;
    setState(newer, .generating, "", "af_heart");
    setState(old, .idle, "Finished", "af_heart"); // dropped
    try std.testing.expectEqual(Phase.generating, phase);
    try std.testing.expect(!current(old) and current(newer));
    // stop(): every running utterance turns stale, its later states are dropped.
    speaking.store(true, .release);
    stop();
    speaking.store(false, .release);
    try std.testing.expectEqual(Phase.idle, phase);
    setState(newer, .playing, "", "af_heart");
    try std.testing.expectEqual(Phase.idle, phase);
    try std.testing.expect(!current(newer));
}

test "stop silences the registered stream; a stale utterance can't register" {
    ever_init.store(true, .release);
    defer ever_init.store(false, .release);
    io = std.testing.io;
    const s = try audio_play.Stream.init(std.testing.io, std.testing.allocator, 24_000);
    defer s.deinit();
    const gen = generation.fetchAdd(1, .acq_rel) + 1;
    try std.testing.expect(register(s, gen));
    defer unregister(s);
    try s.append(&.{ 0.1, 0.2 });
    stop();
    try std.testing.expect(s.finished());
    try std.testing.expectError(error.Cancelled, s.append(&.{0.3}));
    try std.testing.expect(!register(s, gen));
}

test "voice resolution follows the language, then its family, then any voice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    init(std.testing.io, std.testing.allocator, dir);
    defer deinit();
    try std.testing.expectError(error.NoVoice, resolveVoice("auto", "es"));
    // Files of the right size stand in for downloaded voices.
    const blank = try std.testing.allocator.alloc(u8, 522_560);
    defer std.testing.allocator.free(blank);
    @memset(blank, 0);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kokoro-voice-bf_emma.gguf", .data = blank });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kokoro-voice-ef_dora.gguf", .data = blank });
    try std.testing.expectEqualStrings("ef_dora", (try resolveVoice("auto", "es")).id);
    try std.testing.expectEqualStrings("bf_emma", (try resolveVoice("auto", "en-us")).id);
    try std.testing.expectEqualStrings("bf_emma", (try resolveVoice("auto", "fr")).id);
    try std.testing.expectError(error.NoVoice, resolveVoice("af_heart", "en-us"));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kokoro-voice-af_heart.gguf", .data = "short" });
    try std.testing.expect(!voicePresent(findVoice("af_heart").?)); // truncated: not there
}

test "cloned voices: ids, discovery in voices/, routing to the clone model" {
    const t = std.testing;
    try t.expect(validCloneId("lucia") and validCloneId("voz-4_b"));
    try t.expect(!validCloneId("") and !validCloneId("auto") and !validCloneId("ef_dora"));
    try t.expect(!validCloneId("../etc") and !validCloneId("a b") and !validCloneId("x.wav"));

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    init(t.io, t.allocator, dir);
    defer deinit();

    const none = try cloneVoices(t.allocator); // no voices/ directory yet
    defer t.allocator.free(none);
    try t.expectEqual(@as(usize, 0), none.len);
    try t.expect(try clonePath(t.allocator, "lucia") == null);

    try tmp.dir.createDirPath(t.io, clone_dir_name);
    for ([_][]const u8{ "voices/zoe.wav", "voices/lucia.mp3", "voices/lucia.wav", "voices/notes.txt", "voices/ef_dora.wav", "voices/bad id.wav" }) |f|
        try tmp.dir.writeFile(t.io, .{ .sub_path = f, .data = "RIFF" });
    const list = try cloneVoices(t.allocator);
    defer {
        for (list) |x| t.allocator.free(x);
        t.allocator.free(list);
    }
    try t.expectEqual(@as(usize, 2), list.len);
    try t.expectEqualStrings("lucia", list[0]);
    try t.expectEqualStrings("zoe", list[1]);
    const p = (try clonePath(t.allocator, "lucia")).?;
    defer t.allocator.free(p);
    try t.expect(std.mem.endsWith(u8, p, "voices/lucia.wav")); // .wav first

    // A cloned voice never falls back to Kokoro: without its model it says so.
    const expected: anyerror = if (clones_available) error.NoCloneModel else error.EngineUnavailable;
    try t.expectError(expected, synthesize(t.allocator, "Hola.", .{ .voice = "lucia" }));
    try t.expectError(error.NoModel, synthesize(t.allocator, "Hola.", .{ .voice = "nobody" })); // Kokoro: no model here
    try t.expectError(error.UnknownModel, download("nope"));
    try delete("qwen3-tts-1.7b-q8_0"); // not there: nothing to do
}

// End to end with a cloned voice: ORIEL_QWEN3TTS_DIR=<dir with the clone
// model's two files (catalog names) and speaker.wav>. Checks `synthesize`
// picks the clone engine, the language, and gives real speech.
test "synthesize reads in a cloned voice, Spanish and English" {
    if (comptime !clones_available) return error.SkipZigTest;
    const t = std.testing;
    const src = t.environ.getAlloc(t.allocator, "ORIEL_QWEN3TTS_DIR") catch return error.SkipZigTest;
    defer t.allocator.free(src);
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const cm = &clone_models[0];
    for ([_][2][]const u8{ .{ "qwen3tts-q8.gguf", cm.file }, .{ "mmproj-q8.gguf", cm.mmproj_file } }) |f| {
        const target = try std.fs.path.join(t.allocator, &.{ src, f[0] });
        defer t.allocator.free(target);
        try tmp.dir.symLink(t.io, target, f[1], .{});
    }
    try tmp.dir.createDirPath(t.io, clone_dir_name);
    const spk = try std.fs.path.join(t.allocator, &.{ src, "speaker.wav" });
    defer t.allocator.free(spk);
    try tmp.dir.symLink(t.io, spk, "voices/test-voice.wav", .{});
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);
    init(t.io, t.allocator, dir);
    defer deinit();
    try t.expect(status().clone_models[0].present);

    for ([_][3][]const u8{
        .{ "Hola, soy la voz de prueba. ¿Me escuchas bien?", "es", "auto" },
        .{ "**Hello**, I can read English as well.", "en", "auto" },
    }) |job| {
        const made = try synthesize(t.allocator, job[0], .{ .voice = "test-voice", .lang = job[2] });
        defer made.deinit(t.allocator);
        std.debug.print("\n[tts] clone {s}: {d:.1} s of audio in {d} ms (load {d}) on {s}\n", .{ made.lang, made.audio_s, made.synth_ms, made.load_ms, made.backend });
        try t.expectEqualStrings("test-voice", made.voice);
        try t.expectEqualStrings(job[1], made.lang);
        try t.expectEqual(@as(u32, 24_000), made.rate);
        try t.expect(made.audio_s > 1);
        for (made.samples) |x| try t.expect(std.math.isFinite(x));
    }
    unloadIdle();
}

// End to end on real files: ORIEL_TTS_DIR=<dir with kokoro-82m-q8_0.gguf,
// kokoro-voice-af_heart.gguf and kokoro-voice-ef_dora.gguf> (the espeak-ng
// data as `init` finds it). Plays on miniaudio's null backend (silent, real
// time) unless ORIEL_TTS_SPEAKERS=1. Prints first-audio latency, synthesis
// time and real-time factor per backend, against synthesizing the whole
// text before playing it.
test "speak streams English and Spanish, stops promptly, beats synthesize-then-play" {
    const t = std.testing;
    const src = t.environ.getAlloc(t.allocator, "ORIEL_TTS_DIR") catch return error.SkipZigTest;
    defer t.allocator.free(src);
    const speakers = if (t.environ.getAlloc(t.allocator, "ORIEL_TTS_SPEAKERS")) |v| blk: {
        t.allocator.free(v);
        break :blk true;
    } else |_| false;
    const level = t.log_level;
    t.log_level = .debug; // per-chunk timings
    defer t.log_level = level;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "kokoro-82m-q8_0.gguf", "kokoro-voice-af_heart.gguf", "kokoro-voice-ef_dora.gguf" }) |f| {
        const target = try std.fs.path.join(t.allocator, &.{ src, f });
        defer t.allocator.free(target);
        try tmp.dir.symLink(t.io, target, f, .{});
    }
    const dir = try tmp.dir.realPathFileAlloc(t.io, ".", t.allocator);
    defer t.allocator.free(dir);

    var context: audio_play.c.ma_context = undefined;
    var null_backend: audio_play.c.ma_backend = audio_play.c.ma_backend_null;
    try t.expectEqual(audio_play.c.MA_SUCCESS, audio_play.c.ma_context_init(&null_backend, 1, null, &context));
    defer _ = audio_play.c.ma_context_uninit(&context);
    audio_context = if (speakers) null else &context;
    defer audio_context = null;

    init(t.io, t.allocator, dir);
    defer deinit();
    const st = status();
    try t.expect(st.models[0].present and st.espeak_data != null);
    std.debug.print("\n[tts] espeak data {s}; GPU: {s}\n", .{ st.espeak_data.?, st.gpu orelse "none" });

    const english =
        \\# The lighthouse
        \\
        \\The old lighthouse stood at the edge of the cliff, its white paint peeling after decades of storms. Every evening the keeper climbed the spiral stairs, **one hundred and twelve** of them, to light the great lamp.
        \\
        \\Ships passing in the night relied on its steady beam. Fishermen said they could see it from twenty miles out, a small star that never moved. When the fog rolled in, the keeper sounded the horn every thirty seconds until dawn.
        \\
        \\Today the light is automatic, and nobody climbs the stairs anymore. But on clear nights, people still gather on the rocks below to watch it turn, as if the old keeper were up there, keeping watch.
    ;
    const spanish =
        \\El viejo faro estaba al borde del acantilado, con la pintura blanca desconchada después de décadas de tormentas. Cada tarde, el farero subía la escalera de caracol para encender la gran lámpara.
        \\
        \\Los barcos que pasaban de noche confiaban en su luz. Los pescadores decían que podían verla desde veinte millas, una pequeña estrella que nunca se movía.
    ;

    const backends: []const Backend = if (st.gpu != null) &.{ .cpu, .auto } else &.{.cpu};
    for (backends) |b| {
        // Cold: the model loads first.
        const cold = try speak(t.allocator, english, .{ .backend = b });
        defer freeResult(cold);
        try t.expect(!cold.stopped and cold.chunks > 3);
        try t.expectEqualStrings("af_heart", cold.voice);
        try t.expectEqualStrings("en-us", cold.lang);
        report("en cold", b, cold);
        // Warm: the context stays loaded.
        const warm = try speak(t.allocator, english, .{ .backend = b });
        defer freeResult(warm);
        try t.expectEqual(@as(u32, 0), warm.load_ms);
        report("en warm", b, warm);

        // The naive way: all of it synthesized before the first sound.
        const prepared = try prepareText(t.allocator, english);
        defer t.allocator.free(prepared);
        const naive = try synthesizeAll(prepared);
        std.debug.print("[tts] {s:<4} naive   first audio {d} ms ({s}), {d:.1} s audio\n", .{ @tagName(b), naive.ms, naive.how, naive.audio_s });
        try t.expect(warm.first_audio_ms * 2 < naive.ms);

        // Spanish, voice and language picked from the text; the context is reused.
        const es = try speak(t.allocator, spanish, .{ .backend = b });
        defer freeResult(es);
        try t.expectEqualStrings("ef_dora", es.voice);
        try t.expectEqualStrings("es", es.lang);
        try t.expectEqual(@as(u32, 0), es.load_ms);
        report("es warm", b, es);
    }

    // Stop from another thread: speak returns soon after, marked stopped.
    const Stopper = struct {
        fn run(at: *std.atomic.Value(i64)) void {
            std.testing.io.sleep(.fromMilliseconds(1500), .awake) catch {};
            at.store(@intCast(std.Io.Clock.awake.now(std.testing.io).nanoseconds), .release);
            stop();
        }
    };
    var stopped_at: std.atomic.Value(i64) = .init(0);
    const th = try std.Thread.spawn(.{}, Stopper.run, .{&stopped_at});
    const r = try speak(t.allocator, english, .{ .backend = .cpu, .speed = 1.2 });
    defer freeResult(r);
    th.join();
    const now: i64 = @intCast(std.Io.Clock.awake.now(t.io).nanoseconds);
    const lag_ms = @divTrunc(now - stopped_at.load(.acquire), std.time.ns_per_ms);
    std.debug.print("[tts] stop: speak returned {d} ms after stop()\n", .{lag_ms});
    try t.expect(r.stopped);
    try t.expect(lag_ms < 6000); // at most one chunk's synthesis
    try t.expectEqualStrings("idle", status().phase);
    unloadIdle();
    try t.expect(status().loaded == null);

    // Warm-up: the model loads without speaking; the next utterance doesn't.
    try warmUp(.{});
    try t.expect(status().loaded != null);
    const after = try speak(t.allocator, "Warmed up.", .{});
    defer freeResult(after);
    try t.expectEqual(@as(u32, 0), after.load_ms);
    report("warm-up", .auto, after);

    // synthesize: samples in memory, the same voice choice, nothing played.
    const made = try synthesize(t.allocator, spanish, .{ .backend = .cpu });
    defer made.deinit(t.allocator);
    try t.expectEqualStrings("ef_dora", made.voice);
    try t.expectEqualStrings("es", made.lang);
    try t.expectEqual(kokoro.sample_rate, made.rate);
    try t.expect(made.samples.len > made.rate); // over a second of speech
    try t.expect(made.audio_s > 1);
    for (made.samples) |x| try t.expect(std.math.isFinite(x));
    try t.expectError(error.NothingToSay, synthesize(t.allocator, "   ", .{}));
    try t.expect(!status().speaking);
}

fn freeResult(r: Result) void {
    std.testing.allocator.free(r.voice);
    std.testing.allocator.free(r.lang);
    std.testing.allocator.free(r.backend);
}

fn report(what: []const u8, b: Backend, r: Result) void {
    std.debug.print("[tts] {s:<4} {s} on {s}: first audio {d} ms (load {d}), {d} chunks, synth {d} ms for {d:.1} s audio, RTF {d:.3}, gaps {d} ms\n", .{
        @tagName(b),                                            what,     r.backend, r.first_audio_ms, r.load_ms, r.chunks, r.synth_ms, r.audio_s,
        @as(f32, @floatFromInt(r.synth_ms)) / 1000 / r.audio_s, r.gap_ms,
    });
}

/// The whole text in one synthesis (falling back to every chunk in turn
/// when it is too long for one): what the first sound waits for without
/// streaming.
fn synthesizeAll(input: []const u8) !struct { ms: u32, audio_s: f32, how: []const u8 } {
    engine_mutex.lockUncancelable(io);
    defer engine_mutex.unlock(io);
    const ctx = engine.?.ctx;
    const t0 = std.Io.Clock.awake.now(io);
    if (kokoro.synthesize(ctx, input)) |audio| {
        defer kokoro.freePcm(audio.samples);
        return .{ .ms = msSince(t0), .audio_s = @as(f32, @floatFromInt(audio.samples.len)) / 24_000, .how = "one call" };
    } else |_| {}
    const list = try chunks.split(gpa, input);
    defer gpa.free(list);
    var n: usize = 0;
    const t1 = std.Io.Clock.awake.now(io);
    for (list) |chunk| {
        const audio = try kokoro.synthesize(ctx, chunk);
        n += audio.samples.len;
        kokoro.freePcm(audio.samples);
    }
    return .{ .ms = msSince(t1), .audio_s = @as(f32, @floatFromInt(n)) / 24_000, .how = "all chunks" };
}
