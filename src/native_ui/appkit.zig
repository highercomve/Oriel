//! The native renderer's AppKit backend (macOS, docs/native-renderer.md).
//!
//! Like the GTK backend: one view (`OrielNuiView`, flipped, so y goes down)
//! draws the boxes, text and icons with CoreGraphics and CoreText
//! (apple_draw.zig, shared with UIKit), and real NSTextField / NSTextView /
//! NSPopUpButton controls sit over the fields at their nodes' frames.
//! Clicks, scrolling and keys are hit-tested on the node tree in Zig.
//!
//! Main thread only. A surface is found by its token (timers and command
//! answers that arrive after its window closed find nothing).

const std = @import("std");
const cocoa = @import("../platform/macos/cocoa.zig");
const engine_mod = @import("engine.zig");
const tree_mod = @import("tree.zig");
const draw = @import("apple_draw.zig");
const Engine = engine_mod.Engine;
const Node = tree_mod.Node;
const Object = cocoa.Object;
const id = cocoa.id;
const SEL = cocoa.c.SEL;
const BOOL = cocoa.c.BOOL;
const NSRect = cocoa.NSRect;
const NSPoint = cocoa.NSPoint;
const NSSize = cocoa.NSSize;

const log = std.log.scoped(.native_ui);

/// Run a command for the surface `token`; answer with `resolve(token, ...)`.
pub const Invoke = *const fn (ctx: ?*anyopaque, token: u64, call_id: u32, cmd: []const u8, args_json: []const u8) void;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    token: u64,
    engine: *Engine = undefined,
    /// The drawing view (+1), the window's content view.
    view: Object,
    transparent: bool,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    /// Field controls by node id (+1 each, subviews of `view`).
    fields: std.AutoHashMapUnmanaged(i64, Field) = .empty,
    hovered: i64 = 0,
    updating: bool = false,
    dark: bool = false,
    pointer_hand: bool = false,
    /// The window's label (ORIEL_NUI_SNAPSHOT file names).
    label: []u8 = &.{},
    snapshot_queued: bool = false,
    /// How long the last frame's render took (µs): the next waits at least
    /// twice that, so rendering leaves the main thread half free.
    render_us: u64 = 0,
};

const Field = struct {
    /// A plain view (+1) in the page's view, clipped to the part of the
    /// field the page shows (a field half scrolled out of its container is
    /// cut there, as in a browser): the control is its only subview.
    holder: Object,
    /// The text field, popup, or (text areas) the scroll view around the
    /// text view (held by `holder`).
    outer: Object,
    /// What has the text: the same, or the text view.
    inner: Object,
};

/// Live surfaces by token, and which surface and node a view or control
/// belongs to.
var surfaces: std.AutoHashMapUnmanaged(u64, *Surface) = .empty;
var by_view: std.AutoHashMapUnmanaged(usize, *Surface) = .empty;
const Owner = struct { token: u64, node: i64 };
var by_control: std.AutoHashMapUnmanaged(usize, Owner) = .empty;
var next_token: u64 = 1;

var view_class: ?cocoa.Class = null;
var holder_class: ?cocoa.Class = null;
var field_delegate: Object = cocoa.nil;

fn key(o: id) usize {
    return @intFromPtr(o);
}

pub fn get(token: u64) ?*Surface {
    return surfaces.get(token);
}

/// A command's answer, on the main thread (the surface may be gone by then).
pub fn resolve(token: u64, call_id: u32, ok: bool, text: []const u8) void {
    const s = surfaces.get(token) orelse return;
    s.engine.resolve(call_id, ok, text);
}

