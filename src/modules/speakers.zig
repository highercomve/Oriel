//! Speaker embeddings and offline diarization (who spoke when), on
//! voice-detect.cpp (MIT): an encoder (ECAPA-TDNN, WeSpeaker ResNet34...)
//! turns a stretch of 16 kHz mono speech into an L2-normalized vector; similar
//! voices give similar vectors. `diarize` embeds sliding windows over the
//! speech, clusters them (src/modules/speakers/cluster.zig) and returns the
//! turns and one centroid per speaker, which `match` compares with voices the
//! app stored earlier.
//!
//! The engine runs on the shared ggml build: on the CPU, or on the first GPU
//! ggml has registered (`ggml_gpu.load` before `Encoder.load`).
//! `VOICEDETECT_DEVICE=cpu` keeps it on the CPU, `VOICEDETECT_THREADS` sets
//! its CPU threads (default: the cores, at most 8).
//!
//! Not thread-safe: voice-detect.cpp keeps one process-wide backend, so one
//! embedding (or `diarize`) at a time across all encoders.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const core = @import("speakers/cluster.zig");

pub const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cInclude("voicedetect_capi.h");
});

/// The audio the encoders take: mono float samples at this rate.
pub const sample_rate: u32 = 16_000;

pub const cosine = core.cosine;
pub const normalize = core.normalize;
pub const ClusterOptions = core.ClusterOptions;
pub const cluster = core.cluster;
pub const match = core.match;
pub const Region = core.Region;
pub const Turn = core.Turn;

/// A loaded speaker encoder (voice-detect.cpp's context).
pub const Encoder = opaque {
    fn ctx(self: *Encoder) *c.voicedetect_ctx {
        return @ptrCast(self);
    }

    /// Load a GGUF model (`catalog`); `error.LoadFailed` with
    /// `lastLoadError()` explaining.
    pub fn load(path: [:0]const u8) !*Encoder {
        const p = c.voicedetect_capi_load(path.ptr) orelse return error.LoadFailed;
        // An analyze model (age, gender, emotion) has no embedding.
        if (c.voicedetect_capi_embedding_dim(p) <= 0) {
            c.voicedetect_capi_free(p);
            return error.NotSpeakerModel;
        }
        return @ptrCast(p);
    }

    pub fn deinit(self: *Encoder) void {
        c.voicedetect_capi_free(self.ctx());
    }

    /// Values per embedding (192 for ECAPA-TDNN, 256 for WeSpeaker ResNet34).
    pub fn dim(self: *Encoder) usize {
        return @intCast(@max(0, c.voicedetect_capi_embedding_dim(self.ctx())));
    }

    /// The embedding space, "voicedetect:<arch>:<checkpoint>:<dim>": store it
    /// with saved voices and compare before matching (equal sizes don't mean
    /// comparable vectors). Valid until `deinit`.
    pub fn family(self: *Encoder) []const u8 {
        const f: [*c]const u8 = c.voicedetect_capi_encoder_family(self.ctx());
        if (f == null) return "";
        return std.mem.span(f);
    }

    /// Why the last `embed` failed ("" when it didn't).
    pub fn lastError(self: *Encoder) []const u8 {
        const e: [*c]const u8 = c.voicedetect_capi_last_error(self.ctx());
        if (e == null) return "";
        return std.mem.span(e);
    }

    /// L2-normalized embedding of 16 kHz mono samples. Caller frees with gpa.
    pub fn embed(self: *Encoder, gpa: std.mem.Allocator, samples: []const f32) ![]f32 {
        if (samples.len == 0 or samples.len > std.math.maxInt(c_int)) return error.InvalidAudio;
        var vec: [*c]f32 = null;
        var n: c_int = 0;
        if (c.voicedetect_capi_embed_pcm(self.ctx(), samples.ptr, @intCast(samples.len), sample_rate, &vec, &n) != 0 or vec == null)
            return error.EmbedFailed;
        defer c.voicedetect_capi_free_vec(vec);
        return gpa.dupe(f32, vec[0..@intCast(@max(0, n))]);
    }
};

