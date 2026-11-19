//! Text to speech in a cloned voice: Qwen3-TTS (12 Hz, 1.7B Base) on
//! llama.cpp's backbone plus its `mtmd` audio-generation pipeline (speaker
//! encoder, code predictor, code2wav), the engine `llama-tts` drives.
//!
//! A voice is a few seconds of someone speaking (a WAV or MP3, 10-15 s
//! works well): `loadSpeaker` reads it once, and every `synthesize` with
//! that speaker sounds like them, in any of the model's languages ("en",
//! "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ru").
//!
//! The model is two GGUF files (the backbone and its mmproj), ~2.2 GB at
//! Q8_0 on the GPU. A `Context` is not thread-safe: one call at a time.
//! Needs `-Dllama -Dllama_mtmd`. `oriel.tts` builds its cloned voices on
//! this; use it directly for your own pipeline.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const llama = @import("llama.zig");
const c = llama.c;

const log = std.log.scoped(.qwen3tts);

/// Output samples per second.
pub const sample_rate: u32 = 24_000;

/// The languages the model reads (codes `synthesize` takes).
pub const languages = [_][]const u8{ "en", "es", "fr", "de", "it", "pt", "ja", "ko", "zh", "ru" };

/// The model's language for an espeak-ng or BCP 47 tag ("en-us", "pt-BR",
/// "es"): its first two letters when the model reads that language, else
/// null.
pub fn languageOf(tag: []const u8) ?[]const u8 {
    if (tag.len < 2) return null;
    for (languages) |l| if (std.ascii.eqlIgnoreCase(l, tag[0..2])) return l;
    return null;
}

pub const Params = struct {
    /// Backbone and mmproj on the GPU (ggml's backends: CUDA, Vulkan, Metal).
    gpu: bool = true,
    threads: c_int = 4,
    /// The backbone's context: prompt + generated frames (12.5 a second).
    n_ctx: u32 = 2048,
};

