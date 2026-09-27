//! macOS ICNS file format writer.
//!
//! Packs the already-resized icons into one .icns, so no `iconutil` is
//! needed and the icon can be made on any host. Like `iconutil`:
//! - 16x16 and 32x32 are `ic04` / `ic05`: raw "ARGB" planes, each compressed
//!   with the icns run-length encoding (`argbElement`). macOS draws PNGs in
//!   the old small slots (`icp4`, `icp5`, `icp6`) garbled at list sizes (the
//!   Accessibility list, open panels), so those slots aren't used.
//! - every other size is a PNG entry (supported since OS X 10.7), under its
//!   1x type and, where one exists, the 2x (Retina) type of half its size.

const std = @import("std");

/// One PNG image of a square icon size.
pub const PngIconEntry = struct {
    size: u16,
    png_data: []const u8,
};

/// One square icon as straight (not premultiplied) RGBA pixels, row by row.
pub const RgbaIconEntry = struct {
    size: u16,
    rgba: []const u8,
};

/// ICNS element types that hold a PNG of a given pixel size.
const Slot = struct { size: u16, type: *const [4]u8 };
const png_slots = [_]Slot{
    .{ .size = 32, .type = "ic11" }, // 16@2x
    .{ .size = 64, .type = "ic12" }, // 32@2x
    .{ .size = 128, .type = "ic07" },
    .{ .size = 256, .type = "ic08" },
    .{ .size = 256, .type = "ic13" }, // 128@2x
    .{ .size = 512, .type = "ic09" },
    .{ .size = 512, .type = "ic14" }, // 256@2x
    .{ .size = 1024, .type = "ic10" }, // 512@2x
};

/// ICNS element types that hold ARGB pixels of a given size.
const argb_slots = [_]Slot{
    .{ .size = 16, .type = "ic04" },
    .{ .size = 32, .type = "ic05" },
};

/// The icon sizes an .icns can use (the others in `entries` are skipped).
pub const icns_sizes = [_]u16{ 16, 32, 64, 128, 256, 512, 1024 };

/// The sizes `writeIcns` wants as RGBA pixels.
pub const argb_sizes = [_]u16{ 16, 32 };

/// Write an ICNS file from PNG images (the larger sizes) and RGBA pixels (16
/// and 32); the caller owns the result.
pub fn writeIcns(allocator: std.mem.Allocator, pngs: []const PngIconEntry, rgbas: []const RgbaIconEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "icns\x00\x00\x00\x00");
    var count: usize = 0;

    // In the order iconutil writes them: small ARGB first, then the PNGs.
    for (argb_slots) |slot| {
        const entry = findRgba(rgbas, slot.size) orelse continue;
        if (entry.rgba.len != @as(usize, slot.size) * slot.size * 4) return error.BadPixels;
        const start = out.items.len;
        try out.appendSlice(allocator, slot.type);
        try out.appendSlice(allocator, "\x00\x00\x00\x00");
        try out.appendSlice(allocator, "ARGB");
        for ([_]usize{ 3, 0, 1, 2 }) |channel| try packChannel(allocator, &out, entry.rgba, channel);
        try setLength(out.items[start + 4 ..][0..4], out.items.len - start);
        count += 1;
    }
    for (png_slots) |slot| {
        const entry = findPng(pngs, slot.size) orelse continue;
        const start = out.items.len;
        try out.appendSlice(allocator, slot.type);
        try out.appendSlice(allocator, "\x00\x00\x00\x00");
        try out.appendSlice(allocator, entry.png_data);
        try setLength(out.items[start + 4 ..][0..4], out.items.len - start);
        count += 1;
    }
    if (count == 0) return error.NoImages;
    try setLength(out.items[4..8], out.items.len);
    return out.toOwnedSlice(allocator);
}

fn setLength(dest: *[4]u8, len: usize) !void {
    std.mem.writeInt(u32, dest, std.math.cast(u32, len) orelse return error.IconTooLarge, .big);
}

