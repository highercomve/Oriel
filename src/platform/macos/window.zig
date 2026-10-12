//! macOS NSWindow + WKWebView creation and manipulation.
//!
//! Window properties (size, fullscreen, zoom, title), close handling, the
//! navigation policy (`WKNavigationDelegate` / `WKUIDelegate`) and dev-server
//! load retries. AppKit is main-thread only: operations called from another
//! thread are forwarded to the main thread.
//!
//! Ownership: each window holds one reference to its NSWindow and WKWebView
//! (from `alloc`), dropped in `teardown`. Delegates and handlers are one
//! shared instance per class for the whole run (`WindowCreator.init`/
//! `deinit`); AppKit and WebKit keep delegates as weak references, so they
//! are detached before a window is released.

const std = @import("std");
const apple = @import("../apple/apple.zig");
const objc = apple.objc;
const Object = apple.Object;
const ShellMod = @import("Shell.zig");
const scheme_mod = @import("scheme.zig");
const bridge_mod = @import("bridge.zig");
const js_dialogs = @import("js_dialogs.zig");
const overlay = @import("overlay.zig");
const permissions = @import("../../core/permissions/gate.zig");
const App = @import("../../core/App.zig");
const internal = @import("../../core/internal.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");
const build_opts = @import("build_options");
const build_target = @import("../../core/target.zig");
const hooks = @import("../../core/hooks.zig");
const apple_hooks = @import("../apple/hooks.zig");
/// -Dnative_ui: pages drawn with native views instead of WebKit (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/appkit.zig") else struct {};

const log = std.log.scoped(.oriel);

pub const WindowHandle = struct {
    window: apple.id,
    webview: apple.id,
    /// Unique per window for the whole run: a queued handle copy must not
    /// match a new window that reuses a closed one's address.
    serial: u64,
    /// The native renderer's surface (-Dnative_ui, `native_ui/appkit.zig`)
    /// for a window without a web view, else null.
    native: ?*anyopaque = null,
    /// The window's label, owned by its `App.Window` (for the destroyed
    /// hooks of `teardown`).
    label: []const u8 = "",

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.serial == other.serial;
    }

    /// The platform hooks' view of the window (hooks.zig).
    fn hookWindow(self: WindowHandle) ?hooks.NativeWindow {
        const w = self.window orelse return null;
        return .{ .appkit = w };
    }

    fn hookView(self: WindowHandle) ?hooks.NativeWebView {
        const v = self.webview orelse return null;
        return .{ .wkwebview = v };
    }

    pub fn nsWindow(self: WindowHandle) Object {
        return .{ .value = self.window };
    }

    pub fn webView(self: WindowHandle) Object {
        return .{ .value = self.webview };
    }
};

pub const WindowSize = struct {
    width: c_int,
    height: c_int,
};

// NSWindowStyleMask
const style_titled: c_ulong = 1 << 0;
const style_closable: c_ulong = 1 << 1;
const style_miniaturizable: c_ulong = 1 << 2;
const style_resizable: c_ulong = 1 << 3;
const style_fullscreen: c_ulong = 1 << 14;
const NSBackingStoreBuffered: c_ulong = 2;
const NSWindowCollectionBehaviorFullScreenPrimary: c_ulong = 1 << 7;

// ---------------------------------------------------------------------------
// Window operations (main thread; forwarded there from other threads)
// ---------------------------------------------------------------------------

const Op = union(enum) {
    show,
    hide,
    toggle,
    focus,
    close,
    title: [:0]u8,
    fullscreen: bool,
    maximized: bool,
    size: WindowSize,
};

/// The app that was frontmost before one of our windows took the focus
/// (+1), so hiding or closing that window can hand the focus back, as on
/// Linux and Windows. macOS leaves an app active after its key window goes
/// away (an accessory app then holds the focus with nothing on screen).
/// Kept current by `appActivated` (every other app's activation), and set
/// when our window takes the focus.
var previous_app: ?Object = null;

fn rememberFrontmost() void {
    const ws = apple.class("NSWorkspace").msgSend(Object, "sharedWorkspace", .{});
    rememberApp(ws.msgSend(Object, "frontmostApplication", .{}));
}

fn rememberApp(app: Object) void {
    if (app.value == null) return;
    const mine = apple.class("NSRunningApplication").msgSend(Object, "currentApplication", .{});
    if (app.msgSend(i32, "processIdentifier", .{}) == mine.msgSend(i32, "processIdentifier", .{})) return;
    if (previous_app) |p| p.release();
    previous_app = app.msgSend(Object, "retain", .{});
}

/// NSWorkspaceDidActivateApplicationNotification: the last other app the
/// user was in (clicking or Cmd-Tabbing away and back keeps it current).
fn appActivated(_: apple.id, _: apple.c.SEL, notification: apple.id) callconv(.c) void {
    const info = (Object{ .value = notification }).msgSend(Object, "userInfo", .{});
    if (info.value == null) return;
    const key = apple.nsString("NSWorkspaceApplicationKey") orelse return;
    defer key.release();
    rememberApp(info.msgSend(Object, "objectForKey:", .{key}));
}

/// Overlays (`focus_on_show = false`) can't become key, so AppKit never
/// hands them the keyboard when another window goes away or on a click;
/// `focus()` lets one take it until it loses it again (or is hidden).
/// Main thread only.
var focusable_overlays: [16]usize = @splat(0);

