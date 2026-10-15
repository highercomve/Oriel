//! The engine-free half of `oriel.speakers`: cosine similarity, speaker
//! clustering, matching known voices, and turning labeled windows into
//! speaker turns. Pure Zig, so its tests run in every build (src/oriel.zig),
//! not only with `-Dspeakers`.

const std = @import("std");

/// Cosine similarity of two vectors of the same length (0 when either is
/// all zeros). For L2-normalized embeddings this is their dot product.
pub fn cosine(a: []const f32, b: []const f32) f32 {
    std.debug.assert(a.len == b.len);
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * y;
        na += @as(f64, x) * x;
        nb += @as(f64, y) * y;
    }
    if (na == 0 or nb == 0) return 0;
    return @floatCast(dot / (@sqrt(na) * @sqrt(nb)));
}

/// Scale `v` to unit length (left alone when all zeros).
pub fn normalize(v: []f32) void {
    var n: f64 = 0;
    for (v) |x| n += @as(f64, x) * x;
    if (n == 0) return;
    const inv: f32 = @floatCast(1 / @sqrt(n));
    for (v) |*x| x.* *= inv;
}

pub const ClusterOptions = struct {
    /// Agglomerative clustering (average linkage, cosine similarity) stops
    /// when the best pair is below this.
    threshold: f32 = 0.45,
    /// Known number of speakers (0 = decide by threshold). The clustering
    /// then stops at that many and `min_size` / `merge_above` are skipped:
    /// the count is the caller's.
    speakers: u32 = 0,
    /// Clusters with fewer members than this are folded into their nearest
    /// bigger one: a single window always, a smaller cluster only when its
    /// centroid is at least `fold_above` similar to it. In a short meeting
    /// each person may get only two windows: those stay a speaker of their own.
    min_size: usize = 3,
    fold_above: f32 = 0.3,
    /// Clusters whose centroids are this similar are merged afterwards.
    merge_above: f32 = 0.8,
};

/// Above this many embeddings, `cluster` runs the agglomerative pass on
/// this many evenly spaced ones and assigns the rest to the nearest
/// resulting centroid: the pass keeps an n x n similarity matrix (16 MB
/// here, about 25 minutes of speech at the default 0.75 s step).
pub const max_direct = 2048;

/// Labels 0..k-1 for `embeddings` (all of one length), numbered by first
/// appearance. Caller frees.
pub fn cluster(gpa: std.mem.Allocator, embeddings: []const []const f32, opts: ClusterOptions) ![]u32 {
    const n = embeddings.len;
    const labels = try gpa.alloc(u32, n);
    errdefer gpa.free(labels);
    if (n == 0) return labels;

    if (n <= max_direct) {
        try agglomerate(gpa, embeddings, opts, labels);
    } else {
        // Evenly spaced sample; every embedding then goes to its nearest centroid.
        const sample = try gpa.alloc([]const f32, max_direct);
        defer gpa.free(sample);
        for (sample, 0..) |*s, i| s.* = embeddings[i * n / max_direct];
        const sample_labels = try gpa.alloc(u32, max_direct);
        defer gpa.free(sample_labels);
        try agglomerate(gpa, sample, opts, sample_labels);
        const cents = try centroids(gpa, sample, sample_labels);
        defer freeCentroids(gpa, cents);
        for (embeddings, labels) |e, *l| l.* = @intCast(nearest(e, cents).?);
    }

    if (opts.speakers == 0) {
        try foldSmall(gpa, embeddings, labels, opts.min_size, opts.fold_above);
        try mergeSimilar(gpa, embeddings, labels, opts.merge_above);
    }
    relabel(labels);
    return labels;
}

/// Which `known` centroid `centroid` matches: the most similar one with a
/// cosine of at least `threshold`, or null.
pub fn match(centroid: []const f32, known: []const []const f32, threshold: f32) ?usize {
    var best: ?usize = null;
    var best_sim: f32 = threshold;
    for (known, 0..) |k, i| {
        const s = cosine(centroid, k);
        if (s >= best_sim) {
            best = i;
            best_sim = s;
        }
    }
    return best;
}

