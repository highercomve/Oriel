//! Oriel's own runtime state behind `App`: the window registry and its
//! lock, the running app's security settings, the worker pool, untyped
//! event delivery and the run loop entry. The platform shells and the
//! modules share it across files; `src/oriel.zig` does not export it, so
//! apps can't reach it (their API is `App` and `oriel.main`).

const std = @import("std");
const heap = @import("heap.zig");

pub const ShutdownHook = *const fn () void;
var shutdown_hooks: std.ArrayListUnmanaged(ShutdownHook) = .empty;
pub var set_declared_schemes: ?*const fn (schemes: []const []const u8) void = null;

pub fn registerShutdownHook(hook: ShutdownHook) void {
    shutdown_hooks.append(heap.gpa, hook) catch {};
}
const build_opts = @import("build_options");
const platform = @import("../platform/platform.zig");
const ipc = @import("ipc.zig");
const security = @import("security.zig");
const ThreadPool = @import("ThreadPool.zig").ThreadPool;
const lifecycle = @import("lifecycle/backend.zig");
const target = @import("target.zig");
const App = @import("App.zig");
const Window = App.Window;

const log = std.log.scoped(.oriel);

// ---------------------------------------------------------------------------
// Worker pool
// ---------------------------------------------------------------------------

/// Worker pool for async commands; owned by `run`. It also carries the
/// `std.Io` passed to `run`, which the IPC handlers hand to commands.
var worker_pool: ?*ThreadPool = null;
var pool_mutex: std.Io.Mutex = .init;
var pool_borrowers: usize = 0;

/// Borrow the pool until `releaseWorkerPool`. The borrow protects its Io and
/// task queue during shutdown; callers must not retain it after release.
pub fn getWorkerPool() ?*ThreadPool {
    std.Io.Threaded.mutexLock(&pool_mutex);
    defer std.Io.Threaded.mutexUnlock(&pool_mutex);
    const pool = worker_pool orelse return null;
    pool_borrowers += 1;
    return pool;
}

pub fn releaseWorkerPool() void {
    std.Io.Threaded.mutexLock(&pool_mutex);
    defer std.Io.Threaded.mutexUnlock(&pool_mutex);
    std.debug.assert(pool_borrowers > 0);
    pool_borrowers -= 1;
}

fn stopWorkerPool(pool: *ThreadPool) void {
    std.Io.Threaded.mutexLock(&pool_mutex);
    worker_pool = null;
    // No new borrows. Existing callers finish enqueueing before teardown.
    while (pool_borrowers != 0) {
        std.Io.Threaded.mutexUnlock(&pool_mutex);
        std.Thread.yield() catch {};
        std.Io.Threaded.mutexLock(&pool_mutex);
    }
    std.Io.Threaded.mutexUnlock(&pool_mutex);
    pool.deinit();
}

// ---------------------------------------------------------------------------
// Process and app state
// ---------------------------------------------------------------------------

/// The process arguments, for the platform shell (deep links, second-launch
/// forwarding). `oriel.main` sets them before `run`.
pub var process_args: []const []const u8 = &.{};

/// How `platform.startWindowDrag` moves the window: by the OS (the window
/// moves it), by Oriel following the pointer (a layer surface), or not at all.
pub const DragMode = enum { native, placement, unsupported };

/// Linux: the GtkApplication and the main GtkWindow, for modules that
/// parent dialogs or notifications on them. Apps get native handles from
/// `oriel.hooks`.
pub var gtk_app: if (@hasDecl(platform, "GtkApp") and platform.GtkApp != void) ?*platform.GtkApp else ?*anyopaque = null;
pub var main_window: if (@hasDecl(platform, "GtkWindow") and platform.GtkWindow != void) ?*platform.GtkWindow else ?*anyopaque = null;

pub var current_app_id: ?[:0]const u8 = null;
pub var current_security: security.Security = .{};
/// The app's own origins (with the dev server's in dev builds); set with
/// `current_security` in `run`.
pub var current_local: security.Local = .{};

/// Whether window `label`'s page at `page_url` may receive events: it is
/// one the bridge serves (the app's origins or a capability's). Any other
/// page could define its own `window.oriel.__emit` and read them.
pub fn pageGetsEvents(page_url: []const u8, label: ?[]const u8) bool {
    return security.bridgeAllowedForWindow(current_security, current_local, page_url, label);
}

