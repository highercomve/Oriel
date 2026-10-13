//! Keyboard focus for .oriel views (engine_zig.zig): what's focusable in a
//! view's tree, and its drawn controls' state. The rules (Tab's order, what
//! a click focuses, which key activates, the ring, key scrolling) are the
//! platform's, shared with the native renderer's pages: interaction.zig.
//!
//! Native widgets (input, textarea, select, check, button) take platform
//! focus and draw their own ring; the backend reports their "focus"/"blur".
//! Drawn elements are focusable when their accessibility entry says so (a
//! <button>, `focusable="true"`, a drawn checkbox or push button); their
//! focus is this state and a ring.
const std = @import("std");
const tree_mod = @import("tree.zig");
const interaction = @import("interaction.zig");
const core = @import("engine_core.zig");
const Tree = tree_mod.Tree;
const Node = tree_mod.Node;

pub const State = struct {
    /// The focused node's id (0: none).
    id: i64 = 0,
    /// Focus came from the keyboard: drawn elements show a ring.
    visible: bool = false,
    /// The node currently drawn with the ring (0: none).
    ring: i64 = 0,
    /// The drawn element Space went down on (0: none): only its release
    /// there activates it.
    space: i64 = 0,
};

/// A widget the platform hosts: it has its own focus, ring and keys.
pub fn isNative(n: *const Node) bool {
    return switch (n.kind) {
        .input, .textarea, .select, .check, .button => true,
        else => false,
    };
}

/// A field the platform edits: keys typed in it are its own.
pub fn isField(n: *const Node) bool {
    return n.kind == .input or n.kind == .textarea or n.kind == .select;
}

/// A drawn checkbox or radio (no platform widget).
pub fn isDrawnCheck(n: *const Node) bool {
    return n.kind != .check and n.props.ctl != null;
}

fn isRadio(n: *const Node) bool {
    return if (n.props.ctl) |c| std.mem.eql(u8, c, "radio") else false;
}

/// What kind of element it is to the shared rules: a field is text-like; a
/// native or drawn checkbox, radio or push button a control; a drawn
/// element with a tabindex anything else.
pub fn kindOf(n: *const Node) interaction.FocusKind {
    if (isField(n)) return .text;
    if (n.props.ti != null) return .other;
    return .control;
}

/// Its ring (drawn elements only: a native widget draws its own).
pub fn ringKind(n: *const Node) interaction.RingKind {
    if (n.props.ctl != null) return .check;
    if (n.props.ti != null) return .box;
    return .control;
}

/// A drawn element activated by Enter or Space as a button would be.
pub fn isDrawnButton(n: *const Node) bool {
    return !isNative(n) and n.props.ctl == null;
}

/// Focusable now: a native widget or a drawn element its entry marks
/// focusable, enabled, shown and laid out, in the tree.
pub fn focusable(t: *const Tree, n: *const Node) bool {
    const drawn_ok = if (t.ax.get(n.id)) |a| a.s & tree_mod.Ax.focusable != 0 else false;
    if (!isNative(n) and !drawn_ok) return false;
    if (n.frame.w <= 0 or n.frame.h <= 0) return false;
    var at: ?*const Node = n;
    var depth: usize = 0;
    while (at) |x| : (at = x.parent) {
        if (x.props.dis or x.props.vis == false) return false;
        if (x.parent == null) return t.root == x;
        depth += 1;
        if (depth > tree_mod.max_walk_depth) return false;
    }
    return false;
}

/// The focusable nodes in tree order, as the shared rules' candidates. A
/// radio's group is the radios beside it (same parent): numbered 1, 2, ...
/// by parent as they're found.
pub fn candidates(t: *const Tree, gpa: std.mem.Allocator) ![]interaction.Candidate {
    var c: Collect = .{ .gpa = gpa, .t = t };
    defer c.groups.deinit(gpa);
    errdefer c.out.deinit(gpa);
    if (t.root) |root| try c.walk(root, 0);
    return c.out.toOwnedSlice(gpa);
}