/// The L2-normalized mean of each label's members (labels 0..k-1, every one
/// used). Caller frees with `freeCentroids`.
pub fn centroids(gpa: std.mem.Allocator, embeddings: []const []const f32, labels: []const u32) ![][]f32 {
    var k: usize = 0;
    for (labels) |l| k = @max(k, l + 1);
    const dim = if (embeddings.len > 0) embeddings[0].len else 0;
    const out = try gpa.alloc([]f32, k);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |c| gpa.free(c);
        gpa.free(out);
    }
    while (made < k) : (made += 1) {
        out[made] = try gpa.alloc(f32, dim);
        @memset(out[made], 0);
    }
    for (embeddings, labels) |e, l| {
        // Normalized members, so a loud window doesn't outweigh the rest.
        var n: f64 = 0;
        for (e) |x| n += @as(f64, x) * x;
        if (n == 0) continue;
        const inv: f32 = @floatCast(1 / @sqrt(n));
        for (out[l], e) |*c, x| c.* += x * inv;
    }
    for (out) |c| normalize(c);
    return out;
}

pub fn freeCentroids(gpa: std.mem.Allocator, cents: [][]f32) void {
    for (cents) |c| gpa.free(c);
    gpa.free(cents);
}

/// Average-linkage agglomerative clustering on cosine similarity: each
/// row's most similar cluster is cached, and only the rows whose best
/// was one of the merged pair are rescanned. `labels` gets cluster ids
/// (not yet numbered by appearance).
fn agglomerate(gpa: std.mem.Allocator, embeddings: []const []const f32, opts: ClusterOptions, labels: []u32) !void {
    const n = embeddings.len;
    const sim = try gpa.alloc(f32, n * n);
    defer gpa.free(sim);
    for (0..n) |i| {
        sim[i * n + i] = 0;
        for (i + 1..n) |j| {
            const s = cosine(embeddings[i], embeddings[j]);
            sim[i * n + j] = s;
            sim[j * n + i] = s;
        }
    }
    const size = try gpa.alloc(u32, n);
    defer gpa.free(size);
    const owner = try gpa.alloc(u32, n);
    defer gpa.free(owner);
    const best = try gpa.alloc(u32, n);
    defer gpa.free(best);
    const best_sim = try gpa.alloc(f32, n);
    defer gpa.free(best_sim);
    const active = try gpa.alloc(bool, n);
    defer gpa.free(active);
    @memset(size, 1);
    @memset(active, true);
    for (owner, 0..) |*o, i| o.* = @intCast(i);
    for (0..n) |i| rescan(sim, n, active, i, best, best_sim);

    var clusters = n;
    const want: usize = opts.speakers;
    while (clusters > 1) {
        if (want > 0 and clusters <= want) break;
        var i: usize = n;
        for (0..n) |r| {
            if (active[r] and (i == n or best_sim[r] > best_sim[i])) i = r;
        }
        if (want == 0 and best_sim[i] < opts.threshold) break;
        const j: usize = best[i];
        // Lance-Williams update for average linkage.
        const si: f32 = @floatFromInt(size[i]);
        const sj: f32 = @floatFromInt(size[j]);
        for (0..n) |k| {
            if (!active[k] or k == i or k == j) continue;
            const s = (si * sim[i * n + k] + sj * sim[j * n + k]) / (si + sj);
            sim[i * n + k] = s;
            sim[k * n + i] = s;
        }
        size[i] += size[j];
        active[j] = false;
        for (owner) |*o| {
            if (o.* == j) o.* = @intCast(i);
        }
        clusters -= 1;
        rescan(sim, n, active, i, best, best_sim);
        for (0..n) |k| {
            if (!active[k] or k == i) continue;
            if (best[k] == i or best[k] == j) {
                rescan(sim, n, active, k, best, best_sim);
            } else if (sim[k * n + i] > best_sim[k]) {
                best[k] = @intCast(i);
                best_sim[k] = sim[k * n + i];
            }
        }
    }
    @memcpy(labels, owner);
    relabel(labels);
}

