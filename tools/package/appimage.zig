//! AppImage runtime and AppRun script utilities.

const std = @import("std");

/// Upstream continuous release URL template for AppImage type-2 runtime.
/// Pin the URL in one constant with a comment.
pub const APPIMAGE_RUNTIME_URL_TEMPLATE = "https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-{s}";

/// Generate AppRun shell script for AppImage.
pub fn generateAppRun(allocator: std.mem.Allocator, exe_name: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\HERE="$(dirname "$(readlink -f "${{0}}")")"
        \\export PATH="${{HERE}}/usr/bin:${{PATH}}"
        \\export LD_LIBRARY_PATH="${{HERE}}/usr/lib:${{LD_LIBRARY_PATH:-}}"
        \\export XDG_DATA_DIRS="${{HERE}}/usr/share:${{XDG_DATA_DIRS:-/usr/local/share:/usr/share}}"
        \\exec "${{HERE}}/usr/bin/{s}" "$@"
        \\
    , .{exe_name});
}

/// Verify if buffer begins with ELF header magic "\x7fELF".
pub fn isElfBinary(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    return std.mem.eql(u8, bytes[0..4], "\x7fELF");
}

test "generateAppRun" {
    const testing = std.testing;
    const gpa = testing.allocator;

    const script = try generateAppRun(gpa, "oriel-react-notes");
    defer gpa.free(script);

    try testing.expect(std.mem.indexOf(u8, script, "exec \"${HERE}/usr/bin/oriel-react-notes\" \"$@\"") != null);
}

test "isElfBinary" {
    const testing = std.testing;

    try testing.expect(isElfBinary("\x7fELF\x02\x01\x01\x00"));
    try testing.expect(!isElfBinary("MZ\x90\x00"));
    try testing.expect(!isElfBinary("#!/bin/sh"));
    try testing.expect(!isElfBinary(""));
}
