//! Linux GTK4 and WebKitGTK window creation and manipulation.
//!
//! Handles native GtkApplicationWindow and WebKitWebView instantiation,
//! window properties (size, fullscreen, maximized, title), navigation policy decisions,
//! and close requests.

const std = @import("std");
const gtk = @import("gtk");
const webkit = @import("webkit");
const glib = @import("glib");
const gio = @import("gio");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const dev_server = @import("dev_server.zig");

const log = std.log.scoped(.oriel);

pub const WindowHandle = struct {
    gtk_window: *gtk.Window,
    app_window: *gtk.ApplicationWindow,
    web_view: *webkit.WebView,

    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.gtk_window == other.gtk_window;
    }
};

pub fn showWindow(handle: WindowHandle) void {
    handle.gtk_window.present();
}

pub fn hideWindow(handle: WindowHandle) void {
    handle.gtk_window.as(gtk.Widget).setVisible(0);
}

pub fn toggleWindow(handle: WindowHandle) void {
    if (handle.gtk_window.as(gtk.Widget).getVisible() != 0 and handle.gtk_window.isActive() != 0) {
        hideWindow(handle);
    } else {
        showWindow(handle);
    }
}

pub fn closeWindow(handle: WindowHandle) void {
    handle.gtk_window.close();
}

pub fn destroyWindow(handle: WindowHandle) void {
    handle.gtk_window.destroy();
}

pub fn setWindowTitle(handle: WindowHandle, title: [:0]const u8) void {
    handle.gtk_window.setTitle(title);
}

pub fn setWindowFullscreen(handle: WindowHandle, fullscreen: bool) void {
    if (fullscreen) handle.gtk_window.fullscreen() else handle.gtk_window.unfullscreen();
}

pub fn isWindowFullscreen(handle: WindowHandle) bool {
    return handle.gtk_window.isFullscreen() != 0;
}

pub fn setWindowMaximized(handle: WindowHandle, maximized: bool) void {
    if (maximized) handle.gtk_window.maximize() else handle.gtk_window.unmaximize();
}

pub fn isWindowMaximized(handle: WindowHandle) bool {
    return handle.gtk_window.isMaximized() != 0;
}

pub fn setWindowSize(handle: WindowHandle, width: c_int, height: c_int) void {
    handle.gtk_window.setDefaultSize(width, height);
}

pub const WindowSize = struct {
    width: c_int,
    height: c_int,
};

pub fn getWindowSize(handle: WindowHandle) WindowSize {
    var w: c_int = 0;
    var h: c_int = 0;
    handle.gtk_window.getDefaultSize(&w, &h);
    return .{ .width = w, .height = h };
}

pub fn openExternal(uri: [*:0]const u8) void {
    var err: ?*glib.Error = null;
    if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
        if (err) |e| {
            log.err("could not open {s}: {s}", .{ uri, e.f_message orelse "unknown error" });
            e.free();
        }
    }
}

pub fn getWindowByView(view: *webkit.WebView) ?*App.Window {
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |w| {
        if (w.handle.web_view == view) return w;
    }
    return null;
}

pub fn WindowCreator(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime bridge_patterns: anytype,
    comptime csp_z: ?[:0]const u8,
) type {
    const SchemeImpl = @import("scheme.zig").Scheme(config, csp_z);
    const BridgeImpl = @import("bridge.zig").Bridge(api, config, local, bridge_patterns);

    return struct {
        fn devUrl() [:0]const u8 {
            const url = config.dev.?.url;
            return (url ++ "\x00")[0..url.len :0];
        }

        const DevRetry = dev_server.DevRetryContext(&devUrl);

        pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle {
            const app = App.gtk_app orelse return error.AppNotRunning;

            const app_window = gtk.ApplicationWindow.new(app);
            const window = app_window.as(gtk.Window);
            window.setTitle(options.title);
            window.setDefaultSize(options.width, options.height);
            window.setResizable(@intFromBool(options.resizable));
            window.setDecorated(@intFromBool(options.decorations));

            if (options.min_width != null or options.min_height != null) {
                window.as(gtk.Widget).setSizeRequest(options.min_width orelse -1, options.min_height orelse -1);
            }

            const view = webkit.WebView.new();
            SchemeImpl.register(view);

            const settings = view.getSettings();
            settings.setEnableDeveloperExtras(@intFromBool(config.devtools));
            settings.setEnableWriteConsoleMessagesToStdout(@intFromBool(config.devtools));
            settings.setJavascriptCanOpenWindowsAutomatically(0);
            settings.setAllowFileAccessFromFileUrls(0);
            settings.setAllowUniversalAccessFromFileUrls(0);

            BridgeImpl.setupUserContent(view);

            _ = webkit.WebView.signals.decide_policy.connect(view, ?*anyopaque, &onDecidePolicy, null, .{});
            window.setChild(view.as(gtk.Widget));

            _ = gtk.Window.signals.close_request.connect(window, *App.Window, &onWindowCloseRequest, win_inst, .{});

            const gpa = std.heap.smp_allocator;

            if (config.dev) |dev| {
                DevRetry.initRetries(dev.timeout_ms);
                _ = webkit.WebView.signals.load_failed.connect(view, ?*anyopaque, &DevRetry.onLoadFailed, null, .{});
            }

            const target_uri = try security.resolveWindowUrl(
                gpa,
                config.security,
                local,
                if (config.dev) |d| d.url else null,
                options.url,
                config.start,
            );
            defer gpa.free(target_uri);
            view.loadUri(target_uri);

            window.present();

            return WindowHandle{
                .gtk_window = window,
                .app_window = app_window,
                .web_view = view,
            };
        }

        fn onWindowCloseRequest(window: *gtk.Window, win: *App.Window) callconv(.c) c_int {
            if (std.mem.eql(u8, win.label, "main") and config.on_close == .hide) {
                window.as(gtk.Widget).setVisible(0);
                return 1;
            }

            win.saveGeometry();

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

            std.heap.smp_allocator.free(win.label);
            std.heap.smp_allocator.free(win.options.title);
            std.heap.smp_allocator.destroy(win);

            if (remaining == 0) {
                App.quit(0);
            }
            return 0;
        }

        fn onDecidePolicy(
            _: *webkit.WebView,
            decision: *webkit.PolicyDecision,
            decision_type: webkit.PolicyDecisionType,
            _: ?*anyopaque,
        ) callconv(.c) c_int {
            switch (decision_type) {
                .navigation_action, .new_window_action => {},
                else => return 0, // default handling for responses
            }
            const nav_decision: *webkit.NavigationPolicyDecision = @ptrCast(decision);
            const action = nav_decision.getNavigationAction();
            const uri = action.getRequest().getUri();
            const verdict = security.navigation(config.security, local, std.mem.span(uri), action.isUserGesture() != 0);
            switch (verdict) {
                .allow => if (decision_type == .new_window_action) {
                    // No popups: open allowed targets in the main view.
                    decision.ignore();
                    if (App.getWindow("main")) |mw| {
                        mw.handle.web_view.loadUri(uri);
                    }
                } else decision.use(),
                .open_external => {
                    decision.ignore();
                    App.openExternal(uri);
                },
                .block => {
                    decision.ignore();
                    log.warn("blocked navigation to {s}", .{uri});
                },
            }
            return 1;
        }
    };
}
