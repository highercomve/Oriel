//! The native renderer's Android backend (docs/native-renderer.md).
//!
//! Like the GTK backend, the page is drawn by one view: `NuiView` (Kotlin,
//! OrielNative.kt) draws boxes, text (StaticLayout) and icons (Path) on a
//! Canvas, and puts real EditText/Spinner/SeekBar widgets over the fields.
//! Kotlin keeps a copy of every node's props: as JSON when the page's ops
//! change them, a run's new text alone (host.text), and leaf styles once
//! with compact records for the nodes made from them (host.leaf, stamped
//! rows; one batch). It gets the laid-out frames as one packed array after
//! each layout. Touches come back as taps and scrolls, hit-tested here on
//! the node tree.
//!
//! Everything runs on the UI thread (Oriel's main thread on Android).

const std = @import("std");
const engine_mod = @import("engine.zig");
const tree_mod = @import("tree.zig");
const text_measure_cache = @import("text_measure_cache.zig");
const jni = @import("../platform/android/jni.zig");
const runtime = @import("../platform/android/runtime.zig");
const Engine = engine_mod.Engine;
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;

const log = std.log.scoped(.native_ui);

/// Run a command for window `window`; answer later with `resolve`.
pub const Invoke = *const fn (ctx: ?*anyopaque, window: u32, call_id: u32, cmd: []const u8, args_json: []const u8) void;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    window: u32,
    engine: *Engine = undefined,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    frames: std.ArrayList(u8) = .empty,
    json: std.ArrayList(u8) = .empty,
    hovered: i64 = 0,
    /// Text sizes by content and width (rows repeating a label measure it
    /// once), and the epoch of the nodes' natural sizes (bump both if the
    /// font scale ever re-measures text: NuiView doesn't yet).
    text_measurements: text_measure_cache.Cache = .{},
    text_epoch: u64 = 1,
    /// The page wants a display frame (host.vsync), and whether a
    /// Choreographer callback for this window is already posted.
    frame_wanted: bool = false,
    frame_posted: bool = false,
    /// Leaf styles and natively made nodes (Tree.on_leaf_style, on_leaf) not
    /// yet sent to Kotlin: one nuiLeaves call per batch (flushLeaves), before
    /// anything else reaches NuiView.
    leaves: std.ArrayList(u8) = .empty,
    /// ORIEL_NUI_JSON: props and leaf styles go as JSON (nuiProps, 'S'), as
    /// before the binary records, to compare the two.
    json_props: bool = false,
    /// measureTexts' texts missing from the cache: their ids for
    /// nuiMeasureTexts, the nodes, and the sizes Kotlin answers.
    measure_ids: std.ArrayList(u8) = .empty,
    measure_nodes: std.ArrayList(*Node) = .empty,
    measure_sizes: std.ArrayList(u8) = .empty,
    /// The node count after the last layout, and whether a trim_timer is
    /// posted (laidOut).
    node_count: usize = 0,
    trim_posted: bool = false,
    /// The pointer's last move, sent at the next display frame (moves go
    /// once per frame, before the page's), with its buttons, modifiers and
    /// whether it is the mouse.
    move: ?[2]f32 = null,
    move_buttons: u32 = 0,
    move_mods: u32 = 0,
    move_mouse: bool = false,
    /// fontMetrics' answers by (size in 1/64 px, mono): one trip to Kotlin each.
    font_metrics: std.AutoHashMapUnmanaged(FontKey, [3]f32) = .empty,
};

const FontKey = struct { size64: u32, mono: bool };

/// nuiTimer's id for trimming the tree's pools (the engine's timer ids count
/// up from 1 and never reach it).
const trim_timer: u32 = std.math.maxInt(u32);

/// The native windows by id (UI thread only).
var surfaces: std.AutoHashMapUnmanaged(u32, *Surface) = .empty;

pub fn get(window: u32) ?*Surface {
    return surfaces.get(window);
}

pub fn engineOf(window: u32) ?*Engine {
    const s = surfaces.get(window) orelse return null;
    return s.engine;
}

/// Create window `window`'s page and run it. The Kotlin side
/// (`OrielRuntime.createWindow` with the native flag) must exist already.
pub fn create(gpa: std.mem.Allocator, window: u32, assets: []const engine_mod.Asset, platform_json: [:0]const u8, label: [:0]const u8, url: [:0]const u8, invoke_fn: Invoke, invoke_ctx: ?*anyopaque) !*Surface {
    const s = try gpa.create(Surface);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .window = window, .invoke_fn = invoke_fn, .invoke_ctx = invoke_ctx, .json_props = std.c.getenv("ORIEL_NUI_JSON") != null };
    // The window's size in dp and the night mode, before its view is laid out.
    const vp: u64 = @bitCast(runtime.call(.long, "nuiViewport", "(I)J", .{wid(window)}) orelse 0);
    const w: f32 = @floatFromInt(vp & 0xffff);
    const h: f32 = @floatFromInt((vp >> 16) & 0xffff);
    const dark = (vp >> 32) & 1 != 0;
    // devicePixelRatio: the display's density, as the WebView's (2.625 on
    // a 412 dp phone 1080 px wide, though the page is laid out 412 CSS px).
    const with_dpr = withDensity(gpa, window, platform_json);
    defer if (with_dpr) |j| gpa.free(j);
    s.engine = try Engine.create(gpa, .{
        .ctx = s,
        .measure = measure,
        .laid_out = laidOut,
        .removed = removed,
        .add_timer = addTimer,
        .invoke = invoke,
        .focus = focus,
        .selection = selection,
        .set_selection = setSelection,
        .props = props,
        .text = textChanged,
        .measure_texts = measureTexts,
        .font_metrics = fontMetrics,
        .leaf_style = leafStyle,
        .paint = paintChanged,
        .canvas = canvasChanged,
        // Kotlin keeps a copy of every node's props.
        .mirrors_props = true,
        .leaf = leaf,
        .request_display_frame = requestDisplayFrame,
    }, assets, with_dpr orelse platform_json, label, url, if (w > 0) w else 400, if (h > 0) h else 800);
    try surfaces.put(gpa, window, s);
    s.engine.boot(dark, true);
    return s;
}

