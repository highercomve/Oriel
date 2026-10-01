//! iOS windows: a WKWebView in a view controller, shown in a UIWindowScene.
//!
//! A window's controller and webview are created at once (`createWindow`)
//! and live until the window is destroyed; scenes come and go. The first
//! scene the system connects shows the main window. Other windows get a
//! scene of their own where the device has several (iPad: Stage Manager,
//! Split View); on iPhone they are presented full screen over the main
//! window, and closing them dismisses them.
//!
//! UIKit is main-thread only: operations from other threads are forwarded.

const std = @import("std");
const apple = @import("apple.zig");
const Object = apple.Object;
const ShellMod = @import("Shell.zig");
const scheme_mod = @import("scheme.zig");
const bridge_mod = @import("bridge.zig");
const js_dialogs = @import("js_dialogs.zig");
const permissions = @import("../../core/permissions.zig");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");

const log = std.log.scoped(.oriel);

pub const WindowHandle = struct {
    /// The window's view controller (+1).
    controller: apple.id,
    /// Its WKWebView (+1).
    webview: apple.id,
    /// Unique per window for the run (a queued copy must not match a new
    /// window at a reused address).
    serial: u64,

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.serial == other.serial;
    }
};

pub const WindowSize = struct {
    width: c_int,
    height: c_int,
};

/// Per-window UIKit state (main thread).
const State = struct {
    /// The UIWindow showing the window, when it has a scene of its own.
    ui_window: apple.id = null,
    /// Presented over the main window (iPhone).
    presented: bool = false,
    fullscreen: bool = false,
    maximized: bool = false,
    /// Layout constraints (NSArray, +1) pinning the webview to the safe area
    /// (clear of the status bar, the Dynamic Island and the home indicator)
    /// and, in fullscreen, to the whole screen.
    safe_constraints: apple.id = null,
    full_constraints: apple.id = null,
};

/// Pin `inner`'s edges to `outer`'s (a view or a layout guide): an
/// NSArray of four constraints (+1), not yet active.
fn edgeConstraints(inner: Object, outer: Object) Object {
    var list: [4]apple.id = undefined;
    inline for (.{ "topAnchor", "bottomAnchor", "leadingAnchor", "trailingAnchor" }, 0..) |anchor, i| {
        list[i] = inner.msgSend(Object, anchor, .{})
            .msgSend(Object, "constraintEqualToAnchor:", .{outer.msgSend(Object, anchor, .{})}).value;
    }
    return apple.class("NSArray").msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithObjects:count:", .{ @as([*]const apple.id, &list), @as(c_ulong, list.len) });
}

/// Activate the constraints for the window's fullscreen state.
fn applyLayout(st: *State) void {
    if (st.safe_constraints == null or st.full_constraints == null) return;
    const cls = apple.class("NSLayoutConstraint");
    const off: Object = .{ .value = if (st.fullscreen) st.safe_constraints else st.full_constraints };
    const on: Object = .{ .value = if (st.fullscreen) st.full_constraints else st.safe_constraints };
    cls.msgSend(void, "deactivateConstraints:", .{off});
    cls.msgSend(void, "activateConstraints:", .{on});
}

var states: std.AutoHashMapUnmanaged(u64, State) = .empty;
var next_serial: std.atomic.Value(u64) = .init(1);

fn state(serial: u64) ?*State {
    return states.getPtr(serial);
}

// ---------------------------------------------------------------------------
// Operations
// ---------------------------------------------------------------------------

const Op = union(enum) {
    show,
    hide,
    focus,
    close,
    title: [:0]u8,
    fullscreen: bool,
    maximized: bool,
};

fn apply(handle: WindowHandle, op: Op) void {
    switch (op) {
        .show, .focus => show(handle),
        .hide => hide(handle),
        .close => if (App.getWindowByHandle(handle)) |w| closeNow(w),
        .title => |t| {
            const str = apple.nsString(t) orelse return;
            defer str.release();
            (Object{ .value = handle.controller }).msgSend(void, "setTitle:", .{str});
            if (state(handle.serial)) |st| if (st.ui_window != null) {
                const scene = (Object{ .value = st.ui_window }).msgSend(Object, "windowScene", .{});
                if (scene.value != null) scene.msgSend(void, "setTitle:", .{str});
            };
        },
        .fullscreen => |on| if (state(handle.serial)) |st| {
            st.fullscreen = on;
            applyLayout(st);
            (Object{ .value = handle.controller }).msgSend(void, "setNeedsStatusBarAppearanceUpdate", .{});
        },
        .maximized => |on| if (state(handle.serial)) |st| {
            st.maximized = on;
        },
    }
}

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
            if (App.getWindowByHandle(self.handle) != null) apply(self.handle, self.op);
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

