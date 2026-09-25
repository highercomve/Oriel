//! macOS application shell: NSApplication lifecycle, the AppKit run loop,
//! main-thread dispatch (tasks drained from the GCD main queue), the default
//! menu bar and quitting.

const std = @import("std");
const cocoa = @import("cocoa.zig");
const objc = cocoa.objc;
const Object = cocoa.Object;
const window = @import("window.zig");
const dev_server = @import("dev_server.zig");
const WindowHandle = window.WindowHandle;
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const build_opts = @import("build_options");
const deep_link = if (build_opts.deep_link) @import("../../modules/deep_link.zig") else struct {};

const log = std.log.scoped(.oriel);

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn init() Mutex {
        return .{};
    }

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner); // only fails for invalid or deadlocking use
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

const Task = struct {
    run_fn: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
    cleanup_fn: ?*const fn (ctx: ?*anyopaque) void,
};

var task_queue: std.ArrayList(Task) = .empty;
var task_mutex: Mutex = .{};
/// Set under `task_mutex` while `run` services the queue from the run loop.
var running = false;
/// Set under `task_mutex` when `run` stops, before its last drain: a task
/// queued after that from another thread would never run (and a
/// `runOnMainThread` caller would wait forever), so it is cleaned up at once.
var shutting_down = false;
/// A drain is already queued on the GCD main queue (coalesces wakeups).
var drain_scheduled = false;

/// Dispatches a task to execute on the main (AppKit) thread.
///
/// Thread-safe. Tasks queued before `run` starts run once it does; tasks
/// still queued when the run loop ends run during shutdown (see
/// `drainAtShutdown`). If the task can't be queued (out of memory) it is
/// logged and dropped: use `dispatchWithCleanup` when `ctx` owns memory.
pub fn dispatchToMainThread(func: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) void {
    dispatchWithCleanup(func, ctx, null);
}

/// Like `dispatchToMainThread`, but `cleanup(ctx)` runs instead of `func` when
/// the task can't be queued (out of memory, or queued from another thread
/// after shutdown; then on the calling thread, so it must only free memory,
/// not touch AppKit/WebKit objects) or when it is still queued at shutdown
/// (then on the main thread, after the run loop).
pub fn dispatchWithCleanup(
    func: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
    cleanup: ?*const fn (ctx: ?*anyopaque) void,
) void {
    task_mutex.lock();
    // The main thread may still queue while it drains (drainAtShutdown loops).
    if (shutting_down and !cocoa.isMainThread()) {
        task_mutex.unlock();
        if (cleanup) |c| c(ctx) else log.warn("dispatchToMainThread: dropped a task queued after shutdown", .{});
        return;
    }
    task_queue.append(std.heap.smp_allocator, .{ .run_fn = func, .ctx = ctx, .cleanup_fn = cleanup }) catch {
        task_mutex.unlock();
        log.err("dispatchToMainThread failed: out of memory", .{});
        if (cleanup) |c| c(ctx);
        return;
    };
    const wake = running and !drain_scheduled;
    if (wake) drain_scheduled = true;
    task_mutex.unlock();

    // Before `run` starts, tasks wait in the queue; `run` drains it.
    if (wake) cocoa.asyncMain(null, &drainFromMainQueue);
}

fn drainFromMainQueue(_: ?*anyopaque) callconv(.c) void {
    processDispatchQueue();
}

fn takeTasks() ?std.ArrayList(Task) {
    task_mutex.lock();
    defer task_mutex.unlock();
    drain_scheduled = false;
    if (task_queue.items.len == 0) return null;
    // Take the buffer as is (no shrink, so this can't fail): a task lost
    // here could leave a runOnMainThread caller waiting forever.
    const tasks = task_queue;
    task_queue = .empty;
    return tasks;
}

pub fn processDispatchQueue() void {
    var tasks = takeTasks() orelse return;
    defer tasks.deinit(std.heap.smp_allocator);
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    for (tasks.items) |t| t.run_fn(t.ctx);
}

