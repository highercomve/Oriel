//! WAV files for `dictation.transcribeFile`: PCM (8, 16, 24, 32-bit) or
//! 32-bit float, any channel count and sample rate, mixed down to mono and
//! resampled to whisper's 16 kHz. Other formats (MP3, M4A...): decode them
//! to samples and use `dictation.transcribeSamples`.

const std = @import("std");

pub const Error = error{ NotWav, BadWav, UnsupportedWav, OutOfMemory };

/// Mono samples at `rate` Hz, allocated with `gpa`.
pub fn decode(gpa: std.mem.Allocator, data: []const u8, rate: u32) Error![]f32 {
    if (data.len < 12 or !std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return error.NotWav;
    var fmt: ?struct { format: u16, channels: u16, rate: u32, bits: u16 } = null;
    var pos: usize = 12;
    while (pos + 8 <= data.len) {
        const id = data[pos..][0..4];
        const size = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        const start = pos + 8;
        // A streamed file may leave the data size unset (0 or too large).
        const end = @min(data.len, std.math.add(usize, start, size) catch data.len);
        const body = data[start..end];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (body.len < 16) return error.BadWav;
            var format = std.mem.readInt(u16, body[0..2], .little);
            // WAVE_FORMAT_EXTENSIBLE: the real format is the sub-format GUID's first two bytes.
            if (format == 0xFFFE and body.len >= 26) format = std.mem.readInt(u16, body[24..26], .little);
            fmt = .{
                .format = format,
                .channels = std.mem.readInt(u16, body[2..4], .little),
                .rate = std.mem.readInt(u32, body[4..8], .little),
                .bits = std.mem.readInt(u16, body[14..16], .little),
            };
        } else if (std.mem.eql(u8, id, "data")) {
            const f = fmt orelse return error.BadWav;
            if (f.channels == 0 or f.rate == 0) return error.BadWav;
            const pcm = f.format == 1 and (f.bits == 8 or f.bits == 16 or f.bits == 24 or f.bits == 32);
            const float = f.format == 3 and f.bits == 32;
            if (!pcm and !float) return error.UnsupportedWav;
            const bytes: usize = f.bits / 8;
            const frame = bytes * f.channels;
            const frames = body.len / frame;
            const mono = try gpa.alloc(f32, frames);
            defer gpa.free(mono);
            for (mono, 0..) |*m, i| {
                var sum: f32 = 0;
                for (0..f.channels) |c| sum += sample(body[i * frame + c * bytes ..][0..bytes], f.bits, float);
                m.* = sum / @as(f32, @floatFromInt(f.channels));
            }
            return resample(gpa, mono, f.rate, rate);
        }
        pos = end + (size & 1); // chunks are word-aligned
    }
    return error.BadWav;
}

fn sample(b: []const u8, bits: u16, float: bool) f32 {
    if (float) return @bitCast(std.mem.readInt(u32, b[0..4], .little));
    return switch (bits) {
        8 => (@as(f32, @floatFromInt(b[0])) - 128) / 128, // unsigned
        16 => @as(f32, @floatFromInt(std.mem.readInt(i16, b[0..2], .little))) / 32768,
        24 => @as(f32, @floatFromInt(std.mem.readInt(i24, b[0..3], .little))) / 8388608,
        else => @as(f32, @floatFromInt(std.mem.readInt(i32, b[0..4], .little))) / 2147483648,
    };
}

/// Linear interpolation: enough for speech (whisper hears up to 8 kHz). A
/// copy when the rates match.
pub fn resample(gpa: std.mem.Allocator, in: []const f32, from: u32, to: u32) Error![]f32 {
    if (from == to) return gpa.dupe(f32, in);
    const n: usize = @intCast(@as(u64, in.len) * to / from);
    const out = try gpa.alloc(f32, n);
    const step = @as(f64, @floatFromInt(from)) / @as(f64, @floatFromInt(to));
    for (out, 0..) |*o, i| {
        const x = @as(f64, @floatFromInt(i)) * step;
        const j: usize = @intFromFloat(x);
        const t: f32 = @floatCast(x - @as(f64, @floatFromInt(j)));
        const a = in[@min(j, in.len - 1)];
        const b = in[@min(j + 1, in.len - 1)];
        o.* = a + (b - a) * t;
    }
    return out;
}

fn header(buf: []u8, format: u16, channels: u16, rate: u32, bits: u16, data_len: u32) []u8 {
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], 36 + data_len, .little);
    @memcpy(buf[8..16], "WAVEfmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little);
    std.mem.writeInt(u16, buf[20..22], format, .little);
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], rate, .little);
    std.mem.writeInt(u32, buf[28..32], rate * channels * bits / 8, .little);
    std.mem.writeInt(u16, buf[32..34], channels * bits / 8, .little);
    std.mem.writeInt(u16, buf[34..36], bits, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_len, .little);
    return buf[0..44];
}

test "decode: pcm16 mono at the target rate" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotWav, decode(gpa, "nope", 16000));
    var wav: [48]u8 = undefined;
    _ = header(&wav, 1, 1, 16000, 16, 4);
    std.mem.writeInt(i16, wav[44..46], 16384, .little);
    std.mem.writeInt(i16, wav[46..48], -32768, .little);
    const out = try decode(gpa, &wav, 16000);
    defer gpa.free(out);
    try std.testing.expectEqualSlices(f32, &.{ 0.5, -1.0 }, out);
}

test "decode: stereo float at 32 kHz is mixed down and halved" {
    const gpa = std.testing.allocator;
    var wav: [44 + 4 * 8]u8 = undefined;
    _ = header(&wav, 3, 2, 32000, 32, 32);
    const frames = [_][2]f32{ .{ 1, 0 }, .{ 0.5, 0.5 }, .{ 0, 0 }, .{ -1, -1 } };
    for (frames, 0..) |fr, i| for (fr, 0..) |v, c| std.mem.writeInt(u32, wav[44 + i * 8 + c * 4 ..][0..4], @bitCast(v), .little);
    const out = try decode(gpa, &wav, 16000);
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 2), out.len);
    try std.testing.expectEqual(@as(f32, 0.5), out[0]);
    try std.testing.expectEqual(@as(f32, 0), out[1]);
}

test "decode: unsupported format" {
    var wav: [44]u8 = undefined;
    _ = header(&wav, 2, 1, 16000, 4, 0); // ADPCM
    try std.testing.expectError(error.UnsupportedWav, decode(std.testing.allocator, &wav, 16000));
}

test resample {
    const gpa = std.testing.allocator;
    const up = try resample(gpa, &.{ 0, 1 }, 8000, 16000);
    defer gpa.free(up);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0.5, 1, 1 }, up);
}
