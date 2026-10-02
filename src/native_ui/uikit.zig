//! The native renderer's UIKit backend (iOS, docs/native-renderer.md).
//!
//! The same design as AppKit (appkit.zig) and Android: one view
//! (`OrielNuiView`) draws the page with CoreGraphics and CoreText
//! (apple_draw.zig, shared with macOS), and real UITextField / UITextView /
//! UIButton-with-a-menu controls sit over the fields. Taps, long presses
//! (the context menu) and drags (scrolling, with a fling) come from gesture
//! recognizers and are hit-tested on the node tree in Zig, as Android's.
//!
//! Main thread only. A surface is found by its token (timers, frames and
//! command answers that arrive after its window closed find nothing).

const std = @import("std");
const apple = @import("../platform/ios/apple.zig");
const engine_mod = @import("engine.zig");
const tree_mod = @import("tree.zig");
const draw = @import("apple_draw.zig");
const Engine = engine_mod.Engine;
const Node = tree_mod.Node;
const Object = apple.Object;
const id = apple.id;
const SEL = apple.c.SEL;
const BOOL = apple.c.BOOL;
const CGRect = apple.CGRect;
const CGPoint = apple.CGPoint;

const log = std.log.scoped(.native_ui);

/// Run a command for the surface `token`; answer with `resolve(token, ...)`.
pub const Invoke = *const fn (ctx: ?*anyopaque, token: u64, call_id: u32, cmd: []const u8, args_json: []const u8) void;

pub const Surface = struct {
    gpa: std.mem.Allocator,
    token: u64,
    engine: *Engine = undefined,
    /// The drawing view (+1), in the window's controller view.
    view: Object,
    transparent: bool,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    /// Field controls by node id.
    fields: std.AutoHashMapUnmanaged(i64, Field) = .empty,
    updating: bool = false,
    dark: bool = false,
    /// How long the last frame's render took (µs), see `requestFrame`.
    render_us: u64 = 0,
    /// A fling in progress: its speed (points per second, page direction)
    /// and the node it scrolls under.
    fling_v: f32 = 0,
    fling_at: [2]f32 = .{ 0, 0 },
    fling_gen: u32 = 0,
};

const Field = struct {
    /// A plain view (+1) in the page's view, clipped to the part of the
    /// field the page shows (`apple_draw.visiblePart`): the control is its
    /// only subview.
    holder: Object,
    /// The UITextField, UITextView or UIButton (held by `holder`).
    control: Object,
};

/// Live surfaces by token, and which surface and node a view or control
/// belongs to.
var surfaces: std.AutoHashMapUnmanaged(u64, *Surface) = .empty;
var by_view: std.AutoHashMapUnmanaged(usize, *Surface) = .empty;
const Owner = struct { token: u64, node: i64 };
var by_control: std.AutoHashMapUnmanaged(usize, Owner) = .empty;
var next_token: u64 = 1;

var view_class: ?apple.Class = null;
var field_delegate: Object = apple.nil;

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
    view_class = apple.defineSubclass("OrielNuiView", "UIView", &.{}, .{
        .{ "drawRect:", drawRect },
        .{ "layoutSubviews", layoutSubviews },
        .{ "traitCollectionDidChange:", traitsChanged },
        .{ "touchesBegan:withEvent:", touchesBegan },
        .{ "touchesEnded:withEvent:", touchesEnded },
        .{ "touchesCancelled:withEvent:", touchesEnded },
        .{ "nuiTap:", onTap },
        .{ "nuiLongPress:", onLongPress },
        .{ "nuiPan:", onPan },
    });
    field_delegate = apple.new(apple.defineClass("OrielNuiFieldDelegate", &.{ "UITextFieldDelegate", "UITextViewDelegate" }, .{
        .{ "nuiFieldChanged:", fieldChanged },
        .{ "textFieldShouldReturn:", fieldShouldReturn },
        .{ "textViewDidChange:", textViewDidChange },
        .{ "textView:shouldChangeTextInRange:replacementText:", textViewShouldChange },
    }));
}