/// The platform JSON with `dpr`, the display's density (Kotlin's, in
/// thousandths). Owned by the caller (the engine copies it); null: as is.
fn withDensity(gpa: std.mem.Allocator, window: u32, platform_json: [:0]const u8) ?[:0]const u8 {
    const milli = runtime.call(.int, "nuiDensity", "(I)I", .{wid(window)}) orelse return null;
    if (milli <= 0) return null;
    const trimmed = std.mem.trimEnd(u8, platform_json, " \n");
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '}') return null;
    const body = trimmed[0 .. trimmed.len - 1];
    const sep: []const u8 = if (std.mem.trimEnd(u8, body, " \n").len > 1) "," else "";
    const dpr = @as(f64, @floatFromInt(milli)) / 1000;
    return std.fmt.allocPrintSentinel(gpa, "{s}{s}\"dpr\":{d}}}", .{ body, sep, dpr }, 0) catch null;
}

pub fn destroy(window: u32) void {
    const kv = surfaces.fetchRemove(window) orelse return;
    const s = kv.value;
    s.engine.destroy();
    s.frames.deinit(s.gpa);
    s.json.deinit(s.gpa);
    s.text_measurements.deinit(s.gpa);
    s.leaves.deinit(s.gpa);
    s.measure_ids.deinit(s.gpa);
    s.font_metrics.deinit(s.gpa);
    s.measure_nodes.deinit(s.gpa);
    s.measure_sizes.deinit(s.gpa);
    s.gpa.destroy(s);
}

/// A command's answer, on the UI thread (the window may be gone by then).
pub fn resolve(window: u32, call_id: u32, ok: bool, text: []const u8) void {
    const e = engineOf(window) orelse return;
    e.resolve(call_id, ok, text);
}

fn wid(window: u32) i32 {
    return @intCast(window);
}

fn surfaceOf(p: *anyopaque) *Surface {
    return @ptrCast(@alignCast(p));
}

/// An id as the i32 NuiView keys by (no_id when it doesn't fit).
fn idOf(id: i64) i32 {
    return if (id > std.math.minInt(i32) and id <= std.math.maxInt(i32)) @intCast(id) else no_id;
}

/// A node's id across JNI and in the frame records (an int there; the page
/// never reuses ids, so they grow). One beyond an i32 gets `no_id`, which
/// Kotlin knows no node by: it's skipped there instead of a panic here.
fn nid(n: *const Node) i32 {
    return idOf(n.id);
}
const no_id: i32 = std.math.minInt(i32);

// ---------------------------------------------------------------------------
// Backend hooks

fn invoke(ctx: *anyopaque, _: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
    const s = surfaceOf(ctx);
    s.invoke_fn(s.invoke_ctx, s.window, call_id, cmd, args_json);
}

fn addTimer(ctx: *anyopaque, _: *Engine, id: u32, ms: u32) void {
    const s = surfaceOf(ctx);
    _ = runtime.call(.void, "nuiTimer", "(III)V", .{ wid(s.window), @as(i32, @bitCast(id)), @as(i32, @intCast(@min(ms, std.math.maxInt(i32)))) });
}

fn focus(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    flushLeaves(s);
    _ = runtime.call(.void, "nuiFocus", "(II)V", .{ wid(s.window), nid(node) });
}

/// Backend.selection: an EditText's selection, in UTF-16 units (Java's).
fn selection(ctx: *anyopaque, node: *Node, out: *[2]u32) bool {
    const s = surfaceOf(ctx);
    const v = runtime.call(.long, "nuiSelection", "(II)J", .{ wid(s.window), nid(node) }) orelse return false;
    if (v < 0) return false;
    const u: u64 = @bitCast(v);
    out.* = .{ @truncate(u >> 32), @truncate(u) };
    return true;
}

/// Backend.set_selection: EditText.setSelection.
fn setSelection(ctx: *anyopaque, node: *Node, start: u32, end: u32) void {
    const s = surfaceOf(ctx);
    const clamp = std.math.maxInt(i32);
    _ = runtime.call(.void, "nuiSetSelection", "(IIII)V", .{ wid(s.window), nid(node), @as(i32, @intCast(@min(start, clamp))), @as(i32, @intCast(@min(end, clamp))) });
}

fn removed(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    flushLeaves(s);
    _ = runtime.call(.void, "nuiRemove", "(II)V", .{ wid(s.window), nid(node) });
}

/// A node's props: a 'P' record in the batch (one JNI call for a change's
/// nodes), Kotlin reading them without parsing text; JSON with
/// ORIEL_NUI_JSON.
fn props(ctx: *anyopaque, node: *Node, value: std.json.Value) void {
    const s = surfaceOf(ctx);
    if (s.json_props) return jsonProps(s, node, value);
    const mark = s.leaves.items.len;
    putPropsRecord(s, node, value) catch {
        s.leaves.shrinkRetainingCapacity(mark);
        return jsonProps(s, node, value);
    };
}

