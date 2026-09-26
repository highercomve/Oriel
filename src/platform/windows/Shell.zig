//! Windows application shell, main loop, and dispatch queue.
//!
//! Manages COM initialization, main message loop, main-thread task dispatching,
//! global shortcut routing, tray icon interaction, and menu commands.

const std = @import("std");
const win32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const dev_server = @import("dev_server.zig");
const window = @import("window.zig");
const WindowHandle = window.WindowHandle;
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");

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
        win32.WM_COPYDATA => {
            if (lParam == 0) return 0;
            const p_cds: *const win32.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (p_cds.dwData != COPYDATA_ARGS) return 0;
            const bytes: []const u8 = if (p_cds.cbData > 0 and p_cds.cbData <= max_forwarded_bytes and p_cds.lpData != null)
                @as([*]const u8, @ptrCast(p_cds.lpData.?))[0..p_cds.cbData]
            else
                "[]";
            if (on_second_instance_fn) |f| f(bytes);
            return 1;
        },
        else => return win32.DefWindowProcW(hwnd, uMsg, wParam, lParam),
    }
}

const build_opts = @import("build_options");
const deep_link = if (build_opts.deep_link) @import("../../modules/deep_link.zig") else struct {};

/// WM_COPYDATA from a second launch: its arguments (without argv[0]) as a
/// JSON array of strings.
const COPYDATA_ARGS: win32.ULONG_PTR = 0x41524753; // 'ARGS'
const max_forwarded_bytes = 256 * 1024;
/// Set by Shell.run: handles a forwarded launch on the main thread.
var on_second_instance_fn: ?*const fn (json: []const u8) void = null;

/// This launch's arguments without argv[0], as UTF-8. Caller frees with `freeArgs`.
fn launchArgs(gpa: std.mem.Allocator) ![][]u8 {
    var list: std.ArrayList([]u8) = .empty;
    errdefer freeArgs(gpa, list.items);
    errdefer list.deinit(gpa);
    var argc: c_int = 0;
    const w_argv = win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc) orelse return list.toOwnedSlice(gpa);
    defer _ = win32.LocalFree(@ptrCast(w_argv));
    var idx: usize = 1;
    while (idx < @as(usize, @intCast(argc))) : (idx += 1) {
        const arg = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(w_argv[idx]));
        errdefer gpa.free(arg);
        try list.append(gpa, arg);
    }
    return list.toOwnedSlice(gpa);
}

fn freeArgs(gpa: std.mem.Allocator, args: []const []u8) void {
    for (args) |a| gpa.free(a);
    gpa.free(args);
}

pub fn encodeArgs(gpa: std.mem.Allocator, args: []const []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(gpa, args, .{});
}

pub fn decodeArgs(gpa: std.mem.Allocator, json: []const u8) !std.json.Parsed([]const []const u8) {
    return std.json.parseFromSlice([]const []const u8, gpa, json, .{});
}

test "forwarded arguments round-trip" {
    const gpa = std.testing.allocator;
    const args = [_][]const u8{ "--flag", "two words", "app://x?a=1&b=\"q\"", "ünïcode", "" };
    const json = try encodeArgs(gpa, &args);
    defer gpa.free(json);
    const parsed = try decodeArgs(gpa, json);
    defer parsed.deinit();
    try std.testing.expectEqual(args.len, parsed.value.len);
    for (args, parsed.value) |a, b| try std.testing.expectEqualStrings(a, b);
    const empty = try decodeArgs(gpa, "[]");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.value.len);
    try std.testing.expectError(error.UnexpectedToken, decodeArgs(gpa, "{\"not\":\"an array\"}"));
}

fn getAppMutexNameW(gpa: std.mem.Allocator, app_id: []const u8) ![:0]u16 {
    var sanitized: std.ArrayList(u8) = .empty;
    defer sanitized.deinit(gpa);
    try sanitized.appendSlice(gpa, "Local\\OrielApp_");
    for (app_id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') {
            try sanitized.append(gpa, c);
        } else {
            try sanitized.append(gpa, '_');
        }
    }
    return try std.unicode.utf8ToUtf16LeAllocZ(gpa, sanitized.items);
}

