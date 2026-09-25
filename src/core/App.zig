//! Platform-neutral Application API for Oriel.
//!
//! Provides the public windowing, IPC, event dispatch, and application
//! lifecycle API used by apps. OS-specific shell operations are delegated
//! to `src/platform/platform.zig`.

const std = @import("std");
const build_opts = @import("build_options");
const platform = @import("../platform/platform.zig");
const ipc = @import("ipc.zig");
const security = @import("security.zig");
const ThreadPool = @import("ThreadPool.zig").ThreadPool;

const log = std.log.scoped(.oriel);

/// Worker pool for async commands; owned by `run`. It also carries the
/// `std.Io` passed to `run`, which the IPC handlers hand to commands.
var worker_pool: ?*ThreadPool = null;

pub fn getWorkerPool() ?*ThreadPool {
    return worker_pool;
}

pub const Asset = struct {
    path: []const u8,
    data: []const u8,
    mime: [:0]const u8,
};

/// The app's typed API: `commands` are callable from JS, `events` can be
/// emitted from Zig. Both are plain structs; TypeScript bindings are
/// generated from them.
pub const Api = struct {
    commands: type,
    events: type = struct {},
};

pub const Config = struct {
    id: [:0]const u8,
    title: [:0]const u8,
    width: c_int = 960,
    height: c_int = 720,
    min_width: ?c_int = null,
    min_height: ?c_int = null,
    max_width: ?c_int = null,
    max_height: ?c_int = null,
    resizable: bool = true,
    decorations: bool = true,
    fullscreen: bool = false,
    maximized: bool = false,
    remember_geometry: bool = false,
    assets: []const Asset,
    /// Path + query loaded at startup, relative to `app://app/`.
    start: [:0]const u8 = "index.html",
    /// Unknown extension-less paths serve `index.html` (client-side routing).
    spa_fallback: bool = true,
    devtools: bool = @import("builtin").mode == .Debug,
    security: security.Security = .{},
    /// Closing the window quits the app, or only hides it (e.g. when a tray
    /// icon can bring it back).
    on_close: enum { quit, hide } = .quit,
    /// What happens when `window.open()` or `target="_blank"` navigates to an allowed app-local URL.
    /// Defaults to `.main_view` (load in main view). When `.new_window`, opens a new Oriel window.
    window_open: WindowOpenMode = .main_view,
    /// Called once the window exists, on the main thread: create the tray,
    /// register shortcuts, start background work.
    setup: ?*const fn () anyerror!void = null,
    /// Development mode: load the frontend from a dev server (e.g. Vite with
    /// hot reload) instead of the embedded assets.
    dev: ?Dev = null,
    /// Application icon in PNG format (e.g. from `app.icon_bytes`).
    icon: ?[]const u8 = null,
    /// Declared URL schemes handled by the application (e.g. &.{ "oriel-notes" }).
    deep_link_schemes: []const []const u8 = &.{},
    /// OS permissions the app declares (`app.permissions`, from `.permissions`
    /// in build.zig): only these can be requested, by Zig or by the page.
    permissions: @import("permissions.zig").Declared = .{},
};

pub var process_args: []const []const u8 = &.{};
pub fn setProcessArgs(args: []const []const u8) void {
    process_args = args;
}

pub const WindowOpenMode = enum {
    main_view,
    new_window,
};

pub const WindowOptions = struct {
    label: [:0]const u8 = "main",
    title: [:0]const u8 = "",
    url: ?[:0]const u8 = null,
    width: c_int = 800,
    height: c_int = 600,
    min_width: ?c_int = null,
    min_height: ?c_int = null,
    max_width: ?c_int = null,
    max_height: ?c_int = null,
    resizable: bool = true,
    decorations: bool = true,
    fullscreen: bool = false,
    maximized: bool = false,
    remember_geometry: bool = false,
};

