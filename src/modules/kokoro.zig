//! Thin Zig wrapper for kokoro.cpp (offline text to speech, Kokoro-82M).
//!
//! The engine links into the app with espeak-ng (phonemization) and Highway
//! (SQLite SIMD); GPU backends come from the shared ggml build (`ggml_gpu.load`
//! which registers Vulkan/CUDA so Kokoro's AUTO backend can pick them).

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("kokoro.h");
});

pub const sample_rate: u32 = 24_000;
pub const status = c.enum_kokoro_status;
pub const error_ok: c_int = c.KOKORO_STATUS_OK;

/// The last error text for this thread ("" when healthy).
pub fn lastError() []const u8 {
    const msg = c.kokoro_last_error() orelse "";
    return std.mem.span(msg);
}

pub const Context = opaque {};

pub fn defaultParams() c.struct_kokoro_context_params {
    var p = c.kokoro_context_default_params();
    p.abi_version = c.KOKORO_ABI_VERSION;
    return p;
}

/// Initialize with a model file; NULL with `lastError()` explaining.
pub fn init(path_model: [:0]const u8, params: c.struct_kokoro_context_params) ?*Context {
    return @as(?*c.struct_kokoro_context, c.kokoro_init_from_file(path_model.ptr, params)) orelse null;
}

pub fn free(ctx: *Context) void {
    c.kokoro_free(@ptrCast(ctx));
}

pub fn loadVoice(ctx: *Context, path: [:0]const u8) !void {
    if (c.kokoro_load_voice_pack(@ptrCast(ctx), path.ptr) != c.KOKORO_STATUS_OK) return error.VoiceFailed;
}

pub fn setLanguage(ctx: *Context, espeak_lang: []const u8) !void {
    const buf = try std.heap.page_allocator.dupeZ(u8, espeak_lang);
    defer std.heap.page_allocator.free(buf);
    if (c.kokoro_set_language(@ptrCast(ctx), buf.ptr) != c.KOKORO_STATUS_OK) return error.LanguageFailed;
}

pub fn voiceName(ctx: *Context) []const u8 {
    const n = c.kokoro_voice_name(@ptrCast(ctx)) orelse "";
    return std.mem.span(n);
}

/// Text to mono float32 PCM (espeak phonemes → Kokoro). Callers own `samples`
/// until freeing with `freePcm`.
pub fn synthesize(ctx: *Context, text: []const u8, heap: std.mem.Allocator) !struct { samples: []f32, rate: u32 } {
    const buf = try std.heap.page_allocator.dupeZ(u8, text);
    defer std.heap.page_allocator.free(buf);
    var n: c_int = 0;
    const pcm = c.kokoro_synthesize(@ptrCast(ctx), buf.ptr, &n);
    if (pcm == null) return error.SynthesisFailed;
    const samples = @as([*]f32, @ptrCast(pcm))[0..@intCast(n)];
    // Hand the buffer out; the C side owns it, so free through kokoro_pcm_free.
    const owned = try heap.dupe(f32, samples);
    c.kokoro_pcm_free(pcm);
    const rate = c.kokoro_sample_rate(@ptrCast(ctx));
    return .{ .samples = owned, .rate = @intCast(rate) };
}

pub fn freePcm(heap: std.mem.Allocator, samples: []f32) void {
    heap.free(samples);
}
