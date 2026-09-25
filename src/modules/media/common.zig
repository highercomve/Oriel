//! Common types and pure lexical path validation for media file handling.

const std = @import("std");

/// What to do with symbolic links below the media root.
pub const SymlinkPolicy = enum {
    /// Follow symlinks only while they resolve inside the root (default).
    /// A link pointing outside the root is refused.
    inside_root,
    /// Refuse every symlink, even ones pointing inside the root.
    refuse_all,
};

pub const OpenError = error{
    /// The path would leave the root, or hits a refused symlink.
    Forbidden,
    NotFound,
    /// Not a regular file (directory, device, FIFO...).
    NotAFile,
    /// The kernel lacks openat2 (Linux < 5.6) or another unexpected errno / Win32 error.
    Unexpected,
};

/// Security-critical lexical path validation for Windows media file resolution.
///
/// Must lexically reject:
/// - `..` components (e.g. `..\`, `a/../..`, `..`, `sub/..`)
/// - Absolute paths (starts with `/`, `\`, `\\`, `//`)
/// - Drive letters (e.g. `C:`, `C:x`, any `:`)
/// - `:` Alternate Data Streams (ADS, e.g. `file::$DATA`)
/// - Backslashes (`\`)
/// - NUL bytes (`\x00`)
/// - DOS device names (`CON`, `PRN`, `AUX`, `NUL`, `COM1`..`COM9`, `LPT1`..`LPT9`),
///   both bare and with extensions (e.g. `con.txt`, `aux.mp3`, `COM1.dat`)
pub fn validateWindowsPath(path: []const u8) OpenError!void {
    if (path.len == 0) return error.NotFound;

    // Reject NUL
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.Forbidden;

    // Reject backslashes
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.Forbidden;

    // Reject colons (catches drive letters like "C:x" and ADS like "file::$DATA")
    if (std.mem.indexOfScalar(u8, path, ':') != null) return error.Forbidden;

    // Reject absolute paths starting with '/'
    if (path[0] == '/') return error.Forbidden;

    // Reject UNC / double slashes
    if (std.mem.startsWith(u8, path, "//")) return error.Forbidden;

    // Inspect each segment split on '/'
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        // Empty segment (e.g. double slash "a//b")
        if (segment.len == 0) return error.Forbidden;

        // Directory traversal / current directory
        if (std.mem.eql(u8, segment, "..") or std.mem.eql(u8, segment, ".")) {
            return error.Forbidden;
        }

        // Check for DOS device names (CON, PRN, AUX, NUL, COM1..9, LPT1..9)
        const stem = if (std.mem.indexOfScalar(u8, segment, '.')) |dot| segment[0..dot] else segment;
        const trimmed = std.mem.trimEnd(u8, stem, " ");
        if (isDosDeviceName(trimmed)) return error.Forbidden;
    }
}

pub fn isDosDeviceName(name: []const u8) bool {
    if (name.len == 3) {
        if (std.ascii.eqlIgnoreCase(name, "con") or
            std.ascii.eqlIgnoreCase(name, "prn") or
            std.ascii.eqlIgnoreCase(name, "aux") or
            std.ascii.eqlIgnoreCase(name, "nul"))
        {
            return true;
        }
    } else if (name.len == 4) {
        if ((std.ascii.startsWithIgnoreCase(name, "com") or std.ascii.startsWithIgnoreCase(name, "lpt")) and
            (name[3] >= '1' and name[3] <= '9'))
        {
            return true;
        }
    }
    return false;
}