/// Called on the main thread after the run loop ended: tasks with a cleanup
/// are cleaned up, the others still run once (so their memory is freed and
/// any thread waiting on them is released). Loops because a task may queue
/// another one.
fn drainAtShutdown() void {
    while (takeTasks()) |taken| {
        var tasks = taken;
        defer tasks.deinit(std.heap.smp_allocator);
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
        for (tasks.items) |t| {
            if (t.cleanup_fn) |c| c(t.ctx) else t.run_fn(t.ctx);
        }
    }
}

pub fn isRunning() bool {
    task_mutex.lock();
    defer task_mutex.unlock();
    return running;
}

/// Run `func(ctx)` on the main (AppKit) thread and wait for it to finish.
///
/// Runs directly when already on the main thread. From another thread the
/// call is queued and the caller blocks until it ran. Returns
/// error.AppNotRunning when the shell isn't running, or when the task was
/// dropped (out of memory) or discarded at shutdown instead of running.
pub fn runOnMainThread(comptime Ctx: type, ctx: *Ctx, comptime func: fn (*Ctx) void) error{ AppNotRunning, SemaphoreCreateFailed }!void {
    if (!isRunning()) return error.AppNotRunning;
    if (cocoa.isMainThread()) {
        func(ctx);
        return;
    }

    const Call = struct {
        ctx: *Ctx,
        done: cocoa.Semaphore,
        ran: bool = false,

        fn run(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            func(self.ctx);
            self.ran = true;
            self.done.signal();
        }

        fn cleanup(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.done.signal();
        }
    };

    const done = try cocoa.Semaphore.create();
    defer done.deinit();
    // `call` lives on this stack until the task has signalled.
    var call: Call = .{ .ctx = ctx, .done = done };
    dispatchWithCleanup(&Call.run, &call, &Call.cleanup);
    done.wait();
    if (!call.ran) return error.AppNotRunning;
}

pub var active_create_window_fn: ?*const fn (options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle = null;

pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) !WindowHandle {
    if (active_create_window_fn) |f| return f(options, win_inst) else return error.AppNotRunning;
}

var exit_code: std.atomic.Value(u8) = .init(0);
/// Main thread only: `quit` ran before the run loop started.
var quit_requested = false;

/// Stop the run loop and make `run` return `code`. Thread-safe.
pub fn quit(code: u8) void {
    exit_code.store(code, .monotonic);
    if (cocoa.isMainThread()) stopNow() else dispatchToMainThread(&stopTask, null);
}

fn stopTask(_: ?*anyopaque) void {
    stopNow();
}

const NSEventTypeApplicationDefined: c_ulong = 15;

fn stopNow() void {
    quit_requested = true;
    const app = sharedApplication();
    app.msgSend(void, "stop:", .{cocoa.nil});
    // `stop:` only takes effect once the current event is handled: post an
    // empty one so an idle loop wakes up and returns.
    const event = cocoa.class("NSEvent").msgSend(
        Object,
        "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:",
        .{ NSEventTypeApplicationDefined, cocoa.NSPoint{ .x = 0, .y = 0 }, @as(c_ulong, 0), @as(f64, 0), @as(isize, 0), cocoa.nil, @as(i16, 0), @as(isize, 0), @as(isize, 0) },
    );
    if (event.value != null) app.msgSend(void, "postEvent:atStart:", .{ event, cocoa.boolean(true) });
}

pub fn sharedApplication() Object {
    return cocoa.class("NSApplication").msgSend(Object, "sharedApplication", .{});
}

/// Global shortcut, tray and menu backends (PLAN.md Milestone 7, step 2)
/// can hook shutdown here, like on Windows.
pub var on_shutdown_fn: ?*const fn () void = null;

pub fn setMenu(items: anytype, on_action: anytype) !void {
    const menu_mod = @import("../../modules/menu.zig");
    try menu_mod.set(items, on_action);
}

// ---------------------------------------------------------------------------
// Application delegate
// ---------------------------------------------------------------------------

const NSTerminateCancel: c_ulong = 0;

/// Cmd+Q / "Quit" in the app menu: stop the run loop instead of letting
/// AppKit call exit(), so `run` returns and cleans up like on the other platforms.
fn applicationShouldTerminate(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id) callconv(.c) c_ulong {
    quit(0);
    return NSTerminateCancel;
}

