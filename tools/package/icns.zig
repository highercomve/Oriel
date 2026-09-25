//! macOS ICNS file format writer.
//!
//! Packs the already-resized PNG icons into one .icns with PNG entries
//! (supported since OS X 10.7), so no `iconutil` is needed and the icon can
//! be made on any host. Each size is stored under its 1x type and, where
//! one exists, the 2x (Retina) type of half its size.

const std = @import("std");

/// One PNG image of a square icon size.
pub const PngIconEntry = struct {
    size: u16,
    png_data: []const u8,
};

/// ICNS element types that hold a PNG of a given pixel size.
const Slot = struct { size: u16, type: *const [4]u8 };
const slots = [_]Slot{
    .{ .size = 16, .type = "icp4" },
    .{ .size = 32, .type = "icp5" },
    .{ .size = 32, .type = "ic11" }, // 16@2x
    .{ .size = 64, .type = "icp6" },
    .{ .size = 64, .type = "ic12" }, // 32@2x
    .{ .size = 128, .type = "ic07" },
    .{ .size = 256, .type = "ic08" },
    .{ .size = 256, .type = "ic13" }, // 128@2x
    .{ .size = 512, .type = "ic09" },
    .{ .size = 512, .type = "ic14" }, // 256@2x
    .{ .size = 1024, .type = "ic10" }, // 512@2x
};

/// The icon sizes an .icns can use (the others in `entries` are skipped).
pub const icns_sizes = [_]u16{ 16, 32, 64, 128, 256, 512, 1024 };

/// Write an ICNS file from PNG images; the caller owns the result.
pub fn writeIcnsFromPngs(allocator: std.mem.Allocator, entries: []const PngIconEntry) ![]u8 {
    var total: usize = 8;
    var count: usize = 0;
    for (slots) |slot| {
        const entry = find(entries, slot.size) orelse continue;
        total += 8 + entry.png_data.len;
        count += 1;
    }
    if (count == 0) return error.NoImages;
    if (total > std.math.maxInt(u32)) return error.IconTooLarge;

    const buf = try allocator.alloc(u8, total);
    errdefer allocator.free(buf);
    @memcpy(buf[0..4], "icns");
    std.mem.writeInt(u32, buf[4..8], @intCast(total), .big);
    var off: usize = 8;
    for (slots) |slot| {
        const entry = find(entries, slot.size) orelse continue;
        @memcpy(buf[off..][0..4], slot.type);
        std.mem.writeInt(u32, buf[off + 4 ..][0..4], @intCast(8 + entry.png_data.len), .big);
        @memcpy(buf[off + 8 ..][0..entry.png_data.len], entry.png_data);
        off += 8 + entry.png_data.len;
    }
    std.debug.assert(off == total);
    return buf;
}

fn find(entries: []const PngIconEntry, size: u16) ?PngIconEntry {
    for (entries) |e| if (e.size == size) return e;
    return null;
}

test writeIcnsFromPngs {
    const a = std.testing.allocator;
    const out = try writeIcnsFromPngs(a, &.{
        .{ .size = 16, .png_data = "AAAA" },
        .{ .size = 32, .png_data = "BB" },
        .{ .size = 48, .png_data = "skipped" },
    });
    defer a.free(out);
    // header 8 + icp4 (8+4) + icp5 (8+2) + ic11 (8+2)
    try std.testing.expectEqual(@as(usize, 40), out.len);
    try std.testing.expectEqualStrings("icns", out[0..4]);
    try std.testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, out[4..8], .big));
    try std.testing.expectEqualStrings("icp4", out[8..12]);
    try std.testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, out[12..16], .big));
    try std.testing.expectEqualStrings("AAAA", out[16..20]);
    try std.testing.expectEqualStrings("icp5", out[20..24]);
    try std.testing.expectEqualStrings("ic11", out[30..34]);
    try std.testing.expectError(error.NoImages, writeIcnsFromPngs(a, &.{.{ .size = 48, .png_data = "x" }}));
}
