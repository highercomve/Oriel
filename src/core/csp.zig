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

    // A light HTML tokenizer: comments, other tags (whose attribute values
    // may contain "<script"), and raw-text elements whose content never runs
    // are skipped. Anything it gets wrong fails closed: the browser's hash
    // differs and that block is blocked, nothing extra is allowed.
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |lt| {
        i = lt + 1;
        const rest = html[lt..];
        if (std.mem.startsWith(u8, rest, "<!--")) {
            i = commentEnd(html, lt + 4) orelse break;
            continue;
        }
        if (rest.len < 2) break;
        if (rest[1] == '!' or rest[1] == '?' or rest[1] == '/') {
            // Doctype, processing instruction, end tag: up to its '>'.
            i = (std.mem.indexOfScalarPos(u8, html, lt, '>') orelse break) + 1;
            continue;
        }
        if (!std.ascii.isAlphabetic(rest[1])) continue;
        var name_end = lt + 1;
        while (name_end < html.len and !isTagDelimiter(html[name_end])) name_end += 1;
        const name = html[lt + 1 .. name_end];
        const tag_end = tagEnd(html, name_end) orelse break;
        i = tag_end + 1;
        const kind: enum { script, style, raw, other } = if (std.ascii.eqlIgnoreCase(name, "script"))
            .script
        else if (std.ascii.eqlIgnoreCase(name, "style"))
            .style
        else if (isOneOf(name, &.{ "textarea", "title", "xmp", "noscript", "noembed", "noframes", "iframe", "plaintext" }))
            .raw
        else
            .other;
        if (kind == .other) continue;
        const body_start = tag_end + 1;
        const close = findClose(html, body_start, name) orelse break;
        i = close;
        if (kind == .raw) continue; // text, never run: not hashed
        if (kind == .script and hasAttr(html[name_end..tag_end], "src")) continue;
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

fn isTagDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '\x0c', '/', '>' => true,
        else => false,
    };
}

/// Past the end of a comment whose `<!--` ends at `from`: `<!-->` and
/// `<!--->` end at once, otherwise at `-->` or `--!>`.
fn commentEnd(html: []const u8, from: usize) ?usize {
    const rest = html[from..];
    if (std.mem.startsWith(u8, rest, ">")) return from + 1;
    if (std.mem.startsWith(u8, rest, "->")) return from + 2;
    const a = std.mem.indexOfPos(u8, html, from, "-->");
    const b = std.mem.indexOfPos(u8, html, from, "--!>");
    if (a != null and (b == null or a.? < b.?)) return a.? + 3;
    if (b) |at| return at + 4;
    return null;
}

/// The index of the `>` closing a start tag. A quote only starts a value
/// right after `=`.
fn tagEnd(html: []const u8, from: usize) ?usize {
    var after_eq = false;
    var idx = from;
    while (idx < html.len) : (idx += 1) {
        const c = html[idx];
        switch (c) {
            '>' => return idx,
            '=' => after_eq = true,
            ' ', '\t', '\n', '\r', '\x0c' => {},
            '"', '\'' => {
                if (after_eq) idx = std.mem.indexOfScalarPos(u8, html, idx + 1, c) orelse return null;
                after_eq = false;
            },
            else => after_eq = false,
        }
    }
    return null;
}

