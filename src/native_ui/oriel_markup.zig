//! The .oriel grammar, compiled at build time: an XML-style tree of native
//! elements and their attributes, styled by a <style> sheet before the
//! root. Unknown elements, attributes and styles, and malformed markup, are
//! build errors.
//!
//!     <style>
//!       $muted: #8f97a8                        a token, `$muted` in any value
//!       hud: font-size=14 color=$muted         a named style: class="hud"
//!       @media (max-width: 520) {              while the window is that narrow
//!         title: display=none
//!       }
//!       @media (prefers-color-scheme: light) { $muted: #5b6475 }
//!     </style>
//!
//! An element's props: its styles' rules (in its `class` order), then the
//! matching media blocks' rules for them, then its own attributes (as an
//! inline style). Text styles (font, color, line height, spacing,
//! alignment, nowrap) are inherited from the elements around it, as CSS's.
//! Every combination of media blocks is compiled (`parseVariant`); ui.zig
//! switches a view's variant when the window's width or theme changes.
const std = @import("std");
const tree = @import("tree.zig");

/// An element's accessibility entry, as far as the markup decides it.
/// `name_from_content`: named by the text inside it when it has no label.
pub const AxSpec = struct {
    role: tree.AxRole,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    level: u8 = 0,
    focusable: bool = false,
    name_from_content: bool = false,
};

pub const Spec = struct {
    kind: tree.Kind,
    tag: []const u8,
    name: []const u8 = "",
    text: []const u8 = "",
    parent: ?usize,
    props: tree.Props,
    ax: ?AxSpec = null,
    /// An explicit `role`, `level`, `description` or `focusable` (applied
    /// after the element's own defaults).
    role: ?tree.AxRole = null,
    level: u8 = 0,
    description: ?[]const u8 = null,
    alt: ?[]const u8 = null,
    focusable: ?bool = null,
    /// A <text> with <span>s: its runs in order (its own text, outside
    /// spans, is runs in its own style); none: one run of `text`.
    runs: []const RunSpec = &.{},
    /// The inherited text styles it sets itself (`Inherit` bits).
    inh: u16 = 0,
};

/// An attribute as written (key, value with `$tokens` unresolved).
pub const Attr = struct { key: []const u8, value: []const u8 };

/// When a media block applies: each condition set must hold.
pub const Cond = struct {
    max_w: ?f32 = null,
    min_w: ?f32 = null,
    dark: ?bool = null,

    pub fn matches(c: Cond, width: f32, dark: bool) bool {
        if (c.max_w) |m| if (width > m) return false;
        if (c.min_w) |m| if (width < m) return false;
        if (c.dark) |d| if (dark != d) return false;
        return true;
    }
};

const Rule = struct { name: []const u8, attrs: []const Attr };
const Media = struct { cond: Cond, tokens: []const Attr, rules: []const Rule };
/// A view's <style>: tokens, named styles, media blocks (at most
/// `max_media`: each combination is compiled).
const Sheet = struct { tokens: []const Attr = &.{}, rules: []const Rule = &.{}, media: []const Media = &.{} };
pub const max_media = 4;

/// A run of a <text>: `t` literal or a whole `{binding}`, and what a
/// <span> sets over the text's own style.
pub const RunSpec = struct {
    t: []const u8,
    col: ?tree.Color = null,
    fwt: ?f32 = null,
    fz: ?f32 = null,
    mono: ?bool = null,
    it: ?bool = null,
    ff: ?[]const u8 = null,
};
pub const Plan = struct {
    nodes: [512]Spec = undefined,
    len: usize = 0,
    /// The sheet's media blocks' conditions: variant bit i is block i.
    media: [max_media]Cond = undefined,
    media_len: usize = 0,
};

/// The elements: their native kind and what they start with.
const Element = struct { tag: []const u8, kind: tree.Kind, children: bool = false, text: bool = false };
const elements = [_]Element{
    .{ .tag = "view", .kind = .view, .children = true },
    .{ .tag = "row", .kind = .view, .children = true },
    .{ .tag = "column", .kind = .view, .children = true },
    .{ .tag = "button", .kind = .view, .children = true },
    .{ .tag = "text", .kind = .text, .text = true },
    .{ .tag = "canvas", .kind = .canvas },
    .{ .tag = "input", .kind = .input },
    .{ .tag = "textarea", .kind = .textarea },
    .{ .tag = "select", .kind = .select },
    .{ .tag = "checkbox", .kind = .check },
    .{ .tag = "radio", .kind = .check },
    .{ .tag = "slider", .kind = .input },
    .{ .tag = "control", .kind = .button },
    .{ .tag = "image", .kind = .image },
};

fn element(comptime tag: []const u8) Element {
    for (elements) |e| if (std.mem.eql(u8, e.tag, tag)) return e;
    @compileError("Unknown .oriel element: " ++ tag);
}

/// The view with no media block applying.
pub fn parse(comptime source: []const u8) Plan {
    return parseVariant(source, 0);
}

