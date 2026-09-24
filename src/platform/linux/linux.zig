//! Linux platform backend for Oriel (GTK4 + WebKitGTK 6.0).

const std = @import("std");
const App = @import("../../core/App.zig");

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
pub const quit = ShellMod.quit;
pub const setMenu = ShellMod.setMenu;
pub const createWindow = ShellMod.createWindow;

pub fn run(io: std.Io, comptime api: anytype, comptime config: anytype) u8 {
    const S = ShellMod.Shell(api, config);
    return S.run(io);
}

// GTK types behind `App.gtk_app` / `App.main_window` (used by dialog, notification)
pub const GtkApp = @import("gtk").Application;
pub const GtkWindow = @import("gtk").Window;

test {
    std.testing.refAllDecls(window);
    std.testing.refAllDecls(ShellMod);
    std.testing.refAllDecls(bridge);
    std.testing.refAllDecls(scheme);
    std.testing.refAllDecls(dev_server);
}
