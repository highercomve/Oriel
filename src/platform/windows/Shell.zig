//! Windows application shell, main loop, and dispatch queue.
//!
//! Manages COM initialization, main message loop, main-thread task dispatching,
//! global shortcut routing, tray icon interaction, and menu commands.

const std = @import("std");
const win32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const window = @import("window.zig");
const WindowHandle = window.WindowHandle;
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");

const log = std.log.scoped(.oriel);

pub const WM_DISPATCH: win32.UINT = win32.WM_APP + 1;
pub const WM_TRAY_CALLBACK: win32.UINT = win32.WM_APP + 2;

var exit_code: u8 = 0;
pub var main_hwnd: ?win32.HWND = null;

pub const Mutex = struct {
    inner: win32.SRWLOCK = win32.SRWLOCK_INIT,

    pub fn init() Mutex {
        return .{};
    }

    pub fn lock(self: *Mutex) void {
        win32.AcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        win32.ReleaseSRWLockExclusive(&self.inner);
    }
};

const Task = struct {
    run_fn: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
};

var task_queue: std.ArrayList(Task) = .empty;
var task_mutex: win32.SRWLOCK = win32.SRWLOCK_INIT;

/// Dispatches a task to execute on the main Win32 UI thread.
///
/// Thread-safe: can be called from any thread.
/// If task allocation fails due to out-of-memory, an error is logged and the task is dropped.
pub fn dispatchToMainThread(func: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) void {
    win32.AcquireSRWLockExclusive(&task_mutex);
    task_queue.append(std.heap.smp_allocator, .{ .run_fn = func, .ctx = ctx }) catch {
        win32.ReleaseSRWLockExclusive(&task_mutex);
        log.err("dispatchToMainThread failed: out of memory", .{});
        return;
    };
    win32.ReleaseSRWLockExclusive(&task_mutex);

    if (main_hwnd) |hwnd| {
        _ = win32.PostMessageW(hwnd, WM_DISPATCH, 0, 0);
    }
}

pub fn processDispatchQueue() void {
    win32.AcquireSRWLockExclusive(&task_mutex);
    if (task_queue.items.len == 0) {
        win32.ReleaseSRWLockExclusive(&task_mutex);
        return;
    }
    const tasks = task_queue.toOwnedSlice(std.heap.smp_allocator) catch {
        win32.ReleaseSRWLockExclusive(&task_mutex);
        log.err("processDispatchQueue failed: out of memory", .{});
        return;
    };
    win32.ReleaseSRWLockExclusive(&task_mutex);
    defer std.heap.smp_allocator.free(tasks);

    for (tasks) |t| {
        t.run_fn(t.ctx);
    }
}

pub var active_create_window_fn: ?*const fn (options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle = null;

pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) !WindowHandle {
    if (active_create_window_fn) |f| return f(options, win_inst) else return error.AppNotRunning;
}

pub var main_thread_id: win32.DWORD = 0;

pub fn quit(code: u8) void {
    exit_code = code;
    if (main_thread_id != 0) {
        if (win32.GetCurrentThreadId() == main_thread_id) {
            win32.PostQuitMessage(@intCast(code));
        } else {
            _ = win32.PostThreadMessageW(main_thread_id, win32.WM_QUIT, @intCast(code), 0);
        }
    } else {
        win32.PostQuitMessage(@intCast(code));
    }
}

// Global shortcut hook
pub var on_hotkey_fn: ?*const fn (id: usize) void = null;
pub fn handleHotKey(id: win32.WPARAM) void {
    if (on_hotkey_fn) |f| f(id);
}

// Menu hook
pub var on_menu_command_fn: ?*const fn (id: usize) void = null;
pub fn handleMenuCommand(id: win32.WPARAM) void {
    if (on_menu_command_fn) |f| f(id);
}

// Tray callback hook
pub var on_tray_message_fn: ?*const fn (wParam: win32.WPARAM, lParam: win32.LPARAM) void = null;
pub fn handleTrayMessage(wParam: win32.WPARAM, lParam: win32.LPARAM) void {
    if (on_tray_message_fn) |f| f(wParam, lParam);
}

pub fn setMenu(items: anytype, on_action: anytype) !void {
    _ = items;
    _ = on_action;
    return error.NotImplemented;
}

pub fn Shell(comptime api: App.Api, comptime config: App.Config) type {
    const dev_url: ?[]const u8 = if (config.dev) |d| d.url else null;
    const local: security.Local = comptime .{ .dev_origin = if (dev_url) |u| blk: {
        var buf: [512]u8 = undefined;
        const o = security.origin(&buf, u) orelse @compileError("invalid dev URL: " ++ u);
        const copy = o[0..o.len].*;
        break :blk &copy;
    } else null };

    const csp_z: ?[:0]const u8 = if (config.security.csp) |c| (c ++ "\x00")[0..c.len :0] else null;
    const Creator = window.WindowCreator(api, config, local, csp_z);

    return struct {
        pub fn run(io: std.Io) u8 {
            _ = io;
            main_thread_id = win32.GetCurrentThreadId();
            defer main_thread_id = 0;

            const hr = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED | win32.COINIT_DISABLE_OLE1DDE);
            if (hr != win32.S_OK and hr != win32.S_FALSE) {
                log.err("CoInitializeEx failed: 0x{X}", .{@as(u32, @bitCast(hr))});
                return 1;
            }
            defer win32.CoUninitialize();

            active_create_window_fn = &Creator.createWindow;
            defer active_create_window_fn = null;

            const main_win = App.openWindow(.{
                .label = "main",
                .title = config.title,
                .width = config.width,
                .height = config.height,
                .min_width = config.min_width,
                .min_height = config.min_height,
                .max_width = config.max_width,
                .max_height = config.max_height,
                .resizable = config.resizable,
                .decorations = config.decorations,
                .fullscreen = config.fullscreen,
                .maximized = config.maximized,
                .remember_geometry = config.remember_geometry,
            }) catch |err| {
                log.err("failed to open main window: {s}", .{@errorName(err)});
                return 1;
            };

            main_hwnd = main_win.handle.hwnd;

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});

            var msg: win32.MSG = undefined;
            while (true) {
                const res = win32.GetMessageW(&msg, null, 0, 0);
                if (@intFromEnum(res) == 0) {
                    exit_code = @truncate(msg.wParam);
                    break;
                } else if (@intFromEnum(res) < 0) {
                    break;
                }
                _ = win32.TranslateMessage(&msg);
                _ = win32.DispatchMessageW(&msg);
            }

            main_hwnd = null;
            return exit_code;
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
