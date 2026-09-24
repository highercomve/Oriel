//! Pure HTTP Range parsing (RFC 9110 §14), MIME type table, and path sanitization.

const std = @import("std");

/// A byte range representing bytes `start` through `end` inclusive.
pub const Range = struct {
    start: u64,
    end: u64,

    /// Number of bytes in this range.
    pub fn length(self: Range) u64 {
        return self.end - self.start + 1;
    }
};

/// Result of parsing an HTTP `Range` header against a file of size `file_size`.
pub const RangeResult = union(enum) {
    /// Satisfiable range to serve with status 206 Partial Content.
    range: Range,
    /// Serve full body with status 200 OK (e.g. malformed or missing Range).
    full,
    /// Range cannot be satisfied; respond with status 416 Range Not Satisfiable.
    unsatisfiable,
};

/// Parses an HTTP `Range` header field against `file_size` according to RFC 9110 §14.
///
/// Supported forms:
/// - `bytes=a-b` -> range from byte `a` to byte `b` (clamped to `file_size - 1`)
/// - `bytes=a-` -> range from byte `a` to EOF (`file_size - 1`)
/// - `bytes=-n` -> suffix range of the last `n` bytes (clamped to 0..file_size - 1)
///
/// Behavior notes:
/// - If `file_size == 0`: any range is unsatisfiable.
/// - If `header` does not begin with `bytes=` or is malformed (overflow, invalid digits,
///   missing separator): the header is ignored and `.full` is returned.
/// - If `start >= file_size`, or suffix is 0 (`bytes=-0`), or `start > end`: `.unsatisfiable` is returned.
/// - If multiple ranges are specified (e.g. `bytes=0-1,5-6`), this server chooses the RFC 9110 §14.2
///   allowed option to serve only the first specified range as a single 206 response.
pub fn parseRange(header: []const u8, file_size: u64) RangeResult {
    if (file_size == 0) return .unsatisfiable;

    const trimmed = std.mem.trim(u8, header, " \t");
    // Header must start with "bytes" (case-insensitive)
    if (!std.ascii.startsWithIgnoreCase(trimmed, "bytes")) return .full;
    var rest = std.mem.trimStart(u8, trimmed[5..], " \t");
    if (rest.len == 0 or rest[0] != '=') return .full;
    rest = std.mem.trimStart(u8, rest[1..], " \t");

    // If multiple ranges exist (comma-separated), pick the first one per RFC 9110 §14.2.
    const spec = blk: {
        if (std.mem.indexOfScalar(u8, rest, ',')) |comma_idx| {
            break :blk std.mem.trim(u8, rest[0..comma_idx], " \t");
        }
        break :blk std.mem.trim(u8, rest, " \t");
    };

    const dash_idx = std.mem.indexOfScalar(u8, spec, '-') orelse return .full;
    const prefix = std.mem.trim(u8, spec[0..dash_idx], " \t");
    const suffix = std.mem.trim(u8, spec[dash_idx + 1 ..], " \t");

    if (prefix.len == 0) {
        // Suffix range: "bytes=-n"
        if (suffix.len == 0) return .full; // Malformed: just "bytes=-"
        const n = parseDigits(suffix) orelse return .full;
        if (n == 0) return .unsatisfiable; // RFC 9110: suffix length 0 is unsatisfiable
        if (n >= file_size) {
            return .{ .range = .{ .start = 0, .end = file_size - 1 } };
        }
        return .{ .range = .{ .start = file_size - n, .end = file_size - 1 } };
    }

    // Range with explicit start: "bytes=a-" or "bytes=a-b"
    const start = parseDigits(prefix) orelse return .full;
    if (suffix.len == 0) {
        // Open-ended: "bytes=a-"
        if (start >= file_size) return .unsatisfiable;
        return .{ .range = .{ .start = start, .end = file_size - 1 } };
    }

    // Range with start and end: "bytes=a-b"
    const end_raw = parseDigits(suffix) orelse return .full;
    if (start > end_raw) return .unsatisfiable;
    if (start >= file_size) return .unsatisfiable;
    const end = @min(end_raw, file_size - 1);
    return .{ .range = .{ .start = start, .end = end } };
}

/// RFC 9110 `1*DIGIT` as a u64; null for anything else (including the `+`
/// sign and `_` separators `std.fmt.parseUnsigned` accepts) or on overflow.
fn parseDigits(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    for (s) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseUnsigned(u64, s, 10) catch null;
}