fn query(comptime T: type, handle: WindowHandle, comptime get: fn (WindowHandle) T, fallback: T) T {
    if (apple.isMainThread()) return get(handle);
    const Ctx = struct {
        handle: WindowHandle,
        result: T,
        fn run(self: *@This()) void {
            if (App.getWindowByHandle(self.handle) != null) self.result = get(self.handle);
        }
    };
    var ctx: Ctx = .{ .handle = handle, .result = fallback };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch return fallback;
    return ctx.result;
}

const UIModalPresentationFullScreen: isize = 0;

fn isMain(handle: WindowHandle) bool {
    const w = App.getWindowByHandle(handle) orelse return false;
    return std.mem.eql(u8, w.label, "main");
}

fn show(handle: WindowHandle) void {
    const st = state(handle.serial) orelse return;
    if (st.ui_window != null) {
        (Object{ .value = st.ui_window }).msgSend(void, "makeKeyAndVisible", .{});
        return;
    }
    if (st.presented) return;
    // The main window appears when the system connects the first scene.
    if (isMain(handle)) return;
    // A scene of its own on iPad. The Info.plist always declares multiple
    // scenes, so supportsMultipleScenes is YES on iPhone too, where asking
    // for a scene silently does nothing: check the idiom as well.
    const app = ShellMod.sharedApplication();
    const idiom = apple.class("UIDevice").msgSend(Object, "currentDevice", .{}).msgSend(isize, "userInterfaceIdiom", .{});
    if (idiom == UIUserInterfaceIdiomPad and apple.isTrue(app.msgSend(apple.c.BOOL, "supportsMultipleScenes", .{}))) {
        ShellMod.requestScene(handle.serial);
        return;
    }
    // One scene (iPhone): present over the window in front.
    const host = ShellMod.mainController() orelse return;
    const top = topPresented(host);
    const controller: Object = .{ .value = handle.controller };
    controller.msgSend(void, "setModalPresentationStyle:", .{UIModalPresentationFullScreen});
    top.msgSend(void, "presentViewController:animated:completion:", .{ controller, apple.boolean(true), @as(apple.id, null) });
    st.presented = true;
}

const UIUserInterfaceIdiomPad: isize = 1;

fn topPresented(controller: Object) Object {
    var top = controller;
    while (true) {
        const next = top.msgSend(Object, "presentedViewController", .{});
        if (next.value == null) return top;
        top = next;
    }
}

fn hide(handle: WindowHandle) void {
    const st = state(handle.serial) orelse return;
    if (st.presented) {
        (Object{ .value = handle.controller }).msgSend(void, "dismissViewControllerAnimated:completion:", .{ apple.boolean(true), @as(apple.id, null) });
        st.presented = false;
        return;
    }
    // A scene of its own (iPad): close the scene; the window lives on and
    // `show` requests a new one.
    if (st.ui_window != null and !isMain(handle)) ShellMod.destroySceneOf(st.ui_window);
}

pub fn showWindow(handle: WindowHandle) void {
    perform(handle, .show);
}

pub fn hideWindow(handle: WindowHandle) void {
    perform(handle, .hide);
}

pub fn toggleWindow(handle: WindowHandle) void {
    if (query(bool, handle, isShownNow, false)) hideWindow(handle) else showWindow(handle);
}

fn isShownNow(handle: WindowHandle) bool {
    const st = state(handle.serial) orelse return false;
    return st.presented or st.ui_window != null;
}

pub fn focusWindow(handle: WindowHandle) void {
    perform(handle, .focus);
}

pub fn closeWindow(handle: WindowHandle) void {
    perform(handle, .close);
}

