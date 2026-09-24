//! Platform-independent DIB <-> RGBA conversion and clipboard data models.
//!
//! Windows clipboard formats images as DIB (Device Independent Bitmap) or DIBV5,
//! which start with a BITMAPINFOHEADER (or BITMAPV5HEADER) and contain bottom-up
//! (or top-down) BGR/BGRA rows padded to 4-byte boundaries.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");

pub const RgbaImage = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA bytes, length = width * height * 4

    pub fn deinit(self: *RgbaImage, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
        self.* = undefined;
    }
};

fn extractChannel(val: u32, mask: u32) u8 {
    if (mask == 0) return 0;
    const shift = @ctz(mask);
    const shifted = (val & mask) >> @intCast(shift);
    const max_val = mask >> @intCast(shift);
    if (max_val == 0) return 0;
    if (max_val == 255) return @intCast(shifted);
    return @intCast((shifted * 255 + max_val / 2) / max_val);
}

/// Convert Windows DIB bytes (CF_DIB or CF_DIBV5) into standard RGBA32 pixels.
/// Supports top-down and bottom-up bitmaps, 24 bpp and 32 bpp, stride padding,
/// and BI_BITFIELDS masks. Safely validates headers to prevent out-of-bounds reads.
pub fn dibToRgba(gpa: std.mem.Allocator, dib_bytes: []const u8) !RgbaImage {
    if (dib_bytes.len < 40) return error.InvalidDibHeader;

    const biSize = std.mem.readInt(u32, dib_bytes[0..4], .little);
    if (biSize < 40 or biSize > dib_bytes.len) return error.InvalidDibHeader;

    const raw_width = std.mem.readInt(i32, dib_bytes[4..8], .little);
    const raw_height = std.mem.readInt(i32, dib_bytes[8..12], .little);
    const biPlanes = std.mem.readInt(u16, dib_bytes[12..14], .little);
    const biBitCount = std.mem.readInt(u16, dib_bytes[14..16], .little);
    const biCompression = std.mem.readInt(u32, dib_bytes[16..20], .little);
    const biClrUsed = std.mem.readInt(u32, dib_bytes[32..36], .little);

    if (raw_width <= 0 or raw_height == 0 or raw_height == std.math.minInt(i32)) {
        return error.InvalidDimensions;
    }
    const width: u32 = @intCast(raw_width);
    const is_top_down = raw_height < 0;
    const height: u32 = if (is_top_down) @intCast(-raw_height) else @intCast(raw_height);

    const max_dimension: u32 = 32768;
    if (width > max_dimension or height > max_dimension) return error.InvalidDimensions;

    if (biPlanes != 1) return error.UnsupportedFormat;
    if (biBitCount != 24 and biBitCount != 32) return error.UnsupportedFormat;

    var r_mask: u32 = 0;
    var g_mask: u32 = 0;
    var b_mask: u32 = 0;
    var a_mask: u32 = 0;
    var masks_offset: usize = 0;
    var masks_in_header = false;

    switch (biCompression) {
        win32.BI_RGB => {
            if (biBitCount == 32) {
                r_mask = 0x00FF0000;
                g_mask = 0x0000FF00;
                b_mask = 0x000000FF;
                a_mask = 0xFF000000;
            }
        },
        win32.BI_BITFIELDS => {
            if (biBitCount != 32) return error.UnsupportedCompression;
            if (biSize == 40) {
                if (dib_bytes.len < 40 + 12) return error.TruncatedData;
                r_mask = std.mem.readInt(u32, dib_bytes[40..44], .little);
                g_mask = std.mem.readInt(u32, dib_bytes[44..48], .little);
                b_mask = std.mem.readInt(u32, dib_bytes[48..52], .little);
                masks_offset = 12;
            } else if (biSize >= 56) {
                // V4 or V5 header contains masks directly at offset 40..56
                r_mask = std.mem.readInt(u32, dib_bytes[40..44], .little);
                g_mask = std.mem.readInt(u32, dib_bytes[44..48], .little);
                b_mask = std.mem.readInt(u32, dib_bytes[48..52], .little);
                a_mask = std.mem.readInt(u32, dib_bytes[52..56], .little);
                masks_in_header = true;
            } else {
                return error.UnsupportedFormat;
            }
            if (r_mask == 0 or g_mask == 0 or b_mask == 0) return error.InvalidBitmasks;
        },
        else => return error.UnsupportedCompression,
    }

    const color_table_bytes = std.math.mul(usize, biClrUsed, 4) catch return error.InvalidDibHeader;
    const header_and_meta = biSize + (if (masks_in_header) @as(usize, 0) else masks_offset) + color_table_bytes;
    if (header_and_meta > dib_bytes.len) return error.TruncatedData;
    const pixel_offset = header_and_meta;

    const bits_per_row = std.math.mul(usize, width, biBitCount) catch return error.InvalidDimensions;
    const row_stride = ((bits_per_row + 31) / 32) * 4;
    const total_pixel_bytes = std.math.mul(usize, row_stride, height) catch return error.InvalidDimensions;
    if (dib_bytes.len < pixel_offset + total_pixel_bytes) return error.TruncatedData;

    const num_pixels = std.math.mul(usize, width, height) catch return error.InvalidDimensions;
    const out_bytes_len = std.math.mul(usize, num_pixels, 4) catch return error.InvalidDimensions;
    const out_pixels = try gpa.alloc(u8, out_bytes_len);
    errdefer gpa.free(out_pixels);

    if (biBitCount == 24) {
        for (0..height) |y| {
            const dib_y = if (is_top_down) y else (height - 1 - y);
            const dib_row_start = pixel_offset + dib_y * row_stride;
            const out_row_start = y * width * 4;
            for (0..width) |x| {
                const dib_px = dib_row_start + x * 3;
                const b = dib_bytes[dib_px + 0];
                const g = dib_bytes[dib_px + 1];
                const r = dib_bytes[dib_px + 2];
                const out_px = out_row_start + x * 4;
                out_pixels[out_px + 0] = r;
                out_pixels[out_px + 1] = g;
                out_pixels[out_px + 2] = b;
                out_pixels[out_px + 3] = 255;
            }
        }
    } else { // 32 bpp
        if (biCompression == win32.BI_RGB) {
            var has_nonzero_alpha = false;
            for (0..height) |y| {
                const dib_y = if (is_top_down) y else (height - 1 - y);
                const dib_row_start = pixel_offset + dib_y * row_stride;
                for (0..width) |x| {
                    if (dib_bytes[dib_row_start + x * 4 + 3] != 0) {
                        has_nonzero_alpha = true;
                        break;
                    }
                }
                if (has_nonzero_alpha) break;
            }

            for (0..height) |y| {
                const dib_y = if (is_top_down) y else (height - 1 - y);
                const dib_row_start = pixel_offset + dib_y * row_stride;
                const out_row_start = y * width * 4;
                for (0..width) |x| {
                    const dib_px = dib_row_start + x * 4;
                    const b = dib_bytes[dib_px + 0];
                    const g = dib_bytes[dib_px + 1];
                    const r = dib_bytes[dib_px + 2];
                    const a = if (has_nonzero_alpha) dib_bytes[dib_px + 3] else 255;
                    const out_px = out_row_start + x * 4;
                    out_pixels[out_px + 0] = r;
                    out_pixels[out_px + 1] = g;
                    out_pixels[out_px + 2] = b;
                    out_pixels[out_px + 3] = a;
                }
            }
        } else { // BI_BITFIELDS
            var has_nonzero_alpha = false;
            if (a_mask != 0) {
                for (0..height) |y| {
                    const dib_y = if (is_top_down) y else (height - 1 - y);
                    const dib_row_start = pixel_offset + dib_y * row_stride;
                    for (0..width) |x| {
                        const dib_px = dib_row_start + x * 4;
                        const val = std.mem.readInt(u32, dib_bytes[dib_px..][0..4], .little);
                        if (extractChannel(val, a_mask) != 0) {
                            has_nonzero_alpha = true;
                            break;
                        }
                    }
                    if (has_nonzero_alpha) break;
                }
            }

            for (0..height) |y| {
                const dib_y = if (is_top_down) y else (height - 1 - y);
                const dib_row_start = pixel_offset + dib_y * row_stride;
                const out_row_start = y * width * 4;
                for (0..width) |x| {
                    const dib_px = dib_row_start + x * 4;
                    const val = std.mem.readInt(u32, dib_bytes[dib_px..][0..4], .little);
                    const r = extractChannel(val, r_mask);
                    const g = extractChannel(val, g_mask);
                    const b = extractChannel(val, b_mask);
                    const a = if (a_mask != 0 and has_nonzero_alpha) extractChannel(val, a_mask) else 255;
                    const out_px = out_row_start + x * 4;
                    out_pixels[out_px + 0] = r;
                    out_pixels[out_px + 1] = g;
                    out_pixels[out_px + 2] = b;
                    out_pixels[out_px + 3] = a;
                }
            }
        }
    }

    return RgbaImage{
        .width = width,
        .height = height,
        .pixels = out_pixels,
    };
}