/// The view with the media blocks of `mask` applying (bit i: block i).
pub fn parseVariant(comptime source: []const u8, comptime mask: u32) Plan {
    @setEvalBranchQuota(4000000);
    var out: Plan = .{};
    var sheet: Sheet = .{};
    var stack: [32]usize = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    while (at < source.len) {
        // In a <text> the spaces between words and spans are text.
        const in_text = depth > 0 and element(out.nodes[stack[depth - 1]].tag).text;
        if (!in_text) skip(source, &at);
        if (at == source.len) break;
        if (source[at] != '<') {
            const start = at;
            while (at < source.len and source[at] != '<') : (at += 1) {}
            if (!in_text) @compileError(".oriel text requires a <text> element");
            textSegment(&out.nodes[stack[depth - 1]], source[start..at]);
            continue;
        }
        at += 1;
        const closing = at < source.len and source[at] == '/';
        if (closing) at += 1;
        const tag = word(source, &at);
        if (closing) {
            skip(source, &at);
            if (depth == 0 or at == source.len or source[at] != '>' or !std.mem.eql(u8, tag, out.nodes[stack[depth - 1]].tag)) @compileError(".oriel mismatched closing element");
            if (element(tag).text) finishText(&out.nodes[stack[depth - 1]]);
            depth -= 1;
            at += 1;
            continue;
        }
        if (std.mem.eql(u8, tag, "span")) {
            if (depth == 0 or !element(out.nodes[stack[depth - 1]].tag).text) @compileError(".oriel <span> belongs in a <text>");
            span(source, &at, &out.nodes[stack[depth - 1]], sheet, mask);
            continue;
        }
        if (std.mem.eql(u8, tag, "option")) {
            if (depth == 0 or out.nodes[stack[depth - 1]].kind != .select) @compileError(".oriel <option> belongs in a <select>");
            option(source, &at, &out.nodes[stack[depth - 1]]);
            continue;
        }
        if (std.mem.eql(u8, tag, "style")) {
            if (depth != 0 or out.len != 0) @compileError(".oriel <style> comes first, before the root element");
            skip(source, &at);
            if (at == source.len or source[at] != '>') @compileError(".oriel <style> takes no attributes");
            at += 1;
            const close = std.mem.indexOfPos(u8, source, at, "</style>") orelse @compileError(".oriel <style> needs </style>");
            sheet = parseSheet(source[at..close]);
            if (sheet.media.len > max_media) @compileError(".oriel <style> has more than 4 @media blocks");
            for (sheet.media, 0..) |m, i| out.media[i] = m.cond;
            out.media_len = sheet.media.len;
            at = close + "</style>".len;
            continue;
        }
        if (out.len == out.nodes.len or depth == stack.len) @compileError(".oriel template exceeds node/depth limit");
        if (depth > 0 and !element(out.nodes[stack[depth - 1]].tag).children) @compileError(".oriel <" ++ out.nodes[stack[depth - 1]].tag ++ "> cannot have child elements");
        if (out.len > 0 and depth == 0) @compileError(".oriel needs exactly one root element");
        var n = newSpec(tag, if (depth > 0) stack[depth - 1] else null);
        skip(source, &at);
        var attrs: []const Attr = &.{};
        while (at < source.len and source[at] != '>' and source[at] != '/') {
            const key = word(source, &at);
            skip(source, &at);
            if (at == source.len or source[at] != '=') @compileError(".oriel attribute needs =");
            at += 1;
            skip(source, &at);
            if (at == source.len or source[at] != '"') @compileError(".oriel attribute needs a quoted value");
            at += 1;
            const begin = at;
            while (at < source.len and source[at] != '"') : (at += 1) {}
            if (at == source.len) @compileError(".oriel unterminated attribute");
            attrs = attrs ++ &[_]Attr{.{ .key = key, .value = source[begin..at] }};
            at += 1;
            skip(source, &at);
        }
        cascade(&n, attrs, sheet, mask);
        const empty = at < source.len and source[at] == '/';
        if (empty) at += 1;
        if (at == source.len or source[at] != '>') @compileError(".oriel unterminated element");
        at += 1;
        finish(&n);
        out.nodes[out.len] = n;
        if (!empty) {
            stack[depth] = out.len;
            depth += 1;
        }
        out.len += 1;
    }
    if (depth != 0 or out.len == 0) @compileError(".oriel incomplete template");
    // `visible` is inherited, as CSS's visibility: a hidden element hides
    // what's in it (the platform's widgets too) unless one says visible.
    // So are text styles. (Parents come before their children.)
    for (out.nodes[0..out.len]) |*node| {
        const parent = node.parent orelse continue;
        if (node.props.vis == null and out.nodes[parent].props.vis == false) node.props.vis = false;
        // Form controls don't (the UA styles of CSS set their own font).
        const control = switch (node.kind) {
            .input, .textarea, .select, .check, .button => true,
            else => false,
        };
        if (!control) inherit(node, out.nodes[parent]);
    }
    for (out.nodes[0..out.len], 0..) |node, i| {
        if (node.name.len == 0) continue;
        for (out.nodes[0..i]) |other| if (std.mem.eql(u8, node.name, other.name)) @compileError("Duplicate .oriel id: " ++ node.name);
    }
    return out;
}

/// An element before its attributes: its kind and defaults.
fn newSpec(comptime tag: []const u8, parent: ?usize) Spec {
    const e = element(tag);
    var n: Spec = .{ .tag = tag, .kind = e.kind, .parent = parent, .props = .{ .fz = 14, .col = .{ 230, 232, 236, 1 } } };
    if (e.kind == .view or e.kind == .button or e.kind == .input or e.kind == .textarea or e.kind == .select) n.props.fs = 0;
    if (std.mem.eql(u8, tag, "row")) n.props.fd = "row";
    if (std.mem.eql(u8, tag, "column")) n.props.fd = "column";
    if (std.mem.eql(u8, tag, "button")) n.props.click = true;
    if (std.mem.eql(u8, tag, "checkbox") or std.mem.eql(u8, tag, "radio")) {
        n.props.ctl = tag;
        n.props.click = true;
        n.props.w = .{ .px = 13 };
        n.props.h = .{ .px = 13 };
        n.props.fs = 0;
    }
    if (std.mem.eql(u8, tag, "slider")) n.props.range = .{ 0, 100, 1 };
    return n;
}

/// Defaults that depend on attributes, and the accessibility entry.
fn finish(n: *Spec) void {
    if (n.kind == .image and n.props.src == null) @compileError(".oriel <image> needs src");
    if (n.kind == .select and n.props.options == null) n.props.options = &.{};
    // Native widgets carry their own accessibility element (named from
    // `label`); drawn elements get an entry.
    var ax: ?AxSpec = null;
    if (std.mem.eql(u8, n.tag, "button")) ax = .{ .role = .button, .focusable = true, .name_from_content = true };
    if (n.kind == .image) ax = if (n.alt) |alt| .{ .role = .img, .name = alt } else null;
    if (n.role) |role| {
        if (ax == null) ax = .{ .role = role, .name_from_content = role == .heading or role == .link or role == .button };
        ax.?.role = role;
    }
    if (ax) |*a| {
        if (n.props.al) |label| a.name = label;
        a.description = n.description;
        a.level = n.level;
        if (n.focusable) |f| a.focusable = f;
    } else if (n.level != 0 or n.description != null) @compileError(".oriel level/description need a role (or a drawn <button>/<image>)");
    if (n.focusable == true and ax == null) ax = .{ .role = .generic, .focusable = true };
    // A drawn element Tab visits behaves as `tabindex="0"` (a drawn
    // <button> is a `<div role="button" tabindex="0">`): every platform.
    if (ax) |a| if (a.focusable) {
        n.props.ti = 0;
    };
    n.ax = ax;
}

