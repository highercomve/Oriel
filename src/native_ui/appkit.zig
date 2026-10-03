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
    /// The display link (+1) pacing the page's animation frames
    /// (request_display_frame), or nil until the page asks for one.
    display_link: Object = cocoa.nil,
    /// The page asked for an animation frame since the last one.
    frame_wanted: bool = false,
    /// Fonts to load while idle (warm_fonts), the commonest first.
    warm: std.ArrayListUnmanaged(engine_mod.FontSpec) = .empty,
    /// The page's pending timers and when they're due (CFAbsoluteTime):
    /// an idle warm waits while one is due soon.
    timer_dues: std.ArrayListUnmanaged(TimerDue) = .empty,
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
    /// The text measures kept in the nodes (apple_draw.measureText) hold
    /// while this holds; bumped when the text may measure differently.
    text_epoch: u64 = 1,
    pointer_hand: bool = false,
    /// The field node that has the keyboard (0: none), as the page last
    /// heard it ("focus"/"blur"), and whether a check is queued.
    focused: i64 = 0,
    focus_check_queued: bool = false,
    /// The mouse's last move, sent to the page at the next display frame
    /// (one a frame, however fast the mouse reports).
    /// The tree's node count after the last layout, and whether a trim of
    /// its emptied pool slabs is due (trimPools, 2 s after a big drop).
    node_count: usize = 0,
    trim_queued: bool = false,
    /// Scroll indicators showing (flash): redrawn each frame until then.
    flash_queued: bool = false,
    flash_until: i64 = 0,
    move: ?PendingMove = null,
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
    /// An NSSlider (<input type=range>): no text, placeholder or font.
    slider: bool = false,
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
    installKeyUpMonitor();
    view_class = cocoa.defineSubclass("OrielNuiView", "NSView", &.{}, .{
        .{ "nuiDisplayFrame:", onDisplayFrame },
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
        .{ "mouseDragged:", mouseDragged },
        .{ "mouseExited:", mouseExited },
        .{ "scrollWheel:", scrollWheel },
        .{ "keyDown:", keyDown },
        .{ "viewDidChangeEffectiveAppearance", appearanceChanged },
        .{ "viewDidChangeBackingProperties", backingChanged },
    });
    // A field's holder: flipped like the page, so frames read top-down.
    holder_class = cocoa.defineSubclass("OrielNuiFlippedView", "NSView", &.{}, .{
        .{ "isFlipped", yes },
    });
    // The fields: their class's own, telling the page when they take the
    // keyboard (a click into a text field calls no delegate).
    text_field_class = cocoa.defineSubclass("OrielNuiTextField", "NSTextField", &.{}, .{
        .{ "becomeFirstResponder", textFieldBecomeFirst },
    });
    secure_field_class = cocoa.defineSubclass("OrielNuiSecureTextField", "NSSecureTextField", &.{}, .{
        .{ "becomeFirstResponder", secureFieldBecomeFirst },
    });
    text_view_class = cocoa.defineSubclass("OrielNuiTextView", "NSTextView", &.{}, .{
        .{ "becomeFirstResponder", textViewBecomeFirst },
        .{ "resignFirstResponder", textViewResignFirst },
    });
    field_delegate = cocoa.new(cocoa.defineClass("OrielNuiFieldDelegate", &.{ "NSTextFieldDelegate", "NSTextViewDelegate" }, .{
        .{ "controlTextDidChange:", controlTextDidChange },
        .{ "controlTextDidBeginEditing:", fieldEditingChanged },
        .{ "controlTextDidEndEditing:", fieldEditingChanged },
        .{ "textDidBeginEditing:", fieldEditingChanged },
        .{ "textDidEndEditing:", fieldEditingChanged },
        .{ "control:textView:doCommandBySelector:", controlCommand },
        .{ "textDidChange:", textDidChange },
        .{ "textView:doCommandBySelector:", textViewCommand },
        .{ "popupChanged:", popupChanged },
        .{ "sliderChanged:", sliderChanged },
    }));
}