/// Create a window's page at `width`×`height` points and run it.
pub fn create(gpa: std.mem.Allocator, assets: []const engine_mod.Asset, platform_json: [:0]const u8, label: [:0]const u8, url: [:0]const u8, width: f32, height: f32, transparent: bool, invoke_fn: Invoke, invoke_ctx: ?*anyopaque) !*Surface {
    classes();
    const s = try gpa.create(Surface);
    errdefer gpa.destroy(s);
    const frame: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = width, .height = height } };
    const view = view_class.?.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{frame});
    if (view.value == null) return error.CreateViewFailed;
    errdefer view.release();
    view.msgSend(void, "setOpaque:", .{apple.boolean(!transparent)});
    view.msgSend(void, "setBackgroundColor:", .{apple.class("UIColor").msgSend(Object, "clearColor", .{})});
    view.msgSend(void, "setContentMode:", .{@as(isize, 3)}); // redraw on bounds changes
    view.msgSend(void, "setMultipleTouchEnabled:", .{apple.boolean(false)});
    s.* = .{
        .gpa = gpa,
        .token = next_token,
        .view = view,
        .transparent = transparent,
        .invoke_fn = invoke_fn,
        .invoke_ctx = invoke_ctx,
    };
    next_token += 1;
    inline for (.{ .{ "UITapGestureRecognizer", "nuiTap:" }, .{ "UILongPressGestureRecognizer", "nuiLongPress:" }, .{ "UIPanGestureRecognizer", "nuiPan:" } }) |g| {
        const r = apple.class(g[0]).msgSend(Object, "alloc", .{}).msgSend(Object, "initWithTarget:action:", .{ view, apple.objc.sel(g[1]).value });
        // Touches still reach the view (:active), and fields keep theirs.
        r.msgSend(void, "setCancelsTouchesInView:", .{apple.boolean(false)});
        view.msgSend(void, "addGestureRecognizer:", .{r});
        r.release();
    }
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
    s.engine.boot(s.dark, true);
    return s;
}

/// Tear a surface down (its window is closing).
pub fn destroy(s: *Surface) void {
    _ = surfaces.remove(s.token);
    _ = by_view.remove(key(s.view.value));
    // The engine first: freeing its tree calls `removed` for every node,
    // which drops that node's control from `fields`.
    s.engine.destroy();
    var it = s.fields.valueIterator();
    while (it.next()) |f| dropField(f.*);
    s.fields.deinit(s.gpa);
    s.view.msgSend(void, "removeFromSuperview", .{});
    releaseLater(s.view); // it may be in one of its own callbacks
    s.gpa.destroy(s);
}

fn dropField(f: Field) void {
    _ = by_control.remove(key(f.control.value));
    if (f.control.getClass()) |cls| if (cls.respondsToSelector(apple.objc.sel("setDelegate:"))) f.control.msgSend(void, "setDelegate:", .{apple.nil});
    f.holder.msgSend(void, "removeFromSuperview", .{});
    // Released later, not now: the page may drop a field from inside that
    // control's own callback (a handler for its Return or its menu).
    releaseLater(f.holder); // and with it the control
}

/// Release `o` (our reference) once the run loop is back in its default
/// mode. The delayed perform retains `o` and releases it after performing,
/// so the performed `release` is the one that drops ours.
fn releaseLater(o: Object) void {
    o.msgSend(void, "performSelector:withObject:afterDelay:", .{ apple.objc.sel("release").value, apple.nil, @as(f64, 0) });
}

fn surfaceOf(ctx: *anyopaque) *Surface {
    return @ptrCast(@alignCast(ctx));
}

fn isDark(view: Object) bool {
    if (std.c.getenv("ORIEL_COLOR_SCHEME")) |v| return std.mem.eql(u8, std.mem.span(v), "dark");
    return view.msgSend(Object, "traitCollection", .{}).msgSend(isize, "userInterfaceStyle", .{}) == 2;
}

// ---------------------------------------------------------------------------
// Backend hooks

fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const fz = n.props.fz orelse 16;
    switch (n.kind) {
        .text => out.* = draw.measureText("UIFont", n, max_width),
        .image => out.* = draw.measureImage(surfaceOf(ctx).engine, n, max_width),
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), @round(fz * 1.45) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, @round(fz * 1.45 * 2) },
        else => out.* = .{ 0, 0 },
    }
}

fn invoke(ctx: *anyopaque, _: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
    const s = surfaceOf(ctx);
    s.invoke_fn(s.invoke_ctx, s.token, call_id, cmd, args_json);
}

fn nowUs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

/// The page renders at most once per display frame, and a page whose render
/// takes long gets fewer frames (twice its render time apart), so commands
/// and events still get through between them.
fn requestFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    const t = std.heap.smp_allocator.create(u64) catch return s.engine.frame();
    t.* = s.token;
    const ms: u32 = @intCast(std.math.clamp(s.render_us * 2 / 1000, 16, 100));
    apple.afterMain(ms, t, onFrame);
}