fn classes() void {
    if (view_class != null) return;
    view_class = cocoa.defineSubclass("OrielNuiView", "NSView", &.{}, .{
        .{ "isFlipped", yes },
        .{ "isOpaque", isOpaque },
        .{ "acceptsFirstResponder", yes },
        .{ "acceptsFirstMouse:", acceptsFirstMouse },
        .{ "drawRect:", drawRect },
        .{ "resizeSubviewsWithOldSize:", resizeSubviews },
        .{ "mouseDown:", mouseDown },
        .{ "mouseUp:", mouseUp },
        .{ "rightMouseUp:", rightMouseUp },
        .{ "mouseMoved:", mouseMoved },
        .{ "mouseDragged:", mouseMoved },
        .{ "mouseExited:", mouseExited },
        .{ "scrollWheel:", scrollWheel },
        .{ "keyDown:", keyDown },
        .{ "viewDidChangeEffectiveAppearance", appearanceChanged },
    });
    // A field's holder: flipped like the page, so frames read top-down.
    holder_class = cocoa.defineSubclass("OrielNuiFlippedView", "NSView", &.{}, .{
        .{ "isFlipped", yes },
    });
    field_delegate = cocoa.new(cocoa.defineClass("OrielNuiFieldDelegate", &.{ "NSTextFieldDelegate", "NSTextViewDelegate" }, .{
        .{ "controlTextDidChange:", controlTextDidChange },
        .{ "control:textView:doCommandBySelector:", controlCommand },
        .{ "textDidChange:", textDidChange },
        .{ "textView:doCommandBySelector:", textViewCommand },
        .{ "popupChanged:", popupChanged },
    }));
}

/// Create a window's page at `width`×`height` points and run it.
pub fn create(gpa: std.mem.Allocator, assets: []const engine_mod.Asset, platform_json: [:0]const u8, label: [:0]const u8, url: [:0]const u8, width: f32, height: f32, transparent: bool, invoke_fn: Invoke, invoke_ctx: ?*anyopaque) !*Surface {
    classes();
    const s = try gpa.create(Surface);
    errdefer gpa.destroy(s);
    const frame: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } };
    const view = view_class.?.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{frame});
    if (view.value == null) return error.CreateViewFailed;
    errdefer view.release();
    s.* = .{
        .gpa = gpa,
        .token = next_token,
        .view = view,
        .transparent = transparent,
        .invoke_fn = invoke_fn,
        .invoke_ctx = invoke_ctx,
        .label = try gpa.dupe(u8, label),
    };
    errdefer gpa.free(s.label);
    next_token += 1;
    // Mouse moves (hover, the hand cursor) wherever the view is.
    const tracking = cocoa.class("NSTrackingArea").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithRect:options:owner:userInfo:", .{
        frame, @as(c_ulong, 0x01 | 0x02 | 0x80 | 0x200), view, cocoa.nil, // entered/exited, moved, always, in visible rect
    });
    view.msgSend(void, "addTrackingArea:", .{tracking});
    tracking.release();
    try surfaces.put(gpa, s.token, s);
    errdefer _ = surfaces.remove(s.token);
    try by_view.put(gpa, key(view.value), s);
    errdefer _ = by_view.remove(key(view.value));
    s.dark = isDark(view);
    s.engine = try Engine.create(gpa, .{
        .ctx = s,
        .measure = measure,
        .laid_out = laidOut,
        .removed = removed,
        .add_timer = addTimer,
        .invoke = invoke,
        .focus = focus,
        .props = propsChanged,
        .request_frame = requestFrame,
    }, assets, platform_json, label, url, width, height);
    s.engine.boot(s.dark, false);
    return s;
}

/// Tear a surface down (its window is closing).
pub fn destroy(s: *Surface) void {
    _ = surfaces.remove(s.token);
    _ = by_view.remove(key(s.view.value));
    // The engine first: freeing its tree calls `removed` for every node,
    // which drops that node's control from `fields`.
    s.engine.destroy();
    var it = s.fields.iterator();
    while (it.next()) |e| dropField(e.value_ptr.*);
    s.fields.deinit(s.gpa);
    s.view.msgSend(void, "removeFromSuperview", .{});
    _ = s.view.msgSend(Object, "autorelease", .{}); // it may be in one of its own callbacks
    s.gpa.free(s.label);
    s.gpa.destroy(s);
}