fn rescan(sim: []const f32, n: usize, active: []const bool, i: usize, best: []u32, best_sim: []f32) void {
    best[i] = @intCast(i);
    best_sim[i] = -std.math.inf(f32);
    for (0..n) |k| {
        if (k == i or !active[k]) continue;
        if (sim[i * n + k] > best_sim[i]) {
            best[i] = @intCast(k);
            best_sim[i] = sim[i * n + k];
        }
    }
}

/// Index of the most similar centroid (null when there are none).
fn nearest(e: []const f32, cents: []const []const f32) ?usize {
    var best: ?usize = null;
    var best_sim: f32 = -std.math.inf(f32);
    for (cents, 0..) |c, i| {
        const s = cosine(e, c);
        if (s > best_sim) {
            best = i;
            best_sim = s;
        }
    }
    return best;
}

/// Members of clusters smaller than `min_size` move to the nearest cluster
/// that is big enough (by centroid): single windows always, larger ones when
/// at least `fold_above` similar. Nothing moves when no cluster is big enough.
fn foldSmall(gpa: std.mem.Allocator, embeddings: []const []const f32, labels: []u32, min_size: usize, fold_above: f32) !void {
    relabel(labels);
    const cents = try centroids(gpa, embeddings, labels);
    defer freeCentroids(gpa, cents);
    const counts = try gpa.alloc(usize, cents.len);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (labels) |l| counts[l] += 1;
    var big: usize = 0;
    for (counts) |c| big += @intFromBool(c >= min_size);
    if (big == 0 or big == cents.len) return;
    const into = try gpa.alloc(u32, cents.len);
    defer gpa.free(into);
    for (into, cents, counts, 0..) |*t, c, count, i| {
        t.* = @intCast(i);
        if (count >= min_size) continue;
        var best_sim: f32 = -std.math.inf(f32);
        for (cents, counts, 0..) |o, o_count, j| {
            if (o_count < min_size) continue;
            const s = cosine(c, o);
            if (s > best_sim) {
                best_sim = s;
                t.* = @intCast(j);
            }
        }
        // A voice of its own, heard only briefly: kept.
        if (count > 1 and best_sim < fold_above) t.* = @intCast(i);
    }
    for (labels) |*l| l.* = into[l.*];
}

/// Merge the most similar pair of clusters while their centroids' cosine is
/// at least `merge_above`.
fn mergeSimilar(gpa: std.mem.Allocator, embeddings: []const []const f32, labels: []u32, merge_above: f32) !void {
    while (true) {
        relabel(labels);
        const cents = try centroids(gpa, embeddings, labels);
        defer freeCentroids(gpa, cents);
        var pair: ?[2]u32 = null;
        var best: f32 = merge_above;
        for (cents, 0..) |a, i| {
            for (cents[i + 1 ..], i + 1..) |b, j| {
                const s = cosine(a, b);
                if (s >= best) {
                    best = s;
                    pair = .{ @intCast(i), @intCast(j) };
                }
            }
        }
        const p = pair orelse return;
        for (labels) |*l| {
            if (l.* == p[1]) l.* = p[0];
        }
    }
}

/// Number the labels 0..k-1 by first appearance.
fn relabel(labels: []u32) void {
    // Ids are below labels.len: a small map on the stack would cap n, so
    // map through the labels themselves with a marker bit.
    const mark: u32 = 1 << 31;
    var next: u32 = 0;
    for (labels, 0..) |l, i| {
        if (l & mark != 0) continue;
        const new = next | mark;
        next += 1;
        for (labels[i..]) |*m| {
            if (m.* == l) m.* = new;
        }
    }
    for (labels) |*l| l.* &= ~mark;
}

/// A stretch of audio, in seconds.
pub const Region = struct { start: f64, end: f64 };

/// Who spoke from `start` to `end` (seconds): a label of `Diarization.centroids`.
pub const Turn = struct { start: f64, end: f64, speaker: u32 };

/// Shortest region that still gets a window (seconds).
pub const min_window = 0.5;

