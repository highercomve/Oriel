//! Platform-neutral Application API for Oriel.
//!
//! Provides the public windowing, IPC, event dispatch, and application
//! lifecycle API used by apps. OS-specific shell operations are delegated
//! to `src/platform/platform.zig`.

const std = @import("std");
const heap = @import("heap.zig");
const build_opts = @import("build_options");
const platform = @import("../platform/platform.zig");
const ipc = @import("ipc.zig");
const security = @import("security.zig");
const ThreadPool = @import("ThreadPool.zig").ThreadPool;

const log = std.log.scoped(.oriel);

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

pub const Asset = struct {
    path: []const u8,
    data: []const u8,
    mime: [:0]const u8,
    /// HTML: CSP hash sources of the file's inline scripts and style blocks
    /// (space-separated, from `embed_assets`), added to its CSP when served.
    script_hashes: []const u8 = "",
    style_hashes: []const u8 = "",
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
    assets: []const Asset = &.{},
    /// Remote URL to load at startup instead of embedded assets.
    url: ?[:0]const u8 = null,
    /// Custom User-Agent string for the webview.
    user_agent: ?[:0]const u8 = null,
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
    /// Show the main window at startup. False for background apps (tray,
    /// global shortcut): the main window is created hidden; `show()` it later.
    show_main_window: bool = true,
    /// Main-window options for overlay-style apps (see WindowOptions).
    transparent: bool = false,
    always_on_top: bool = false,
    skip_taskbar: bool = false,
    placement: ?Placement = null,
    /// Single instance: a second launch of the app forwards its arguments
    /// (without argv[0]) here, on the main thread of the running instance,
    /// and exits. Null keeps the platform default.
    on_second_instance: ?*const fn (args: []const []const u8) void = null,
    /// The OS session is ending (Windows logoff, restart or shutdown). The
    /// process may be killed as soon as this returns, before `run` returns,
    /// so cleanup that would follow `run` (temp files, discovery files)
    /// belongs here too. Called on the main thread. Linux and macOS quit
    /// through the run loop on SIGTERM instead, so `run` returns there.
    on_session_end: ?*const fn () void = null,
};

/// The process arguments, for the platform shell (deep links, second-launch
/// forwarding). `oriel.main` sets them; an app calling `App.run` directly
/// should call `setProcessArgs` first.
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
    /// Show the window once created; false creates it hidden (`show()` later).
    visible: bool = true,
    /// Transparent window background: only what the page paints shows
    /// (give `html, body` a transparent background).
    transparent: bool = false,
    /// Keep above other windows (overlays, floating menus).
    always_on_top: bool = false,
    /// Leave the window out of the taskbar / dock / alt-tab.
    skip_taskbar: bool = false,
    /// Where to put the window when it's shown; null = the window manager decides.
    placement: ?Placement = null,
    /// Closing the window hides it instead (reopen with `show()`).
    hide_on_close: bool = false,
    /// Take keyboard focus when shown. False for overlays that must not steal
    /// typing from the app underneath (live captions).
    focus_on_show: bool = true,
};

/// A position relative to the work area of the window's monitor. Portable
/// where absolute coordinates are not (Wayland: layer-shell anchors).
pub const Placement = struct {
    anchor: Anchor = .center,
    /// Distance from the anchored edges, in logical pixels.
    margin: c_int = 0,
    /// Shift from the anchored position, in logical pixels (x right, y down):
    /// where the user dragged the window (`Window.startDragging`).
    offset_x: c_int = 0,
    offset_y: c_int = 0,

    pub const Anchor = enum { center, top, bottom, left, right, top_left, top_right, bottom_left, bottom_right };

    /// Top-left corner of a `w`×`h` window placed in `area`.
    pub fn origin(self: Placement, area: Rect, w: c_int, h: c_int) struct { x: c_int, y: c_int } {
        const cx = area.x + @divTrunc(area.width - w, 2) + self.offset_x;
        const cy = area.y + @divTrunc(area.height - h, 2) + self.offset_y;
        const left = area.x + self.margin + self.offset_x;
        const right = area.x + area.width - w - self.margin + self.offset_x;
        const top = area.y + self.margin + self.offset_y;
        const bottom = area.y + area.height - h - self.margin + self.offset_y;
        return switch (self.anchor) {
            .center => .{ .x = cx, .y = cy },
            .top => .{ .x = cx, .y = top },
            .bottom => .{ .x = cx, .y = bottom },
            .left => .{ .x = left, .y = cy },
            .right => .{ .x = right, .y = cy },
            .top_left => .{ .x = left, .y = top },
            .top_right => .{ .x = right, .y = top },
            .bottom_left => .{ .x = left, .y = bottom },
            .bottom_right => .{ .x = right, .y = bottom },
        };
    }
};