/// The index of the end tag `</name` (case-insensitive, followed by
/// whitespace, `/` or `>`) at or after `from`.
fn findClose(html: []const u8, from: usize, name: []const u8) ?usize {
    var i = from;
    while (std.mem.indexOfPos(u8, html, i, "</")) |at| {
        const after = at + 2 + name.len;
        if (after < html.len and std.ascii.eqlIgnoreCase(html[at + 2 .. after], name) and isTagDelimiter(html[after])) return at;
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
        if (add.len == 0 or inlineAllowed(value)) continue;
        try w.writeByte(' ');
        try w.writeAll(add);
        changed = true;
    }
    if (default_src) |base| {
        if (inlineAllowed(base)) return finish(&out, changed);
        const none = isNone(base);
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

/// Whether a source list allows inline code through `'unsafe-inline'`
/// (which a hash or nonce source switches off, CSP3): adding hashes there
/// would change its meaning, so it's left alone.
fn inlineAllowed(value: []const u8) bool {
    if (!hasSource(value, "'unsafe-inline'")) return false;
    var it = std.mem.tokenizeAny(u8, value, " \t");
    while (it.next()) |s| {
        if (startsWithIgnoreCase(s, "'sha256-") or startsWithIgnoreCase(s, "'sha384-") or
            startsWithIgnoreCase(s, "'sha512-") or startsWithIgnoreCase(s, "'nonce-")) return false;
    }
    return true;
}

/// `'none'` counts only as the sole source (browsers ignore it otherwise).
fn isNone(value: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, value, " \t");
    const first = it.next() orelse return false;
    return std.ascii.eqlIgnoreCase(first, "'none'") and it.next() == null;
}

fn startsWithIgnoreCase(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
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
/// and `style-src-elem`. Without a `style-src`, one is made from
/// `default-src` minus `'unsafe-inline'` (none: styles were unrestricted,
/// which strict_styles can't mean, so that's a compile error). An explicit
/// `style-src-attr` is the app's choice and stays.
pub fn strictStyles(comptime csp: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var has_style_src = false;
        var default_src: ?[]const u8 = null;
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, csp, ';');
        while (it.next()) |part| {
            const d = std.mem.trim(u8, part, " \t");
            if (d.len == 0) continue;
            const end = std.mem.indexOfAny(u8, d, " \t") orelse d.len;
            const name = d[0..end];
            var directive: []const u8 = name;
            if (isOneOf(name, &.{ "style-src", "style-src-elem" })) {
                if (std.ascii.eqlIgnoreCase(name, "style-src")) has_style_src = true;
                directive = name ++ withoutUnsafeInline(d[end..]);
            } else directive = d;
            if (std.ascii.eqlIgnoreCase(name, "default-src")) default_src = d[end..];
            out = out ++ (if (out.len == 0) "" else "; ") ++ directive;
        }
        if (!has_style_src) {
            const base = default_src orelse @compileError("security.strict_styles: the CSP has neither style-src nor default-src, so styles are unrestricted");
            const sources = withoutUnsafeInline(base);
            out = out ++ "; style-src" ++ (if (sources.len == 0) " 'none'" else sources);
        }
        return out;
    }
}

/// " a b" for the sources of `value` other than `'unsafe-inline'`.
fn withoutUnsafeInline(comptime value: []const u8) []const u8 {
    var out: []const u8 = "";
    var toks = std.mem.tokenizeAny(u8, value, " \t");
    while (toks.next()) |t| {
        if (!std.ascii.eqlIgnoreCase(t, "'unsafe-inline'")) out = out ++ " " ++ t;
    }
    return out;
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

test "scanner edge cases (review)" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { []const u8, []const []const u8 }{
        // Short comment forms end at once; --!> ends a comment.
        .{ "<!--><script>a()</script>--><script>b()</script>", &.{ "a()", "b()" } },
        .{ "<!---><script>c()</script>", &.{"c()"} },
        .{ "<!-- x --!><script>d()</script>", &.{"d()"} },
        // A quote only opens a value after '='.
        .{ "<script data-x=a'b>real()</script>", &.{"real()"} },
        // "<script" inside another tag's attribute.
        .{ "<div title='<script >'><script>real()</script>", &.{"real()"} },
        // The end tag needs a delimiter.
        .{ "<script>x='</scripty>'</script >", &.{"x='</scripty>'"} },
        // Raw text never runs: not hashed.
        .{ "<textarea><script>shown()</script></textarea><title><script>t()</script></title>", &.{} },
    };
    for (cases) |c| {
        const h = try inlineHashes(gpa, c[0]);
        defer h.deinit(gpa);
        var want: std.ArrayList(u8) = .empty;
        defer want.deinit(gpa);
        for (c[1], 0..) |body, n| {
            if (n > 0) try want.append(gpa, ' ');
            try want.appendSlice(gpa, &hashSource(body));
        }
        try std.testing.expectEqualStrings(want.items, h.scripts);
    }
}

test "withHashes: 'none' with other sources, unsafe-inline next to a hash" {
    const gpa = std.testing.allocator;
    const mixed = (try withHashes(gpa, "default-src 'none' 'self'", "'sha256-A'", "")).?;
    defer gpa.free(mixed);
    try std.testing.expectEqualStrings("default-src 'none' 'self'; script-src 'none' 'self' 'sha256-A'", mixed);
    const ui = (try withHashes(gpa, "script-src 'self' 'unsafe-inline' 'nonce-x'", "'sha256-A'", "")).?;
    defer gpa.free(ui);
    try std.testing.expectEqualStrings("script-src 'self' 'unsafe-inline' 'nonce-x' 'sha256-A'", ui);
}

test strictStyles {
    try std.testing.expectEqualStrings(
        "default-src 'self' 'unsafe-inline'; style-src 'self'",
        comptime strictStyles("default-src 'self' 'unsafe-inline'"),
    );
    try std.testing.expectEqualStrings(
        "default-src 'self'; style-src 'self'; img-src data:",
        comptime strictStyles("default-src 'self'; style-src 'self' 'unsafe-inline'; img-src data:"),
    );
}