pub const Window = struct {
    label: [:0]const u8,
    handle: platform.WindowHandle,
    options: WindowOptions,
    app_id: [:0]const u8,
    ready: bool = false,
    pending_close: bool = false,

    pub fn show(self: *Window) void {
        platform.showWindow(self.handle);
    }

    pub fn hide(self: *Window) void {
        platform.hideWindow(self.handle);
    }

    pub fn toggle(self: *Window) void {
        platform.toggleWindow(self.handle);
    }

    pub fn close(self: *Window) void {
        platform.closeWindow(self.handle);
    }

    pub fn focus(self: *Window) void {
        platform.focusWindow(self.handle);
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        platform.setWindowTitle(self.handle, title);
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        platform.setWindowFullscreen(self.handle, fullscreen);
    }

    pub fn isFullscreen(self: *Window) bool {
        return platform.isWindowFullscreen(self.handle);
    }

    pub fn setMaximized(self: *Window, maximized: bool) void {
        platform.setWindowMaximized(self.handle, maximized);
    }

    pub fn isMaximized(self: *Window) bool {
        return platform.isWindowMaximized(self.handle);
    }

    pub fn setSize(self: *Window, width: c_int, height: c_int) void {
        platform.setWindowSize(self.handle, width, height);
    }

    pub const WindowSize = platform.WindowSize;

    pub fn getSize(self: *Window) WindowSize {
        return platform.getWindowSize(self.handle);
    }

    /// Send event only to this window's webview.
    pub fn emit(self: *Window, name: []const u8, payload: anytype) void {
        emitJson(self.handle, name, payload) catch |err| log.err("window emit {s}: {s}", .{ name, @errorName(err) });
    }

    pub fn saveGeometry(self: *Window) void {
        if (!build_opts.store) return;
        if (!self.options.remember_geometry) return;
        const size = self.getSize();
        const store_mod = @import("../modules/store.zig");
        var store = store_mod.Store.open(std.heap.smp_allocator, self.app_id, "window_geometry") catch return;
        defer store.deinit();

        var key_w_buf: [128]u8 = undefined;
        const key_w = std.fmt.bufPrint(&key_w_buf, "{s}_width", .{self.label}) catch return;
        store.set(key_w, size.width) catch {};

        var key_h_buf: [128]u8 = undefined;
        const key_h = std.fmt.bufPrint(&key_h_buf, "{s}_height", .{self.label}) catch return;
        store.set(key_h, size.height) catch {};

        var key_m_buf: [128]u8 = undefined;
        const key_m = std.fmt.bufPrint(&key_m_buf, "{s}_maximized", .{self.label}) catch return;
        store.set(key_m, self.isMaximized()) catch {};
    }

    pub fn restoreGeometry(self: *Window) void {
        if (!build_opts.store) return;
        if (!self.options.remember_geometry) return;
        const store_mod = @import("../modules/store.zig");
        var store = store_mod.Store.open(std.heap.smp_allocator, self.app_id, "window_geometry") catch return;
        defer store.deinit();

        var key_w_buf: [128]u8 = undefined;
        const key_w = std.fmt.bufPrint(&key_w_buf, "{s}_width", .{self.label}) catch return;
        const saved_w = store.getInt(key_w, c_int);

        var key_h_buf: [128]u8 = undefined;
        const key_h = std.fmt.bufPrint(&key_h_buf, "{s}_height", .{self.label}) catch return;
        const saved_h = store.getInt(key_h, c_int);

        if (saved_w != null and saved_h != null and saved_w.? > 0 and saved_h.? > 0) {
            self.setSize(saved_w.?, saved_h.?);
        }

        var key_m_buf: [128]u8 = undefined;
        const key_m = std.fmt.bufPrint(&key_m_buf, "{s}_maximized", .{self.label}) catch return;
        if (store.getBool(key_m)) |max| {
            if (max) self.setMaximized(true);
        }
    }
};

pub const Dev = struct {
    url: []const u8,
    /// Dev server command, started with the app and stopped when it exits.
    /// Null when the dev server is managed externally.
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    /// How long to keep retrying while the dev server starts up.
    timeout_ms: u32 = 30_000,
};

// On Linux, backward compatibility pointers for modules like dialog and notification
pub var gtk_app: if (@hasDecl(platform, "GtkApp") and platform.GtkApp != void) ?*platform.GtkApp else ?*anyopaque = null;
pub var main_window: if (@hasDecl(platform, "GtkWindow") and platform.GtkWindow != void) ?*platform.GtkWindow else ?*anyopaque = null;

pub var current_app_id: ?[:0]const u8 = null;
pub var current_security: security.Security = .{};

pub var windows_list: std.ArrayList(*Window) = .empty;
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

pub fn getWindow(label: []const u8) ?*Window {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) return w;
    }
    return null;
}

pub fn getWindowByHandle(handle: platform.WindowHandle) ?*Window {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (windows_list.items) |w| {
        if (w.handle.eql(handle)) return w;
    }
    return null;
}

pub fn closeWindow(label: []const u8) void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const handle = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) break w.handle;
    } else {
        windows_mutex.unlock();
        return;
    };
    windows_mutex.unlock();
    platform.closeWindow(handle);
}