/// 'P' node id (i32), kind (string), props (a value: putValue).
fn putPropsRecord(s: *Surface, node: *const Node, value: std.json.Value) !void {
    try putByte(s, 'P');
    try putI32(s, nid(node));
    try putBytes(s, @tagName(node.kind));
    try putValue(s, value);
}

/// A transform or opacity changed alone (the "x" op, an animation frame):
/// an 'X' record in the batch; its other props, and Kotlin's copy, stay.
fn paintChanged(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    const mark = s.leaves.items.len;
    putPaintRecord(s, node, paintOf(node)) catch s.leaves.shrinkRetainingCapacity(mark);
}

/// A canvas's new program (host.canvas, Tree.on_canvas): a 'C' record.
fn canvasChanged(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    const mark = s.leaves.items.len;
    putCanvasRecord(s, node) catch s.leaves.shrinkRetainingCapacity(mark);
}

/// opacity, scale and rotation as NuiNode keeps them (translate is in the
/// frames).
fn paintOf(node: *const Node) [3]f32 {
    return .{ node.props.op orelse 1, node.props.sc orelse 1, node.props.rot orelse 0 };
}

// --- Props as binary values ---------------------------------------------------
// What NuiView reads as JSONObject/JSONArray (OrielNative.kt's readValue),
// without text to parse: a type byte, then
//   0 null, 1 false, 2 true, 3 i32, 4 f64, 5 string (u32 length, UTF-8),
//   6 array (u32 count, values), 7 object (u32 count, key + value each).
// A key is one byte, its index in `prop_keys` (the same table in Kotlin),
// or 255 and the key as a string: a key either side doesn't know still
// works. Little-endian, as every record.

/// Keys by frequency, as Kotlin's PROP_KEYS: append only, never reorder.
pub const prop_keys = [_][]const u8{
    "fd",     "w",      "h",      "fs",     "ai",      "runs",  "t",     "c",    "sz",     "wt",
    "dis",    "click",  "cg",     "rg",     "ar",      "val",   "maxw",  "maxh", "minw",   "minh",
    "fw",     "fg",     "fb",     "as",     "ac",      "jc",    "acc",   "src",  "range",  "pw",
    "pos",    "ph",     "pad",    "m",      "options", "on",    "icon",  "fit",  "cw",     "ch",
    "cv",     "ctl",    "cols",   "trow",   "tcell",   "table", "bc",    "bg",   "br",     "bw",
    "clip",   "col",    "fwt",    "fz",     "ins",     "it",    "lh",    "ls",   "mono",   "nowrap",
    "op",     "rel",    "rot",    "sc",     "scroll",  "scrollx", "sh",  "sticky", "ta",   "tx",
    "ty",     "vis",    "z",      "root",   "color",   "gradient", "angle", "stops", "radial", "spread",
    "blur",   "x",      "y",      "vb",     "shapes",  "d",     "fill",  "stroke", "sw",   "cap",
    "join",   "evenodd", "u",     "i",      "label",   "href",  "hover", "radius", "cx",   "cy",
    "ff",     "ol",
};

const prop_key_ids = blk: {
    var kvs: [prop_keys.len]struct { []const u8, u8 } = undefined;
    for (prop_keys, 0..) |k, n| kvs[n] = .{ k, n };
    break :blk std.StaticStringMap(u8).initComptime(kvs);
};

fn putValue(s: *Surface, v: std.json.Value) !void {
    switch (v) {
        .null => try putByte(s, 0),
        .bool => |b| try putByte(s, if (b) 2 else 1),
        .integer => |i| if (i >= std.math.minInt(i32) and i <= std.math.maxInt(i32)) {
            try putByte(s, 3);
            try putI32(s, @intCast(i));
        } else {
            try putByte(s, 4);
            try putF64(s, @floatFromInt(i));
        },
        .float => |f| {
            try putByte(s, 4);
            try putF64(s, f);
        },
        .number_string => |ns| {
            try putByte(s, 4);
            try putF64(s, std.fmt.parseFloat(f64, ns) catch 0);
        },
        .string => |str| {
            try putByte(s, 5);
            try putBytes(s, str);
        },
        .array => |a| {
            try putByte(s, 6);
            try putU32(s, @intCast(a.items.len));
            for (a.items) |x| try putValue(s, x);
        },
        .object => |o| {
            try putByte(s, 7);
            try putU32(s, @intCast(o.count()));
            var it = o.iterator();
            while (it.next()) |e| {
                if (prop_key_ids.get(e.key_ptr.*)) |id| try putByte(s, id) else {
                    try putByte(s, 255);
                    try putBytes(s, e.key_ptr.*);
                }
                try putValue(s, e.value_ptr.*);
            }
        },
    }
}

fn putF64(s: *Surface, v: f64) !void {
    try s.leaves.appendSlice(s.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u64, @bitCast(v))));
}

/// 'X' node id (i32), opacity, scale, rotation (f32).
fn putPaintRecord(s: *Surface, node: *const Node, paint: [3]f32) !void {
    try putByte(s, 'X');
    try putI32(s, nid(node));
    for (paint) |v| try putF32(s, v);
}

/// 'C' node id (i32), op count (u32), then the canvas program packed from
/// the commands tree.zig parsed (OrielCanvas.kt's CanvasProgram.unpack).
fn putCanvasRecord(s: *Surface, node: *const Node) !void {
    const cmds = node.canvas orelse &.{};
    try putByte(s, 'C');
    try putI32(s, nid(node));
    try putU32(s, @intCast(cmds.len));
    for (cmds) |c| try putCanvasCmd(s, c);
}