/// The platform JSON with what's read as the window opens:
/// `fullKeyboardAccess`, whether macOS's keyboard navigation setting lets
/// Tab reach every control (WKWebView's Tab then visits buttons and links
/// too), and `dpr`, the main screen's backing scale (devicePixelRatio).
/// Owned by the caller (the engine copies it); null: as is.
fn withPlatformExtras(gpa: std.mem.Allocator, platform_json: [:0]const u8) ?[:0]const u8 {
    const trimmed = std.mem.trimEnd(u8, platform_json, " \n");
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '}') return null;
    const app = cocoa.class("NSApplication").msgSend(Object, "sharedApplication", .{});
    const fka = cocoa.isTrue(app.msgSend(BOOL, "isFullKeyboardAccessEnabled", .{}));
    const screen = cocoa.class("NSScreen").msgSend(Object, "mainScreen", .{});
    const dpr: f64 = if (screen.value != null) screen.msgSend(f64, "backingScaleFactor", .{}) else 1;
    const body = trimmed[0 .. trimmed.len - 1];
    const sep: []const u8 = if (std.mem.trimEnd(u8, body, " \n").len > 1) "," else "";
    return std.fmt.allocPrintSentinel(gpa, "{s}{s}\"fullKeyboardAccess\":{},\"dpr\":{d}}}", .{ body, sep, fka, dpr }, 0) catch null;
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
    const extras = withPlatformExtras(gpa, platform_json);
    // Scroll bars always shown (System Settings, or a mouse without
    // gestures): WebKit's classic ones keep room in the layout, 15 px (11
    // thin); overlay ones (the default) none.
    const legacy = cocoa.class("NSScroller").msgSend(c_long, "preferredScrollerStyle", .{}) == 0;
    defer if (extras) |j| gpa.free(j);
    const platform = extras orelse platform_json;
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
    }, assets, platform, label, url, width, height);
    if (legacy) s.engine.tree.scrollbar = .{ 15, 11 };
    // Text-only updates that keep a text's size keep the layout (its
    // natural size is kept per node: measureText).
    s.engine.tree.reuse_text_layout = true;
    s.engine.boot(s.dark, false);
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
    var it = s.fields.iterator();
    while (it.next()) |e| dropField(e.value_ptr.*);
    s.fields.deinit(s.gpa);
    s.view.msgSend(void, "removeFromSuperview", .{});
    releaseLater(s.view); // it may be in one of its own callbacks
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
    // Released later, not now: the page may drop a field from inside that
    // control's own callback (a handler for its Enter), or while its menu is
    // open (timers and commands run during menu tracking, each draining its
    // own pool, so autorelease isn't late enough). A delayed perform runs in
    // the default run loop mode only: after tracking ends.
    releaseLater(f.holder); // and with it the control
}

/// Release `o` (our reference) once the run loop is back in its default
/// mode. The delayed perform retains `o` and releases it after performing,
/// so the performed `release` is the one that drops ours.
fn releaseLater(o: Object) void {
    o.msgSend(void, "performSelector:withObject:afterDelay:", .{ cocoa.objc.sel("release").value, cocoa.nil, @as(f64, 0) });
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

fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    switch (n.kind) {
        .text => out.* = draw.measureText("NSFont", n, max_width, surfaceOf(ctx).text_epoch),
        .image => out.* = draw.measureImage(surfaceOf(ctx).engine, n, max_width),
        // One line of the field's font (WebKit's control sizes come from
        // it); a textarea `rows` of them (2 by default).
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), draw.fieldLine("NSFont", n) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, draw.fieldLine("NSFont", n) * @max(1, n.props.rows orelse 2) },
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

// ---------------------------------------------------------------------------
// Display frames: the page's requestAnimationFrame at the display's refresh
// (a ProMotion panel's 120 Hz, an external display's 144), not a 60 Hz timer.
// The link runs only while the page asks: each frame takes the request, and
// a frame with no new one pauses the link.

extern const NSRunLoopCommonModes: id;

const CAFrameRateRange = extern struct { minimum: f32, maximum: f32, preferred: f32 };

fn hasDisplayLink(view: Object) bool {
    // NSView.displayLink(target:selector:): macOS 14; before, the timer grid.
    const cls = view.getClass() orelse return false;
    return cls.respondsToSelector(cocoa.objc.sel("displayLinkWithTarget:selector:"));
}

fn requestDisplayFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.frame_wanted = true;
    runDisplayLink(s);
}

/// Start (or resume) the display link: a frame the page asked for, or a
/// pointer move to send.
fn runDisplayLink(s: *Surface) void {
    if (s.display_link.value != null) {
        s.display_link.msgSend(void, "setPaused:", .{cocoa.boolean(false)});
        return;
    }
    const link = s.view.msgSend(Object, "displayLinkWithTarget:selector:", .{ s.view, cocoa.objc.sel("nuiDisplayFrame:").value });
    if (link.value == null) return;
    s.display_link = link.retain();
    
    const loop = cocoa.class("NSRunLoop").msgSend(Object, "currentRunLoop", .{});
    link.msgSend(void, "addToRunLoop:forMode:", .{ loop, Object{ .value = NSRunLoopCommonModes } });
}