const Collect = struct {
    gpa: std.mem.Allocator,
    t: *const Tree,
    out: std.ArrayList(interaction.Candidate) = .empty,
    /// Radio groups by their parent's id.
    groups: std.AutoHashMapUnmanaged(i64, u32) = .empty,

    fn walk(c: *Collect, n: *Node, depth: usize) !void {
        if (n.props.vis == false or n.props.dis) return;
        if (depth > tree_mod.max_walk_depth) return tree_mod.warnTooDeep("Tab order");
        if (focusable(c.t, n)) {
            var group: u32 = 0;
            if (isRadio(n)) if (n.parent) |p| {
                const gop = try c.groups.getOrPut(c.gpa, p.id);
                if (!gop.found_existing) gop.value_ptr.* = c.groups.count();
                group = gop.value_ptr.*;
            };
            try c.out.append(c.gpa, .{ .id = n.id, .kind = kindOf(n), .tabindex = n.props.ti, .group = group, .checked = n.props.on });
        }
        for (n.kids.items) |k| try c.walk(k, depth + 1);
    }
};

/// The first scroller in the view (depth first) that has more inside than it
/// shows: what a scrolling key moves when nothing focused is in one.
pub fn firstScroller(t: *const Tree) ?*Node {
    return if (t.root) |root| firstScrollerIn(root, 0) else null;
}

fn firstScrollerIn(n: *Node, depth: usize) ?*Node {
    if (n.props.vis == false) return null;
    if (depth > tree_mod.max_walk_depth) {
        tree_mod.warnTooDeep("key scrolling");
        return null;
    }
    if (n.props.scroll and core.maxScroll(n) > 0.5) return n;
    for (n.kids.items) |k| if (firstScrollerIn(k, depth + 1)) |s| return s;
    return null;
}

/// The node, or the nearest one around it, that takes focus on a click.
pub fn focusTarget(t: *const Tree, id: i64) ?*Node {
    var at = t.nodes.get(id);
    var depth: usize = 0;
    while (at) |n| : (at = n.parent) {
        if (focusable(t, n)) return n;
        depth += 1;
        if (depth > tree_mod.max_walk_depth) break;
    }
    return null;
}

/// Move the ring to the focused node when it's drawn and focus is visible.
pub fn updateRing(t: *Tree, st: *State, platform: interaction.Platform) !void {
    const want: i64 = if (st.visible and st.id != 0) if (t.get(st.id)) |n| if (isNative(n)) 0 else st.id else 0 else 0;
    if (want == st.ring) return;
    try clearRing(t, st);
    if (want != 0) {
        const n = t.get(want).?;
        var props = n.props;
        props.ol = core.outline(interaction.ring(platform, ringKind(n)));
        try t.updateUiProps(n.id, props);
        st.ring = want;
    }
}

/// Take the ring off (the accent changed: it's drawn again).
pub fn clearRing(t: *Tree, st: *State) !void {
    if (st.ring != 0) if (t.get(st.ring)) |n| {
        var props = n.props;
        props.ol = null;
        try t.updateUiProps(n.id, props);
    };
    st.ring = 0;
}

