//! Architecture mappings and package metadata utilities.

const std = @import("std");

/// Map CPU architecture to Debian architecture name.
pub fn targetToDebArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm, .armeb => "armhf",
        .riscv64 => "riscv64",
        .x86 => "i386",
        else => @tagName(arch),
    };
}

/// Map CPU architecture to RPM architecture name.
pub fn targetToRpmArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm, .armeb => "armhfp",
        .riscv64 => "riscv64",
        .x86 => "i686",
        else => @tagName(arch),
    };
}

/// Map CPU architecture to AppImage architecture suffix.
pub fn targetToAppImageArch(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm, .armeb => "armhf",
        .riscv64 => "riscv64",
        .x86 => "i686",
        else => @tagName(arch),
    };
}

pub const ValidationError = error{
    InvalidExeName,
    InvalidAppId,
    InvalidUrlScheme,
    ContainsControlChar,
    ContainsNewline,
    InvalidExec,
};

/// Validate reverse-DNS application ID (e.g. "dev.oriel.ReactNotes"):
/// At least two dot-separated elements of [A-Za-z0-9_-], none empty or starting with a digit.
pub fn validAppId(id: []const u8) bool {
    if (id.len == 0 or id.len > 255) return false;
    var elements: usize = 0;
    var it = std.mem.splitScalar(u8, id, '.');
    while (it.next()) |element| {
        if (element.len == 0 or std.ascii.isDigit(element[0])) return false;
        for (element) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
        }
        elements += 1;
    }
    return elements >= 2;
}

/// Validate that a scheme string is valid per RFC 3986 §3.1:
/// ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )
pub fn isValidSchemeFormat(scheme: []const u8) bool {
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

/// Validate executable name:
/// - Must match `[A-Za-z0-9._+-]+`
/// - Must not start with '-' or '.'
pub fn validateExeName(exe_name: []const u8) ValidationError!void {
    if (exe_name.len == 0) return error.InvalidExeName;
    if (exe_name[0] == '-' or exe_name[0] == '.') return error.InvalidExeName;
    for (exe_name) |c| {
        const is_alnum = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9');
        const is_allowed_punct = (c == '.' or c == '_' or c == '+' or c == '-');
        if (!is_alnum and !is_allowed_punct) return error.InvalidExeName;
    }
}

/// Reject ASCII control characters (< 0x20) and DEL (0x7F).
pub fn validateNoControlChars(s: []const u8) ValidationError!void {
    for (s) |c| {
        if (c < 0x20 or c == 0x7F) return error.ContainsControlChar;
    }
}

/// Reject ASCII control characters and newlines (\r, \n).
pub fn validateNoControlOrNewline(s: []const u8) ValidationError!void {
    for (s) |c| {
        if (c == '\n' or c == '\r') return error.ContainsNewline;
        if (c < 0x20 or c == 0x7F) return error.ContainsControlChar;
    }
}

/// Escape YAML scalar:
/// - Rejects control chars and newlines.
/// - Escapes '\' -> '\\' and '"' -> '\"'.
pub fn escapeYamlScalar(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    try validateNoControlOrNewline(s);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    for (s) |c| {
        switch (c) {
            '\\' => try out.writer.writeAll("\\\\"),
            '"' => try out.writer.writeAll("\\\""),
            else => try out.writer.writeByte(c),
        }
    }
    return try allocator.dupe(u8, out.written());
}

/// Escape Desktop Entry string value per XDG Desktop Entry Specification:
/// Supported escapes: \s (space), \n (newline), \t (tab), \r (carriage return), \\ (backslash).
/// Leading and trailing spaces are escaped with \s to preserve them.
/// Unallowed control characters (< 0x20 except \n,\t,\r, and 0x7F) are rejected.
pub fn escapeDesktopString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    for (s) |c| {
        if (c < 0x20 and c != '\n' and c != '\t' and c != '\r') return error.ContainsControlChar;
        if (c == 0x7F) return error.ContainsControlChar;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    // Find range of leading spaces and trailing spaces
    var leading_spaces: usize = 0;
    while (leading_spaces < s.len and s[leading_spaces] == ' ') : (leading_spaces += 1) {}

    var trailing_spaces_start: usize = s.len;
    while (trailing_spaces_start > leading_spaces and s[trailing_spaces_start - 1] == ' ') : (trailing_spaces_start -= 1) {}

    for (0..leading_spaces) |_| {
        try out.writer.writeAll("\\s");
    }

    const middle = s[leading_spaces..trailing_spaces_start];
    for (middle) |c| {
        switch (c) {
            '\\' => try out.writer.writeAll("\\\\"),
            '\n' => try out.writer.writeAll("\\n"),
            '\t' => try out.writer.writeAll("\\t"),
            '\r' => try out.writer.writeAll("\\r"),
            else => try out.writer.writeByte(c),
        }
    }

    for (trailing_spaces_start..s.len) |_| {
        try out.writer.writeAll("\\s");
    }

    return try allocator.dupe(u8, out.written());
}

/// Characters that force quoting of an Exec argument (Desktop Entry spec,
/// "The Exec key": space, tab, newline and the shell-reserved characters).
fn isExecReservedChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '"', '\'', '\\', '>', '<', '~', '|', '&', ';', '*', '?', '#', '(', ')', '`', '$' => true,
        else => false,
    };
}

