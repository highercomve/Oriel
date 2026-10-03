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
    /// The display link (+1) pacing the page's animation frames
    /// (request_display_frame), or nil until the page asks for one.
    display_link: Object = apple.nil,
    /// The page asked for an animation frame since the last one.
    frame_wanted: bool = false,
    /// Fonts to load while idle (warm_fonts), the commonest first.
    warm: std.ArrayListUnmanaged(engine_mod.FontSpec) = .empty,
    /// The page's pending timers and when they're due (CFAbsoluteTime):
    /// an idle warm waits while one is due soon.
    timer_dues: std.ArrayListUnmanaged(TimerDue) = .empty,
    /// The drawing view (+1), in the window's controller view.
    view: Object,
    transparent: bool,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    /// Field controls by node id.
    fields: std.AutoHashMapUnmanaged(i64, Field) = .empty,
    updating: bool = false,
    dark: bool = false,
    /// The text measures kept in the nodes (apple_draw.measureText) hold
    /// while this holds; bumped when the text may measure differently.
    text_epoch: u64 = 1,
    /// How long the last frame's render took (µs), see `requestFrame`.
    render_us: u64 = 0,
    /// A fling in progress: its speed (points per second, page direction)
    /// and the node it scrolls under.
    fling_v: f32 = 0,
    fling_at: [2]f32 = .{ 0, 0 },
    fling_gen: u32 = 0,
    /// A finger is down and the page hears it (pointer events).
    touching: bool = false,
    /// The page took the finger's drag (touch-action: none, or it
    /// prevented the pointerdown): no scrolling, fling or long press.
    drag_owned: bool = false,
    /// The pan in progress is the page's drag (drag_owned when it began;
    /// it can end after the finger's touchesEnded).
    pan_owned: bool = false,
    /// The finger's last move, sent at the next display frame.
    /// The tree's node count after the last layout, and whether a trim of
    /// its emptied pool slabs is due (trimPools, 2 s after a big drop).
    node_count: usize = 0,
    trim_queued: bool = false,
    move: ?[2]f32 = null,
};

const Field = struct {
    /// A plain view (+1) in the page's view, clipped to the part of the
    /// field the page shows (`apple_draw.visiblePart`): the control is its
    /// only subview.
    holder: Object,
    /// The UITextField, UITextView, UIButton or UISlider (held by `holder`).
    control: Object,
    /// A UISlider (<input type=range>): no text, placeholder or font.
    slider: bool = false,
};

/// Live surfaces by token, and which surface and node a view or control
/// belongs to.
var surfaces: std.AutoHashMapUnmanaged(u64, *Surface) = .empty;
var by_view: std.AutoHashMapUnmanaged(usize, *Surface) = .empty;
const Owner = struct { token: u64, node: i64 };
var by_control: std.AutoHashMapUnmanaged(usize, Owner) = .empty;
var next_token: u64 = 1;

var view_class: ?apple.Class = null;
var text_field_class: ?apple.Class = null;
var text_view_class: ?apple.Class = null;
var field_delegate: Object = apple.nil;
var gesture_delegate: Object = apple.nil;

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
        .{ "nuiDisplayFrame:", onDisplayFrame },
        .{ "drawRect:", drawRect },
        .{ "layoutSubviews", layoutSubviews },
        .{ "traitCollectionDidChange:", traitsChanged },
        .{ "touchesBegan:withEvent:", touchesBegan },
        .{ "touchesMoved:withEvent:", touchesMoved },
        .{ "touchesEnded:withEvent:", touchesEnded },
        .{ "touchesCancelled:withEvent:", touchesCancelled },
        .{ "nuiTap:", onTap },
        .{ "nuiLongPress:", onLongPress },
        .{ "nuiPan:", onPan },
        // A hardware keyboard: the page hears its keys (keydown, keyup) and
        // Tab, also from inside a field (a key command over the system's
        // own focus navigation).
        .{ "canBecomeFirstResponder", yes },
        .{ "didMoveToWindow", viewMovedToWindow },
        .{ "keyCommands", keyCommands },
        .{ "nuiTab:", onTabCommand },
        .{ "pressesBegan:withEvent:", pressesBegan },
        .{ "pressesEnded:withEvent:", pressesEnded },
        .{ "pressesCancelled:withEvent:", pressesCancelled },
    });
    // A field's hardware keys reach the page before the field acts on them.
    text_field_class = apple.defineSubclass("OrielNuiTextField", "UITextField", &.{}, .{
        .{ "pressesBegan:withEvent:", textFieldPressesBegan },
        .{ "pressesEnded:withEvent:", textFieldPressesEnded },
        .{ "pressesCancelled:withEvent:", textFieldPressesCancelled },
    });
    text_view_class = apple.defineSubclass("OrielNuiTextView", "UITextView", &.{}, .{
        .{ "pressesBegan:withEvent:", textViewPressesBegan },
        .{ "pressesEnded:withEvent:", textViewPressesEnded },
        .{ "pressesCancelled:withEvent:", textViewPressesCancelled },
    });
    field_delegate = apple.new(apple.defineClass("OrielNuiFieldDelegate", &.{ "UITextFieldDelegate", "UITextViewDelegate" }, .{
        .{ "nuiFieldChanged:", fieldChanged },
        .{ "nuiSliderMoved:", sliderMoved },
        .{ "nuiSliderDone:", sliderDone },
        .{ "textFieldShouldReturn:", fieldShouldReturn },
        .{ "textFieldDidBeginEditing:", fieldFocused },
        .{ "textFieldDidEndEditing:", fieldBlurred },
        .{ "textViewDidBeginEditing:", fieldFocused },
        .{ "textViewDidEndEditing:", fieldBlurred },
        .{ "textViewDidChange:", textViewDidChange },
        .{ "textView:shouldChangeTextInRange:replacementText:", textViewShouldChange },
    }));
    gesture_delegate = apple.new(apple.defineClass("OrielNuiGestureDelegate", &.{"UIGestureRecognizerDelegate"}, .{
        .{ "gestureRecognizer:shouldReceiveTouch:", gestureShouldReceive },
        .{ "gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:", gestureAlongside },
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
        // The page hears a finger lift (pointerup) before the tap's click.
        r.msgSend(void, "setDelaysTouchesEnded:", .{apple.boolean(false)});
        r.msgSend(void, "setDelegate:", .{gesture_delegate});
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
        .text = textChanged,
        .request_frame = requestFrame,
        .request_display_frame = if (hasDisplayLink(view)) requestDisplayFrame else null,
        .warm_fonts = warmFonts,
        .font_metrics = fontMetrics,
    }, assets, platform_json, label, url, width, height);
    // Text-only updates that keep a text's size keep the layout (its
    // natural size is kept per node: measureText).
    s.engine.tree.reuse_text_layout = true;
    s.engine.boot(s.dark, true);
    return s;
}