fn dropField(f: Field) void {
    _ = by_control.remove(key(f.outer.value));
    _ = by_control.remove(key(f.inner.value));
    // A delegate outlives nothing: clear it before the control goes.
    if (f.inner.getClass()) |cls| if (cls.respondsToSelector(cocoa.objc.sel("setDelegate:"))) f.inner.msgSend(void, "setDelegate:", .{cocoa.nil});
    // A text field being edited: end it, so the window's field editor
    // doesn't keep a delegate that's going away.
    if (f.inner.getClass()) |cls| if (cls.respondsToSelector(cocoa.objc.sel("abortEditing"))) {
        _ = f.inner.msgSend(BOOL, "abortEditing", .{});
    };
    f.holder.msgSend(void, "removeFromSuperview", .{});
    // Autoreleased, not released: the page may drop a field from inside
    // that control's own callback (a handler for its Enter).
    _ = f.holder.msgSend(Object, "autorelease", .{}); // and with it the control
}

fn surfaceOf(ctx: *anyopaque) *Surface {
    return @ptrCast(@alignCast(ctx));
}

fn isDark(view: Object) bool {
    if (std.c.getenv("ORIEL_COLOR_SCHEME")) |v| return std.mem.eql(u8, std.mem.span(v), "dark");
    const appearance = view.msgSend(Object, "effectiveAppearance", .{});
    const name = cocoa.utf8(appearance.msgSend(Object, "name", .{})) orelse return false;
    return std.mem.indexOf(u8, name, "Dark") != null;
}

// ---------------------------------------------------------------------------
// Backend hooks

fn measure(_: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const fz = n.props.fz orelse 16;
    switch (n.kind) {
        .text => out.* = draw.measureText("NSFont", n, max_width),
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), @round(fz * 1.45) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, @round(fz * 1.45 * 2) },
        else => out.* = .{ 0, 0 },
    }
}

fn invoke(ctx: *anyopaque, _: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
    const s = surfaceOf(ctx);
    s.invoke_fn(s.invoke_ctx, s.token, call_id, cmd, args_json);
}

/// The page renders at most once per display frame (~60 a second), however
/// many events reach it (a chat streams a hundred tokens a second). A page
/// whose render takes long gets fewer frames: commands and events (a Stop
/// button) still get through between them.
fn requestFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    const t = std.heap.smp_allocator.create(u64) catch return s.engine.frame();
    t.* = s.token;
    const ms: u32 = @intCast(std.math.clamp(s.render_us * 2 / 1000, 16, 100));
    cocoa.afterMain(ms, t, onFrame);
}

fn nowUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

fn onFrame(p: ?*anyopaque) callconv(.c) void {
    const t: *u64 = @ptrCast(@alignCast(p.?));
    const token = t.*;
    std.heap.smp_allocator.destroy(t);
    const s = surfaces.get(token) orelse return;
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    const start = nowUs();
    s.engine.frame();
    // The surface may have gone during the frame (the page closed its window).
    if (surfaces.get(token)) |still| still.render_us = nowUs() - start;
}

const TimerData = struct { token: u64, id: u32 };

fn addTimer(ctx: *anyopaque, _: *Engine, timer_id: u32, ms: u32) void {
    const s = surfaceOf(ctx);
    const d = std.heap.smp_allocator.create(TimerData) catch return;
    d.* = .{ .token = s.token, .id = timer_id };
    cocoa.afterMain(ms, d, onTimer);
}

fn onTimer(p: ?*anyopaque) callconv(.c) void {
    const d: *TimerData = @ptrCast(@alignCast(p.?));
    const token = d.token;
    const timer_id = d.id;
    std.heap.smp_allocator.destroy(d);
    const s = surfaces.get(token) orelse return; // the window is gone
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    s.engine.timerFired(timer_id);
}

fn focus(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    const f = s.fields.get(n.id) orelse return;
    const win = s.view.msgSend(Object, "window", .{});
    _ = win.msgSend(BOOL, "makeFirstResponder:", .{f.inner});
}

fn removed(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    draw.dropText(n);
    if (s.fields.fetchRemove(n.id)) |kv| dropField(kv.value);
}