fn onDisplayFrame(self: id, _: SEL, link_id: id) callconv(.c) void {
    const link: Object = .{ .value = link_id };
    const s = by_view.get(key(self)) orelse return;
    // Input first, then the frame (as a browser): the page's handler can
    // ask for the frame that shows it.
    if (s.move != null) {
        const token = s.token;
        flushMove(s);
        if (surfaces.get(token) == null) return; // the page closed its window
    }
    if (!s.frame_wanted) {
        link.msgSend(void, "setPaused:", .{cocoa.boolean(true)});
        return;
    }
    s.frame_wanted = false;
    // The refresh interval: this frame's to the next (a variable-rate panel
    // changes it), else the link's nominal duration.
    var interval = (link.msgSend(f64, "targetTimestamp", .{}) - link.msgSend(f64, "timestamp", .{})) * 1000;
    if (!(interval > 0) or !std.math.isFinite(interval)) interval = link.msgSend(f64, "duration", .{}) * 1000;
    if (!(interval > 0) or !std.math.isFinite(interval)) interval = 0;
    const token = s.token;
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    s.engine.displayFrame(interval);
    // The page may have closed its window during the frame (destroy
    // invalidated the link); else the link runs on only if it asked again.
    const still = surfaces.get(token) orelse return;
    if (!still.frame_wanted) link.msgSend(void, "setPaused:", .{cocoa.boolean(true)});
}

/// Backend.warm_fonts: fonts load when the main run loop is idle (about to
/// sleep: kCFRunLoopBeforeWaiting), one per idle moment, and not while a
/// timer is due within `warm_margin` or the page wants an animation frame:
/// a cold font takes a few ms, which shouldn't make a due timer late.
/// Backend.font_metrics: the text font's ascent and descent at a size.
fn fontMetrics(_: *anyopaque, size: f32, mono: bool, out: *[3]f32) bool {
    return draw.fontMetrics("NSFont", size, mono, out);
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
        const pool = cocoa.objc.AutoreleasePool.init();
        defer pool.deinit();
        draw.warmFont("NSFont", spec);
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
    cocoa.afterMain(ms, d, onTimer);
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
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    s.engine.timerFired(timer_id);
}

