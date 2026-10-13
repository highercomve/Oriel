//! Keyboard focus and the default actions for the Zig engine (oriel.ui):
//! what main.js does for a page, without one. Tab order, a focus ring on
//! drawn elements focused from the keyboard, Enter/Space activating them,
//! checkboxes and radios toggling, field edits recorded, keys scrolling.
//!
//! Native widgets (input, textarea, select, check, button) take platform
//! focus and draw their own ring; the backend reports their "focus"/"blur".
//! Drawn elements are focusable when their accessibility entry says so
//! (a <button>, `focusable="true"`); their focus is this state and a ring.
const std = @import("std");
const tree_mod = @import("tree.zig");
const Tree = tree_mod.Tree;
const Node = tree_mod.Node;

pub const State = struct {
    /// The focused node's id (0: none).
    id: i64 = 0,
    /// Focus came from the keyboard: drawn elements show a ring.
    visible: bool = false,
    /// The node currently drawn with the ring (0: none).
    ring: i64 = 0,
    /// The platform's accent color (the "accent" event): the ring's.
    accent: [3]f32 = .{ 52, 132, 228 },
};

const mod_shift: i64 = 1;

/// A widget the platform hosts: it has its own focus, ring and keys.
pub fn isNative(n: *const Node) bool {
    return switch (n.kind) {
        .input, .textarea, .select, .check, .button => true,
        else => false,
    };
}

/// A field the platform edits: keys typed in it are its own.
fn isField(n: *const Node) bool {
    return n.kind == .input or n.kind == .textarea or n.kind == .select;
}

/// A drawn checkbox or radio (no platform widget): toggled here.
fn isDrawnCheck(n: *const Node) bool {
    return n.kind != .check and n.props.ctl != null;
}

/// Focusable now: a native widget or a drawn element its entry marks
/// focusable, enabled, shown and laid out, in the tree.
pub fn focusable(t: *const Tree, n: *const Node) bool {
    const drawn_ok = if (t.ax.get(n.id)) |a| a.s & tree_mod.Ax.focusable != 0 else false;
    if (!isNative(n) and !drawn_ok) return false;
    if (n.frame.w <= 0 or n.frame.h <= 0) return false;
    var at: ?*const Node = n;
    while (at) |x| : (at = x.parent) {
        if (x.props.dis or x.props.vis == false) return false;
        if (x.parent == null) return t.root == x;
    }
    return false;
}

/// The focusable nodes in tree order (depth first, children in order).
pub fn order(t: *const Tree, gpa: std.mem.Allocator) ![]*Node {
    var out: std.ArrayList(*Node) = .empty;
    errdefer out.deinit(gpa);
    const root = t.root orelse return out.toOwnedSlice(gpa);
    try collect(t, gpa, root, &out, 0);
    return out.toOwnedSlice(gpa);
}

fn collect(t: *const Tree, gpa: std.mem.Allocator, n: *Node, out: *std.ArrayList(*Node), depth: usize) !void {
    if (depth > 64 or n.props.vis == false or n.props.dis) return;
    if (focusable(t, n)) try out.append(gpa, n);
    for (n.kids.items) |k| try collect(t, gpa, k, out, depth + 1);
}

/// The node, or the nearest one around it, that takes focus on a click.
pub fn focusTarget(t: *const Tree, id: i64) ?*Node {
    var at = t.nodes.get(id);
    var depth: usize = 0;
    while (at) |n| : (at = n.parent) {
        if (focusable(t, n)) return n;
        depth += 1;
        if (depth > 64) break;
    }
    return null;
}

/// The next focusable node after the focused one (before it, `back`),
/// wrapping around; the first (last) when nothing is focused.
pub fn next(t: *const Tree, gpa: std.mem.Allocator, current: i64, back: bool) !?*Node {
    const list = try order(t, gpa);
    defer gpa.free(list);
    if (list.len == 0) return null;
    const at: ?usize = for (list, 0..) |n, i| {
        if (n.id == current) break i;
    } else null;
    if (at) |i| return list[if (back) (i + list.len - 1) % list.len else (i + 1) % list.len];
    return list[if (back) list.len - 1 else 0];
}