/// Tear a surface down (its window is closing).
pub fn destroy(s: *Surface) void {
    if (s.display_link.value != null) {
        s.display_link.msgSend(void, "invalidate", .{});
        releaseLater(s.display_link); // it may be in its own callback
    }
    _ = surfaces.remove(s.token);
    _ = by_view.remove(key(s.view.value));
    s.warm.deinit(s.gpa);
    s.timer_dues.deinit(s.gpa);
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
    switch (n.kind) {
        .text => out.* = draw.measureText("UIFont", n, max_width, surfaceOf(ctx).text_epoch),
        .image => out.* = draw.measureImage(surfaceOf(ctx).engine, n, max_width),
        // One line of the field's font (WebKit's control sizes come from
        // it); a textarea `rows` of them (2 by default).
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), draw.fieldLine("UIFont", n) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, draw.fieldLine("UIFont", n) * @max(1, n.props.rows orelse 2) },
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

// ---------------------------------------------------------------------------
// Display frames: the page's requestAnimationFrame at the display's refresh
// (a ProMotion panel's 120 Hz, an external display's 144), not a 60 Hz timer.
// The link runs only while the page asks: each frame takes the request, and
// a frame with no new one pauses the link.

extern const NSRunLoopCommonModes: id;

const CAFrameRateRange = extern struct { minimum: f32, maximum: f32, preferred: f32 };

fn hasDisplayLink(view: Object) bool {
    _ = view;
    return true; // CADisplayLink: every iOS
}

fn requestDisplayFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.frame_wanted = true;
    runDisplayLink(s);
}

/// Start (or resume) the display link: a frame the page asked for, or a
/// finger's move to send.
fn runDisplayLink(s: *Surface) void {
    if (s.display_link.value != null) {
        s.display_link.msgSend(void, "setPaused:", .{apple.boolean(false)});
        return;
    }
    const link = apple.class("CADisplayLink").msgSend(Object, "displayLinkWithTarget:selector:", .{ s.view, apple.objc.sel("nuiDisplayFrame:").value });
    if (link.value == null) return;
    s.display_link = link.retain();
    // ProMotion: up to the screen's rate (the Info.plist's
    // CADisableMinimumFrameDurationOnPhone lets an iPhone go past 60).
    const window = s.view.msgSend(Object, "window", .{});
    const screen = if (window.value != null) window.msgSend(Object, "screen", .{}) else apple.class("UIScreen").msgSend(Object, "mainScreen", .{});
    const max_fps: f32 = @floatFromInt(@max(60, if (screen.value != null) screen.msgSend(isize, "maximumFramesPerSecond", .{}) else 60));
    link.msgSend(void, "setPreferredFrameRateRange:", .{CAFrameRateRange{ .minimum = 30, .maximum = max_fps, .preferred = max_fps }});
    const loop = apple.class("NSRunLoop").msgSend(Object, "currentRunLoop", .{});
    link.msgSend(void, "addToRunLoop:forMode:", .{ loop, Object{ .value = NSRunLoopCommonModes } });
}

fn onDisplayFrame(self: id, _: SEL, link_id: id) callconv(.c) void {
    const link: Object = .{ .value = link_id };
    const s = by_view.get(key(self)) orelse return;
    // Input first, then the frame (as a browser).
    if (s.move != null) {
        const token = s.token;
        flushMove(s);
        if (surfaces.get(token) == null) return; // the page closed its window
    }
    if (!s.frame_wanted) {
        link.msgSend(void, "setPaused:", .{apple.boolean(true)});
        return;
    }
    s.frame_wanted = false;
    // The refresh interval: this frame's to the next (a variable-rate panel
    // changes it), else the link's nominal duration.
    var interval = (link.msgSend(f64, "targetTimestamp", .{}) - link.msgSend(f64, "timestamp", .{})) * 1000;
    if (!(interval > 0) or !std.math.isFinite(interval)) interval = link.msgSend(f64, "duration", .{}) * 1000;
    if (!(interval > 0) or !std.math.isFinite(interval)) interval = 0;
    const token = s.token;
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    s.engine.displayFrame(interval);
    // The page may have closed its window during the frame (destroy
    // invalidated the link); else the link runs on only if it asked again.
    const still = surfaces.get(token) orelse return;
    if (!still.frame_wanted) link.msgSend(void, "setPaused:", .{apple.boolean(true)});
}