fn focus(ctx: *anyopaque, n: *Node) void {
    const s = surfaceOf(ctx);
    const win = s.view.msgSend(Object, "window", .{});
    // Not a native field (a button the page's Tab reached): the page takes
    // the keyboard back from a field that had it.
    const f = s.fields.get(n.id) orelse {
        if (s.focused != 0) _ = win.msgSend(BOOL, "makeFirstResponder:", .{s.view});
        return;
    };
    // A control that won't take the keyboard (a popup without Full
    // Keyboard Access): the page takes it from a field that had it.
    if (!cocoa.isTrue(win.msgSend(BOOL, "makeFirstResponder:", .{f.inner})) or
        !cocoa.isTrue(f.inner.msgSend(BOOL, "acceptsFirstResponder", .{})))
    {
        if (s.focused != 0) _ = win.msgSend(BOOL, "makeFirstResponder:", .{s.view});
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
    s.view.msgSend(void, "setNeedsDisplay:", .{cocoa.boolean(true)});
    if (std.c.getenv("ORIEL_NUI_SNAPSHOT") != null and !s.snapshot_queued) {
        const t = std.heap.smp_allocator.create(u64) catch return;
        s.snapshot_queued = true;
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
        // The page changes placeholders ("Select text first…" → "Tell
        // GhostPen what to do…"); a text area's is drawn under it.
        if (n.kind == .input and !f.slider) if (cocoa.nsString(n.props.ph orelse "")) |ph| {
            defer ph.release();
            f.inner.msgSend(void, "setPlaceholderString:", .{ph});
        };
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
        .input => if (n.props.range != null) blk: {
            const sl = cocoa.class("NSSlider").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
            if (sl.value == null) return null;
            const r = draw.Range.of(n);
            sl.msgSend(void, "setMinValue:", .{r.min});
            sl.msgSend(void, "setMaxValue:", .{r.max});
            sl.msgSend(void, "setDoubleValue:", .{r.min});
            sl.msgSend(void, "setContinuous:", .{cocoa.boolean(true)});
            sl.msgSend(void, "setTarget:", .{field_delegate});
            sl.msgSend(void, "setAction:", .{cocoa.objc.sel("sliderChanged:").value});
            break :blk .{ .holder = cocoa.nil, .outer = sl, .inner = sl, .slider = true };
        } else blk: {
            const cls = (if (n.props.pw) secure_field_class else text_field_class).?;
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
            const tv = text_view_class.?.msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFrame:", .{zero});
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
    if (f.slider) return f.inner.msgSend(void, "setDoubleValue:", .{draw.Range.of(n).parse(v)});
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
    if (f.slider) {
        // The page's min/max/step may change; accent-color tints the track.
        const r = draw.Range.of(n);
        f.inner.msgSend(void, "setMinValue:", .{r.min});
        f.inner.msgSend(void, "setMaxValue:", .{r.max});
        if (n.props.acc) |a| if (f.inner.getClass()) |cls| if (cls.respondsToSelector(cocoa.objc.sel("setTrackFillColor:"))) {
            f.inner.msgSend(void, "setTrackFillColor:", .{cocoa.class("NSColor").msgSend(Object, "colorWithSRGBRed:green:blue:alpha:", .{
                @as(f64, a[0] / 255), @as(f64, a[1] / 255), @as(f64, a[2] / 255), @as(f64, a[3]),
            })});
        };
        return;
    }
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

/// Nothing of the surface is read after the event: a window's close is
/// queued today, but a handler that ended the surface would free it.
fn sendValue(s: *Surface, n: *Node, kind: []const u8, text: []const u8) void {
    const gpa = s.gpa;
    const json = std.json.Stringify.valueAlloc(gpa, text, .{}) catch return;
    defer gpa.free(json);
    _ = s.engine.event(n.id, kind, json);
}

// ---------------------------------------------------------------------------
// Focus: the page hears which field has the keyboard ("focus" and "blur",
// so :focus, :focus-visible and document.activeElement follow it). A text
// field hands the keyboard to the window's field editor; its owner is the
// editor's delegate. Checked once things settle after a change.

var text_field_class: ?cocoa.objc.Class = null;
var secure_field_class: ?cocoa.objc.Class = null;
var text_view_class: ?cocoa.objc.Class = null;

fn textFieldBecomeFirst(self: id, _: SEL) callconv(.c) BOOL {
    const ok = (Object{ .value = self }).msgSendSuper(cocoa.class("NSTextField"), BOOL, "becomeFirstResponder", .{});
    focusChangedNear(self);
    return ok;
}

fn secureFieldBecomeFirst(self: id, _: SEL) callconv(.c) BOOL {
    const ok = (Object{ .value = self }).msgSendSuper(cocoa.class("NSSecureTextField"), BOOL, "becomeFirstResponder", .{});
    focusChangedNear(self);
    return ok;
}

fn textViewBecomeFirst(self: id, _: SEL) callconv(.c) BOOL {
    const ok = (Object{ .value = self }).msgSendSuper(cocoa.class("NSTextView"), BOOL, "becomeFirstResponder", .{});
    focusChangedNear(self);
    return ok;
}

fn textViewResignFirst(self: id, _: SEL) callconv(.c) BOOL {
    const ok = (Object{ .value = self }).msgSendSuper(cocoa.class("NSTextView"), BOOL, "resignFirstResponder", .{});
    focusChangedNear(self);
    return ok;
}

fn fieldEditingChanged(_: id, _: SEL, note: id) callconv(.c) void {
    focusChangedNear((Object{ .value = note }).msgSend(Object, "object", .{}).value);
}

/// A field of some page may have taken or lost the keyboard.
fn focusChangedNear(control: id) void {
    const o = by_control.get(key(control)) orelse return;
    const s = surfaces.get(o.token) orelse return;
    queueFocusCheck(s);
}

fn queueFocusCheck(s: *Surface) void {
    if (s.focus_check_queued) return;
    const t = std.heap.smp_allocator.create(u64) catch return;
    t.* = s.token;
    s.focus_check_queued = true;
    cocoa.afterMain(0, t, onFocusCheck);
}

fn onFocusCheck(p: ?*anyopaque) callconv(.c) void {
    const t: *u64 = @ptrCast(@alignCast(p.?));
    const token = t.*;
    std.heap.smp_allocator.destroy(t);
    const s = surfaces.get(token) orelse return;
    s.focus_check_queued = false;
    // The field node whose control has the keyboard, if any.
    var nid: i64 = 0;
    const window = s.view.msgSend(Object, "window", .{});
    if (window.value != null) {
        var r = window.msgSend(Object, "firstResponder", .{});
        if (r.value != null and cocoa.isTrue(r.msgSend(BOOL, "isKindOfClass:", .{cocoa.class("NSTextView").value})) and
            cocoa.isTrue(r.msgSend(BOOL, "isFieldEditor", .{}))) r = r.msgSend(Object, "delegate", .{});
        if (r.value != null) if (by_control.get(key(r.value))) |o| {
            if (o.token == token) nid = o.node;
        };
    }
    if (nid == s.focused) return;
    const old = s.focused;
    s.focused = nid;
    if (old != 0) {
        _ = s.engine.event(old, "blur", "null");
        if (surfaces.get(token) == null) return; // the page closed its window
    }
    if (nid != 0) _ = s.engine.event(nid, "focus", "null");
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
    // The page heard this key as it came (onKeyEvent) and let it through.
    if (event.value != null and event.value == field_key) {
        field_key = null;
        return false;
    }
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
    // The placeholder under it comes and goes with the text.
    o.s.view.msgSend(void, "setNeedsDisplay:", .{cocoa.boolean(true)});
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

/// A slider moved: `input` while the mouse drags it, `input` and `change`
/// when it lets go or a key moved it (as Android's SeekBar sends them).
fn sliderChanged(_: id, _: SEL, sender: id) callconv(.c) void {
    const o = ownerOf(sender) orelse return;
    if (o.s.updating) return;
    const sl: Object = .{ .value = sender };
    const r = draw.Range.of(o.n);
    var buf: [48]u8 = undefined;
    const text = r.text(&buf, sl.msgSend(f64, "doubleValue", .{}));
    sl.msgSend(void, "setDoubleValue:", .{r.snap(sl.msgSend(f64, "doubleValue", .{}))});
    sendValue(o.s, o.n, "input", text);
    const event = cocoa.class("NSApplication").msgSend(Object, "sharedApplication", .{}).msgSend(Object, "currentEvent", .{});
    const kind = if (event.value != null) event.msgSend(c_ulong, "type", .{}) else 0;
    // NSEventTypeLeftMouseDown 1, LeftMouseDragged 6: still dragging.
    if (kind == 1 or kind == 6) return;
    // The page may have closed the window or rebuilt the node.
    const again = ownerOf(sender) orelse return;
    sendValue(again.s, again.n, "change", text);
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
    // A canvas's bitmap is as many pixels per point as the screen has.
    const win = s.view.msgSend(Object, "window", .{});
    const scale: f64 = if (win.value != null) win.msgSend(f64, "backingScaleFactor", .{}) else 2;
    draw.paint("NSFont", @ptrCast(cg orelse return), s.engine, s.transparent, .{ .ctx = s, .empty = fieldEmpty, .dark = s.dark }, scale);
}

/// A text area's control is empty: its placeholder is drawn under it.
fn fieldEmpty(ctx: *anyopaque, n: *Node) bool {
    const s = surfaceOf(ctx);
    const f = s.fields.get(n.id) orelse return true;
    return f.inner.msgSend(Object, "string", .{}).msgSend(c_ulong, "length", .{}) == 0;
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
    s.text_epoch +%= 1;
    if (s.text_epoch == 0) s.text_epoch = 1;
    // Same size: force the page to hear the new color scheme.
    const w = s.engine.tree.width;
    s.engine.tree.width = -1;
    s.engine.resize(w, s.engine.tree.height, dark);
}

/// The window went to a screen with another scale (or the view into a
/// window): the page's devicePixelRatio ("dpr"; main.js ignores the same).
fn backingChanged(self: id, _: SEL) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const win = s.view.msgSend(Object, "window", .{});
    if (win.value == null) return;
    const scale: f64 = win.msgSend(f64, "backingScaleFactor", .{});
    if (!(scale > 0)) return;
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{d}", .{scale}) catch return;
    _ = s.engine.event(0, "dpr", json);
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
    if (s.focused != 0) queueFocusCheck(s);
    const p = point(self, event);
    const token = s.token;
    const mods = modFlags((Object{ .value = event }).msgSend(c_ulong, "modifierFlags", .{}));
    // :active while the button is down.
    const hit = s.engine.tree.hit(p[0], p[1]);
    if (hit) |n| _ = s.engine.event(n.id, "press", "null");
    if (surfaces.get(token) == null) return;
    // A move still waiting goes before the down.
    if (s.move != null) flushMove(s);
    if (surfaces.get(token) == null) return;
    _ = sendPointer(s, "down", p, 1, mods);
}

fn mouseUp(self: id, _: SEL, event: id) callconv(.c) void {
    const s = by_view.get(key(self)) orelse return;
    const token = s.token;
    // A move still waiting goes first, then the up, then the click.
    if (s.move != null) flushMove(s);
    if (surfaces.get(token) == null) return;
    const p = point(self, event);
    _ = sendPointer(s, "up", p, 0, modFlags((Object{ .value = event }).msgSend(c_ulong, "modifierFlags", .{})));
    if (surfaces.get(token) == null) return;
    _ = s.engine.event(0, "release", "null");
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

fn mouseDragged(self: id, _: SEL, event: id) callconv(.c) void {
    pointerMoved(self, event, 1);
}

fn mouseMoved(self: id, _: SEL, event: id) callconv(.c) void {
    pointerMoved(self, event, 0);
}

/// The mouse moved (`buttons` 1: dragging): the page's pointer move, then
/// the cursor and :hover under it.
fn pointerMoved(self: id, event: id, buttons: u32) void {
    const s = by_view.get(key(self)) orelse return;
    const token = s.token;
    const p = point(self, event);
    queueMove(s, p, buttons, modFlags((Object{ .value = event }).msgSend(c_ulong, "modifierFlags", .{})));
    // Sent at once (no display link): the page may have closed its window.
    if (surfaces.get(token) == null) return;
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
    const k: f64 = if (precise) 1 else 16;
    // Positive deltas move the content down/right: the page's d is the opposite.
    var dy: f32 = @floatCast(-ev.msgSend(f64, "scrollingDeltaY", .{}) * k);
    var dx: f32 = @floatCast(-ev.msgSend(f64, "scrollingDeltaX", .{}) * k);
    // Shift with a mouse wheel scrolls sideways, as in browsers.
    const shift = ev.msgSend(c_ulong, "modifierFlags", .{}) & (1 << 17) != 0;
    if (shift and !precise and dx == 0) {
        dx = dy;
        dy = 0;
    }
    if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return;
    const p = point(self, event);
    const under = s.engine.tree.hit(p[0], p[1]);
    if (dy != 0) {
        var target = s.engine.tree.scroller(under);
        while (target) |t| {
            if (s.engine.scrollBy(t, dy)) {
                flash(s, t);
                break;
            }
            target = s.engine.tree.scroller(t.parent);
        }
    }
    if (dx != 0) {
        var target = s.engine.tree.scrollerX(under);
        while (target) |t| {
            if (s.engine.scrollByX(t, dx)) {
                flash(s, t);
                break;
            }
            target = s.engine.tree.scrollerX(t.parent);
        }
    }
}

const PendingMove = struct { at: [2]f32, buttons: u32, mods: u32 };

/// A pointer event for the page (main.js pointerEvent): `phase` down, move,
/// up or cancel at `p` (the view's points: CSS px), on the node there.
/// True when the page prevented the default.
fn sendPointer(s: *Surface, phase: []const u8, p: [2]f32, buttons: u32, mods: u32) bool {
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return false;
    const nid: i64 = if (s.engine.tree.hit(p[0], p[1])) |n| n.id else 0;
    var buf: [96]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d:.2},{d:.2},{d},1,\"mouse\",{d}]", .{ phase, p[0], p[1], buttons, mods }) catch return false;
    return s.engine.event(nid, "pointer", json);
}

/// A mouse move waits for the next display frame (the latest one wins);
/// without a display link (before macOS 14) it goes at once.
fn queueMove(s: *Surface, p: [2]f32, buttons: u32, mods: u32) void {
    if (!hasDisplayLink(s.view)) {
        _ = sendPointer(s, "move", p, buttons, mods);
        return;
    }
    s.move = .{ .at = p, .buttons = buttons, .mods = mods };
    runDisplayLink(s);
}

/// A layout that dropped many nodes (a list that went): the tree's emptied
/// pool slabs go back 2 s later, if the window is still there (a list
/// rebuilt at once reuses them first).

/// The user scrolled `n`: its overlay indicator shows (apple_draw
/// paintIndicators), the view redrawn each frame until it has faded.
fn flash(s: *Surface, n: *Node) void {
    const now = draw.nowMs();
    n.flashed_at = now;
    s.flash_until = now + draw.indicator.hold_ms + draw.indicator.fade_ms;
    if (s.flash_queued) return;
    const t = std.heap.smp_allocator.create(u64) catch return;
    t.* = s.token;
    s.flash_queued = true;
    cocoa.afterMain(16, t, onFlash);
}

fn onFlash(p: ?*anyopaque) callconv(.c) void {
    const t: *u64 = @ptrCast(@alignCast(p.?));
    const s = surfaces.get(t.*) orelse {
        std.heap.smp_allocator.destroy(t);
        return; // the window is gone
    };
    s.view.msgSend(void, "setNeedsDisplay:", .{cocoa.boolean(true)});
    if (draw.nowMs() < s.flash_until + 16) return cocoa.afterMain(16, t, onFlash);
    std.heap.smp_allocator.destroy(t);
    s.flash_queued = false;
}

fn queueTrim(s: *Surface) void {
    const count = s.engine.tree.nodes.count();
    defer s.node_count = count;
    if (s.node_count <= count + 1000 or s.trim_queued) return;
    const t = std.heap.smp_allocator.create(u64) catch return;
    t.* = s.token;
    s.trim_queued = true;
    cocoa.afterMain(2000, t, onTrim);
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
    const m = s.move orelse return;
    s.move = null;
    _ = sendPointer(s, "move", m.at, m.buttons, m.mods);
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
    // A Tab the monitor already gave the page (onKeyEvent).
    if (event == tab_sent) {
        tab_sent = null;
        return;
    }
    _ = sendKeyDown(s, 0, event);
}

/// A key down for the page ("key", on node `nid` or the focused element):
/// true when the page prevented its default.
fn sendKeyDown(s: *Surface, nid: i64, event: id) bool {
    return sendKey(s, nid, event, "key");
}

/// The last Tab key down the monitor sent the page (keyDown skips it).
var tab_sent: id = null;

// Key releases: AppKit doesn't send keyUp: to the page's view (the key
// window's first responder) here, so a local event monitor, one for the
// process, hands each key up to the view that has the keyboard. The
// handler is a global block (no captures), as the runtime's blocks are laid out.
extern var _NSConcreteGlobalBlock: anyopaque;
const BlockDescriptor = extern struct { reserved: c_ulong, size: c_ulong };
const MonitorBlock = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*MonitorBlock, id) callconv(.c) id,
    descriptor: *const BlockDescriptor,
};
const block_is_global: c_int = 1 << 28;
const key_up_mask: c_ulonglong = 1 << 11; // NSEventMaskKeyUp
const key_down_mask: c_ulonglong = 1 << 10; // NSEventMaskKeyDown
const flags_changed_mask: c_ulonglong = 1 << 12; // NSEventMaskFlagsChanged
const tab_key_code: c_ushort = 48;
const key_up_descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(MonitorBlock) };
var key_up_block: MonitorBlock = undefined;
var key_up_monitor: bool = false;

