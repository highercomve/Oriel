//! A flex row's leaves read straight from the native DOM and stamped into
//! the tree (docs/native-dom.md, phase 3): what render.js's useFlexShape
//! did per child (its id, its text, its node), without JavaScript objects,
//! maps or JSON. The page's runtime decides that a row has this shape and
//! registers its plan (Tree.defineStampPlan): each child element's leaf
//! styles and text-transform. Here each child element becomes a text leaf
//! (its one text node, whitespace collapsed and trimmed as the runtime
//! does) or, empty, a box leaf; anything else declines and the runtime's
//! general path renders the row.

const std = @import("std");
const tree_mod = @import("tree.zig");
const capi = @import("dom/capi.zig");
const st = @import("dom/store.zig");

const Tree = tree_mod.Tree;

/// Tree ids of DOM nodes: this plus the store index. Below Android's
/// 32-bit node ids, above any id the runtime counts out itself.
pub const id_base: i64 = 1 << 30;

/// Stamp DOM element `row` as tree row `row_id` with plan `plan_id`.
/// False when the row doesn't have the plan's shape now (the runtime then
/// renders it the general way); the tree is unchanged then.
pub fn stamp(t: *Tree, d: *capi.Dom, row: st.Index, row_id: i64, plan_id: u32) !bool {
    const plan = t.stampPlan(plan_id) orelse return false;
    const s = &d.store;
    if (row == st.none or row >= s.used or s.get(row).kind != .element) return false;

    var sfa = std.heap.stackFallback(2048, t.gpa);
    var arena: std.heap.ArenaAllocator = .init(sfa.get());
    defer arena.deinit();
    const a = arena.allocator();

    // The children in source order (comments skipped), as leaves.
    const n = plan.entries.len;
    const leaves = try a.alloc(Tree.StampLeaf, n);
    var i: usize = 0;
    var c = s.get(row).first;
    while (c != st.none) : (c = s.get(c).next) {
        const child = s.get(c);
        if (child.kind == .comment) continue;
        if (child.kind != .element or i == n) return false;
        const e = plan.entries[i];
        const id = id_base + @as(i64, c);
        const text = (try textOf(d, a, c, e.transform)) orelse return false;
        leaves[i] = if (text.len > 0)
            .{ .id = id, .kind = .text, .style = e.text_style, .text = text }
        else
            .{ .id = id, .kind = .view, .style = e.view_style, .text = "" };
        if (leaves[i].style == 0) return false;
        i += 1;
    }
    if (i != n) return false;
    const ordered = try a.alloc(Tree.StampLeaf, n);
    for (plan.order, 0..) |at, k| ordered[k] = leaves[at];
    return t.stampRow(row_id, ordered);
}

/// An element's text as the runtime writes a simple leaf's: its one text
/// node with whitespace runs made one space, trimmed, and upper/lower cased;
/// "" with no children; null for anything else (more nodes, an element, a
/// case change of non-ASCII text).
fn textOf(d: *capi.Dom, a: std.mem.Allocator, el: st.Index, transform: anytype) !?[]const u8 {
    const s = &d.store;
    const first = s.get(el).first;
    if (first == st.none) return "";
    const node = s.get(first);
    if (node.kind != .text or node.next != st.none) return null;
    const v = s.dataOf(first) orelse return "";
    const h = &d.host;
    // ASCII strings are read in place; others as UTF-8 (freed below).
    var len: usize = 0;
    var utf8: ?[*]const u8 = null;
    defer if (utf8) |p| h.free_utf8(h.ctx, p);
    const raw: []const u8 = blk: {
        if (h.latin1(h.ctx, v, &len)) |p| if (isAscii(p[0..len])) break :blk p[0..len];
        utf8 = h.to_utf8(h.ctx, v, &len) orelse return error.OutOfMemory;
        break :blk utf8.?[0..len];
    };
    const out = try a.alloc(u8, raw.len);
    var o: usize = 0;
    var space = false; // a whitespace run waiting for a word after it
    var at: usize = 0;
    while (at < raw.len) {
        const w = jsSpace(raw[at..]);
        if (w > 0) {
            space = o > 0;
            at += w;
            continue;
        }
        if (space) {
            out[o] = ' ';
            o += 1;
            space = false;
        }
        const b = raw[at];
        if (b >= 0x80 and transform != .none) return null;
        out[o] = switch (transform) {
            .upper => std.ascii.toUpper(b),
            .lower => std.ascii.toLower(b),
            .none => b,
        };
        o += 1;
        at += 1;
    }
    return out[0..o];
}

fn isAscii(b: []const u8) bool {
    for (b) |x| if (x >= 0x80) return false;
    return true;
}

/// The length of a JavaScript `\s` character at the start of UTF-8 `b`
/// (0 when it isn't one): ASCII tab to carriage return and space, and
/// U+00A0, U+1680, U+2000-U+200A, U+2028, U+2029, U+202F, U+205F, U+3000,
/// U+FEFF.
fn jsSpace(b: []const u8) usize {
    const c = b[0];
    if (c == ' ' or (c >= 0x09 and c <= 0x0d)) return 1;
    if (c < 0x80) return 0;
    if (b.len >= 2 and c == 0xc2 and b[1] == 0xa0) return 2;
    if (b.len < 3) return 0;
    const x = b[1];
    const y = b[2];
    if (c == 0xe1 and x == 0x9a and y == 0x80) return 3; // U+1680
    if (c == 0xe2 and x == 0x80 and ((y >= 0x80 and y <= 0x8a) or y == 0xa8 or y == 0xa9 or y == 0xaf)) return 3;
    if (c == 0xe2 and x == 0x81 and y == 0x9f) return 3; // U+205F
    if (c == 0xe3 and x == 0x80 and y == 0x80) return 3; // U+3000
    if (c == 0xef and x == 0xbb and y == 0xbf) return 3; // U+FEFF
    return 0;
}

test "jsSpace matches JavaScript's \\s" {
    try std.testing.expectEqual(@as(usize, 1), jsSpace(" x"));
    try std.testing.expectEqual(@as(usize, 1), jsSpace("\n"));
    try std.testing.expectEqual(@as(usize, 2), jsSpace("\u{00A0}"));
    try std.testing.expectEqual(@as(usize, 3), jsSpace("\u{2009}"));
    try std.testing.expectEqual(@as(usize, 3), jsSpace("\u{3000}"));
    try std.testing.expectEqual(@as(usize, 3), jsSpace("\u{FEFF}"));
    try std.testing.expectEqual(@as(usize, 0), jsSpace("\u{200B}")); // zero width space isn't \s
    try std.testing.expectEqual(@as(usize, 0), jsSpace("é"));
}
