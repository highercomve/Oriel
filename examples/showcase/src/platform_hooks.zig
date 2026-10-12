//! Platform hooks in Zig (`oriel.hooks`, docs/platform-hooks.md): every
//! window and web view the app opens, with its native handle. The showcase
//! logs them, and on Linux turns on a WebKitGTK setting through the handle,
//! before the page loads. Android and iOS hook natively instead
//! (`oriel.hooks.available` is false there).

const std = @import("std");
const oriel = @import("oriel");

const log = std.log.scoped(.showcase_hooks);

/// Before `oriel.main`, so the main window is seen too.
pub fn install() void {
    if (comptime !oriel.hooks.available) return;
    oriel.hooks.subscribe(.{
        .window_created = windowCreated,
        .webview_created = webViewCreated,
        .webview_destroyed = webViewDestroyed,
        .window_destroyed = windowDestroyed,
    }) catch |err| log.warn("subscribe: {s}", .{@errorName(err)});
}

fn windowCreated(w: oriel.hooks.Window) void {
    log.info("window \"{s}\" created ({s} {*})", .{ w.label, @tagName(w.native), nativeWindow(w.native) });
}

fn windowDestroyed(w: oriel.hooks.Window) void {
    log.info("window \"{s}\" destroyed", .{w.label});
}

fn webViewCreated(v: oriel.hooks.WebView) void {
    log.info("web view of \"{s}\" created ({s})", .{ v.label, @tagName(v.native) });
    switch (v.native) {
        .webkitgtk => |view| if (comptime webkit) smoothScrolling(view),
        .wkwebview, .webview2 => {},
    }
}

fn webViewDestroyed(v: oriel.hooks.WebView) void {
    log.info("web view of \"{s}\" destroyed", .{v.label});
}

fn nativeWindow(n: oriel.hooks.NativeWindow) *anyopaque {
    return switch (n) {
        inline else => |p| p,
    };
}

// WebKitGTK through the handle (desktop Linux with a web view; -Dnative_ui
// links no WebKit).
const webkit = oriel.target.is_desktop_linux and !oriel.options.native_ui;
extern fn webkit_web_view_get_settings(view: *anyopaque) ?*anyopaque;
extern fn webkit_settings_set_enable_smooth_scrolling(settings: *anyopaque, enabled: c_int) void;
extern fn webkit_settings_get_enable_smooth_scrolling(settings: *anyopaque) c_int;

fn smoothScrolling(view: *anyopaque) void {
    const settings = webkit_web_view_get_settings(view) orelse return;
    webkit_settings_set_enable_smooth_scrolling(settings, 1);
    log.info("WebKitGTK smooth scrolling: {}", .{webkit_settings_get_enable_smooth_scrolling(settings) != 0});
}
