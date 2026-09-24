//! Thin Zig wrapper for whisper.cpp.
//!
//! Provides system info reporting, default context parameters,
//! and model loading with error handling.

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    @cInclude("whisper.h");
});

/// Return a copy of the backend system info string (CPU features); the
/// caller frees it with `gpa`. The C function returns a pointer into a static
/// string it rebuilds on every call, so handing that out would dangle.
pub fn systemInfo(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8, std.mem.span(c.whisper_print_system_info()));
}

/// Return default context parameters.
pub fn contextDefaultParams() c.whisper_context_params {
    return c.whisper_context_default_params();
}

/// Audio format whisper expects: mono float samples at this rate.
pub const sample_rate: u32 = c.WHISPER_SAMPLE_RATE;

pub const TranscribeOptions = struct {
    /// Spoken language ("en", "es", ...) or "auto" to detect it.
    language: [:0]const u8 = "auto",
    /// Translate to English instead of transcribing.
    translate: bool = false,
    /// CPU threads (the GPU backend, when loaded, does the heavy work).
    threads: c_int = 4,
    /// Force one segment (short live-caption chunks).
    single_segment: bool = false,
};

/// A loaded whisper context handle. Not thread-safe: run one `transcribe`
/// at a time per context.
pub const Context = struct {
    handle: *c.whisper_context,

    pub fn deinit(self: Context) void {
        c.whisper_free(self.handle);
    }

    /// Transcribe mono `sample_rate` Hz samples; returns the text of all
    /// segments, joined, which the caller frees with `gpa`.
    pub fn transcribe(self: Context, gpa: std.mem.Allocator, samples: []const f32, opts: TranscribeOptions) ![]u8 {
        const n_samples = std.math.cast(c_int, samples.len) orelse return error.AudioTooLong;
        var p = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
        p.print_progress = false;
        p.print_realtime = false;
        p.print_timestamps = false;
        p.print_special = false;
        p.no_context = true;
        p.language = opts.language.ptr;
        p.translate = opts.translate;
        p.n_threads = opts.threads;
        p.single_segment = opts.single_segment;
        if (c.whisper_full(self.handle, p, samples.ptr, n_samples) != 0) return error.TranscribeFailed;

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const n_segments: usize = @intCast(@max(0, c.whisper_full_n_segments(self.handle)));
        for (0..n_segments) |i| {
            const text: ?[*:0]const u8 = c.whisper_full_get_segment_text(self.handle, @intCast(i));
            if (text) |t| try out.appendSlice(gpa, std.mem.span(t));
        }
        return out.toOwnedSlice(gpa);
    }
};

/// Load a whisper model from the given filesystem path. Returns `error.ModelLoadFailed`
/// if the file does not exist or cannot be parsed.
pub fn loadModel(path: [:0]const u8, params: c.whisper_context_params) !Context {
    const handle = c.whisper_init_from_file_with_params(path.ptr, params) orelse return error.ModelLoadFailed;
    return .{ .handle = handle };
}

/// Suppress all ggml and whisper log output on stderr (process-wide, for good).
pub fn silenceLogs() void {
    const noop = struct {
        fn cb(_: c.ggml_log_level, _: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
    }.cb;
    c.whisper_log_set(noop, null);
    c.ggml_log_set(noop, null);
}

/// Smoke check for oriel checkAll: verifies whisper system info reporting.
pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const info = try systemInfo(gpa);
    defer gpa.free(info);
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    return .{
        .module = "whisper",
        .ok = info.len > 0,
        .detail = try std.fmt.allocPrint(gpa, "whisper.cpp: {s}", .{trimmed}),
    };
}

test {
    std.testing.refAllDecls(@This());
}

test "whisper check" {
    silenceLogs();
    const res = try check(std.testing.allocator, undefined);
    defer std.testing.allocator.free(res.detail);
    try std.testing.expect(res.ok);
    try std.testing.expect(std.mem.indexOf(u8, res.detail, "whisper.cpp: ") != null);
}

test "whisper system info, default params, and missing file error" {
    silenceLogs();
    const info = try systemInfo(std.testing.allocator);
    defer std.testing.allocator.free(info);
    try std.testing.expect(info.len > 0);

    const params = contextDefaultParams();

    const res = loadModel("nonexistent_whisper_model_file.bin", params);
    try std.testing.expectError(error.ModelLoadFailed, res);
}