pub const Rect = struct { x: c_int, y: c_int, width: c_int, height: c_int };

/// How `platform.startWindowDrag` moves the window: by the OS (the window
/// moves it), by Oriel following the pointer (a layer surface), or not at all.
pub const DragMode = enum { native, placement, unsupported };

test "Placement.origin" {
    const area: Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const c = (Placement{}).origin(area, 200, 100);
    try std.testing.expectEqual(@as(c_int, 400), c.x);
    try std.testing.expectEqual(@as(c_int, 350), c.y);
    const b = (Placement{ .anchor = .bottom, .margin = 48 }).origin(area, 200, 100);
    try std.testing.expectEqual(@as(c_int, 400), b.x);
    try std.testing.expectEqual(@as(c_int, 652), b.y);
    const tr = (Placement{ .anchor = .top_right, .margin = 10 }).origin(.{ .x = 100, .y = 50, .width = 1000, .height = 800 }, 200, 100);
    try std.testing.expectEqual(@as(c_int, 890), tr.x);
    try std.testing.expectEqual(@as(c_int, 60), tr.y);
    const moved = (Placement{ .anchor = .bottom, .margin = 48, .offset_x = -300, .offset_y = -20 }).origin(area, 200, 100);
    try std.testing.expectEqual(@as(c_int, 100), moved.x);
    try std.testing.expectEqual(@as(c_int, 632), moved.y);
}

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

    /// The page's theme colour ([r, g, b, a], or null for none): the
    /// window's caption takes it where the platform draws one (Android's
    /// task description on ChromeOS and desktop Android). A no-op elsewhere.
    pub fn setThemeColor(self: *Window, color: ?[4]u8) void {
        if (platform.has_window_theme_color) platform.setWindowThemeColor(self.handle, color);
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

    /// Move the window to `placement` on its monitor's work area.
    pub fn place(self: *Window, placement: Placement) void {
        self.options.placement = placement;
        platform.setWindowPlacement(self.handle, placement);
    }

    /// Let the user move the window with the mouse: call while the primary
    /// button is down (a `mousedown` in the page), e.g. for a window without
    /// decorations. The OS moves it where it can; a Wayland layer-shell
    /// overlay (which the compositor won't move) follows the pointer until
    /// the button is released. Either way the window drops its placement
    /// (`options.placement` becomes null): showing it again leaves it where
    /// the user put it, and an app can tell it was moved.
    pub fn startDragging(self: *Window) void {
        switch (platform.startWindowDrag(self.handle)) {
            .native, .placement => self.options.placement = null,
            .unsupported => {},
        }
    }

    /// Center the window on its monitor.
    pub fn center(self: *Window) void {
        self.place(.{});
    }

    /// Let mouse input pass through the window to what's below it.
    pub fn setClickThrough(self: *Window, enabled: bool) void {
        platform.setWindowClickThrough(self.handle, enabled);
    }

    pub fn setAlwaysOnTop(self: *Window, enabled: bool) void {
        self.options.always_on_top = enabled;
        platform.setWindowAlwaysOnTop(self.handle, enabled);
    }

    /// The usable area of the window's monitor (without panels/docks where
    /// the OS reports them), or null when unknown.
    pub fn workArea(self: *Window) ?Rect {
        return platform.getWindowWorkArea(self.handle);
    }

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
        var store = store_mod.Store.open(heap.gpa, self.app_id, "window_geometry") catch return;
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
        var store = store_mod.Store.open(heap.gpa, self.app_id, "window_geometry") catch return;
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

/// A theme colour sent before its window was registered: the native
/// renderer's page boots inside platform.createWindow, before openWindow
/// adds the window. Applied when it is (one slot; guarded by windows_mutex).
const PendingTheme = struct {
    label_buf: [64]u8 = undefined,
    label_len: usize = 0,
    color: ?[4]u8,
    fn label(p: *const PendingTheme) []const u8 {
        return p.label_buf[0..p.label_len];
    }
};
var pending_theme: ?PendingTheme = null;

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
/// Guards `windows_list`. Never emit (App.emit/emitTo, Window.emit,
/// platform.evalJs*) while holding it: on the main thread emits evaluate at
/// once and take this (non-recursive) lock, which would deadlock.
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

/// The window `label`. The pointer is freed when the window closes (on the
/// main thread), so use it on the main thread only; from another thread, go
/// by label (emitTo, closeWindow) or use it inside `runOnMain`.
pub fn getWindow(label: []const u8) ?*Window {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, label)) return w;
    }
    return null;
}

