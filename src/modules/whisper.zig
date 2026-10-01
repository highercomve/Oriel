//! Thin Zig wrapper for whisper.cpp.
//!
//! Provides system info reporting, default context parameters,
//! and model loading with error handling.

const std = @import("std");
const oriel = @import("../oriel.zig");

pub const c = @cImport({
    // Zig defines _FORTIFY_SOURCE in optimized builds; translate-c can't
    // read the NDK's fortified <stdio.h> (Android release builds failed).
    // The C code itself is compiled with its own flags.
    @cUndef("_FORTIFY_SOURCE");
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
    /// Encoder context in frames (50 per second of audio), 0 for whisper's
    /// fixed 30 s window (1500). Whisper pads every clip to 30 s, so a
    /// short clip costs as much as a long one; `audioCtxFor` sizes it to
    /// the clip instead: several times faster on short live chunks, at
    /// some accuracy cost.
    audio_ctx: c_int = 0,
    /// Path of the voice activity detection model (`VadModel.install`):
    /// whisper then only hears the speech. Without it, silence gets made-up
    /// text ("Thank you.") and, past 30 s, repeats of the last sentence.
    vad_model: ?[:0]const u8 = null,
};

/// whisper_full parameters for `opts` (greedy decoding), for callers that
/// run whisper_full themselves (e.g. for segment timestamps). With VAD,
/// whisper.cpp maps the timestamps back onto the original audio.
pub fn fullParams(opts: TranscribeOptions) c.whisper_full_params {
    var p = c.whisper_full_default_params(c.WHISPER_SAMPLING_GREEDY);
    p.print_progress = false;
    p.print_realtime = false;
    p.print_timestamps = false;
    p.print_special = false;
    p.no_context = true;
    // no_context only clears the prompt when a call starts: each 30 s
    // window would still get the previous window's text as its prompt, and
    // a window without speech then repeats it ("the lazy dog." every 2 s).
    p.n_max_text_ctx = 0;
    p.language = opts.language.ptr;
    p.translate = opts.translate;
    p.n_threads = opts.threads;
    p.single_segment = opts.single_segment;
    p.audio_ctx = opts.audio_ctx;
    if (opts.vad_model) |path| {
        p.vad = true;
        p.vad_model_path = path.ptr;
        p.vad_params = c.whisper_vad_default_params();
        // Room around each stretch of speech (default 30 ms), so soft word
        // onsets and endings aren't cut.
        p.vad_params.speech_pad_ms = 200;
    }
    return p;
}

/// An encoder context for `n_samples` of audio (`TranscribeOptions.audio_ctx`):
/// its frames (50 per second) plus a margin, in steps of 64, at least 256
/// (smaller contexts make whisper hallucinate) and at most whisper's 1500.
pub fn audioCtxFor(n_samples: usize) c_int {
    const frames = n_samples * 50 / sample_rate + 64;
    return @intCast(@max(256, @min(1500, std.mem.alignForward(usize, frames, 64))));
}

test audioCtxFor {
    try std.testing.expectEqual(@as(c_int, 256), audioCtxFor(sample_rate)); // 1 s
    try std.testing.expectEqual(@as(c_int, 448), audioCtxFor(sample_rate * 7)); // 350 + 64
    try std.testing.expectEqual(@as(c_int, 1500), audioCtxFor(sample_rate * 40));
}

/// Silero VAD v6.2.0 (MIT, github.com/snakers4/silero-vad) in whisper.cpp's
/// ggml format, built in: 885 KB, identical to ggml-org/whisper-vad's
/// ggml-silero-v6.2.0.bin. whisper.cpp loads it from a file (once per
/// context), so `install` writes it out.
pub const VadModel = struct {
    pub const bytes = @embedFile("whisper_vad_model");
    pub const file_name = "ggml-silero-v6.2.0.bin";

    /// Write the model into directory `dir` (absolute; created if missing)
    /// unless it's there already, and return its path, which the caller frees.
    pub fn install(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) ![:0]u8 {
        const path = try std.fs.path.joinZ(gpa, &.{ dir, file_name });
        errdefer gpa.free(path);
        var d = try std.Io.Dir.cwd().createDirPathOpen(io, dir, .{});
        defer d.close(io);
        if (d.readFileAlloc(io, file_name, gpa, .limited(bytes.len + 1))) |existing| {
            defer gpa.free(existing);
            if (std.mem.eql(u8, existing, bytes)) return path;
        } else |_| {}
        var f = try d.createFileAtomic(io, file_name, .{ .replace = true });
        defer f.deinit(io);
        try f.file.writeStreamingAll(io, bytes);
        try f.replace(io);
        return path;
    }
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
        if (c.whisper_full(self.handle, fullParams(opts), samples.ptr, n_samples) != 0) return error.TranscribeFailed;

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
/// `error.CpuUnsupported` when the CPU lacks the ARM extensions ggml was
/// built for (`-Dggml_arm`).
pub fn loadModel(path: [:0]const u8, params: c.whisper_context_params) !Context {
    if (!@import("ggml_gpu.zig").cpuSupported()) return error.CpuUnsupported;
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

test "fullParams: no text carried between windows; VAD only with a model" {
    const plain = fullParams(.{});
    try std.testing.expectEqual(@as(c_int, 0), plain.n_max_text_ctx);
    try std.testing.expect(!plain.vad);
    const vad = fullParams(.{ .vad_model = "silero.bin" });
    try std.testing.expect(vad.vad);
    try std.testing.expectEqualStrings("silero.bin", std.mem.span(vad.vad_model_path));
    try std.testing.expectEqual(@as(c_int, 200), vad.vad_params.speech_pad_ms);
}

test "VadModel.install writes the model once and repairs a bad copy" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fs.path.join(gpa, &.{ buf[0..try tmp.dir.realPath(io, &buf)], "models" });
    defer gpa.free(dir);

    const path = try VadModel.install(io, gpa, dir);
    defer gpa.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, VadModel.file_name));
    const sub = "models" ++ std.fs.path.sep_str ++ VadModel.file_name;
    const written = try tmp.dir.readFileAlloc(io, sub, gpa, .unlimited);
    defer gpa.free(written);
    try std.testing.expectEqualSlices(u8, VadModel.bytes, written);

    try tmp.dir.writeFile(io, .{ .sub_path = sub, .data = "truncated" });
    const again = try VadModel.install(io, gpa, dir);
    defer gpa.free(again);
    const repaired = try tmp.dir.readFileAlloc(io, sub, gpa, .unlimited);
    defer gpa.free(repaired);
    try std.testing.expectEqualSlices(u8, VadModel.bytes, repaired);
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