/// An element's props from its styles, the media blocks applying, and its
/// own attributes, in that order (later wins).
fn cascade(n: *Spec, comptime attrs: []const Attr, comptime sheet: Sheet, comptime mask: u32) void {
    const tokens = tokensOf(sheet, mask);
    for (attrs) |a| if (std.mem.eql(u8, a.key, "class")) {
        var names = std.mem.tokenizeScalar(u8, a.value, ' ');
        while (names.next()) |name| {
            const rule = ruleOf(sheet.rules, name) orelse @compileError(".oriel style not in the <style>: " ++ name);
            for (rule.attrs) |r| apply(n, r.key, substitute(r.value, tokens));
            for (sheet.media, 0..) |m, i| if (mask & (1 << i) != 0) if (ruleOf(m.rules, name)) |mr| {
                for (mr.attrs) |r| apply(n, r.key, substitute(r.value, tokens));
            };
        }
    };
    for (attrs) |a| if (!std.mem.eql(u8, a.key, "class")) apply(n, a.key, substitute(a.value, tokens));
}

fn ruleOf(comptime rules: []const Rule, comptime name: []const u8) ?Rule {
    for (rules) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// The tokens with the media blocks of `mask` applying (later wins).
fn tokensOf(comptime sheet: Sheet, comptime mask: u32) []const Attr {
    var out: []const Attr = sheet.tokens;
    for (sheet.media, 0..) |m, i| if (mask & (1 << i) != 0) {
        out = m.tokens ++ out; // found first
    };
    return out;
}

/// `$name`s in a value replaced by their tokens.
fn substitute(comptime value: []const u8, comptime tokens: []const Attr) []const u8 {
    if (std.mem.indexOfScalar(u8, value, '$') == null) return value;
    var out: []const u8 = "";
    var i: usize = 0;
    while (i < value.len) {
        if (value[i] != '$') {
            out = out ++ value[i .. i + 1];
            i += 1;
            continue;
        }
        var end = i + 1;
        while (end < value.len and (std.ascii.isAlphanumeric(value[end]) or value[end] == '-' or value[end] == '_')) end += 1;
        const name = value[i + 1 .. end];
        const t = for (tokens) |t| {
            if (std.mem.eql(u8, t.key, name)) break t.value;
        } else @compileError(".oriel token not in the <style>: $" ++ name);
        out = out ++ t;
        i = end;
    }
    return out;
}

/// The text styles an element inherits (CSS's inherited properties).
const Inherit = enum(u4) { ff, fz, fwt, col, lh, ls, mono, it, ta, nowrap };
fn inheritBit(comptime key: []const u8) ?u16 {
    const keys = .{ .{ "font-family", .ff }, .{ "font-size", .fz }, .{ "font-weight", .fwt }, .{ "color", .col }, .{ "line-height", .lh }, .{ "letter-spacing", .ls }, .{ "mono", .mono }, .{ "italic", .it }, .{ "text-align", .ta }, .{ "nowrap", .nowrap } };
    inline for (keys) |k| if (std.mem.eql(u8, k[0], key)) return @as(u16, 1) << @intFromEnum(@as(Inherit, k[1]));
    return null;
}

fn apply(n: *Spec, comptime key: []const u8, comptime value: []const u8) void {
    if (inheritBit(key)) |bit| n.inh |= bit;
    attribute(n, key, value);
}

/// The text styles `n` doesn't set itself, from `parent` (which has them
/// from its own parents by now).
fn inherit(n: *Spec, parent: Spec) void {
    inline for (std.meta.fields(Inherit)) |f| {
        const bit = @as(u16, 1) << f.value;
        if (n.inh & bit == 0 and parent.inh & bit != 0) {
            @field(n.props, f.name) = @field(parent.props, f.name);
            n.inh |= bit;
        }
    }
}

/// A <style>'s text: `$token: value` lines, `name: key=value ...` rules,
/// and `@media (cond) [and (cond)] { ... }` blocks of both.
fn parseSheet(comptime s: []const u8) Sheet {
    var sheet: Sheet = .{};
    var at: usize = 0;
    while (true) {
        skipSheet(s, &at);
        if (at == s.len) break;
        if (std.mem.startsWith(u8, s[at..], "@media")) {
            at += "@media".len;
            const cond = mediaCond(s, &at);
            const block = sheetBlock(s, &at);
            sheet.media = sheet.media ++ &[_]Media{.{ .cond = cond, .tokens = block.tokens, .rules = block.rules }};
            continue;
        }
        const item = sheetItem(s, &at);
        if (item.token) |t| sheet.tokens = sheet.tokens ++ &[_]Attr{t} else sheet.rules = sheet.rules ++ &[_]Rule{item.rule.?};
    }
    return sheet;
}

/// `{ items }` after a media condition.
fn sheetBlock(comptime s: []const u8, at: *usize) Sheet {
    skipSheet(s, at);
    if (at.* == s.len or s[at.*] != '{') @compileError(".oriel @media needs { ... }");
    at.* += 1;
    var block: Sheet = .{};
    while (true) {
        skipSheet(s, at);
        if (at.* == s.len) @compileError(".oriel @media block needs }");
        if (s[at.*] == '}') {
            at.* += 1;
            return block;
        }
        const item = sheetItem(s, at);
        if (item.token) |t| block.tokens = block.tokens ++ &[_]Attr{t} else block.rules = block.rules ++ &[_]Rule{item.rule.?};
    }
}

/// `(max-width: 520) and (prefers-color-scheme: dark)`.
fn mediaCond(comptime s: []const u8, at: *usize) Cond {
    var c: Cond = .{};
    while (true) {
        skipSheet(s, at);
        if (at.* == s.len or s[at.*] != '(') @compileError(".oriel @media needs (condition)");
        const close = std.mem.indexOfScalarPos(u8, s, at.*, ')') orelse @compileError(".oriel @media condition needs )");
        const inner = s[at.* + 1 .. close];
        const colon = std.mem.indexOfScalar(u8, inner, ':') orelse @compileError(".oriel @media condition is (feature: value)");
        const feature = std.mem.trim(u8, inner[0..colon], " ");
        const value = std.mem.trim(u8, inner[colon + 1 ..], " ");
        const px = std.mem.trimEnd(u8, value, "px");
        if (std.mem.eql(u8, feature, "max-width")) c.max_w = number(px) //
        else if (std.mem.eql(u8, feature, "min-width")) c.min_w = number(px) //
        else if (std.mem.eql(u8, feature, "prefers-color-scheme")) c.dark = std.mem.eql(u8, oneOf("prefers-color-scheme", value, &.{ "dark", "light" }), "dark") //
        else @compileError(".oriel @media knows max-width, min-width and prefers-color-scheme, not " ++ feature);
        at.* = close + 1;
        skipSheet(s, at);
        if (!std.mem.startsWith(u8, s[at.*..], "and")) return c;
        at.* += "and".len;
    }
}

const SheetItem = struct { token: ?Attr = null, rule: ?Rule = null };

/// `$name: value` (to the end of its line) or `name: key=value ...` (to the
/// next item, `}` or the end).
fn sheetItem(comptime s: []const u8, at: *usize) SheetItem {
    if (s[at.*] == '$') {
        at.* += 1;
        const name = word(s, at);
        skipSheet(s, at);
        if (at.* == s.len or s[at.*] != ':') @compileError(".oriel token needs : ($name: value)");
        at.* += 1;
        const end = std.mem.indexOfAnyPos(u8, s, at.*, "\n}") orelse s.len;
        const value = std.mem.trim(u8, s[at.*..end], " \t\r\";");
        at.* = end;
        return .{ .token = .{ .key = name, .value = value } };
    }
    const name = word(s, at);
    skipSheet(s, at);
    if (at.* == s.len or s[at.*] != ':') @compileError(".oriel style needs : (name: key=value ...)");
    at.* += 1;
    var attrs: []const Attr = &.{};
    while (true) {
        skipSheet(s, at);
        if (at.* == s.len or s[at.*] == '}' or s[at.*] == '$' or s[at.*] == '@' or ruleStarts(s, at.*)) break;
        const key = word(s, at);
        if (at.* == s.len or s[at.*] != '=') @compileError(".oriel style attribute needs = (key=value): " ++ key);
        at.* += 1;
        var value: []const u8 = undefined;
        if (at.* < s.len and s[at.*] == '"') {
            const close = std.mem.indexOfScalarPos(u8, s, at.* + 1, '"') orelse @compileError(".oriel unterminated style value");
            value = s[at.* + 1 .. close];
            at.* = close + 1;
        } else {
            const begin = at.*;
            while (at.* < s.len and !std.ascii.isWhitespace(s[at.*]) and s[at.*] != '}') at.* += 1;
            value = s[begin..at.*];
        }
        attrs = attrs ++ &[_]Attr{.{ .key = key, .value = value }};
    }
    return .{ .rule = .{ .name = name, .attrs = attrs } };
}

/// A name followed by `:` (the next style), not `=` (an attribute).
fn ruleStarts(comptime s: []const u8, from: usize) bool {
    var i = from;
    while (i < s.len and (std.ascii.isAlphanumeric(s[i]) or s[i] == '-' or s[i] == '_')) i += 1;
    if (i == from) return false;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i < s.len and s[i] == ':';
}

/// Spaces, `;` and `/* comments */`.
fn skipSheet(s: []const u8, at: *usize) void {
    while (at.* < s.len) {
        if (std.ascii.isWhitespace(s[at.*]) or s[at.*] == ';') {
            at.* += 1;
        } else if (std.mem.startsWith(u8, s[at.*..], "/*")) {
            at.* = if (std.mem.indexOfPos(u8, s, at.* + 2, "*/")) |e| e + 2 else s.len;
        } else return;
    }
}

/// Text inside a <text> (between its spans, or all of it).
fn textSegment(n: *Spec, raw: []const u8) void {
    if (n.runs.len == 0) {
        n.text = n.text ++ raw;
    } else n.runs = n.runs ++ &[_]RunSpec{.{ .t = raw }};
}

/// `<span attrs>text</span>` in a <text>: a run in its own style. The
/// text before the first span becomes the first run.
fn span(comptime s: []const u8, at: *usize, n: *Spec, comptime sheet: Sheet, comptime mask: u32) void {
    if (n.runs.len == 0 and n.text.len > 0) {
        n.runs = &[_]RunSpec{.{ .t = n.text }};
        n.text = "";
    }
    var run: RunSpec = .{ .t = "" };
    skip(s, at);
    while (at.* < s.len and s[at.*] != '>') {
        const key = word(s, at);
        skip(s, at);
        if (at.* == s.len or s[at.*] != '=') @compileError(".oriel attribute needs =");
        at.* += 1;
        skip(s, at);
        if (at.* == s.len or s[at.*] != '"') @compileError(".oriel attribute needs a quoted value");
        at.* += 1;
        const begin = at.*;
        while (at.* < s.len and s[at.*] != '"') : (at.* += 1) {}
        if (at.* == s.len) @compileError(".oriel unterminated attribute");
        spanAttribute(&run, key, substitute(s[begin..at.*], tokensOf(sheet, mask)));
        at.* += 1;
        skip(s, at);
    }
    if (at.* == s.len) @compileError(".oriel unterminated <span>");
    at.* += 1;
    const begin = at.*;
    while (at.* < s.len and s[at.*] != '<') : (at.* += 1) {}
    run.t = s[begin..at.*];
    const close = "</span>";
    if (!std.mem.startsWith(u8, s[at.*..], close)) @compileError(".oriel <span> holds text only, then </span>");
    at.* += close.len;
    n.runs = n.runs ++ &[_]RunSpec{run};
}

fn spanAttribute(run: *RunSpec, comptime key: []const u8, v: []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, key, "color")) run.col = color(v) //
    else if (eq(u8, key, "font-weight")) run.fwt = number(v) //
    else if (eq(u8, key, "font-size")) run.fz = number(v) //
    else if (eq(u8, key, "font-family")) run.ff = v //
    else if (eq(u8, key, "mono")) run.mono = boolean(v) //
    else if (eq(u8, key, "italic")) run.it = boolean(v) //
    else @compileError("Unknown .oriel <span> attribute: " ++ key);
}