fn installKeyUpMonitor() void {
    if (key_up_monitor) return;
    key_up_monitor = true;
    key_up_block = .{ .isa = &_NSConcreteGlobalBlock, .flags = block_is_global, .reserved = 0, .invoke = onKeyEvent, .descriptor = &key_up_descriptor };
    // The monitor lives as long as the process (never removed).
    _ = cocoa.class("NSEvent").msgSend(Object, "addLocalMonitorForEventsMatchingMask:handler:", .{ key_up_mask | key_down_mask | flags_changed_mask, @as(*anyopaque, @ptrCast(&key_up_block)) });
}

fn onKeyEvent(_: *MonitorBlock, event: id) callconv(.c) id {
    const ev: Object = .{ .value = event };
    const window = ev.msgSend(Object, "window", .{});
    if (window.value == null) return event;
    const responder = window.msgSend(Object, "firstResponder", .{});
    if (responder.value == null) return event;
    const page = by_view.get(key(responder.value));
    var s: *Surface = undefined;
    var nid: i64 = 0;
    if (page) |p| {
        s = p;
    } else {
        // A field: its control (a text field's is the field editor's delegate).
        var control = responder;
        if (cocoa.isTrue(control.msgSend(BOOL, "isKindOfClass:", .{cocoa.class("NSTextView").value})) and
            cocoa.isTrue(control.msgSend(BOOL, "isFieldEditor", .{}))) control = control.msgSend(Object, "delegate", .{});
        const o = by_control.get(key(control.value)) orelse return event;
        s = surfaces.get(o.token) orelse return event;
        nid = o.node;
    }
    // While an input method composes (marked text) in a field, its keys
    // are the field's alone: the page hears none of them.
    const composing = page == null and cocoa.isTrue(responder.msgSend(BOOL, "respondsToSelector:", .{cocoa.objc.sel("hasMarkedText").value})) and
        cocoa.isTrue(responder.msgSend(BOOL, "hasMarkedText", .{}));
    // The page may close its window in a handler: nothing of it is used
    // after, and the event goes nowhere.
    const token = s.token;
    switch (ev.msgSend(c_ulong, "type", .{})) {
        // NSEventTypeFlagsChanged 12: Shift, Control, Option or Command
        // went down or up, its own keydown and keyup, as in browsers.
        12 => {
            if (!composing) sendModifier(s, nid, ev);
            return if (surfaces.get(token) == null) null else event;
        },
        // NSEventTypeKeyUp 11 (AppKit sends the page's view no keyUp:). Not
        // a key let go while Command is down: WebKit fires no keyup for it.
        11 => {
            if (!composing and ev.msgSend(c_ulong, "modifierFlags", .{}) & (1 << 20) == 0) _ = sendKey(s, nid, event, "keyup");
            return if (surfaces.get(token) == null) null else event;
        },
        else => {},
    }
    // A key down. Tab (and Shift+Tab): AppKit's key-view loop takes it
    // before any keyDown:, from the page and from its fields. The page
    // hears it first (its focus navigation); the loop only gets what it
    // doesn't handle. The page's other keys come to its keyDown:.
    const tab = ev.msgSend(c_ushort, "keyCode", .{}) == tab_key_code;
    field_key = null;
    if (page != null and !tab) {
        tab_sent = null;
        return event;
    }
    if (page != null) tab_sent = event;
    // A field's keys reach the page before the field acts on them, and one
    // it prevents never reaches the field (no character, no caret move, no
    // select-all).
    if (composing) return event;
    if (page == null) field_key = event;
    const prevented = sendKeyDown(s, nid, event);
    return if (prevented or surfaces.get(token) == null) null else event;
}