pub fn postCloseWindow(handle: WindowHandle) void {
    const Task = struct {
        fn run(ctx: ?*anyopaque) void {
            const h: *WindowHandle = @ptrCast(@alignCast(ctx.?));
            defer std.heap.smp_allocator.destroy(h);
            if (App.getWindowByHandle(h.*)) |w| closeNow(w);
        }
        fn cleanup(ctx: ?*anyopaque) void {
            std.heap.smp_allocator.destroy(@as(*WindowHandle, @ptrCast(@alignCast(ctx.?))));
        }
    };
    const copy = std.heap.smp_allocator.create(WindowHandle) catch return;
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
    return if (state(handle.serial)) |st| st.fullscreen else false;
}

pub fn isWindowFullscreen(handle: WindowHandle) bool {
    return query(bool, handle, isFullscreenNow, false);
}

/// The system sizes windows on iOS: the state is kept and reported.
pub fn setWindowMaximized(handle: WindowHandle, maximized: bool) void {
    perform(handle, .{ .maximized = maximized });
}

fn isMaximizedNow(handle: WindowHandle) bool {
    return if (state(handle.serial)) |st| st.maximized else false;
}

pub fn isWindowMaximized(handle: WindowHandle) bool {
    return query(bool, handle, isMaximizedNow, false);
}

/// iOS apps don't size their windows.
pub fn setWindowSize(handle: WindowHandle, width: c_int, height: c_int) void {
    _ = handle;
    _ = width;
    _ = height;
}

fn sizeNow(handle: WindowHandle) WindowSize {
    const bounds = (Object{ .value = handle.webview }).msgSend(apple.CGRect, "bounds", .{});
    return .{ .width = @intFromFloat(bounds.size.width), .height = @intFromFloat(bounds.size.height) };
}

/// The page's size in points (CSS pixels).
pub fn getWindowSize(handle: WindowHandle) WindowSize {
    return query(WindowSize, handle, sizeNow, .{ .width = 0, .height = 0 });
}

pub fn setWindowPlacement(handle: WindowHandle, placement: App.Placement) void {
    _ = handle;
    _ = placement;
}

pub fn setWindowClickThrough(handle: WindowHandle, enabled: bool) void {
    _ = handle;
    _ = enabled;
}

pub fn setWindowAlwaysOnTop(handle: WindowHandle, enabled: bool) void {
    _ = handle;
    _ = enabled;
}

fn workAreaNow(_: WindowHandle) ?App.Rect {
    const screen = apple.class("UIScreen").msgSend(Object, "mainScreen", .{});
    const b = screen.msgSend(apple.CGRect, "bounds", .{});
    return .{ .x = 0, .y = 0, .width = @intFromFloat(b.size.width), .height = @intFromFloat(b.size.height) };
}

/// The screen, in points.
pub fn getWindowWorkArea(handle: WindowHandle) ?App.Rect {
    return query(?App.Rect, handle, workAreaNow, null);
}

pub fn startWindowDrag(handle: WindowHandle) App.DragMode {
    _ = handle;
    return .unsupported;
}

pub fn openExternal(uri: [*:0]const u8) void {
    const S = struct {
        fn open(ctx: ?*anyopaque) void {
            const s: [*:0]u8 = @ptrCast(ctx.?);
            defer std.heap.smp_allocator.free(std.mem.span(s));
            const url = apple.nsUrl(std.mem.span(s));
            if (url.value == null) {
                log.err("could not open {s}: invalid URL", .{s});
                return;
            }
            const options = apple.class("NSDictionary").msgSend(Object, "dictionary", .{});
            ShellMod.sharedApplication().msgSend(void, "openURL:options:completionHandler:", .{ url, options, @as(apple.id, null) });
        }
        fn drop(ctx: ?*anyopaque) void {
            const s: [*:0]u8 = @ptrCast(ctx.?);
            std.heap.smp_allocator.free(std.mem.span(s));
        }
    };
    const copy = std.heap.smp_allocator.dupeZ(u8, std.mem.span(uri)) catch return;
    if (apple.isMainThread()) return S.open(copy.ptr);
    ShellMod.dispatchWithCleanup(&S.open, copy.ptr, &S.drop);
}

// ---------------------------------------------------------------------------
// Lookup, scenes and teardown
// ---------------------------------------------------------------------------