/// Clicking the Dock icon while every window is hidden (`on_close = .hide`)
/// brings the main window back.
/// Set by applicationDidFinishLaunching. Launch Services sends the URL that
/// launched the app before that; later URLs are for the running app.
var finished_launching = false;

fn applicationDidFinishLaunching(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id) callconv(.c) void {
    finished_launching = true;
}

// Deep links: Launch Services sends `open myapp://...` (browser links,
// `open`) to the app that declares the scheme in Info.plist as a kAEGetURL
// Apple Event; to the running instance if there is one.
const kInternetEventClass: u32 = 0x4755_524C; // 'GURL'
const kAEGetURL: u32 = 0x4755_524C; // 'GURL'
const keyDirectObject: u32 = 0x2D2D_2D2D; // '----'

extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

fn applicationShouldHandleReopen(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, has_visible_windows: cocoa.c.BOOL) callconv(.c) cocoa.c.BOOL {
    if (!cocoa.isTrue(has_visible_windows)) App.showWindow();
    return cocoa.boolean(true);
}

// ---------------------------------------------------------------------------
// Default menu bar: app menu (Hide, Quit), Edit (so Cmd+C/V/X/Z/A reach the
// webview) and Window. Apps get their own menus with the menu module later.
// ---------------------------------------------------------------------------

fn menuItem(title: []const u8, action: ?[:0]const u8, key: []const u8) Object {
    const title_ns = cocoa.nsString(title) orelse cocoa.nil;
    defer if (title_ns.value != null) title_ns.release();
    const key_ns = cocoa.nsString(key) orelse cocoa.nil;
    defer if (key_ns.value != null) key_ns.release();
    const sel: cocoa.c.SEL = if (action) |a| objc.sel(a).value else null;
    return cocoa.class("NSMenuItem").msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithTitle:action:keyEquivalent:", .{ title_ns, sel, key_ns });
}

/// Build a submenu `title` from `items` (`.{ title, action, key }`, or null
/// for a separator) and add it to `bar`. Returns the (borrowed) submenu.
/// Tags of the default top-level menus, so the menu module can keep them
/// when an app installs its own menu bar.
pub const app_menu_tag: isize = -100;
pub const edit_menu_tag: isize = -101;
pub const window_menu_tag: isize = -102;

fn addSubmenu(bar: Object, title: []const u8, tag: isize, items: []const ?struct { []const u8, [:0]const u8, []const u8 }) Object {
    const title_ns = cocoa.nsString(title) orelse cocoa.nil;
    defer if (title_ns.value != null) title_ns.release();
    const menu = cocoa.class("NSMenu").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithTitle:", .{title_ns});
    defer menu.release(); // the parent item keeps it
    for (items) |entry| {
        if (entry) |e| {
            const item = menuItem(e[0], e[1], e[2]);
            menu.msgSend(void, "addItem:", .{item});
            item.release();
        } else {
            menu.msgSend(void, "addItem:", .{cocoa.class("NSMenuItem").msgSend(Object, "separatorItem", .{})});
        }
    }
    const holder = menuItem(title, null, "");
    holder.msgSend(void, "setTag:", .{tag});
    holder.msgSend(void, "setSubmenu:", .{menu});
    bar.msgSend(void, "addItem:", .{holder});
    holder.release();
    return menu;
}

