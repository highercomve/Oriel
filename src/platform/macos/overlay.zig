//! Overlay windows on macOS (Milestone 10): transparency, always-on-top,
//! staying out of the Dock's window list and the app switcher, placement on
//! the work area of the window's screen, and click-through.
//!
//! - transparent: the window is not opaque, its background is clearColor,
//!   and the WKWebView draws no background (`drawsBackground` = NO, and
//!   `underPageBackgroundColor` clear on macOS 12+); give `html, body` a
//!   transparent background.
//! - always_on_top: NSFloatingWindowLevel, or NSStatusWindowLevel when the
//!   window also skips the taskbar (an overlay: above other apps' floating
//!   panels too).
//! - skip_taskbar: collectionBehavior canJoinAllSpaces | transient |
//!   ignoresCycle | fullScreenAuxiliary (shown on every Space, over
//!   full-screen apps, left out of ⌘` cycling and Mission Control). An app
//!   without a Dock icon is `show_main_window = false` (Shell.zig: accessory
//!   activation policy).
//! - placement / workArea: the NSScreen `visibleFrame` (without the menu bar
//!   and Dock), flipped to top-left coordinates like the other platforms.
//! - click-through: `ignoresMouseEvents`.
//!
//! All AppKit calls run on the main thread (forwarded there from others).

const std = @import("std");
const App = @import("../../core/App.zig");
const cocoa = @import("cocoa.zig");
const ShellMod = @import("Shell.zig");
const WindowHandle = @import("window.zig").WindowHandle;

const Object = cocoa.Object;

const NSNormalWindowLevel: isize = 0;
const NSFloatingWindowLevel: isize = 3;
const NSStatusWindowLevel: isize = 25;

// NSWindowCollectionBehavior
const can_join_all_spaces: c_ulong = 1 << 0;
const transient: c_ulong = 1 << 3;
const ignores_cycle: c_ulong = 1 << 6;
const full_screen_primary: c_ulong = 1 << 7;
const full_screen_auxiliary: c_ulong = 1 << 8;

fn levelFor(options: App.WindowOptions) isize {
    return if (options.skip_taskbar) NSStatusWindowLevel else NSFloatingWindowLevel;
}

/// Called by createWindow (main thread) before the window is shown.
pub fn setup(win: Object, view: Object, options: App.WindowOptions) void {
    if (options.transparent) {
        win.msgSend(void, "setOpaque:", .{cocoa.boolean(false)});
        const clear = cocoa.class("NSColor").msgSend(Object, "clearColor", .{});
        win.msgSend(void, "setBackgroundColor:", .{clear});
        win.msgSend(void, "setHasShadow:", .{cocoa.boolean(false)});
        // WKWebView paints white under the page unless told not to.
        const no = cocoa.class("NSNumber").msgSend(Object, "numberWithBool:", .{cocoa.boolean(false)});
        const key = cocoa.nsString("drawsBackground") orelse return;
        defer key.release();
        view.msgSend(void, "setValue:forKey:", .{ no, key });
        if (view.getClass().?.respondsToSelector(cocoa.objc.sel("setUnderPageBackgroundColor:"))) {
            view.msgSend(void, "setUnderPageBackgroundColor:", .{clear}); // macOS 12+
        }
    }
    if (options.always_on_top) win.msgSend(void, "setLevel:", .{levelFor(options)});
    if (options.skip_taskbar) {
        const behavior = win.msgSend(c_ulong, "collectionBehavior", .{});
        win.msgSend(void, "setCollectionBehavior:", .{(behavior & ~full_screen_primary) | can_join_all_spaces | transient | ignores_cycle | full_screen_auxiliary});
    }
}

/// Called by window.zig when the window is shown (main thread): a window
/// with a placement is put there, computed from its current size.
pub fn onShow(handle: WindowHandle, options: App.WindowOptions) void {
    if (options.placement) |p| placeNow(handle, p);
}

// --- Runtime operations (App.Window.place / setClickThrough / ...) -----------------

/// Run `func(ctx)` on the main thread: at once there, else waiting for it.
fn onMain(comptime Ctx: type, ctx: *Ctx, comptime func: fn (*Ctx) void) void {
    if (cocoa.isMainThread()) return func(ctx);
    ShellMod.runOnMainThread(Ctx, ctx, func) catch {};
}

