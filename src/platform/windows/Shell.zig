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
pub const WM_NOTIFY_CALLBACK: win32.UINT = win32.WM_APP + 3;

var exit_code: u8 = 0;
/// The "main" app window, or null once it has been destroyed. Use it as a
/// parent for dialogs; never as a message target (see `host_hwnd`).
pub var main_hwnd: ?win32.HWND = null;
/// Hidden top-level window owned by the shell for the whole run. Main-thread
/// dispatch, hotkeys, tray callbacks and clipboard ownership target it, so
/// they keep working when the main window is closed while others stay open.
/// (Not a message-only HWND_MESSAGE window: those miss broadcasts such as
/// "TaskbarCreated" and can't become foreground for tray popup menus.)
pub var host_hwnd: ?win32.HWND = null;
const HOST_CLASS_NAME = std.unicode.utf8ToUtf16LeStringLiteral("OrielHostWindow");

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
    cleanup_fn: ?*const fn (ctx: ?*anyopaque) void,
};

var task_queue: std.ArrayList(Task) = .empty;
var task_mutex: win32.SRWLOCK = win32.SRWLOCK_INIT;
/// Set under `task_mutex` when `run` stops, before its last drain: a task
/// queued after that would never run (and a `runOnMainThread` caller
/// would wait forever), so it is cleaned up at once instead.
var shutting_down = false;

/// Dispatches a task to execute on the main Win32 UI thread.
///
/// Thread-safe: can be called from any thread. Tasks queued before `run`
/// creates the host window run once it exists; tasks still queued when the
/// message loop ends run during shutdown (see `drainAtShutdown`). If the task
/// can't be queued (out of memory) it is logged and dropped: use
/// `dispatchWithCleanup` when `ctx` owns memory or references.
pub fn dispatchToMainThread(func: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) void {
    dispatchWithCleanup(func, ctx, null);
}

/// Like `dispatchToMainThread`, but `cleanup(ctx)` runs instead of `func` when
/// the task can't be queued (out of memory, or queued after shutdown; then on
/// the calling thread, so it must only free memory, not touch COM objects or
/// windows) or when it is still queued at shutdown (then on the main thread,
/// after the message loop).
pub fn dispatchWithCleanup(
    func: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
    cleanup: ?*const fn (ctx: ?*anyopaque) void,
) void {
    win32.AcquireSRWLockExclusive(&task_mutex);
    // The main thread may still queue while it drains (drainAtShutdown loops).
    if (shutting_down and win32.GetCurrentThreadId() != main_thread_id) {
        win32.ReleaseSRWLockExclusive(&task_mutex);
        if (cleanup) |c| c(ctx) else log.warn("dispatchToMainThread: dropped a task queued after shutdown", .{});
        return;
    }
    task_queue.append(std.heap.smp_allocator, .{ .run_fn = func, .ctx = ctx, .cleanup_fn = cleanup }) catch {
        win32.ReleaseSRWLockExclusive(&task_mutex);
        log.err("dispatchToMainThread failed: out of memory", .{});
        if (cleanup) |c| c(ctx);
        return;
    };
    // Read under the lock: `run` clears host_hwnd under it at shutdown.
    const target = host_hwnd;
    win32.ReleaseSRWLockExclusive(&task_mutex);

    // Before `run` creates the host window, tasks wait in the queue; `run`
    // drains it once the window exists.
    if (target) |hwnd| {
        if (win32.PostMessageW(hwnd, WM_DISPATCH, 0, 0) == win32.FALSE) {
            log.err("dispatchToMainThread: PostMessageW failed ({d})", .{win32.GetLastError()});
        }
    }
}

fn takeTasks() ?[]Task {
    win32.AcquireSRWLockExclusive(&task_mutex);
    defer win32.ReleaseSRWLockExclusive(&task_mutex);
    if (task_queue.items.len == 0) return null;
    return task_queue.toOwnedSlice(std.heap.smp_allocator) catch {
        log.err("processDispatchQueue failed: out of memory", .{});
        return null;
    };
}

pub fn processDispatchQueue() void {
    const tasks = takeTasks() orelse return;
    defer std.heap.smp_allocator.free(tasks);
    for (tasks) |t| t.run_fn(t.ctx);
}

/// Called on the main thread after the message loop ended: tasks with a
/// cleanup are cleaned up, the others still run once (so their memory is
/// freed and any thread waiting on them is released). Loops because a task
/// may queue another one.
fn drainAtShutdown() void {
    while (takeTasks()) |tasks| {
        defer std.heap.smp_allocator.free(tasks);
        for (tasks) |t| {
            if (t.cleanup_fn) |c| c(t.ctx) else t.run_fn(t.ctx);
        }
    }
}

