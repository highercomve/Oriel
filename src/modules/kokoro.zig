//! Thin Zig wrapper for kokoro.cpp (offline text to speech, Kokoro-82M).
//!
//! The engine links into the app with espeak-ng (phonemization) and Highway
//! (the CPU synthesis SIMD); GPU backends come from the shared ggml build
//! (`ggml_gpu.load` registers Vulkan/CUDA so Kokoro's AUTO backend finds
//! them). The PCM buffer the synthesis hands out belongs to the C allocator
//! inside kokoro.cpp: the caller frees it through `freePcm`.

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("kokoro.h");
});

pub const sample_rate: u32 = 24_000;
pub const Audio = struct { samples: []f32, rate: u32 };
pub const status = c.enum_kokoro_status;
pub const error_ok: c_int = c.KOKORO_STATUS_OK;

/// The context handle, the C library's own opaque struct.
pub const Context = c.struct_kokoro_context;

/// The last error text for this thread ("" when healthy).
pub fn lastError() []const u8 {
    const msg: [*c]const u8 = c.kokoro_last_error();
    if (msg == null) return "";
    return std.mem.span(msg);
}

pub fn defaultParams() c.struct_kokoro_context_params {
    var p = c.kokoro_context_default_params();
    p.abi_version = c.KOKORO_ABI_VERSION;
    return p;
}

/// Initialize with a model file; null with `lastError()` explaining.
pub fn init(path_model: [:0]const u8, params: c.struct_kokoro_context_params) ?*Context {
    return c.kokoro_init_from_file(path_model.ptr, params);
}

pub fn free(ctx: *Context) void {
    c.kokoro_free(ctx);
}

pub fn loadVoice(ctx: *Context, path: [:0]const u8) !void {
    if (c.kokoro_load_voice_pack(ctx, path.ptr) != c.KOKORO_STATUS_OK) return error.VoiceFailed;
}

pub fn setLanguage(ctx: *Context, espeak_lang: []const u8) !void {
    const buf = try std.heap.page_allocator.dupeZ(u8, espeak_lang);
    defer std.heap.page_allocator.free(buf);
    if (c.kokoro_set_language(ctx, buf.ptr) != c.KOKORO_STATUS_OK) return error.LanguageFailed;
}

/// Speech duration multiplier (1 = normal, 2 = half as fast), clamped by
/// the engine to 0.25-4. Takes effect on the next synthesis.
pub fn setLengthScale(ctx: *Context, scale: f32) void {
    c.kokoro_set_length_scale(ctx, scale);
}

/// CPU threads for the next synthesis (the CPU backend's, and the CPU
/// parts of a GPU run).
pub fn setThreads(ctx: *Context, n: c_int) void {
    c.kokoro_set_n_threads(ctx, n);
}

/// The backend the context runs on ("CPU", "Vulkan", "Metal", "CUDA"...).
pub fn backendName(ctx: *Context) []const u8 {
    const n: [*c]const u8 = c.kokoro_backend_name(ctx);
    if (n == null) return "";
    return std.mem.span(n);
}

pub fn voiceName(ctx: *Context) []const u8 {
    const n: [*c]const u8 = c.kokoro_voice_name(ctx);
    if (n == null) return "";
    return std.mem.span(n);
}

/// Text to mono float32 PCM (espeak phonemes → Kokoro). The samples are the
/// C library's until `freePcm`.
pub fn synthesize(ctx: *Context, text: []const u8) !Audio {
    const buf = try std.heap.page_allocator.dupeZ(u8, text);
    defer std.heap.page_allocator.free(buf);
    var n: c_int = 0;
    const pcm = c.kokoro_synthesize(ctx, buf.ptr, &n);
    if (pcm == null) return error.SynthesisFailed;
    const raw_rate = c.kokoro_sample_rate(ctx);
    if (n <= 0 or raw_rate <= 0) {
        c.kokoro_pcm_free(pcm);
        return error.InvalidAudio;
    }
    const len: usize = @intCast(n);
    const rate: u32 = @intCast(raw_rate);
    return .{ .samples = @as([*]f32, @ptrCast(pcm))[0..len], .rate = rate };
}

/// Free what `synthesize` handed out.
pub fn freePcm(samples: []f32) void {
    if (samples.len == 0) return;
    c.kokoro_pcm_free(@ptrCast(samples.ptr));
}

test "Kokoro context defaults match the pinned C ABI" {
    const params = defaultParams();
    try std.testing.expectEqual(c.KOKORO_ABI_VERSION, params.abi_version);
    try std.testing.expect(params.length_scale > 0);
}

test "Kokoro synthesizes finite mono PCM from supplied model and voice" {
    const gpa = std.testing.allocator;
    const model = std.testing.environ.getAlloc(gpa, "ORIEL_TTS_MODEL") catch return error.SkipZigTest;
    defer gpa.free(model);
    const voice = try std.testing.environ.getAlloc(gpa, "ORIEL_TTS_VOICE");
    defer gpa.free(voice);
    const model_z = try gpa.dupeZ(u8, model);
    defer gpa.free(model_z);
    const voice_z = try gpa.dupeZ(u8, voice);
    defer gpa.free(voice_z);
    var params = defaultParams();
    params.backend = c.KOKORO_BACKEND_CPU;
    params.n_threads = 2;
    const ctx = init(model_z, params) orelse return error.ModelLoadFailed;
    defer free(ctx);
    try loadVoice(ctx, voice_z);
    try setLanguage(ctx, "en-us");
    const audio = try synthesize(ctx, "Hello from Oriel.");
    defer freePcm(audio.samples);
    try std.testing.expectEqual(sample_rate, audio.rate);
    try std.testing.expect(audio.samples.len > 0);
    for (audio.samples) |value| try std.testing.expect(std.math.isFinite(value));
}