/// New props: a text node's CoreText objects are stale.
fn propsChanged(_: *anyopaque, n: *Node, _: std.json.Value) void {
    draw.dropText(n);
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    syncFields(s);
    s.view.msgSend(void, "setNeedsDisplay:", .{cocoa.boolean(true)});
    if (std.c.getenv("ORIEL_NUI_SNAPSHOT") != null and !s.snapshot_queued) {
        s.snapshot_queued = true;
        const t = std.heap.smp_allocator.create(u64) catch return;
        t.* = s.token;
        cocoa.afterMain(400, t, snapshot);
    }
}

/// Debugging (ORIEL_NUI_SNAPSHOT=<dir>): the window as drawn, fields
/// included, in <dir>/<label>.png, a moment after each layout.
fn snapshot(p: ?*anyopaque) callconv(.c) void {
    const t: *u64 = @ptrCast(@alignCast(p.?));
    const token = t.*;
    std.heap.smp_allocator.destroy(t);
    const s = surfaces.get(token) orelse return;
    s.snapshot_queued = false;
    const dir = std.c.getenv("ORIEL_NUI_SNAPSHOT") orelse return;
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    const bounds = s.view.msgSend(NSRect, "bounds", .{});
    const bitmap = s.view.msgSend(Object, "bitmapImageRepForCachingDisplayInRect:", .{bounds});
    if (bitmap.value == null) return;
    s.view.msgSend(void, "cacheDisplayInRect:toBitmapImageRep:", .{ bounds, bitmap });
    const props = cocoa.class("NSDictionary").msgSend(Object, "dictionary", .{});
    const png = bitmap.msgSend(Object, "representationUsingType:properties:", .{ @as(c_ulong, 4), props }); // PNG
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}.png", .{ std.mem.span(dir), s.label }) catch return;
    const ns = cocoa.nsString(path) orelse return;
    defer ns.release();
    _ = png.msgSend(BOOL, "writeToFile:atomically:", .{ ns, cocoa.boolean(true) });
}

// ---------------------------------------------------------------------------
// Fields: NSTextField (input), NSTextView in an NSScrollView (textarea),
// NSPopUpButton (select)

fn syncFields(s: *Surface) void {
    var it = s.engine.tree.nodes.valueIterator();
    while (it.next()) |np| {
        const n = np.*;
        if (n.kind != .input and n.kind != .textarea and n.kind != .select) continue;
        const f = s.fields.get(n.id) orelse blk: {
            const f = makeField(s, n) orelse continue;
            s.fields.put(s.gpa, n.id, f) catch {
                dropField(f);
                continue;
            };
            break :blk f;
        };
        s.updating = true;
        defer s.updating = false;
        if (n.pending_value) |v| {
            n.pending_value = null;
            setValue(n, f, v);
        }
        style(n, f);
        // The holder covers the visible part of the field; the control sits
        // at the field's place inside it.
        const r = n.content();
        const shown = draw.visiblePart(&s.engine.tree, n);
        f.holder.msgSend(void, "setFrame:", .{NSRect{ .origin = .{ .x = shown.x, .y = shown.y }, .size = .{ .width = shown.w, .height = shown.h } }});
        f.outer.msgSend(void, "setFrame:", .{NSRect{ .origin = .{ .x = r.x - shown.x, .y = r.y - shown.y }, .size = .{ .width = @max(1, r.w), .height = @max(1, r.h) } }});
        const visible = shown.h > 1 and shown.w > 1 and n.props.vis != false;
        f.holder.msgSend(void, "setHidden:", .{cocoa.boolean(!visible)});
        if (n.kind != .textarea) f.inner.msgSend(void, "setEnabled:", .{cocoa.boolean(!n.props.dis)}) else f.inner.msgSend(void, "setEditable:", .{cocoa.boolean(!n.props.dis)});
    }
}