fn installDefaultMenu(app: Object, app_name: []const u8) void {
    const bar = cocoa.new(cocoa.class("NSMenu"));
    defer bar.release(); // NSApp keeps it

    var hide_buf: [256]u8 = undefined;
    const hide = std.fmt.bufPrint(&hide_buf, "Hide {s}", .{app_name}) catch "Hide";
    var quit_buf: [256]u8 = undefined;
    const quit_title = std.fmt.bufPrint(&quit_buf, "Quit {s}", .{app_name}) catch "Quit";

    _ = addSubmenu(bar, app_name, app_menu_tag, &.{
        .{ hide, "hide:", "h" },
        .{ "Show All", "unhideAllApplications:", "" },
        null,
        .{ quit_title, "terminate:", "q" },
    });
    _ = addSubmenu(bar, "Edit", edit_menu_tag, &.{
        .{ "Undo", "undo:", "z" },
        .{ "Redo", "redo:", "Z" },
        null,
        .{ "Cut", "cut:", "x" },
        .{ "Copy", "copy:", "c" },
        .{ "Paste", "paste:", "v" },
        .{ "Select All", "selectAll:", "a" },
    });
    const window_menu = addSubmenu(bar, "Window", window_menu_tag, &.{
        .{ "Minimize", "performMiniaturize:", "m" },
        .{ "Zoom", "performZoom:", "" },
        .{ "Close", "performClose:", "w" },
    });
    app.msgSend(void, "setMainMenu:", .{bar});
    app.msgSend(void, "setWindowsMenu:", .{window_menu});
}

// ---------------------------------------------------------------------------
// SIGTERM / SIGINT: quit through the run loop, so `run` still cleans up
// (e.g. stops the dev server), like g_unix_signal_add on Linux.
// ---------------------------------------------------------------------------