fn onFrame(p: ?*anyopaque) callconv(.c) void {
    const t: *u64 = @ptrCast(@alignCast(p.?));
    const token = t.*;
    std.heap.smp_allocator.destroy(t);
    const s = surfaces.get(token) orelse return;
    const pool = apple.objc.AutoreleasePool.init();
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
    apple.afterMain(ms, d, onTimer);
}

fn onTimer(p: ?*anyopaque) callconv(.c) void {
    const d: *TimerData = @ptrCast(@alignCast(p.?));
    const token = d.token;
    const timer_id = d.id;
    std.heap.smp_allocator.destroy(d);
    const s = surfaces.get(token) orelse return; // the window is gone
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    s.engine.timerFired(timer_id);
}

fn focus(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    const f = s.fields.get(n.id) orelse return;
    _ = f.control.msgSend(BOOL, "becomeFirstResponder", .{});
}

fn removed(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    draw.dropNative(n);
    if (s.fields.fetchRemove(n.id)) |kv| dropField(kv.value);
}

/// New props: a text node's CoreText objects are stale.
fn propsChanged(_: *anyopaque, n: *Node, _: std.json.Value) void {
    draw.dropText(n);
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    syncFields(s);
    s.view.msgSend(void, "setNeedsDisplay", .{});
}

// ---------------------------------------------------------------------------
// Fields: UITextField (input), UITextView (textarea), a UIButton with a
// menu (select)

fn syncFields(s: *Surface) void {
    var it = s.engine.tree.nodes.valueIterator();
    while (it.next()) |np| {
        const n = np.*;
        if (n.kind != .input and n.kind != .textarea and n.kind != .select) continue;
        const field = s.fields.get(n.id) orelse blk: {
            const f = makeField(s, n) orelse continue;
            s.fields.put(s.gpa, n.id, f) catch {
                dropField(f);
                continue;
            };
            break :blk f;
        };
        const f = field.control;
        s.updating = true;
        defer s.updating = false;
        if (n.pending_value) |v| {
            n.pending_value = null;
            setValue(n, f, v);
        }
        style(n, f);
        // The page changes placeholders; a text area's is drawn under it.
        if (n.kind == .input) if (apple.nsString(n.props.ph orelse "")) |ph| {
            defer ph.release();
            f.msgSend(void, "setPlaceholder:", .{ph});
        };
        // The holder covers the visible part of the field; the control sits
        // at the field's place inside it.
        const r = n.content();
        const shown = draw.visiblePart(&s.engine.tree, n);
        field.holder.msgSend(void, "setFrame:", .{CGRect{ .origin = .{ .x = shown.x, .y = shown.y }, .size = .{ .width = shown.w, .height = shown.h } }});
        f.msgSend(void, "setFrame:", .{CGRect{ .origin = .{ .x = r.x - shown.x, .y = r.y - shown.y }, .size = .{ .width = @max(1, r.w), .height = @max(1, r.h) } }});
        const visible = shown.h > 1 and shown.w > 1 and n.props.vis != false;
        field.holder.msgSend(void, "setHidden:", .{apple.boolean(!visible)});
        if (n.kind == .textarea) f.msgSend(void, "setEditable:", .{apple.boolean(!n.props.dis)}) else f.msgSend(void, "setEnabled:", .{apple.boolean(!n.props.dis)});
    }
}

const UIControlEventEditingChanged: c_ulong = 1 << 17;