fn makeField(s: *Surface, n: *Node) ?Field {
    const zero: NSRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 10 } };
    var f: Field = switch (n.kind) {
        .input => blk: {
            const cls = cocoa.class(if (n.props.pw) "NSSecureTextField" else "NSTextField");
            const tf = cls.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (tf.value == null) return null;
            tf.msgSend(void, "setBezeled:", .{cocoa.boolean(false)});
            tf.msgSend(void, "setBordered:", .{cocoa.boolean(false)});
            tf.msgSend(void, "setDrawsBackground:", .{cocoa.boolean(false)});
            tf.msgSend(void, "setFocusRingType:", .{@as(c_ulong, 1)}); // none: the page draws its own
            tf.msgSend(void, "setUsesSingleLineMode:", .{cocoa.boolean(true)});
            if (n.props.ph) |ph| if (cocoa.nsString(ph)) |str| {
                defer str.release();
                tf.msgSend(void, "setPlaceholderString:", .{str});
            };
            tf.msgSend(void, "setDelegate:", .{field_delegate});
            break :blk .{ .holder = cocoa.nil, .outer = tf, .inner = tf };
        },
        .textarea => blk: {
            const sv = cocoa.class("NSScrollView").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (sv.value == null) return null;
            sv.msgSend(void, "setDrawsBackground:", .{cocoa.boolean(false)});
            sv.msgSend(void, "setBorderType:", .{@as(c_ulong, 0)});
            sv.msgSend(void, "setHasVerticalScroller:", .{cocoa.boolean(true)});
            sv.msgSend(void, "setAutohidesScrollers:", .{cocoa.boolean(true)});
            const tv = cocoa.class("NSTextView").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (tv.value == null) {
                sv.release();
                return null;
            }
            tv.msgSend(void, "setDrawsBackground:", .{cocoa.boolean(false)});
            tv.msgSend(void, "setRichText:", .{cocoa.boolean(false)});
            tv.msgSend(void, "setAutomaticQuoteSubstitutionEnabled:", .{cocoa.boolean(false)});
            tv.msgSend(void, "setVerticallyResizable:", .{cocoa.boolean(true)});
            tv.msgSend(void, "setHorizontallyResizable:", .{cocoa.boolean(false)});
            tv.msgSend(void, "setAutoresizingMask:", .{@as(c_ulong, 2)}); // width sizable
            tv.msgSend(void, "setTextContainerInset:", .{NSSize{ .width = 0, .height = 0 }});
            tv.msgSend(Object, "textContainer", .{}).msgSend(void, "setLineFragmentPadding:", .{@as(f64, 0)});
            tv.msgSend(void, "setDelegate:", .{field_delegate});
            sv.msgSend(void, "setDocumentView:", .{tv});
            tv.release(); // the scroll view holds it
            break :blk .{ .holder = cocoa.nil, .outer = sv, .inner = tv };
        },
        .select => blk: {
            const pb = cocoa.class("NSPopUpButton").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:pullsDown:", .{ zero, cocoa.boolean(false) });
            if (pb.value == null) return null;
            pb.msgSend(void, "setBordered:", .{cocoa.boolean(false)});
            // Each item carries its option's index as its tag: titles may
            // repeat (addItemWithTitle: replaces an equal one) or be skipped.
            const no_key = cocoa.nsString("") orelse {
                pb.release();
                return null;
            };
            defer no_key.release();
            const menu = pb.msgSend(Object, "menu", .{});
            if (n.props.options) |opts| for (opts, 0..) |o, i| if (cocoa.nsString(o[1])) |str| {
                defer str.release();
                const item = menu.msgSend(Object, "addItemWithTitle:action:keyEquivalent:", .{ str, @as(cocoa.c.SEL, null), no_key });
                item.msgSend(void, "setTag:", .{@as(c_long, @intCast(i))});
            };
            pb.msgSend(void, "setTarget:", .{field_delegate});
            pb.msgSend(void, "setAction:", .{cocoa.objc.sel("popupChanged:").value});
            break :blk .{ .holder = cocoa.nil, .outer = pb, .inner = pb };
        },
        else => return null,
    };
    const holder = holder_class.?.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
    if (holder.value == null) {
        f.outer.release();
        return null;
    }
    if (holder.getClass().?.respondsToSelector(cocoa.objc.sel("setClipsToBounds:"))) holder.msgSend(void, "setClipsToBounds:", .{cocoa.boolean(true)}); // macOS 14+; before, views always clip
    holder.msgSend(void, "addSubview:", .{f.outer});
    f.outer.release(); // the holder keeps it
    f.holder = holder;
    by_control.put(s.gpa, key(f.outer.value), .{ .token = s.token, .node = n.id }) catch {};
    by_control.put(s.gpa, key(f.inner.value), .{ .token = s.token, .node = n.id }) catch {};
    s.view.msgSend(void, "addSubview:", .{holder});
    return f;
}