fn putCanvasCmd(s: *Surface, c: tree_mod.CanvasCmd) !void {
    try putByte(s, @intFromEnum(std.meta.activeTag(c)));
    switch (c) {
        .save, .restore, .begin_path, .close_path, .stroke => {},
        .fill, .clip => |evenodd| try putByte(s, @intFromBool(evenodd)),
        .translate, .scale, .move_to, .line_to => |v| for (v) |x| try putF32(s, x),
        .rotate, .line_width, .global_alpha => |v| try putF32(s, v),
        .rect, .fill_rect, .stroke_rect, .clear_rect => |v| for (v) |x| try putF32(s, x),
        .bezier_to => |v| for (v) |x| try putF32(s, x),
        .arc => |a| {
            for ([_]f32{ a.x, a.y, a.r, a.a0, a.a1 }) |x| try putF32(s, x);
            try putByte(s, @intFromBool(a.ccw));
        },
        .fill_text => |t| try putText(s, t.t, t.x, t.y),
        .stroke_text => |t| try putText(s, t.t, t.x, t.y),
        .fill_style, .stroke_style => |paint| switch (paint) {
            .color => |col| {
                try putByte(s, 0);
                for (col) |x| try putF32(s, x);
            },
            .grad => |id| {
                try putByte(s, 1);
                try putI32(s, id);
            },
        },
        .line_cap, .line_join, .text_align => |v| try putByte(s, v),
        .text_baseline => |v| try putByte(s, v),
        .font => |f| {
            try putByte(s, @intFromBool(f.italic));
            try putF32(s, f.weight);
            try putF32(s, f.size);
            try putBytes(s, f.family);
        },
        .linear_gradient => |g| {
            try putI32(s, g.id);
            for ([_]f32{ g.x0, g.y0, g.x1, g.y1 }) |x| try putF32(s, x);
        },
        .radial_gradient => |g| {
            try putI32(s, g.id);
            for ([_]f32{ g.x0, g.y0, g.r0, g.x1, g.y1, g.r1 }) |x| try putF32(s, x);
        },
        .color_stop => |g| {
            try putI32(s, g.id);
            try putF32(s, g.off);
            for (g.c) |x| try putF32(s, x);
        },
    }
}

fn putText(s: *Surface, t: []const u8, x: f32, y: f32) !void {
    try putBytes(s, t);
    try putF32(s, x);
    try putF32(s, y);
}

fn putByte(s: *Surface, v: u8) !void {
    try s.leaves.append(s.gpa, v);
}
fn putI32(s: *Surface, v: i32) !void {
    try s.leaves.appendSlice(s.gpa, &std.mem.toBytes(std.mem.nativeToLittle(i32, v)));
}
fn putU32(s: *Surface, v: u32) !void {
    try s.leaves.appendSlice(s.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
}
fn putF32(s: *Surface, v: f32) !void {
    try putU32(s, @bitCast(v));
}
fn putBytes(s: *Surface, b: []const u8) !void {
    try putU32(s, @intCast(b.len));
    try s.leaves.appendSlice(s.gpa, b);
}

/// The props as JSON (nuiProps, its own JNI call): ORIEL_NUI_JSON, or when
/// a record can't be made.
fn jsonProps(s: *Surface, node: *Node, value: std.json.Value) void {
    s.json.clearRetainingCapacity();
    s.json.print(s.gpa, "{f}", .{std.json.fmt(value, .{})}) catch return;
    flushLeaves(s);
    _ = runtime.call(.void, "nuiProps", "(II[B[B)V", .{ wid(s.window), nid(node), @as([]const u8, @tagName(node.kind)), @as([]const u8, s.json.items) });
    // An <img>'s data: URI can be megabytes: don't keep that much for the
    // window's lifetime.
    if (s.json.capacity > 1 << 20) s.json.clearAndFree(s.gpa);
}

/// A text node's single run has new text (host.text): Kotlin swaps it into
/// its copy of the props, without the props' JSON.
fn textChanged(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    const runs = node.props.runs orelse return;
    if (runs.len != 1) return;
    // 'T' node id (i32), text: in the batch, one JNI call for a frame's texts.
    const mark = s.leaves.items.len;
    (struct {
        fn put(sf: *Surface, id: i32, t: []const u8) !void {
            try putByte(sf, 'T');
            try putI32(sf, id);
            try putBytes(sf, t);
        }
    }).put(s, nid(node), runs[0].t) catch {
        s.leaves.shrinkRetainingCapacity(mark);
        flushLeaves(s);
        _ = runtime.call(.void, "nuiText", "(II[B)V", .{ wid(s.window), nid(node), @as([]const u8, runs[0].t) });
    };
}

/// A leaf style (host.leafStyle): its props JSON, once, for NuiView's style
/// table. Record: 'S', style id (i32), JSON length (u32), JSON.
fn leafStyle(ctx: *anyopaque, id: i64, json: []const u8) void {
    const s = surfaceOf(ctx);
    if (!s.json_props) {
        // 'Y' style id (i32), its props as a binary value.
        const mark = s.leaves.items.len;
        if (styleRecord(s, id, json)) return else |_| s.leaves.shrinkRetainingCapacity(mark);
    }
    appendLeafRecord(s, 'S', idOf(id), 0, 0, json);
}

fn styleRecord(s: *Surface, id: i64, json: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, s.gpa, json, .{});
    defer parsed.deinit();
    try putByte(s, 'Y');
    try putI32(s, idOf(id));
    try putValue(s, parsed.value);
}