/// A <text> closed: its text trimmed; with spans, spaces collapsed as HTML
/// does (one space for a run of them, none at either end), and runs left
/// empty dropped.
fn finishText(n: *Spec) void {
    if (n.runs.len == 0) {
        n.text = std.mem.trim(u8, n.text, " \t\r\n");
        return;
    }
    var runs: []const RunSpec = &.{};
    var space_before = true; // at the start: leading spaces go
    for (n.runs) |r| {
        var t: []const u8 = "";
        for (r.t) |c| {
            const ws = c == ' ' or c == '\t' or c == '\r' or c == '\n';
            if (ws and space_before) continue;
            t = t ++ &[_]u8{if (ws) ' ' else c};
            space_before = ws;
        }
        if (t.len == 0) continue;
        var run = r;
        run.t = t;
        runs = runs ++ &[_]RunSpec{run};
    }
    // The trailing space of the last run goes too.
    if (runs.len > 0 and std.mem.endsWith(u8, runs[runs.len - 1].t, " ")) {
        var last = runs[runs.len - 1];
        last.t = last.t[0 .. last.t.len - 1];
        runs = runs[0 .. runs.len - 1] ++ if (last.t.len > 0) &[_]RunSpec{last} else &[_]RunSpec{};
    }
    n.runs = runs;
}