/// The windows `diarize` embeds: `window`-long, every `step`, inside each
/// region (clamped to `duration`), plus one ending at the region's end when
/// the last one stops short of it. A region shorter than a window gets one
/// window over all of it if it is at least `min_window` long. Time-ordered.
/// Caller frees.
pub fn windows(gpa: std.mem.Allocator, duration: f64, regions: []const Region, window: f64, step: f64) ![]Region {
    std.debug.assert(window > 0 and step > 0);
    const sorted = try gpa.dupe(Region, regions);
    defer gpa.free(sorted);
    std.mem.sort(Region, sorted, {}, struct {
        fn lt(_: void, a: Region, b: Region) bool {
            return a.start < b.start;
        }
    }.lt);
    var out: std.ArrayList(Region) = .empty;
    errdefer out.deinit(gpa);
    for (sorted) |r| {
        const start = @max(0, r.start);
        const end = @min(duration, r.end);
        if (end - start < min_window) continue;
        if (end - start <= window) {
            try out.append(gpa, .{ .start = start, .end = end });
            continue;
        }
        var t = start;
        while (t + window <= end + 1e-9) : (t += step) try out.append(gpa, .{ .start = t, .end = t + window });
        const last = out.items[out.items.len - 1].end;
        if (end - last > 1e-6) try out.append(gpa, .{ .start = end - window, .end = end });
    }
    return out.toOwnedSlice(gpa);
}

/// Speaker turns from time-ordered labeled windows: overlapping or touching
/// windows of one speaker become one turn, and where two speakers' windows
/// overlap the boundary is the middle of the overlap. Caller frees.
pub fn turns(gpa: std.mem.Allocator, wins: []const Region, labels: []const u32) ![]Turn {
    std.debug.assert(wins.len == labels.len);
    var out: std.ArrayList(Turn) = .empty;
    errdefer out.deinit(gpa);
    for (wins, labels) |w, l| {
        if (out.items.len > 0) {
            const last = &out.items[out.items.len - 1];
            if (w.start <= last.end) {
                if (last.speaker == l) {
                    last.end = @max(last.end, w.end);
                    continue;
                }
                const mid = (w.start + last.end) / 2;
                last.end = mid;
                try out.append(gpa, .{ .start = mid, .end = w.end, .speaker = l });
                continue;
            }
        }
        try out.append(gpa, .{ .start = w.start, .end = w.end, .speaker = l });
    }
    return out.toOwnedSlice(gpa);
}

// ---------------------------------------------------------------------------
// Tests

/// `per` noisy copies of each of `k` orthogonal unit directions in `dim`
/// dimensions, interleaved (a, b, c, a, b, c...).
fn synthetic(gpa: std.mem.Allocator, k: usize, per: usize, dim: usize, noise: f32, seed: u64) ![][]f32 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const centers = try gpa.alloc(f32, k * dim);
    defer gpa.free(centers);
    for (centers) |*x| x.* = r.floatNorm(f32);
    // Orthonormal (Gram-Schmidt): distinct speakers, not merely random ones.
    for (0..k) |c| {
        const v = centers[c * dim ..][0..dim];
        for (0..c) |p| {
            const u = centers[p * dim ..][0..dim];
            var d: f32 = 0;
            for (v, u) |x, y| d += x * y;
            for (v, u) |*x, y| x.* -= d * y;
        }
        normalize(v);
    }
    const out = try gpa.alloc([]f32, k * per);
    for (out, 0..) |*e, i| {
        e.* = try gpa.alloc(f32, dim);
        const c = i % k;
        for (e.*, centers[c * dim ..][0..dim]) |*x, m| x.* = m + noise * r.floatNorm(f32) / @sqrt(@as(f32, @floatFromInt(dim)));
        normalize(e.*);
    }
    return out;
}

fn freeSynthetic(gpa: std.mem.Allocator, e: [][]f32) void {
    for (e) |x| gpa.free(x);
    gpa.free(e);
}

fn asConst(e: [][]f32) []const []const f32 {
    return @ptrCast(e);
}

test cosine {
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosine(&.{ 1, 2, 3 }, &.{ 2, 4, 6 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosine(&.{ 1, 0 }, &.{ 0, 1 }), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1), cosine(&.{ 1, 0 }, &.{ -3, 0 }), 1e-6);
    try std.testing.expectEqual(@as(f32, 0), cosine(&.{ 0, 0 }, &.{ 1, 0 }));
}