/// A node made from a leaf style (host.leaf, a stamped row or its leaves):
/// NuiView makes its node from the style, with its text. Record: 'L', node
/// id (i32), kind (0 view, 1 text), style id (i32), text length (u32), text.
fn leaf(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    const text: []const u8 = if (node.kind == .text) if (node.props.runs) |runs| (if (runs.len == 1) runs[0].t else "") else "" else "";
    appendLeafRecord(s, 'L', nid(node), @intFromBool(node.kind == .text), idOf(node.leaf_style), text);
}

fn appendLeafRecord(s: *Surface, tag: u8, id: i32, kind: u8, style: i32, bytes: []const u8) void {
    putLeafRecord(s, tag, id, kind, style, bytes) catch log.err("native ui: a leaf for Kotlin was dropped (out of memory)", .{});
}

fn putLeafRecord(s: *Surface, tag: u8, id: i32, kind: u8, style: i32, bytes: []const u8) !void {
    const b = &s.leaves;
    try b.append(s.gpa, tag);
    try b.appendSlice(s.gpa, &std.mem.toBytes(std.mem.nativeToLittle(i32, id)));
    if (tag == 'L') {
        try b.append(s.gpa, kind);
        try b.appendSlice(s.gpa, &std.mem.toBytes(std.mem.nativeToLittle(i32, style)));
    }
    try b.appendSlice(s.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(bytes.len))));
    try b.appendSlice(s.gpa, bytes);
}

/// Send the pending leaf records (one JNI call), so NuiView knows every node
/// the tree names next.
fn flushLeaves(s: *Surface) void {
    if (s.leaves.items.len == 0) return;
    _ = runtime.call(.void, "nuiLeaves", "(I[B)V", .{ wid(s.window), @as([]const u8, s.leaves.items) });
    s.leaves.clearRetainingCapacity();
    if (s.leaves.capacity > 1 << 20) s.leaves.clearAndFree(s.gpa);
}

/// requestAnimationFrame: one Choreographer callback at the next refresh
/// (Nui.requestFrame), posted only while frames are wanted.
fn requestDisplayFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.frame_wanted = true;
    postFrame(s);
}

/// One Choreographer callback for the window's next display frame.
fn postFrame(s: *Surface) void {
    if (s.frame_posted) return;
    s.frame_posted = true;
    _ = runtime.call(.void, "nuiRequestFrame", "(I)V", .{wid(s.window)});
}

/// Text sizes come from Kotlin (StaticLayout, in dp), and so do images'
/// (their decoded size, scaled down to the width they may take); fields
/// have a fixed size like on GTK.
fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const s = surfaceOf(ctx);
    const fz = n.props.fz orelse 16;
    switch (n.kind) {
        .text => {
            // Its natural (one-line) size, kept on the node like GTK's: at
            // a width it fits in, that's the answer, without a JNI call
            // (the tree clears it when the text or props change).
            const nat = if (n.measured_text_size != null and n.text_measure_epoch == s.text_epoch) n.measured_text_size.? else blk: {
                const size = measuredText(s, n, std.math.inf(f32));
                n.measured_text_size = size;
                n.text_measure_epoch = s.text_epoch;
                break :blk size;
            };
            if (n.props.nowrap or max_width >= nat[0]) {
                out.* = nat;
                return;
            }
            out.* = measuredText(s, n, max_width);
        },
        .image => out.* = kotlinMeasure(s, n, max_width),
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), @round(fz * 1.45) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, @round(fz * 1.45 * 2) },
        else => out.* = .{ 0, 0 },
    }
}

/// The natural sizes of a frame's updated texts (Tree.measure_texts): those
/// the cache doesn't know go to Kotlin in one nuiMeasureTexts call.
fn measureTexts(ctx: *anyopaque, nodes: []const *Node) void {
    const s = surfaceOf(ctx);
    s.measure_ids.clearRetainingCapacity();
    s.measure_nodes.clearRetainingCapacity();
    var buf: [1024]u8 = undefined;
    for (nodes) |n| {
        if (n.kind != .text) continue;
        if (text_measure_cache.keyFor(&buf, &n.props, std.math.inf(f32))) |k| if (s.text_measurements.get(k)) |size| {
            n.measured_text_size = size;
            n.text_measure_epoch = s.text_epoch;
            continue;
        };
        s.measure_ids.appendSlice(s.gpa, std.mem.asBytes(&std.mem.nativeToLittle(i32, nid(n)))) catch return measureEach(s, nodes);
        s.measure_nodes.append(s.gpa, n) catch return measureEach(s, nodes);
    }
    if (s.measure_nodes.items.len == 0) return;
    flushLeaves(s);
    const sizes = kotlinMeasureTexts(s) orelse return measureEach(s, nodes);
    for (s.measure_nodes.items, 0..) |n, i| {
        const r = std.mem.readInt(u64, sizes[i * 8 ..][0..8], .little);
        const size: [2]f32 = .{ @as(f32, @floatFromInt(r >> 32)) / 64, @as(f32, @floatFromInt(r & 0xffffffff)) / 64 };
        n.measured_text_size = size;
        n.text_measure_epoch = s.text_epoch;
        // Nodes with the same text measured twice in one batch store it twice: harmless.
        if (text_measure_cache.keyFor(&buf, &n.props, std.math.inf(f32))) |k| s.text_measurements.put(s.gpa, k, size) catch {};
    }
}

/// One measure per node: when the batch can't be made or Kotlin fails.
fn measureEach(s: *Surface, nodes: []const *Node) void {
    for (nodes) |n| {
        if (n.kind != .text) continue;
        n.measured_text_size = measuredText(s, n, std.math.inf(f32));
        n.text_measure_epoch = s.text_epoch;
    }
}