/// Convert RGBA pixels into standard Windows 32 bpp bottom-up DIB (BITMAPINFOHEADER + BGRA).
pub fn rgbaToDib(gpa: std.mem.Allocator, width: u32, height: u32, rgba_pixels: []const u8) ![]u8 {
    if (width == 0 or height == 0 or width > 32768 or height > 32768) return error.InvalidDimensions;
    const expected_len = std.math.mul(usize, @as(usize, width) * @as(usize, height), 4) catch return error.InvalidDimensions;
    if (rgba_pixels.len != expected_len) return error.InvalidDimensions;

    const bpp: usize = 32;
    const stride = ((@as(usize, width) * bpp + 31) / 32) * 4;
    const pixel_data_len = stride * height;
    const header_len: usize = 40;
    const total_len = header_len + pixel_data_len;

    const dib = try gpa.alloc(u8, total_len);
    errdefer gpa.free(dib);

    // BITMAPINFOHEADER (40 bytes)
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], @intCast(width), .little);
    std.mem.writeInt(i32, dib[8..12], @intCast(height), .little); // positive = bottom-up
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    std.mem.writeInt(u32, dib[16..20], win32.BI_RGB, .little);
    std.mem.writeInt(u32, dib[20..24], @intCast(pixel_data_len), .little);
    std.mem.writeInt(i32, dib[24..28], 0, .little);
    std.mem.writeInt(i32, dib[28..32], 0, .little);
    std.mem.writeInt(u32, dib[32..36], 0, .little);
    std.mem.writeInt(u32, dib[36..40], 0, .little);

    for (0..height) |y| {
        const dest_y = height - 1 - y;
        const src_row = y * width * 4;
        const dest_row = header_len + dest_y * stride;
        for (0..width) |x| {
            const src_px = src_row + x * 4;
            const dest_px = dest_row + x * 4;
            dib[dest_px + 0] = rgba_pixels[src_px + 2]; // B
            dib[dest_px + 1] = rgba_pixels[src_px + 1]; // G
            dib[dest_px + 2] = rgba_pixels[src_px + 0]; // R
            dib[dest_px + 3] = rgba_pixels[src_px + 3]; // A
        }
    }

    return dib;
}