test "cluster: three noisy speakers in 16 dimensions" {
    const gpa = std.testing.allocator;
    const e = try synthetic(gpa, 3, 20, 16, 0.4, 1);
    defer freeSynthetic(gpa, e);
    const labels = try cluster(gpa, asConst(e), .{});
    defer gpa.free(labels);
    // Interleaved a, b, c: numbered by first appearance, so 0, 1, 2 repeating.
    for (labels, 0..) |l, i| try std.testing.expectEqual(@as(u32, @intCast(i % 3)), l);
}

test "cluster: a known number of speakers" {
    const gpa = std.testing.allocator;
    const e = try synthetic(gpa, 4, 10, 16, 0.4, 2);
    defer freeSynthetic(gpa, e);
    for ([_]u32{ 1, 2, 4 }) |k| {
        const labels = try cluster(gpa, asConst(e), .{ .speakers = k, .threshold = 2 });
        defer gpa.free(labels);
        var max: u32 = 0;
        for (labels) |l| max = @max(max, l);
        try std.testing.expectEqual(k - 1, max);
    }
    // More speakers than embeddings: one each.
    const labels = try cluster(gpa, asConst(e[0..3]), .{ .speakers = 9 });
    defer gpa.free(labels);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, labels);
}

test "cluster: small clusters fold into their nearest" {
    const gpa = std.testing.allocator;
    const e = try synthetic(gpa, 2, 10, 16, 0.3, 3);
    defer freeSynthetic(gpa, e);
    // An outlier close to speaker 0, too far for the threshold.
    const odd = try gpa.alloc(f32, 16);
    defer gpa.free(odd);
    var prng = std.Random.DefaultPrng.init(9);
    for (odd, e[0]) |*x, y| x.* = y + 1.2 * prng.random().floatNorm(f32) / 4;
    normalize(odd);
    try std.testing.expect(cosine(odd, e[0]) < 0.9);
    var all: [21][]const f32 = undefined;
    for (e, 0..) |x, i| all[i] = x;
    all[20] = odd;
    const strict = ClusterOptions{ .threshold = 0.9 * cosine(odd, e[0]) + 0.1, .min_size = 1, .merge_above = 2 };
    const kept = try cluster(gpa, &all, strict);
    defer gpa.free(kept);
    try std.testing.expectEqual(@as(u32, 2), kept[20]);
    var folded_opts = strict;
    folded_opts.min_size = 3;
    const folded = try cluster(gpa, &all, folded_opts);
    defer gpa.free(folded);
    try std.testing.expectEqual(@as(u32, 0), folded[20]);
}

test "cluster: similar centroids merge afterwards" {
    const gpa = std.testing.allocator;
    const e = try synthetic(gpa, 2, 10, 16, 0.2, 4);
    defer freeSynthetic(gpa, e);
    // Split by a high threshold, then merged back by a low merge_above.
    const split = try cluster(gpa, asConst(e), .{ .threshold = 0.999, .min_size = 1, .merge_above = 2 });
    defer gpa.free(split);
    var max: u32 = 0;
    for (split) |l| max = @max(max, l);
    try std.testing.expect(max > 1);
    const merged = try cluster(gpa, asConst(e), .{ .threshold = 0.999, .min_size = 1, .merge_above = -1 });
    defer gpa.free(merged);
    for (merged) |l| try std.testing.expectEqual(@as(u32, 0), l);
}

test "cluster: past max_direct, sampled and assigned" {
    const gpa = std.testing.allocator;
    const e = try synthetic(gpa, 3, max_direct / 3 + 50, 8, 0.3, 5);
    defer freeSynthetic(gpa, e);
    const labels = try cluster(gpa, asConst(e), .{});
    defer gpa.free(labels);
    for (labels, 0..) |l, i| try std.testing.expectEqual(@as(u32, @intCast(i % 3)), l);
}

test "cluster: none and one" {
    const gpa = std.testing.allocator;
    const none = try cluster(gpa, &.{}, .{});
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
    const one = try cluster(gpa, &.{&.{ 1, 0 }}, .{});
    defer gpa.free(one);
    try std.testing.expectEqualSlices(u32, &.{0}, one);
}

