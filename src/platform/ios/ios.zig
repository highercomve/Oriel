//! iOS platform backend for Oriel: UIKit + WKWebView through the
//! Objective-C runtime (`../apple/objc.zig`, declared without SDK headers,
//! so the backend type-checks on any host; linking needs the iOS SDK).
//!
//! - `Shell.zig`: UIApplicationMain, the app and scene delegates, the main
//!   thread's task queue, `quit`.
//! - `window.zig`: a view controller + WKWebView per window, scenes.
//! - `bridge.zig`, `scheme.zig`, `js_dialogs.zig`: as on macOS.

const std = @import("std");
const App = @import("../../core/App.zig");

pub const apple = @import("apple.zig");
pub const window = @import("window.zig");
pub const ShellMod = @import("Shell.zig");
pub const bridge = @import("bridge.zig");
pub const scheme = @import("scheme.zig");
pub const js_dialogs = @import("js_dialogs.zig");

pub const WindowHandle = window.WindowHandle;
pub const WindowSize = window.WindowSize;
pub const Mutex = ShellMod.Mutex;

pub const showWindow = window.showWindow;
pub const hideWindow = window.hideWindow;
pub const toggleWindow = window.toggleWindow;
pub const closeWindow = window.closeWindow;
pub const postCloseWindow = window.postCloseWindow;
pub const focusWindow = window.focusWindow;
pub const destroyWindow = window.destroyWindow;
pub const setWindowTitle = window.setWindowTitle;
pub const setWindowFullscreen = window.setWindowFullscreen;
pub const isWindowFullscreen = window.isWindowFullscreen;
pub const setWindowMaximized = window.setWindowMaximized;
pub const isWindowMaximized = window.isWindowMaximized;
pub const setWindowSize = window.setWindowSize;
pub const getWindowSize = window.getWindowSize;
pub const setWindowPlacement = window.setWindowPlacement;
pub const setWindowClickThrough = window.setWindowClickThrough;
pub const setWindowAlwaysOnTop = window.setWindowAlwaysOnTop;
pub const getWindowWorkArea = window.getWindowWorkArea;
pub const startWindowDrag = window.startWindowDrag;
pub const openExternal = window.openExternal;
pub const dispatchWithCleanup = ShellMod.dispatchWithCleanup;

pub const evalJs = bridge.evalJs;
pub const evalJsByLabel = bridge.evalJsByLabel;
pub const quit = ShellMod.quit;
pub const setMenu = ShellMod.setMenu;
pub const createWindow = ShellMod.createWindow;
pub const dispatchToMainThread = ShellMod.dispatchToMainThread;
pub const runOnMainThread = ShellMod.runOnMainThread;

/// The app's lifecycle: "background", "foreground", "memory-warning" (main
/// thread). See `Shell.SystemEventHandler`.
pub const SystemEventHandler = ShellMod.SystemEventHandler;
pub const onSystemEvent = ShellMod.onSystemEvent;

pub fn run(io: std.Io, comptime api: anytype, comptime config: anytype) u8 {
    const S = ShellMod.Shell(api, config);
    return S.run(io);
}

test {
    _ = &run;
    const S = ShellMod.Shell(.{ .commands = struct {} }, .{ .id = "dev.oriel.Check", .title = "check", .assets = &.{} });
    _ = &S.run;
    std.testing.refAllDecls(apple);
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(ShellMod);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(scheme);
    std.testing.refAllDecls(js_dialogs);
    _ = App;
}