/// Trims trailing padding bytes from raw clipboard memory containing PNG data.
/// GlobalSize rounds up to heap allocation granularity, so clipboard data for the
/// registered "PNG" format may contain trailing garbage bytes past the PNG IEND chunk.
/// The PNG specification requires an IEND chunk consisting of:
/// - 4 bytes length (0)
/// - 4 bytes chunk type ("IEND")
/// - 4 bytes CRC
/// This function finds the "IEND" marker and trims the slice to end after the CRC (8 bytes after "IEND").
/// If no valid IEND marker is found or the data is not a PNG, returns the original slice.
pub fn trimPngPadding(data: []const u8) []const u8 {
    const png_magic = "\x89PNG\r\n\x1a\n";
    if (data.len < png_magic.len or !std.mem.startsWith(u8, data, png_magic)) {
        return data;
    }
    const marker = "IEND";
    if (std.mem.indexOf(u8, data, marker)) |idx| {
        const end = idx + marker.len + 4; // 4 bytes marker + 4 bytes CRC
        if (end <= data.len) {
            return data[0..end];
        }
    }
    return data;
}

test "rgbaToDib roundtrip 32 bpp bottom-up" {
    const gpa = std.testing.allocator;
    const w = 3;
    const h = 2;
    // 3x2 image with distinct colors
    const src_rgba = [_]u8{
        255, 0,   0,   255, // (0,0) Red
        0,   255, 0,   255, // (1,0) Green
        0,   0,   255, 255, // (2,0) Blue
        255, 255, 0,   200, // (0,1) Yellow
        255, 0,   255, 150, // (1,1) Magenta
        0,   255, 255, 100, // (2,1) Cyan
    };

    const dib = try rgbaToDib(gpa, w, h, &src_rgba);
    defer gpa.free(dib);

    var img = try dibToRgba(gpa, dib);
    defer img.deinit(gpa);

    try std.testing.expectEqual(@as(u32, w), img.width);
    try std.testing.expectEqual(@as(u32, h), img.height);
    try std.testing.expectEqualSlices(u8, &src_rgba, img.pixels);
}