fn setValue(n: *Node, f: Field, v: []const u8) void {
    switch (n.kind) {
        .input => if (cocoa.nsString(v)) |str| {
            defer str.release();
            f.inner.msgSend(void, "setStringValue:", .{str});
        },
        .textarea => if (cocoa.nsString(v)) |str| {
            defer str.release();
            f.inner.msgSend(void, "setString:", .{str});
        },
        .select => if (n.props.options) |opts| for (opts, 0..) |o, i| {
            if (std.mem.eql(u8, o[0], v)) _ = f.inner.msgSend(BOOL, "selectItemWithTag:", .{@as(c_long, @intCast(i))});
        },
        else => {},
    }
}

fn style(n: *Node, f: Field) void {
    const c = n.props.col orelse tree_mod.Color{ 0, 0, 0, 1 };
    const color = cocoa.class("NSColor").msgSend(Object, "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, c[0] / 255), @as(f64, c[1] / 255), @as(f64, c[2] / 255), @as(f64, c[3]),
    });
    const font = cocoa.class("NSFont").msgSend(Object, "systemFontOfSize:", .{@as(f64, n.props.fz orelse 16)});
    f.inner.msgSend(void, "setFont:", .{font});
    if (n.kind == .select) return;
    f.inner.msgSend(void, "setTextColor:", .{color});
    if (n.kind == .textarea) f.inner.msgSend(void, "setInsertionPointColor:", .{color});
}

fn ownerOf(control: id) ?struct { s: *Surface, n: *Node } {
    const o = by_control.get(key(control)) orelse return null;
    const s = surfaces.get(o.token) orelse return null;
    const n = s.engine.tree.get(o.node) orelse return null;
    return .{ .s = s, .n = n };
}

fn sendValue(s: *Surface, n: *Node, kind: []const u8, text: []const u8) void {
    const json = std.json.Stringify.valueAlloc(s.gpa, text, .{}) catch return;
    defer s.gpa.free(json);
    _ = s.engine.event(n.id, kind, json);
}

fn controlTextDidChange(_: id, _: SEL, note: id) callconv(.c) void {
    const field = (Object{ .value = note }).msgSend(Object, "object", .{});
    const o = ownerOf(field.value) orelse return;
    if (o.s.updating) return;
    const text = cocoa.utf8(field.msgSend(Object, "stringValue", .{})) orelse "";
    sendValue(o.s, o.n, "input", text);
}

/// Enter (and Escape) in a field: the page's keydown; true when it
/// prevented the default (no newline in a text area).
fn commandKey(control: id, selector: SEL) ?bool {
    const name: []const u8 = if (selector == cocoa.objc.sel("insertNewline:").value)
        "Enter"
    else if (selector == cocoa.objc.sel("cancelOperation:").value)
        "Escape"
    else
        return null;
    const o = ownerOf(control) orelse return null;
    const event = cocoa.class("NSApplication").msgSend(Object, "sharedApplication", .{}).msgSend(Object, "currentEvent", .{});
    const flags = if (event.value != null) modFlags(event.msgSend(c_ulong, "modifierFlags", .{})) else 0;
    var buf: [48]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d}]", .{ name, flags }) catch return null;
    return o.s.engine.event(o.n.id, "key", json);
}

fn controlCommand(_: id, _: SEL, control: id, _: id, selector: SEL) callconv(.c) BOOL {
    return cocoa.boolean(commandKey(control, selector) orelse false);
}

