//! Common deep link URL validation and types.
//!
//! Validates incoming deep link URLs before delivery to the application:
//! - Scheme matches one of the declared schemes for the application (case-insensitive)
//! - Max URL length 2048 bytes
//! - No ASCII control characters (0x00..0x1F, 0x7F)
//! - Valid URI according to std.Uri.parse

const std = @import("std");

/// Maximum supported URL length for deep links (2048 bytes).
pub const max_url_len: usize = 2048;

pub const ValidationError = error{
    UrlTooLong,
    ContainsControlChar,
    InvalidScheme,
    DisallowedScheme,
    InvalidUri,
};

/// Validate that a scheme string consists only of valid scheme characters
/// as defined in RFC 3986 §3.1: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ).
pub fn isValidSchemeFormat(scheme: []const u8) bool {
    if (scheme.len == 0) return false;
    const first = scheme[0];
    const is_alpha = (first >= 'a' and first <= 'z') or (first >= 'A' and first <= 'Z');
    if (!is_alpha) return false;
    for (scheme[1..]) |c| {
        const is_alnum = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9');
        const is_allowed = is_alnum or c == '+' or c == '-' or c == '.';
        if (!is_allowed) return false;
    }
    return true;
}

/// Validate an untrusted URL string against declared application schemes.
/// Returns the validated URL slice on success.
pub fn validateUrl(url: []const u8, declared_schemes: []const []const u8) ValidationError![]const u8 {
    if (url.len > max_url_len) return error.UrlTooLong;
    if (!std.unicode.utf8ValidateSlice(url)) return error.InvalidUri;

    for (url) |c| {
        if (c < 0x20 or c == 0x7F) return error.ContainsControlChar;
    }

    const colon_idx = std.mem.indexOfScalar(u8, url, ':') orelse return error.InvalidScheme;
    const scheme = url[0..colon_idx];
    if (!isValidSchemeFormat(scheme)) return error.InvalidScheme;

    // Check scheme against declared schemes (case-insensitive)
    var matched = false;
    for (declared_schemes) |declared| {
        if (std.ascii.eqlIgnoreCase(scheme, declared)) {
            matched = true;
            break;
        }
    }
    if (!matched) return error.DisallowedScheme;

    // Parse with std.Uri to ensure structural validity
    _ = std.Uri.parse(url) catch return error.InvalidUri;

    return url;
}

test "validateUrl with declared schemes" {
    const declared = [_][]const u8{ "oriel-notes", "myapp" };

    // Valid URLs
    try std.testing.expectEqualStrings("oriel-notes://note/hello", try validateUrl("oriel-notes://note/hello", &declared));
    try std.testing.expectEqualStrings("myapp://path?query=1&foo=bar#hash", try validateUrl("myapp://path?query=1&foo=bar#hash", &declared));

    // Case-insensitive scheme
    try std.testing.expectEqualStrings("ORIEL-NOTES://note/test", try validateUrl("ORIEL-NOTES://note/test", &declared));
    try std.testing.expectEqualStrings("MyApp://settings", try validateUrl("MyApp://settings", &declared));

    // Disallowed scheme
    try std.testing.expectError(error.DisallowedScheme, validateUrl("other://foo", &declared));
    try std.testing.expectError(error.DisallowedScheme, validateUrl("http://example.com", &declared));

    // Control characters
    try std.testing.expectError(error.ContainsControlChar, validateUrl("oriel-notes://note/\x00evil", &declared));
    try std.testing.expectError(error.ContainsControlChar, validateUrl("oriel-notes://note/\nnewline", &declared));
    try std.testing.expectError(error.ContainsControlChar, validateUrl("oriel-notes://note/\x1Bescape", &declared));
    try std.testing.expectError(error.ContainsControlChar, validateUrl("oriel-notes://note/\x7Fdel", &declared));

    // Length limit
    var long_url: [max_url_len + 1]u8 = undefined;
    @memcpy(long_url[0..14], "oriel-notes://");
    @memset(long_url[14..], 'a');
    try std.testing.expectError(error.UrlTooLong, validateUrl(&long_url, &declared));

    // Exactly max length is allowed if valid
    var max_url: [max_url_len]u8 = undefined;
    @memcpy(max_url[0..14], "oriel-notes://");
    @memset(max_url[14..], 'a');
    _ = try validateUrl(&max_url, &declared);

    // Invalid scheme formats
    try std.testing.expectError(error.InvalidScheme, validateUrl("123bad://path", &declared));
    try std.testing.expectError(error.InvalidScheme, validateUrl("://path", &declared));
    try std.testing.expectError(error.InvalidScheme, validateUrl("bad scheme://path", &declared));

    // Invalid URI format
    try std.testing.expectError(error.InvalidUri, validateUrl("oriel-notes://[invalid-ipv6", &declared));

    // Invalid UTF-8
    try std.testing.expectError(error.InvalidUri, validateUrl("oriel-notes://note/\xFF\xFE", &declared));
}
