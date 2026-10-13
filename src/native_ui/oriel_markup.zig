//! Small compile-time XML-style .oriel grammar for the renderer experiment.
//! Unknown elements/properties and malformed markup are build errors.
const std = @import("std");
const tree = @import("tree.zig");
pub const Spec = struct { kind: tree.Kind, tag: []const u8, name: []const u8 = "", text: []const u8 = "", parent: ?usize, props: tree.Props };
pub const Plan = struct { nodes: [512]Spec = undefined, len: usize = 0 };

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
            if (depth == 0 or out.nodes[stack[depth - 1]].kind != .text) @compileError(".oriel text requires a <text> element");
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
        if (out.len == out.nodes.len or depth == stack.len) @compileError(".oriel template exceeds node/depth limit");
        if (depth > 0 and out.nodes[stack[depth - 1]].kind != .view) @compileError(".oriel text/canvas elements cannot have child elements");
        if (out.len > 0 and depth == 0) @compileError(".oriel needs exactly one root element");
        var n: Spec = .{ .tag = tag, .kind = if (std.mem.eql(u8, tag, "text")) .text else if (std.mem.eql(u8, tag, "canvas")) .canvas else if (std.mem.eql(u8, tag, "input")) .input else if (std.mem.eql(u8, tag, "control")) .button else .view, .parent = if (depth > 0) stack[depth - 1] else null, .props = .{ .fz = 14, .col = .{ 230, 232, 236, 1 } } };
        if (std.mem.eql(u8, tag, "row")) n.props.fd = "row" else if (std.mem.eql(u8, tag, "column")) n.props.fd = "column" else if (!std.mem.eql(u8, tag, "view") and !std.mem.eql(u8, tag, "text") and !std.mem.eql(u8, tag, "button") and !std.mem.eql(u8, tag, "canvas") and !std.mem.eql(u8, tag, "input") and !std.mem.eql(u8, tag, "control")) @compileError("Unknown .oriel element: " ++ tag);
        if (n.kind == .view or n.kind == .button or n.kind == .input) n.props.fs = 0;
        if (std.mem.eql(u8, tag, "button")) n.props.click = true;
        skip(source, &at);
        while (at < source.len and source[at] != '>' and source[at] != '/') {
            const key = word(source, &at);
            skip(source, &at);
            if (at == source.len or source[at] != '=') @compileError(".oriel attribute needs =");
            at += 1;
            skip(source, &at);
            if (at == source.len or source[at] != '"') @compileError(".oriel attribute needs a quoted value");
            at += 1;
            const start = at;
            while (at < source.len and source[at] != '"') : (at += 1) {}
            if (at == source.len) @compileError(".oriel unterminated attribute");
            attribute(&n, key, source[start..at]);
            at += 1;
            skip(source, &at);
        }
        const empty = at < source.len and source[at] == '/';
        if (empty) at += 1;
        if (at == source.len or source[at] != '>') @compileError(".oriel unterminated element");
        at += 1;
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
fn skip(s: []const u8, at: *usize) void {
    while (at.* < s.len and std.ascii.isWhitespace(s[at.*])) : (at.* += 1) {}
}
fn word(s: []const u8, at: *usize) []const u8 {
    const start = at.*;
    while (at.* < s.len and (std.ascii.isAlphanumeric(s[at.*]) or s[at.*] == '-' or s[at.*] == '_')) : (at.* += 1) {}
    if (start == at.*) @compileError(".oriel expected a name");
    return s[start..at.*];
}
fn number(s: []const u8) f32 {
    const n = std.fmt.parseFloat(f32, s) catch @compileError("Invalid .oriel number");
    if (!std.math.isFinite(n)) @compileError("Non-finite .oriel number");
    return n;
}
fn dim(s: []const u8) tree.Dim {
    return if (std.mem.endsWith(u8, s, "%")) .{ .pct = number(s[0 .. s.len - 1]) } else .{ .px = number(s) };
}
fn color(s: []const u8) tree.Color {
    if ((s.len != 7 and s.len != 9) or s[0] != '#') @compileError(".oriel colors use #RRGGBB or #RRGGBBAA");
    const v = std.fmt.parseInt(u24, s[1..7], 16) catch @compileError("Invalid .oriel color");
    const alpha: f32 = if (s.len == 9) @as(f32, @floatFromInt(std.fmt.parseInt(u8, s[7..9], 16) catch @compileError("Invalid .oriel alpha"))) / 255 else 1;
    return .{ @floatFromInt(v >> 16), @floatFromInt((v >> 8) & 255), @floatFromInt(v & 255), alpha };
}
fn attribute(n: *Spec, key: []const u8, v: []const u8) void {
    const p = &n.props;
    if (std.mem.eql(u8, key, "id")) n.name = v else if (std.mem.eql(u8, key, "gap")) {
        p.rg = number(v);
        p.cg = number(v);
    } else if (std.mem.eql(u8, key, "width")) p.w = dim(v) else if (std.mem.eql(u8, key, "height")) p.h = dim(v) else if (std.mem.eql(u8, key, "min-height")) p.minh = dim(v) else if (std.mem.eql(u8, key, "grow")) p.fg = number(v) else if (std.mem.eql(u8, key, "shrink")) p.fs = number(v) else if (std.mem.eql(u8, key, "align")) p.ai = v else if (std.mem.eql(u8, key, "background")) p.bg = .{ .color = color(v) } else if (std.mem.eql(u8, key, "color")) p.col = color(v) else if (std.mem.eql(u8, key, "font-size")) p.fz = number(v) else if (std.mem.eql(u8, key, "padding")) {
        var it = std.mem.splitScalar(u8, v, ',');
        var a: [4]tree.Dim = undefined;
        var i: usize = 0;
        while (it.next()) |x| {
            if (i == 4) @compileError(".oriel padding needs one or four numbers");
            a[i] = dim(x);
            i += 1;
        }
        if (i == 1) a = @splat(a[0]) else if (i != 4) @compileError(".oriel padding needs one or four numbers");
        p.pad = a;
    } else if (std.mem.eql(u8, key, "radius")) p.br = @splat(.{ .x = dim(v), .y = dim(v) }) else if (std.mem.eql(u8, key, "border-bottom")) p.bw = .{ 0, 0, number(v), 0 } else if (std.mem.eql(u8, key, "border-color")) p.bc = @splat(color(v)) else if (std.mem.eql(u8, key, "clip")) {
        if (!std.mem.eql(u8, v, "true")) @compileError("clip must be true");
        p.clip = true;
    } else if (std.mem.eql(u8, key, "scroll")) p.scroll = boolean(v) else if (std.mem.eql(u8, key, "nowrap")) p.nowrap = boolean(v) else if (std.mem.eql(u8, key, "wrap")) p.fw = v else if (std.mem.eql(u8, key, "basis")) p.fb = dim(v) else if (std.mem.eql(u8, key, "justify")) p.jc = v else if (std.mem.eql(u8, key, "min-width")) p.minw = dim(v) else if (std.mem.eql(u8, key, "max-width")) p.maxw = dim(v) else if (std.mem.eql(u8, key, "border-width")) p.bw = @splat(number(v)) else if (std.mem.eql(u8, key, "font-family")) p.ff = v else if (std.mem.eql(u8, key, "mono")) p.mono = boolean(v) else if (std.mem.eql(u8, key, "text-align")) p.ta = v else if (std.mem.eql(u8, key, "letter-spacing")) p.ls = number(v) else if (std.mem.eql(u8, key, "line-height")) p.lh = number(v) else if (std.mem.eql(u8, key, "font-weight")) p.fwt = number(v) else if (std.mem.eql(u8, key, "value")) p.val = v else if (std.mem.eql(u8, key, "placeholder")) p.ph = v else if (std.mem.eql(u8, key, "label")) p.al = v else if (std.mem.eql(u8, key, "disabled")) p.dis = boolean(v) else if (std.mem.eql(u8, key, "visible")) p.vis = boolean(v) else if (std.mem.eql(u8, key, "top")) {
        if (p.ins == null) p.ins = @splat(null);
        p.ins.?[0] = dim(v);
    } else if (std.mem.eql(u8, key, "right")) {
        if (p.ins == null) p.ins = @splat(null);
        p.ins.?[1] = dim(v);
    } else if (std.mem.eql(u8, key, "left")) {
        if (p.ins == null) p.ins = @splat(null);
        p.ins.?[3] = dim(v);
    } else if (std.mem.eql(u8, key, "position")) p.pos = v else @compileError("Unknown .oriel attribute: " ++ key);
}
test ".oriel compiles hierarchy and literal text" {
    const p = comptime parse("<column id=\"root\"><row gap=\"8\"><text>Hello</text></row></column>");
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqualStrings("Hello", p.nodes[2].text);
    try std.testing.expectEqual(@as(?usize, 1), p.nodes[2].parent);
}

fn boolean(s: []const u8) bool {
    if (std.mem.eql(u8, s, "true")) return true;
    if (std.mem.eql(u8, s, "false")) return false;
    @compileError(".oriel boolean must be true or false");
}

test ".oriel controls and scrolling compile native properties" {
    const p = comptime parse("<column scroll=\"true\" wrap=\"wrap\" justify=\"center\" background=\"#10203080\"><input value=\"test\" disabled=\"false\" /><control value=\"Refresh\" label=\"Refresh sample\" /></column>");
    try std.testing.expect(p.nodes[0].props.scroll);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), p.nodes[0].props.bg.?.color.?[3], 0.001);
    try std.testing.expectEqual(tree.Kind.input, p.nodes[1].kind);
    try std.testing.expectEqual(tree.Kind.button, p.nodes[2].kind);
    try std.testing.expectEqualStrings("Refresh sample", p.nodes[2].props.al.?);
}
