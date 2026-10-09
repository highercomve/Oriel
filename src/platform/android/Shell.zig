//! Android application shell: the main-thread task queue, `run` and `quit`.
//!
//! Threads: Kotlin's `NativeLib.start` (on the UI thread) starts the app's
//! `main` on a thread of its own (`entry.zig`). `App.run` reaches `run` here
//! on that thread, which opens the main window and runs `setup` on the UI
//! thread, then waits until `quit`. The UI thread is Oriel's "main thread":
//! windows, sync IPC commands and `App.runOnMain` tasks all run there.
//!
//! Tasks from any thread go into a queue and wake the UI thread through an
//! eventfd registered on its `ALooper` (NDK), so no thread but the UI thread
//! ever calls into Java.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const linux = std.os.linux;
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const build_opts = @import("build_options");
const jni = @import("jni.zig");
const runtime = @import("runtime.zig");
const window = @import("window.zig");
const handlers = @import("handlers.zig");
const deep_link = if (build_opts.deep_link) @import("../../modules/deep_link.zig") else struct {};

const log = std.log.scoped(.oriel);

pub const Mutex = struct {
    inner: std.c.pthread_mutex_t = .{},

    pub fn init() Mutex {
        return .{};
    }

    pub fn lock(self: *Mutex) void {
        _ = std.c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = std.c.pthread_mutex_unlock(&self.inner);
    }
};

/// A one-shot event for one waiter (pthread condition variable).
const Event = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    set: bool = false,

    fn signal(self: *Event) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        self.set = true;
        _ = std.c.pthread_cond_broadcast(&self.cond);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    fn wait(self: *Event) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        while (!self.set) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    fn reset(self: *Event) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        self.set = false;
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }
};

// ---------------------------------------------------------------------------
// The UI thread's looper (NDK <android/looper.h>)
// ---------------------------------------------------------------------------

const ALooper = opaque {};
const ALooper_callbackFunc = *const fn (fd: c_int, events: c_int, data: ?*anyopaque) callconv(.c) c_int;
extern "android" fn ALooper_forThread() ?*ALooper;
extern "android" fn ALooper_acquire(looper: *ALooper) void;
extern "android" fn ALooper_addFd(looper: *ALooper, fd: c_int, ident: c_int, events: c_int, callback: ?ALooper_callbackFunc, data: ?*anyopaque) c_int;
const ALOOPER_POLL_CALLBACK: c_int = -2;
const ALOOPER_EVENT_INPUT: c_int = 1;

var wake_fd: i32 = -1;

/// Register the wake-up eventfd on the calling (UI) thread's looper. Once
/// per process: the registration outlives each run of the app.
pub fn attachLooper() !void {
    if (wake_fd >= 0) return;
    const looper = ALooper_forThread() orelse return error.NoLooper;
    const rc = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(rc) != .SUCCESS) return error.EventFd;
    const fd: i32 = @intCast(rc);
    ALooper_acquire(looper); // kept for the process
    if (ALooper_addFd(looper, fd, ALOOPER_POLL_CALLBACK, ALOOPER_EVENT_INPUT, &onWake, null) != 1) {
        _ = linux.close(fd);
        return error.LooperAddFd;
    }
    wake_fd = fd;
}

fn wake() void {
    if (wake_fd < 0) return;
    const one: u64 = 1;
    _ = linux.write(wake_fd, std.mem.asBytes(&one), 8);
}

/// Looper callback (UI thread): run the queued tasks, then report a finished
/// run to Kotlin. Returns 1 to stay registered.
fn onWake(fd: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    var counter: u64 = 0;
    _ = linux.read(fd, std.mem.asBytes(&counter), 8);
    processDispatchQueue();
    if (exit_pending.swap(false, .acq_rel)) {
        _ = runtime.call(.void, "onExit", "(I)V", .{@as(i32, exit_code.load(.monotonic))});
    }
    return 1;
}