test "dibToRgba 24 bpp bottom-up with stride padding" {
    const gpa = std.testing.allocator;
    // Width 3: 3 * 3 = 9 bytes per row, stride must be 12 (3 bytes padding per row)
    const w = 3;
    const h = 2;
    var dib: [40 + 2 * 12]u8 = undefined;
    @memset(&dib, 0);

    // BITMAPINFOHEADER (40 bytes)
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], w, .little);
    std.mem.writeInt(i32, dib[8..12], h, .little); // bottom-up
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 24, .little);
    std.mem.writeInt(u32, dib[16..20], win32.BI_RGB, .little);
    std.mem.writeInt(u32, dib[20..24], 24, .little);

    // Row 0 (bottom row in image, bottom-up):
    // Pixel (0,1): R=70, G=80, B=90 -> BGR: 90, 80, 70
    // Pixel (1,1): R=100, G=110, B=120 -> BGR: 120, 110, 100
    // Pixel (2,1): R=130, G=140, B=150 -> BGR: 150, 140, 130
    dib[40..49].* = .{ 90, 80, 70, 120, 110, 100, 150, 140, 130 };
    // 3 bytes padding (49..52) already zero

    // Row 1 (top row in image):
    // Pixel (0,0): R=255, G=10, B=20 -> BGR: 20, 10, 255
    // Pixel (1,0): R=30, G=255, B=40 -> BGR: 40, 255, 30
    // Pixel (2,0): R=50, G=60, B=255 -> BGR: 255, 60, 50
    dib[52..61].* = .{ 20, 10, 255, 40, 255, 30, 255, 60, 50 };
    // 3 bytes padding (61..64) already zero

    var img = try dibToRgba(gpa, &dib);
    defer img.deinit(gpa);

    try std.testing.expectEqual(@as(u32, w), img.width);
    try std.testing.expectEqual(@as(u32, h), img.height);

    const expected = [_]u8{
        255, 10,  20,  255,
        30,  255, 40,  255,
        50,  60,  255, 255,
        70,  80,  90,  255,
        100, 110, 120, 255,
        130, 140, 150, 255,
    };
    try std.testing.expectEqualSlices(u8, &expected, img.pixels);
}