/// Backend.warm_fonts: fonts load when the main run loop is idle (about to
/// sleep: kCFRunLoopBeforeWaiting), one per idle moment, and not while a
/// timer is due within `warm_margin` or the page wants an animation frame:
/// a cold font takes a few ms, which shouldn't make a due timer late.
/// Backend.font_metrics: the text font's ascent and descent at a size.
fn fontMetrics(_: *anyopaque, size: f32, mono: bool, out: *[3]f32) bool {
    return draw.fontMetrics("UIFont", size, mono, out);
}

fn warmFonts(ctx: *anyopaque, specs: []const engine_mod.FontSpec) void {
    const s = surfaceOf(ctx);
    s.warm.appendSlice(s.gpa, specs) catch return;
    startWarmObserver();
}

const TimerDue = struct { id: u32, due: f64 };
const warm_margin: f64 = 0.010; // s

extern fn CFAbsoluteTimeGetCurrent() f64;
extern fn CFRunLoopGetMain() ?*anyopaque;
extern fn CFRunLoopWakeUp(rl: ?*anyopaque) void;
extern fn CFRunLoopObserverCreate(alloc: ?*anyopaque, activities: c_ulong, repeats: u8, order: c_long, callout: *const fn (?*anyopaque, c_ulong, ?*anyopaque) callconv(.c) void, context: ?*anyopaque) ?*anyopaque;
extern fn CFRunLoopAddObserver(rl: ?*anyopaque, observer: ?*anyopaque, mode: ?*anyopaque) void;
extern fn CFRunLoopRemoveObserver(rl: ?*anyopaque, observer: ?*anyopaque, mode: ?*anyopaque) void;
extern fn CFRunLoopObserverInvalidate(observer: ?*anyopaque) void;
extern fn CFRelease(cf: ?*anyopaque) void;
extern const kCFRunLoopCommonModes: ?*anyopaque;
const kCFRunLoopBeforeWaiting: c_ulong = 1 << 5;

var warm_observer: ?*anyopaque = null;

fn startWarmObserver() void {
    if (warm_observer != null) return;
    warm_observer = CFRunLoopObserverCreate(null, kCFRunLoopBeforeWaiting, 1, 0, onIdle, null) orelse return;
    CFRunLoopAddObserver(CFRunLoopGetMain(), warm_observer, kCFRunLoopCommonModes);
    CFRunLoopWakeUp(CFRunLoopGetMain()); // an idle moment soon, even with nothing else to do
}

fn stopWarmObserver() void {
    const o = warm_observer orelse return;
    warm_observer = null;
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, kCFRunLoopCommonModes);
    CFRunLoopObserverInvalidate(o);
    CFRelease(o);
}

/// The run loop is about to sleep: warm one font, unless a page is busy
/// (a frame wanted or pending, a timer due soon); wake the loop again while
/// fonts are left, so the next idle moment comes.
fn onIdle(_: ?*anyopaque, _: c_ulong, _: ?*anyopaque) callconv(.c) void {
    const now = CFAbsoluteTimeGetCurrent();
    var left = false;
    var busy = false;
    var it = surfaces.valueIterator();
    while (it.next()) |sp| {
        const s = sp.*;
        if (s.warm.items.len > 0) left = true;
        if (s.frame_wanted or s.engine.frame_pending) busy = true;
        for (s.timer_dues.items) |t| if (t.due - now < warm_margin) {
            busy = true;
        };
    }
    if (!left) return stopWarmObserver();
    if (busy) return; // the timer or frame wakes the loop; a later idle moment warms
    it = surfaces.valueIterator();
    while (it.next()) |sp| {
        const s = sp.*;
        if (s.warm.items.len == 0) continue;
        const spec = s.warm.orderedRemove(0);
        const pool = apple.objc.AutoreleasePool.init();
        defer pool.deinit();
        draw.warmFont("UIFont", spec);
        break;
    }
    CFRunLoopWakeUp(CFRunLoopGetMain());
}

const TimerData = struct { token: u64, id: u32 };

fn addTimer(ctx: *anyopaque, _: *Engine, timer_id: u32, ms: u32) void {
    const s = surfaceOf(ctx);
    const d = std.heap.smp_allocator.create(TimerData) catch return;
    d.* = .{ .token = s.token, .id = timer_id };
    s.timer_dues.append(s.gpa, .{ .id = timer_id, .due = CFAbsoluteTimeGetCurrent() + @as(f64, @floatFromInt(ms)) / 1000 }) catch {};
    apple.afterMain(ms, d, onTimer);
}

fn onTimer(p: ?*anyopaque) callconv(.c) void {
    const d: *TimerData = @ptrCast(@alignCast(p.?));
    const token = d.token;
    const timer_id = d.id;
    std.heap.smp_allocator.destroy(d);
    const s = surfaces.get(token) orelse return; // the window is gone
    for (s.timer_dues.items, 0..) |t, i| if (t.id == timer_id) {
        _ = s.timer_dues.swapRemove(i);
        break;
    };
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    s.engine.timerFired(timer_id);
}

fn focus(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    // Not a native field (a button the page's Tab reached): a field that
    // had the keyboard gives it up.
    const f = s.fields.get(n.id) orelse {
        if (focusedField(s) != 0) {
            _ = s.view.msgSend(BOOL, "endEditing:", .{apple.boolean(true)});
            _ = s.view.msgSend(BOOL, "becomeFirstResponder", .{});
        }
        return;
    };
    // A control that can't take the keyboard (a select's button): the
    // field that had it gives it up.
    if (!apple.isTrue(f.control.msgSend(BOOL, "becomeFirstResponder", .{})) and focusedField(s) != 0) {
        _ = s.view.msgSend(BOOL, "endEditing:", .{apple.boolean(true)});
        _ = s.view.msgSend(BOOL, "becomeFirstResponder", .{});
    }
}