/// Set by `entry.zig` when the app's `main` returned: Kotlin finishes the
/// Activities (on the next wake).
var exit_pending: std.atomic.Value(bool) = .init(false);

pub fn notifyExited(code: u8) void {
    exit_code.store(code, .monotonic);
    exit_pending.store(true, .release);
    wake();
}

// ---------------------------------------------------------------------------
// Main-thread dispatch
// ---------------------------------------------------------------------------

const Task = struct {
    run_fn: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
    cleanup_fn: ?*const fn (ctx: ?*anyopaque) void,
};

var task_queue: std.ArrayList(Task) = .empty;
var task_mutex: Mutex = .{};
/// Set under `task_mutex` while `run` runs.
var running = false;
/// Set under `task_mutex` at shutdown: tasks queued from other threads after
/// that are cleaned up at once instead of queued (nothing would run them).
var shutting_down = false;
/// Set under `task_mutex` once the shutdown drain is done: from then on the
/// UI thread's own late tasks (JNI callbacks) are cleaned up at once too,
/// rather than waiting for a later `start` in the same process.
var drained = false;

pub fn isMainThread() bool {
    return runtime.isMainThread();
}

/// Queue `func(ctx)` on the UI thread (any thread). See `dispatchWithCleanup`.
pub fn dispatchToMainThread(func: *const fn (ctx: ?*anyopaque) void, ctx: ?*anyopaque) void {
    dispatchWithCleanup(func, ctx, null);
}

/// Queue `func(ctx)` on the UI thread. `cleanup(ctx)` runs instead when the
/// task can't be queued (out of memory, or queued from another thread after
/// shutdown, or from the UI thread after its drain; then on the calling
/// thread, so it must only free memory) or is
/// still queued at shutdown.
pub fn dispatchWithCleanup(
    func: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
    cleanup: ?*const fn (ctx: ?*anyopaque) void,
) void {
    task_mutex.lock();
    if (shutting_down and (drained or !isMainThread())) {
        task_mutex.unlock();
        if (cleanup) |c| c(ctx) else log.warn("dispatchToMainThread: dropped a task queued after shutdown", .{});
        return;
    }
    task_queue.append(heap.gpa, .{ .run_fn = func, .ctx = ctx, .cleanup_fn = cleanup }) catch {
        task_mutex.unlock();
        log.err("dispatchToMainThread failed: out of memory", .{});
        if (cleanup) |c| c(ctx);
        return;
    };
    task_mutex.unlock();
    wake();
}

fn takeTasks() ?std.ArrayList(Task) {
    task_mutex.lock();
    defer task_mutex.unlock();
    if (task_queue.items.len == 0) return null;
    const tasks = task_queue;
    task_queue = .empty;
    return tasks;
}

/// Run the queued tasks (UI thread). Each runs in its own JNI local frame,
/// so references made by Java calls don't pile up in the looper callback.
pub fn processDispatchQueue() void {
    const e = runtime.mainEnv();
    while (takeTasks()) |taken| {
        var tasks = taken;
        defer tasks.deinit(heap.gpa);
        for (tasks.items) |t| {
            const framed = if (e) |env| env.functions.PushLocalFrame(env, 32) == 0 else false;
            t.run_fn(t.ctx);
            if (framed) _ = e.?.functions.PopLocalFrame(e.?, null);
        }
    }
}