pub fn postCloseWindow(label: []const u8) !void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const handle = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) break w.handle;
    } else {
        windows_mutex.unlock();
        return error.WindowNotFound;
    };
    windows_mutex.unlock();
    platform.postCloseWindow(handle);
}

pub fn emitTo(label: []const u8, name: []const u8, payload: anytype) !void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const exists = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) break true;
    } else false;
    windows_mutex.unlock();
    if (!exists) return error.WindowNotFound;

    const gpa = std.heap.smp_allocator;
    const payload_json = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(payload_json);
    const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
    defer gpa.free(name_json);
    const script = try std.fmt.allocPrintSentinel(gpa, "window.oriel?.__emit({s}, {s});", .{ name_json, payload_json }, 0);
    defer gpa.free(script);
    const label_z = try gpa.dupeZ(u8, label);
    defer gpa.free(label_z);

    platform.evalJsByLabel(label_z, script);
}


pub fn getWindowCount() usize {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    return windows_list.items.len;
}

pub fn openWindow(options: WindowOptions) !*Window {
    if (getWindow(options.label)) |existing| {
        if (std.mem.eql(u8, options.label, "main")) {
            if (comptime @hasDecl(platform, "GtkWindow") and platform.GtkWindow != void) {
                main_window = existing.handle.gtk_window;
            } else if (comptime platform.ShellMod != void and @hasDecl(platform.ShellMod, "main_hwnd")) {
                platform.ShellMod.main_hwnd = existing.handle.hwnd;
            }
        }
        existing.show();
        return existing;
    }

    try security.validateWindowCount(current_security, getWindowCount());

    const gpa = std.heap.smp_allocator;
    const win_inst = try gpa.create(Window);
    errdefer gpa.destroy(win_inst);

    const label_z = try gpa.dupeZ(u8, options.label);
    errdefer gpa.free(label_z);

    const title_z = try gpa.dupeZ(u8, options.title);
    errdefer gpa.free(title_z);

    const url_z = if (options.url) |u| try gpa.dupeZ(u8, u) else null;
    errdefer if (url_z) |u| gpa.free(u);

    var opt_copy = options;
    opt_copy.label = label_z;
    opt_copy.title = title_z;
    opt_copy.url = url_z;

    win_inst.* = .{
        .label = label_z,
        .handle = undefined,
        .options = opt_copy,
        .app_id = current_app_id orelse "",
        .ready = false,
        .pending_close = false,
    };

    {
        ensureWindowsMutex();
        windows_mutex.lock();
        defer windows_mutex.unlock();
        try windows_list.ensureUnusedCapacity(gpa, 1);
    }

    const handle = try platform.createWindow(opt_copy, win_inst);
    errdefer platform.destroyWindow(handle);
    win_inst.handle = handle;

    {
        windows_mutex.lock();
        defer windows_mutex.unlock();
        windows_list.appendAssumeCapacity(win_inst);
    }

    if (std.mem.eql(u8, options.label, "main")) {
        if (comptime @hasDecl(platform, "GtkWindow") and platform.GtkWindow != void) {
            main_window = win_inst.handle.gtk_window;
        } else if (comptime platform.ShellMod != void and @hasDecl(platform.ShellMod, "main_hwnd")) {
            platform.ShellMod.main_hwnd = win_inst.handle.hwnd;
        }
    }

    win_inst.ready = true;

    if (options.remember_geometry) {
        win_inst.restoreGeometry();
    }
    if (options.fullscreen) {
        win_inst.setFullscreen(true);
    } else if (options.maximized) {
        win_inst.setMaximized(true);
    }

    win_inst.show();
    if (win_inst.pending_close) {
        platform.closeWindow(win_inst.handle);
    }
    emit("window:created", .{ .label = win_inst.label });
    return win_inst;
}

const menu = if (build_opts.menu) @import("../modules/menu.zig") else struct {};

pub const setMenu = if (build_opts.menu) struct {
    fn setMenuTyped(items: []const menu.MenuItem, on_action: menu.ActionCallback) !void {
        try platform.setMenu(items, on_action);
    }
}.setMenuTyped else struct {
    fn setMenuStub(items: anytype, on_action: anytype) !void {
        _ = items;
        _ = on_action;
        return error.NotImplemented;
    }
}.setMenuStub;

pub fn quit(code: u8) void {
    platform.quit(code);
}

pub fn showWindow() void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const handle = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, "main")) break w.handle;
    } else {
        windows_mutex.unlock();
        return;
    };
    windows_mutex.unlock();
    platform.showWindow(handle);
}

