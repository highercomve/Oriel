//! Common types and text truncation helpers for notifications.

const std = @import("std");

pub const NotificationOptions = struct {
    id: ?[]const u8 = null,
    title: []const u8,
    body: ?[]const u8 = null,
};

/// Truncate UTF-8 string `input` so that its UTF-16 representation has at most `max_wchars` WCHARs,
/// without splitting any UTF-16 surrogate pairs.
/// Writes to `out_w` (which must have capacity for at least `max_wchars + 1` for null-termination)
/// and returns the number of WCHARs written (excluding null terminator).
pub fn truncateUtf8ToUtf16(input: []const u8, out_w: []u16, max_wchars: usize) usize {
    if (out_w.len == 0) return 0;
    const limit = @min(max_wchars, out_w.len - 1);

    const view = std.unicode.Utf8View.init(input) catch {
        var count: usize = 0;
        for (input) |b| {
            if (count >= limit) break;
            out_w[count] = @as(u16, b);
            count += 1;
        }
        out_w[count] = 0;
        return count;
    };

    var it = view.iterator();
    var count: usize = 0;
    while (it.nextCodepoint()) |cp| {
        if (cp <= 0xFFFF) {
            if (count + 1 > limit) break;
            out_w[count] = @intCast(cp);
            count += 1;
        } else {
            // Needs a surrogate pair: 2 WCHARs
            if (count + 2 > limit) break;
            const high: u16 = @intCast(0xD800 + ((cp - 0x10000) >> 10));
            const low: u16 = @intCast(0xDC00 + ((cp - 0x10000) & 0x3FF));
            out_w[count] = high;
            out_w[count + 1] = low;
            count += 2;
        }
    }
    out_w[count] = 0;
    return count;
}

test "truncateUtf8ToUtf16: basic ascii and boundaries" {
    var buf: [64]u16 = undefined;

    // Empty
    const n0 = truncateUtf8ToUtf16("", &buf, 63);
    try std.testing.expectEqual(@as(usize, 0), n0);
    try std.testing.expectEqual(@as(u16, 0), buf[0]);

    // Short string within limit
    const n1 = truncateUtf8ToUtf16("Hello", &buf, 63);
    try std.testing.expectEqual(@as(usize, 5), n1);
    try std.testing.expectEqual(@as(u16, 'H'), buf[0]);
    try std.testing.expectEqual(@as(u16, 0), buf[5]);

    // Truncated at exact limit
    const n2 = truncateUtf8ToUtf16("1234567890", &buf, 5);
    try std.testing.expectEqual(@as(usize, 5), n2);
    try std.testing.expectEqual(@as(u16, '5'), buf[4]);
    try std.testing.expectEqual(@as(u16, 0), buf[5]);
}

test "truncateUtf8ToUtf16: multibyte BMP characters" {
    var buf: [64]u16 = undefined;

    // Spanish ñ, Greek Ω, Chinese 你
    const text = "ñΩ你好";
    const n = truncateUtf8ToUtf16(text, &buf, 3);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u16, 0x00F1), buf[0]); // ñ
    try std.testing.expectEqual(@as(u16, 0x03A9), buf[1]); // Ω
    try std.testing.expectEqual(@as(u16, 0x4F60), buf[2]); // 你
    try std.testing.expectEqual(@as(u16, 0), buf[3]);
}

test "truncateUtf8ToUtf16: surrogate pair boundary protection" {
    var buf: [64]u16 = undefined;

    // "abcd🎉" - 'abcd' is 4 WCHARs. '🎉' (U+1F389) needs 2 WCHARs.
    // If limit is 5 WCHARs, only 1 slot is left, which is not enough for the surrogate pair.
    // The helper must NOT write an orphan high surrogate.
    const text = "abcd🎉efgh";
    const n = truncateUtf8ToUtf16(text, &buf, 5);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u16, 'd'), buf[3]);
    try std.testing.expectEqual(@as(u16, 0), buf[4]);

    // If limit is 6 WCHARs, the surrogate pair fits completely.
    const n2 = truncateUtf8ToUtf16(text, &buf, 6);
    try std.testing.expectEqual(@as(usize, 6), n2);
    // U+1F389: high = 0xD83C, low = 0xDF89
    try std.testing.expectEqual(@as(u16, 0xD83C), buf[4]);
    try std.testing.expectEqual(@as(u16, 0xDF89), buf[5]);
    try std.testing.expectEqual(@as(u16, 0), buf[6]);
}