fn removed(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    draw.dropNative(n);
    if (s.fields.fetchRemove(n.id)) |kv| dropField(kv.value);
}

/// New props: a text node's CoreText objects are stale.
fn propsChanged(_: *anyopaque, n: *Node, _: std.json.Value) void {
    draw.dropText(n);
    draw.imagePropsChanged(n);
    n.measured_text_size = null;
}

fn textChanged(_: *anyopaque, n: *Node) void {
    draw.dropText(n);
    n.measured_text_size = null;
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    queueTrim(s);
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
        if (field.slider) {
            styleSlider(n, f);
            if (n.pending_value) |v| f.msgSend(void, "setValue:", .{@as(f32, @floatCast(draw.Range.of(n).parse(v)))});
            n.pending_value = null;
        } else {
            if (n.pending_value) |v| {
                n.pending_value = null;
                setValue(n, f, v);
            }
            style(n, f);
        }
        // The page changes placeholders; a text area's is drawn under it.
        if (n.kind == .input and !field.slider) if (apple.nsString(n.props.ph orelse "")) |ph| {
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
const UIControlEventValueChanged: c_ulong = 1 << 12;
const UIControlEventTouchUp: c_ulong = (1 << 6) | (1 << 7) | (1 << 8); // inside, outside, cancel

fn makeField(s: *Surface, n: *Node) ?Field {
    const zero: CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 10, .height = 10 } };
    var slider = false;
    const f: Object = switch (n.kind) {
        .input => if (n.props.range != null) blk: {
            const sl = apple.class("UISlider").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (sl.value == null) return null;
            sl.msgSend(void, "setContinuous:", .{apple.boolean(true)});
            sl.msgSend(void, "addTarget:action:forControlEvents:", .{ field_delegate, apple.objc.sel("nuiSliderMoved:").value, UIControlEventValueChanged });
            sl.msgSend(void, "addTarget:action:forControlEvents:", .{ field_delegate, apple.objc.sel("nuiSliderDone:").value, UIControlEventTouchUp });
            slider = true;
            styleSlider(n, sl);
            sl.msgSend(void, "setValue:", .{@as(f32, @floatCast(draw.Range.of(n).min))});
            break :blk sl;
        } else blk: {
            const tf = (Object{ .value = @ptrCast(text_field_class.?.value) }).msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
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
            const tv = (Object{ .value = @ptrCast(text_view_class.?.value) }).msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
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
    return .{ .holder = holder, .control = f, .slider = slider };
}

/// The page's min/max (they may change) and accent-color on a UISlider.
fn styleSlider(n: *Node, sl: Object) void {
    const r = draw.Range.of(n);
    sl.msgSend(void, "setMinimumValue:", .{@as(f32, @floatCast(r.min))});
    sl.msgSend(void, "setMaximumValue:", .{@as(f32, @floatCast(r.max))});
    if (n.props.acc) |a| sl.msgSend(void, "setMinimumTrackTintColor:", .{apple.class("UIColor").msgSend(Object, "colorWithRed:green:blue:alpha:", .{
        @as(f64, a[0] / 255), @as(f64, a[1] / 255), @as(f64, a[2] / 255), @as(f64, a[3]),
    })});
}

/// A slider's value on its step, as the page's text.
fn sliderText(n: *Node, sl: Object, buf: []u8) []const u8 {
    const r = draw.Range.of(n);
    const v = r.snap(@floatCast(sl.msgSend(f32, "value", .{})));
    sl.msgSend(void, "setValue:", .{@as(f32, @floatCast(v))});
    return r.text(buf, v);
}

/// Dragging a slider: `input`; letting go: `change` (as Android's SeekBar).
fn sliderMoved(_: id, _: SEL, sender: id) callconv(.c) void {
    const o = ownerOf(sender) orelse return;
    if (o.s.updating) return;
    var buf: [48]u8 = undefined;
    sendValue(o.s, o.n, "input", sliderText(o.n, .{ .value = sender }, &buf));
}

fn sliderDone(_: id, _: SEL, sender: id) callconv(.c) void {
    const o = ownerOf(sender) orelse return;
    if (o.s.updating) return;
    var buf: [48]u8 = undefined;
    sendValue(o.s, o.n, "change", sliderText(o.n, .{ .value = sender }, &buf));
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

// ---------------------------------------------------------------------------
// A hardware keyboard. The page view takes the keyboard when it's on screen
// and whenever a field gives it up, so keys that no field takes reach it
// (pressesBegan). Tab is a key command with priority over the system's
// focus navigation: the page gets it from a field too, and moves the focus
// itself.

fn yes(_: id, _: SEL) callconv(.c) BOOL {
    return apple.boolean(true);
}

fn viewMovedToWindow(self: id, _: SEL) callconv(.c) void {
    const v: Object = .{ .value = self };
    if (v.msgSend(Object, "window", .{}).value == null) return;
    // Not from a field the user is typing in (the keyboard would go away).
    if (by_view.get(key(self))) |s| if (focusedField(s) != 0) return;
    _ = v.msgSend(BOOL, "becomeFirstResponder", .{});
}

const key_shift: isize = 1 << 17;
var key_commands: Object = apple.nil;

fn keyCommands(_: id, _: SEL) callconv(.c) id {
    if (key_commands.value == null) {
        const tab = apple.nsString("\t") orelse return null;
        defer tab.release();
        var cmds: [2]id = undefined;
        for ([_]isize{ 0, key_shift }, 0..) |mods, i| {
            const c = apple.class("UIKeyCommand").msgSend(Object, "keyCommandWithInput:modifierFlags:action:", .{ tab, mods, apple.objc.sel("nuiTab:").value });
            if (c.value == null) return null;
            // iOS 15: before the system's own Tab (focus between fields).
            if (apple.isTrue(c.msgSend(BOOL, "respondsToSelector:", .{apple.objc.sel("setWantsPriorityOverSystemBehavior:").value})))
                c.msgSend(void, "setWantsPriorityOverSystemBehavior:", .{apple.boolean(true)});
            cmds[i] = c.value;
        }
        key_commands = apple.class("NSArray").msgSend(Object, "arrayWithObjects:count:", .{ @as([*]const id, &cmds), @as(usize, 2) }).retain();
    }
    return key_commands.value;
}

/// The field with the keyboard, if any (its node id), else 0.
fn focusedField(s: *Surface) i64 {
    var it = s.fields.iterator();
    while (it.next()) |e| {
        if (apple.isTrue(e.value_ptr.control.msgSend(BOOL, "isFirstResponder", .{}))) return e.key_ptr.*;
    }
    return 0;
}

fn onTabCommand(self: id, _: SEL, command: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const shift = (Object{ .value = command }).msgSend(isize, "modifierFlags", .{}) & key_shift != 0;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"Tab\",{d},false]", .{@as(u32, if (shift) 1 else 0)}) catch return;
    _ = s.engine.event(focusedField(s), "key", json);
}

/// A key's name for the page (DOM KeyboardEvent.key), from its HID usage
/// or its characters.
fn pressKeyName(k: Object, buf: []u8) ?[]const u8 {
    const code = k.msgSend(isize, "keyCode", .{});
    const named: ?[]const u8 = switch (code) {
        0x28, 0x58 => "Enter",
        0x29 => "Escape",
        0x2A => "Backspace",
        0x2B => "Tab",
        0x2C => " ",
        0x4C => "Delete",
        0x4F => "ArrowRight",
        0x50 => "ArrowLeft",
        0x51 => "ArrowDown",
        0x52 => "ArrowUp",
        0x4A => "Home",
        0x4D => "End",
        0x4B => "PageUp",
        0x4E => "PageDown",
        0xE0, 0xE4 => "Control",
        0xE1, 0xE5 => "Shift",
        0xE2, 0xE6 => "Alt",
        0xE3, 0xE7 => "Meta",
        else => null,
    };
    if (named) |n| return n;
    const chars = apple.utf8(k.msgSend(Object, "charactersIgnoringModifiers", .{})) orelse return null;
    if (chars.len == 0 or chars.len > 4 or chars.len > buf.len) return null;
    @memcpy(buf[0..chars.len], chars);
    return buf[0..chars.len];
}

/// UIKeyModifierFlags to the page's (shift 1, control 2, alt 4, meta 8).
fn pressMods(k: Object) u32 {
    const f = k.msgSend(isize, "modifierFlags", .{});
    var m: u32 = 0;
    if (f & (1 << 17) != 0) m |= 1;
    if (f & (1 << 18) != 0) m |= 2;
    if (f & (1 << 19) != 0) m |= 4;
    if (f & (1 << 20) != 0) m |= 8;
    return m;
}

/// A modifier key's own flag (shift 1, control 2, alt 4, meta 8), else 0:
/// set on its key down, clear on its key up, as browsers report them.
fn modifierBit(k: Object) u32 {
    return switch (k.msgSend(isize, "keyCode", .{})) {
        0xE1, 0xE5 => 1,
        0xE0, 0xE4 => 2,
        0xE2, 0xE6 => 4,
        0xE3, 0xE7 => 8,
        else => 0,
    };
}

/// A press's mods for its "key" or "keyup".
fn pressModsFor(k: Object, kind: []const u8) u32 {
    const bit = modifierBit(k);
    const m = pressMods(k);
    return if (bit == 0) m else if (std.mem.eql(u8, kind, "key")) m | bit else m & ~bit;
}

/// An Enter key down the presses gave the page, let through: the field's
/// own Return (fieldShouldReturn, a text area's newline) doesn't send it again.
var press_enter_sent = false;

/// A field's presses for the page ("key" or "keyup", on its node), before
/// the field has them: true when the page prevented every one (the field
/// doesn't get them). Not Tab (it goes up to the page's view, fieldTab),
/// nothing while an input method composes (the field's alone), and no key
/// up for a key let go while Command is down (WebKit fires none).
fn fieldPresses(self: id, presses: id, kind: []const u8) bool {
    const o = ownerOf(self) orelse return false;
    const field: Object = .{ .value = self };
    if (field.msgSend(Object, "markedTextRange", .{}).value != null) return false;
    const s = o.s;
    const nid = o.n.id;
    const token = s.token;
    const gpa = s.gpa; // not read from the surface after an event
    const all = (Object{ .value = presses }).msgSend(Object, "allObjects", .{});
    const count: usize = @intCast(@max(0, all.msgSend(isize, "count", .{})));
    const down = std.mem.eql(u8, kind, "key");
    var prevented = count > 0;
    for (0..count) |i| {
        const k = all.msgSend(Object, "objectAtIndex:", .{i}).msgSend(Object, "key", .{});
        if (k.value == null or k.msgSend(isize, "keyCode", .{}) == 0x2B) {
            prevented = false;
            continue;
        }
        var nbuf: [8]u8 = undefined;
        const name = pressKeyName(k, &nbuf) orelse {
            prevented = false;
            continue;
        };
        const mods = pressModsFor(k, kind);
        if (!down and mods & 8 != 0 and modifierBit(k) == 0) {
            prevented = false;
            continue;
        }
        const q = std.json.Stringify.valueAlloc(gpa, name, .{}) catch return false;
        defer gpa.free(q);
        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "[{s},{d},false]", .{ q, mods }) catch continue;
        if (!down) {
            laterKeyUp(token, nid, json);
            continue;
        }
        const used = (surfaces.get(token) orelse return true).engine.event(nid, kind, json);
        if (surfaces.get(token) == null) return true; // the page closed its window
        if (!used) {
            prevented = false;
            if (down and std.mem.eql(u8, name, "Enter")) press_enter_sent = true;
        }
    }
    return prevented;
}

const ObjcSuper = extern struct { receiver: id, super_class: ?*anyopaque };
extern fn objc_msgSendSuper() void;

/// UIKit's own pressesBegan: (or Ended, Cancelled) for a field subclass.
fn superPresses(self: id, comptime superclass: [:0]const u8, comptime selector: [:0]const u8, presses: id, event: id) void {
    const sup: ObjcSuper = .{ .receiver = self, .super_class = @ptrCast(apple.class(superclass).value) };
    const f: *const fn (*const ObjcSuper, SEL, id, id) callconv(.c) void = @ptrCast(&objc_msgSendSuper);
    f(&sup, apple.objc.sel(selector).value, presses, event);
}

/// A field's key up, a turn after UIKit's own pressesEnded: UIKit types
/// the character a little after the press, and the page hears keyup after
/// the input (as in WebKit).
const LaterKeyUp = struct { token: u64, nid: i64, len: usize, json: [64]u8 };

fn laterKeyUp(token: u64, nid: i64, json: []const u8) void {
    const k = std.heap.smp_allocator.create(LaterKeyUp) catch return;
    k.* = .{ .token = token, .nid = nid, .len = json.len, .json = undefined };
    @memcpy(k.json[0..json.len], json);
    apple.asyncMain(k, onLaterKeyUp);
}

fn onLaterKeyUp(p: ?*anyopaque) callconv(.c) void {
    const k: *LaterKeyUp = @ptrCast(@alignCast(p.?));
    defer std.heap.smp_allocator.destroy(k);
    const s = surfaces.get(k.token) orelse return; // the window is gone
    if (s.engine.tree.get(k.nid) == null) return; // the field is gone
    _ = s.engine.event(k.nid, "keyup", k.json[0..k.len]);
}

fn textFieldPressesBegan(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    if (!fieldPresses(self, presses, "key")) superPresses(self, "UITextField", "pressesBegan:withEvent:", presses, event);
}

fn textFieldPressesEnded(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    superPresses(self, "UITextField", "pressesEnded:withEvent:", presses, event);
    _ = fieldPresses(self, presses, "keyup");
    press_enter_sent = false;
}

fn textFieldPressesCancelled(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    superPresses(self, "UITextField", "pressesCancelled:withEvent:", presses, event);
    _ = fieldPresses(self, presses, "keyup");
    press_enter_sent = false;
}

fn textViewPressesBegan(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    if (!fieldPresses(self, presses, "key")) superPresses(self, "UITextView", "pressesBegan:withEvent:", presses, event);
}

fn textViewPressesEnded(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    superPresses(self, "UITextView", "pressesEnded:withEvent:", presses, event);
    _ = fieldPresses(self, presses, "keyup");
    press_enter_sent = false;
}

fn textViewPressesCancelled(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    superPresses(self, "UITextView", "pressesCancelled:withEvent:", presses, event);
    _ = fieldPresses(self, presses, "keyup");
    press_enter_sent = false;
}

fn hasTab(presses: id) bool {
    const all = (Object{ .value = presses }).msgSend(Object, "allObjects", .{});
    const count: usize = @intCast(@max(0, all.msgSend(isize, "count", .{})));
    for (0..count) |i| {
        const k = all.msgSend(Object, "objectAtIndex:", .{i}).msgSend(Object, "key", .{});
        if (k.value != null and k.msgSend(isize, "keyCode", .{}) == 0x2B) return true;
    }
    return false;
}

/// A Tab press that came up from a field: the page's "key"/"keyup", on
/// the field.
fn fieldTab(self: id, presses: id, kind: []const u8) void {
    const s = by_view.get(key(self)) orelse return;
    const all = (Object{ .value = presses }).msgSend(Object, "allObjects", .{});
    const count: usize = @intCast(@max(0, all.msgSend(isize, "count", .{})));
    for (0..count) |i| {
        const k = all.msgSend(Object, "objectAtIndex:", .{i}).msgSend(Object, "key", .{});
        if (k.value == null or k.msgSend(isize, "keyCode", .{}) != 0x2B) continue;
        var buf: [32]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "[\"Tab\",{d},false]", .{pressMods(k)}) catch return;
        _ = s.engine.event(focusedField(s), kind, json);
        return; // one Tab (the surface may be gone after the event)
    }
}