/// Returns the MIME content-type string for a given file extension (with or without leading dot).
/// Falls back to `"application/octet-stream"`.
pub fn mimeForExtension(raw_ext: []const u8) [:0]const u8 {
    const ext = if (std.mem.startsWith(u8, raw_ext, ".")) raw_ext[1..] else raw_ext;

    if (std.ascii.eqlIgnoreCase(ext, "mp4")) return "video/mp4";
    if (std.ascii.eqlIgnoreCase(ext, "webm")) return "video/webm";
    if (std.ascii.eqlIgnoreCase(ext, "mkv")) return "video/x-matroska";
    if (std.ascii.eqlIgnoreCase(ext, "mov")) return "video/quicktime";
    if (std.ascii.eqlIgnoreCase(ext, "mp3")) return "audio/mpeg";
    if (std.ascii.eqlIgnoreCase(ext, "ogg")) return "audio/ogg";
    if (std.ascii.eqlIgnoreCase(ext, "oga")) return "audio/ogg";
    if (std.ascii.eqlIgnoreCase(ext, "ogv")) return "video/ogg";
    if (std.ascii.eqlIgnoreCase(ext, "opus")) return "audio/opus";
    if (std.ascii.eqlIgnoreCase(ext, "wav")) return "audio/wav";
    if (std.ascii.eqlIgnoreCase(ext, "flac")) return "audio/flac";
    if (std.ascii.eqlIgnoreCase(ext, "m4a")) return "audio/mp4";
    if (std.ascii.eqlIgnoreCase(ext, "aac")) return "audio/aac";
    if (std.ascii.eqlIgnoreCase(ext, "vtt")) return "text/vtt";
    if (std.ascii.eqlIgnoreCase(ext, "srt")) return "text/plain";
    if (std.ascii.eqlIgnoreCase(ext, "json")) return "application/json";
    if (std.ascii.eqlIgnoreCase(ext, "png")) return "image/png";
    if (std.ascii.eqlIgnoreCase(ext, "jpg") or std.ascii.eqlIgnoreCase(ext, "jpeg")) return "image/jpeg";
    if (std.ascii.eqlIgnoreCase(ext, "webp")) return "image/webp";

    return "application/octet-stream";
}

pub const SanitizeError = error{
    PathTraversal,
    NotFound,
    OutOfMemory,
};

/// Sanitizes a requested relative path against directory traversal.
///
/// Decodes percent-encoded characters, rejects NUL bytes (`\x00` and `%00`),
/// rejects backslashes (`\`), rejects absolute paths (starting with `/`),
/// and rejects any path containing `..` path segments.
/// Returns an owned slice containing the clean relative path.
pub fn sanitizePath(allocator: std.mem.Allocator, raw_path: []const u8) SanitizeError![]const u8 {
    if (raw_path.len == 0) return error.NotFound;

    // Reject absolute paths
    if (raw_path[0] == '/') return error.PathTraversal;

    // Reject backslashes
    if (std.mem.indexOfScalar(u8, raw_path, '\\') != null) return error.PathTraversal;

    // Reject embedded NUL
    if (std.mem.indexOfScalar(u8, raw_path, 0) != null) return error.PathTraversal;

    // Percent-decode
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(allocator);

    var i: usize = 0;
    while (i < raw_path.len) {
        if (raw_path[i] == '%') {
            if (i + 2 >= raw_path.len) return error.PathTraversal;
            const h1 = std.fmt.charToDigit(raw_path[i + 1], 16) catch return error.PathTraversal;
            const h2 = std.fmt.charToDigit(raw_path[i + 2], 16) catch return error.PathTraversal;
            const byte = (@as(u8, h1) << 4) | @as(u8, h2);
            if (byte == 0) return error.PathTraversal; // NUL byte (%00)
            try decoded.append(allocator, byte);
            i += 3;
        } else {
            try decoded.append(allocator, raw_path[i]);
            i += 1;
        }
    }

    const decoded_slice = decoded.items;
    if (decoded_slice.len == 0) return error.NotFound;

    // Check post-decode absolute path or backslashes
    if (decoded_slice[0] == '/') return error.PathTraversal;
    if (std.mem.indexOfScalar(u8, decoded_slice, '\\') != null) return error.PathTraversal;

    // Reject traversal '..' segments
    var it = std.mem.splitScalar(u8, decoded_slice, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.PathTraversal;
    }

    // Trailing slash implies a directory, not a media file
    if (decoded_slice[decoded_slice.len - 1] == '/') return error.NotFound;

    return try allocator.dupe(u8, decoded_slice);
}

// --- Unit Tests -----------------------------------------------------------

test "range: valid range forms" {
    const size: u64 = 1000;

    // bytes=a-b
    const r1 = parseRange("bytes=0-499", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 0, .end = 499 } }, r1);
    try std.testing.expectEqual(@as(u64, 500), r1.range.length());

    // bytes=a- (open-ended)
    const r2 = parseRange("bytes=500-", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 500, .end = 999 } }, r2);
    try std.testing.expectEqual(@as(u64, 500), r2.range.length());

    // bytes=-n (suffix)
    const r3 = parseRange("bytes=-500", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 500, .end = 999 } }, r3);
    try std.testing.expectEqual(@as(u64, 500), r3.range.length());
}

test "range: end beyond size clamps" {
    const size: u64 = 100;
    const r = parseRange("bytes=10-200", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 10, .end = 99 } }, r);
    try std.testing.expectEqual(@as(u64, 90), r.range.length());
}

test "range: suffix larger than size clamps" {
    const size: u64 = 100;
    const r = parseRange("bytes=-200", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 0, .end = 99 } }, r);
    try std.testing.expectEqual(@as(u64, 100), r.range.length());
}