/// Why the last `Encoder.load` on this thread failed.
pub fn lastLoadError() []const u8 {
    const e: [*c]const u8 = c.voicedetect_capi_last_load_error();
    if (e == null) return "";
    return std.mem.span(e);
}

/// Progress of a `diarize` call, read from another thread.
pub const Progress = struct {
    /// Windows embedded so far, out of `total` (set before the first).
    done: std.atomic.Value(u32) = .init(0),
    total: std.atomic.Value(u32) = .init(0),
    /// Set to stop early: `diarize` returns `error.Canceled`.
    cancel: std.atomic.Value(bool) = .init(false),
};

pub const DiarizeOptions = struct {
    /// Seconds of audio per embedding. Shorter windows follow quick turns
    /// but recognize voices less reliably (one voice's 1.5 s windows were
    /// only 0.54 alike with ECAPA, 0.80 at 3 s).
    window: f64 = 3.0,
    /// Seconds between window starts.
    step: f64 = 1.5,
    cluster: ClusterOptions = .{},
    progress: ?*Progress = null,
};

pub const Diarization = struct {
    /// Time-ordered; adjacent windows of one speaker are one turn.
    turns: []Turn,
    /// Per speaker (index = `Turn.speaker`), L2-normalized, for `match`.
    centroids: [][]f32,

    pub fn deinit(self: *Diarization, gpa: std.mem.Allocator) void {
        gpa.free(self.turns);
        core.freeCentroids(gpa, self.centroids);
        self.* = undefined;
    }
};

/// Embed sliding windows inside `regions` (the speech, from a voice activity
/// detector; a region shorter than a window gets one window over its whole
/// length if it is at least 0.5 s), cluster them, and return the speaker
/// turns. `samples` are 16 kHz mono. Blocks for a while on long audio: run it
/// on a worker and watch `opts.progress`.
pub fn diarize(gpa: std.mem.Allocator, enc: *Encoder, samples: []const f32, regions: []const Region, opts: DiarizeOptions) !Diarization {
    const rate: f64 = @floatFromInt(sample_rate);
    const duration = @as(f64, @floatFromInt(samples.len)) / rate;
    const wins = try core.windows(gpa, duration, regions, opts.window, opts.step);
    defer gpa.free(wins);
    if (opts.progress) |p| {
        p.done.store(0, .release);
        p.total.store(@intCast(wins.len), .release);
    }

    const embeddings = try gpa.alloc([]f32, wins.len);
    var made: usize = 0;
    defer {
        for (embeddings[0..made]) |e| gpa.free(e);
        gpa.free(embeddings);
    }
    for (wins) |w| {
        if (opts.progress) |p| if (p.cancel.load(.acquire)) return error.Canceled;
        const from: usize = @intFromFloat(@round(w.start * rate));
        const to: usize = @min(samples.len, @as(usize, @intFromFloat(@round(w.end * rate))));
        embeddings[made] = try enc.embed(gpa, samples[from..to]);
        made += 1;
        if (opts.progress) |p| _ = p.done.fetchAdd(1, .release);
    }

    const all: []const []const f32 = @ptrCast(embeddings);
    const labels = try core.cluster(gpa, all, opts.cluster);
    defer gpa.free(labels);
    const turns = try core.turns(gpa, wins, labels);
    errdefer gpa.free(turns);
    return .{ .turns = turns, .centroids = try core.centroids(gpa, all, labels) };
}

/// A speaker encoder to download (`model_download.fetchVerified` with `url`,
/// `file` and `sha256`).
pub const Model = struct {
    id: []const u8,
    /// For people.
    name: []const u8,
    file: []const u8,
    url: []const u8,
    sha256: []const u8,
    size: u64,
    /// The weights' license (the checkpoint's, not voice-detect.cpp's).
    license: []const u8,
    dim: u32,

    pub fn mb(self: *const Model) u32 {
        return @intCast((self.size + (1 << 19)) >> 20);
    }
};

const repo_url = "https://huggingface.co/mudler/voice-detect-gguf/resolve/main/";