/// Run `func(ctx)` on the main (UI) thread and wait for it to finish.
///
/// Runs directly when already on the main thread. From another thread the
/// call is queued and the caller blocks until it ran. Returns
/// error.AppNotRunning when the shell isn't running, or when the task was
/// dropped (out of memory) or discarded at shutdown instead of running.
pub fn runOnMainThread(comptime Ctx: type, ctx: *Ctx, comptime func: fn (*Ctx) void) error{ AppNotRunning, CreateEventFailed }!void {
    const main_id = main_thread_id;
    if (main_id == 0) return error.AppNotRunning;
    if (win32.GetCurrentThreadId() == main_id) {
        func(ctx);
        return;
    }

    const Call = struct {
        ctx: *Ctx,
        event: win32.HANDLE,
        ran: bool = false,

        fn run(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            func(self.ctx);
            self.ran = true;
            signal(self.event);
        }

        fn cleanup(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            signal(self.event);
        }

        fn signal(event: win32.HANDLE) void {
            // The waiter owns this stack frame: failing to wake it is unrecoverable.
            if (win32.SetEvent(event) == win32.FALSE) std.debug.panic("SetEvent failed ({d})", .{win32.GetLastError()});
        }
    };

    const event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse return error.CreateEventFailed;
    defer _ = win32.CloseHandle(event); // nothing to undo if closing fails
    var call: Call = .{ .ctx = ctx, .event = event };
    dispatchWithCleanup(&Call.run, &call, &Call.cleanup);
    // `call` lives on this stack until the task has signalled, so returning
    // early on a wait failure would leave the main thread writing into a dead
    // frame: treat it as fatal.
    if (win32.WaitForSingleObject(event, win32.INFINITE) != win32.WAIT_OBJECT_0) {
        std.debug.panic("WaitForSingleObject failed ({d})", .{win32.GetLastError()});
    }
    if (!call.ran) return error.AppNotRunning;
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
pub var current_haccel: ?win32.HACCEL = null;
pub var on_window_created_fn: ?*const fn (hwnd: win32.HWND) void = null;
pub fn handleMenuCommand(id: win32.WPARAM) void {
    if (on_menu_command_fn) |f| f(id & 0xFFFF);
}

// Tray callback hook
pub var on_tray_message_fn: ?*const fn (wParam: win32.WPARAM, lParam: win32.LPARAM) void = null;
pub fn handleTrayMessage(wParam: win32.WPARAM, lParam: win32.LPARAM) void {
    if (on_tray_message_fn) |f| f(wParam, lParam);
}

// Notification callback hook
pub var on_notify_message_fn: ?*const fn (wParam: win32.WPARAM, lParam: win32.LPARAM) void = null;
pub fn handleNotifyMessage(wParam: win32.WPARAM, lParam: win32.LPARAM) void {
    if (on_notify_message_fn) |f| f(wParam, lParam);
}

// Shell shutdown hook
pub var on_shutdown_fn: ?*const fn () void = null;

fn hostWndProc(hwnd: win32.HWND, uMsg: win32.UINT, wParam: win32.WPARAM, lParam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    switch (uMsg) {
        WM_DISPATCH => {
            processDispatchQueue();
            return 0;
        },
        win32.WM_HOTKEY => {
            handleHotKey(wParam);
            return 0;
        },
        WM_TRAY_CALLBACK => {
            handleTrayMessage(wParam, lParam);
            return 0;
        },
        WM_NOTIFY_CALLBACK => {
            handleNotifyMessage(wParam, lParam);
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam),
    }
}

/// Create the hidden host window (never shown; WS_EX_TOOLWINDOW keeps it off
/// the taskbar and Alt+Tab).
fn createHostWindow() !win32.HWND {
    const hInst: win32.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null) orelse return error.NoModuleHandle);
    const wc = win32.WNDCLASSEXW{
        .lpfnWndProc = &hostWndProc,
        .hInstance = hInst,
        .lpszClassName = HOST_CLASS_NAME,
    };
    if (win32.RegisterClassExW(&wc) == 0 and win32.GetLastError() != 1410) { // ERROR_CLASS_ALREADY_EXISTS
        return error.RegisterClassFailed;
    }
    return win32.CreateWindowExW(win32.WS_EX_TOOLWINDOW, HOST_CLASS_NAME, null, win32.WS_POPUP, 0, 0, 0, 0, null, null, hInst, null) orelse
        error.CreateWindowFailed;
}

pub fn setMenu(items: anytype, on_action: anytype) !void {
    const menu_mod = @import("../../modules/menu.zig");
    try menu_mod.set(items, on_action);
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

            const host = createHostWindow() catch |err| {
                log.err("failed to create the host window: {s}", .{@errorName(err)});
                return 1;
            };
            win32.AcquireSRWLockExclusive(&task_mutex);
            host_hwnd = host;
            shutting_down = false;
            win32.ReleaseSRWLockExclusive(&task_mutex);
            defer {
                if (on_shutdown_fn) |f| f();
                win32.AcquireSRWLockExclusive(&task_mutex);
                host_hwnd = null;
                shutting_down = true; // later tasks are cleaned up, not queued
                win32.ReleaseSRWLockExclusive(&task_mutex);
                if (win32.DestroyWindow(host) == win32.FALSE) {
                    log.err("DestroyWindow(host) failed ({d})", .{win32.GetLastError()});
                }
                drainAtShutdown();
            }
            // Tasks queued before the host window existed.
            processDispatchQueue();

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
                if (current_haccel) |haccel| {
                    const top_wnd = if (msg.hwnd) |h| (win32.GetAncestor(h, win32.GA_ROOT) orelse h) else main_hwnd;
                    if (top_wnd) |wnd| {
                        if (win32.TranslateAcceleratorW(wnd, haccel, &msg) != 0) {
                            continue;
                        }
                    }
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