/// `<option value="v">Label</option>`: one entry of the select's options.
fn option(comptime s: []const u8, at: *usize, select: *Spec) void {
    skip(s, at);
    var value: ?[]const u8 = null;
    if (at.* < s.len and s[at.*] != '>') {
        const key = word(s, at);
        if (!std.mem.eql(u8, key, "value")) @compileError(".oriel <option> takes only value");
        skip(s, at);
        if (at.* == s.len or s[at.*] != '=') @compileError(".oriel attribute needs =");
        at.* += 1;
        skip(s, at);
        if (at.* == s.len or s[at.*] != '"') @compileError(".oriel attribute needs a quoted value");
        at.* += 1;
        const begin = at.*;
        while (at.* < s.len and s[at.*] != '"') : (at.* += 1) {}
        if (at.* == s.len) @compileError(".oriel unterminated attribute");
        value = s[begin..at.*];
        at.* += 1;
        skip(s, at);
    }
    if (at.* == s.len or s[at.*] != '>') @compileError(".oriel unterminated <option>");
    at.* += 1;
    const begin = at.*;
    while (at.* < s.len and s[at.*] != '<') : (at.* += 1) {}
    const label = std.mem.trim(u8, s[begin..at.*], " \t\r\n");
    const close = "</option>";
    if (!std.mem.startsWith(u8, s[at.*..], close)) @compileError(".oriel <option> needs </option>");
    at.* += close.len;
    const entry: [2][]const u8 = .{ value orelse label, label };
    select.props.options = (select.props.options orelse &.{}) ++ &[_][2][]const u8{entry};
}

fn skip(s: []const u8, at: *usize) void {
    while (at.* < s.len and std.ascii.isWhitespace(s[at.*])) : (at.* += 1) {}
}
fn word(s: []const u8, at: *usize) []const u8 {
    const start_at = at.*;
    while (at.* < s.len and (std.ascii.isAlphanumeric(s[at.*]) or s[at.*] == '-' or s[at.*] == '_')) : (at.* += 1) {}
    if (start_at == at.*) @compileError(".oriel expected a name");
    return s[start_at..at.*];
}
fn number(s: []const u8) f32 {
    const n = std.fmt.parseFloat(f32, s) catch @compileError("Invalid .oriel number: " ++ s);
    if (!std.math.isFinite(n)) @compileError("Non-finite .oriel number");
    return n;
}
fn dim(s: []const u8) tree.Dim {
    if (std.mem.eql(u8, s, "auto")) return .auto; // a media block undoing a size
    return if (std.mem.endsWith(u8, s, "%")) .{ .pct = number(s[0 .. s.len - 1]) } else .{ .px = number(s) };
}
/// One or four comma-separated dimensions (top, right, bottom, left).
fn sides(comptime what: []const u8, s: []const u8) [4]tree.Dim {
    var it = std.mem.splitScalar(u8, s, ',');
    var a: [4]tree.Dim = undefined;
    var i: usize = 0;
    while (it.next()) |x| {
        if (i == 4) @compileError(".oriel " ++ what ++ " needs one or four numbers");
        a[i] = dim(std.mem.trim(u8, x, " "));
        i += 1;
    }
    if (i == 1) return @splat(a[0]);
    if (i != 4) @compileError(".oriel " ++ what ++ " needs one or four numbers");
    return a;
}
fn color(s: []const u8) tree.Color {
    if (std.mem.startsWith(u8, s, "rgba(") and std.mem.endsWith(u8, s, ")")) return rgba(s[5 .. s.len - 1]);
    if ((s.len != 7 and s.len != 9) or s[0] != '#') @compileError(".oriel colors use #RRGGBB, #RRGGBBAA or rgba(r, g, b, a)");
    const v = std.fmt.parseInt(u24, s[1..7], 16) catch @compileError("Invalid .oriel color");
    const alpha: f32 = if (s.len == 9) @as(f32, @floatFromInt(std.fmt.parseInt(u8, s[7..9], 16) catch @compileError("Invalid .oriel alpha"))) / 255 else 1;
    return .{ @floatFromInt(v >> 16), @floatFromInt((v >> 8) & 255), @floatFromInt(v & 255), alpha };
}
/// `rgba(r, g, b, a)`: an alpha #RRGGBBAA can't say exactly (0.72).
fn rgba(s: []const u8) tree.Color {
    var out: tree.Color = undefined;
    var it = std.mem.splitScalar(u8, s, ',');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == 4) @compileError(".oriel rgba() takes four numbers");
        out[i] = number(std.mem.trim(u8, part, " "));
    }
    if (i != 4) @compileError(".oriel rgba() takes four numbers");
    for (out[0..3]) |c| if (c < 0 or c > 255) @compileError(".oriel rgba() channels are 0-255");
    if (out[3] < 0 or out[3] > 1) @compileError(".oriel rgba() alpha is 0-1");
    return out;
}