/// nuiMeasureTexts: the unbounded sizes of measure_ids' nodes, one u64 each
/// (width << 32 | height, in 1/64 dp, little-endian), in measure_sizes.
fn kotlinMeasureTexts(s: *Surface) ?[]const u8 {
    const e = runtime.mainEnv() orelse return null;
    const arr = runtime.call(.object, "nuiMeasureTexts", "(I[B)[B", .{ wid(s.window), @as([]const u8, s.measure_ids.items) }) orelse return null;
    defer e.functions.DeleteLocalRef(e, arr);
    const want = s.measure_nodes.items.len * 8;
    if (arr == null or e.functions.GetArrayLength(e, arr) != want) return null;
    s.measure_sizes.resize(s.gpa, want) catch return null;
    e.functions.GetByteArrayRegion(e, arr, 0, @intCast(want), s.measure_sizes.items.ptr);
    return s.measure_sizes.items;
}

/// A text's size at `width` (inf: unbounded): from the content-keyed cache,
/// else Kotlin's StaticLayout.
fn measuredText(s: *Surface, n: *Node, width: f32) [2]f32 {
    const actual = if (n.props.nowrap or std.math.isInf(width)) std.math.inf(f32) else @max(1, width);
    var buf: [1024]u8 = undefined;
    const key = text_measure_cache.keyFor(&buf, &n.props, actual);
    if (key) |k| if (s.text_measurements.get(k)) |size| return size;
    const size = kotlinMeasure(s, n, actual);
    if (key) |k| s.text_measurements.put(s.gpa, k, size) catch {};
    return size;
}

/// host.fontMetrics: the ascent, descent and line gap (px) of the font text is drawn
/// with (NuiNode's typeface) at `size`, from Kotlin's Paint.FontMetrics.
fn fontMetrics(ctx: *anyopaque, size: f32, mono: bool, out: *[3]f32) bool {
    const s = surfaceOf(ctx);
    const key: FontKey = .{ .size64 = @intFromFloat(@round(std.math.clamp(size, 1, 512) * 64)), .mono = mono };
    if (s.font_metrics.get(key)) |m| {
        out.* = m;
        return true;
    }
    // Ascent, descent and line gap (Paint.FontMetrics' leading) in 1/64 px, 21 bits each.
    const r: u64 = @bitCast(runtime.call(.long, "nuiFontMetrics", "(IZ)J", .{ @as(i32, @intCast(key.size64)), mono }) orelse return false);
    if (r == 0) return false;
    const field = (1 << 21) - 1;
    const m: [3]f32 = .{
        @as(f32, @floatFromInt((r >> 42) & field)) / 64,
        @as(f32, @floatFromInt((r >> 21) & field)) / 64,
        @as(f32, @floatFromInt(r & field)) / 64,
    };
    if (s.font_metrics.count() < 256) s.font_metrics.put(s.gpa, key, m) catch {};
    out.* = m;
    return true;
}

/// nuiMeasure: the node's size from Kotlin at `max_width` (inf: unbounded),
/// in 1/64 dp across JNI.
fn kotlinMeasure(s: *Surface, n: *Node, max_width: f32) [2]f32 {
    const max: i32 = if (std.math.isInf(max_width)) -1 else @intFromFloat(@max(0, @min(max_width, 1e6)) * 64);
    flushLeaves(s);
    const r: u64 = @bitCast(runtime.call(.long, "nuiMeasure", "(III)J", .{ wid(s.window), nid(n), max }) orelse 0);
    return .{ @as(f32, @floatFromInt(r >> 32)) / 64, @as(f32, @floatFromInt(r & 0xffffffff)) / 64 };
}

/// After a layout or a scroll: the frames, in drawing order, and the
/// values the page set on fields.
fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    const root = s.engine.tree.root orelse return;
    s.frames.clearRetainingCapacity();
    pack(s, root) catch return;
    flushLeaves(s);
    _ = runtime.call(.void, "nuiFrames", "(I[B)V", .{ wid(s.window), @as([]const u8, s.frames.items) });
    // A render that removed many nodes (a page section rebuilt): the
    // tree's empty slabs go back to the system 2 s later, as on GTK.
    const count = s.engine.tree.nodes.count();
    if (s.node_count > count + 1000 and !s.trim_posted) {
        s.trim_posted = true;
        _ = runtime.call(.void, "nuiTimer", "(III)V", .{ wid(s.window), @as(i32, @bitCast(trim_timer)), @as(i32, 2000) });
    }
    s.node_count = count;
    var it = s.engine.tree.nodes.valueIterator();
    while (it.next()) |np| {
        const n = np.*;
        const v = n.pending_value orelse continue;
        n.pending_value = null;
        _ = runtime.call(.void, "nuiValue", "(II[B)V", .{ wid(s.window), nid(n), v });
    }
}

/// One record per node: id, frame (4), clip (4), content (4), and how many
/// records its subtree takes after it, as little-endian f32 (14 values).
const record_len = 14;

fn pack(s: *Surface, n: *Node) !void {
    if (n.props.vis == false) return;
    const start = s.frames.items.len;
    const c = n.content();
    const f = n.frame;
    // The id's int bits, not its value as a float: a float holds integers
    // exactly only up to 2^24 (Kotlin reads this slot as an int).
    const vals = [record_len]f32{ @bitCast(nid(n)), f.x, f.y, f.w, f.h, n.clip.x, n.clip.y, n.clip.w, n.clip.h, c.x, c.y, c.w, c.h, 0 };
    try s.frames.appendSlice(s.gpa, std.mem.sliceAsBytes(&vals));
    for (n.kids.items) |k| try pack(s, k);
    const after: f32 = @floatFromInt((s.frames.items.len - start) / (record_len * 4) - 1);
    @memcpy(s.frames.items[start + (record_len - 1) * 4 ..][0..4], std.mem.asBytes(&after));
}