/// Options of windows declared with `registerWindow` and not created yet.
/// Guarded by `windows_mutex`; the strings are owned (`heap.gpa`).
var registered_windows: std.ArrayList(WindowOptions) = .empty;

/// Declare a window without creating it: `ensureWindow(label)` creates it
/// the first time it's needed. Each window is a web view (a WebKit or
/// WebView2 process and a page load), so a window the user may never open
/// (settings, a playground) costs nothing at startup. Declaring a label
/// again replaces its options.
pub fn registerWindow(options: WindowOptions) !void {
    const gpa = heap.gpa;
    var opts = options;
    opts.label = try gpa.dupeZ(u8, options.label);
    errdefer gpa.free(opts.label);
    opts.title = try gpa.dupeZ(u8, options.title);
    errdefer gpa.free(opts.title);
    opts.url = if (options.url) |u| try gpa.dupeZ(u8, u) else null;
    errdefer if (opts.url) |u| gpa.free(u);

    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (registered_windows.items) |*r| if (std.mem.eql(u8, r.label, opts.label)) {
        freeRegistered(r.*);
        r.* = opts;
        return;
    };
    try registered_windows.append(gpa, opts);
}

fn freeRegistered(opts: WindowOptions) void {
    const gpa = heap.gpa;
    gpa.free(opts.label);
    gpa.free(opts.title);
    if (opts.url) |u| gpa.free(u);
}

/// The window `label`, created now from its `registerWindow` options if it
/// doesn't exist yet (hidden unless registered `visible`). Main thread.
pub fn ensureWindow(label: []const u8) !*Window {
    if (getWindow(label)) |w| return w;
    const opts = blk: {
        ensureWindowsMutex();
        windows_mutex.lock();
        defer windows_mutex.unlock();
        for (registered_windows.items) |r| if (std.mem.eql(u8, r.label, label)) {
            var copy = r;
            copy.label = try heap.gpa.dupeZ(u8, r.label);
            errdefer heap.gpa.free(copy.label);
            copy.title = try heap.gpa.dupeZ(u8, r.title);
            errdefer heap.gpa.free(copy.title);
            copy.url = if (r.url) |u| try heap.gpa.dupeZ(u8, u) else null;
            break :blk copy;
        };
        return error.WindowNotFound;
    };
    defer freeRegistered(opts);
    // openWindow copies this snapshot; registration can change concurrently.
    return openWindow(opts);
}

/// Whether `label` was declared with `registerWindow` (created or not).
pub fn isWindowRegistered(label: []const u8) bool {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (registered_windows.items) |r| if (std.mem.eql(u8, r.label, label)) return true;
    return false;
}