/// The ring for a drawn element: 2px of accent, 1px out, corners 3
/// (render.js's Linux "box" ring).
pub fn ring(accent: [3]f32) tree_mod.Outline {
    return .{ .w = 2, .o = 1, .c = .{ accent[0], accent[1], accent[2], 0.8 }, .r = 3 };
}

/// Move the ring to the focused node when it's drawn and focus is visible.
pub fn updateRing(t: *Tree, st: *State) !void {
    const want: i64 = if (st.visible and st.id != 0) if (t.get(st.id)) |n| if (isNative(n)) 0 else st.id else 0 else 0;
    if (want == st.ring) return;
    if (st.ring != 0) if (t.get(st.ring)) |n| {
        var props = n.props;
        props.ol = null;
        try t.updateUiProps(n.id, props);
    };
    st.ring = 0;
    if (want != 0) {
        const n = t.get(want).?;
        var props = n.props;
        props.ol = ring(st.accent);
        try t.updateUiProps(n.id, props);
        st.ring = want;
    }
}

/// A drawn checkbox or radio clicked (or activated): check it (a radio
/// unchecks the radios beside it). Returns its new state.
pub fn toggle(t: *Tree, n: *Node) !bool {
    const radio = if (n.props.ctl) |c| std.mem.eql(u8, c, "radio") else false;
    const now = if (radio) true else !n.props.on;
    if (radio) if (n.parent) |p| for (p.kids.items) |k| {
        if (k == n or !k.props.on) continue;
        const kr = if (k.props.ctl) |c| std.mem.eql(u8, c, "radio") else false;
        if (!kr) continue;
        var props = k.props;
        props.on = false;
        try t.updateUiProps(k.id, props);
    };
    var props = n.props;
    props.on = now;
    props.mix = false;
    try t.updateUiProps(n.id, props);
    return now;
}

/// A field edit's value: GTK sends the value as a JSON string, AppKit,
/// UIKit and Win32 `[value, inputType, data]`.
pub fn editedValue(gpa: std.mem.Allocator, data: []const u8) !?std.json.Parsed(std.json.Value) {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return null;
    switch (parsed.value) {
        .string => return parsed,
        .array => |a| if (a.items.len > 0 and a.items[0] == .string) return parsed,
        else => {},
    }
    parsed.deinit();
    return null;
}

pub fn valueOf(v: std.json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        .array => |a| a.items[0].string,
        else => "",
    };
}

/// A "key" event's key name and modifier flags (`[key, mods, repeat]`).
pub fn keyOf(gpa: std.mem.Allocator, data: []const u8, name: []u8) ?struct { key: []const u8, mods: i64 } {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 2) return null;
    const a = parsed.value.array.items;
    if (a[0] != .string or a[0].string.len > name.len) return null;
    @memcpy(name[0..a[0].string.len], a[0].string);
    return .{ .key = name[0..a[0].string.len], .mods = if (a[1] == .integer) a[1].integer else 0 };
}

/// The scroller a scrolling key moves: the focused node's nearest one,
/// else the first one in the window.
pub fn scrollerFor(t: *const Tree, focused: i64) ?*Node {
    var at = t.nodes.get(focused);
    while (at) |n| : (at = n.parent) if (n.props.scroll and n.content_h > n.frame.h) return n;
    const root = t.root orelse return null;
    return firstScroller(root, 0);
}

fn firstScroller(n: *Node, depth: usize) ?*Node {
    if (depth > 64 or n.props.vis == false) return null;
    if (n.props.scroll and n.content_h > n.frame.h) return n;
    for (n.kids.items) |k| if (firstScroller(k, depth + 1)) |s| return s;
    return null;
}

/// How far a key scrolls `n` (null: not a scrolling key).
pub fn scrollDelta(n: *const Node, key: []const u8) ?f32 {
    const line: f32 = 40;
    const page = @max(line, n.frame.h * 0.875);
    if (std.mem.eql(u8, key, "ArrowDown")) return line;
    if (std.mem.eql(u8, key, "ArrowUp")) return -line;
    if (std.mem.eql(u8, key, "PageDown")) return page;
    if (std.mem.eql(u8, key, "PageUp")) return -page;
    if (std.mem.eql(u8, key, "Home")) return -n.scroll_y;
    if (std.mem.eql(u8, key, "End")) return n.content_h;
    return null;
}

pub fn isShift(mods: i64) bool {
    return mods & mod_shift != 0;
}