fn allowOverlayKey(window: apple.id, allow: bool) void {
    const key = @intFromPtr(window orelse return);
    for (&focusable_overlays) |*slot| {
        if (slot.* == key) {
            if (!allow) slot.* = 0;
            return;
        }
    }
    if (!allow) return;
    for (&focusable_overlays) |*slot| {
        if (slot.* == 0) {
            slot.* = key;
            return;
        }
    }
}

/// An overlay that lost the keyboard can't get it back on its own.
fn windowDidResignKey(_: apple.id, _: apple.c.SEL, notification: apple.id) callconv(.c) void {
    allowOverlayKey((Object{ .value = notification }).msgSend(Object, "object", .{}).value, false);
}

fn overlayCanBecome(self: apple.id, _: apple.c.SEL) callconv(.c) apple.c.BOOL {
    const key = @intFromPtr(self orelse return apple.boolean(false));
    for (focusable_overlays) |w| if (w == key) return apple.boolean(true);
    return apple.boolean(false);
}

/// After our key window went away: when no other window of ours took the
/// keyboard, activate the app that had it before.
fn returnFocus() void {
    const app = ShellMod.sharedApplication();
    if (!apple.isTrue(app.msgSend(apple.c.BOOL, "isActive", .{}))) return;
    if (app.msgSend(Object, "keyWindow", .{}).value != null) return;
    const prev = previous_app orelse return;
    if (apple.isTrue(prev.msgSend(apple.c.BOOL, "isTerminated", .{}))) return;
    _ = prev.msgSend(apple.c.BOOL, "activateWithOptions:", .{@as(c_ulong, 0)});
}

/// Give the web view the keyboard when the window itself holds it (a
/// control the page focused inside the web view keeps it).
/// The view that takes the page's keys: the web view, or a native window's
/// drawing view.
fn pageView(handle: WindowHandle) Object {
    if (comptime build_opts.native_ui) if (handle.native) |p| return @as(*native.Surface, @ptrCast(@alignCast(p))).view;
    return handle.webView();
}

fn focusPage(handle: WindowHandle) void {
    const win = handle.nsWindow();
    const responder = win.msgSend(Object, "firstResponder", .{});
    if (responder.value == null or responder.value == handle.window) {
        _ = win.msgSend(apple.c.BOOL, "makeFirstResponder:", .{pageView(handle)});
    }
}

fn apply(handle: WindowHandle, op: Op) void {
    const win = handle.nsWindow();
    switch (op) {
        .show => {
            const w = internal.getWindowByHandle(handle);
            if (w == null or w.?.options.focus_on_show) {
                rememberFrontmost();
                win.msgSend(void, "makeKeyAndOrderFront:", .{apple.nil});
                ShellMod.sharedApplication().msgSend(void, "activateIgnoringOtherApps:", .{apple.boolean(true)});
                focusPage(handle);
            } else {
                // Overlays (captions): shown without taking the keyboard or
                // activating the app, so typing stays where it was.
                win.msgSend(void, "orderFrontRegardless", .{});
            }
            if (w) |ww| overlay.onShow(handle, ww.options);
        },
        .focus => {
            rememberFrontmost();
            if (internal.getWindowByHandle(handle)) |w| {
                if (!w.options.focus_on_show) allowOverlayKey(handle.window, true);
            }
            win.msgSend(void, "makeKeyAndOrderFront:", .{apple.nil});
            ShellMod.sharedApplication().msgSend(void, "activateIgnoringOtherApps:", .{apple.boolean(true)});
            focusPage(handle);
        },
        .hide => {
            const was_key = apple.isTrue(win.msgSend(apple.c.BOOL, "isKeyWindow", .{}));
            allowOverlayKey(handle.window, false);
            win.msgSend(void, "orderOut:", .{apple.nil});
            if (was_key) returnFocus();
        },
        .toggle => {
            const visible = apple.isTrue(win.msgSend(apple.c.BOOL, "isVisible", .{}));
            const key = apple.isTrue(win.msgSend(apple.c.BOOL, "isKeyWindow", .{}));
            // A window that never takes focus toggles on visibility alone.
            const takes_focus = if (internal.getWindowByHandle(handle)) |w| w.options.focus_on_show else true;
            apply(handle, if (visible and (key or !takes_focus)) .hide else .show);
        },
        .close => if (internal.getWindowByHandle(handle)) |w| closeNow(w),
        .title => |t| {
            const str = apple.nsString(t) orelse return;
            defer str.release();
            win.msgSend(void, "setTitle:", .{str});
        },
        .fullscreen => |on| if (isFullscreenNow(handle) != on) win.msgSend(void, "toggleFullScreen:", .{apple.nil}),
        .maximized => |on| if (apple.isTrue(win.msgSend(apple.c.BOOL, "isZoomed", .{})) != on) win.msgSend(void, "zoom:", .{apple.nil}),
        .size => |s| win.msgSend(void, "setContentSize:", .{apple.NSSize{ .width = @floatFromInt(s.width), .height = @floatFromInt(s.height) }}),
    }
}

/// Apply `op` now on the main thread, or queue it for the live window that
/// matches `handle` (a copy may outlive its window).
fn perform(handle: WindowHandle, op: Op) void {
    if (apple.isMainThread()) {
        defer freeOp(op);
        apply(handle, op);
        return;
    }
    const Task = struct {
        handle: WindowHandle,
        op: Op,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer discard(self);
            if (internal.getWindowByHandle(self.handle) != null) apply(self.handle, self.op);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            discard(@ptrCast(@alignCast(ctx.?)));
        }

        fn discard(self: *@This()) void {
            freeOp(self.op);
            std.heap.smp_allocator.destroy(self);
        }
    };
    const task = std.heap.smp_allocator.create(Task) catch {
        freeOp(op);
        log.err("window operation dropped: out of memory", .{});
        return;
    };
    task.* = .{ .handle = handle, .op = op };
    ShellMod.dispatchWithCleanup(&Task.run, task, &Task.cleanup);
}