/// A drawn checkbox or radio clicked (or activated): check it (a radio
/// unchecks the radios beside it). Returns its new state.
pub fn toggle(t: *Tree, n: *Node) !bool {
    const radio = isRadio(n);
    const now = if (radio) true else !n.props.on;
    if (radio) if (n.parent) |p| for (p.kids.items) |k| {
        if (k == n or !k.props.on or !isRadio(k)) continue;
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

/// A "key"/"keyup" event's data (`[key, mods, repeat]`; keyup without
/// repeat). Modifier flags: shift 1, ctrl 2, alt 4, meta 8.
pub const Key = struct { key: []const u8, mods: i64, repeat: bool };
pub fn keyOf(gpa: std.mem.Allocator, data: []const u8, name: []u8) ?Key {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len < 2) return null;
    const a = parsed.value.array.items;
    if (a[0] != .string or a[0].string.len > name.len) return null;
    @memcpy(name[0..a[0].string.len], a[0].string);
    return .{
        .key = name[0..a[0].string.len],
        .mods = if (a[1] == .integer) a[1].integer else 0,
        .repeat = a.len > 2 and a[2] == .bool and a[2].bool,
    };
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
        \\  <control id="native" value="OK" />
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
    const cands = try candidates(&t, gpa);
    defer gpa.free(cands);
    try std.testing.expectEqual(@as(usize, 4), cands.len);
    const a = V.id("a", 1);
    const field = V.id("field", 1);
    const native = V.id("native", 1);
    const b = V.id("b", 1);
    try std.testing.expectEqual(interaction.FocusKind.text, cands[1].kind);
    try std.testing.expectEqual(interaction.FocusKind.control, cands[2].kind);
    var at: ?i64 = null;
    var all: [5]i64 = undefined;
    for (&all) |*o| {
        at = try interaction.tabNext(gpa, .all, cands, at, false);
        o.* = at.?;
    }
    try std.testing.expectEqual([5]i64{ a, field, native, b, a }, all);
    // macOS without Full Keyboard Access: no native push button; drawn
    // buttons (tabindex 0) and fields stay.
    at = null;
    var mac: [3]i64 = undefined;
    for (&mac) |*o| {
        at = try interaction.tabNext(gpa, .mac, cands, at, false);
        o.* = at.?;
    }
    try std.testing.expectEqual([3]i64{ a, field, b }, mac);
    // A click inside a button focuses the button.
    try std.testing.expectEqual(a, focusTarget(&t, a + 1).?.id);
    try std.testing.expect(focusTarget(&t, V.id("plain", 1)) == null);
}

test "radios in different parents are different Tab stops" {
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
    // Radios in the column (id 100) and in its row (id 101): groups made
    // from `parent id | 1` once collided (both 101).
    const V = ui.View(
        \\<column id="root" width="300" height="300">
        \\  <row><radio id="b1" /><radio id="b2" checked="true" /></row>
        \\  <radio id="a1" checked="true" />
        \\  <radio id="a2" />
        \\</column>
    );
    try V.prepare(&t, 10);
    _ = try V.mount(&t, 100, 10, &.{});
    t.root = t.get(100);
    t.width = 300;
    t.height = 300;
    t.layout();
    const gpa = std.testing.allocator;
    const cands = try candidates(&t, gpa);
    defer gpa.free(cands);
    try std.testing.expectEqual(@as(i64, 101), t.get(V.id("b1", 100)).?.parent.?.id);
    try std.testing.expect(cands[0].group != cands[2].group);
    try std.testing.expectEqual(V.id("b2", 100), (try interaction.tabNext(gpa, .all, cands, null, false)).?);
    try std.testing.expectEqual(V.id("a1", 100), (try interaction.tabNext(gpa, .all, cands, V.id("b2", 100), false)).?);
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
    // The radio group is one Tab stop: its checked radio.
    const gpa = std.testing.allocator;
    const cands = try candidates(&t, gpa);
    defer gpa.free(cands);
    try std.testing.expectEqual(r1.id, (try interaction.tabNext(gpa, .all, cands, null, false)).?);
    try std.testing.expectEqual(V.id("c", 1), (try interaction.tabNext(gpa, .all, cands, r1.id, false)).?);
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
    const linux: interaction.Platform = .{ .os = .linux };
    var st: State = .{ .id = r2.id, .visible = true };
    try updateRing(&t, &st, linux);
    try std.testing.expectEqual(core.outline(interaction.ring(linux, .check)), t.get(r2.id).?.props.ol.?);
    st.id = ok.id;
    try updateRing(&t, &st, linux);
    try std.testing.expect(t.get(r2.id).?.props.ol == null);
    try std.testing.expectEqual(core.outline(interaction.ring(linux, .control)), t.get(ok.id).?.props.ol.?);
    st.visible = false;
    try updateRing(&t, &st, linux);
    try std.testing.expect(t.get(ok.id).?.props.ol == null);
}