pub fn getWindowByView(view: apple.id) ?*App.Window {
    if (view == null) return null;
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |w| {
        if (w.handle.webview == view) return w;
    }
    return null;
}

fn getWindowBySerial(serial: u64) ?*App.Window {
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |w| {
        if (w.handle.serial == serial) return w;
    }
    return null;
}

/// The controller to present from for `view` (JS dialogs, pickers).
pub fn controllerForView(view: apple.id) ?Object {
    const w = getWindowByView(view) orelse return null;
    return topPresented(.{ .value = w.handle.controller });
}

/// The controller in front of the main window (to present pickers from).
pub fn frontController() ?Object {
    const host = ShellMod.mainController() orelse return null;
    return topPresented(host);
}

/// A scene connected (Shell's scene delegate): show window `serial` in it
/// (0: the main window). Returns the UIWindow (+1, the scene delegate keeps
/// it), or null when there's nothing to show.
pub fn attachToScene(scene: Object, serial: u64) ?Object {
    const w = (if (serial == 0) App.getWindow("main") else getWindowBySerial(serial)) orelse return null;
    const st = state(w.handle.serial) orelse return null;
    if (st.presented) {
        (Object{ .value = w.handle.controller }).msgSend(void, "dismissViewControllerAnimated:completion:", .{ apple.boolean(false), @as(apple.id, null) });
        st.presented = false;
    }
    const ui_window = apple.class("UIWindow").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithWindowScene:", .{scene});
    ui_window.msgSend(void, "setRootViewController:", .{Object{ .value = w.handle.controller }});
    ui_window.msgSend(void, "makeKeyAndVisible", .{});
    if (apple.nsString(w.options.title)) |t| {
        defer t.release();
        scene.msgSend(void, "setTitle:", .{t});
    }
    st.ui_window = ui_window.value;
    return ui_window;
}

/// A scene went away (the user closed it, or `hide`): its window stays.
pub fn detachFromScene(ui_window: apple.id) void {
    var it = states.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.ui_window == ui_window) {
            e.value_ptr.ui_window = null;
            (Object{ .value = ui_window }).msgSend(void, "setRootViewController:", .{apple.nil});
        }
    }
}

fn teardown(handle: WindowHandle) void {
    isolation.forget(@intFromPtr(handle.webview));
    const view: Object = .{ .value = handle.webview };
    view.msgSend(void, "setNavigationDelegate:", .{apple.nil});
    view.msgSend(void, "setUIDelegate:", .{apple.nil});
    view.msgSend(void, "stopLoading", .{});
    const content = view.msgSend(Object, "configuration", .{}).msgSend(Object, "userContentController", .{});
    content.msgSend(void, "removeAllScriptMessageHandlers", .{});
    if (states.fetchRemove(handle.serial)) |kv| {
        const st = kv.value;
        if (st.safe_constraints != null) (Object{ .value = st.safe_constraints }).release();
        if (st.full_constraints != null) (Object{ .value = st.full_constraints }).release();
        if (st.presented) (Object{ .value = handle.controller }).msgSend(void, "dismissViewControllerAnimated:completion:", .{ apple.boolean(true), @as(apple.id, null) });
        if (st.ui_window != null) {
            (Object{ .value = st.ui_window }).msgSend(void, "setRootViewController:", .{apple.nil});
            ShellMod.destroySceneOf(st.ui_window);
        }
    }
    _ = view.msgSend(Object, "autorelease", .{});
    _ = (Object{ .value = handle.controller }).msgSend(Object, "autorelease", .{});
}

pub fn destroyWindow(handle: WindowHandle) void {
    teardown(handle);
}

var current_on_close_hide = false;

/// The close sequence. The main window can't be closed on iOS (the system
/// owns the app's lifecycle): it only hides what's presented over it.
pub fn closeNow(win: *App.Window) void {
    const is_main = std.mem.eql(u8, win.label, "main");
    if (is_main or win.options.hide_on_close or current_on_close_hide) {
        if (!is_main) hide(win.handle);
        return;
    }
    win.saveGeometry();
    App.emit("window:closed", .{ .label = win.label });
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    for (App.windows_list.items, 0..) |w, i| {
        if (w == win) {
            _ = App.windows_list.swapRemove(i);
            break;
        }
    }
    App.windows_mutex.unlock();
    teardown(win.handle);
    freeWindow(win);
}