pub const Context = struct {
    model: *c.llama_model,
    lctx: *c.llama_context,
    mctx: *c.mtmd_context,
    gen: *c.mtmd_helper_gen_audio,
    gpu: bool,

    /// Load the backbone (`model_path`) and its mmproj; `error.ModelLoadFailed`
    /// when either can't be read or the mmproj has no audio generation.
    pub fn init(model_path: [:0]const u8, mmproj_path: [:0]const u8, params: Params) !*Context {
        if (!@import("ggml_gpu.zig").cpuSupported()) return error.CpuUnsupported;
        silenceLogs();
        var mp = c.llama_model_default_params();
        mp.n_gpu_layers = if (params.gpu) 999 else 0;
        const model = c.llama_model_load_from_file(model_path.ptr, mp) orelse return error.ModelLoadFailed;
        errdefer c.llama_model_free(model);

        var cp = c.llama_context_default_params();
        cp.n_ctx = params.n_ctx;
        cp.n_batch = 512;
        cp.n_ubatch = 512;
        cp.n_threads = params.threads;
        cp.n_threads_batch = params.threads;
        cp.embeddings = true; // the pipeline reads the backbone's hidden states
        // On the CPU, all of it there: llama.cpp otherwise keeps the KV cache
        // and offloads ops to a GPU it found, which fails when that is full
        // (the reason for the CPU in the first place).
        cp.offload_kqv = params.gpu;
        cp.op_offload = params.gpu;
        const lctx = c.llama_init_from_model(model, cp) orelse return error.ModelLoadFailed;
        errdefer c.llama_free(lctx);

        var mtp = c.mtmd_context_params_default();
        mtp.use_gpu = params.gpu;
        mtp.print_timings = false;
        mtp.n_threads = params.threads;
        const mctx = c.mtmd_init_from_file(mmproj_path.ptr, model, mtp) orelse return error.ModelLoadFailed;
        errdefer c.mtmd_free(mctx);
        if (c.mtmd_gen_audio_get_info(mctx).type != c.MTMD_GEN_AUDIO_TYPE_QWEN3TTS) {
            log.err("{s}: not a Qwen3-TTS mmproj", .{mmproj_path});
            return error.ModelLoadFailed;
        }
        const gen = c.mtmd_helper_gen_audio_init(lctx, mctx) orelse return error.ModelLoadFailed;
        errdefer c.mtmd_helper_gen_audio_free(gen);

        const self = try std.heap.c_allocator.create(Context);
        self.* = .{ .model = model, .lctx = lctx, .mctx = mctx, .gen = gen, .gpu = params.gpu };
        return self;
    }

    pub fn deinit(self: *Context) void {
        c.mtmd_helper_gen_audio_free(self.gen);
        c.mtmd_free(self.mctx);
        c.llama_free(self.lctx);
        c.llama_model_free(self.model);
        std.heap.c_allocator.destroy(self);
    }

    /// Where the backbone runs: "CPU", or the GPU backend's device name.
    pub fn backendName(self: *const Context) []const u8 {
        return if (self.gpu) (@import("ggml_gpu.zig").backendName() orelse "GPU") else "CPU";
    }

    /// The reference voice in `path` (WAV, MP3, FLAC), decoded and resampled
    /// for the speaker encoder. Free it with `Speaker.deinit`.
    pub fn loadSpeaker(self: *Context, path: [:0]const u8) !Speaker {
        const w = c.mtmd_helper_bitmap_init_from_file(self.mctx, path.ptr, false, c.mtmd_helper_init_opt_default());
        const bitmap = w.bitmap orelse return error.SpeakerFailed;
        return .{ .bitmap = bitmap };
    }

    pub const Options = struct {
        /// A code from `languages`.
        lang: []const u8 = "en",
        /// The backbone's sampling (Qwen3-TTS's own defaults).
        temperature: f32 = 0.9,
        top_k: i32 = 50,
        top_p: f32 = 1.0,
        repeat_penalty: f32 = 1.05,
        /// The code predictor's sampling (0: the pipeline's defaults).
        code_top_k: i32 = 0,
        code_top_p: f32 = 0,
        /// null: random.
        seed: ?u32 = null,
        /// Frames at most (12.5 a second): a runaway generation stops here.
        max_frames: u32 = 1200,
    };

    /// `text` spoken in `speaker`'s voice (null: the model's own, not
    /// recommended). The samples (mono, -1 to 1, `sample_rate`) are allocated
    /// with `a`. Blocks for the whole synthesis.
    pub fn synthesize(self: *Context, a: std.mem.Allocator, text: []const u8, speaker: ?*const Speaker, opts: Options) ![]f32 {
        const lang = languageOf(opts.lang) orelse return error.UnsupportedLanguage;
        var lang_buf: [3]u8 = undefined;
        @memcpy(lang_buf[0..2], lang);
        lang_buf[2] = 0;
        const seed: u32 = opts.seed orelse std.math.maxInt(u32); // LLAMA_DEFAULT_SEED: random

        // A fresh sequence each time: the helper decodes from position 0.
        c.llama_memory_clear(c.llama_get_memory(self.lctx), true);
        c.mtmd_helper_gen_audio_reset(self.gen);

        var inp = c.mtmd_helper_gen_audio_inp_default();
        inp.seq_id = 0;
        inp.prompt = text.ptr;
        inp.prompt_len = text.len;
        inp.speaker_ref = if (speaker) |s| s.bitmap else null;
        inp.lang = &lang_buf;
        inp.top_k = opts.code_top_k;
        inp.top_p = opts.code_top_p;
        inp.seed = seed;
        inp.out_type = c.MTMD_HELPER_GEN_AUDIO_OUTTYPE_PCM;
        if (c.mtmd_helper_gen_audio_set_input(self.gen, &inp) != 0) return error.SynthesisFailed;
        while (true) {
            const left = c.mtmd_helper_gen_audio_step_prompt(self.gen, 512);
            if (left < 0) return error.BackendFailed;
            if (left == 0) break;
        }

        const smpl = c.llama_sampler_chain_init(c.llama_sampler_chain_default_params()) orelse return error.OutOfMemory;
        defer c.llama_sampler_free(smpl);
        c.llama_sampler_chain_add(smpl, c.llama_sampler_init_penalties(c.llama_vocab_n_tokens(c.llama_model_get_vocab(self.model)), 64, opts.repeat_penalty, 0, 0));
        c.llama_sampler_chain_add(smpl, c.llama_sampler_init_top_k(opts.top_k));
        c.llama_sampler_chain_add(smpl, c.llama_sampler_init_top_p(opts.top_p, 1));
        c.llama_sampler_chain_add(smpl, c.llama_sampler_init_temp(opts.temperature));
        c.llama_sampler_chain_add(smpl, c.llama_sampler_init_dist(seed));

        // The sampler accepts what it samples (llama_sampler_sample does).
        var sampled = c.llama_sampler_sample(smpl, self.lctx, -1);
        var h_state: [*c]const f32 = c.llama_get_embeddings_ith(self.lctx, -1);
        var frames: u32 = 0;
        var stop = false;
        while (!stop and frames < opts.max_frames) {
            var h_next: [*c]const f32 = null;
            if (c.mtmd_helper_gen_audio_step_gen(self.gen, sampled, h_state, &h_next, &stop) != 0) return error.BackendFailed;
            if (h_next == null) break;
            frames += 1;
            h_state = h_next;
            sampled = c.llama_sampler_sample(smpl, self.lctx, -1);
        }
        if (frames >= opts.max_frames) log.warn("stopped at {d} frames: no end of speech", .{frames});

        var rate: i32 = 0;
        var data: [*c]const u8 = null;
        var len: usize = 0;
        var n: i64 = 0;
        if (c.mtmd_helper_gen_audio_get_output(self.gen, &rate, &data, &len, &n) != 0) return error.SynthesisFailed;
        if (rate != sample_rate) log.warn("sample rate {d}, expected {d}", .{ rate, sample_rate });
        const count = len / @sizeOf(f32);
        const out = try a.alloc(f32, count);
        if (count > 0) @memcpy(std.mem.sliceAsBytes(out), data[0 .. count * @sizeOf(f32)]);
        return out;
    }
};

