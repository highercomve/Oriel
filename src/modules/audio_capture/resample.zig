//! Streaming linear resampling of mono device frames. The capture backend
//! supplies frames; this state owns the samples awaiting interpolation.
const std = @import("std");
const Resampler = @This();

pending: std.ArrayList(f32) = .empty,
pos: f64 = 0,

pub fn deinit(self: *Resampler, gpa: std.mem.Allocator) void {
    self.pending.deinit(gpa);
    self.* = .{};
}

pub fn read(
    self: *Resampler,
    gpa: std.mem.Allocator,
    samples: []f32,
    from: u32,
    to: u32,
    ctx: anytype,
    comptime readFrames: fn (@TypeOf(ctx), []f32) anyerror!void,
) !void {
    if (from == 0 or to == 0) return error.UnsupportedSampleRate;
    const step = @as(f64, @floatFromInt(from)) / @as(f64, @floatFromInt(to));
    var out: usize = 0;
    var chunk: [1024]f32 = undefined;
    while (out < samples.len) {
        const need: usize = @as(usize, @intFromFloat(@floor(self.pos))) + 2;
        if (self.pending.items.len < need) {
            try readFrames(ctx, &chunk);
            try self.pending.appendSlice(gpa, &chunk);
            continue;
        }
        const i: usize = @intFromFloat(@floor(self.pos));
        const frac: f32 = @floatCast(self.pos - @floor(self.pos));
        samples[out] = self.pending.items[i] * (1 - frac) + self.pending.items[i + 1] * frac;
        out += 1;
        self.pos += step;
        const consumed: usize = @intFromFloat(@floor(self.pos));
        if (consumed > 4096) {
            // Downsampling can step past the buffered frames. Drop only
            // frames we actually have, retaining the offset into future input.
            const drop = @min(consumed, self.pending.items.len);
            const rest = self.pending.items.len - drop;
            std.mem.copyForwards(f32, self.pending.items[0..rest], self.pending.items[drop..]);
            self.pending.shrinkRetainingCapacity(rest);
            self.pos -= @floatFromInt(drop);
        }
    }
}

test "resampling across buffer boundaries preserves the input position" {
    const Ramp = struct {
        next: usize = 0,
        fn read(self: *@This(), frames: []f32) !void {
            for (frames) |*f| {
                f.* = @floatFromInt(self.next);
                self.next += 1;
            }
        }
    };
    // 96/192 kHz used to underflow after the first 4096 input frames.
    for ([_]u32{ 8000, 16000, 44100, 48000, 96000, 192000 }) |from| {
        var resampler: Resampler = .{};
        defer resampler.deinit(std.testing.allocator);
        var ramp: Ramp = .{};
        var samples: [1600]f32 = undefined;
        for (0..3) |batch| {
            try resampler.read(std.testing.allocator, &samples, from, 16000, &ramp, Ramp.read);
            for (samples, 0..) |sample, i| {
                const want = @as(f32, @floatFromInt(batch * samples.len + i)) * @as(f32, @floatFromInt(from)) / 16000;
                try std.testing.expectApproxEqAbs(want, sample, 0.01);
            }
        }
    }
}