/// The presses' keys to the page ("key" or "keyup"): true when it prevented
/// every one's default (else UIKit gets them too).
fn sendPresses(self: id, presses: id, kind: []const u8) bool {
    const s = by_view.get(key(self)) orelse return false;
    // Only the page view's own keys: a field's come up the responder chain
    // too, and the field already tells the page (Enter, its typing).
    if (!apple.isTrue((Object{ .value = self }).msgSend(BOOL, "isFirstResponder", .{}))) return false;
    const token = s.token;
    const gpa = s.gpa; // not read from the surface after an event
    const all = (Object{ .value = presses }).msgSend(Object, "allObjects", .{});
    const count: usize = @intCast(@max(0, all.msgSend(isize, "count", .{})));
    var prevented = count > 0;
    for (0..count) |i| {
        const k = all.msgSend(Object, "objectAtIndex:", .{i}).msgSend(Object, "key", .{});
        if (k.value == null) {
            prevented = false;
            continue;
        }
        var nbuf: [8]u8 = undefined;
        const name = pressKeyName(k, &nbuf) orelse {
            prevented = false;
            continue;
        };
        const q = std.json.Stringify.valueAlloc(gpa, name, .{}) catch return false;
        defer gpa.free(q);
        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "[{s},{d},false]", .{ q, pressModsFor(k, kind) }) catch continue;
        if (!s.engine.event(0, kind, json)) prevented = false;
        if (surfaces.get(token) == null) return true; // the page closed its window
    }
    return prevented;
}