fn disabledUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.dis) return true;
    return false;
}

// ---------------------------------------------------------------------------
// JNI natives of dev.oriel.NuiNative (OrielNative.kt)

const Env = jni.Env;
const jclass = jni.jclass;
const jobject = jni.jobject;
const jint = jni.jint;
const jboolean = jni.jboolean;

fn byId(win: jint) ?*Surface {
    return surfaces.get(@bitCast(win));
}

/// The view's size (dp) or night mode changed.
fn nResize(_: *Env, _: jclass, win: jint, w: f32, h: f32, dark: jboolean) callconv(.c) void {
    const s = byId(win) orelse return;
    s.engine.resize(w, h, dark != 0);
}

/// A tap at (x, y) dp: a click on the node there.
fn nTap(_: *Env, _: jclass, win: jint, x: f32, y: f32) callconv(.c) void {
    const s = byId(win) orelse return;
    const n = s.engine.tree.hit(x, y) orelse return;
    if (disabledUp(n)) return;
    _ = s.engine.event(n.id, "click", "0");
}

/// A finger or button down (:active on the node there) or up.
fn nPress(_: *Env, _: jclass, win: jint, x: f32, y: f32, down: jboolean) callconv(.c) void {
    const s = byId(win) orelse return;
    if (down == 0) {
        _ = s.engine.event(0, "release", "null");
        return;
    }
    const n = s.engine.tree.hit(x, y) orelse return;
    _ = s.engine.event(n.id, "press", "null");
}

/// A mouse over the page (ChromeOS, desktop mode) at (x, y), or gone (x < 0):
/// :hover follows the node under it.
fn nHover(_: *Env, _: jclass, win: jint, x: f32, y: f32) callconv(.c) void {
    const s = byId(win) orelse return;
    const id: i64 = if (x < 0) 0 else if (s.engine.tree.hit(x, y)) |n| n.id else 0;
    if (id == s.hovered) return;
    s.hovered = id;
    _ = s.engine.event(id, "hover", "null");
}

/// A pointer event for the page (main.js pointerEvent; see "Pointer and key
/// events" in docs/native-renderer.md). `phase`: 0 down, 1 move, 2 up, 3
/// cancel; (x, y) in dp (CSS px); `mouse`: the mouse, else a touch. A move
/// waits for the next display frame; the others go now, after a move still
/// waiting. True when the page prevented the default (on down: it takes
/// the drag).
fn nPointer(_: *Env, _: jclass, win: jint, phase: jint, x: f32, y: f32, buttons: jint, mouse: jboolean, mods: jint) callconv(.c) jboolean {
    const s = byId(win) orelse return 0;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return 0;
    if (phase == 1) {
        s.move = .{ x, y };
        s.move_buttons = @bitCast(buttons);
        s.move_mods = @bitCast(mods);
        s.move_mouse = mouse != 0;
        postFrame(s);
        return 0;
    }
    if (s.move != null) {
        flushMove(s);
        if (byId(win) != s) return 0;
    }
    const name = switch (phase) {
        0 => "down",
        2 => "up",
        else => "cancel",
    };
    return @intFromBool(sendPointer(s, name, .{ x, y }, @bitCast(buttons), mouse != 0, @bitCast(mods)));
}

fn flushMove(s: *Surface) void {
    const p = s.move orelse return;
    s.move = null;
    _ = sendPointer(s, "move", p, s.move_buttons, s.move_mouse, s.move_mods);
}

fn sendPointer(s: *Surface, phase: []const u8, p: [2]f32, buttons: u32, mouse: bool, mods: u32) bool {
    const under: i64 = if (s.engine.tree.hit(p[0], p[1])) |n| n.id else 0;
    var buf: [112]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d:.2},{d:.2},{d},1,\"{s}\",{d}]", .{ phase, p[0], p[1], buttons, if (mouse) "mouse" else "touch", mods }) catch return false;
    return s.engine.event(under, "pointer", json);
}

/// A long press: the page's contextmenu.
fn nLongPress(_: *Env, _: jclass, win: jint, x: f32, y: f32) callconv(.c) jboolean {
    const s = byId(win) orelse return 0;
    const n = s.engine.tree.hit(x, y) orelse return 0;
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0}]", .{ x, y }) catch return 0;
    return @intFromBool(s.engine.event(n.id, "contextmenu", json));
}

/// Scroll the container under (x, y) by dy dp: true if something moved.
fn nScroll(_: *Env, _: jclass, win: jint, x: f32, y: f32, dy: f32) callconv(.c) jboolean {
    const s = byId(win) orelse return 0;
    const n = s.engine.tree.hit(x, y);
    var target = s.engine.tree.scroller(n);
    while (target) |t| {
        if (s.engine.scrollBy(t, dy)) return 1;
        target = s.engine.tree.scroller(t.parent);
    }
    return 0;
}

/// A sideways drag or wheel at (x, y): scroll the nearest container that
/// can scroll sideways; true if one moved.
fn nScrollX(_: *Env, _: jclass, win: jint, x: f32, y: f32, dx: f32) callconv(.c) jboolean {
    const s = byId(win) orelse return 0;
    const n = s.engine.tree.hit(x, y);
    var target = s.engine.tree.scrollerX(n);
    while (target) |t| {
        if (s.engine.scrollByX(t, dx)) return 1;
        target = s.engine.tree.scrollerX(t.parent);
    }
    return 0;
}