/// Encode a single program path (no arguments) as a Desktop Entry `Exec` value.
///
/// The spec applies two layers: Exec quoting (inside double quotes `"`, `` ` ``,
/// `$` and `\` are backslash-escaped), then the general string escaping, which
/// doubles every backslash again. `%` becomes `%%` so it is not a field code.
/// Callers pass the executable name or an absolute path; arguments are not
/// supported (they would need their own quoting).
pub fn escapeDesktopExec(allocator: std.mem.Allocator, exec: []const u8) ![]const u8 {
    try validateNoControlOrNewline(exec);
    if (exec.len == 0) return error.InvalidExec;

    var needs_quote = false;
    for (exec) |c| {
        if (isExecReservedChar(c)) needs_quote = true;
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    if (needs_quote) try w.writeByte('"');
    for (exec) |c| switch (c) {
        // Exec-quoted `\x`, then string-escaped backslash: `\\x`.
        '"', '`', '$' => if (needs_quote) try w.print("\\\\{c}", .{c}) else try w.writeByte(c),
        '\\' => try w.writeAll("\\\\\\\\"),
        '%' => try w.writeAll("%%"),
        else => try w.writeByte(c),
    };
    if (needs_quote) try w.writeByte('"');
    return try allocator.dupe(u8, out.written());
}

/// Escape string literal for NSIS scripts within double quotes ("..."):
/// - '$' -> '$$'
/// - '"' -> '$\"'
/// - '\r' -> '$\r'
/// - '\n' -> '$\n'
/// - '\t' -> '$\t'
/// Backslashes are preserved as-is for Windows filesystem paths.
pub fn escapeNsisString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    for (s) |c| {
        switch (c) {
            '$' => try out.writer.writeAll("$$"),
            '"' => try out.writer.writeAll("$\\\""),
            '\r' => try out.writer.writeAll("$\\r"),
            '\n' => try out.writer.writeAll("$\\n"),
            '\t' => try out.writer.writeAll("$\\t"),
            else => try out.writer.writeByte(c),
        }
    }
    return try allocator.dupe(u8, out.written());
}

test "targetToArch mappings" {
    const testing = std.testing;

    try testing.expectEqualStrings("amd64", targetToDebArch(.x86_64));
    try testing.expectEqualStrings("arm64", targetToDebArch(.aarch64));
    try testing.expectEqualStrings("armhf", targetToDebArch(.arm));
    try testing.expectEqualStrings("riscv64", targetToDebArch(.riscv64));
    try testing.expectEqualStrings("i386", targetToDebArch(.x86));

    try testing.expectEqualStrings("x86_64", targetToRpmArch(.x86_64));
    try testing.expectEqualStrings("aarch64", targetToRpmArch(.aarch64));
    try testing.expectEqualStrings("armhfp", targetToRpmArch(.arm));
    try testing.expectEqualStrings("riscv64", targetToRpmArch(.riscv64));
    try testing.expectEqualStrings("i686", targetToRpmArch(.x86));

    try testing.expectEqualStrings("x86_64", targetToAppImageArch(.x86_64));
    try testing.expectEqualStrings("aarch64", targetToAppImageArch(.aarch64));
    try testing.expectEqualStrings("armhf", targetToAppImageArch(.arm));
    try testing.expectEqualStrings("riscv64", targetToAppImageArch(.riscv64));
    try testing.expectEqualStrings("i686", targetToAppImageArch(.x86));
}

test "validateExeName rejects and accepts" {
    const testing = std.testing;

    // Valid names
    try validateExeName("oriel-react-notes");
    try validateExeName("app");
    try validateExeName("MyApp123");
    try validateExeName("my_cool_app+v1.0");

    // Invalid names
    try testing.expectError(error.InvalidExeName, validateExeName(""));
    try testing.expectError(error.InvalidExeName, validateExeName("-app"));
    try testing.expectError(error.InvalidExeName, validateExeName(".app"));
    try testing.expectError(error.InvalidExeName, validateExeName("app with spaces"));
    try testing.expectError(error.InvalidExeName, validateExeName("app/slash"));
    try testing.expectError(error.InvalidExeName, validateExeName("app;injection"));
    try testing.expectError(error.InvalidExeName, validateExeName("app\nnewline"));
}