fn textDidChange(_: id, _: SEL, note: id) callconv(.c) void {
    const tv = (Object{ .value = note }).msgSend(Object, "object", .{});
    const o = ownerOf(tv.value) orelse return;
    if (o.s.updating) return;
    const text = cocoa.utf8(tv.msgSend(Object, "string", .{})) orelse "";
    sendValue(o.s, o.n, "input", text);
}

fn textViewCommand(_: id, _: SEL, tv: id, selector: SEL) callconv(.c) BOOL {
    return cocoa.boolean(commandKey(tv, selector) orelse false);
}

fn popupChanged(_: id, _: SEL, sender: id) callconv(.c) void {
    const o = ownerOf(sender) orelse return;
    if (o.s.updating) return;
    const item = (Object{ .value = sender }).msgSend(Object, "selectedItem", .{});
    if (item.value == null) return;
    const i = item.msgSend(c_long, "tag", .{});
    const opts = o.n.props.options orelse return;
    if (i < 0 or @as(usize, @intCast(i)) >= opts.len) return;
    sendValue(o.s, o.n, "change", opts[@intCast(i)][0]);
}

// ---------------------------------------------------------------------------
// The view

fn yes(_: id, _: SEL) callconv(.c) BOOL {
    return cocoa.boolean(true);
}

fn acceptsFirstMouse(_: id, _: SEL, _: id) callconv(.c) BOOL {
    return cocoa.boolean(true);
}

fn isOpaque(self: id, _: SEL) callconv(.c) BOOL {
    const s = by_view.get(key(self)) orelse return cocoa.boolean(false);
    return cocoa.boolean(!s.transparent);
}

fn drawRect(self: id, _: SEL, _: NSRect) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const ctx = cocoa.class("NSGraphicsContext").msgSend(Object, "currentContext", .{});
    const cg: ?*anyopaque = ctx.msgSend(?*anyopaque, "CGContext", .{});
    draw.paint("NSFont", @ptrCast(cg orelse return), &s.engine.tree, s.transparent);
}

fn resizeSubviews(self: id, _: SEL, _: NSSize) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const b = (Object{ .value = self }).msgSend(NSRect, "bounds", .{});
    s.engine.resize(@floatCast(b.size.width), @floatCast(b.size.height), s.dark);
}

fn appearanceChanged(self: id, _: SEL) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const dark = isDark(s.view);
    if (dark == s.dark) return;
    s.dark = dark;
    // Same size: force the page to hear the new color scheme.
    const w = s.engine.tree.width;
    s.engine.tree.width = -1;
    s.engine.resize(w, s.engine.tree.height, dark);
}

fn point(view: id, event: id) [2]f32 {
    const ev: Object = .{ .value = event };
    const p = ev.msgSend(NSPoint, "locationInWindow", .{});
    const q = (Object{ .value = view }).msgSend(NSPoint, "convertPoint:fromView:", .{ p, cocoa.nil });
    return .{ @floatCast(q.x), @floatCast(q.y) };
}

/// NSEventModifierFlags to the page's (shift 1, control 2, alt 4, meta 8).
fn modFlags(flags: c_ulong) u32 {
    var f: u32 = 0;
    if (flags & (1 << 17) != 0) f |= 1;
    if (flags & (1 << 18) != 0) f |= 2;
    if (flags & (1 << 19) != 0) f |= 4;
    if (flags & (1 << 20) != 0) f |= 8;
    return f;
}

fn mouseDown(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    // A click on the page takes the keyboard from a field.
    _ = s.view.msgSend(Object, "window", .{}).msgSend(BOOL, "makeFirstResponder:", .{s.view});
    const p = point(self, event);
    // :active while the button is down.
    if (s.engine.tree.hit(p[0], p[1])) |n| _ = s.engine.event(n.id, "press", "null");
}