fn freeOp(op: Op) void {
    switch (op) {
        .title => |t| std.heap.smp_allocator.free(t),
        else => {},
    }
}

/// Read a window property on the main thread (waiting for it from others).
fn query(comptime T: type, handle: WindowHandle, comptime get: fn (WindowHandle) T, fallback: T) T {
    // A stale handle (its window closed) must not reach freed state.
    if (apple.isMainThread()) return if (internal.getWindowByHandle(handle) != null) get(handle) else fallback;
    const Ctx = struct {
        handle: WindowHandle,
        result: T,

        fn run(self: *@This()) void {
            if (internal.getWindowByHandle(self.handle) != null) self.result = get(self.handle);
        }
    };
    var ctx: Ctx = .{ .handle = handle, .result = fallback };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return fallback;
    return ctx.result;
}

pub fn showWindow(handle: WindowHandle) void {
    perform(handle, .show);
}

pub fn hideWindow(handle: WindowHandle) void {
    perform(handle, .hide);
}

pub fn toggleWindow(handle: WindowHandle) void {
    perform(handle, .toggle);
}

pub fn focusWindow(handle: WindowHandle) void {
    perform(handle, .focus);
}

/// Close like the user clicked the close button. On the main thread this is
/// synchronous (as on GTK): the window is gone when it returns. From other
/// threads the close is queued.
pub fn closeWindow(handle: WindowHandle) void {
    perform(handle, .close);
}

/// Close from the main loop, never inside the caller: for a window closing
/// itself from its own webview callbacks.
pub fn postCloseWindow(handle: WindowHandle) void {
    const Task = struct {
        fn run(ctx: ?*anyopaque) void {
            const h: *WindowHandle = @ptrCast(@alignCast(ctx.?));
            defer std.heap.smp_allocator.destroy(h);
            if (internal.getWindowByHandle(h.*)) |w| closeNow(w);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            std.heap.smp_allocator.destroy(@as(*WindowHandle, @ptrCast(@alignCast(ctx.?))));
        }
    };
    const copy = std.heap.smp_allocator.create(WindowHandle) catch {
        log.err("postCloseWindow: out of memory", .{});
        return;
    };
    copy.* = handle;
    ShellMod.dispatchWithCleanup(&Task.run, copy, &Task.cleanup);
}

pub fn setWindowTitle(handle: WindowHandle, title: [:0]const u8) void {
    const copy = std.heap.smp_allocator.dupeZ(u8, title) catch return;
    perform(handle, .{ .title = copy });
}

pub fn setWindowFullscreen(handle: WindowHandle, fullscreen: bool) void {
    perform(handle, .{ .fullscreen = fullscreen });
}

fn isFullscreenNow(handle: WindowHandle) bool {
    return handle.nsWindow().msgSend(c_ulong, "styleMask", .{}) & style_fullscreen != 0;
}

pub fn isWindowFullscreen(handle: WindowHandle) bool {
    return query(bool, handle, isFullscreenNow, false);
}

/// "Maximized" is AppKit's zoom (the green button with Option).
pub fn setWindowMaximized(handle: WindowHandle, maximized: bool) void {
    perform(handle, .{ .maximized = maximized });
}

fn isZoomedNow(handle: WindowHandle) bool {
    return apple.isTrue(handle.nsWindow().msgSend(apple.c.BOOL, "isZoomed", .{}));
}

pub fn isWindowMaximized(handle: WindowHandle) bool {
    return query(bool, handle, isZoomedNow, false);
}

/// Sets the content (webview) size in points.
pub fn setWindowSize(handle: WindowHandle, width: c_int, height: c_int) void {
    perform(handle, .{ .size = .{ .width = width, .height = height } });
}

fn contentSizeNow(handle: WindowHandle) WindowSize {
    const content = handle.nsWindow().msgSend(Object, "contentView", .{});
    if (content.value == null) return .{ .width = 0, .height = 0 };
    const frame = content.msgSend(apple.NSRect, "frame", .{});
    return .{ .width = @intFromFloat(@round(frame.size.width)), .height = @intFromFloat(@round(frame.size.height)) };
}

/// The content (webview) size in points.
pub fn getWindowSize(handle: WindowHandle) WindowSize {
    return query(WindowSize, handle, contentSizeNow, .{ .width = 0, .height = 0 });
}

/// Open `uri` with its default app. Callable from any thread: AppKit is
/// used on the main thread (a copy of `uri` is queued from other threads).
pub fn openExternal(uri: [*:0]const u8) void {
    if (apple.isMainThread()) return openExternalNow(uri);
    const copy = std.heap.smp_allocator.dupeZ(u8, std.mem.span(uri)) catch {
        log.err("could not open {s}: out of memory", .{uri});
        return;
    };
    ShellMod.dispatchWithCleanup(&openQueued, copy.ptr, &freeQueued);
}

fn openQueued(ctx: ?*anyopaque) void {
    const uri: [*:0]const u8 = @ptrCast(ctx.?);
    defer freeQueued(ctx);
    openExternalNow(uri);
}

/// Frees the copy made by `openExternal` (also when the task is dropped at shutdown).
fn freeQueued(ctx: ?*anyopaque) void {
    const uri: [*:0]u8 = @ptrCast(ctx.?);
    std.heap.smp_allocator.free(std.mem.span(uri));
}