test "tab order skips disabled, hidden and unlaid nodes and wraps" {
    const measure = struct {
        fn f(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    const ui = @import("ui.zig");
    const V = ui.View(
        \\<column id="root" width="300" height="300">
        \\  <button id="a" height="20"><text>A</text></button>
        \\  <button id="off" height="20" disabled="true"><text>Off</text></button>
        \\  <column visible="false"><button id="hidden" height="20"><text>H</text></button></column>
        \\  <input id="field" />
        \\  <view id="plain" height="20" />
        \\  <button id="b" height="20"><text>B</text></button>
        \\</column>
    );
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 1, 10, &.{});
    t.root = t.get(1);
    t.width = 300;
    t.height = 300;
    t.layout();
    const gpa = std.testing.allocator;
    const list = try order(&t, gpa);
    defer gpa.free(list);
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(V.id("a", 1), list[0].id);
    try std.testing.expectEqual(V.id("field", 1), list[1].id);
    try std.testing.expectEqual(V.id("b", 1), list[2].id);
    try std.testing.expectEqual(V.id("a", 1), (try next(&t, gpa, 0, false)).?.id);
    try std.testing.expectEqual(V.id("b", 1), (try next(&t, gpa, 0, true)).?.id);
    try std.testing.expectEqual(V.id("a", 1), (try next(&t, gpa, V.id("b", 1), false)).?.id);
    try std.testing.expectEqual(V.id("b", 1), (try next(&t, gpa, V.id("a", 1), true)).?.id);
    // A click inside a button focuses the button.
    try std.testing.expectEqual(V.id("a", 1), focusTarget(&t, V.id("a", 1) + 1).?.id);
    try std.testing.expect(focusTarget(&t, V.id("plain", 1)) == null);
}

test "drawn radios check one at a time; the ring follows keyboard focus" {
    const measure = struct {
        fn f(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 40, 18 };
        }
    }.f;
    var ctx: u8 = 0;
    var t = Tree.init(std.testing.allocator, &ctx, measure);
    defer t.deinit();
    t.controls = .{ .check = false, .button = false };
    const ui = @import("ui.zig");
    const V = ui.View(
        \\<column id="root" width="300" height="300">
        \\  <radio id="r1" checked="true" label="One" />
        \\  <radio id="r2" label="Two" />
        \\  <checkbox id="c" label="Agree" />
        \\  <control id="ok" value="OK" />
        \\</column>
    );
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 1, 10, &.{});
    t.root = t.get(1);
    t.width = 300;
    t.height = 300;
    t.layout();
    const r1 = t.get(V.id("r1", 1)).?;
    const r2 = t.get(V.id("r2", 1)).?;
    try std.testing.expectEqual(tree_mod.Kind.view, r1.kind);
    try std.testing.expectEqual(tree_mod.AxRole.radio, t.ax.get(r1.id).?.r);
    try std.testing.expect(t.ax.get(r1.id).?.s & tree_mod.Ax.checked != 0);
    try std.testing.expect(try toggle(&t, r2));
    try std.testing.expect(!t.get(r1.id).?.props.on);
    try std.testing.expect(t.ax.get(r1.id).?.s & tree_mod.Ax.checked == 0);
    try std.testing.expect(t.ax.get(r2.id).?.s & tree_mod.Ax.checked != 0);
    const c = t.get(V.id("c", 1)).?;
    try std.testing.expect(try toggle(&t, c));
    try std.testing.expect(!try toggle(&t, c));
    // The drawn push button: a clickable text named by its value.
    const ok = t.get(V.id("ok", 1)).?;
    try std.testing.expectEqual(tree_mod.Kind.text, ok.kind);
    try std.testing.expectEqualStrings("OK", t.ax.get(ok.id).?.n.?);
    var st: State = .{ .id = r2.id, .visible = true };
    try updateRing(&t, &st);
    try std.testing.expect(t.get(r2.id).?.props.ol != null);
    st.id = ok.id;
    try updateRing(&t, &st);
    try std.testing.expect(t.get(r2.id).?.props.ol == null);
    try std.testing.expect(t.get(ok.id).?.props.ol != null);
    st.visible = false;
    try updateRing(&t, &st);
    try std.testing.expect(t.get(ok.id).?.props.ol == null);
}
