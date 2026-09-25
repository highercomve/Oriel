//! Windows platform backend for Oriel (Win32 + WebView2).

const std = @import("std");
const App = @import("../../core/App.zig");

pub const win32 = @import("win32.zig");
pub const webview2 = @import("webview2.zig");
pub const window = @import("window.zig");
pub const ShellMod = @import("Shell.zig");
pub const bridge = @import("bridge.zig");
pub const scheme = @import("scheme.zig");
pub const dev_server = @import("dev_server.zig");

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
pub const overlay = @import("overlay.zig");
pub const setWindowPlacement = overlay.setWindowPlacement;
pub const setWindowClickThrough = overlay.setWindowClickThrough;
pub const setWindowAlwaysOnTop = overlay.setWindowAlwaysOnTop;
pub const getWindowWorkArea = overlay.getWindowWorkArea;
pub const openExternal = window.openExternal;

pub const evalJs = bridge.evalJs;
pub const evalJsByLabel = bridge.evalJsByLabel;
pub const quit = ShellMod.quit;
pub const setMenu = ShellMod.setMenu;
pub const createWindow = ShellMod.createWindow;
pub const dispatchToMainThread = ShellMod.dispatchToMainThread;
pub const runOnMainThread = ShellMod.runOnMainThread;

pub fn run(io: std.Io, comptime api: anytype, comptime config: anytype) u8 {
    const S = ShellMod.Shell(api, config);
    return S.run(io);
}

test {
    // Instantiate the generic shell so `zig build check -Dtarget=x86_64-windows`
    // compiles the message loop, window creation and WebView2 wiring too.
    _ = &run;
    const S = ShellMod.Shell(.{ .commands = struct {} }, .{ .id = "dev.oriel.Check", .title = "check", .assets = &.{} });
    _ = &S.run;
    // A dev build too: the dev server and the load retry only exist there.
    const SDev = ShellMod.Shell(.{ .commands = struct {} }, .{
        .id = "dev.oriel.Check",
        .title = "check",
        .assets = &.{},
        .dev = .{ .url = "http://localhost:5173", .command = &.{ "node_modules/.bin/vite", "--strictPort" }, .cwd = "frontend" },
    });
    _ = &SDev.run;
    const Probe = struct {
        fn touch(_: *u8) void {}
        fn call(x: *u8) !void {
            return ShellMod.runOnMainThread(u8, x, touch);
        }
    };
    _ = &Probe.call;
    std.testing.refAllDecls(win32);
    std.testing.refAllDecls(webview2);
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(ShellMod);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(scheme);
    std.testing.refAllDecls(dev_server);
}