test "registerWindow: declared, replaced, not created" {
    try registerWindow(.{ .label = "lazy-test", .title = "A", .url = "index.html#/a" });
    try registerWindow(.{ .label = "lazy-test", .title = "B", .url = null });
    try std.testing.expect(isWindowRegistered("lazy-test"));
    try std.testing.expect(!isWindowRegistered("other"));
    try std.testing.expect(getWindow("lazy-test") == null);
    windows_mutex.lock();
    defer windows_mutex.unlock();
    var n: usize = 0;
    for (registered_windows.items) |r| if (std.mem.eql(u8, r.label, "lazy-test")) {
        n += 1;
        try std.testing.expectEqualStrings("B", r.title);
        try std.testing.expect(r.url == null);
    };
    try std.testing.expectEqual(@as(usize, 1), n);
}

/// Main thread only for the same reason as `getWindow`.
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

    const gpa = heap.gpa;
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

    const early_theme: ?PendingTheme = blk: {
        windows_mutex.lock();
        defer windows_mutex.unlock();
        // Again under the lock: another openWindow may have added one since
        // the check above (and used the capacity reserved for this one).
        try security.validateWindowCount(current_security, windows_list.items.len);
        try windows_list.append(gpa, win_inst);
        const p = pending_theme orelse break :blk null;
        if (!std.mem.eql(u8, p.label(), options.label)) break :blk null;
        pending_theme = null;
        break :blk p;
    };
    if (early_theme) |p| win_inst.setThemeColor(p.color);

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

    if (options.visible) win_inst.show();
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
    const pool = getWorkerPool() orelse return error.AppNotRunning;
    defer releaseWorkerPool();
    const Job = struct {
        task: ThreadPool.Task,
        args: @TypeOf(args),

        fn run(task: *ThreadPool.Task) void {
            const self: *@This() = @fieldParentPtr("task", task);
            defer heap.gpa.destroy(self);
            const result = @call(.auto, func, self.args);
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = result catch |err| log.err("background task failed: {s}", .{@errorName(err)});
            }
        }
    };
    const job = try heap.gpa.create(Job);
    errdefer heap.gpa.destroy(job);
    job.* = .{ .task = .{ .run_fn = &Job.run }, .args = args };
    if (!pool.post(&job.task)) return error.AppNotRunning;
}

/// Run `func(ctx)` on the main (UI) thread, from any thread: windows, the
/// tray and other UI may only be touched there. Always queued (it runs after
/// the caller returns, even on the main thread); `ctx` is copied.
///
///     App.runOnMain(@as(u32, 7), struct {
///         fn f(n: u32) void { if (App.getWindow("main")) |w| w.show(); _ = n; }
///     }.f);
pub fn runOnMain(ctx: anytype, comptime func: fn (@TypeOf(ctx)) void) void {
    const Ctx = @TypeOf(ctx);
    const Task = struct {
        ctx: Ctx,
        fn run(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            defer heap.gpa.destroy(self);
            func(self.ctx);
        }
        fn drop(p: ?*anyopaque) void {
            heap.gpa.destroy(@as(*@This(), @ptrCast(@alignCast(p.?))));
        }
    };
    const task = heap.gpa.create(Task) catch {
        log.err("runOnMain: out of memory; task dropped", .{});
        return;
    };
    task.* = .{ .ctx = ctx };
    platform.dispatchWithCleanup(&Task.run, task, &Task.drop);
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
    comptime security.checkHeaders(config.security.headers);
    comptime @import("isolation.zig").checkHook(config.security);
    current_security = config.security;
    @import("permissions.zig").setDeclared(config.permissions);
    ipc.initToken(io); // before any window (and bridge script) exists

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
    current_app_id = config.id;
    defer {
        stopWorkerPool(pool);
        // The loop has returned: replies and runOnMain tasks the drained
        // jobs queued would never run (and leak) otherwise.
        platform.drainMainQueue();
        // No queued command can restart playback after the pool drained.
        if (build_opts.kokoro) @import("../modules/audio_play.zig").shutdown();
        // Dictation owns threads outside the command pool. They must finish
        // while this run's Io and allocator are still alive (Android restarts).
        if (build_opts.whisper and build_opts.audio_capture)
            @import("../modules/dictation.zig").deinit();
        current_app_id = null;
    }

    return platform.run(io, api, config);
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