fn mouseUp(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    _ = s.engine.event(0, "release", "null");
    const p = point(self, event);
    const hit = s.engine.tree.hit(p[0], p[1]);
    if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("native ui: click at {d:.0},{d:.0} on node {d}", .{ p[0], p[1], if (hit) |h| h.id else 0 });
    const n = hit orelse return;
    const flags = (Object{ .value = event }).msgSend(c_ulong, "modifierFlags", .{});
    // Control-click: the context menu, as on every Mac.
    if (flags & (1 << 18) != 0) return contextMenu(s, n, p);
    if (disabledUp(n)) return;
    var buf: [16]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{d}", .{modFlags(flags)}) catch return;
    _ = s.engine.event(n.id, "click", json);
}

fn rightMouseUp(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const p = point(self, event);
    const n = s.engine.tree.hit(p[0], p[1]) orelse return;
    contextMenu(s, n, p);
}

fn contextMenu(s: *Surface, n: *Node, p: [2]f32) void {
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0}]", .{ p[0], p[1] }) catch return;
    _ = s.engine.event(n.id, "contextmenu", json);
}

fn disabledUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.dis) return true;
    return false;
}

fn clickableUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.click) return !x.props.dis;
    return false;
}

fn mouseMoved(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const p = point(self, event);
    const n = s.engine.tree.hit(p[0], p[1]);
    const hand = n != null and clickableUp(n.?);
    if (hand != s.pointer_hand) {
        s.pointer_hand = hand;
        cocoa.class("NSCursor").msgSend(Object, if (hand) "pointingHandCursor" else "arrowCursor", .{}).msgSend(void, "set", .{});
    }
    // :hover: the page hears when the node under the pointer changes.
    const nid: i64 = if (n) |node| node.id else 0;
    if (nid != s.hovered) {
        s.hovered = nid;
        _ = s.engine.event(nid, "hover", "null");
    }
}

fn mouseExited(self: id, _: SEL, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    if (s.pointer_hand) {
        s.pointer_hand = false;
        cocoa.class("NSCursor").msgSend(Object, "arrowCursor", .{}).msgSend(void, "set", .{});
    }
    if (s.hovered == 0) return;
    s.hovered = 0;
    _ = s.engine.event(0, "hover", "null");
}

fn scrollWheel(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const ev: Object = .{ .value = event };
    const precise = cocoa.isTrue(ev.msgSend(BOOL, "hasPreciseScrollingDeltas", .{}));
    const raw: f64 = ev.msgSend(f64, "scrollingDeltaY", .{});
    // Positive deltas move the content down (scroll up): the page's dy is the opposite.
    const dy: f32 = @floatCast(-raw * (if (precise) @as(f64, 1) else 16));
    if (dy == 0) return;
    const p = point(self, event);
    var target = s.engine.tree.scroller(s.engine.tree.hit(p[0], p[1]));
    while (target) |t| {
        if (s.engine.scrollBy(t, dy)) return;
        target = s.engine.tree.scroller(t.parent);
    }
}

fn keyName(event: Object) ?[]const u8 {
    const code = event.msgSend(c_ushort, "keyCode", .{});
    return switch (code) {
        36, 76 => "Enter",
        53 => "Escape",
        48 => "Tab",
        51 => "Backspace",
        117 => "Delete",
        126 => "ArrowUp",
        125 => "ArrowDown",
        123 => "ArrowLeft",
        124 => "ArrowRight",
        115 => "Home",
        119 => "End",
        116 => "PageUp",
        121 => "PageDown",
        49 => " ",
        else => blk: {
            const chars = cocoa.utf8(event.msgSend(Object, "charactersIgnoringModifiers", .{})) orelse break :blk null;
            if (chars.len == 0 or chars.len > 4) break :blk null;
            break :blk chars;
        },
    };
}

fn keyDown(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const ev: Object = .{ .value = event };
    const name = keyName(ev) orelse return;
    const k = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return;
    defer s.gpa.free(k);
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{s},{d}]", .{ k, modFlags(ev.msgSend(c_ulong, "modifierFlags", .{})) }) catch return;
    _ = s.engine.event(0, "key", json);
}

test {
    _ = log;
}
