//! Markdown to readable prose for `tts`: headings, list markers, quotes,
//! emphasis, inline code ticks, rules and link targets go; the words,
//! punctuation, numbers and symbols stay (they change what is said).

const std = @import("std");

/// `text` without its Markdown markup, allocated with `a`. Fenced code keeps
/// its content (without the fences); plain text passes through unchanged
/// apart from line-edge whitespace.
pub fn prepare(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_code = false;
    var first = true;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "```") or std.mem.startsWith(u8, line, "~~~")) {
            in_code = !in_code;
            continue;
        }
        if (!first) try output.append(a, '\n');
        first = false;
        if (in_code) {
            try output.appendSlice(a, std.mem.trimEnd(u8, raw, "\r"));
        } else if (!isRule(line)) {
            try appendInline(a, &output, stripPrefix(line));
        }
    }
    return output.toOwnedSlice(a);
}

fn isRule(line: []const u8) bool {
    if (line.len < 3) return false;
    const marker = line[0];
    if (marker != '-' and marker != '*' and marker != '_') return false;
    var count: usize = 0;
    for (line) |ch| {
        if (ch == marker) count += 1 else if (ch != ' ' and ch != '\t') return false;
    }
    return count >= 3;
}

/// Block markers: quotes, headings, bullets and task boxes, numbered items.
fn stripPrefix(raw: []const u8) []const u8 {
    var line = raw;
    // "> quote", ">> nested" ("x >= 5" and ">=" stay).
    while (line.len > 0 and line[0] == '>' and (line.len == 1 or line[1] == ' ' or line[1] == '>'))
        line = std.mem.trimStart(u8, line[1..], " \t");
    var i: usize = 0;
    while (i < line.len and line[i] == '#') i += 1;
    if (i > 0 and i <= 6 and i < line.len and line[i] == ' ') return std.mem.trimStart(u8, line[i..], " \t");
    if (line.len >= 2 and (line[0] == '-' or line[0] == '*' or line[0] == '+') and line[1] == ' ') {
        line = std.mem.trimStart(u8, line[2..], " \t");
        if (line.len >= 4 and line[0] == '[' and line[2] == ']' and line[3] == ' ' and
            (line[1] == ' ' or line[1] == 'x' or line[1] == 'X')) line = line[4..];
        return line;
    }
    i = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
    if (i > 0 and i + 1 < line.len and (line[i] == '.' or line[i] == ')') and line[i + 1] == ' ')
        return std.mem.trimStart(u8, line[i + 2 ..], " \t");
    return line;
}

/// Emphasis, strikethrough, code ticks and link/image targets.
fn appendInline(a: std.mem.Allocator, output: *std.ArrayList(u8), line: []const u8) !void {
    const hidden = try a.alloc(bool, line.len);
    defer a.free(hidden);
    @memset(hidden, false);
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (hidden[i]) continue;
        if (line[i] == '[' or (line[i] == '!' and i + 1 < line.len and line[i + 1] == '[')) {
            const open = if (line[i] == '!') i + 1 else i;
            if (std.mem.indexOfPos(u8, line, open + 1, "](")) |close| {
                if (std.mem.indexOfScalarPos(u8, line, close + 2, ')')) |end| {
                    @memset(hidden[i .. open + 1], true);
                    @memset(hidden[close .. end + 1], true);
                    continue;
                }
            }
        }
        const ch = line[i];
        if (ch != '*' and ch != '_' and ch != '~' and ch != '`') continue;
        var width: usize = 1;
        while (i + width < line.len and line[i + width] == ch) width += 1;
        if (ch == '~' and width != 2) continue;
        // Underscores within identifiers and asterisks used in arithmetic stay.
        if (ch != '`' and i > 0 and !std.ascii.isWhitespace(line[i - 1]) and line[i - 1] != '(') continue;
        if (i + width == line.len or std.ascii.isWhitespace(line[i + width])) continue;
        if (std.mem.indexOfPos(u8, line, i + width, line[i .. i + width])) |close| {
            if (close == i + width or std.ascii.isWhitespace(line[close - 1])) continue;
            if (ch != '`' and close + width < line.len and std.ascii.isAlphanumeric(line[close + width])) continue;
            @memset(hidden[i .. i + width], true);
            @memset(hidden[close .. close + width], true);
            if (ch == '`') i = close + width - 1 else i += width - 1;
        }
    }
    for (line, hidden) |ch, hide| if (!hide) try output.append(a, ch);
}

test "markdown: formatting goes, prose and link labels stay" {
    const text = "# Reader\n- **Hello**, *world*.\n1. Visit [our site](https://example.com).\n> _Take a breath_: now.\n- [x] Done\n---\n```zig\nconst value = 3.14;\n```";
    const result = try prepare(std.testing.allocator, text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Reader\nHello, world.\nVisit our site.\nTake a breath: now.\nDone\n\nconst value = 3.14;", result);
}

test "markdown: punctuation, numbers, symbols and code content are kept" {
    const text = "Price: $12.50. At 08:30, -5 degrees; 2 * 3 = 6.\nfile_name and C#; A - B. Use `a_b * c`.\n¿Está bien? ¡Sí!\nUnmatched * and [brackets].";
    const result = try prepare(std.testing.allocator, text);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("Price: $12.50. At 08:30, -5 degrees; 2 * 3 = 6.\nfile_name and C#; A - B. Use a_b * c.\n¿Está bien? ¡Sí!\nUnmatched * and [brackets].", result);
}

test "markdown: images keep their alt text, nested quotes and ~~strike~~ unwrap" {
    const result = try prepare(std.testing.allocator, ">> ![A cat](cat.png) is ~~not~~ here");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("A cat is not here", result);
}