fn openExternalNow(uri: [*:0]const u8) void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const str = apple.nsString(std.mem.span(uri)) orelse {
        log.err("could not open {s}: not UTF-8", .{uri});
        return;
    };
    defer str.release();
    const url = apple.class("NSURL").msgSend(Object, "URLWithString:", .{str});
    if (url.value == null) {
        log.err("could not open {s}: invalid URL", .{uri});
        return;
    }
    const workspace = apple.class("NSWorkspace").msgSend(Object, "sharedWorkspace", .{});
    if (!apple.isTrue(workspace.msgSend(apple.c.BOOL, "openURL:", .{url}))) {
        log.err("could not open {s}", .{uri});
    }
}

// ---------------------------------------------------------------------------
// Lookup and teardown
// ---------------------------------------------------------------------------

pub fn getWindowByView(view: apple.id) ?*App.Window {
    if (view == null) return null;
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    for (internal.windows_list.items) |w| {
        if (w.handle.webview == view) return w;
    }
    return null;
}

fn getWindowByNSWindow(nswindow: apple.id) ?*App.Window {
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    for (internal.windows_list.items) |w| {
        if (w.handle.window == nswindow) return w;
    }
    return null;
}

/// Detach the delegates, close the window and drop our references. The
/// release is deferred to the enclosing autorelease pool so a window can be
/// torn down from inside its own delegate or webview callbacks.
fn teardown(handle: WindowHandle) void {
    if (handle.hookWindow()) |w| hooks.destroyed(handle.label, w, handle.hookView());
    // The Objective-C platform hooks (.macos.hooks), at the same moment.
    if (handle.webview != null) apple_hooks.webViewDestroyed(handle.webview);
    apple_hooks.windowWillClose(handle.window);
    allowOverlayKey(handle.window, false);
    if (comptime build_opts.native_ui) if (handle.native) |p| {
        // The window must not keep pointing at the view (its initial first
        // responder is unretained).
        const w = handle.nsWindow();
        w.msgSend(void, "setInitialFirstResponder:", .{apple.nil});
        _ = w.msgSend(apple.c.BOOL, "makeFirstResponder:", .{apple.nil});
        w.msgSend(void, "setContentView:", .{apple.nil});
        native.destroy(@ptrCast(@alignCast(p)));
    };
    const view = handle.webView();
    if (handle.webview) |v| isolation.forget(@intFromPtr(v));
    view.msgSend(void, "setNavigationDelegate:", .{apple.nil});
    view.msgSend(void, "setUIDelegate:", .{apple.nil});
    view.msgSend(void, "stopLoading", .{});
    const content = view.msgSend(Object, "configuration", .{}).msgSend(Object, "userContentController", .{});
    content.msgSend(void, "removeAllScriptMessageHandlers", .{});

    const win = handle.nsWindow();
    win.msgSend(void, "setDelegate:", .{apple.nil});
    win.msgSend(void, "orderOut:", .{apple.nil});
    win.msgSend(void, "close", .{});
    _ = view.msgSend(Object, "autorelease", .{});
    _ = win.msgSend(Object, "autorelease", .{});
}

/// Undo `createWindow` for a window that never made it into the window list.
pub fn destroyWindow(handle: WindowHandle) void {
    teardown(handle);
}

/// The close sequence shared by the close button, `closeWindow` and JS.
fn closeNow(win: *App.Window) void {
    const was_key = apple.isTrue(win.handle.nsWindow().msgSend(apple.c.BOOL, "isKeyWindow", .{}));
    if (win.options.hide_on_close) {
        win.handle.nsWindow().msgSend(void, "orderOut:", .{apple.nil});
        if (was_key) returnFocus();
        return;
    }

    win.saveGeometry();
    internal.emit("window:closed", .{ .label = win.label });

    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    for (internal.windows_list.items, 0..) |w, i| {
        if (w == win) {
            _ = internal.windows_list.swapRemove(i);
            break;
        }
    }
    const remaining = internal.windows_list.items.len;
    internal.windows_mutex.unlock();

    teardown(win.handle);
    freeWindow(win);

    if (remaining == 0) return App.quit(0);
    if (was_key) returnFocus();
}

fn freeWindow(win: *App.Window) void {
    const gpa = @import("../../core/heap.zig").gpa;
    gpa.free(win.label);
    gpa.free(win.options.title);
    if (win.options.url) |u| gpa.free(u);
    gpa.destroy(win);
}

/// Shutdown: tear down every window still open (no events, the app is
/// exiting). Main thread, after the run loop.
pub fn destroyAllWindows() void {
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    while (true) {
        internal.ensureWindowsMutex();
        internal.windows_mutex.lock();
        const win = internal.windows_list.pop();
        internal.windows_mutex.unlock();
        const w = win orelse break;
        teardown(w.handle);
        freeWindow(w);
    }
}

var next_serial: std.atomic.Value(u64) = .init(1);

// ---------------------------------------------------------------------------
// Window creation and delegates
// ---------------------------------------------------------------------------

// WKNavigationActionPolicy
const policy_cancel: isize = 0;
const policy_allow: isize = 1;
// WKNavigationType
const nav_link_activated: isize = 0;
const nav_form_submitted: isize = 1;