// ---------------------------------------------------------------------------
// Window registry
// ---------------------------------------------------------------------------

pub var windows_list: std.ArrayList(*Window) = .empty;

/// A theme colour sent before its window was registered: the native
/// renderer's page boots inside platform.createWindow, before openWindow
/// adds the window. Applied when it is (one slot; guarded by windows_mutex).
pub const PendingTheme = struct {
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,
    color: ?[4]u8,
    pub fn label(p: *const PendingTheme) []const u8 {
        return p.label_buf[0..p.label_len];
    }
};
pub var pending_theme: ?PendingTheme = null;

/// Keep `color` for window `label`, which isn't registered yet.
pub fn setPendingThemeColor(label: []const u8, color: ?[4]u8) void {
    if (label.len > 64) return;
    var p: PendingTheme = .{ .color = color, .label_len = label.len };
    @memcpy(p.label_buf[0..label.len], label);
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    pending_theme = p;
}

/// Guards `windows_list`. Never emit (`emit`, `emitTo`, platform.evalJs*)
/// while holding it: on the main thread emits evaluate at once and take
/// this (non-recursive) lock, which would deadlock.
pub var windows_mutex: platform.Mutex = undefined;
var mutex_init_state: std.atomic.Value(u8) = .init(0); // 0 = uninit, 1 = initializing, 2 = initialized

pub fn ensureWindowsMutex() void {
    if (mutex_init_state.load(.acquire) == 2) return;
    if (mutex_init_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        windows_mutex = platform.Mutex.init();
        mutex_init_state.store(2, .release);
    } else {
        while (mutex_init_state.load(.acquire) != 2) {
            std.atomic.spinLoopHint();
        }
    }
}

/// Main thread only for the same reason as `App.getWindow`.
pub fn getWindowByHandle(handle: platform.WindowHandle) ?*Window {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (windows_list.items) |w| {
        if (w.handle.eql(handle)) return w;
    }
    return null;
}

pub fn getWindowCount() usize {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    return windows_list.items.len;
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

/// Oriel's own events (`window:created`, `deep-link`, module events), to
/// every window. Apps emit through `App.events(Events)`, typed. Any thread.
pub fn emit(name: []const u8, payload: anytype) void {
    emitJson(null, name, payload) catch |err| log.err("emit {s}: {s}", .{ name, @errorName(err) });
}

/// An event to window `label` only (the page's `oriel.window.emitTo`, and
/// `App.events(Events).emitTo`). Any thread.
pub fn emitTo(label: []const u8, name: []const u8, payload: anytype) !void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const exists = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) break true;
    } else false;
    windows_mutex.unlock();
    if (!exists) return error.WindowNotFound;

    const gpa = heap.gpa;
    const payload_json = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(payload_json);
    const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
    defer gpa.free(name_json);
    if (comptime platform.has_emit_event) return platform.emitEvent(null, label, name_json, payload_json);
    const script = try std.fmt.allocPrintSentinel(gpa, "window.oriel?.__emit({s}, {s});", .{ name_json, payload_json }, 0);
    defer gpa.free(script);
    const label_z = try gpa.dupeZ(u8, label);
    defer gpa.free(label_z);

    platform.evalJsByLabel(label_z, script);
}

fn emitJson(target_handle: ?platform.WindowHandle, name: []const u8, payload: anytype) !void {
    const gpa = heap.gpa;
    const payload_json = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(payload_json);
    const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
    defer gpa.free(name_json);
    if (comptime platform.has_emit_event) return platform.emitEvent(target_handle, null, name_json, payload_json);
    const script = try std.fmt.allocPrintSentinel(gpa, "window.oriel?.__emit({s}, {s});", .{ name_json, payload_json }, 0);
    defer gpa.free(script);

    platform.evalJs(target_handle, script);
}

// ---------------------------------------------------------------------------
// Assets
// ---------------------------------------------------------------------------

pub fn findAsset(assets: []const App.Asset, path: []const u8, spa_fallback: bool) ?App.Asset {
    const rel = std.mem.trimStart(u8, path, "/");
    const wanted = if (rel.len == 0) "index.html" else rel;
    const is_route = std.mem.indexOfScalar(u8, std.fs.path.basename(wanted), '.') == null;
    const asset = lookupAsset(assets, wanted) orelse if (spa_fallback and is_route) lookupAsset(assets, "index.html") else null;
    return asset;
}

