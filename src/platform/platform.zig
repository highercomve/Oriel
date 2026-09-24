//! Platform abstraction layer for Oriel.
//!
//! Selects the OS-specific shell implementation at compile time.
//! Currently supported:
//!   - Linux: GTK4 + WebKitGTK 6.0 (`src/platform/linux/`)
//!   - Windows: Win32 + WebView2 (`src/platform/windows/`)
//!
//! Any platform backend must export the following declarations:
//!
//! Types:
//!   - `WindowHandle`: Platform-specific handle to a window and its webview. Must support `.eql(other)`.
//!   - `Mutex`: Mutex implementation providing `.init()`, `.lock()`, `.unlock()`.
//!
//! Window Operations:
//!   - `showWindow(handle: WindowHandle) void`: Present the window to the user.
//!   - `hideWindow(handle: WindowHandle) void`: Hide the window without closing it.
//!   - `toggleWindow(handle: WindowHandle) void`: Toggle visibility / focus state.
//!   - `closeWindow(handle: WindowHandle) void`: Request window closure.
//!   - `setWindowTitle(handle: WindowHandle, title: [:0]const u8) void`: Set window title.
//!   - `setWindowFullscreen(handle: WindowHandle, fullscreen: bool) void`: Set fullscreen state.
//!   - `isWindowFullscreen(handle: WindowHandle) bool`: Query fullscreen state.
//!   - `setWindowMaximized(handle: WindowHandle, maximized: bool) void`: Set maximized state.
//!   - `isWindowMaximized(handle: WindowHandle) bool`: Query maximized state.
//!   - `setWindowSize(handle: WindowHandle, width: c_int, height: c_int) void`: Set window default/current size.
//!   - `getWindowSize(handle: WindowHandle) struct { width: c_int, height: c_int }`: Query current window size.
//!   - `createWindow(options: anytype, win_inst: anytype) anyerror!WindowHandle`: Create a native window.
//!   - `destroyWindow(handle: WindowHandle) void`: Destroy a native window and its associated platform resources.
//!
//! Lifecycle and Application Operations:
//!   - `run(io: std.Io, comptime api: anytype, comptime config: anytype) u8`: Run the platform event loop.
//!   - `quit(code: u8) void`: Safely exit the main application loop from any thread.
//!   - `openExternal(uri: [*:0]const u8) void`: Open a URI using the operating system's default handler.
//!   - `evalJs(handle: ?WindowHandle, script: [:0]const u8) void`: Evaluate JS in a window (or all if null).
//!   - `setMenu(items: anytype, on_action: anytype) anyerror!void`: Set native application menubar.

const builtin = @import("builtin");
const std = @import("std");

pub const impl = switch (builtin.os.tag) {
    .linux => @import("linux/linux.zig"),
    .windows => @import("windows/windows.zig"),
    else => @compileError("Unsupported operating system: " ++ @tagName(builtin.os.tag) ++ ". Supported platforms are Linux and Windows."),
};

// Comptime check that the selected implementation exports all required declarations.
comptime {
    const required_decls = [_][]const u8{
        "WindowHandle",
        "WindowSize",
        "Mutex",
        "showWindow",
        "hideWindow",
        "toggleWindow",
        "closeWindow",
        "setWindowTitle",
        "setWindowFullscreen",
        "isWindowFullscreen",
        "setWindowMaximized",
        "isWindowMaximized",
        "setWindowSize",
        "getWindowSize",
        "createWindow",
        "destroyWindow",
        "run",
        "quit",
        "openExternal",
        "evalJs",
        "setMenu",
    };
    for (required_decls) |decl_name| {
        if (!@hasDecl(impl, decl_name)) {
            @compileError("Platform implementation for " ++ @tagName(builtin.os.tag) ++ " is missing required declaration: " ++ decl_name);
        }
    }
}

// Re-export interface declarations from the selected implementation
pub const WindowHandle = impl.WindowHandle;
pub const WindowSize = impl.WindowSize;
pub const Mutex = impl.Mutex;
pub const showWindow = impl.showWindow;
pub const hideWindow = impl.hideWindow;
pub const toggleWindow = impl.toggleWindow;
pub const closeWindow = impl.closeWindow;
pub const setWindowTitle = impl.setWindowTitle;
pub const setWindowFullscreen = impl.setWindowFullscreen;
pub const isWindowFullscreen = impl.isWindowFullscreen;
pub const setWindowMaximized = impl.setWindowMaximized;
pub const isWindowMaximized = impl.isWindowMaximized;
pub const setWindowSize = impl.setWindowSize;
pub const getWindowSize = impl.getWindowSize;
pub const createWindow = impl.createWindow;
pub const destroyWindow = impl.destroyWindow;
pub const run = impl.run;
pub const quit = impl.quit;
pub const openExternal = impl.openExternal;
pub const evalJs = impl.evalJs;
pub const setMenu = impl.setMenu;

// Platform-specific declarations (e.g. for Linux backward compatibility)
pub const GtkApp = if (@hasDecl(impl, "GtkApp")) impl.GtkApp else void;
pub const GtkWindow = if (@hasDecl(impl, "GtkWindow")) impl.GtkWindow else void;

test {
    std.testing.refAllDecls(@This());
}