test match {
    const known = [_][]const f32{ &.{ 1, 0, 0 }, &.{ 0, 1, 0 }, &.{ 0.8, 0.6, 0 } };
    try std.testing.expectEqual(@as(?usize, 0), match(&.{ 1, 0.1, 0 }, &known, 0.5));
    try std.testing.expectEqual(@as(?usize, 2), match(&.{ 0.7, 0.7, 0 }, &known, 0.5));
    try std.testing.expectEqual(@as(?usize, null), match(&.{ 0, 0, 1 }, &known, 0.5));
    try std.testing.expectEqual(@as(?usize, null), match(&.{ 1, 0, 0 }, &.{}, 0.5));
}

test relabel {
    var l = [_]u32{ 7, 7, 2, 9, 2, 7 };
    relabel(&l);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1, 2, 1, 0 }, &l);
}

test windows {
    const gpa = std.testing.allocator;
    // 0-4 s: 0-1.5, 0.75-2.25, 1.5-3, 2.25-3.75, and 2.5-4 for the tail;
    // 5-5.3 s is too short; 6-7 s gets one window.
    const w = try windows(gpa, 10, &.{ .{ .start = 6, .end = 7 }, .{ .start = 0, .end = 4 }, .{ .start = 5, .end = 5.3 } }, 1.5, 0.75);
    defer gpa.free(w);
    const want = [_]Region{
        .{ .start = 0, .end = 1.5 },     .{ .start = 0.75, .end = 2.25 }, .{ .start = 1.5, .end = 3 },
        .{ .start = 2.25, .end = 3.75 }, .{ .start = 2.5, .end = 4 },     .{ .start = 6, .end = 7 },
    };
    try std.testing.expectEqual(want.len, w.len);
    for (want, w) |a, b| {
        try std.testing.expectApproxEqAbs(a.start, b.start, 1e-9);
        try std.testing.expectApproxEqAbs(a.end, b.end, 1e-9);
    }
    // Clamped to the audio.
    const c = try windows(gpa, 1, &.{.{ .start = -1, .end = 3 }}, 1.5, 0.75);
    defer gpa.free(c);
    try std.testing.expectEqual(@as(usize, 1), c.len);
    try std.testing.expectEqual(@as(f64, 1), c[0].end);
}

test turns {
    const gpa = std.testing.allocator;
    const w = [_]Region{
        .{ .start = 0, .end = 1.5 },     .{ .start = 0.75, .end = 2.25 }, .{ .start = 1.5, .end = 3 },
        .{ .start = 2.25, .end = 3.75 }, .{ .start = 6, .end = 7 },       .{ .start = 8, .end = 9 },
    };
    const t = try turns(gpa, &w, &.{ 0, 0, 1, 1, 1, 1 });
    defer gpa.free(t);
    // 0 until the middle of 1.5-2.25; 1 to 3.75; a gap; 1 again (not merged
    // across silence), and again.
    const want = [_]Turn{
        .{ .start = 0, .end = 1.875, .speaker = 0 }, .{ .start = 1.875, .end = 3.75, .speaker = 1 },
        .{ .start = 6, .end = 7, .speaker = 1 },     .{ .start = 8, .end = 9, .speaker = 1 },
    };
    try std.testing.expectEqualSlices(Turn, &want, t);
}

test "cluster: a short meeting's briefly heard voices stay apart" {
    // One speaker with 5 windows, three with 2 each: min_size folding must
    // not swallow the pairs (a 45 s meeting with five people came out as one).
    const gpa = std.testing.allocator;
    // Four orthonormal voices, interleaved (window i is voice i % 4).
    const e = try synthetic(gpa, 4, 5, 16, 0.2, 21);
    defer freeSynthetic(gpa, e);
    var all: [11][]const f32 = undefined;
    var n: usize = 0;
    for (e, 0..) |x, i| {
        const voice = i % 4;
        const nth = i / 4;
        if (voice == 0 or nth < 2) {
            all[n] = x;
            n += 1;
        }
    }
    const labels = try cluster(gpa, all[0..11], .{});
    defer gpa.free(labels);
    var k: u32 = 0;
    for (labels) |l| k = @max(k, l + 1);
    try std.testing.expectEqual(@as(u32, 4), k);
}