/// A field's event: kind "input", "change" (data: the value as UTF-8),
/// "key" (data: JSON), "focus", "blur".
fn nEvent(env: *Env, _: jclass, win: jint, id: jint, kind: jobject, data: jobject) callconv(.c) jboolean {
    const s = byId(win) orelse return 0;
    const gpa = s.gpa;
    const k = (env.bytesAlloc(gpa, kind) catch return 0) orelse return 0;
    defer gpa.free(k);
    const d = (env.bytesAlloc(gpa, data) catch return 0) orelse (gpa.alloc(u8, 0) catch return 0);
    defer gpa.free(d);
    // A text field's edit: [value, inputType, data] as JSON from Kotlin.
    if (std.mem.eql(u8, k, "edit")) return @intFromBool(s.engine.event(id, "input", d));
    if (std.mem.eql(u8, k, "input") or std.mem.eql(u8, k, "change")) {
        const json = std.json.Stringify.valueAlloc(gpa, d, .{}) catch return 0;
        defer gpa.free(json);
        return @intFromBool(s.engine.event(id, k, json));
    }
    return @intFromBool(s.engine.event(id, k, if (d.len > 0) d else "null"));
}

/// The display refreshed (Choreographer; `interval_ms` from its refresh
/// rate): the page's animation frame, if it still wants one. A page that
/// asks again during it posts the next callback (requestDisplayFrame).
fn nDisplayFrame(_: *Env, _: jclass, win: jint, interval_ms: f32) callconv(.c) void {
    const s = byId(win) orelse return; // the window closed
    s.frame_posted = false;
    // The pointer's move first, as a browser sends it before the frame.
    if (s.move != null) {
        flushMove(s);
        if (byId(win) != s) return;
    }
    if (!s.frame_wanted) return;
    s.frame_wanted = false;
    s.engine.displayFrame(interval_ms);
}

fn nTimer(_: *Env, _: jclass, win: jint, id: jint) callconv(.c) void {
    const s = byId(win) orelse return; // the window is gone
    if (@as(u32, @bitCast(id)) == trim_timer) {
        s.trim_posted = false;
        const freed = s.engine.tree.trimPools();
        if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("nui trim: {d} pool slabs freed", .{freed});
        return;
    }
    s.engine.timerFired(@bitCast(id));
}

/// The back button: true when the page went back.
fn nBack(_: *Env, _: jclass, win: jint) callconv(.c) jboolean {
    const s = byId(win) orelse return 0;
    return @intFromBool(s.engine.back());
}

/// An app asset's bytes (an <img> src that isn't a data: URI), or null.
fn nAsset(env: *Env, _: jclass, win: jint, path: jobject) callconv(.c) jobject {
    const s = byId(win) orelse return null;
    const p = (env.bytesAlloc(s.gpa, path) catch return null) orelse return null;
    defer s.gpa.free(p);
    const data = s.engine.assetData(std.mem.trimStart(u8, p, "./")) orelse return null;
    return env.newBytes(data);
}

/// The JS heap in bytes (for the memory numbers).
fn nJsMemory(_: *Env, _: jclass, win: jint) callconv(.c) jni.jlong {
    const s = byId(win) orelse return 0;
    return @intCast(s.engine.jsMemory());
}

/// ORIEL_NUI_TRACE (on Android from `debug.oriel.env`): NuiView logs when it
/// has drawn ("nui drawn", tag OrielNui), for on-screen timings.
fn nTrace(_: *Env, _: jclass) callconv(.c) jni.jboolean {
    return @intFromBool(std.c.getenv("ORIEL_NUI_TRACE") != null);
}

/// ORIEL_NUI_DUMP: NuiView logs what it holds after each frames() (tag
/// OrielNui): what it draws, for comparing renderer changes on a device.
fn nDump(_: *Env, _: jclass) callconv(.c) jni.jboolean {
    return @intFromBool(std.c.getenv("ORIEL_NUI_DUMP") != null);
}

/// ORIEL_NUI_TEXT_CHECK: NuiView measures plain lines both ways (font and
/// StaticLayout) and logs where they differ ("nui text check").
fn nTextCheck(_: *Env, _: jclass) callconv(.c) jni.jboolean {
    return @intFromBool(std.c.getenv("ORIEL_NUI_TEXT_CHECK") != null);
}

comptime {
    const prefix = "Java_dev_oriel_NuiNative_";
    @export(&nTextCheck, .{ .name = prefix ++ "textCheck" });
    @export(&nDump, .{ .name = prefix ++ "dump" });
    @export(&nTrace, .{ .name = prefix ++ "trace" });
    @export(&nDisplayFrame, .{ .name = prefix ++ "displayFrame" });
    @export(&nResize, .{ .name = prefix ++ "resize" });
    @export(&nTap, .{ .name = prefix ++ "tap" });
    @export(&nPointer, .{ .name = prefix ++ "pointer" });
    @export(&nPress, .{ .name = prefix ++ "press" });
    @export(&nHover, .{ .name = prefix ++ "hover" });
    @export(&nLongPress, .{ .name = prefix ++ "longPress" });
    @export(&nScroll, .{ .name = prefix ++ "scroll" });
    @export(&nScrollX, .{ .name = prefix ++ "scrollX" });
    @export(&nEvent, .{ .name = prefix ++ "event" });
    @export(&nTimer, .{ .name = prefix ++ "timer" });
    @export(&nBack, .{ .name = prefix ++ "back" });
    @export(&nJsMemory, .{ .name = prefix ++ "jsMemory" });
    @export(&nAsset, .{ .name = prefix ++ "asset" });
}

test {
    _ = log;
    _ = Rect;
}
