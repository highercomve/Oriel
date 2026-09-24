//! macOS platform backend for Oriel (AppKit + WKWebView through the
//! Objective-C runtime, via zig-objc).

const std = @import("std");
const App = @import("../../core/App.zig");

pub const cocoa = @import("cocoa.zig");
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
    // Instantiate the generic shell so `zig build check` compiles the run
    // loop, window creation and the WebKit delegates too.
    _ = &run;
    const S = ShellMod.Shell(.{ .commands = struct {} }, .{ .id = "dev.oriel.Check", .title = "check", .assets = &.{} });
    _ = &S.run;
    const Probe = struct {
        fn touch(_: *u8) void {}
        fn call(x: *u8) !void {
            return ShellMod.runOnMainThread(u8, x, touch);
        }
    };
    _ = &Probe.call;
    std.testing.refAllDecls(cocoa);
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(ShellMod);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(scheme);
    std.testing.refAllDecls(dev_server);
}