/// mudler/voice-detect-gguf; the default first. WeSpeaker tells people
/// apart far better here: on LibriSpeech voices (3 s halves) it put one
/// man at cosine 0.73, two women at 0.22, a man and a woman at 0.08; the
/// ECAPA GGUF gave 0.80, 0.70 and 0.45 (its SpeechBrain features aren't the
/// Kaldi fbank the engine feeds every model).
pub const catalog = [_]Model{
    .{
        .id = "wespeaker-resnet34-voxceleb",
        .name = "WeSpeaker ResNet34 (VoxCeleb)",
        .file = "wespeaker-resnet34-voxceleb.gguf",
        .url = repo_url ++ "wespeaker-resnet34-voxceleb.gguf",
        .sha256 = "72040372494eafec299836bc1977cfc13c603cb486674ed59b0f4c03758d29da",
        .size = 26_527_360,
        .license = "CC-BY-4.0",
        .dim = 256,
    },
    .{
        .id = "ecapa-tdnn-voxceleb",
        .name = "ECAPA-TDNN (VoxCeleb)",
        .file = "ecapa-tdnn-voxceleb.gguf",
        .url = repo_url ++ "ecapa-tdnn-voxceleb.gguf",
        .sha256 = "68046a1fdfb7843f460962db4739fbd381cc5c3ab93d1505e75e2f4c0dc19b8f",
        .size = 64_369_440,
        .license = "Apache-2.0",
        .dim = 192,
    },
};

test "the catalog: unique ids, well-formed checksums" {
    for (catalog, 0..) |m, i| {
        try std.testing.expectEqual(@as(usize, 64), m.sha256.len);
        try std.testing.expect(std.mem.endsWith(u8, m.url, m.file));
        for (catalog[i + 1 ..]) |o| try std.testing.expect(!std.mem.eql(u8, m.id, o.id));
    }
    try std.testing.expectEqual(@as(u32, 25), catalog[0].mb());
}

/// 16-bit PCM mono WAV samples as floats (test input). Caller frees.
fn readWav(gpa: std.mem.Allocator, path: []const u8) ![]f32 {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    var i: usize = 12;
    while (i + 8 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[i + 4 ..][0..4], .little);
        if (std.mem.eql(u8, bytes[i..][0..4], "data")) {
            const data = bytes[i + 8 ..][0..@min(len, bytes.len - i - 8)];
            const out = try gpa.alloc(f32, data.len / 2);
            for (out, 0..) |*s, k| s.* = @as(f32, @floatFromInt(std.mem.readInt(i16, data[k * 2 ..][0..2], .little))) / 32768;
            return out;
        }
        i += 8 + len + (len & 1);
    }
    return error.NoData;
}

/// `samples` read `rate` times as fast (linear interpolation): pitch and
/// formants shift, a stand-in for another voice.
fn resampled(gpa: std.mem.Allocator, samples: []const f32, rate: f64) ![]f32 {
    const n: usize = @intFromFloat(@as(f64, @floatFromInt(samples.len - 1)) / rate);
    const out = try gpa.alloc(f32, n);
    for (out, 0..) |*s, i| {
        const t = @as(f64, @floatFromInt(i)) * rate;
        const k: usize = @intFromFloat(t);
        const f: f32 = @floatCast(t - @as(f64, @floatFromInt(k)));
        s.* = samples[k] * (1 - f) + samples[k + 1] * f;
    }
    return out;
}

fn loadTestEncoder(gpa: std.mem.Allocator) !*Encoder {
    const model = std.testing.environ.getAlloc(gpa, "ORIEL_SPEAKER_MODEL") catch return error.SkipZigTest;
    defer gpa.free(model);
    const model_z = try gpa.dupeZ(u8, model);
    defer gpa.free(model_z);
    return Encoder.load(model_z) catch |err| {
        std.debug.print("speakers: {s}\n", .{lastLoadError()});
        return err;
    };
}