fn makeField(s: *Surface, n: *Node) ?Field {
    const zero: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 10 } };
    const f: Object = switch (n.kind) {
        .input => blk: {
            const tf = apple.class("UITextField").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (tf.value == null) return null;
            tf.msgSend(void, "setBorderStyle:", .{@as(isize, 0)}); // none: the page draws its own
            tf.msgSend(void, "setSecureTextEntry:", .{apple.boolean(n.props.pw)});
            if (n.props.ph) |ph| if (apple.nsString(ph)) |str| {
                defer str.release();
                tf.msgSend(void, "setPlaceholder:", .{str});
            };
            tf.msgSend(void, "setDelegate:", .{field_delegate});
            tf.msgSend(void, "addTarget:action:forControlEvents:", .{ field_delegate, apple.objc.sel("nuiFieldChanged:").value, UIControlEventEditingChanged });
            break :blk tf;
        },
        .textarea => blk: {
            const tv = apple.class("UITextView").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (tv.value == null) return null;
            tv.msgSend(void, "setBackgroundColor:", .{apple.class("UIColor").msgSend(Object, "clearColor", .{})});
            tv.msgSend(void, "setTextContainerInset:", .{UIEdgeInsets{}});
            tv.msgSend(Object, "textContainer", .{}).msgSend(void, "setLineFragmentPadding:", .{@as(f64, 0)});
            tv.msgSend(void, "setDelegate:", .{field_delegate});
            break :blk tv;
        },
        .select => blk: {
            const b = apple.class("UIButton").msgSend(Object, "buttonWithType:", .{@as(isize, 1)}).retain(); // system
            if (b.value == null) return null;
            b.msgSend(void, "setContentHorizontalAlignment:", .{@as(isize, 4)}); // leading
            setMenu(b, n);
            b.msgSend(void, "setShowsMenuAsPrimaryAction:", .{apple.boolean(true)});
            break :blk b;
        },
        else => return null,
    };
    const holder = apple.new(apple.class("UIView"));
    if (holder.value == null) {
        f.release();
        return null;
    }
    holder.msgSend(void, "setClipsToBounds:", .{apple.boolean(true)});
    holder.msgSend(void, "addSubview:", .{f});
    f.release(); // the holder keeps it
    by_control.put(s.gpa, key(f.value), .{ .token = s.token, .node = n.id }) catch {};
    s.view.msgSend(void, "addSubview:", .{holder});
    return .{ .holder = holder, .control = f };
}

const UIEdgeInsets = extern struct { top: f64 = 0, left: f64 = 0, bottom: f64 = 0, right: f64 = 0 };

/// A select's options as the button's menu: each action's identifier is its
/// index, so the (capture-free) handler finds it from the action alone.
fn setMenu(b: Object, n: *Node) void {
    const opts = n.props.options orelse return;
    const list = apple.class("NSMutableArray").msgSend(Object, "array", .{});
    const handler = apple.globalBlock(onMenuAction);
    var buf: [24]u8 = undefined;
    for (opts, 0..) |o, i| {
        const title = apple.nsString(o[1]) orelse continue;
        defer title.release();
        const ident = apple.nsString(std.fmt.bufPrint(&buf, "{d}", .{i}) catch continue) orelse continue;
        defer ident.release();
        const action = apple.class("UIAction").msgSend(Object, "actionWithTitle:image:identifier:handler:", .{ title, apple.nil, ident, handler });
        list.msgSend(void, "addObject:", .{action});
    }
    const empty = apple.nsString("") orelse return;
    defer empty.release();
    const menu = apple.class("UIMenu").msgSend(Object, "menuWithTitle:children:", .{ empty, list });
    b.msgSend(void, "setMenu:", .{menu});
}

fn onMenuAction(_: *anyopaque, action_id: id) callconv(.c) void {
    const action: Object = .{ .value = action_id };
    const sender = action.msgSend(Object, "sender", .{});
    const o = ownerOf(sender.value) orelse return;
    const ident = apple.utf8(action.msgSend(Object, "identifier", .{})) orelse return;
    const i = std.fmt.parseInt(usize, ident, 10) catch return;
    const opts = o.n.props.options orelse return;
    if (i >= opts.len) return;
    setValue(o.n, sender, opts[i][0]);
    sendValue(o.s, o.n, "change", opts[i][0]);
}

fn setValue(n: *Node, f: Object, v: []const u8) void {
    switch (n.kind) {
        .input, .textarea => if (apple.nsString(v)) |str| {
            defer str.release();
            f.msgSend(void, "setText:", .{str});
        },
        .select => if (n.props.options) |opts| for (opts) |o| {
            if (!std.mem.eql(u8, o[0], v)) continue;
            if (apple.nsString(o[1])) |title| {
                defer title.release();
                f.msgSend(void, "setTitle:forState:", .{ title, @as(c_ulong, 0) });
            }
        },
        else => {},
    }
}

