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
const permissions = @import("../../core/permissions.zig");
const overlay = @import("overlay.zig");

extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;
extern fn webkit_user_media_permission_is_for_audio_device(req: *webkit.UserMediaPermissionRequest) c_int;
extern fn webkit_user_media_permission_is_for_video_device(req: *webkit.UserMediaPermissionRequest) c_int;
extern fn webkit_user_media_permission_is_for_display_device(req: *webkit.UserMediaPermissionRequest) c_int;
extern fn webkit_permission_request_allow(req: *webkit.PermissionRequest) void;
extern fn webkit_permission_request_deny(req: *webkit.PermissionRequest) void;
extern fn webkit_web_view_get_uri(view: *webkit.WebView) ?[*:0]const u8;

/// The permissions a WebKit permission request needs (null: a request type
/// Oriel leaves to WebKit's default, which denies).
fn requestKinds(req: *webkit.PermissionRequest, out: *[3]permissions.Kind) ?[]const permissions.Kind {
    if (g_type_check_instance_is_a(req, webkit.UserMediaPermissionRequest.getGObjectType()) != 0) {
        const um: *webkit.UserMediaPermissionRequest = @ptrCast(req);
        var n: usize = 0;
        if (webkit_user_media_permission_is_for_audio_device(um) != 0) {
            out[n] = .microphone;
            n += 1;
        }
        if (webkit_user_media_permission_is_for_video_device(um) != 0) {
            out[n] = .camera;
            n += 1;
        }
        if (webkit_user_media_permission_is_for_display_device(um) != 0) {
            out[n] = .screen_capture;
            n += 1;
        }
        return out[0..n];
    }
    if (g_type_check_instance_is_a(req, webkit.GeolocationPermissionRequest.getGObjectType()) != 0) {
        out[0] = .location;
        return out[0..1];
    }
    if (g_type_check_instance_is_a(req, webkit.NotificationPermissionRequest.getGObjectType()) != 0) {
        out[0] = .notifications;
        return out[0..1];
    }
    return null;
}

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

pub fn postCloseWindow(handle: WindowHandle) void {
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    const label_copy = for (App.windows_list.items) |w| {
        if (w.handle.eql(handle)) {
            break std.heap.smp_allocator.dupeZ(u8, w.label) catch {
                App.windows_mutex.unlock();
                return;
            };
        }
    } else {
        App.windows_mutex.unlock();
        return;
    };
    App.windows_mutex.unlock();

    if (glib.idleAdd(&idleCloseWindow, label_copy.ptr) == 0) {
        std.heap.smp_allocator.free(label_copy);
    }
}

fn idleCloseWindow(data: ?*anyopaque) callconv(.c) c_int {
    const label_ptr: [*:0]const u8 = @ptrCast(@alignCast(data orelse return 0));
    const label = std.mem.span(label_ptr);
    defer std.heap.smp_allocator.free(label_ptr[0 .. label.len + 1]);

    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    const gtk_win = for (App.windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) break w.handle.gtk_window;
    } else null;
    App.windows_mutex.unlock();

    if (gtk_win) |win| {
        win.close();
    }
    return 0;
}

pub fn focusWindow(handle: WindowHandle) void {
    handle.gtk_window.present();
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
            const id_z = (config.id ++ "\x00")[0..config.id.len :0];
            window.setIconName(id_z);
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
            // getUserMedia exists only when the app may use a microphone or camera.
            settings.setEnableMediaStream(@intFromBool(config.permissions.has(.microphone) or config.permissions.has(.camera) or config.permissions.has(.screen_capture)));

            BridgeImpl.setupUserContent(view, options.label);

            _ = webkit.WebView.signals.decide_policy.connect(view, ?*anyopaque, &onDecidePolicy, null, .{});
            _ = webkit.WebView.signals.permission_request.connect(view, ?*anyopaque, &onPermissionRequest, null, .{});
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

            overlay.setup(window, view, options, (config.id ++ "\x00")[0..config.id.len :0]);
            if (options.visible) window.present();

            return WindowHandle{
                .gtk_window = window,
                .app_window = app_window,
                .web_view = view,
            };
        }

        fn onWindowCloseRequest(window: *gtk.Window, win: *App.Window) callconv(.c) c_int {
            if ((std.mem.eql(u8, win.label, "main") and config.on_close == .hide) or win.options.hide_on_close) {
                window.as(gtk.Widget).setVisible(0);
                return 1;
            }
            overlay.forget(window);

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

            if (App.main_window == window) {
                App.main_window = null;
            }

            std.heap.smp_allocator.free(win.label);
            std.heap.smp_allocator.free(win.options.title);
            if (win.options.url) |u| std.heap.smp_allocator.free(u);
            std.heap.smp_allocator.destroy(win);

            if (remaining == 0) {
                App.quit(0);
            }
            return 0;
        }

        var window_open_counter = std.atomic.Value(u32).init(1);

        /// The page asks for the microphone, camera, screen, location or
        /// notifications: allowed only if the app declares it and the page's
        /// origin is trusted (permissions.allowForPage).
        fn onPermissionRequest(view: *webkit.WebView, req: *webkit.PermissionRequest, _: ?*anyopaque) callconv(.c) c_int {
            var buf: [3]permissions.Kind = undefined;
            const kinds = requestKinds(req, &buf) orelse return 0;
            const page = if (webkit_web_view_get_uri(view)) |u| std.mem.span(u) else "";
            var allow = kinds.len > 0;
            for (kinds) |k| {
                if (!permissions.allowForPage(k, local, page)) allow = false;
            }
            if (allow) webkit_permission_request_allow(req) else webkit_permission_request_deny(req);
            return 1;
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
                    decision.ignore();
                    var obuf: [512]u8 = undefined;
                    const o = security.origin(&obuf, std.mem.span(uri));
                    if (config.window_open == .new_window and o != null and local.contains(o.?)) {
                        const id = window_open_counter.fetchAdd(1, .monotonic);
                        var label_buf: [32]u8 = undefined;
                        const label = std.fmt.bufPrint(&label_buf, "win-{d}", .{id}) catch return 1;
                        const uri_span = std.mem.span(uri);
                        const label_z = std.heap.smp_allocator.dupeZ(u8, label) catch return 1;
                        defer std.heap.smp_allocator.free(label_z);
                        const uri_z = std.heap.smp_allocator.dupeZ(u8, uri_span) catch return 1;
                        defer std.heap.smp_allocator.free(uri_z);
                        _ = App.openWindow(.{
                            .label = label_z,
                            .url = uri_z,
                        }) catch |err| log.err("window.open failed: {s}", .{@errorName(err)});
                    } else if (App.getWindow("main")) |mw| {
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
