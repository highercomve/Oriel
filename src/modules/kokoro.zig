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

pub fn voiceName(ctx: *Context) []const u8 {
    const n: [*c]const u8 = c.kokoro_voice_name(ctx);
    if (n == null) return "";
    return std.mem.span(n);
}

/// Text to mono float32 PCM (espeak phonemes → Kokoro). The samples are the
/// C library's until `freePcm`.
pub fn synthesize(ctx: *Context, text: []const u8) !struct { samples: []f32, rate: u32 } {
    const buf = try std.heap.page_allocator.dupeZ(u8, text);
    defer std.heap.page_allocator.free(buf);
    var n: c_int = 0;
    const pcm = c.kokoro_synthesize(ctx, buf.ptr, &n);
    if (pcm == null) return error.SynthesisFailed;
    const len: usize = @intCast(n);
    const rate: u32 = @intCast(c.kokoro_sample_rate(ctx));
    return .{ .samples = @as([*]f32, @ptrCast(pcm))[0..len], .rate = rate };
}

/// Free what `synthesize` handed out.
pub fn freePcm(samples: []f32) void {
    if (samples.len == 0) return;
    c.kokoro_pcm_free(@ptrCast(samples.ptr));
}
