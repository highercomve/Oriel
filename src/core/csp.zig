//! CSP hashes for inline `<script>` and `<style>` blocks (security 4.1).
//!
//! At build time `embed_assets` hashes every inline block of each HTML file
//! (`inlineHashes`) and records the sources on the asset. At serve time
//! `withHashes` adds them to that page's CSP, so inline code the app shipped
//! runs without `'unsafe-inline'`, while anything injected later doesn't.
//!
//! - Scripts: an inline `<script>` without `src` (any type; a JSON one is
//!   hashed too, which is harmless).
//! - Styles: `<style>` blocks only. `style="..."` attributes can't be allowed
//!   by hash; they need `'unsafe-inline'`, which is why style hashes only
//!   take effect with `Security.strict_styles` (it drops `'unsafe-inline'`
//!   from `style-src`). A hash in a directive that still has
//!   `'unsafe-inline'` would switch that off (CSP3), so `withHashes` leaves
//!   such directives alone.
//!
//! No Oriel imports: `tools/embed_assets.zig` uses this file too.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// One CSP hash source: `'sha256-<base64>'`.
pub const source_len = "'sha256-'".len + std.base64.standard.Encoder.calcSize(Sha256.digest_length);

/// The hash source of an inline block's text. The HTML parser turns CRLF and
/// CR into LF before CSP hashes the text, so this does too.
pub fn hashSource(text: []const u8) [source_len]u8 {
    var h = Sha256.init(.{});
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\r') {
            h.update("\n");
            if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
        } else {
            const end = std.mem.indexOfScalarPos(u8, text, i, '\r') orelse text.len;
            h.update(text[i..end]);
            i = end - 1;
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    var out: [source_len]u8 = undefined;
    @memcpy(out[0..8], "'sha256-");
    _ = std.base64.standard.Encoder.encode(out[8 .. source_len - 1], &digest);
    out[source_len - 1] = '\'';
    return out;
}

/// Space-separated hash sources of an HTML file's inline scripts and style
/// blocks (duplicates once). Caller frees both.
pub const Hashes = struct {
    scripts: []u8,
    styles: []u8,

    pub fn deinit(self: Hashes, gpa: std.mem.Allocator) void {
        gpa.free(self.scripts);
        gpa.free(self.styles);
    }
};

pub fn inlineHashes(gpa: std.mem.Allocator, html: []const u8) !Hashes {
    var scripts: std.ArrayList(u8) = .empty;
    errdefer scripts.deinit(gpa);
    var styles: std.ArrayList(u8) = .empty;
    errdefer styles.deinit(gpa);

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        i = lt + 1;
        const rest = html[lt..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            const end = std.mem.indexOfPos(u8, html, lt + 4, "-->") orelse break;
            i = end + 3;
            continue;
        }
        const kind: enum { script, style } = if (tagIs(rest, "script")) .script else if (tagIs(rest, "style")) .style else continue;
        const name = if (kind == .script) "script" else "style";
        const tag_end = tagEnd(html, lt + 1 + name.len) orelse break;
        const attrs = html[lt + 1 + name.len .. tag_end];
        const body_start = tag_end + 1;
        const close = findClose(html, body_start, name) orelse break;
        i = close;
        if (kind == .script and hasAttr(attrs, "src")) continue;
        const list = if (kind == .script) &scripts else &styles;
        const src = hashSource(html[body_start..close]);
        if (std.mem.indexOf(u8, list.items, &src) != null) continue;
        if (list.items.len > 0) try list.append(gpa, ' ');
        try list.appendSlice(gpa, &src);
    }
    const s = try scripts.toOwnedSlice(gpa);
    errdefer gpa.free(s);
    return .{ .scripts = s, .styles = try styles.toOwnedSlice(gpa) };
}

/// `rest` starts with `<name` followed by whitespace, `/` or `>`.
fn tagIs(rest: []const u8, name: []const u8) bool {
    if (rest.len < name.len + 2) return false;
    if (!std.ascii.eqlIgnoreCase(rest[1 .. 1 + name.len], name)) return false;
    return switch (rest[1 + name.len]) {
        ' ', '\t', '\n', '\r', '\x0c', '/', '>' => true,
        else => false,
    };
}

/// The index of the `>` closing a start tag, skipping quoted values.
fn tagEnd(html: []const u8, from: usize) ?usize {
    var quote: ?u8 = null;
    for (html[from..], from..) |c, idx| {
        if (quote) |q| {
            if (c == q) quote = null;
        } else switch (c) {
            '"', '\'' => quote = c,
            '>' => return idx,
            else => {},
        }
    }
    return null;
}