fn freeWindow(win: *App.Window) void {
    const gpa = std.heap.smp_allocator;
    gpa.free(win.label);
    gpa.free(win.options.title);
    if (win.options.url) |u| gpa.free(u);
    gpa.destroy(win);
}

pub fn destroyAllWindows() void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    while (true) {
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        const win = App.windows_list.pop();
        App.windows_mutex.unlock();
        const w = win orelse break;
        teardown(w.handle);
        freeWindow(w);
    }
}

// ---------------------------------------------------------------------------
// Creation and the WebKit delegates
// ---------------------------------------------------------------------------

// WKNavigationActionPolicy
const policy_cancel: isize = 0;
const policy_allow: isize = 1;
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
        var nav_delegate: Object = apple.nil;
        var message_handler: Object = apple.nil;
        var scheme_handler: Object = apple.nil;
        var controller_class: ?apple.Class = null;
        var window_open_counter = std.atomic.Value(u32).init(1);
        var dev_retries_left: u32 = 0;
        const dev_retry_interval_ms = 250;

        pub fn init() void {
            current_on_close_hide = config.on_close == .hide;
            if (config.dev) |dev| dev_retries_left = dev.timeout_ms / dev_retry_interval_ms;
            nav_delegate = apple.new(apple.defineClass("OrielNavigationDelegate", &.{ "WKNavigationDelegate", "WKUIDelegate" }, .{
                .{ "webView:decidePolicyForNavigationAction:decisionHandler:", decidePolicy },
                .{ "webView:didFailProvisionalNavigation:withError:", didFailProvisionalNavigation },
                .{ "webViewWebContentProcessDidTerminate:", webContentProcessDidTerminate },
                .{ "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", createWebView },
                .{ "webViewDidClose:", webViewDidClose },
                .{ "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", requestMediaCapture },
            } ++ js_dialogs.methods));
            message_handler = apple.new(BridgeImpl.handlerClass());
            scheme_handler = apple.new(SchemeImpl.handlerClass());
            controller_class = apple.defineSubclass("OrielViewController", "UIViewController", &.{}, .{
                .{ "prefersStatusBarHidden", prefersStatusBarHidden },
                .{ "prefersHomeIndicatorAutoHidden", prefersStatusBarHidden },
            });
        }

        pub fn deinit() void {
            inline for (.{ &nav_delegate, &message_handler, &scheme_handler }) |obj| {
                obj.*.release();
                obj.* = apple.nil;
            }
        }

        fn prefersStatusBarHidden(self: apple.id, _: apple.c.SEL) callconv(.c) apple.c.BOOL {
            App.ensureWindowsMutex();
            App.windows_mutex.lock();
            defer App.windows_mutex.unlock();
            for (App.windows_list.items) |w| {
                if (w.handle.controller == self) return apple.boolean(if (state(w.handle.serial)) |st| st.fullscreen else false);
            }
            return apple.boolean(false);
        }

        pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            _ = win_inst;
            if (!apple.isMainThread()) return error.NotMainThread;
            const pool = apple.objc.AutoreleasePool.init();
            defer pool.deinit();
            const gpa = std.heap.smp_allocator;

            const wk_config = apple.new(apple.class("WKWebViewConfiguration"));
            defer wk_config.release();
            const scheme_name = apple.nsString(scheme_mod.scheme_name) orelse return error.OutOfMemory;
            defer scheme_name.release();
            wk_config.msgSend(void, "setURLSchemeHandler:forURLScheme:", .{ scheme_handler, scheme_name });
            // Media plays in the page, without a tap first (like the desktop).
            wk_config.msgSend(void, "setAllowsInlineMediaPlayback:", .{apple.boolean(true)});
            wk_config.msgSend(void, "setMediaTypesRequiringUserActionForPlayback:", .{@as(c_ulong, 0)});
            const content = wk_config.msgSend(Object, "userContentController", .{});
            try BridgeImpl.setupUserContent(content, message_handler, options.label);

            const zero: apple.CGRect = .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } };
            const view = apple.class("WKWebView").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithFrame:configuration:", .{ zero, wk_config });
            if (view.value == null) return error.CreateWebViewFailed;
            errdefer view.release();
            view.msgSend(void, "setNavigationDelegate:", .{nav_delegate});
            view.msgSend(void, "setUIDelegate:", .{nav_delegate});
            if (options.transparent) {
                view.msgSend(void, "setOpaque:", .{apple.boolean(false)});
                view.msgSend(void, "setBackgroundColor:", .{apple.class("UIColor").msgSend(Object, "clearColor", .{})});
            }
            if (config.devtools and view.getClass().?.respondsToSelector(apple.objc.sel("setInspectable:"))) {
                view.msgSend(void, "setInspectable:", .{apple.boolean(true)}); // iOS 16.4+
            }

            const controller = controller_class.?.msgSend(Object, "alloc", .{}).msgSend(Object, "init", .{});
            if (controller.value == null) return error.CreateWindowFailed;
            // The controller's view is a container filling the window; the
            // webview sits in its safe area, as Android pads the page by the
            // system bars, so pages don't need env(safe-area-inset-*).
            const container = apple.new(apple.class("UIView"));
            defer container.release();
            container.msgSend(void, "setBackgroundColor:", .{apple.class("UIColor").msgSend(Object, if (options.transparent) "clearColor" else "systemBackgroundColor", .{})});
            view.msgSend(void, "setTranslatesAutoresizingMaskIntoConstraints:", .{apple.boolean(false)});
            container.msgSend(void, "addSubview:", .{view});
            const safe = edgeConstraints(view, container.msgSend(Object, "safeAreaLayoutGuide", .{}));
            errdefer safe.release();
            const full = edgeConstraints(view, container);
            errdefer full.release();
            controller.msgSend(void, "setView:", .{container});
            if (apple.nsString(options.title)) |t| {
                defer t.release();
                controller.msgSend(void, "setTitle:", .{t});
            }

            const target_uri = try security.resolveWindowUrl(gpa, config.security, local, if (config.dev) |d| d.url else null, options.url, config.start);
            defer gpa.free(target_uri);
            try load(view, target_uri);

            const serial = next_serial.fetchAdd(1, .monotonic);
            try states.put(gpa, serial, .{
                .fullscreen = options.fullscreen,
                .safe_constraints = safe.value,
                .full_constraints = full.value,
            });
            applyLayout(state(serial).?);
            return .{ .controller = controller.value, .webview = view.value, .serial = serial };
        }

        fn load(view: Object, uri: []const u8) !void {
            const url = apple.nsUrl(uri);
            if (url.value == null) return error.InvalidUrl;
            const request = apple.class("NSURLRequest").msgSend(Object, "requestWithURL:", .{url});
            _ = view.msgSend(Object, "loadRequest:", .{request});
        }

        fn actionUrl(action: Object) ?[:0]const u8 {
            return apple.urlString(action.msgSend(Object, "request", .{}).msgSend(Object, "URL", .{}));
        }

        fn isUserGesture(action: Object) bool {
            const kind = action.msgSend(isize, "navigationType", .{});
            return kind == nav_link_activated or kind == nav_form_submitted;
        }

        fn decidePolicy(_: apple.id, _: apple.c.SEL, _: apple.id, action_id: apple.id, handler: apple.id) callconv(.c) void {
            const action: Object = .{ .value = action_id };
            const uri = actionUrl(action) orelse return apple.callBlock(handler, &.{isize}, .{policy_cancel});
            if (comptime config.security.isolation != null) {
                const frame = action.msgSend(Object, "targetFrame", .{});
                if (frame.value != null and !apple.isTrue(frame.msgSend(apple.c.BOOL, "isMainFrame", .{}))) {
                    var buf: [512]u8 = undefined;
                    if (security.origin(&buf, uri)) |o| if (std.mem.eql(u8, o, isolation.origin))
                        return apple.callBlock(handler, &.{isize}, .{policy_allow});
                }
            }
            const new_window = action.msgSend(Object, "targetFrame", .{}).value == null;
            switch (security.navigation(config.security, local, uri, isUserGesture(action))) {
                .allow => apple.callBlock(handler, &.{isize}, .{policy_allow}),
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

        /// `window.open` / allowed `target="_blank"`: an Oriel window or the
        /// main view (`config.window_open`), never a WebKit popup.
        fn createWebView(_: apple.id, _: apple.c.SEL, _: apple.id, _: apple.id, action_id: apple.id, _: apple.id) callconv(.c) apple.id {
            const action: Object = .{ .value = action_id };
            const uri = actionUrl(action) orelse return null;
            switch (security.navigation(config.security, local, uri, isUserGesture(action))) {
                .allow => {
                    var obuf: [512]u8 = undefined;
                    const o = security.origin(&obuf, uri);
                    if (config.window_open == .new_window and o != null and local.contains(o.?)) {
                        const n = window_open_counter.fetchAdd(1, .monotonic);
                        var label_buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrintZ(&label_buf, "win-{d}", .{n}) catch return null;
                        _ = App.openWindow(.{ .label = label, .url = uri }) catch |err| log.err("window.open failed: {s}", .{@errorName(err)});
                    } else if (App.getWindow("main")) |mw| {
                        load(.{ .value = mw.handle.webview }, uri) catch |err| log.err("window.open failed: {s}", .{@errorName(err)});
                    }
                },
                .open_external => App.openExternal(uri.ptr),
                .block => log.warn("blocked new window to {s}", .{uri}),
            }
            return null;
        }

        fn webViewDidClose(_: apple.id, _: apple.c.SEL, view: apple.id) callconv(.c) void {
            if (getWindowByView(view)) |w| postCloseWindow(w.handle);
        }

        /// iOS kills background web content processes freely: reload.
        fn webContentProcessDidTerminate(_: apple.id, _: apple.c.SEL, view: apple.id) callconv(.c) void {
            log.warn("web content process terminated; reloading", .{});
            _ = (Object{ .value = view }).msgSend(Object, "reload", .{});
        }

        /// getUserMedia (iOS 15+): declared devices, trusted pages only.
        fn requestMediaCapture(_: apple.id, _: apple.c.SEL, _: apple.id, origin_id: apple.id, _: apple.id, capture_type: i64, handler: apple.id) callconv(.c) void {
            const kinds: []const permissions.Kind = switch (capture_type) {
                0 => &.{.camera},
                1 => &.{.microphone},
                2 => &.{ .camera, .microphone },
                else => &.{},
            };
            var buf: [600]u8 = undefined;
            const origin: Object = .{ .value = origin_id };
            const scheme = apple.utf8(origin.msgSend(Object, "protocol", .{})) orelse "";
            const host = apple.utf8(origin.msgSend(Object, "host", .{})) orelse "";
            const port = origin.msgSend(isize, "port", .{});
            const page = (if (port > 0) std.fmt.bufPrint(&buf, "{s}://{s}:{d}/", .{ scheme, host, port }) else std.fmt.bufPrint(&buf, "{s}://{s}/", .{ scheme, host })) catch "";
            var allow = kinds.len > 0;
            for (kinds) |k| {
                if (!permissions.allowForPage(k, local, page)) allow = false;
            }
            // WKPermissionDecision: prompt 0, grant 1, deny 2.
            apple.callBlock(handler, &.{isize}, .{if (allow) 1 else 2});
        }

        fn didFailProvisionalNavigation(_: apple.id, _: apple.c.SEL, view: apple.id, _: apple.id, err: apple.id) callconv(.c) void {
            const code = (Object{ .value = err }).msgSend(isize, "code", .{});
            if (config.dev == null or dev_retries_left == 0) {
                if (code != -999) log.warn("load failed (NSURLError {d})", .{code});
                return;
            }
            dev_retries_left -= 1;
            _ = (Object{ .value = view }).msgSend(Object, "retain", .{});
            apple.afterMain(dev_retry_interval_ms, view, &retryDevLoad);
        }

        fn retryDevLoad(ctx: ?*anyopaque) callconv(.c) void {
            const view: Object = .{ .value = @ptrCast(@alignCast(ctx)) };
            defer view.release();
            if (getWindowByView(view.value) == null) return;
            load(view, config.dev.?.url) catch |err| log.err("dev reload failed: {s}", .{@errorName(err)});
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