/// Shift, Control, Option or Command (either side) as the page's key down
/// or up.
fn sendModifier(s: *Surface, nid: i64, ev: Object) void {
    const code = ev.msgSend(c_ushort, "keyCode", .{});
    // Down when its own side's (device-dependent) flag is now set: with
    // both Shifts held, letting one go is its key up.
    const name: []const u8, const bit: c_ulong = switch (code) {
        56 => .{ "Shift", 0x2 },
        60 => .{ "Shift", 0x4 },
        59 => .{ "Control", 0x1 },
        62 => .{ "Control", 0x2000 },
        58 => .{ "Alt", 0x20 },
        61 => .{ "Alt", 0x40 },
        55 => .{ "Meta", 0x8 },
        54 => .{ "Meta", 0x10 },
        else => return,
    };
    const flags = ev.msgSend(c_ulong, "modifierFlags", .{});
    var buf: [48]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d},false]", .{ name, modFlags(flags) }) catch return;
    _ = s.engine.event(nid, if (flags & bit != 0) "key" else "keyup", json);
}

/// The key down a field's keys last sent the page (commandKey doesn't
/// send it again).
var field_key: id = null;

/// A key's "key" (down) or "keyup" for the page, on node `nid` (0: the
/// focused element): true when the page prevented its default.
fn sendKey(s: *Surface, nid: i64, event: id, kind: []const u8) bool {
    const ev: Object = .{ .value = event };
    const name = keyName(ev) orelse return false;
    const gpa = s.gpa; // not read from the surface after the event (see sendValue)
    const k = std.json.Stringify.valueAlloc(gpa, name, .{}) catch return false;
    defer gpa.free(k);
    var buf: [64]u8 = undefined;
    const repeat = cocoa.isTrue(ev.msgSend(BOOL, "isARepeat", .{}));
    const json = std.fmt.bufPrint(&buf, "[{s},{d},{}]", .{ k, modFlags(ev.msgSend(c_ulong, "modifierFlags", .{})), repeat }) catch return false;
    return s.engine.event(nid, kind, json);
}

test {
    _ = log;
}