/// One channel (0 R, 1 G, 2 B, 3 A) of `rgba`, run-length encoded the icns
/// way: a byte n < 0x80 is followed by n+1 literal bytes; a byte n >= 0x80
/// repeats the next byte n - 0x80 + 3 times (3..130).
fn packChannel(allocator: std.mem.Allocator, out: *std.ArrayList(u8), rgba: []const u8, channel: usize) !void {
    const n = rgba.len / 4;
    var i: usize = 0;
    while (i < n) {
        // A run of 3+ equal bytes?
        var run: usize = 1;
        while (i + run < n and run < 130 and rgba[(i + run) * 4 + channel] == rgba[i * 4 + channel]) run += 1;
        if (run >= 3) {
            try out.append(allocator, @intCast(0x80 + run - 3));
            try out.append(allocator, rgba[i * 4 + channel]);
            i += run;
            continue;
        }
        // Literals up to the next run of 3 (or 128 bytes).
        var len: usize = 0;
        while (i + len < n and len < 128) : (len += 1) {
            const k = i + len;
            if (k + 2 < n and rgba[k * 4 + channel] == rgba[(k + 1) * 4 + channel] and rgba[k * 4 + channel] == rgba[(k + 2) * 4 + channel]) break;
        }
        try out.append(allocator, @intCast(len - 1));
        for (0..len) |j| try out.append(allocator, rgba[(i + j) * 4 + channel]);
        i += len;
    }
}

/// Width and height from a PNG's IHDR chunk, or null if `data` isn't a PNG.
pub fn pngSize(data: []const u8) ?[2]u32 {
    const signature = "\x89PNG\r\n\x1a\n";
    if (data.len < 24 or !std.mem.eql(u8, data[0..8], signature) or !std.mem.eql(u8, data[12..16], "IHDR")) return null;
    return .{ std.mem.readInt(u32, data[16..20], .big), std.mem.readInt(u32, data[20..24], .big) };
}

fn findPng(entries: []const PngIconEntry, size: u16) ?PngIconEntry {
    for (entries) |e| if (e.size == size) return e;
    return null;
}

fn findRgba(entries: []const RgbaIconEntry, size: u16) ?RgbaIconEntry {
    for (entries) |e| if (e.size == size) return e;
    return null;
}

/// Decode one channel packed by `packChannel` (tests).
fn unpackChannel(data: []const u8, count: usize, out: []u8) !usize {
    var o: usize = 0;
    var j: usize = 0;
    while (o < count) {
        const b = data[j];
        j += 1;
        if (b < 0x80) {
            const len = @as(usize, b) + 1;
            @memcpy(out[o..][0..len], data[j..][0..len]);
            j += len;
            o += len;
        } else {
            const len = @as(usize, b) - 0x80 + 3;
            @memset(out[o..][0..len], data[j]);
            j += 1;
            o += len;
        }
    }
    if (o != count) return error.Overrun;
    return j;
}

test writeIcns {
    const a = std.testing.allocator;
    // 16x16: alpha 0 left half, 255 right half; colours varying per pixel.
    var px: [16 * 16 * 4]u8 = undefined;
    for (0..256) |p| {
        px[p * 4 + 0] = @intCast(p & 0xff);
        px[p * 4 + 1] = 7;
        px[p * 4 + 2] = @intCast((p / 3) & 0xff);
        px[p * 4 + 3] = if (p % 16 < 8) 0 else 255;
    }
    const out = try writeIcns(a, &.{
        .{ .size = 32, .png_data = "BB" },
        .{ .size = 48, .png_data = "skipped" },
    }, &.{.{ .size = 16, .rgba = &px }});
    defer a.free(out);
    try std.testing.expectEqualStrings("icns", out[0..4]);
    try std.testing.expectEqual(@as(u32, @intCast(out.len)), std.mem.readInt(u32, out[4..8], .big));
    // ic04 first, then ic11 (the 32 PNG as 16@2x); no icp4/icp5/icp6.
    try std.testing.expectEqualStrings("ic04", out[8..12]);
    const ic04_len = std.mem.readInt(u32, out[12..16], .big);
    try std.testing.expectEqualStrings("ARGB", out[16..20]);
    try std.testing.expectEqualStrings("ic11", out[8 + ic04_len ..][0..4]);
    try std.testing.expect(std.mem.indexOf(u8, out, "icp") == null);
    // The planes decode back to A, R, G, B.
    var plane: [256]u8 = undefined;
    var off: usize = 20;
    for ([_]usize{ 3, 0, 1, 2 }) |channel| {
        off += try unpackChannel(out[off..], 256, &plane);
        for (0..256) |p| try std.testing.expectEqual(px[p * 4 + channel], plane[p]);
    }
    try std.testing.expectEqual(@as(usize, 8 + ic04_len), off);
    try std.testing.expectError(error.NoImages, writeIcns(a, &.{.{ .size = 48, .png_data = "x" }}, &.{}));
    try std.testing.expectError(error.BadPixels, writeIcns(a, &.{}, &.{.{ .size = 16, .rgba = "short" }}));
}

test pngSize {
    const header = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x04\x00\x00\x00\x02\x00";
    try std.testing.expectEqual([2]u32{ 1024, 512 }, pngSize(header).?);
    try std.testing.expectEqual(@as(?[2]u32, null), pngSize("GIF89a-not-a-png-at-all!"));
}