test "an encoder embeds two clips into unit vectors of its size" {
    const gpa = std.testing.allocator;
    const enc = try loadTestEncoder(gpa);
    defer enc.deinit();
    try std.testing.expect(enc.dim() > 0);
    try std.testing.expect(std.mem.startsWith(u8, enc.family(), "voicedetect:"));
    var prng = std.Random.DefaultPrng.init(7);
    var a: [sample_rate * 2]f32 = undefined;
    var b: [sample_rate * 2]f32 = undefined;
    for (&a, 0..) |*s, i| s.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.07) + 0.05 * prng.random().floatNorm(f32);
    for (&b, 0..) |*s, i| s.* = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.23) * @sin(@as(f32, @floatFromInt(i)) * 0.001);
    for ([_][]const f32{ &a, &b }) |clip| {
        const e = try enc.embed(gpa, clip);
        defer gpa.free(e);
        try std.testing.expectEqual(enc.dim(), e.len);
        var n: f32 = 0;
        for (e) |x| n += x * x;
        try std.testing.expectApproxEqAbs(@as(f32, 1), @sqrt(n), 1e-3);
    }
}

test "one voice is closer to itself than to a shifted copy" {
    // ORIEL_SPEAKER_WAV: 16 kHz mono 16-bit speech of one speaker, 6 s or more.
    const gpa = std.testing.allocator;
    const wav = std.testing.environ.getAlloc(gpa, "ORIEL_SPEAKER_WAV") catch return error.SkipZigTest;
    defer gpa.free(wav);
    const enc = try loadTestEncoder(gpa);
    defer enc.deinit();
    const speech = try readWav(gpa, wav);
    defer gpa.free(speech);
    const half = speech.len / 2;
    const first = try enc.embed(gpa, speech[0..half]);
    defer gpa.free(first);
    const second = try enc.embed(gpa, speech[half..]);
    defer gpa.free(second);
    const shifted_audio = try resampled(gpa, speech[half..], 1.3);
    defer gpa.free(shifted_audio);
    const shifted = try enc.embed(gpa, shifted_audio);
    defer gpa.free(shifted);
    const same = cosine(first, second);
    const other = cosine(first, shifted);
    std.debug.print("speakers: same voice {d:.3}, shifted x1.3 {d:.3}\n", .{ same, other });
    try std.testing.expect(same > 0.5);
    try std.testing.expect(other < same);

    // The voice, then the shifted copy: two speakers.
    const both = try gpa.alloc(f32, half + shifted_audio.len);
    defer gpa.free(both);
    @memcpy(both[0..half], speech[0..half]);
    @memcpy(both[half..], shifted_audio);
    // Threshold mode, for the log only: a sped-up copy of a voice stays
    // about 0.5 similar to it, above the default threshold. Then a known count.
    const secs = @as(f64, @floatFromInt(both.len)) / sample_rate;
    const regions = [_]Region{.{ .start = 0, .end = secs }};
    var guess = try diarize(gpa, enc, both, &regions, .{ .cluster = .{ .min_size = 1 } });
    defer guess.deinit(gpa);
    for (guess.turns) |t| std.debug.print("speakers: threshold {d:.2}-{d:.2} s speaker {d}\n", .{ t.start, t.end, t.speaker });
    var progress: Progress = .{};
    var d = try diarize(gpa, enc, both, &regions, .{ .progress = &progress, .cluster = .{ .speakers = 2 } });
    defer d.deinit(gpa);
    for (d.turns) |t| std.debug.print("speakers: two {d:.2}-{d:.2} s speaker {d}\n", .{ t.start, t.end, t.speaker });
    try std.testing.expectEqual(progress.total.load(.acquire), progress.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), d.centroids.len);
    try std.testing.expectEqual(@as(usize, 2), d.turns.len);
    // The switch within a step of where the shifted copy starts.
    const switch_at = @as(f64, @floatFromInt(half)) / sample_rate;
    try std.testing.expectApproxEqAbs(switch_at, d.turns[0].end, 0.75);
    try std.testing.expectEqual(@as(?usize, 0), match(first, @ptrCast(d.centroids), 0.5));
}