const QuitSignals = struct {
    const signals = [_]std.posix.SIG{ .TERM, .INT };
    sources: [signals.len]?*anyopaque = @splat(null),
    previous: [signals.len]std.posix.Sigaction = undefined,

    fn install() QuitSignals {
        var self: QuitSignals = .{};
        const ignore: std.posix.Sigaction = .{
            .handler = .{ .handler = std.posix.SIG.IGN },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        for (signals, 0..) |sig, i| {
            self.sources[i] = cocoa.signalSource(sig, &onQuitSignal);
            if (self.sources[i] == null) {
                log.err("could not watch signal {s}", .{@tagName(sig)});
                continue;
            }
            std.posix.sigaction(sig, &ignore, &self.previous[i]);
        }
        return self;
    }

    fn uninstall(self: *QuitSignals) void {
        for (signals, 0..) |sig, i| {
            const source = self.sources[i] orelse continue;
            std.posix.sigaction(sig, &self.previous[i], null);
            cocoa.cancelSource(source);
        }
    }

    fn onQuitSignal(_: ?*anyopaque) callconv(.c) void {
        quit(0);
    }
};

/// Watch `ORIEL_DEV_RUNNER_PID` (set by tools/dev_runner.zig) and quit when
/// it exits. Returns the dispatch source, or null outside dev_runner.
fn watchDevRunner() ?*anyopaque {
    const value = std.c.getenv("ORIEL_DEV_RUNNER_PID") orelse return null;
    const pid = std.fmt.parseInt(std.c.pid_t, std.mem.span(value), 10) catch {
        log.err("invalid ORIEL_DEV_RUNNER_PID {s}", .{value});
        return null;
    };
    const source = cocoa.processExitSource(pid, &onDevRunnerExit) orelse {
        // Already gone (the source can't watch a dead pid).
        log.err("dev_runner (pid {d}) is gone; exiting", .{pid});
        quit(1);
        return null;
    };
    return source;
}

fn onDevRunnerExit(_: ?*anyopaque) callconv(.c) void {
    log.info("dev_runner exited; quitting", .{});
    quit(0);
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

const NSApplicationActivationPolicyRegular: isize = 0;

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
        /// NSAppleEventManager handler for kAEGetURL (main thread).
        fn handleGetURL(_: cocoa.id, _: cocoa.c.SEL, event: cocoa.id, _: cocoa.id) callconv(.c) void {
            if (!build_opts.deep_link) return;
            const desc = (Object{ .value = event }).msgSend(Object, "paramDescriptorForKeyword:", .{keyDirectObject});
            if (desc.value == null) return;
            const url = cocoa.utf8(desc.msgSend(Object, "stringValue", .{})) orelse return;
            _ = deep_link.validate(url, config.deep_link_schemes) catch |err| {
                log.warn("deep link rejected: {s}", .{@errorName(err)});
                return;
            };
            if (!finished_launching) {
                deep_link.setColdStartUrl(url);
            } else {
                App.showWindow();
            }
            deep_link.deliver(url);
        }

        /// A URL among the arguments (an unbundled executable started as
        /// `app myapp://...`, as on Linux and Windows), or null.
        fn urlFromArgv() ?[]const u8 {
            const argc: usize = @intCast(_NSGetArgc().*);
            const argv = _NSGetArgv().*;
            for (1..argc) |i| {
                const arg = std.mem.span(argv[i]);
                if (deep_link.validate(arg, config.deep_link_schemes)) |_| return arg else |_| {}
            }
            return null;
        }

        pub fn run(io: std.Io) u8 {
            const pool = objc.AutoreleasePool.init();
            defer pool.deinit();

            exit_code.store(0, .monotonic);
            quit_requested = false;

            const app = sharedApplication();
            // A plain executable (no .app bundle) is a background app by
            // default: no Dock icon, no menu bar, windows behind others.
            _ = app.msgSend(cocoa.c.BOOL, "setActivationPolicy:", .{NSApplicationActivationPolicyRegular});

            const delegate_class = cocoa.defineClass("OrielAppDelegate", &.{"NSApplicationDelegate"}, .{
                .{ "applicationShouldTerminate:", applicationShouldTerminate },
                .{ "applicationShouldHandleReopen:hasVisibleWindows:", applicationShouldHandleReopen },
                .{ "applicationDidFinishLaunching:", applicationDidFinishLaunching },
                .{ "handleGetURLEvent:withReplyEvent:", handleGetURL },
            });
            // NSApp's delegate is a weak reference: keep ours for the whole run.
            const delegate = cocoa.new(delegate_class);
            defer {
                app.msgSend(void, "setDelegate:", .{cocoa.nil});
                delegate.release();
            }
            app.msgSend(void, "setDelegate:", .{delegate});
            installDefaultMenu(app, config.title);

            // Before `run`: the launch URL arrives while it finishes launching.
            finished_launching = false;
            const ae_manager = cocoa.class("NSAppleEventManager").msgSend(Object, "sharedAppleEventManager", .{});
            if (build_opts.deep_link) {
                ae_manager.msgSend(void, "setEventHandler:andSelector:forEventClass:andEventID:", .{ delegate, objc.sel("handleGetURLEvent:withReplyEvent:").value, kInternetEventClass, kAEGetURL });
            }
            defer if (build_opts.deep_link) {
                ae_manager.msgSend(void, "removeEventHandlerForEventClass:andEventID:", .{ kInternetEventClass, kAEGetURL });
            };
            const argv_url: ?[]const u8 = if (build_opts.deep_link) urlFromArgv() else null;
            if (argv_url) |url| deep_link.setColdStartUrl(url);

            // Before QuitSignals: children inherit ignored signals across exec,
            // and a dev server ignoring SIGTERM couldn't be stopped.
            var dev_server_proc: ?std.process.Child = if (config.dev) |dev| dev_server.startDevServer(io, dev) else null;
            defer if (dev_server_proc) |*p| dev_server.stopDevServer(io, p);

            var quit_signals = QuitSignals.install();
            defer quit_signals.uninstall();

            // Under `zig build dev`, exit with dev_runner even when it is
            // killed outright (Linux: PR_SET_PDEATHSIG).
            const runner_watch = watchDevRunner();
            defer if (runner_watch) |w| cocoa.cancelSource(w);

            Creator.init();
            defer Creator.deinit();
            active_create_window_fn = &Creator.createWindow;
            defer active_create_window_fn = null;

            task_mutex.lock();
            running = true;
            shutting_down = false;
            task_mutex.unlock();
            defer shutdown();
            // Tasks queued before the run loop existed.
            processDispatchQueue();

            _ = App.openWindow(.{
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

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
            if (argv_url) |url| deep_link.deliver(url);

            app.msgSend(void, "activateIgnoringOtherApps:", .{cocoa.boolean(true)});
            if (!quit_requested) app.msgSend(void, "run", .{});
            return exit_code.load(.monotonic);
        }

        fn shutdown() void {
            if (on_shutdown_fn) |f| f();
            task_mutex.lock();
            running = false;
            shutting_down = true; // later tasks from other threads are cleaned up, not queued
            task_mutex.unlock();
            window.destroyAllWindows();
            drainAtShutdown();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