test "rgbaToDib rejects oversized dimensions (> 32768)" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidDimensions, rgbaToDib(gpa, 32769, 1, &[_]u8{}));
    try std.testing.expectError(error.InvalidDimensions, rgbaToDib(gpa, 1, 32769, &[_]u8{}));
    try std.testing.expectError(error.InvalidDimensions, rgbaToDib(gpa, 0, 10, &[_]u8{}));
    try std.testing.expectError(error.InvalidDimensions, rgbaToDib(gpa, 10, 0, &[_]u8{}));
}

test "trimPngPadding trims trailing padding past IEND chunk" {
    // Valid PNG signature + dummy IEND chunk
    const fake_png = "\x89PNG\r\n\x1a\n" ++ "\x00\x00\x00\x00IEND\xaeB`\x82";
    const with_padding = fake_png ++ "\x00\x00\x00\x00\x00\x00";

    const trimmed = trimPngPadding(with_padding);
    try std.testing.expectEqual(fake_png.len, trimmed.len);
    try std.testing.expectEqualStrings(fake_png, trimmed);

    // Without padding stays unchanged
    try std.testing.expectEqualStrings(fake_png, trimPngPadding(fake_png));

    // Non-PNG data stays unchanged
    const not_png = "just some text";
    try std.testing.expectEqualStrings(not_png, trimPngPadding(not_png));
}

test "dibToRgba top-down 32 bpp" {
    const gpa = std.testing.allocator;
    const w = 2;
    const h = 2;
    var dib: [40 + 2 * 2 * 4]u8 = undefined;
    @memset(&dib, 0);

    // BITMAPINFOHEADER with negative biHeight = top-down
    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], w, .little);
    std.mem.writeInt(i32, dib[8..12], -h, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    std.mem.writeInt(u32, dib[16..20], win32.BI_RGB, .little);
    std.mem.writeInt(u32, dib[20..24], 16, .little);

    // Row 0 (top row): Pixel 0 = Red (BGRA: 0, 0, 255, 255), Pixel 1 = Blue (255, 0, 0, 255)
    dib[40..48].* = .{ 0, 0, 255, 255, 255, 0, 0, 255 };
    // Row 1 (bottom row): Pixel 0 = Green (0, 255, 0, 255), Pixel 1 = White (255, 255, 255, 255)
    dib[48..56].* = .{ 0, 255, 0, 255, 255, 255, 255, 255 };

    var img = try dibToRgba(gpa, &dib);
    defer img.deinit(gpa);

    const expected = [_]u8{
        255, 0,   0,   255, // top-left Red
        0,   0,   255, 255, // top-right Blue
        0,   255, 0,   255, // bottom-left Green
        255, 255, 255, 255, // bottom-right White
    };
    try std.testing.expectEqualSlices(u8, &expected, img.pixels);
}

test "dibToRgba BI_BITFIELDS masks with standard header" {
    const gpa = std.testing.allocator;
    const w = 1;
    const h = 1;
    // 40 byte header + 12 byte masks (R, G, B) + 4 bytes pixel
    var dib: [40 + 12 + 4]u8 = undefined;
    @memset(&dib, 0);

    std.mem.writeInt(u32, dib[0..4], 40, .little);
    std.mem.writeInt(i32, dib[4..8], w, .little);
    std.mem.writeInt(i32, dib[8..12], h, .little); // bottom-up
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    std.mem.writeInt(u32, dib[16..20], win32.BI_BITFIELDS, .little);

    // Masks: R=0x00FF0000, G=0x0000FF00, B=0x000000FF
    std.mem.writeInt(u32, dib[40..44], 0x00FF0000, .little);
    std.mem.writeInt(u32, dib[44..48], 0x0000FF00, .little);
    std.mem.writeInt(u32, dib[48..52], 0x000000FF, .little);

    // Pixel: 0x00AABBCC (R=AA, G=BB, B=CC)
    std.mem.writeInt(u32, dib[52..56], 0x00AABBCC, .little);

    var img = try dibToRgba(gpa, &dib);
    defer img.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 0xAA), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 0xBB), img.pixels[1]);
    try std.testing.expectEqual(@as(u8, 0xCC), img.pixels[2]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels[3]);
}