fn style(n: *Node, f: Object) void {
    const c = n.props.col orelse tree_mod.Color{ 0, 0, 0, 1 };
    const color = apple.class("UIColor").msgSend(Object, "colorWithRed:green:blue:alpha:", .{
        @as(f64, c[0] / 255), @as(f64, c[1] / 255), @as(f64, c[2] / 255), @as(f64, c[3]),
    });
    const font = apple.class("UIFont").msgSend(Object, "systemFontOfSize:", .{@as(f64, n.props.fz orelse 16)});
    switch (n.kind) {
        .select => {
            f.msgSend(Object, "titleLabel", .{}).msgSend(void, "setFont:", .{font});
            f.msgSend(void, "setTitleColor:forState:", .{ color, @as(c_ulong, 0) });
        },
        else => {
            f.msgSend(void, "setFont:", .{font});
            f.msgSend(void, "setTextColor:", .{color});
            f.msgSend(void, "setTintColor:", .{color}); // the caret
        },
    }
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

fn fieldChanged(_: id, _: SEL, field: id) callconv(.c) void {
    const o = ownerOf(field) orelse return;
    if (o.s.updating) return;
    const text = apple.utf8((Object{ .value = field }).msgSend(Object, "text", .{})) orelse "";
    sendValue(o.s, o.n, "input", text);
}

/// Return in a one-line field: the page's Enter (which submits its form).
fn fieldShouldReturn(_: id, _: SEL, field: id) callconv(.c) BOOL {
    const o = ownerOf(field) orelse return apple.boolean(true);
    _ = o.s.engine.event(o.n.id, "key", "[\"Enter\",0]");
    return apple.boolean(false);
}

fn textViewDidChange(_: id, _: SEL, tv: id) callconv(.c) void {
    const o = ownerOf(tv) orelse return;
    // The placeholder under it comes and goes with the text.
    o.s.view.msgSend(void, "setNeedsDisplay", .{});
    if (o.s.updating) return;
    const text = apple.utf8((Object{ .value = tv }).msgSend(Object, "text", .{})) orelse "";
    sendValue(o.s, o.n, "input", text);
}

/// Return in a text area: the page's Enter first; no newline when it
/// prevented the default (a chat sends the message).
fn textViewShouldChange(_: id, _: SEL, tv: id, _: NSRange, text: id) callconv(.c) BOOL {
    const s = apple.utf8(.{ .value = text }) orelse return apple.boolean(true);
    if (!std.mem.eql(u8, s, "\n")) return apple.boolean(true);
    const o = ownerOf(tv) orelse return apple.boolean(true);
    const prevented = o.s.engine.event(o.n.id, "key", "[\"Enter\",0]");
    return apple.boolean(!prevented);
}

const NSRange = extern struct { location: c_ulong, length: c_ulong };

// ---------------------------------------------------------------------------
// The view

fn drawRect(self: id, _: SEL, _: CGRect) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const cg = UIGraphicsGetCurrentContext() orelse return;
    // A canvas's bitmap is as many pixels per point as the screen has.
    const scale: f64 = s.view.msgSend(f64, "contentScaleFactor", .{});
    draw.paint("UIFont", @ptrCast(cg), s.engine, s.transparent, .{ .ctx = s, .empty = fieldEmpty }, scale);
}

extern fn UIGraphicsGetCurrentContext() ?*anyopaque;

/// A text area's control is empty: its placeholder is drawn under it.
fn fieldEmpty(ctx: *anyopaque, n: *Node) bool {
    const s = surfaceOf(ctx);
    const f = s.fields.get(n.id) orelse return true;
    return f.control.msgSend(Object, "text", .{}).msgSend(c_ulong, "length", .{}) == 0;
}

fn layoutSubviews(self: id, _: SEL) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const b = s.view.msgSend(CGRect, "bounds", .{});
    if (b.size.width <= 0 or b.size.height <= 0) return;
    s.engine.resize(@floatCast(b.size.width), @floatCast(b.size.height), s.dark);
}

fn traitsChanged(self: id, _: SEL, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const dark = isDark(s.view);
    if (dark == s.dark) return;
    s.dark = dark;
    // Same size: force the page to hear the new color scheme.
    const w = s.engine.tree.width;
    s.engine.tree.width = -1;
    s.engine.resize(w, s.engine.tree.height, dark);
}

fn pointIn(view: Object, thing: Object) [2]f32 {
    const p = thing.msgSend(CGPoint, "locationInView:", .{view});
    return .{ @floatCast(p.x), @floatCast(p.y) };
}

fn touchesBegan(self: id, _: SEL, touches: id, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    s.fling_v = 0; // a finger down stops a fling
    const touch = (Object{ .value = touches }).msgSend(Object, "anyObject", .{});
    if (touch.value == null) return;
    const p = pointIn(s.view, touch);
    // :active while the finger is down.
    if (s.engine.tree.hit(p[0], p[1])) |n| _ = s.engine.event(n.id, "press", "null");
}