fn lookupAsset(assets: []const App.Asset, path: []const u8) ?App.Asset {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.path, path)) return asset;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

/// Run the app on the calling (main) thread until it quits: `oriel.main`'s
/// last step, after it set `process_args`.
pub fn run(io: std.Io, comptime api: App.Api, comptime config: App.Config) u8 {
    ensureWindowsMutex();
    comptime if (!std.mem.eql(u8, config.window.label, "main"))
        @compileError("App.Config.window is the main window: its label is \"main\", not \"" ++ config.window.label ++ "\"");
    comptime security.checkHeaders(config.security.headers);
    comptime @import("isolation.zig").checkHook(config.app.isolation);
    current_security = config.security;
    current_local = comptime .{ .dev_origin = if (config.app.dev) |d| blk: {
        var buf: [512]u8 = undefined;
        const o = security.origin(&buf, d.url) orelse @compileError("invalid dev URL: " ++ d.url);
        const copy = o[0..o.len].*;
        break :blk &copy;
    } else null };
    @import("permissions/gate.zig").setDeclared(config.app.permissions);
    ipc.initToken(io); // before any window (and bridge script) exists

    const app_log = @import("log.zig");
    app_log.init(config.app.id);
    defer app_log.deinit();

    if (set_declared_schemes) |set_schemes| {
        set_schemes(config.app.url_schemes);
        if (config.app.url_schemes.len == 0)
            std.log.warn("deep links are enabled but no scheme is accepted: declare `.url_schemes` in addApp (build.zig)", .{});
    }

    defer {
        ensureWindowsMutex();
        windows_mutex.lock();
        windows_list.deinit(heap.gpa);
        windows_list = .empty;
        windows_mutex.unlock();
    }

    const pool = ThreadPool.init(heap.gpa, io, null) catch |err| {
        log.err("failed to initialize worker thread pool: {s}", .{@errorName(err)});
        return 1;
    };
    std.Io.Threaded.mutexLock(&pool_mutex);
    worker_pool = pool;
    std.Io.Threaded.mutexUnlock(&pool_mutex);
    current_app_id = config.app.id;
    defer {
        stopWorkerPool(pool);
        // The loop has returned: replies and runOnMain tasks the drained
        // jobs queued would never run (and leak) otherwise.
        platform.drainMainQueue();
        for (shutdown_hooks.items) |hook| {
            hook();
        }
        shutdown_hooks.deinit(heap.gpa);
        shutdown_hooks = .empty;
        current_app_id = null;
    }

    lifecycle.beginRun();
    @import("extensions/runtime.zig").begin(io);
    const code = platform.run(io, api, config);
    // The loop returned on the main thread (desktop): a quit the backend
    // didn't announce (the last window closed) still sends `terminating`.
    // Android ends processes without it, and iOS never gets here.
    if (comptime !target.is_android) lifecycle.terminateAfterLoop();
    return code;
}

test "pool shutdown withdraws publication and waits for outstanding borrows" {
    const pool = try ThreadPool.init(std.testing.allocator, std.testing.io, 1);
    std.Io.Threaded.mutexLock(&pool_mutex);
    worker_pool = pool;
    std.Io.Threaded.mutexUnlock(&pool_mutex);
    const borrowed = getWorkerPool().?;
    var finished: std.atomic.Value(bool) = .init(false);
    const Stopper = struct {
        fn run(p: *ThreadPool, done: *std.atomic.Value(bool)) void {
            stopWorkerPool(p);
            done.store(true, .release);
        }
    };
    const thread = std.Thread.spawn(.{}, Stopper.run, .{ pool, &finished }) catch |err| {
        releaseWorkerPool();
        stopWorkerPool(pool);
        return err;
    };
    while (true) {
        std.Io.Threaded.mutexLock(&pool_mutex);
        const withdrawn = worker_pool == null;
        std.Io.Threaded.mutexUnlock(&pool_mutex);
        if (withdrawn) break;
        std.Thread.yield() catch {};
    }
    const still_alive = !finished.load(.acquire);
    const io_is_valid = borrowed.io.vtable == std.testing.io.vtable;
    const no_new_borrow = getWorkerPool() == null;
    releaseWorkerPool();
    thread.join();
    try std.testing.expect(still_alive);
    try std.testing.expect(io_is_valid);
    try std.testing.expect(no_new_borrow);
    try std.testing.expect(finished.load(.acquire));
}