/// The index of `</name` (case-insensitive) at or after `from`.
fn findClose(html: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, html, i, "</")) |at| {
        if (at + 2 + name.len <= html.len and std.ascii.eqlIgnoreCase(html[at + 2 .. at + 2 + name.len], name)) return at;
        i = at + 2;
    }
    return null;
}

/// Whether a start tag's attribute text has attribute `name`.
fn hasAttr(attrs: []const u8, name: []const u8) bool {
    var i: usize = 0;
    while (i < attrs.len) {
        while (i < attrs.len and (std.ascii.isWhitespace(attrs[i]) or attrs[i] == '/')) i += 1;
        const start = i;
        while (i < attrs.len and !std.ascii.isWhitespace(attrs[i]) and attrs[i] != '=' and attrs[i] != '/') i += 1;
        if (i > start and std.ascii.eqlIgnoreCase(attrs[start..i], name)) return true;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i < attrs.len and attrs[i] == '=') {
            i += 1;
            while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
            if (i < attrs.len and (attrs[i] == '"' or attrs[i] == '\'')) {
                const q = attrs[i];
                i += 1;
                while (i < attrs.len and attrs[i] != q) i += 1;
                i += 1;
            } else {
                while (i < attrs.len and !std.ascii.isWhitespace(attrs[i])) i += 1;
            }
        }
        if (i == start) i += 1;
    }
    return false;
}

// --- The page's CSP --------------------------------------------------------------------

/// `csp` with `scripts` added to `script-src`/`script-src-elem` and `styles`
/// to `style-src`/`style-src-elem` (space-separated sources, "" for none).
/// A directive holding `'unsafe-inline'` is left alone (a hash would turn it
/// off). Without the directive, one is made from `default-src` (unless that
/// is missing, which leaves the type unrestricted). Null when nothing
/// changes; else the caller frees (0-terminated for the C header APIs).
pub fn withHashes(gpa: std.mem.Allocator, csp: []const u8, scripts: []const u8, styles: []const u8) !?[:0]u8 {
    if (scripts.len == 0 and styles.len == 0) return null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    var changed = false;
    var seen_script = false;
    var seen_style = false;
    var default_src: ?[]const u8 = null;
    var first = true;
    var it = std.mem.splitScalar(u8, csp, ';');
    while (it.next()) |part| {
        const d = std.mem.trim(u8, part, " \t");
        if (d.len == 0) continue;
        const end = std.mem.indexOfAny(u8, d, " \t") orelse d.len;
        const name = d[0..end];
        const value = std.mem.trim(u8, d[end..], " \t");
        if (!first) try w.writeAll("; ");
        first = false;
        try w.writeAll(d);
        const add = if (isOneOf(name, &.{ "script-src", "script-src-elem" })) blk: {
            seen_script = true;
            break :blk scripts;
        } else if (isOneOf(name, &.{ "style-src", "style-src-elem" })) blk: {
            seen_style = true;
            break :blk styles;
        } else blk: {
            if (std.ascii.eqlIgnoreCase(name, "default-src")) default_src = value;
            break :blk "";
        };
        if (add.len == 0 or hasSource(value, "'unsafe-inline'")) continue;
        try w.writeByte(' ');
        try w.writeAll(add);
        changed = true;
    }
    if (default_src) |base| {
        if (hasSource(base, "'unsafe-inline'")) return finish(&out, changed);
        const none = hasSource(base, "'none'");
        const pairs = [_]struct { bool, []const u8, []const u8 }{ .{ seen_script, "script-src", scripts }, .{ seen_style, "style-src", styles } };
        for (pairs) |p| {
            if (p[0] or p[2].len == 0) continue;
            try w.print("{s}{s} {s}{s}{s}", .{ if (first) "" else "; ", p[1], if (none) "" else base, if (none) "" else " ", p[2] });
            first = false;
            changed = true;
        }
    }
    return finish(&out, changed);
}

fn finish(out: *std.Io.Writer.Allocating, changed: bool) !?[:0]u8 {
    if (!changed) {
        out.deinit();
        return null;
    }
    return try out.toOwnedSliceSentinel(0);
}

fn isOneOf(name: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(name, n)) return true;
    return false;
}

fn hasSource(value: []const u8, source: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    while (it.next()) |s| if (std.ascii.eqlIgnoreCase(s, source)) return true;
    return false;
}