fn touchesEnded(self: id, _: SEL, _: id, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    _ = s.engine.event(0, "release", "null");
}

fn disabledUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.dis) return true;
    return false;
}

const state_began: isize = 1;
const state_changed: isize = 2;
const state_ended: isize = 3;

fn onTap(self: id, _: SEL, recognizer: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const r: Object = .{ .value = recognizer };
    if (r.msgSend(isize, "state", .{}) != state_ended) return;
    // A tap on the page takes the keyboard from a field.
    _ = s.view.msgSend(BOOL, "endEditing:", .{apple.boolean(true)});
    const p = pointIn(s.view, r);
    const n = s.engine.tree.hit(p[0], p[1]) orelse return;
    if (disabledUp(n)) return;
    _ = s.engine.event(n.id, "click", "0");
}

fn onLongPress(self: id, _: SEL, recognizer: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const r: Object = .{ .value = recognizer };
    if (r.msgSend(isize, "state", .{}) != state_began) return;
    const p = pointIn(s.view, r);
    const n = s.engine.tree.hit(p[0], p[1]) orelse return;
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0}]", .{ p[0], p[1] }) catch return;
    _ = s.engine.event(n.id, "contextmenu", json);
}

/// Scroll the sideways-scrolling container under `at` (or one around it) by `dx`.
fn scrollAtX(s: *Surface, at: [2]f32, dx: f32) bool {
    var target = s.engine.tree.scrollerX(s.engine.tree.hit(at[0], at[1]));
    while (target) |t| {
        if (s.engine.scrollByX(t, dx)) return true;
        target = s.engine.tree.scrollerX(t.parent);
    }
    return false;
}

/// Scroll the container under `at` (or one around it) by `dy`.
fn scrollAt(s: *Surface, at: [2]f32, dy: f32) bool {
    var target = s.engine.tree.scroller(s.engine.tree.hit(at[0], at[1]));
    while (target) |t| {
        if (s.engine.scrollBy(t, dy)) return true;
        target = s.engine.tree.scroller(t.parent);
    }
    return false;
}

fn onPan(self: id, _: SEL, recognizer: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const r: Object = .{ .value = recognizer };
    const st = r.msgSend(isize, "state", .{});
    if (st == state_began) s.fling_at = pointIn(s.view, r);
    if (st == state_began or st == state_changed) {
        const t = r.msgSend(CGPoint, "translationInView:", .{s.view});
        r.msgSend(void, "setTranslation:inView:", .{ CGPoint{ .x = 0, .y = 0 }, s.view });
        // The finger moves up: the content scrolls down (and sideways the same).
        if (!std.math.isFinite(t.x) or !std.math.isFinite(t.y)) return;
        if (t.y != 0) _ = scrollAt(s, s.fling_at, @floatCast(-t.y));
        if (t.x != 0) _ = scrollAtX(s, s.fling_at, @floatCast(-t.x));
        return;
    }
    if (st != state_ended) return;
    // A fling: keep going at the finger's speed, slowing down.
    const v = r.msgSend(CGPoint, "velocityInView:", .{s.view});
    s.fling_v = @floatCast(-v.y);
    if (@abs(s.fling_v) < 50) {
        s.fling_v = 0;
        return;
    }
    s.fling_gen +%= 1;
    flingStep(s);
}

const FlingData = struct { token: u64, gen: u32 };

fn flingStep(s: *Surface) void {
    const d = std.heap.smp_allocator.create(FlingData) catch return;
    d.* = .{ .token = s.token, .gen = s.fling_gen };
    apple.afterMain(16, d, onFling);
}

fn onFling(p: ?*anyopaque) callconv(.c) void {
    const d: *FlingData = @ptrCast(@alignCast(p.?));
    const token = d.token;
    const gen = d.gen;
    std.heap.smp_allocator.destroy(d);
    const s = surfaces.get(token) orelse return;
    if (gen != s.fling_gen or s.fling_v == 0) return; // stopped, or a newer fling
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    if (!scrollAt(s, s.fling_at, s.fling_v * 0.016)) {
        s.fling_v = 0;
        return;
    }
    s.fling_v *= 0.95;
    if (@abs(s.fling_v) < 20) {
        s.fling_v = 0;
        return;
    }
    flingStep(s);
}

test {
    _ = log;
}