fn boolean(s: []const u8) bool {
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    @compileError(".oriel boolean must be true or false");
}
fn oneOf(comptime what: []const u8, s: []const u8, comptime allowed: []const []const u8) []const u8 {
    for (allowed) |a| if (std.mem.eql(u8, a, s)) return a;
    @compileError(".oriel " ++ what ++ " can't be \"" ++ s ++ "\"");
}
fn inset(p: *tree.Props, side: usize, v: []const u8) void {
    if (p.ins == null) p.ins = @splat(null);
    p.ins.?[side] = dim(v);
}
/// `x,y,blur,#color` (and an optional spread before the color).
fn shadow(s: []const u8) tree.Shadow {
    var parts: [5][]const u8 = undefined;
    var i: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |x| {
        if (i == 5) @compileError(".oriel shadow is x,y,blur[,spread],#color");
        parts[i] = std.mem.trim(u8, x, " ");
        i += 1;
    }
    if (i < 4) @compileError(".oriel shadow is x,y,blur[,spread],#color");
    return .{ .x = number(parts[0]), .y = number(parts[1]), .blur = number(parts[2]), .spread = if (i == 5) number(parts[3]) else 0, .color = color(parts[i - 1]) };
}

/// One attribute: each group's function takes the ones it knows.
fn attribute(n: *Spec, comptime key: []const u8, v: []const u8) void {
    if (identity(n, key, v) or layout(&n.props, key, v) or drawing(&n.props, key, v) or text(&n.props, key, v) or controls(&n.props, key, v) or image(&n.props, key, v)) return;
    @compileError("Unknown .oriel attribute: " ++ key);
}

/// id, accessibility, focus and the tooltip.
fn identity(n: *Spec, comptime key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "id")) n.name = v //
    else if (eq(u8, key, "label")) n.props.al = v //
    else if (eq(u8, key, "role")) n.role = std.meta.stringToEnum(tree.AxRole, v) orelse @compileError(".oriel unknown role: " ++ v) //
    else if (eq(u8, key, "level")) n.level = headingLevel(v) //
    else if (eq(u8, key, "description")) n.description = v //
    else if (eq(u8, key, "alt")) n.alt = v //
    else if (eq(u8, key, "focusable")) n.focusable = boolean(v) //
    else if (eq(u8, key, "tooltip")) n.props.tip = v //
    else return false;
    return true;
}

fn headingLevel(v: []const u8) u8 {
    const level = std.fmt.parseInt(u8, v, 10) catch @compileError(".oriel level is 1-6");
    if (level < 1 or level > 6) @compileError(".oriel level is 1-6");
    return level;
}

/// Flex layout, sizes, spacing, position, scrolling, visibility.
fn layout(p: *tree.Props, comptime key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "gap")) {
        p.rg = number(v);
        p.cg = number(v);
    } else if (eq(u8, key, "row-gap")) p.rg = number(v) //
    else if (eq(u8, key, "column-gap")) p.cg = number(v) //
    else if (eq(u8, key, "width")) p.w = dim(v) //
    else if (eq(u8, key, "height")) p.h = dim(v) //
    else if (eq(u8, key, "min-width")) p.minw = dim(v) //
    else if (eq(u8, key, "min-height")) p.minh = dim(v) //
    else if (eq(u8, key, "max-width")) p.maxw = dim(v) //
    else if (eq(u8, key, "max-height")) p.maxh = dim(v) //
    else if (eq(u8, key, "aspect-ratio")) p.ar = number(v) //
    else if (eq(u8, key, "grow")) p.fg = number(v) //
    else if (eq(u8, key, "shrink")) p.fs = number(v) //
    else if (eq(u8, key, "basis")) p.fb = dim(v) //
    else if (eq(u8, key, "wrap")) p.fw = oneOf(key, v, &.{ "nowrap", "wrap", "wrap-reverse" }) //
    else if (eq(u8, key, "align")) p.ai = oneOf(key, v, &.{ "flex-start", "flex-end", "center", "stretch", "baseline", "start", "end" }) //
    else if (eq(u8, key, "align-self")) p.as = oneOf(key, v, &.{ "auto", "flex-start", "flex-end", "center", "stretch", "baseline", "start", "end" }) //
    else if (eq(u8, key, "justify")) p.jc = oneOf(key, v, &.{ "flex-start", "flex-end", "center", "space-between", "space-around", "space-evenly", "start", "end" }) //
    else if (eq(u8, key, "padding")) p.pad = sides(key, v) //
    else if (eq(u8, key, "margin")) p.m = sides(key, v) //
    else if (eq(u8, key, "position")) p.pos = oneOf(key, v, &.{ "relative", "absolute" }) //
    else if (eq(u8, key, "top")) inset(p, 0, v) //
    else if (eq(u8, key, "right")) inset(p, 1, v) //
    else if (eq(u8, key, "bottom")) inset(p, 2, v) //
    else if (eq(u8, key, "left")) inset(p, 3, v) //
    else if (eq(u8, key, "scroll")) p.scroll = boolean(v) //
    else if (eq(u8, key, "scroll-x")) p.scrollx = boolean(v) //
    else if (eq(u8, key, "clip")) p.clip = clipValue(v) //
    else if (eq(u8, key, "visible")) p.vis = boolean(v) //
    else if (eq(u8, key, "clickable")) p.click = boolean(v) //
    else if (eq(u8, key, "display")) p.none = eq(u8, oneOf(key, v, &.{ "flex", "none" }), "none") //
    else if (eq(u8, key, "box-sizing")) p.cb = eq(u8, oneOf(key, v, &.{ "border-box", "content-box" }), "content-box") //
    else if (eq(u8, key, "z")) p.z = std.fmt.parseInt(i32, v, 10) catch @compileError(".oriel z is an integer") //
    else return false;
    return true;
}

