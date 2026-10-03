//! The native renderer's Android backend (docs/native-renderer.md).
//!
//! Like the GTK backend, the page is drawn by one view: `NuiView` (Kotlin,
//! OrielNative.kt) draws boxes, text (StaticLayout) and icons (Path) on a
//! Canvas, and puts real EditText/Spinner widgets over the fields. Kotlin
//! keeps a copy of every node's props (sent as JSON when they change) and
//! gets the laid-out frames as one packed array after each layout. Touches
//! come back as taps and scrolls, hit-tested here on the node tree.
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
};

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
    s.* = .{ .gpa = gpa, .window = window, .invoke_fn = invoke_fn, .invoke_ctx = invoke_ctx };
    // The window's size in dp and the night mode, before its view is laid out.
    const vp: u64 = @bitCast(runtime.call(.long, "nuiViewport", "(I)J", .{wid(window)}) orelse 0);
    const w: f32 = @floatFromInt(vp & 0xffff);
    const h: f32 = @floatFromInt((vp >> 16) & 0xffff);
    const dark = (vp >> 32) & 1 != 0;
    s.engine = try Engine.create(gpa, .{
        .ctx = s,
        .measure = measure,
        .laid_out = laidOut,
        .removed = removed,
        .add_timer = addTimer,
        .invoke = invoke,
        .focus = focus,
        .props = props,
        .text = textChanged,
        .leaf_style = leafStyle,
        .leaf = leaf,
        .request_display_frame = requestDisplayFrame,
    }, assets, platform_json, label, url, if (w > 0) w else 400, if (h > 0) h else 800);
    try surfaces.put(gpa, window, s);
    s.engine.boot(dark, true);
    return s;
}

pub fn destroy(window: u32) void {
    const kv = surfaces.fetchRemove(window) orelse return;
    const s = kv.value;
    s.engine.destroy();
    s.frames.deinit(s.gpa);
    s.json.deinit(s.gpa);
    s.text_measurements.deinit(s.gpa);
    s.leaves.deinit(s.gpa);
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

fn removed(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    flushLeaves(s);
    _ = runtime.call(.void, "nuiRemove", "(II)V", .{ wid(s.window), nid(node) });
}

fn props(ctx: *anyopaque, node: *Node, value: std.json.Value) void {
    const s = surfaceOf(ctx);
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
    flushLeaves(s);
    _ = runtime.call(.void, "nuiText", "(II[B)V", .{ wid(s.window), nid(node), @as([]const u8, runs[0].t) });
}

/// A leaf style (host.leafStyle): its props JSON, once, for NuiView's style
/// table. Record: 'S', style id (i32), JSON length (u32), JSON.
fn leafStyle(ctx: *anyopaque, id: i64, json: []const u8) void {
    const s = surfaceOf(ctx);
    appendLeafRecord(s, 'S', idOf(id), 0, 0, json);
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
    if (!s.frame_wanted) return;
    s.frame_wanted = false;
    s.engine.displayFrame(interval_ms);
}

fn nTimer(_: *Env, _: jclass, win: jint, id: jint) callconv(.c) void {
    const s = byId(win) orelse return;
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

comptime {
    const prefix = "Java_dev_oriel_NuiNative_";
    @export(&nDump, .{ .name = prefix ++ "dump" });
    @export(&nTrace, .{ .name = prefix ++ "trace" });
    @export(&nDisplayFrame, .{ .name = prefix ++ "displayFrame" });
    @export(&nResize, .{ .name = prefix ++ "resize" });
    @export(&nTap, .{ .name = prefix ++ "tap" });
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