test "range: unsatisfiable ranges" {
    const size: u64 = 100;

    // Suffix 0
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=-0", size));

    // Start >= size
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=100-", size));
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=150-200", size));

    // Start > end
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=50-20", size));

    // Zero-size file
    try std.testing.expectEqual(RangeResult.unsatisfiable, parseRange("bytes=0-10", 0));
}

test "range: malformed and overflow headers return full" {
    const size: u64 = 1000;

    // Missing "bytes="
    try std.testing.expectEqual(RangeResult.full, parseRange("10-20", size));
    try std.testing.expectEqual(RangeResult.full, parseRange("items=0-10", size));

    // Missing dash
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=500", size));

    // Bad digits
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=abc-def", size));

    // Only plain digits (parseUnsigned alone would accept these)
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=+5-10", size));
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=1_0-20", size));
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=-+5", size));

    // Overflow u64
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=0-99999999999999999999", size));
    try std.testing.expectEqual(RangeResult.full, parseRange("bytes=-99999999999999999999", size));
}

test "range: whitespace handling" {
    const size: u64 = 1000;
    const r1 = parseRange("  bytes = 0 - 50 ", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 0, .end = 50 } }, r1);

    const r2 = parseRange("bytes=  100 -  ", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 100, .end = 999 } }, r2);

    const r3 = parseRange("bytes= - 50  ", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 950, .end = 999 } }, r3);
}

test "range: multiple ranges selects first" {
    const size: u64 = 1000;
    const r = parseRange("bytes=0-1, 5-6, 10-20", size);
    try std.testing.expectEqual(RangeResult{ .range = .{ .start = 0, .end = 1 } }, r);
}

test "content type mapping" {
    try std.testing.expectEqualStrings("video/mp4", mimeForExtension("mp4"));
    try std.testing.expectEqualStrings("video/mp4", mimeForExtension(".mp4"));
    try std.testing.expectEqualStrings("video/webm", mimeForExtension("webm"));
    try std.testing.expectEqualStrings("video/x-matroska", mimeForExtension("mkv"));
    try std.testing.expectEqualStrings("video/quicktime", mimeForExtension("mov"));
    try std.testing.expectEqualStrings("audio/mpeg", mimeForExtension("mp3"));
    try std.testing.expectEqualStrings("audio/ogg", mimeForExtension("ogg"));
    try std.testing.expectEqualStrings("audio/ogg", mimeForExtension("oga"));
    try std.testing.expectEqualStrings("video/ogg", mimeForExtension("ogv"));
    try std.testing.expectEqualStrings("audio/opus", mimeForExtension("opus"));
    try std.testing.expectEqualStrings("audio/wav", mimeForExtension("wav"));
    try std.testing.expectEqualStrings("audio/flac", mimeForExtension("flac"));
    try std.testing.expectEqualStrings("audio/mp4", mimeForExtension("m4a"));
    try std.testing.expectEqualStrings("audio/aac", mimeForExtension("aac"));
    try std.testing.expectEqualStrings("text/vtt", mimeForExtension("vtt"));
    try std.testing.expectEqualStrings("text/plain", mimeForExtension("srt"));
    try std.testing.expectEqualStrings("application/json", mimeForExtension("json"));
    try std.testing.expectEqualStrings("image/png", mimeForExtension("png"));
    try std.testing.expectEqualStrings("image/jpeg", mimeForExtension("jpg"));
    try std.testing.expectEqualStrings("image/jpeg", mimeForExtension("jpeg"));
    try std.testing.expectEqualStrings("image/webp", mimeForExtension("webp"));
    try std.testing.expectEqualStrings("application/octet-stream", mimeForExtension("unknown_ext"));
}

test "path sanitization: valid paths" {
    const ally = std.testing.allocator;

    const p1 = try sanitizePath(ally, "movie.mp4");
    defer ally.free(p1);
    try std.testing.expectEqualStrings("movie.mp4", p1);

    const p2 = try sanitizePath(ally, "videos/2026/test.webm");
    defer ally.free(p2);
    try std.testing.expectEqualStrings("videos/2026/test.webm", p2);

    const p3 = try sanitizePath(ally, "sub%20dir/my%20song.mp3");
    defer ally.free(p3);
    try std.testing.expectEqualStrings("sub dir/my song.mp3", p3);
}

test "path sanitization: traversal attempts rejected" {
    const ally = std.testing.allocator;

    // ../
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "../"));
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "../secret.txt"));

    // %2e%2e/
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "%2e%2e/"));
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "%2E%2E/passwd"));

    // a/../../b
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "a/../../b"));

    // /etc/passwd (absolute)
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "/etc/passwd"));

    // a\..\b (backslashes)
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "a\\..\\b"));
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "a\\b\\c.mp4"));

    // %00 (NUL byte)
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "%00"));
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "file.mp4%00.jpg"));
    try std.testing.expectError(error.PathTraversal, sanitizePath(ally, "file\x00.mp4"));
}