/// `Security.strict_styles`: `csp` without `'unsafe-inline'` in `style-src`
/// and `style-src-elem`.
pub fn strictStyles(comptime csp: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, csp, ';');
        while (it.next()) |part| {
            const d = std.mem.trim(u8, part, " \t");
            if (d.len == 0) continue;
            const end = std.mem.indexOfAny(u8, d, " \t") orelse d.len;
            const name = d[0..end];
            var directive: []const u8 = name;
            if (isOneOf(name, &.{ "style-src", "style-src-elem" })) {
                var toks = std.mem.tokenizeAny(u8, d[end..], " \t");
                while (toks.next()) |t| {
                    if (!std.ascii.eqlIgnoreCase(t, "'unsafe-inline'")) directive = directive ++ " " ++ t;
                }
            } else directive = d;
            out = out ++ (if (out.len == 0) "" else "; ") ++ directive;
        }
        return out;
    }
}

// --- Tests -----------------------------------------------------------------------------

test hashSource {
    // echo -n "alert(1)" | openssl dgst -sha256 -binary | base64
    try std.testing.expectEqualStrings("'sha256-bhHHL3z2vDgxUt0W3dWQOrprscmda2Y5pLsLg4GF+pI='", &hashSource("alert(1)"));
    // CRLF and CR hash as LF.
    try std.testing.expectEqualStrings(&hashSource("a\nb\nc"), &hashSource("a\r\nb\rc"));
}

test inlineHashes {
    const gpa = std.testing.allocator;
    const html =
        \\<!doctype html><html><head>
        \\<style>body { margin: 0 }</style>
        \\<script>alert(1)</script>
        \\<script src="app.js"></script>
        \\<SCRIPT type="module" data-x='a>b'>alert(1)</SCRIPT>
        \\<!-- <script>commented()</script> -->
        \\<script>let s = "</scr" + "ipt>";</script>
        \\<scripts>not a script</scripts>
        \\</head></html>
    ;
    const h = try inlineHashes(gpa, html);
    defer h.deinit(gpa);
    const a = hashSource("alert(1)");
    const b = hashSource("let s = \"</scr\" + \"ipt>\";");
    try std.testing.expectEqualStrings(&a ++ " " ++ &b, h.scripts);
    try std.testing.expectEqualStrings(&hashSource("body { margin: 0 }"), h.styles);
    const none = try inlineHashes(gpa, "<p>no inline code</p><script src=x></script>");
    defer none.deinit(gpa);
    try std.testing.expectEqualStrings("", none.scripts);
    try std.testing.expectEqualStrings("", none.styles);
}

test withHashes {
    const gpa = std.testing.allocator;
    const default = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; object-src 'none'";
    const got = (try withHashes(gpa, default, "'sha256-A'", "'sha256-B'")).?;
    defer gpa.free(got);
    // The style hash stays out while 'unsafe-inline' is there.
    try std.testing.expectEqualStrings("default-src 'self'; script-src 'self' 'sha256-A'; style-src 'self' 'unsafe-inline'; object-src 'none'", got);
    const strict = (try withHashes(gpa, comptime strictStyles(default), "", "'sha256-B'")).?;
    defer gpa.free(strict);
    try std.testing.expectEqualStrings("default-src 'self'; script-src 'self'; style-src 'self' 'sha256-B'; object-src 'none'", strict);
    // Derived from default-src.
    const derived = (try withHashes(gpa, "default-src 'self' https://x.example", "'sha256-A'", "")).?;
    defer gpa.free(derived);
    try std.testing.expectEqualStrings("default-src 'self' https://x.example; script-src 'self' https://x.example 'sha256-A'", derived);
    const from_none = (try withHashes(gpa, "default-src 'none';", "'sha256-A'", "'sha256-B'")).?;
    defer gpa.free(from_none);
    try std.testing.expectEqualStrings("default-src 'none'; script-src 'sha256-A'; style-src 'sha256-B'", from_none);
    // Nothing to add, or nothing restricted, or already unsafe-inline.
    try std.testing.expect(try withHashes(gpa, default, "", "") == null);
    try std.testing.expect(try withHashes(gpa, "img-src 'self'", "'sha256-A'", "") == null);
    try std.testing.expect(try withHashes(gpa, "script-src 'self' 'unsafe-inline'", "'sha256-A'", "") == null);
}

test strictStyles {
    try std.testing.expectEqualStrings(
        "default-src 'self'; style-src 'self'; img-src data:",
        comptime strictStyles("default-src 'self'; style-src 'self' 'unsafe-inline'; img-src data:"),
    );
}