fn clipValue(v: []const u8) bool {
    if (!boolean(v)) @compileError("clip must be true");
    return true;
}

/// Background, corners, border, opacity, shadow.
fn drawing(p: *tree.Props, comptime key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "background")) p.bg = .{ .color = color(v) } //
    else if (eq(u8, key, "radius")) p.br = @splat(.{ .x = dim(v), .y = dim(v) }) //
    else if (eq(u8, key, "border-width")) p.bw = @splat(number(v)) //
    else if (eq(u8, key, "border-bottom")) p.bw = .{ 0, 0, number(v), 0 } //
    else if (eq(u8, key, "border-color")) p.bc = @splat(color(v)) //
    else if (eq(u8, key, "opacity")) p.op = number(v) //
    else if (eq(u8, key, "shadow")) p.sh = shadow(v) //
    else return false;
    return true;
}

/// Text color, font, alignment, spacing, wrapping.
fn text(p: *tree.Props, comptime key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "color")) p.col = color(v) //
    else if (eq(u8, key, "font-size")) p.fz = number(v) //
    else if (eq(u8, key, "font-weight")) p.fwt = number(v) //
    else if (eq(u8, key, "font-family")) p.ff = v //
    else if (eq(u8, key, "italic")) p.it = boolean(v) //
    else if (eq(u8, key, "mono")) p.mono = boolean(v) //
    else if (eq(u8, key, "text-align")) p.ta = oneOf(key, v, &.{ "left", "center", "right" }) //
    else if (eq(u8, key, "letter-spacing")) p.ls = number(v) //
    else if (eq(u8, key, "line-height")) p.lh = number(v) //
    else if (eq(u8, key, "nowrap")) p.nowrap = boolean(v) //
    else return false;
    return true;
}

/// Fields, checkboxes and the slider.
fn controls(p: *tree.Props, comptime key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "value")) p.val = v //
    else if (eq(u8, key, "placeholder")) p.ph = v //
    else if (eq(u8, key, "disabled")) p.dis = boolean(v) //
    else if (eq(u8, key, "readonly")) p.ro = boolean(v) //
    else if (eq(u8, key, "password")) p.pw = boolean(v) //
    else if (eq(u8, key, "rows")) p.rows = number(v) //
    else if (eq(u8, key, "cols")) p.cols = number(v) //
    else if (eq(u8, key, "checked")) p.on = boolean(v) //
    else if (eq(u8, key, "mixed")) p.mix = boolean(v) //
    else if (eq(u8, key, "accent")) p.acc = color(v) //
    else if (eq(u8, key, "min") or eq(u8, key, "max") or eq(u8, key, "step")) {
        const r = &(p.range orelse @compileError(".oriel " ++ key ++ " is for <slider>"));
        r.*[if (eq(u8, key, "min")) 0 else if (eq(u8, key, "max")) 1 else 2] = number(v);
    } else return false;
    return true;
}

fn image(p: *tree.Props, comptime key: []const u8, v: []const u8) bool {
    const eq = std.mem.eql;
    if (eq(u8, key, "src")) p.src = v //
    else if (eq(u8, key, "fit")) p.fit = oneOf(key, v, &.{ "fill", "contain", "cover", "none", "scale-down" }) //
    else return false;
    return true;
}

test ".oriel compiles hierarchy and literal text" {
    const p = comptime parse("<column id=\"root\"><row gap=\"8\"><text>Hello</text></row></column>");
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqualStrings("Hello", p.nodes[2].text);
    try std.testing.expectEqual(@as(?usize, 1), p.nodes[2].parent);
}

test ".oriel controls and scrolling compile native properties" {
    const p = comptime parse("<column scroll=\"true\" wrap=\"wrap\" justify=\"center\" background=\"#10203080\"><input value=\"test\" disabled=\"false\" /><control value=\"Refresh\" label=\"Refresh sample\" /></column>");
    try std.testing.expect(p.nodes[0].props.scroll);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), p.nodes[0].props.bg.?.color.?[3], 0.001);
    try std.testing.expectEqual(tree.Kind.input, p.nodes[1].kind);
    try std.testing.expectEqual(tree.Kind.button, p.nodes[2].kind);
    try std.testing.expectEqualStrings("Refresh sample", p.nodes[2].props.al.?);
}

test ".oriel spans: runs in their own style, spaces as HTML collapses them" {
    const p = comptime parse(
        \\<text color="#8f97a8" font-size="14">
        \\  Score <span color="#e8eaee" font-weight="700">{score}</span>
        \\</text>
    );
    const runs = p.nodes[0].runs;
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqualStrings("Score ", runs[0].t);
    try std.testing.expect(runs[0].col == null);
    try std.testing.expectEqualStrings("{score}", runs[1].t);
    try std.testing.expectEqual(@as(f32, 700), runs[1].fwt.?);
    const q = comptime parse("<text><span mono=\"true\">1</span> balls · <span>0</span> particles</text>");
    try std.testing.expectEqual(@as(usize, 4), q.nodes[0].runs.len);
    try std.testing.expectEqualStrings(" balls · ", q.nodes[0].runs[1].t);
    try std.testing.expectEqualStrings(" particles", q.nodes[0].runs[3].t);
    try std.testing.expectEqual(tree.Color{ 10, 13, 20, 0.72 }, (comptime parse("<view background=\"rgba(10, 13, 20, 0.72)\" />")).nodes[0].props.bg.?.color.?);
    // visible="false" is inherited, unless a child says otherwise.
    const h = comptime parse("<column visible=\"false\"><checkbox /><text visible=\"true\">x</text></column>");
    try std.testing.expectEqual(@as(?bool, false), h.nodes[1].props.vis);
    try std.testing.expectEqual(@as(?bool, true), h.nodes[2].props.vis);
    // Plain text is still one trimmed run.
    try std.testing.expectEqualStrings("Hello", (comptime parse("<text>  Hello  </text>")).nodes[0].text);
}