pub fn WindowCreator(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime csp_z: ?[:0]const u8,
) type {
    const SchemeImpl = scheme_mod.Scheme(config, local, csp_z);
    const BridgeImpl = bridge_mod.Bridge(api, config, local);

    return struct {
        // Shared delegate/handler instances (+1 each), alive between init and deinit.
        var window_delegate: Object = apple.nil;
        var nav_delegate: Object = apple.nil;
        var message_handler: Object = apple.nil;
        var scheme_handler: Object = apple.nil;
        /// NSWindow subclass: a borderless window (`decorations = false`)
        /// can still become key and main, so it takes keyboard input (plain
        /// NSWindow refuses for borderless windows). Overlays get
        /// `overlay_class` (see `focusable_overlays`).
        var window_class: ?apple.Class = null;
        var overlay_class: ?apple.Class = null;
        var workspace_observer: Object = apple.nil;

        var window_open_counter = std.atomic.Value(u32).init(1);
        var dev_retries_left: u32 = 0;

        pub fn init() void {
            if (config.app.dev) |dev| dev_retries_left = dev.timeout_ms / dev_retry_interval_ms;

            window_delegate = apple.new(apple.defineClass("OrielWindowDelegate", &.{"NSWindowDelegate"}, .{
                .{ "windowShouldClose:", windowShouldClose },
                .{ "windowDidResignKey:", windowDidResignKey },
            }));
            nav_delegate = apple.new(apple.defineClass("OrielNavigationDelegate", &.{ "WKNavigationDelegate", "WKUIDelegate" }, .{
                .{ "webView:decidePolicyForNavigationAction:decisionHandler:", decidePolicy },
                .{ "webView:didFailProvisionalNavigation:withError:", didFailProvisionalNavigation },
                .{ "webViewWebContentProcessDidTerminate:", webContentProcessDidTerminate },
                .{ "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", createWebView },
                .{ "webViewDidClose:", webViewDidClose },
                .{ "webView:didFinishNavigation:", didFinishNavigation },
                .{ "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", requestMediaCapture },
            } ++ js_dialogs.methods));
            message_handler = apple.new(BridgeImpl.handlerClass());
            scheme_handler = apple.new(SchemeImpl.handlerClass());
            window_class = apple.defineSubclass("OrielWindow", "NSWindow", &.{}, .{
                .{ "canBecomeKeyWindow", canBecome },
                .{ "canBecomeMainWindow", canBecome },
            });
            overlay_class = apple.defineSubclass("OrielOverlayWindow", "NSWindow", &.{}, .{
                .{ "canBecomeKeyWindow", overlayCanBecome },
                .{ "canBecomeMainWindow", overlayCanBecome },
            });
            workspace_observer = apple.new(apple.defineClass("OrielWorkspaceObserver", &.{}, .{
                .{ "appActivated:", appActivated },
            }));
            const center = apple.class("NSWorkspace").msgSend(Object, "sharedWorkspace", .{}).msgSend(Object, "notificationCenter", .{});
            if (apple.nsString("NSWorkspaceDidActivateApplicationNotification")) |name| {
                defer name.release();
                center.msgSend(void, "addObserver:selector:name:object:", .{ workspace_observer, objc.sel("appActivated:"), name, apple.nil });
            }
        }

        fn canBecome(_: apple.id, _: apple.c.SEL) callconv(.c) apple.c.BOOL {
            return apple.boolean(true);
        }

        pub fn deinit() void {
            if (workspace_observer.value != null) {
                const center = apple.class("NSWorkspace").msgSend(Object, "sharedWorkspace", .{}).msgSend(Object, "notificationCenter", .{});
                center.msgSend(void, "removeObserver:", .{workspace_observer});
            }
            inline for (.{ &window_delegate, &nav_delegate, &message_handler, &scheme_handler, &workspace_observer }) |obj| {
                obj.*.release();
                obj.* = apple.nil;
            }
        }

        pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            if (!apple.isMainThread()) return error.NotMainThread;
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            const gpa = std.heap.smp_allocator;

            var style: c_ulong = 0; // borderless without decorations
            if (options.decorations) {
                style = style_titled | style_closable | style_miniaturizable;
                if (options.resizable) style |= style_resizable;
            }
            const rect: apple.NSRect = .{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = @floatFromInt(options.width), .height = @floatFromInt(options.height) },
            };
            const cls = (if (options.focus_on_show) window_class else overlay_class) orelse apple.class("NSWindow");
            const win = cls.msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, NSBackingStoreBuffered, apple.boolean(false) });
            if (win.value == null) return error.CreateWindowFailed;
            errdefer win.release();
            // We own the window and release it in teardown.
            win.msgSend(void, "setReleasedWhenClosed:", .{apple.boolean(false)});
            win.msgSend(void, "setCollectionBehavior:", .{win.msgSend(c_ulong, "collectionBehavior", .{}) | NSWindowCollectionBehaviorFullScreenPrimary});
            if (apple.nsString(options.title)) |title| {
                defer title.release();
                win.msgSend(void, "setTitle:", .{title});
            }
            if (options.min_width != null or options.min_height != null) {
                win.msgSend(void, "setContentMinSize:", .{apple.NSSize{
                    .width = @floatFromInt(options.min_width orelse 0),
                    .height = @floatFromInt(options.min_height orelse 0),
                }});
            }
            if (options.max_width != null or options.max_height != null) {
                const huge: f64 = std.math.floatMax(f32);
                win.msgSend(void, "setContentMaxSize:", .{apple.NSSize{
                    .width = if (options.max_width) |w| @floatFromInt(w) else huge,
                    .height = if (options.max_height) |h| @floatFromInt(h) else huge,
                }});
            }
            win.msgSend(void, "center", .{});

            if (comptime build_opts.native_ui) return createNativeWindow(win, options, win_inst);

            const wk_config = apple.new(apple.class("WKWebViewConfiguration"));
            defer wk_config.release(); // the webview copies it
            const scheme_name = apple.nsString(scheme_mod.scheme_name) orelse return error.OutOfMemory;
            defer scheme_name.release();
            wk_config.msgSend(void, "setURLSchemeHandler:forURLScheme:", .{ scheme_handler, scheme_name });
            const content = wk_config.msgSend(Object, "userContentController", .{});
            try BridgeImpl.setupUserContent(content, message_handler, options.label);
            apple_hooks.webViewConfiguration(wk_config.value, options.label);
            // getUserMedia: WKWebView only exposes navigator.mediaDevices with
            // this (private, long-standing) preference on. Enabled only for
            // apps that declare the microphone or camera; every request still
            // goes through requestMediaCapture (allowForPage), then TCC.
            if (comptime (config.app.permissions.has(.microphone) or config.app.permissions.has(.camera))) {
                const prefs = wk_config.msgSend(Object, "preferences", .{});
                if (prefs.getClass().?.respondsToSelector(objc.sel("_setMediaDevicesEnabled:"))) {
                    prefs.msgSend(void, "_setMediaDevicesEnabled:", .{apple.boolean(true)});
                }
            }

            const view = apple.class("WKWebView").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithFrame:configuration:", .{ rect, wk_config });
            if (view.value == null) return error.CreateWebViewFailed;
            errdefer view.release();
            view.msgSend(void, "setNavigationDelegate:", .{nav_delegate});
            view.msgSend(void, "setUIDelegate:", .{nav_delegate});
            if (config.devtools and view.getClass().?.respondsToSelector(objc.sel("setInspectable:"))) {
                view.msgSend(void, "setInspectable:", .{apple.boolean(true)}); // macOS 13.3+
            }
            win.msgSend(void, "setContentView:", .{view});
            // Keys go to the page (a borderless window doesn't pick its
            // content view on its own).
            win.msgSend(void, "setInitialFirstResponder:", .{view});
            _ = win.msgSend(apple.c.BOOL, "makeFirstResponder:", .{view});
            win.msgSend(void, "setDelegate:", .{window_delegate});
            overlay.setup(win, view, options);

            const target_uri = try security.resolveWindowUrl(
                gpa,
                config.security,
                local,
                if (config.app.dev) |d| d.url else null,
                options.url,
                config.start,
            );
            defer gpa.free(target_uri);
            const handle: WindowHandle = .{ .window = win.value, .webview = view.value, .serial = next_serial.fetchAdd(1, .monotonic), .label = options.label };
            if (handle.hookWindow()) |w| hooks.created(options.label, w, handle.hookView());
            errdefer if (handle.hookWindow()) |w| hooks.destroyed(options.label, w, handle.hookView());
            apple_hooks.windowCreated(win.value, options.label);
            errdefer apple_hooks.windowWillClose(win.value);
            apple_hooks.webViewCreated(view.value, options.label);
            errdefer apple_hooks.webViewDestroyed(view.value);
            try load(view, target_uri);

            return handle;
        }

        /// -Dnative_ui: the page's HTML, CSS and JS run on the native renderer
        /// (QuickJS, Yoga, CoreGraphics/CoreText and AppKit fields), no WebKit.
        fn createNativeWindow(win: Object, options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            const surface = try native.create(
                std.heap.smp_allocator,
                config.app.assets,
                @import("../../core/features.zig").platform_json,
                options.label,
                options.url orelse "index.html",
                @floatFromInt(options.width),
                @floatFromInt(options.height),
                options.transparent,
                BridgeImpl.nativeInvoke,
                win_inst,
            );
            errdefer native.destroy(surface);
            win.msgSend(void, "setContentView:", .{surface.view});
            // An sRGB backing store, as WebKit's layers: CSS colors blend in
            // sRGB (a translucent fill over white as in WKWebView), and the
            // window server matches the result to the display.
            win.msgSend(void, "setColorSpace:", .{apple.class("NSColorSpace").msgSend(apple.Object, "sRGBColorSpace", .{})});
            win.msgSend(void, "setInitialFirstResponder:", .{surface.view});
            _ = win.msgSend(apple.c.BOOL, "makeFirstResponder:", .{surface.view});
            win.msgSend(void, "setAcceptsMouseMovedEvents:", .{apple.boolean(true)});
            win.msgSend(void, "setDelegate:", .{window_delegate});
            // Transparency and overlay placement (always on top, placement),
            // as for a web view window.
            overlay.setup(win, apple.nil, options);
            const handle: WindowHandle = .{ .window = win.value, .webview = null, .serial = next_serial.fetchAdd(1, .monotonic), .native = surface, .label = options.label };
            if (handle.hookWindow()) |w| hooks.created(options.label, w, null);
            apple_hooks.windowCreated(win.value, options.label);
            return handle;
        }

        fn load(view: Object, uri: []const u8) !void {
            const str = apple.nsString(uri) orelse return error.InvalidUrl;
            defer str.release();
            const url = apple.class("NSURL").msgSend(Object, "URLWithString:", .{str});
            if (url.value == null) return error.InvalidUrl;
            const request = apple.class("NSURLRequest").msgSend(Object, "requestWithURL:", .{url});
            _ = view.msgSend(Object, "loadRequest:", .{request});
        }

        fn windowShouldClose(_: apple.id, _: apple.c.SEL, sender: apple.id) callconv(.c) apple.c.BOOL {
            const w = getWindowByNSWindow(sender) orelse return apple.boolean(true);
            if (!w.ready) {
                w.pending_close = true;
                return apple.boolean(false);
            }
            closeNow(w);
            return apple.boolean(false); // closeNow closed it (or hid it)
        }

        /// Borrowed UTF-8 URL of a navigation action's request.
        fn actionUrl(action: Object) ?[:0]const u8 {
            return apple.urlString(action.msgSend(Object, "request", .{}).msgSend(Object, "URL", .{}));
        }

        fn isUserGesture(action: Object) bool {
            const kind = action.msgSend(isize, "navigationType", .{});
            return kind == nav_link_activated or kind == nav_form_submitted;
        }

        /// getUserMedia (WKUIDelegate, macOS 12+): granted only when the app
        /// declares every requested device and the page's origin is trusted
        /// (permissions.allowForPage); TCC then asks the user on first use.
        fn requestMediaCapture(_: apple.id, _: apple.c.SEL, webview: apple.id, origin_id: apple.id, frame_id: apple.id, capture_type: i64, handler: apple.id) callconv(.c) void {
            // A platform hook that returns YES owns the decision.
            if (apple_hooks.intercept(.media_capture, .{ webview, origin_id, frame_id, @as(isize, @intCast(capture_type)), handler })) return;
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            // WKMediaCaptureType: camera 0, microphone 1, camera and microphone 2.
            const kinds: []const permissions.Kind = switch (capture_type) {
                0 => &.{.camera},
                1 => &.{.microphone},
                2 => &.{ .camera, .microphone },
                else => &.{},
            };
            var url_buf: [1024]u8 = undefined;
            const page = frameUrl(&url_buf, frame_id, origin_id);
            var allow = kinds.len > 0;
            for (kinds) |k| {
                if (!permissions.allowForPage(k, local, page)) allow = false;
            }
            // WKPermissionDecision: grant 1, deny 2.
            apple.callBlock(handler, &.{isize}, .{if (allow) 1 else 2});
        }

        /// The requesting frame's URL, else `scheme://host[:port]` from its
        /// WKSecurityOrigin (borrowed / in `buf`).
        fn frameUrl(buf: []u8, frame_id: apple.id, origin_id: apple.id) []const u8 {
            if (frame_id != null) {
                const req = (Object{ .value = frame_id }).msgSend(Object, "request", .{});
                if (req.value != null) if (apple.urlString(req.msgSend(Object, "URL", .{}))) |u| {
                    // about:blank/srcdoc, blob: and data: frames inherit their
                    // origin: judge them by the WKSecurityOrigin instead.
                    const inherits = std.mem.startsWith(u8, u, "about:") or std.mem.startsWith(u8, u, "blob:") or std.mem.startsWith(u8, u, "data:");
                    if (u.len > 0 and !inherits) return u;
                };
            }
            if (origin_id == null) return "";
            const origin: Object = .{ .value = origin_id };
            const scheme = apple.utf8(origin.msgSend(Object, "protocol", .{})) orelse return "";
            const host = apple.utf8(origin.msgSend(Object, "host", .{})) orelse return "";
            const port = origin.msgSend(isize, "port", .{});
            return (if (port > 0)
                std.fmt.bufPrint(buf, "{s}://{s}:{d}/", .{ scheme, host, port })
            else
                std.fmt.bufPrint(buf, "{s}://{s}/", .{ scheme, host })) catch "";
        }

        fn decidePolicy(_: apple.id, _: apple.c.SEL, webview: apple.id, action_id: apple.id, handler: apple.id) callconv(.c) void {
            // A platform hook that returns YES owns the decision.
            if (apple_hooks.intercept(.decide_policy, .{ webview, action_id, handler })) return;
            const action: Object = .{ .value = action_id };
            const uri = actionUrl(action) orelse {
                apple.callBlock(handler, &.{isize}, .{policy_cancel});
                return;
            };
            if (comptime config.app.isolation != null) {
                if (isIsolationFrame(action, uri)) {
                    apple.callBlock(handler, &.{isize}, .{policy_allow});
                    return;
                }
            }
            const verdict = security.navigation(config.security, local, uri, isUserGesture(action));
            // No target frame: a new-window request (target="_blank"). An
            // allowed one continues to `createWebView`, which decides where it opens.
            const new_window = action.msgSend(Object, "targetFrame", .{}).value == null;
            switch (verdict) {
                .allow => {
                    apple.callBlock(handler, &.{isize}, .{policy_allow});
                    return;
                },
                .open_external => {
                    apple.callBlock(handler, &.{isize}, .{policy_cancel});
                    App.openExternal(uri.ptr);
                },
                .block => {
                    apple.callBlock(handler, &.{isize}, .{policy_cancel});
                    log.warn("blocked {s} to {s}", .{ if (new_window) "new window" else "navigation", uri });
                },
            }
        }

        /// The bridge's isolation frame: an iframe (never the top frame or a
        /// new window) loading the isolation origin.
        fn isIsolationFrame(action: Object, uri: []const u8) bool {
            const target = action.msgSend(Object, "targetFrame", .{});
            if (target.value == null or apple.isTrue(target.msgSend(apple.c.BOOL, "isMainFrame", .{}))) return false;
            var buf: [512]u8 = undefined;
            const o = security.origin(&buf, uri) orelse return false;
            return std.mem.eql(u8, o, isolation.origin);
        }

        /// `window.open` and allowed `target="_blank"` navigations: open an
        /// Oriel window or load in the main view (`config.window_open`); never
        /// a WebKit-managed popup.
        fn createWebView(_: apple.id, _: apple.c.SEL, _: apple.id, _: apple.id, action_id: apple.id, _: apple.id) callconv(.c) apple.id {
            const action: Object = .{ .value = action_id };
            const uri = actionUrl(action) orelse return null;
            switch (security.navigation(config.security, local, uri, isUserGesture(action))) {
                .allow => {
                    var obuf: [512]u8 = undefined;
                    const o = security.origin(&obuf, uri);
                    if (config.window_open == .new_window and o != null and local.contains(o.?)) {
                        const id = window_open_counter.fetchAdd(1, .monotonic);
                        var label_buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrintZ(&label_buf, "win-{d}", .{id}) catch return null;
                        _ = App.openWindow(.{ .label = label, .url = uri }) catch |err| log.err("window.open failed: {s}", .{@errorName(err)});
                    } else if (App.getWindow("main")) |mw| {
                        load(mw.handle.webView(), uri) catch |err| log.err("window.open failed: {s}", .{@errorName(err)});
                    }
                },
                .open_external => App.openExternal(uri.ptr),
                .block => log.warn("blocked new window to {s}", .{uri}),
            }
            return null;
        }

        /// `window.close()` from the page.
        fn webViewDidClose(_: apple.id, _: apple.c.SEL, view: apple.id) callconv(.c) void {
            if (getWindowByView(view)) |w| postCloseWindow(w.handle);
        }

        fn webContentProcessDidTerminate(_: apple.id, _: apple.c.SEL, view: apple.id) callconv(.c) void {
            log.err("web content process terminated; reloading", .{});
            _ = (Object{ .value = view }).msgSend(Object, "reload", .{});
        }

        /// Debugging aid for machines where screen capture needs a Screen
        /// Recording grant: `ORIEL_SNAPSHOT=/path/shot.png` saves the main
        /// window's page once, a second (`ORIEL_SNAPSHOT_DELAY_MS`) after its
        /// first load finished (like
        /// `SHOT=` under scripts/headless.sh on Linux).
        fn didFinishNavigation(_: apple.id, _: apple.c.SEL, view: apple.id, _: apple.id) callconv(.c) void {
            if (snapshot_taken) return;
            if (std.c.getenv("ORIEL_SNAPSHOT") == null) return;
            const w = getWindowByView(view) orelse return;
            if (!std.mem.eql(u8, w.label, "main")) return;
            snapshot_taken = true;
            // Until the snapshot ran; leaked if the app quits first (debug-only path).
            _ = (Object{ .value = view }).retain();
            const delay_ms = if (std.c.getenv("ORIEL_SNAPSHOT_DELAY_MS")) |d| std.fmt.parseInt(u32, std.mem.span(d), 10) catch 1000 else 1000;
            apple.afterMain(delay_ms, view, &takeSnapshot);
        }

        var snapshot_taken = false;

        fn takeSnapshot(ctx: ?*anyopaque) callconv(.c) void {
            const view: Object = .{ .value = @ptrCast(@alignCast(ctx)) };
            defer view.release();
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            view.msgSend(void, "takeSnapshotWithConfiguration:completionHandler:", .{ apple.nil, apple.globalBlock(snapshotDone) });
        }

        fn snapshotDone(_: *apple.BlockLiteral, image_id: apple.id, _: apple.id) callconv(.c) void {
            const path = std.c.getenv("ORIEL_SNAPSHOT") orelse return;
            const image: Object = .{ .value = image_id };
            if (image.value == null) {
                log.err("ORIEL_SNAPSHOT: WebKit returned no image", .{});
                return;
            }
            const tiff = image.msgSend(Object, "TIFFRepresentation", .{});
            const rep = apple.class("NSBitmapImageRep").msgSend(Object, "imageRepWithData:", .{tiff});
            const NSBitmapImageFileTypePNG: c_ulong = 4;
            const png = if (rep.value != null) rep.msgSend(Object, "representationUsingType:properties:", .{
                NSBitmapImageFileTypePNG, apple.class("NSDictionary").msgSend(Object, "dictionary", .{}),
            }) else apple.nil;
            const path_ns = apple.nsString(std.mem.span(path)) orelse return;
            defer path_ns.release();
            if (png.value == null or !apple.isTrue(png.msgSend(apple.c.BOOL, "writeToFile:atomically:", .{ path_ns, apple.boolean(true) }))) {
                log.err("ORIEL_SNAPSHOT: could not write {s}", .{path});
                return;
            }
            log.info("ORIEL_SNAPSHOT: wrote {s}", .{path});
        }

        // Dev mode: the dev server may still be starting; retry the dev URL
        // (like the Linux backend) until `dev.timeout_ms` is used up.
        const dev_retry_interval_ms = 250;

        fn didFailProvisionalNavigation(_: apple.id, _: apple.c.SEL, view: apple.id, _: apple.id, err: apple.id) callconv(.c) void {
            const failure: Object = .{ .value = err };
            const code = failure.msgSend(isize, "code", .{});
            if (config.app.dev == null or dev_retries_left == 0) {
                if (code != -999) log.warn("load failed (NSURLError {d})", .{code}); // -999: cancelled by our policy
                return;
            }
            dev_retries_left -= 1;
            // Keep the webview alive until the retry ran (it may be closed
            // meanwhile). Leaked if the app quits within the retry interval: the
            // main queue isn't serviced after the run loop (dev builds only).
            _ = (Object{ .value = view }).retain();
            apple.afterMain(dev_retry_interval_ms, view, &retryDevLoad);
        }

        fn retryDevLoad(ctx: ?*anyopaque) callconv(.c) void {
            const view: Object = .{ .value = @ptrCast(@alignCast(ctx)) };
            defer view.release();
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            if (getWindowByView(view.value) == null) return; // closed while waiting
            load(view, config.app.dev.?.url) catch |err| log.err("dev reload failed: {s}", .{@errorName(err)});
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