fn pressesBegan(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    // A field's keys passing up the chain (the field told the page, see
    // fieldPresses): on to UIKit's text input, through UIView's own (not
    // nextResponder's), but Tab is the page's (its focus navigation;
    // UIKit's key command doesn't fire from a field).
    if (!apple.isTrue((Object{ .value = self }).msgSend(BOOL, "isFirstResponder", .{}))) {
        if (!hasTab(presses)) return superPresses(self, "UIView", "pressesBegan:withEvent:", presses, event);
        return fieldTab(self, presses, "key");
    }
    // Not all the page's: on up the responder chain (UIView's own does that).
    if (!sendPresses(self, presses, "key")) {
        const next = (Object{ .value = self }).msgSend(Object, "nextResponder", .{});
        if (next.value != null) next.msgSend(void, "pressesBegan:withEvent:", .{ presses, event });
    }
}

fn pressesCancelled(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    // A field's keys passing up the chain: on, through UIView's own.
    if (!apple.isTrue((Object{ .value = self }).msgSend(BOOL, "isFirstResponder", .{}))) {
        if (!hasTab(presses)) superPresses(self, "UIView", "pressesCancelled:withEvent:", presses, event);
        return;
    }
    // Not all the page's: on up the responder chain (UIView's own does that).
    if (!sendPresses(self, presses, "keyup")) {
        const next = (Object{ .value = self }).msgSend(Object, "nextResponder", .{});
        if (next.value != null) next.msgSend(void, "pressesCancelled:withEvent:", .{ presses, event });
    }
}