test ".oriel styles: named styles, tokens, media variants, inherited text" {
    const src =
        \\<style>
        \\  $muted: #8f97a8
        \\  $text: #e8eaee
        \\  /* the header */
        \\  top: padding=10,14,10,14 column-gap=14 font-family="system-ui, sans-serif" color=$text
        \\  hud: color=$muted nowrap=true
        \\  title: font-size=16 font-weight=700
        \\  @media (max-width: 520px) {
        \\    top: padding=8,10,8,10 column-gap=10
        \\    title: display=none
        \\  }
        \\  @media (prefers-color-scheme: light) and (min-width: 300) { $text: #111111 }
        \\</style>
        \\<row id="top" class="top">
        \\  <text id="title" class="title">Breakout</text>
        \\  <text id="score" class="hud" color="#ffffff">Score</text>
        \\  <checkbox id="c" />
        \\</row>
    ;
    const p = comptime parse(src);
    try std.testing.expectEqual(@as(usize, 2), p.media_len);
    try std.testing.expectEqual(@as(?f32, 520), p.media[0].max_w);
    try std.testing.expectEqual(@as(?bool, false), p.media[1].dark);
    try std.testing.expect(p.media[0].matches(400, true) and !p.media[0].matches(600, true));
    try std.testing.expect(p.media[1].matches(400, false) and !p.media[1].matches(400, true) and !p.media[1].matches(200, false));
    const top = p.nodes[0];
    try std.testing.expectEqual(@as(f32, 14), top.props.pad.?[1].px);
    try std.testing.expectEqual(@as(?f32, 14), top.props.cg);
    // Inherited: the title's font and color come from the row.
    const title = p.nodes[1];
    try std.testing.expectEqualStrings("system-ui, sans-serif", title.props.ff.?);
    try std.testing.expectEqual(tree.Color{ 232, 234, 238, 1 }, title.props.col.?);
    try std.testing.expectEqual(@as(?f32, 700), title.props.fwt);
    try std.testing.expect(!title.props.none);
    // The element's own attribute wins over its style.
    try std.testing.expectEqual(tree.Color{ 255, 255, 255, 1 }, p.nodes[2].props.col.?);
    try std.testing.expect(p.nodes[2].props.nowrap);
    // A form control doesn't inherit text styles.
    try std.testing.expect(p.nodes[3].props.ff == null);
    // Narrow: the media block's rules over the styles.
    const narrow = comptime parseVariant(src, 1);
    try std.testing.expectEqual(@as(f32, 10), narrow.nodes[0].props.pad.?[1].px);
    try std.testing.expectEqual(@as(?f32, 10), narrow.nodes[0].props.cg);
    try std.testing.expect(narrow.nodes[1].props.none);
    // Light: the token's other value, inherited too.
    const light = comptime parseVariant(src, 2);
    try std.testing.expectEqual(tree.Color{ 17, 17, 17, 1 }, light.nodes[1].props.col.?);
}

test ".oriel form controls, images and accessibility" {
    const p = comptime parse(
        \\<column>
        \\  <select id="size" value="m" label="Size"><option value="s">Small</option><option value="m">Medium</option><option>Large</option></select>
        \\  <checkbox id="agree" checked="true" label="I agree" />
        \\  <radio id="r1" />
        \\  <slider id="volume" min="0" max="10" step="0.5" value="3" />
        \\  <textarea rows="4" placeholder="Notes" />
        \\  <image src="logo.png" alt="Oriel logo" fit="contain" />
        \\  <image src="divider.png" />
        \\  <button id="go" tooltip="Start now" margin="4,8,4,8"><text>Go</text></button>
        \\  <text role="heading" level="2">Settings</text>
        \\</column>
    );
    const select = p.nodes[1];
    try std.testing.expectEqual(tree.Kind.select, select.kind);
    try std.testing.expectEqual(@as(usize, 3), select.props.options.?.len);
    try std.testing.expectEqualStrings("Large", select.props.options.?[2][0]);
    try std.testing.expectEqualStrings("Medium", select.props.options.?[1][1]);
    try std.testing.expect(select.ax == null);
    try std.testing.expectEqual(tree.Kind.check, p.nodes[2].kind);
    try std.testing.expect(p.nodes[2].props.on);
    try std.testing.expectEqualStrings("radio", p.nodes[3].props.ctl.?);
    try std.testing.expectEqual([3]f64{ 0, 10, 0.5 }, p.nodes[4].props.range.?);
    try std.testing.expectEqual(@as(f32, 4), p.nodes[5].props.rows.?);
    try std.testing.expectEqual(tree.AxRole.img, p.nodes[6].ax.?.role);
    try std.testing.expectEqualStrings("Oriel logo", p.nodes[6].ax.?.name.?);
    try std.testing.expect(p.nodes[7].ax == null);
    const go = p.nodes[8];
    try std.testing.expectEqual(tree.AxRole.button, go.ax.?.role);
    try std.testing.expect(go.ax.?.focusable and go.ax.?.name_from_content);
    try std.testing.expectEqualStrings("Start now", go.props.tip.?);
    try std.testing.expectEqual(@as(f32, 8), go.props.m.?[1].px);
    const heading = p.nodes[10];
    try std.testing.expectEqual(tree.AxRole.heading, heading.ax.?.role);
    try std.testing.expectEqual(@as(u8, 2), heading.ax.?.level);
}