/// llama.cpp, ggml and mtmd log every load and step to stderr: quiet, as
/// `oriel.chat` keeps them (errors come back as Zig errors and `log`).
fn silenceLogs() void {
    llama.silenceLogs();
    const noop = struct {
        fn cb(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    c.mtmd_helper_log_set(noop, null);
}

/// A reference voice (`Context.loadSpeaker`).
pub const Speaker = struct {
    bitmap: *c.mtmd_bitmap,

    pub fn deinit(self: Speaker) void {
        c.mtmd_bitmap_free(self.bitmap);
    }
};

test languageOf {
    try std.testing.expectEqualStrings("en", languageOf("en-us").?);
    try std.testing.expectEqualStrings("pt", languageOf("pt-BR").?);
    try std.testing.expectEqualStrings("es", languageOf("es").?);
    try std.testing.expect(languageOf("hi") == null);
    try std.testing.expect(languageOf("e") == null);
}

// End to end on real files: ORIEL_QWEN3TTS_DIR=<dir with qwen3tts-q8.gguf,
// mmproj-q8.gguf and speaker.wav>. Writes nothing; checks the speech is
// there and finite, and prints the real-time factor.
test "synthesize speaks Spanish and English in the reference voice" {
    const t = std.testing;
    const dir = t.environ.getAlloc(t.allocator, "ORIEL_QWEN3TTS_DIR") catch return error.SkipZigTest;
    defer t.allocator.free(dir);
    const join = struct {
        fn f(d: []const u8, name: []const u8) ![:0]u8 {
            return std.fs.path.joinZ(std.testing.allocator, &.{ d, name });
        }
    }.f;
    const mp = try join(dir, "qwen3tts-q8.gguf");
    defer t.allocator.free(mp);
    const pp = try join(dir, "mmproj-q8.gguf");
    defer t.allocator.free(pp);
    const sp = try join(dir, "speaker.wav");
    defer t.allocator.free(sp);

    _ = @import("ggml_gpu.zig").load(t.io);
    llama.initBackend();
    const ctx = try Context.init(mp, pp, .{});
    defer ctx.deinit();
    const spk = try ctx.loadSpeaker(sp);
    defer spk.deinit();
    for ([_][2][]const u8{ .{ "es", "Hola, ya puedo hablar con esta voz." }, .{ "en-us", "Hello, I can speak English too." } }) |job| {
        const t0 = std.Io.Clock.awake.now(t.io);
        const pcm = try ctx.synthesize(t.allocator, job[1], &spk, .{ .lang = job[0], .seed = 42 });
        defer t.allocator.free(pcm);
        const ms = t0.durationTo(std.Io.Clock.awake.now(t.io)).toMilliseconds();
        const secs = @as(f32, @floatFromInt(pcm.len)) / sample_rate;
        std.debug.print("\n[qwen3tts] {s}: {d:.1} s of audio in {d} ms on {s}\n", .{ job[0], secs, ms, ctx.backendName() });
        try t.expect(secs > 1 and secs < 15);
        for (pcm) |x| try t.expect(std.math.isFinite(x));
    }
}