test "validateNoControlChars and validateNoControlOrNewline" {
    const testing = std.testing;

    try validateNoControlChars("Hello, world! 123");
    try validateNoControlOrNewline("Hello, world! 123");

    // Control characters
    try testing.expectError(error.ContainsControlChar, validateNoControlChars("Hello\x00World"));
    try testing.expectError(error.ContainsControlChar, validateNoControlChars("Hello\x1BWorld"));
    try testing.expectError(error.ContainsControlChar, validateNoControlChars("Hello\x7FWorld"));

    // Newlines
    try testing.expectError(error.ContainsNewline, validateNoControlOrNewline("Hello\nWorld"));
    try testing.expectError(error.ContainsNewline, validateNoControlOrNewline("Hello\rWorld"));
}

test "escapeYamlScalar escaping and validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Normal string
    {
        const escaped = try escapeYamlScalar(allocator, "simple string");
        defer allocator.free(escaped);
        try testing.expectEqualStrings("simple string", escaped);
    }

    // Quotes and backslashes
    {
        const escaped = try escapeYamlScalar(allocator, "C:\\Program Files\\\"App\"");
        defer allocator.free(escaped);
        try testing.expectEqualStrings("C:\\\\Program Files\\\\\\\"App\\\"", escaped);
    }

    // Rejects control characters and newlines
    try testing.expectError(error.ContainsNewline, escapeYamlScalar(allocator, "line 1\nline 2"));
    try testing.expectError(error.ContainsControlChar, escapeYamlScalar(allocator, "bad\x01char"));
}

test "escapeDesktopString escaping and validation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Normal string with internal spaces
    {
        const escaped = try escapeDesktopString(allocator, "React Notes");
        defer allocator.free(escaped);
        try testing.expectEqualStrings("React Notes", escaped);
    }

    // Leading and trailing spaces
    {
        const escaped = try escapeDesktopString(allocator, "  padded  ");
        defer allocator.free(escaped);
        try testing.expectEqualStrings("\\s\\spadded\\s\\s", escaped);
    }

    // Escapes: \\ \n \t \r
    {
        const escaped = try escapeDesktopString(allocator, "Line1\nLine2\tTab\\Backslash\rCR");
        defer allocator.free(escaped);
        try testing.expectEqualStrings("Line1\\nLine2\\tTab\\\\Backslash\\rCR", escaped);
    }

    // Rejects unallowed control characters
    try testing.expectError(error.ContainsControlChar, escapeDesktopString(allocator, "bad\x00char"));
    try testing.expectError(error.ContainsControlChar, escapeDesktopString(allocator, "bad\x1Bchar"));
}

test "escapeDesktopExec quoting and escaping" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Simple binary name
    {
        const res = try escapeDesktopExec(allocator, "oriel-react-notes");
        defer allocator.free(res);
        try testing.expectEqualStrings("oriel-react-notes", res);
    }

    // Absolute path with spaces
    {
        const res = try escapeDesktopExec(allocator, "/home/user/My Apps/bin");
        defer allocator.free(res);
        try testing.expectEqualStrings("\"/home/user/My Apps/bin\"", res);
    }

    // Path with reserved characters
    {
        const res = try escapeDesktopExec(allocator, "/usr/bin/app$1");
        defer allocator.free(res);
        try testing.expectEqualStrings("\"/usr/bin/app\\\\$1\"", res);
    }

    // Backslash and percent: Exec escape then string escape (four backslashes).
    {
        const res = try escapeDesktopExec(allocator, "/opt/a\\b%");
        defer allocator.free(res);
        try testing.expectEqualStrings("\"/opt/a\\\\\\\\b%%\"", res);
    }

    // Rejects control characters and newlines
    try testing.expectError(error.ContainsNewline, escapeDesktopExec(allocator, "app\n--bad"));
    try testing.expectError(error.ContainsControlChar, escapeDesktopExec(allocator, "app\x07bell"));
}

test "escapeNsisString handles quotes, dollar signs, whitespace, and paths" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Plain text
    {
        const res = try escapeNsisString(allocator, "Oriel React Notes");
        defer allocator.free(res);
        try testing.expectEqualStrings("Oriel React Notes", res);
    }

    // Quotes and dollar signs (NSIS $$ and $\")
    {
        const res = try escapeNsisString(allocator, "My \"Cool\" App $100");
        defer allocator.free(res);
        try testing.expectEqualStrings("My $\\\"Cool$\\\" App $$100", res);
    }

    // Windows paths with backslashes (must NOT be escaped in NSIS)
    {
        const res = try escapeNsisString(allocator, "C:\\Program Files\\App\\app.exe");
        defer allocator.free(res);
        try testing.expectEqualStrings("C:\\Program Files\\App\\app.exe", res);
    }

    // Newlines, carriage returns, and tabs
    {
        const res = try escapeNsisString(allocator, "Line 1\r\nLine 2\tTab");
        defer allocator.free(res);
        try testing.expectEqualStrings("Line 1$\\r$\\nLine 2$\\tTab", res);
    }
}
