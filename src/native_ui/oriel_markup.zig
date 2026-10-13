//! The .oriel grammar, compiled at build time: an XML-style tree of native
//! elements and their attributes. Unknown elements/attributes and malformed
//! markup are build errors.
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
};
pub const Plan = struct { nodes: [512]Spec = undefined, len: usize = 0 };

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

pub fn parse(comptime source: []const u8) Plan {
    @setEvalBranchQuota(1000000);
    var out: Plan = .{};
    var stack: [32]usize = undefined;
    var depth: usize = 0;
    var at: usize = 0;
    while (at < source.len) {
        skip(source, &at);
        if (at == source.len) break;
        if (source[at] != '<') {
            const start = at;
            while (at < source.len and source[at] != '<') : (at += 1) {}
            if (depth == 0 or !element(out.nodes[stack[depth - 1]].tag).text) @compileError(".oriel text requires a <text> element");
            out.nodes[stack[depth - 1]].text = std.mem.trim(u8, source[start..at], " \t\r\n");
            continue;
        }
        at += 1;
        const closing = at < source.len and source[at] == '/';
        if (closing) at += 1;
        const tag = word(source, &at);
        if (closing) {
            skip(source, &at);
            if (depth == 0 or at == source.len or source[at] != '>' or !std.mem.eql(u8, tag, out.nodes[stack[depth - 1]].tag)) @compileError(".oriel mismatched closing element");
            depth -= 1;
            at += 1;
            continue;
        }
        if (std.mem.eql(u8, tag, "option")) {
            if (depth == 0 or out.nodes[stack[depth - 1]].kind != .select) @compileError(".oriel <option> belongs in a <select>");
            option(source, &at, &out.nodes[stack[depth - 1]]);
            continue;
        }
        if (out.len == out.nodes.len or depth == stack.len) @compileError(".oriel template exceeds node/depth limit");
        if (depth > 0 and !element(out.nodes[stack[depth - 1]].tag).children) @compileError(".oriel <" ++ out.nodes[stack[depth - 1]].tag ++ "> cannot have child elements");
        if (out.len > 0 and depth == 0) @compileError(".oriel needs exactly one root element");
        var n = newSpec(tag, if (depth > 0) stack[depth - 1] else null);
        skip(source, &at);
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
            attribute(&n, key, source[begin..at]);
            at += 1;
            skip(source, &at);
        }
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
    if ((s.len != 7 and s.len != 9) or s[0] != '#') @compileError(".oriel colors use #RRGGBB or #RRGGBBAA");
    const v = std.fmt.parseInt(u24, s[1..7], 16) catch @compileError("Invalid .oriel color");
    const alpha: f32 = if (s.len == 9) @as(f32, @floatFromInt(std.fmt.parseInt(u8, s[7..9], 16) catch @compileError("Invalid .oriel alpha"))) / 255 else 1;
    return .{ @floatFromInt(v >> 16), @floatFromInt((v >> 8) & 255), @floatFromInt(v & 255), alpha };
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
