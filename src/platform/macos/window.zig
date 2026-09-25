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
const cocoa = @import("cocoa.zig");
const objc = cocoa.objc;
const Object = cocoa.Object;
const ShellMod = @import("Shell.zig");
const scheme_mod = @import("scheme.zig");
const bridge_mod = @import("bridge.zig");
const js_dialogs = @import("js_dialogs.zig");
const permissions = @import("../../core/permissions.zig");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");

const log = std.log.scoped(.oriel);

pub const WindowHandle = struct {
    window: cocoa.id,
    webview: cocoa.id,
    /// Unique per window for the whole run: a queued handle copy must not
    /// match a new window that reuses a closed one's address.
    serial: u64,

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.serial == other.serial;
    }

    fn nsWindow(self: WindowHandle) Object {
        return .{ .value = self.window };
    }

    fn webView(self: WindowHandle) Object {
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

fn apply(handle: WindowHandle, op: Op) void {
    const win = handle.nsWindow();
    switch (op) {
        .show, .focus => {
            win.msgSend(void, "makeKeyAndOrderFront:", .{cocoa.nil});
            ShellMod.sharedApplication().msgSend(void, "activateIgnoringOtherApps:", .{cocoa.boolean(true)});
        },
        .hide => win.msgSend(void, "orderOut:", .{cocoa.nil}),
        .toggle => {
            const visible = cocoa.isTrue(win.msgSend(cocoa.c.BOOL, "isVisible", .{}));
            const key = cocoa.isTrue(win.msgSend(cocoa.c.BOOL, "isKeyWindow", .{}));
            apply(handle, if (visible and key) .hide else .show);
        },
        .close => if (App.getWindowByHandle(handle)) |w| closeNow(w),
        .title => |t| {
            const str = cocoa.nsString(t) orelse return;
            defer str.release();
            win.msgSend(void, "setTitle:", .{str});
        },
        .fullscreen => |on| if (isFullscreenNow(handle) != on) win.msgSend(void, "toggleFullScreen:", .{cocoa.nil}),
        .maximized => |on| if (cocoa.isTrue(win.msgSend(cocoa.c.BOOL, "isZoomed", .{})) != on) win.msgSend(void, "zoom:", .{cocoa.nil}),
        .size => |s| win.msgSend(void, "setContentSize:", .{cocoa.NSSize{ .width = @floatFromInt(s.width), .height = @floatFromInt(s.height) }}),
    }
}

/// Apply `op` now on the main thread, or queue it for the live window that
/// matches `handle` (a copy may outlive its window).
fn perform(handle: WindowHandle, op: Op) void {
    if (cocoa.isMainThread()) {
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
    if (cocoa.isMainThread()) return get(handle);
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
            if (App.getWindowByHandle(h.*)) |w| closeNow(w);
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
    return cocoa.isTrue(handle.nsWindow().msgSend(cocoa.c.BOOL, "isZoomed", .{}));
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
    const frame = content.msgSend(cocoa.NSRect, "frame", .{});
    return .{ .width = @intFromFloat(@round(frame.size.width)), .height = @intFromFloat(@round(frame.size.height)) };
}

/// The content (webview) size in points.
pub fn getWindowSize(handle: WindowHandle) WindowSize {
    return query(WindowSize, handle, contentSizeNow, .{ .width = 0, .height = 0 });
}

/// Open `uri` with its default app. Callable from any thread: AppKit is
/// used on the main thread (a copy of `uri` is queued from other threads).
pub fn openExternal(uri: [*:0]const u8) void {
    if (cocoa.isMainThread()) return openExternalNow(uri);
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
    const str = cocoa.nsString(std.mem.span(uri)) orelse {
        log.err("could not open {s}: not UTF-8", .{uri});
        return;
    };
    defer str.release();
    const url = cocoa.class("NSURL").msgSend(Object, "URLWithString:", .{str});
    if (url.value == null) {
        log.err("could not open {s}: invalid URL", .{uri});
        return;
    }
    const workspace = cocoa.class("NSWorkspace").msgSend(Object, "sharedWorkspace", .{});
    if (!cocoa.isTrue(workspace.msgSend(cocoa.c.BOOL, "openURL:", .{url}))) {
        log.err("could not open {s}", .{uri});
    }
}

// ---------------------------------------------------------------------------
// Lookup and teardown
// ---------------------------------------------------------------------------

pub fn getWindowByView(view: cocoa.id) ?*App.Window {
    if (view == null) return null;
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |w| {
        if (w.handle.webview == view) return w;
    }
    return null;
}

fn getWindowByNSWindow(nswindow: cocoa.id) ?*App.Window {
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |w| {
        if (w.handle.window == nswindow) return w;
    }
    return null;
}

/// Detach the delegates, close the window and drop our references. The
/// release is deferred to the enclosing autorelease pool so a window can be
/// torn down from inside its own delegate or webview callbacks.
fn teardown(handle: WindowHandle) void {
    const view = handle.webView();
    view.msgSend(void, "setNavigationDelegate:", .{cocoa.nil});
    view.msgSend(void, "setUIDelegate:", .{cocoa.nil});
    view.msgSend(void, "stopLoading", .{});
    const content = view.msgSend(Object, "configuration", .{}).msgSend(Object, "userContentController", .{});
    content.msgSend(void, "removeAllScriptMessageHandlers", .{});

    const win = handle.nsWindow();
    win.msgSend(void, "setDelegate:", .{cocoa.nil});
    win.msgSend(void, "orderOut:", .{cocoa.nil});
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
    if (std.mem.eql(u8, win.label, "main") and current_on_close_hide) {
        win.handle.nsWindow().msgSend(void, "orderOut:", .{cocoa.nil});
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
    const remaining = App.windows_list.items.len;
    App.windows_mutex.unlock();

    teardown(win.handle);
    freeWindow(win);

    if (remaining == 0) App.quit(0);
}

fn freeWindow(win: *App.Window) void {
    const gpa = std.heap.smp_allocator;
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
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        const win = App.windows_list.pop();
        App.windows_mutex.unlock();
        const w = win orelse break;
        teardown(w.handle);
        freeWindow(w);
    }
}

var next_serial: std.atomic.Value(u64) = .init(1);

/// `config.on_close == .hide`, captured by `WindowCreator.init` for the
/// non-generic close path.
var current_on_close_hide = false;

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
    const SchemeImpl = scheme_mod.Scheme(config, csp_z);
    const BridgeImpl = bridge_mod.Bridge(api, config, local);

    return struct {
        // Shared delegate/handler instances (+1 each), alive between init and deinit.
        var window_delegate: Object = cocoa.nil;
        var nav_delegate: Object = cocoa.nil;
        var message_handler: Object = cocoa.nil;
        var scheme_handler: Object = cocoa.nil;

        var window_open_counter = std.atomic.Value(u32).init(1);
        var dev_retries_left: u32 = 0;

        pub fn init() void {
            current_on_close_hide = config.on_close == .hide;
            if (config.dev) |dev| dev_retries_left = dev.timeout_ms / dev_retry_interval_ms;

            window_delegate = cocoa.new(cocoa.defineClass("OrielWindowDelegate", &.{"NSWindowDelegate"}, .{
                .{ "windowShouldClose:", windowShouldClose },
            }));
            nav_delegate = cocoa.new(cocoa.defineClass("OrielNavigationDelegate", &.{ "WKNavigationDelegate", "WKUIDelegate" }, .{
                .{ "webView:decidePolicyForNavigationAction:decisionHandler:", decidePolicy },
                .{ "webView:didFailProvisionalNavigation:withError:", didFailProvisionalNavigation },
                .{ "webViewWebContentProcessDidTerminate:", webContentProcessDidTerminate },
                .{ "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:", createWebView },
                .{ "webViewDidClose:", webViewDidClose },
                .{ "webView:didFinishNavigation:", didFinishNavigation },
                .{ "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:", requestMediaCapture },
            } ++ js_dialogs.methods));
            message_handler = cocoa.new(BridgeImpl.handlerClass());
            scheme_handler = cocoa.new(SchemeImpl.handlerClass());
        }

        pub fn deinit() void {
            inline for (.{ &window_delegate, &nav_delegate, &message_handler, &scheme_handler }) |obj| {
                obj.*.release();
                obj.* = cocoa.nil;
            }
        }

        pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            _ = win_inst; // looked up through App.windows_list by NSWindow / WKWebView
            if (!cocoa.isMainThread()) return error.NotMainThread;
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            const gpa = std.heap.smp_allocator;

            var style: c_ulong = 0; // borderless without decorations
            if (options.decorations) {
                style = style_titled | style_closable | style_miniaturizable;
                if (options.resizable) style |= style_resizable;
            }
            const rect: cocoa.NSRect = .{
                .origin = .{ .x = 0, .y = 0 },
                .size = .{ .width = @floatFromInt(options.width), .height = @floatFromInt(options.height) },
            };
            const win = cocoa.class("NSWindow").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithContentRect:styleMask:backing:defer:", .{ rect, style, NSBackingStoreBuffered, cocoa.boolean(false) });
            if (win.value == null) return error.CreateWindowFailed;
            errdefer win.release();
            // We own the window and release it in teardown.
            win.msgSend(void, "setReleasedWhenClosed:", .{cocoa.boolean(false)});
            win.msgSend(void, "setCollectionBehavior:", .{win.msgSend(c_ulong, "collectionBehavior", .{}) | NSWindowCollectionBehaviorFullScreenPrimary});
            if (cocoa.nsString(options.title)) |title| {
                defer title.release();
                win.msgSend(void, "setTitle:", .{title});
            }
            if (options.min_width != null or options.min_height != null) {
                win.msgSend(void, "setContentMinSize:", .{cocoa.NSSize{
                    .width = @floatFromInt(options.min_width orelse 0),
                    .height = @floatFromInt(options.min_height orelse 0),
                }});
            }
            if (options.max_width != null or options.max_height != null) {
                const huge: f64 = std.math.floatMax(f32);
                win.msgSend(void, "setContentMaxSize:", .{cocoa.NSSize{
                    .width = if (options.max_width) |w| @floatFromInt(w) else huge,
                    .height = if (options.max_height) |h| @floatFromInt(h) else huge,
                }});
            }
            win.msgSend(void, "center", .{});

            const wk_config = cocoa.new(cocoa.class("WKWebViewConfiguration"));
            defer wk_config.release(); // the webview copies it
            const scheme_name = cocoa.nsString(scheme_mod.scheme_name) orelse return error.OutOfMemory;
            defer scheme_name.release();
            wk_config.msgSend(void, "setURLSchemeHandler:forURLScheme:", .{ scheme_handler, scheme_name });
            const content = wk_config.msgSend(Object, "userContentController", .{});
            try BridgeImpl.setupUserContent(content, message_handler, options.label);
            // getUserMedia: WKWebView only exposes navigator.mediaDevices with
            // this (private, long-standing) preference on. Enabled only for
            // apps that declare the microphone or camera; every request still
            // goes through requestMediaCapture (allowForPage), then TCC.
            if (comptime (config.permissions.has(.microphone) or config.permissions.has(.camera))) {
                const prefs = wk_config.msgSend(Object, "preferences", .{});
                if (prefs.getClass().?.respondsToSelector(objc.sel("_setMediaDevicesEnabled:"))) {
                    prefs.msgSend(void, "_setMediaDevicesEnabled:", .{cocoa.boolean(true)});
                }
            }

            const view = cocoa.class("WKWebView").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithFrame:configuration:", .{ rect, wk_config });
            if (view.value == null) return error.CreateWebViewFailed;
            errdefer view.release();
            view.msgSend(void, "setNavigationDelegate:", .{nav_delegate});
            view.msgSend(void, "setUIDelegate:", .{nav_delegate});
            if (config.devtools and view.getClass().?.respondsToSelector(objc.sel("setInspectable:"))) {
                view.msgSend(void, "setInspectable:", .{cocoa.boolean(true)}); // macOS 13.3+
            }
            win.msgSend(void, "setContentView:", .{view});
            win.msgSend(void, "setDelegate:", .{window_delegate});

            const target_uri = try security.resolveWindowUrl(
                gpa,
                config.security,
                local,
                if (config.dev) |d| d.url else null,
                options.url,
                config.start,
            );
            defer gpa.free(target_uri);
            try load(view, target_uri);

            return .{ .window = win.value, .webview = view.value, .serial = next_serial.fetchAdd(1, .monotonic) };
        }

        fn load(view: Object, uri: []const u8) !void {
            const str = cocoa.nsString(uri) orelse return error.InvalidUrl;
            defer str.release();
            const url = cocoa.class("NSURL").msgSend(Object, "URLWithString:", .{str});
            if (url.value == null) return error.InvalidUrl;
            const request = cocoa.class("NSURLRequest").msgSend(Object, "requestWithURL:", .{url});
            _ = view.msgSend(Object, "loadRequest:", .{request});
        }

        fn windowShouldClose(_: cocoa.id, _: cocoa.c.SEL, sender: cocoa.id) callconv(.c) cocoa.c.BOOL {
            const w = getWindowByNSWindow(sender) orelse return cocoa.boolean(true);
            if (!w.ready) {
                w.pending_close = true;
                return cocoa.boolean(false);
            }
            closeNow(w);
            return cocoa.boolean(false); // closeNow closed it (or hid it)
        }

        /// Borrowed UTF-8 URL of a navigation action's request.
        fn actionUrl(action: Object) ?[:0]const u8 {
            return cocoa.urlString(action.msgSend(Object, "request", .{}).msgSend(Object, "URL", .{}));
        }

        fn isUserGesture(action: Object) bool {
            const kind = action.msgSend(isize, "navigationType", .{});
            return kind == nav_link_activated or kind == nav_form_submitted;
        }

        /// getUserMedia (WKUIDelegate, macOS 12+): granted only when the app
        /// declares every requested device and the page's origin is trusted
        /// (permissions.allowForPage); TCC then asks the user on first use.
        fn requestMediaCapture(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, origin_id: cocoa.id, frame_id: cocoa.id, capture_type: i64, handler: cocoa.id) callconv(.c) void {
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
            cocoa.callBlock(handler, struct { isize }, .{if (allow) 1 else 2});
        }

        /// The requesting frame's URL, else `scheme://host[:port]` from its
        /// WKSecurityOrigin (borrowed / in `buf`).
        fn frameUrl(buf: []u8, frame_id: cocoa.id, origin_id: cocoa.id) []const u8 {
            if (frame_id != null) {
                const req = (Object{ .value = frame_id }).msgSend(Object, "request", .{});
                if (req.value != null) if (cocoa.urlString(req.msgSend(Object, "URL", .{}))) |u| {
                    // about:blank/srcdoc, blob: and data: frames inherit their
                    // origin: judge them by the WKSecurityOrigin instead.
                    const inherits = std.mem.startsWith(u8, u, "about:") or std.mem.startsWith(u8, u, "blob:") or std.mem.startsWith(u8, u, "data:");
                    if (u.len > 0 and !inherits) return u;
                };
            }
            if (origin_id == null) return "";
            const origin: Object = .{ .value = origin_id };
            const scheme = cocoa.utf8(origin.msgSend(Object, "protocol", .{})) orelse return "";
            const host = cocoa.utf8(origin.msgSend(Object, "host", .{})) orelse return "";
            const port = origin.msgSend(isize, "port", .{});
            return (if (port > 0)
                std.fmt.bufPrint(buf, "{s}://{s}:{d}/", .{ scheme, host, port })
            else
                std.fmt.bufPrint(buf, "{s}://{s}/", .{ scheme, host })) catch "";
        }

        fn decidePolicy(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, action_id: cocoa.id, handler: cocoa.id) callconv(.c) void {
            const action: Object = .{ .value = action_id };
            const uri = actionUrl(action) orelse {
                cocoa.callBlock(handler, struct { isize }, .{policy_cancel});
                return;
            };
            const verdict = security.navigation(config.security, local, uri, isUserGesture(action));
            // No target frame: a new-window request (target="_blank"). An
            // allowed one continues to `createWebView`, which decides where it opens.
            const new_window = action.msgSend(Object, "targetFrame", .{}).value == null;
            switch (verdict) {
                .allow => {
                    cocoa.callBlock(handler, struct { isize }, .{policy_allow});
                    return;
                },
                .open_external => {
                    cocoa.callBlock(handler, struct { isize }, .{policy_cancel});
                    App.openExternal(uri.ptr);
                },
                .block => {
                    cocoa.callBlock(handler, struct { isize }, .{policy_cancel});
                    log.warn("blocked {s} to {s}", .{ if (new_window) "new window" else "navigation", uri });
                },
            }
        }

        /// `window.open` and allowed `target="_blank"` navigations: open an
        /// Oriel window or load in the main view (`config.window_open`); never
        /// a WebKit-managed popup.
        fn createWebView(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, _: cocoa.id, action_id: cocoa.id, _: cocoa.id) callconv(.c) cocoa.id {
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
        fn webViewDidClose(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id) callconv(.c) void {
            if (getWindowByView(view)) |w| postCloseWindow(w.handle);
        }

        fn webContentProcessDidTerminate(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id) callconv(.c) void {
            log.err("web content process terminated; reloading", .{});
            _ = (Object{ .value = view }).msgSend(Object, "reload", .{});
        }

        /// Debugging aid for machines where screen capture needs a Screen
        /// Recording grant: `ORIEL_SNAPSHOT=/path/shot.png` saves the main
        /// window's page once, a second (`ORIEL_SNAPSHOT_DELAY_MS`) after its
        /// first load finished (like
        /// `SHOT=` under scripts/headless.sh on Linux).
        fn didFinishNavigation(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id, _: cocoa.id) callconv(.c) void {
            if (snapshot_taken) return;
            if (std.c.getenv("ORIEL_SNAPSHOT") == null) return;
            const w = getWindowByView(view) orelse return;
            if (!std.mem.eql(u8, w.label, "main")) return;
            snapshot_taken = true;
            // Until the snapshot ran; leaked if the app quits first (debug-only path).
            _ = (Object{ .value = view }).retain();
            const delay_ms = if (std.c.getenv("ORIEL_SNAPSHOT_DELAY_MS")) |d| std.fmt.parseInt(u32, std.mem.span(d), 10) catch 1000 else 1000;
            cocoa.afterMain(delay_ms, view, &takeSnapshot);
        }

        var snapshot_taken = false;

        const SnapshotBlock = objc.Block(struct {}, .{ cocoa.id, cocoa.id }, void);

        fn takeSnapshot(ctx: ?*anyopaque) callconv(.c) void {
            const view: Object = .{ .value = @ptrCast(@alignCast(ctx)) };
            defer view.release();
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            // WebKit copies the (stack) block before this call returns.
            var block = SnapshotBlock.init(.{}, &snapshotDone);
            view.msgSend(void, "takeSnapshotWithConfiguration:completionHandler:", .{ cocoa.nil, @as(cocoa.id, @ptrCast(&block)) });
        }

        fn snapshotDone(_: *const SnapshotBlock.Context, image_id: cocoa.id, _: cocoa.id) callconv(.c) void {
            const path = std.c.getenv("ORIEL_SNAPSHOT") orelse return;
            const image: Object = .{ .value = image_id };
            if (image.value == null) {
                log.err("ORIEL_SNAPSHOT: WebKit returned no image", .{});
                return;
            }
            const tiff = image.msgSend(Object, "TIFFRepresentation", .{});
            const rep = cocoa.class("NSBitmapImageRep").msgSend(Object, "imageRepWithData:", .{tiff});
            const NSBitmapImageFileTypePNG: c_ulong = 4;
            const png = if (rep.value != null) rep.msgSend(Object, "representationUsingType:properties:", .{
                NSBitmapImageFileTypePNG, cocoa.class("NSDictionary").msgSend(Object, "dictionary", .{}),
            }) else cocoa.nil;
            const path_ns = cocoa.nsString(std.mem.span(path)) orelse return;
            defer path_ns.release();
            if (png.value == null or !cocoa.isTrue(png.msgSend(cocoa.c.BOOL, "writeToFile:atomically:", .{ path_ns, cocoa.boolean(true) }))) {
                log.err("ORIEL_SNAPSHOT: could not write {s}", .{path});
                return;
            }
            log.info("ORIEL_SNAPSHOT: wrote {s}", .{path});
        }

        // Dev mode: the dev server may still be starting; retry the dev URL
        // (like the Linux backend) until `dev.timeout_ms` is used up.
        const dev_retry_interval_ms = 250;

        fn didFailProvisionalNavigation(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id, _: cocoa.id, err: cocoa.id) callconv(.c) void {
            const failure: Object = .{ .value = err };
            const code = failure.msgSend(isize, "code", .{});
            if (config.dev == null or dev_retries_left == 0) {
                if (code != -999) log.warn("load failed (NSURLError {d})", .{code}); // -999: cancelled by our policy
                return;
            }
            dev_retries_left -= 1;
            // Keep the webview alive until the retry ran (it may be closed
            // meanwhile). Leaked if the app quits within the retry interval: the
            // main queue isn't serviced after the run loop (dev builds only).
            _ = (Object{ .value = view }).retain();
            cocoa.afterMain(dev_retry_interval_ms, view, &retryDevLoad);
        }

        fn retryDevLoad(ctx: ?*anyopaque) callconv(.c) void {
            const view: Object = .{ .value = @ptrCast(@alignCast(ctx)) };
            defer view.release();
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();
            if (getWindowByView(view.value) == null) return; // closed while waiting
            load(view, config.dev.?.url) catch |err| log.err("dev reload failed: {s}", .{@errorName(err)});
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