fn pressesEnded(self: id, _: SEL, presses: id, event: id) callconv(.c) void {
    if (!apple.isTrue((Object{ .value = self }).msgSend(BOOL, "isFirstResponder", .{}))) {
        if (!hasTab(presses)) return superPresses(self, "UIView", "pressesEnded:withEvent:", presses, event);
        return fieldTab(self, presses, "keyup");
    }
    // Not all the page's: on up the responder chain (UIView's own does that).
    if (!sendPresses(self, presses, "keyup")) {
        const next = (Object{ .value = self }).msgSend(Object, "nextResponder", .{});
        if (next.value != null) next.msgSend(void, "pressesEnded:withEvent:", .{ presses, event });
    }
}

/// A field took the keyboard (UIKit's editing is its focus) or gave it up:
/// the page's "focus" and "blur" (:focus, :focus-visible, activeElement).
fn fieldFocused(_: id, _: SEL, control: id) callconv(.c) void {
    const o = ownerOf(control) orelse return;
    _ = o.s.engine.event(o.n.id, "focus", "null");
}

fn fieldBlurred(_: id, _: SEL, control: id) callconv(.c) void {
    const o = ownerOf(control) orelse return;
    _ = o.s.engine.event(o.n.id, "blur", "null");
}

fn ownerOf(control: id) ?struct { s: *Surface, n: *Node } {
    const o = by_control.get(key(control)) orelse return null;
    const s = surfaces.get(o.token) orelse return null;
    const n = s.engine.tree.get(o.node) orelse return null;
    return .{ .s = s, .n = n };
}

/// Nothing of the surface is read after the event: a window's close is
/// queued today, but a handler that ended the surface would free it.
fn sendValue(s: *Surface, n: *Node, kind: []const u8, text: []const u8) void {
    const gpa = s.gpa;
    const json = std.json.Stringify.valueAlloc(gpa, text, .{}) catch return;
    defer gpa.free(json);
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
    // A hardware Enter the page already heard (fieldPresses).
    if (press_enter_sent) {
        press_enter_sent = false;
        return apple.boolean(false);
    }
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
    // A hardware Enter the page already heard and let through (fieldPresses).
    if (press_enter_sent) {
        press_enter_sent = false;
        return apple.boolean(true);
    }
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
    s.text_epoch +%= 1;
    if (s.text_epoch == 0) s.text_epoch = 1;
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
    const token = s.token;
    // :active while the finger is down.
    if (s.engine.tree.hit(p[0], p[1])) |n| _ = s.engine.event(n.id, "press", "null");
    if (surfaces.get(token) == null) return;
    s.move = null;
    s.touching = true;
    s.drag_owned = sendPointer(s, "down", p, 1);
}

fn touchesMoved(self: id, _: SEL, touches: id, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    if (!s.touching) return;
    const touch = (Object{ .value = touches }).msgSend(Object, "anyObject", .{});
    if (touch.value == null) return;
    s.move = pointIn(s.view, touch);
    runDisplayLink(s);
}

fn touchesEnded(self: id, _: SEL, touches: id, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const token = s.token;
    s.drag_owned = false;
    if (s.touching) {
        if (s.move != null) flushMove(s);
        if (surfaces.get(token) == null) return;
        s.touching = false;
        const touch = (Object{ .value = touches }).msgSend(Object, "anyObject", .{});
        if (touch.value != null) _ = sendPointer(s, "up", pointIn(s.view, touch), 0);
        if (surfaces.get(token) == null) return;
    }
    _ = s.engine.event(0, "release", "null");
}

