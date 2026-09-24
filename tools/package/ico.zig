//! Windows ICO file format writer.
//!
//! Packs the already-resized PNG icons into one multi-resolution .ico with
//! PNG-compressed entries (read by Windows Vista and later, Explorer and NSIS).

const std = @import("std");

/// One PNG image of a square icon size.
pub const PngIconEntry = struct {
    width: u16,
    height: u16,
    png_data: []const u8,
};

/// Default icon resolutions included in a standard Windows application icon.
pub const default_ico_sizes = [_]u16{ 16, 32, 48, 64, 128, 256 };

/// Write an ICO file containing PNG-compressed images; the caller owns the result.
pub fn writeIcoFromPngs(allocator: std.mem.Allocator, entries: []const PngIconEntry) ![]u8 {
    if (entries.len == 0) return error.NoImages;
    if (entries.len > std.math.maxInt(u16)) return error.TooManyImages;

    var total_size: usize = 6 + entries.len * 16;
    for (entries) |entry| {
        total_size += entry.png_data.len;
    }

    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    // 1. Write ICONDIR header (6 bytes)
    std.mem.writeInt(u16, buf[0..2], 0, .little); // idReserved = 0
    std.mem.writeInt(u16, buf[2..4], 1, .little); // idType = 1 (icon)
    std.mem.writeInt(u16, buf[4..6], @intCast(entries.len), .little); // idCount

    // 2. Write ICONDIRENTRY (16 bytes per image)
    var offset: u32 = @intCast(6 + entries.len * 16);
    for (entries, 0..) |entry, i| {
        const entry_offset = 6 + i * 16;
        const bw: u8 = if (entry.width >= 256) 0 else @intCast(entry.width);
        const bh: u8 = if (entry.height >= 256) 0 else @intCast(entry.height);

        buf[entry_offset + 0] = bw;
        buf[entry_offset + 1] = bh;
        buf[entry_offset + 2] = 0; // color count (0 for >= 8bpp)
        buf[entry_offset + 3] = 0; // reserved
        std.mem.writeInt(u16, buf[entry_offset + 4 ..][0..2], 1, .little); // planes
        std.mem.writeInt(u16, buf[entry_offset + 6 ..][0..2], 32, .little); // bit count
        std.mem.writeInt(u32, buf[entry_offset + 8 ..][0..4], @intCast(entry.png_data.len), .little);
        std.mem.writeInt(u32, buf[entry_offset + 12 ..][0..4], offset, .little);

        // 3. Write image payload
        @memcpy(buf[offset .. offset + entry.png_data.len], entry.png_data);
        offset += @intCast(entry.png_data.len);
    }

    return buf;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test {
    std.testing.refAllDecls(@This());
}

test "writeIcoFromPngs creates valid ICO structure" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const dummy_png_16 = [_]u8{ 0x89, 'P', 'N', 'G', 1, 2, 3, 4 };
    const dummy_png_32 = [_]u8{ 0x89, 'P', 'N', 'G', 5, 6, 7, 8, 9 };

    const entries = [_]PngIconEntry{
        .{ .width = 16, .height = 16, .png_data = &dummy_png_16 },
        .{ .width = 32, .height = 32, .png_data = &dummy_png_32 },
    };

    const ico_bytes = try writeIcoFromPngs(gpa, &entries);
    defer gpa.free(ico_bytes);

    // Verify ICONDIR
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, ico_bytes[0..2], .little)); // reserved
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ico_bytes[2..4], .little)); // type
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, ico_bytes[4..6], .little)); // count

    // Entry 0
    try testing.expectEqual(@as(u8, 16), ico_bytes[6]); // width
    try testing.expectEqual(@as(u8, 16), ico_bytes[7]); // height
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, ico_bytes[14..18], .little)); // size
    try testing.expectEqual(@as(u32, 38), std.mem.readInt(u32, ico_bytes[18..22], .little)); // offset (6 + 32 = 38)

    // Entry 1
    try testing.expectEqual(@as(u8, 32), ico_bytes[22]); // width
    try testing.expectEqual(@as(u8, 32), ico_bytes[23]); // height
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, ico_bytes[30..34], .little)); // size
    try testing.expectEqual(@as(u32, 46), std.mem.readInt(u32, ico_bytes[34..38], .little)); // offset (38 + 8 = 46)

    // Payloads
    try testing.expectEqualSlices(u8, &dummy_png_16, ico_bytes[38..46]);
    try testing.expectEqualSlices(u8, &dummy_png_32, ico_bytes[46..55]);
}