fn getHostWindowTitleW(gpa: std.mem.Allocator, app_id: []const u8) ![:0]u16 {
    const title_u8 = try std.fmt.allocPrint(gpa, "OrielHost_{s}", .{app_id});
    defer gpa.free(title_u8);
    return try std.unicode.utf8ToUtf16LeAllocZ(gpa, title_u8);
}

/// Create the hidden host window (never shown; WS_EX_TOOLWINDOW keeps it off
/// the taskbar and Alt+Tab).
fn createHostWindow(title_w: ?[*:0]const win32.WCHAR) !win32.HWND {
    const hInst: win32.HINSTANCE = @ptrCast(win32.GetModuleHandleW(null) orelse return error.NoModuleHandle);
    const wc = win32.WNDCLASSEXW{
        .lpfnWndProc = &hostWndProc,
        .hInstance = hInst,
        .lpszClassName = HOST_CLASS_NAME,
    };
    if (win32.RegisterClassExW(&wc) == 0 and win32.GetLastError() != 1410) { // ERROR_CLASS_ALREADY_EXISTS
        return error.RegisterClassFailed;
    }
    return win32.CreateWindowExW(win32.WS_EX_TOOLWINDOW, HOST_CLASS_NAME, title_w, win32.WS_POPUP, 0, 0, 0, 0, null, null, hInst, null) orelse
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

    // strict_styles and isolation adjust the app's CSP (security.effectiveCsp).
    const csp_z: ?[:0]const u8 = if (comptime security.effectiveCsp(config.security)) |c| (c ++ "\x00")[0..c.len :0] else null;
    const Creator = window.WindowCreator(api, config, local, csp_z);

    const single_instance = build_opts.deep_link or config.on_second_instance != null;

    return struct {
        /// A second launch: send this launch's arguments to the running
        /// instance (found by its host window) and let it handle them.
        fn forwardToPrimary(gpa: std.mem.Allocator, app_id: []const u8) void {
            const host_title_w = getHostWindowTitleW(gpa, app_id) catch return;
            defer gpa.free(host_title_w);

            var primary_host: ?win32.HWND = null;
            var retries: usize = 60; // 60 * 50ms = 3000ms (~3s)
            while (retries > 0) : (retries -= 1) {
                primary_host = win32.FindWindowW(HOST_CLASS_NAME, host_title_w);
                if (primary_host != null) break;
                win32.Sleep(50);
            }
            const host = primary_host orelse {
                log.warn("primary instance mutex exists but host window was not found within 3s", .{});
                return;
            };

            const args = launchArgs(gpa) catch return;
            defer freeArgs(gpa, args);
            const json = encodeArgs(gpa, args) catch return;
            defer gpa.free(json);
            if (json.len > max_forwarded_bytes) {
                log.warn("second launch: arguments too long to forward ({d} bytes)", .{json.len});
                return;
            }

            // Windows only lets the process the user just started take the
            // foreground; pass that right on so the running instance can
            // bring its window to the front (it doesn't when the app handles
            // second launches itself).
            if (config.on_second_instance == null) {
                var primary_pid: win32.DWORD = 0;
                _ = win32.GetWindowThreadProcessId(host, &primary_pid);
                if (primary_pid != 0) _ = win32.AllowSetForegroundWindow(primary_pid);
            }

            var cds = win32.COPYDATASTRUCT{
                .dwData = COPYDATA_ARGS,
                .cbData = @intCast(json.len),
                .lpData = @ptrCast(@constCast(json.ptr)),
            };
            var result: win32.DWORD_PTR = 0;
            _ = win32.SendMessageTimeoutW(
                host,
                win32.WM_COPYDATA,
                0,
                @bitCast(@intFromPtr(&cds)),
                win32.SMTO_ABORTIFHUNG | win32.SMTO_BLOCK,
                3000,
                &result,
            );
        }

        /// In the running instance, on the main thread (host window): a
        /// second launch's arguments. Deep links go to deep_link; the app's
        /// `on_second_instance` gets every argument and decides what to show;
        /// without one, the main window comes back.
        fn onSecondInstance(json: []const u8) void {
            const gpa = std.heap.smp_allocator;
            const parsed = decodeArgs(gpa, json) catch |err| {
                log.warn("second launch: bad arguments ({s})", .{@errorName(err)});
                return;
            };
            defer parsed.deinit();
            const args = parsed.value;

            if (build_opts.deep_link) {
                for (args) |a| {
                    if (deep_link.validate(a, config.deep_link_schemes)) |_| {
                        deep_link.deliver(a);
                        break;
                    } else |_| {}
                }
            }

            if (config.on_second_instance) |handler| {
                handler(args);
            } else if (main_hwnd) |mw| {
                _ = win32.ShowWindow(mw, win32.SW_RESTORE);
                _ = win32.SetForegroundWindow(mw);
            }
        }

        pub fn run(io: std.Io) u8 {
            const gpa = std.heap.smp_allocator;
            const app_id = if (config.dev != null) config.id ++ ".Dev" else config.id;
            var h_mutex: ?win32.HANDLE = null;
            defer {
                if (h_mutex) |m| _ = win32.CloseHandle(m);
            }

            // Single instance: for deep links, and for apps that handle a
            // second launch themselves (`on_second_instance`).
            if (single_instance) {
                const mutex_name_w = getAppMutexNameW(gpa, app_id) catch return 1;
                defer gpa.free(mutex_name_w);

                h_mutex = win32.CreateMutexW(null, win32.FALSE, mutex_name_w);
                if (win32.GetLastError() == win32.ERROR_ALREADY_EXISTS) {
                    forwardToPrimary(gpa, app_id);
                    return 0;
                }
            }
            on_second_instance_fn = &onSecondInstance;
            defer on_second_instance_fn = null;

            var cold_url: ?[]const u8 = null;
            defer {
                if (cold_url) |u| gpa.free(u);
            }
            if (build_opts.deep_link) {
                var argc: c_int = 0;
                if (win32.CommandLineToArgvW(win32.GetCommandLineW(), &argc)) |w_argv| {
                    defer _ = win32.LocalFree(@ptrCast(w_argv));
                    if (argc > 1) {
                        var idx: usize = 1;
                        while (idx < @as(usize, @intCast(argc))) : (idx += 1) {
                            const w_slice = std.mem.span(w_argv[idx]);
                            const u8_arg = std.unicode.utf16LeToUtf8Alloc(gpa, w_slice) catch continue;
                            defer gpa.free(u8_arg);
                            if (deep_link.validate(u8_arg, config.deep_link_schemes)) |_| {
                                cold_url = gpa.dupe(u8, u8_arg) catch null;
                                break;
                            } else |_| {}
                        }
                    }
                }
                if (cold_url) |url| {
                    deep_link.setColdStartUrl(url);
                }
            }

            // After the single-instance check above: an instance that only
            // forwards a deep link must not start a second dev server.
            var dev_server_proc: ?dev_server.DevServer = if (config.dev) |dev| dev_server.startDevServer(io, dev) else null;
            defer if (dev_server_proc) |*p| dev_server.stopDevServer(io, p);

            // Sharp on every monitor: per-monitor DPI aware (V2) before any
            // window exists. Window sizes stay logical in Oriel's API
            // (window.zig converts); WebView2 scales its content itself.
            if (win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == win32.FALSE) {
                // ERROR_ACCESS_DENIED: already set (e.g. by a manifest).
                if (win32.GetLastError() != 5) log.debug("SetProcessDpiAwarenessContext failed ({d})", .{win32.GetLastError()});
            }

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

            const host_title_w = getHostWindowTitleW(gpa, app_id) catch null;
            defer if (host_title_w) |t| gpa.free(t);

            const host = createHostWindow(if (host_title_w) |t| t.ptr else null) catch |err| {
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
                .visible = config.show_main_window,
                .transparent = config.transparent,
                .always_on_top = config.always_on_top,
                .skip_taskbar = config.skip_taskbar,
                .placement = config.placement,
            }) catch |err| {
                log.err("failed to open main window: {s}", .{@errorName(err)});
                return 1;
            };

            main_hwnd = main_win.handle.hwnd;

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});

            if (build_opts.deep_link) {
                if (cold_url) |url| {
                    deep_link.deliver(url);
                }
            }

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
