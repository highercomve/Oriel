//! Entry points into the app-specific (comptime `api`/`config`) parts of the
//! backend, for the JNI natives in `exports.zig`, which can't be generic.
//! `WindowCreator.init` sets them when `run` starts; `deinit` clears them.

const std = @import("std");
const App = @import("../../core/App.zig");
const window = @import("window.zig");

/// A response for WebView's `shouldInterceptRequest` (`scheme.zig`).
pub const Response = struct {
    status: u16,
    mime: []const u8,
    /// "Name: value\n" lines.
    headers: []const u8,
    body: []const u8,
};

pub var create_window: ?*const fn (App.WindowOptions, *App.Window) anyerror!window.WindowHandle = null;
/// A message from a page (UI thread).
pub var on_message: ?*const fn (id: u32, data: []const u8, origin: []const u8) void = null;
/// An `https://app.localhost/...` (or isolation) request, on a WebView IO
/// thread. The response is written into `arena`.
pub var serve: ?*const fn (arena: std.mem.Allocator, id: u32, url: []const u8) ?Response = null;
/// A navigation of window `id` (UI thread): true lets the webview load it.
pub var navigation: ?*const fn (id: u32, url: []const u8, user_gesture: bool) bool = null;
/// `window.open` / `target="_blank"` from window `id` (UI thread).
pub var new_window: ?*const fn (id: u32, url: []const u8, user_gesture: bool) void = null;
/// A later launch intent (UI thread): its arguments.
pub var on_new_intent: ?*const fn (args: []const []const u8) void = null;
/// A page load failed (UI thread): the dev server may still be starting.
pub var load_failed: ?*const fn (id: u32) void = null;
/// getUserMedia from a page (UI thread): allowed kinds (bit 0 microphone, bit 1 camera).
pub var allow_media: ?*const fn (id: u32, origin: []const u8, kinds: u32) bool = null;

pub fn clear() void {
    create_window = null;
    on_message = null;
    serve = null;
    navigation = null;
    new_window = null;
    on_new_intent = null;
    load_failed = null;
    allow_media = null;
}
