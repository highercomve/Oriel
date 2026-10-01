//! iOS application shell: UIApplicationMain with an app delegate and a
//! scene delegate defined at run time, main-thread dispatch (tasks drained
//! from the GCD main queue), scene requests for extra windows and quitting.
//!
//! The app's `main` calls `oriel.App.run`, which never returns on iOS
//! (UIApplicationMain doesn't): launching opens the main window and runs
//! `setup`; the first scene the system connects shows it. `quit` cleans up
//! and exits the process, which Apple discourages outside of fatal errors.

const std = @import("std");
const apple = @import("apple.zig");
const Object = apple.Object;
const window = @import("window.zig");
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
    if (shutting_down and !apple.isMainThread()) {
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
    if (wake) apple.asyncMain(null, &drainFromMainQueue);
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
    const pool = apple.objc.AutoreleasePool.init();
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
        const pool = apple.objc.AutoreleasePool.init();
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
    if (apple.isMainThread()) {
        func(ctx);
        return;
    }

    const Call = struct {
        ctx: *Ctx,
        done: apple.Semaphore,
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

    const done = try apple.Semaphore.create();
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
/// Set by `run`: the app's cleanup before `quit` exits.
var shutdown_fn: ?*const fn () void = null;

/// Clean up and exit the process with `code`. Thread-safe.
pub fn quit(code: u8) void {
    exit_code.store(code, .monotonic);
    if (apple.isMainThread()) quitNow() else dispatchToMainThread(&quitTask, null);
}

fn quitTask(_: ?*anyopaque) void {
    quitNow();
}

fn quitNow() void {
    if (shutdown_fn) |f| f();
    std.c.exit(exit_code.load(.monotonic));
}

pub fn sharedApplication() Object {
    return apple.class("UIApplication").msgSend(Object, "sharedApplication", .{});
}

pub var on_shutdown_fn: ?*const fn () void = null;

/// The app's lifecycle, for apps to react to (`oriel.ios.onSystemEvent`):
/// "background" (every window left the screen), "foreground" (back), and
/// "memory-warning" (iOS may end the app next: drop caches and models).
/// Called on the main thread. Do "background" work right there, not on
/// another thread: iOS suspends the app soon after the handler returns,
/// and a worker it froze mid-way finishes only when the app comes back.
pub const SystemEventHandler = *const fn (name: []const u8, data: []const u8) void;
var system_event_handler: ?SystemEventHandler = null;

pub fn onSystemEvent(handler: ?SystemEventHandler) void {
    system_event_handler = handler;
}

fn systemEvent(name: []const u8) void {
    log.info("app {s}", .{name});
    if (system_event_handler) |h| h(name, "");
}

fn didEnterBackground(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
    systemEvent("background");
}

fn willEnterForeground(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
    systemEvent("foreground");
}

fn didReceiveMemoryWarning(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
    systemEvent("memory-warning");
}

// With scenes, UIKit posts these when the app as a whole changes state
// (the app delegate's own background methods are no longer called).
extern const UIApplicationDidEnterBackgroundNotification: apple.id;
extern const UIApplicationWillEnterForegroundNotification: apple.id;

pub fn setMenu(items: anytype, on_action: anytype) !void {
    _ = items;
    _ = on_action;
    return error.Unsupported;
}

/// The main window's view controller (to present other windows over).
pub fn mainController() ?Object {
    const w = App.getWindow("main") orelse return null;
    return .{ .value = w.handle.controller };
}

// ---------------------------------------------------------------------------
// Scenes
// ---------------------------------------------------------------------------

/// The NSUserActivity type of a scene requested for a window (declared in
/// Info.plist's NSUserActivityTypes by `oriel.addApp`).
pub const window_activity_type = "dev.oriel.window";

/// A connected scene and the UIWindow showing an Oriel window in it (+1).
const SceneEntry = struct { scene: apple.id, ui_window: apple.id };
var scenes: std.ArrayList(SceneEntry) = .empty;
/// The scene showing the main window.
var main_scene: apple.id = null;

/// This run, in a requested scene's activity: a scene the system restores
/// from an earlier run (iPad) must not show a window of this one that has
/// the same serial.
fn runId() i64 {
    return std.c.getpid();
}

fn nsNumberU64(value: u64) Object {
    return apple.class("NSNumber").msgSend(Object, "numberWithUnsignedLongLong:", .{value});
}

fn nsNumberI64(value: i64) Object {
    return apple.class("NSNumber").msgSend(Object, "numberWithLongLong:", .{value});
}

/// Ask the system for a new scene showing window `serial` (iPad).
pub fn requestScene(serial: u64) void {
    const type_ns = apple.nsString(window_activity_type) orelse return;
    defer type_ns.release();
    const activity = apple.class("NSUserActivity").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithActivityType:", .{type_ns});
    if (activity.value == null) return;
    defer activity.release();
    const info = apple.class("NSMutableDictionary").msgSend(Object, "dictionary", .{});
    inline for (.{ .{ "serial", nsNumberU64(serial) }, .{ "run", nsNumberI64(runId()) } }) |kv| {
        const key = apple.nsString(kv[0]) orelse return;
        defer key.release();
        info.msgSend(void, "setObject:forKey:", .{ kv[1], key });
    }
    activity.msgSend(void, "setUserInfo:", .{info});
    sharedApplication().msgSend(void, "requestSceneSessionActivation:userActivity:options:errorHandler:", .{ apple.nil, activity, apple.nil, apple.nil });
}

/// The window serial a requested scene's activity names; null for another
/// activity, 0 for none (the main window), maxInt when it is stale.
fn serialOf(activity: Object) ?u64 {
    const kind = apple.utf8(activity.msgSend(Object, "activityType", .{})) orelse return null;
    if (!std.mem.eql(u8, kind, window_activity_type)) return null;
    const info = activity.msgSend(Object, "userInfo", .{});
    if (info.value == null) return std.math.maxInt(u64);
    const run_key = apple.nsString("run") orelse return null;
    defer run_key.release();
    const serial_key = apple.nsString("serial") orelse return null;
    defer serial_key.release();
    const run = info.msgSend(Object, "objectForKey:", .{run_key});
    const serial = info.msgSend(Object, "objectForKey:", .{serial_key});
    if (run.value == null or serial.value == null) return std.math.maxInt(u64);
    if (run.msgSend(i64, "longLongValue", .{}) != runId()) return std.math.maxInt(u64);
    return serial.msgSend(u64, "unsignedLongLongValue", .{});
}

fn destroySession(session: Object) void {
    sharedApplication().msgSend(void, "requestSceneSessionDestruction:options:errorHandler:", .{ session, apple.nil, apple.nil });
}

/// Close the scene showing `ui_window` (its window lives on).
pub fn destroySceneOf(ui_window: apple.id) void {
    const scene = (Object{ .value = ui_window }).msgSend(Object, "windowScene", .{});
    if (scene.value == null) return;
    destroySession(scene.msgSend(Object, "session", .{}));
}

/// Each element of an NSSet (borrowed).
fn setItems(set: Object, comptime f: anytype, extra: anytype) void {
    if (set.value == null) return;
    const all = set.msgSend(Object, "allObjects", .{});
    const n = all.msgSend(c_ulong, "count", .{});
    var i: c_ulong = 0;
    while (i < n) : (i += 1) @call(.auto, f, .{all.msgSend(Object, "objectAtIndex:", .{i})} ++ extra);
}

fn sceneDidDisconnect(_: apple.id, _: apple.c.SEL, scene: apple.id) callconv(.c) void {
    if (scene == main_scene) main_scene = null;
    for (scenes.items, 0..) |e, i| {
        if (e.scene != scene) continue;
        window.detachFromScene(e.ui_window);
        (Object{ .value = e.ui_window }).release();
        _ = scenes.swapRemove(i);
        return;
    }
}

extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;
extern fn UIApplicationMain(argc: c_int, argv: [*][*:0]u8, principal: apple.id, delegate: apple.id) c_int;

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
        var scene_delegate_class: ?apple.Class = null;
        /// The first scene's URLs are the launch's (a cold start).
        var connected_once = false;

        fn didFinishLaunching(self_id: apple.id, _: apple.c.SEL, _: apple.id, _: apple.id) callconv(.c) apple.c.BOOL {
            const center = apple.class("NSNotificationCenter").msgSend(Object, "defaultCenter", .{});
            center.msgSend(void, "addObserver:selector:name:object:", .{ Object{ .value = self_id }, apple.objc.sel("orielDidEnterBackground:"), UIApplicationDidEnterBackgroundNotification, apple.nil });
            center.msgSend(void, "addObserver:selector:name:object:", .{ Object{ .value = self_id }, apple.objc.sel("orielWillEnterForeground:"), UIApplicationWillEnterForegroundNotification, apple.nil });
            Creator.init();
            active_create_window_fn = &Creator.createWindow;

            task_mutex.lock();
            running = true;
            shutting_down = false;
            task_mutex.unlock();
            // Tasks queued before the app finished launching.
            processDispatchQueue();

            // The main window's size is the scene's: only the options that
            // mean something on iOS matter here.
            _ = App.openWindow(.{
                .label = "main",
                .title = config.title,
                .width = config.width,
                .height = config.height,
                .fullscreen = config.fullscreen,
                .visible = true,
            }) catch |err| {
                log.err("failed to open main window: {s}", .{@errorName(err)});
                quit(1);
                return apple.boolean(false);
            };
            // A deep link among the launch arguments (`xcrun simctl launch
            // <device> <id> myapp://...`, as on the desktop): the system's
            // own route (UIOpenURLContexts) asks the user first, which
            // scripted runs can't answer.
            const argv_url: ?[]const u8 = if (build_opts.deep_link) urlFromArgv() else null;
            if (argv_url) |url| deep_link.setColdStartUrl(url);
            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
            if (argv_url) |url| deep_link.deliver(url);
            return apple.boolean(true);
        }

        fn urlFromArgv() ?[]const u8 {
            const argc: usize = @intCast(@max(_NSGetArgc().*, 0));
            if (argc < 2) return null;
            const argv = _NSGetArgv().*;
            for (1..argc) |i| {
                const arg = std.mem.span(argv[i]);
                if (deep_link.validate(arg, config.deep_link_schemes)) |_| return arg else |_| {}
            }
            return null;
        }

        fn configurationForConnecting(_: apple.id, _: apple.c.SEL, _: apple.id, session: apple.id, _: apple.id) callconv(.c) apple.id {
            const role = (Object{ .value = session }).msgSend(Object, "role", .{});
            const cfg = apple.class("UISceneConfiguration").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithName:sessionRole:", .{ apple.nil, role });
            if (scene_delegate_class) |cls| cfg.msgSend(void, "setDelegateClass:", .{cls});
            return cfg.msgSend(Object, "autorelease", .{}).value;
        }

        fn willTerminate(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
            shutdown();
        }

        fn sceneWillConnect(_: apple.id, _: apple.c.SEL, scene_id: apple.id, session_id: apple.id, options_id: apple.id) callconv(.c) void {
            const scene: Object = .{ .value = scene_id };
            const session: Object = .{ .value = session_id };
            const options: Object = .{ .value = options_id };

            var serial: u64 = 0;
            var found = false;
            const Find = struct {
                fn each(activity: Object, out: *u64, ok: *bool) void {
                    if (ok.*) return;
                    if (serialOf(activity)) |s| {
                        out.* = s;
                        ok.* = true;
                    }
                }
            };
            setItems(options.msgSend(Object, "userActivities", .{}), Find.each, .{ &serial, &found });
            if (!found) {
                const restored = session.msgSend(Object, "stateRestorationActivity", .{});
                if (restored.value != null) Find.each(restored, &serial, &found);
            }

            // A second scene without a window to show (the system's "New
            // Window", a scene restored from an earlier run): close it.
            const extra = (serial == 0 and main_scene != null) or serial == std.math.maxInt(u64);
            const ui_window = if (extra) null else window.attachToScene(scene, serial);
            if (ui_window) |w| {
                scenes.append(std.heap.smp_allocator, .{ .scene = scene_id, .ui_window = w.value }) catch {
                    w.release();
                    destroySession(session);
                    return;
                };
                if (serial == 0) main_scene = scene_id;
            } else {
                destroySession(session);
            }

            const cold = !connected_once;
            connected_once = true;
            handleUrlContexts(options.msgSend(Object, "URLContexts", .{}), cold);
        }

        fn sceneOpenUrls(_: apple.id, _: apple.c.SEL, _: apple.id, contexts: apple.id) callconv(.c) void {
            handleUrlContexts(.{ .value = contexts }, false);
        }

        /// Deep links (`myapp://...`, declared in Info.plist's
        /// CFBundleURLTypes) arrive as UIOpenURLContexts.
        fn handleUrlContexts(contexts: Object, cold: bool) void {
            if (!build_opts.deep_link) return;
            const Each = struct {
                fn each(ctx: Object, is_cold: bool) void {
                    const url = apple.urlString(ctx.msgSend(Object, "URL", .{})) orelse return;
                    _ = deep_link.validate(url, config.deep_link_schemes) catch |err| {
                        log.warn("deep link rejected: {s}", .{@errorName(err)});
                        return;
                    };
                    if (is_cold) deep_link.setColdStartUrl(url) else App.showWindow();
                    deep_link.deliver(url);
                }
            };
            setItems(contexts, Each.each, .{cold});
        }

        pub fn run(io: std.Io) u8 {
            _ = io;
            const pool = apple.objc.AutoreleasePool.init();
            defer pool.deinit();
            exit_code.store(0, .monotonic);
            shutdown_fn = &shutdown;
            if (config.dev) |dev| log.info("dev URL {s}: the device must reach it (not the device's own localhost)", .{dev.url});

            scene_delegate_class = apple.defineSubclass("OrielSceneDelegate", "UIResponder", &.{"UIWindowSceneDelegate"}, .{
                .{ "scene:willConnectToSession:options:", sceneWillConnect },
                .{ "scene:openURLContexts:", sceneOpenUrls },
                .{ "sceneDidDisconnect:", sceneDidDisconnect },
            });
            const delegate_class = apple.defineSubclass("OrielAppDelegate", "UIResponder", &.{"UIApplicationDelegate"}, .{
                .{ "application:didFinishLaunchingWithOptions:", didFinishLaunching },
                .{ "application:configurationForConnectingSceneSession:options:", configurationForConnecting },
                .{ "applicationWillTerminate:", willTerminate },
                .{ "applicationDidReceiveMemoryWarning:", didReceiveMemoryWarning },
                .{ "orielDidEnterBackground:", didEnterBackground },
                .{ "orielWillEnterForeground:", willEnterForeground },
            });
            const name = apple.nsString(std.mem.span(apple.c.class_getName(delegate_class.value))) orelse return 1;
            defer name.release();

            // Never returns: the process ends in `quit` or when the system
            // terminates the app.
            _ = UIApplicationMain(_NSGetArgc().*, _NSGetArgv().*, apple.nil.value, name.value);
            return exit_code.load(.monotonic);
        }

        fn shutdown() void {
            task_mutex.lock();
            const was_running = running;
            running = false;
            shutting_down = true; // later tasks from other threads are cleaned up, not queued
            task_mutex.unlock();
            if (!was_running) return;
            if (on_shutdown_fn) |f| f();
            window.destroyAllWindows();
            for (scenes.items) |e| (Object{ .value = e.ui_window }).release();
            scenes.clearAndFree(std.heap.smp_allocator);
            main_scene = null;
            drainAtShutdown();
            active_create_window_fn = null;
            Creator.deinit();
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}

// std.debug's stack traces call `_dyld_get_image_header_containing_address`,
// which iOS's libdyld doesn't export: the same answer through `dladdr`.
const DlInfo = extern struct { fname: ?[*:0]const u8, fbase: ?*anyopaque, sname: ?[*:0]const u8, saddr: ?*anyopaque };
extern "c" fn dladdr(addr: ?*const anyopaque, info: *DlInfo) c_int;

fn imageHeaderContaining(addr: ?*const anyopaque) callconv(.c) ?*anyopaque {
    var info: DlInfo = undefined;
    if (dladdr(addr, &info) == 0) return null;
    return info.fbase;
}

comptime {
    @export(&imageHeaderContaining, .{ .name = "_dyld_get_image_header_containing_address" });
}