test "media: lexical path validation on Windows security rules" {
    // Required security-critical test cases from spec:
    // `..\`, `a/../..`, `C:x`, `\\?\`, `con.txt`, `file::$DATA`
    try std.testing.expectError(error.Forbidden, validateWindowsPath("..\\"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("a/../.."));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("C:x"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("\\\\?\\"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("con.txt"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("file::$DATA"));

    // Additional boundary and device name cases
    try std.testing.expectError(error.Forbidden, validateWindowsPath("CON"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("sub/aux.mp3"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("media/prn"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("nul.wav"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("COM1.json"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("com9"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("LPT1.txt"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("lpt9"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("/absolute/path"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("sub/.."));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("../secret"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("foo//bar"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("foo/./bar"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("a\x00b"));
    try std.testing.expectError(error.Forbidden, validateWindowsPath("C:/windows/system32"));
    try std.testing.expectError(error.NotFound, validateWindowsPath(""));

    // Valid paths should succeed
    try validateWindowsPath("sample.mp4");
    try validateWindowsPath("audio/music.mp3");
    try validateWindowsPath("images/photo.png");
    try validateWindowsPath("sub/dir/deep/file.wav");
    try validateWindowsPath("constant.mp3"); // "con" prefix in longer word is OK
    try validateWindowsPath("complex.json"); // "com" prefix in longer word is OK
}

// Pure UTF-16 path comparisons used by the Windows backend (open/windows.zig);
// kept here so they are unit-tested on every OS.

/// Strip `\\?\` or `\\.\` prefix for path comparison normalization.
pub fn stripExtendedPrefix(path: []const u16) []const u16 {
    if (path.len >= 4 and path[0] == '\\' and path[1] == '\\' and (path[2] == '?' or path[2] == '.') and path[3] == '\\') {
        return path[4..];
    }
    return path;
}

/// Compare two paths case-insensitively after `\\?\` prefix normalization.
/// Used under SymlinkPolicy.refuse_all to detect intermediate reparse points / junctions.
pub fn isPathLexicallyEqual(path_a: []const u16, path_b: []const u16) bool {
    const a = stripExtendedPrefix(path_a);
    const b = stripExtendedPrefix(path_b);
    if (a.len != b.len) return false;
    for (a, 0..) |ac, i| {
        const bc = b[i];
        const a_norm = if (ac == '/') '\\' else if (ac < 128) std.ascii.toLower(@truncate(ac)) else ac;
        const b_norm = if (bc == '/') '\\' else if (bc < 128) std.ascii.toLower(@truncate(bc)) else bc;
        if (a_norm != b_norm) return false;
    }
    return true;
}

/// Check if `path` is strictly inside `root` on a path separator boundary, case-insensitively.
pub fn isSubpathCaseInsensitive(path: []const u16, root: []const u16) bool {
    const a = stripExtendedPrefix(path);
    const r = stripExtendedPrefix(root);
    if (a.len <= r.len) return false;
    for (r, 0..) |rc, i| {
        const pc = a[i];
        const rc_lower = if (rc < 128) std.ascii.toLower(@truncate(rc)) else rc;
        const pc_lower = if (pc < 128) std.ascii.toLower(@truncate(pc)) else pc;
        if (rc_lower != pc_lower) return false;
    }
    // Must be bounded by a separator
    if (r[r.len - 1] == '\\') return true;
    if (a[r.len] == '\\') return true;
    return false;
}

test "media windows: isSubpathCaseInsensitive" {
    const root = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media");
    const valid1 = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media\\sub\\file.mp3");
    const valid_case = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\c:\\APP\\Media\\sub\\file.mp3");
    const sibling = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media_extra\\file.mp3");
    const outside = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\other\\file.mp3");
    const same = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media");

    try std.testing.expect(isSubpathCaseInsensitive(valid1, root));
    try std.testing.expect(isSubpathCaseInsensitive(valid_case, root));
    try std.testing.expect(!isSubpathCaseInsensitive(sibling, root));
    try std.testing.expect(!isSubpathCaseInsensitive(outside, root));
    try std.testing.expect(!isSubpathCaseInsensitive(same, root));
}

test "media windows: isPathLexicallyEqual comparison helper" {
    const p1 = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media\\sub\\file.mp3");
    const p1_no_prefix = std.unicode.utf8ToUtf16LeStringLiteral("C:\\app\\media\\sub\\file.mp3");
    const p1_diff_case = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\c:\\APP\\media\\SUB\\file.mp3");
    const p1_forward_slash = std.unicode.utf8ToUtf16LeStringLiteral("c:/app/media/sub/file.mp3");

    // Equal matches
    try std.testing.expect(isPathLexicallyEqual(p1, p1));
    try std.testing.expect(isPathLexicallyEqual(p1, p1_no_prefix));
    try std.testing.expect(isPathLexicallyEqual(p1, p1_diff_case));
    try std.testing.expect(isPathLexicallyEqual(p1, p1_forward_slash));

    // Intermediate junction traversal difference (e.g. junction pointed to 'other')
    const junction_traversed = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media\\other\\file.mp3");
    try std.testing.expect(!isPathLexicallyEqual(junction_traversed, p1));

    // Different file name
    const diff_file = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media\\sub\\other.mp3");
    try std.testing.expect(!isPathLexicallyEqual(diff_file, p1));

    // Substring or prefix mismatch
    const prefix_only = std.unicode.utf8ToUtf16LeStringLiteral("\\\\?\\C:\\app\\media\\sub");
    try std.testing.expect(!isPathLexicallyEqual(prefix_only, p1));
}