fn touchesCancelled(self: id, _: SEL, touches: id, _: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const token = s.token;
    s.drag_owned = false;
    if (s.touching) {
        s.touching = false;
        s.move = null;
        const touch = (Object{ .value = touches }).msgSend(Object, "anyObject", .{});
        const p = if (touch.value != null) pointIn(s.view, touch) else [2]f32{ 0, 0 };
        _ = sendPointer(s, "cancel", p, 0);
        if (surfaces.get(token) == null) return;
    }
    _ = s.engine.event(0, "release", "null");
}

/// A pointer event for the page (main.js pointerEvent): `phase` down, move,
/// up or cancel at `p` (the view's points: CSS px), on the node there. True
/// when the page prevented the default (on "down": it takes the drag).
fn sendPointer(s: *Surface, phase: []const u8, p: [2]f32, buttons: u32) bool {
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return false;
    const nid: i64 = if (s.engine.tree.hit(p[0], p[1])) |n| n.id else 0;
    var buf: [96]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d:.2},{d:.2},{d},1,\"touch\",0]", .{ phase, p[0], p[1], buttons }) catch return false;
    return s.engine.event(nid, "pointer", json);
}

/// A layout that dropped many nodes (a list that went): the tree's emptied
/// pool slabs go back 2 s later, if the window is still there (a list
/// rebuilt at once reuses them first).
fn queueTrim(s: *Surface) void {
    const count = s.engine.tree.nodes.count();
    defer s.node_count = count;
    if (s.node_count <= count + 1000 or s.trim_queued) return;
    const t = std.heap.smp_allocator.create(u64) catch return;
    t.* = s.token;
    s.trim_queued = true;
    apple.afterMain(2000, t, onTrim);
}

fn onTrim(p: ?*anyopaque) callconv(.c) void {
    const t: *u64 = @ptrCast(@alignCast(p.?));
    const token = t.*;
    std.heap.smp_allocator.destroy(t);
    const s = surfaces.get(token) orelse return; // the window is gone
    s.trim_queued = false;
    const freed = s.engine.tree.trimPools();
    if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("native ui: trim freed {d} pool slabs", .{freed});
}

fn flushMove(s: *Surface) void {
    const p = s.move orelse return;
    s.move = null;
    if (s.touching) _ = sendPointer(s, "move", p, 1);
}

/// A tap or long press in a native field is the field's (the page's would
/// take its focus away); a drag from one still scrolls the page, except
/// on a slider, which the drag moves.
fn gestureShouldReceive(_: id, _: SEL, recognizer: id, touch: id) callconv(.c) BOOL {
    const r: Object = .{ .value = recognizer };
    const pan = apple.isTrue(r.msgSend(BOOL, "isKindOfClass:", .{apple.class("UIPanGestureRecognizer").value}));
    const page = r.msgSend(Object, "view", .{});
    var v = (Object{ .value = touch }).msgSend(Object, "view", .{});
    while (v.value != null and v.value != page.value) : (v = v.msgSend(Object, "superview", .{})) {
        if (apple.isTrue(v.msgSend(BOOL, "isKindOfClass:", .{apple.class("UISlider").value}))) return apple.boolean(false);
        if (!pan and (apple.isTrue(v.msgSend(BOOL, "isKindOfClass:", .{apple.class("UITextField").value})) or
            apple.isTrue(v.msgSend(BOOL, "isKindOfClass:", .{apple.class("UITextView").value})))) return apple.boolean(false);
    }
    return apple.boolean(true);
}

/// A field's own recognizers (double tap to select, …) run beside the page's
/// (the system's and the page's own keep UIKit's rules):
/// a tap on the page right after one in a field is the page's.
fn gestureAlongside(_: id, _: SEL, recognizer: id, other: id) callconv(.c) BOOL {
    const mine = (Object{ .value = recognizer }).msgSend(Object, "view", .{});
    const theirs = (Object{ .value = other }).msgSend(Object, "view", .{});
    if (theirs.value == null or theirs.value == mine.value) return apple.boolean(false);
    return theirs.msgSend(BOOL, "isDescendantOfView:", .{mine});
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
    _ = s.view.msgSend(BOOL, "becomeFirstResponder", .{});
    const p = pointIn(s.view, r);
    // The finger's up before its click (as a browser), though the tap
    // recognizer fires before touchesEnded.
    if (s.touching) {
        const token = s.token;
        if (s.move != null) flushMove(s);
        if (surfaces.get(token) == null) return;
        s.touching = false;
        _ = sendPointer(s, "up", p, 0);
        if (surfaces.get(token) == null) return;
    }
    // Hit-tested after the up: its handler may have changed the page.
    const hit = s.engine.tree.hit(p[0], p[1]);
    if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("native ui: tap at {d:.0},{d:.0} on node {d}", .{ p[0], p[1], if (hit) |h| h.id else 0 });
    const n = hit orelse return;
    if (disabledUp(n)) return;
    _ = s.engine.event(n.id, "click", "0");
}

fn onLongPress(self: id, _: SEL, recognizer: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const r: Object = .{ .value = recognizer };
    if (r.msgSend(isize, "state", .{}) != state_began) return;
    if (s.drag_owned) return; // the page's drag (a finger held still on a game)
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
    // The page's drag: it gets the finger's moves, nothing scrolls.
    if (st == state_began) s.pan_owned = s.drag_owned;
    if (s.pan_owned) return;
    if (st == state_began and s.touching) {
        // The page scrolls: the page's pointer is cancelled, as in a browser.
        const token = s.token;
        s.touching = false;
        s.move = null;
        _ = sendPointer(s, "cancel", pointIn(s.view, r), 0);
        if (surfaces.get(token) == null) return;
    }
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