fn alive(handle: WindowHandle) bool {
    return App.getWindowByHandle(handle) != null;
}

pub fn setWindowPlacement(handle: WindowHandle, placement: App.Placement) void {
    const Ctx = struct {
        handle: WindowHandle,
        placement: App.Placement,
        fn run(c: *@This()) void {
            if (alive(c.handle)) placeNow(c.handle, c.placement);
        }
    };
    var ctx: Ctx = .{ .handle = handle, .placement = placement };
    onMain(Ctx, &ctx, Ctx.run);
}

pub fn setWindowClickThrough(handle: WindowHandle, enabled: bool) void {
    const Ctx = struct {
        handle: WindowHandle,
        enabled: bool,
        fn run(c: *@This()) void {
            if (!alive(c.handle)) return;
            c.handle.nsWindow().msgSend(void, "setIgnoresMouseEvents:", .{cocoa.boolean(c.enabled)});
        }
    };
    var ctx: Ctx = .{ .handle = handle, .enabled = enabled };
    onMain(Ctx, &ctx, Ctx.run);
}

pub fn setWindowAlwaysOnTop(handle: WindowHandle, enabled: bool) void {
    const Ctx = struct {
        handle: WindowHandle,
        enabled: bool,
        fn run(c: *@This()) void {
            const w = App.getWindowByHandle(c.handle) orelse return;
            const level = if (c.enabled) levelFor(w.options) else NSNormalWindowLevel;
            c.handle.nsWindow().msgSend(void, "setLevel:", .{level});
        }
    };
    var ctx: Ctx = .{ .handle = handle, .enabled = enabled };
    onMain(Ctx, &ctx, Ctx.run);
}

pub fn getWindowWorkArea(handle: WindowHandle) ?App.Rect {
    const Ctx = struct {
        handle: WindowHandle,
        result: ?App.Rect = null,
        fn run(c: *@This()) void {
            if (alive(c.handle)) c.result = workAreaNow(c.handle);
        }
    };
    var ctx: Ctx = .{ .handle = handle };
    onMain(Ctx, &ctx, Ctx.run);
    return ctx.result;
}

/// Height of the primary screen: Cocoa's global coordinates start at its
/// bottom-left corner; ours at its top-left.
fn primaryHeight() f64 {
    const screens = cocoa.class("NSScreen").msgSend(Object, "screens", .{});
    if (screens.value == null or screens.msgSend(c_ulong, "count", .{}) == 0) return 0;
    const primary = screens.msgSend(Object, "objectAtIndex:", .{@as(c_ulong, 0)});
    return primary.msgSend(cocoa.NSRect, "frame", .{}).size.height;
}

/// The visible frame (no menu bar, no Dock) of the window's screen, or the
/// main screen's, in top-left coordinates.
fn workAreaNow(handle: WindowHandle) ?App.Rect {
    const pool = cocoa.objc.AutoreleasePool.init();
    defer pool.deinit();
    var screen = handle.nsWindow().msgSend(Object, "screen", .{});
    if (screen.value == null) screen = cocoa.class("NSScreen").msgSend(Object, "mainScreen", .{});
    if (screen.value == null) return null;
    const vf = screen.msgSend(cocoa.NSRect, "visibleFrame", .{});
    return .{
        .x = @intFromFloat(@round(vf.origin.x)),
        .y = @intFromFloat(@round(primaryHeight() - (vf.origin.y + vf.size.height))),
        .width = @intFromFloat(@round(vf.size.width)),
        .height = @intFromFloat(@round(vf.size.height)),
    };
}

fn placeNow(handle: WindowHandle, placement: App.Placement) void {
    const area = workAreaNow(handle) orelse return;
    const win = handle.nsWindow();
    const frame = win.msgSend(cocoa.NSRect, "frame", .{});
    const w: c_int = @intFromFloat(@round(frame.size.width));
    const h: c_int = @intFromFloat(@round(frame.size.height));
    const o = placement.origin(area, w, h);
    // Back to Cocoa: the bottom-left corner, y up from the primary screen's bottom.
    const y = primaryHeight() - @as(f64, @floatFromInt(o.y)) - frame.size.height;
    win.msgSend(void, "setFrameOrigin:", .{cocoa.NSPoint{ .x = @floatFromInt(o.x), .y = y }});
}

test {
    std.testing.refAllDecls(@This());
}