test "dibToRgba BI_BITFIELDS with V5 header and alpha mask" {
    const gpa = std.testing.allocator;
    const w = 1;
    const h = 1;
    // 124 byte V5 header + 4 byte pixel
    var dib: [124 + 4]u8 = undefined;
    @memset(&dib, 0);

    std.mem.writeInt(u32, dib[0..4], 124, .little);
    std.mem.writeInt(i32, dib[4..8], w, .little);
    std.mem.writeInt(i32, dib[8..12], h, .little);
    std.mem.writeInt(u16, dib[12..14], 1, .little);
    std.mem.writeInt(u16, dib[14..16], 32, .little);
    std.mem.writeInt(u32, dib[16..20], win32.BI_BITFIELDS, .little);

    // Masks inside V5 header at offset 40..56
    // R mask
    std.mem.writeInt(u32, dib[40..44], 0x000000FF, .little);
    // G mask
    std.mem.writeInt(u32, dib[44..48], 0x0000FF00, .little);
    // B mask
    std.mem.writeInt(u32, dib[48..52], 0x00FF0000, .little);
    // Alpha mask
    std.mem.writeInt(u32, dib[52..56], 0xFF000000, .little);

    // Pixel: R=10, G=20, B=30, A=40 (little endian: 10, 20, 30, 40)
    dib[124..128].* = .{ 10, 20, 30, 40 };

    var img = try dibToRgba(gpa, &dib);
    defer img.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 10), img.pixels[0]);
    try std.testing.expectEqual(@as(u8, 20), img.pixels[1]);
    try std.testing.expectEqual(@as(u8, 30), img.pixels[2]);
    try std.testing.expectEqual(@as(u8, 40), img.pixels[3]);
}

test "dibToRgba rejects malformed and truncated headers safely" {
    const gpa = std.testing.allocator;

    // Less than 40 bytes
    try std.testing.expectError(error.InvalidDibHeader, dibToRgba(gpa, "short"));

    // biSize less than 40
    var buf40: [40]u8 = undefined;
    @memset(&buf40, 0);
    std.mem.writeInt(u32, buf40[0..4], 30, .little);
    try std.testing.expectError(error.InvalidDibHeader, dibToRgba(gpa, &buf40));

    // biSize larger than buffer length
    std.mem.writeInt(u32, buf40[0..4], 80, .little);
    try std.testing.expectError(error.InvalidDibHeader, dibToRgba(gpa, &buf40));

    // Invalid width / height
    std.mem.writeInt(u32, buf40[0..4], 40, .little);
    std.mem.writeInt(i32, buf40[4..8], 0, .little); // width 0
    std.mem.writeInt(i32, buf40[8..12], 10, .little);
    try std.testing.expectError(error.InvalidDimensions, dibToRgba(gpa, &buf40));

    std.mem.writeInt(i32, buf40[4..8], 10, .little);
    std.mem.writeInt(i32, buf40[8..12], 0, .little); // height 0
    try std.testing.expectError(error.InvalidDimensions, dibToRgba(gpa, &buf40));

    // Truncated pixel data
    std.mem.writeInt(i32, buf40[4..8], 100, .little);
    std.mem.writeInt(i32, buf40[8..12], 100, .little);
    std.mem.writeInt(u16, buf40[12..14], 1, .little);
    std.mem.writeInt(u16, buf40[14..16], 32, .little);
    try std.testing.expectError(error.TruncatedData, dibToRgba(gpa, &buf40));
}
