//! Icon resizing and raster processing utilities.

const std = @import("std");
const zigimg = @import("zigimg");

pub const icon_sizes = [_]u16{ 16, 24, 32, 48, 64, 128, 256, 512 };

/// Downsample an RGBA32 pixel buffer using box (area) averaging.
pub fn downsampleRgba32(
    src: []const zigimg.color.Rgba32,
    src_w: usize,
    src_h: usize,
    dst: []zigimg.color.Rgba32,
    dst_w: usize,
    dst_h: usize,
) void {
    std.debug.assert(src.len == src_w * src_h);
    std.debug.assert(dst.len == dst_w * dst_h);

    for (0..dst_h) |dy| {
        const sy_start = (dy * src_h) / dst_h;
        const sy_end = @max(sy_start + 1, ((dy + 1) * src_h) / dst_h);
        for (0..dst_w) |dx| {
            const sx_start = (dx * src_w) / dst_w;
            const sx_end = @max(sx_start + 1, ((dx + 1) * src_w) / dst_w);

            var r_sum: u64 = 0;
            var g_sum: u64 = 0;
            var b_sum: u64 = 0;
            var a_sum: u64 = 0;
            var count: u64 = 0;

            for (sy_start..sy_end) |sy| {
                for (sx_start..sx_end) |sx| {
                    const p = src[sy * src_w + sx];
                    r_sum += p.r;
                    g_sum += p.g;
                    b_sum += p.b;
                    a_sum += p.a;
                    count += 1;
                }
            }

            dst[dy * dst_w + dx] = .{
                .r = @intCast(r_sum / count),
                .g = @intCast(g_sum / count),
                .b = @intCast(b_sum / count),
                .a = @intCast(a_sum / count),
            };
        }
    }
}

test "downsampleRgba32 test" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const src = try gpa.alloc(zigimg.color.Rgba32, 4 * 4);
    defer gpa.free(src);
    for (src, 0..) |*p, i| {
        p.* = .{ .r = @truncate(i * 10), .g = 100, .b = 200, .a = 255 };
    }

    const dst = try gpa.alloc(zigimg.color.Rgba32, 2 * 2);
    defer gpa.free(dst);

    downsampleRgba32(src, 4, 4, dst, 2, 2);
    try testing.expectEqual(@as(u8, 100), dst[0].g);
    try testing.expectEqual(@as(u8, 200), dst[0].b);
    try testing.expectEqual(@as(u8, 255), dst[0].a);
}

test "zigimg in-memory image create and write" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var img = try zigimg.Image.create(gpa, 16, 16, .rgba32);
    defer img.deinit(gpa);
    @memset(img.pixels.rgba32, .{ .r = 255, .g = 0, .b = 0, .a = 255 });

    const write_buf = try gpa.alloc(u8, 4096);
    defer gpa.free(write_buf);
    const encoded = try img.writeToMemory(gpa, write_buf, .{ .png = .{} });
    try testing.expect(encoded.len > 0);

    // Read back
    var read_back = try zigimg.Image.fromMemory(gpa, encoded);
    defer read_back.deinit(gpa);
    try testing.expectEqual(@as(usize, 16), read_back.width);
    try testing.expectEqual(@as(usize, 16), read_back.height);
}