pub fn hideWindow() void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const handle = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, "main")) break w.handle;
    } else {
        windows_mutex.unlock();
        return;
    };
    windows_mutex.unlock();
    platform.hideWindow(handle);
}

pub fn toggleWindow() void {
    ensureWindowsMutex();
    windows_mutex.lock();
    const handle = for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, "main")) break w.handle;
    } else {
        windows_mutex.unlock();
        return;
    };
    windows_mutex.unlock();
    platform.toggleWindow(handle);
}

pub fn spawn(comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !void {
    const pool = worker_pool orelse return error.AppNotRunning;
    const Job = struct {
        task: ThreadPool.Task,
        args: @TypeOf(args),

        fn run(task: *ThreadPool.Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            defer std.heap.smp_allocator.destroy(self);
            const result = @call(.auto, func, self.args);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| log.err("background task failed: {s}", .{@errorName(err)});
            }
        }
    };
    const job = try std.heap.smp_allocator.create(Job);
    job.* = .{ .task = .{ .run_fn = &Job.run }, .args = args };
    pool.post(&job.task);
}

pub fn emit(name: []const u8, payload: anytype) void {
    emitJson(null, name, payload) catch |err| log.err("emit {s}: {s}", .{ name, @errorName(err) });
}

pub fn events(comptime Events: type) type {
    return struct {
        pub fn emit(comptime name: std.meta.FieldEnum(Events), payload: @FieldType(Events, @tagName(name))) void {
            emitJson(null, @tagName(name), payload) catch |err| log.err("emit {s}: {s}", .{ @tagName(name), @errorName(err) });
        }
    };
}

fn emitJson(target_handle: ?platform.WindowHandle, name: []const u8, payload: anytype) !void {
    const gpa = std.heap.smp_allocator;
    const payload_json = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(payload_json);
    const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
    defer gpa.free(name_json);
    const script = try std.fmt.allocPrintSentinel(gpa, "window.oriel?.__emit({s}, {s});", .{ name_json, payload_json }, 0);
    defer gpa.free(script);

    platform.evalJs(target_handle, script);
}

pub var open_external_hook: ?*const fn (uri: [*:0]const u8) void = null;

pub fn openExternal(uri: [*:0]const u8) void {
    if (open_external_hook) |hook| {
        hook(uri);
        return;
    }
    platform.openExternal(uri);
}

pub const resolveWindowUrl = security.resolveWindowUrl;
pub const validateExternalUrl = security.validateExternalUrl;

pub fn findAsset(assets: []const Asset, path: []const u8, spa_fallback: bool) ?Asset {
    const rel = std.mem.trimStart(u8, path, "/");
    const wanted = if (rel.len == 0) "index.html" else rel;
    const is_route = std.mem.indexOfScalar(u8, std.fs.path.basename(wanted), '.') == null;
    const asset = lookupAsset(assets, wanted) orelse if (spa_fallback and is_route) lookupAsset(assets, "index.html") else null;
    return asset;
}

fn lookupAsset(assets: []const Asset, path: []const u8) ?Asset {
    for (assets) |asset| {
        if (std.mem.eql(u8, asset.path, path)) return asset;
    }
    return null;
}

pub fn run(io: std.Io, comptime api: Api, comptime config: Config) u8 {
    ensureWindowsMutex();
    current_security = config.security;
    @import("permissions.zig").setDeclared(config.permissions);

    const app_log = @import("log.zig");
    app_log.init(config.id);
    defer app_log.deinit();

    if (build_opts.deep_link) {
        const deep_link = @import("../modules/deep_link.zig");
        deep_link.setDeclaredSchemes(config.deep_link_schemes);
        if (config.deep_link_schemes.len == 0)
            std.log.warn("deep links are enabled but no scheme is accepted: pass `.deep_link_schemes = app.url_schemes` to App.run", .{});
    }

    defer {
        ensureWindowsMutex();
        windows_mutex.lock();
        windows_list.deinit(std.heap.smp_allocator);
        windows_list = .empty;
        windows_mutex.unlock();
    }

    const pool = ThreadPool.init(std.heap.smp_allocator, io, null) catch |err| {
        log.err("failed to initialize worker thread pool: {s}", .{@errorName(err)});
        return 1;
    };
    worker_pool = pool;
    current_app_id = config.id;
    defer {
        pool.deinit();
        worker_pool = null;
        current_app_id = null;
    }

    return platform.run(io, api, config);
}