/// At shutdown (UI thread): tasks with a cleanup are cleaned up, the others
/// still run once (freeing their memory and releasing any waiter).
fn drainAtShutdown() void {
    while (takeTasks()) |taken| {
        var tasks = taken;
        defer tasks.deinit(heap.gpa);
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

/// Run `func(ctx)` on the UI thread and wait for it. Runs directly on the
/// UI thread. error.AppNotRunning when the shell isn't running or the task
/// was discarded at shutdown.
pub fn runOnMainThread(comptime Ctx: type, ctx: *Ctx, comptime func: fn (*Ctx) void) error{AppNotRunning}!void {
    if (!isRunning()) return error.AppNotRunning;
    if (isMainThread()) {
        func(ctx);
        return;
    }
    const Call = struct {
        ctx: *Ctx,
        done: Event = .{},
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
    var c: Call = .{ .ctx = ctx };
    dispatchWithCleanup(&Call.run, &c, &Call.cleanup);
    c.done.wait();
    if (!c.ran) return error.AppNotRunning;
}

// ---------------------------------------------------------------------------
// Windows, menu, quit
// ---------------------------------------------------------------------------

pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) !window.WindowHandle {
    const f = handlers.create_window orelse return error.AppNotRunning;
    return f(options, win_inst);
}

pub fn setMenu(items: anytype, on_action: anytype) !void {
    _ = items;
    _ = on_action;
    return error.NotSupported; // no menu bar on Android
}

/// Hook for modules that must clean up at shutdown (UI thread).
pub var on_shutdown_fn: ?*const fn () void = null;

var exit_code: std.atomic.Value(u8) = .init(0);
var quit_event: Event = .{};

/// Make `run` return `code`. Thread-safe.
pub fn quit(code: u8) void {
    exit_code.store(code, .monotonic);
    quit_event.signal();
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

pub fn Shell(comptime api: App.Api, comptime config: App.Config) type {
    const dev_url: ?[]const u8 = if (config.dev) |d| d.url else null;
    const local: security.Local = comptime .{ .dev_origin = if (dev_url) |u| blk: {
        var buf: [512]u8 = undefined;
        const o = security.origin(&buf, u) orelse @compileError("invalid dev URL: " ++ u);
        const copy = o[0..o.len].*;
        break :blk &copy;
    } else null };
    const csp_z: ?[:0]const u8 = if (comptime security.effectiveCsp(config.security)) |c| (c ++ "\x00")[0..c.len :0] else null;
    const Creator = window.WindowCreator(api, config, local, csp_z);

    return struct {
        /// On the app's main thread (not the UI thread).
        pub fn run(io: std.Io) u8 {
            _ = io; // the dev server runs on the development machine, not here
            if (runtime.vm == null) {
                log.err("the Android runtime isn't attached (NativeLib.start was not called)", .{});
                return 1;
            }
            exit_code.store(0, .monotonic);
            quit_event.reset();
            Creator.init();

            task_mutex.lock();
            running = true;
            shutting_down = false;
            drained = false;
            task_mutex.unlock();

            dispatchToMainThread(&start, null);
            quit_event.wait();

            // Tear down on the UI thread, then stop taking tasks.
            var nothing: u8 = 0;
            runOnMainThread(u8, &nothing, shutdown) catch {};
            Creator.deinit();
            return exit_code.load(.monotonic);
        }

        /// UI thread: the main window, the app's setup, the launch deep link.
        fn start(_: ?*anyopaque) void {
            _ = App.openWindow(.{
                .label = "main",
                .title = config.title,
                .url = config.url,
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
                quit(1);
                return;
            };
            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
            // The launch intent's arguments (a deep link's URL): like a
            // desktop app's argv.
            handleArgs(App.process_args, true);
        }

        /// A launch's arguments (the first launch, or `onNewIntent` of the
        /// running app): `on_second_instance`, then any deep link.
        pub fn handleArgs(args: []const []const u8, first: bool) void {
            if (!first) {
                if (config.on_second_instance) |h| h(args);
                App.showWindow();
            }
            if (build_opts.deep_link) {
                for (args) |arg| {
                    if (deep_link.validate(arg, config.deep_link_schemes)) |_| {
                        if (first) deep_link.setColdStartUrl(arg);
                        deep_link.deliver(arg);
                        break;
                    } else |_| {}
                }
            }
        }

        fn shutdown(_: *u8) void {
            if (on_shutdown_fn) |f| f();
            window.destroyAllWindows();
            task_mutex.lock();
            running = false;
            shutting_down = true;
            task_mutex.unlock();
            drainAtShutdown();
            task_mutex.lock();
            drained = true;
            task_mutex.unlock();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
