//! Linux shell: a GTK4 application window hosting a WebKitGTK 6.0 webview.
//!
//! - Frontend assets are embedded in the binary and served from `app://app/`
//!   with a Content-Security-Policy header.
//! - `window.ziguri.invoke(cmd, args)` in JS returns a Promise resolved by
//!   `ipc.dispatch` on the Zig side; `window.ziguri.listen(event, cb)`
//!   receives events sent with `emit`.
//! - Navigation, IPC and bridge injection follow `security.Security`.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const webkit = @import("webkit");
const jsc = @import("jsc");
const soup = @import("soup");
const ipc = @import("ipc.zig");
const security = @import("security.zig");
const ThreadPool = @import("ThreadPool.zig").ThreadPool;

const log = std.log.scoped(.ziguri);

pub var io: ?std.Io = null;
var worker_pool: ?*ThreadPool = null;

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
    /// Called once the window exists, on the main thread: create the tray,
    /// register shortcuts, start background work.
    setup: ?*const fn () anyerror!void = null,
    /// Development mode: load the frontend from a dev server (e.g. Vite with
    /// hot reload) instead of the embedded assets.
    dev: ?Dev = null,
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
    app_window: *gtk.ApplicationWindow,
    gtk_window: *gtk.Window,
    web_view: *webkit.WebView,
    options: WindowOptions,
    app_id: [:0]const u8,

    pub fn show(self: *Window) void {
        self.gtk_window.present();
    }

    pub fn hide(self: *Window) void {
        self.gtk_window.as(gtk.Widget).setVisible(0);
    }

    pub fn toggle(self: *Window) void {
        if (self.gtk_window.as(gtk.Widget).getVisible() != 0 and self.gtk_window.isActive() != 0) {
            self.hide();
        } else {
            self.show();
        }
    }

    pub fn close(self: *Window) void {
        self.gtk_window.close();
    }

    pub fn setTitle(self: *Window, title: [:0]const u8) void {
        self.gtk_window.setTitle(title);
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        if (fullscreen) self.gtk_window.fullscreen() else self.gtk_window.unfullscreen();
    }

    pub fn isFullscreen(self: *Window) bool {
        return self.gtk_window.isFullscreen() != 0;
    }

    pub fn setMaximized(self: *Window, maximized: bool) void {
        if (maximized) self.gtk_window.maximize() else self.gtk_window.unmaximize();
    }

    pub fn isMaximized(self: *Window) bool {
        return self.gtk_window.isMaximized() != 0;
    }

    pub fn setSize(self: *Window, width: c_int, height: c_int) void {
        self.gtk_window.setDefaultSize(width, height);
    }

    pub fn getSize(self: *Window) struct { width: c_int, height: c_int } {
        var w: c_int = 0;
        var h: c_int = 0;
        self.gtk_window.getDefaultSize(&w, &h);
        return .{ .width = w, .height = h };
    }

    /// Send event only to this window's webview.
    pub fn emit(self: *Window, name: []const u8, payload: anytype) void {
        emitJson(self.web_view, name, payload) catch |err| log.err("window emit {s}: {s}", .{ name, @errorName(err) });
    }

    pub fn saveGeometry(self: *Window) void {
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

const scheme = "app";
const handler_name = "ziguri";

/// Injected into allowed pages before their own scripts run.
const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const handler = window.webkit.messageHandlers.
++ handler_name ++
    \\;
    \\  Object.defineProperty(window, "ziguri", { value: Object.freeze({
    \\    invoke(cmd, args) {
    \\      return handler.postMessage(JSON.stringify({ cmd, args: args ?? null }));
    \\    },
    \\    listen(event, callback) {
    \\      let set = listeners.get(event);
    \\      if (!set) listeners.set(event, (set = new Set()));
    \\      set.add(callback);
    \\      return () => set.delete(callback);
    \\    },
    \\    __emit(event, payload) {
    \\      for (const cb of listeners.get(event) ?? []) {
    \\        try { cb(payload); } catch (e) { console.error(e); }
    \\      }
    \\    },
    \\  }) });
    \\})();
;

pub var gtk_app: ?*gtk.Application = null;
pub var main_window: ?*gtk.Window = null;
var main_view: ?*webkit.WebView = null;
var exit_code: u8 = 0;
var dev_retries_left: u32 = 0;

pub var windows_list: std.ArrayList(*Window) = .empty;
var windows_mutex: glib.Mutex = undefined;
var windows_mutex_initialized: bool = false;

pub fn ensureWindowsMutex() void {
    if (!windows_mutex_initialized) {
        windows_mutex.init();
        windows_mutex_initialized = true;
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

pub fn getWindowByView(view: *webkit.WebView) ?*Window {
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (windows_list.items) |w| {
        if (w.web_view == view) return w;
    }
    return null;
}

pub fn closeWindow(label: []const u8) void {
    if (getWindow(label)) |w| {
        w.close();
    }
}

pub fn getWindows() []*Window {
    return windows_list.items;
}

pub var open_window_fn: ?*const fn (options: WindowOptions) anyerror!*Window = null;

pub fn openWindow(options: WindowOptions) !*Window {
    if (open_window_fn) |f| return f(options) else return error.AppNotRunning;
}

pub fn setMenu(items: []const @import("../modules/menu.zig").MenuItem, on_action: @import("../modules/menu.zig").ActionCallback) !void {
    const app = gtk_app orelse return error.AppNotRunning;
    const menu_mod = @import("../modules/menu.zig");
    try menu_mod.set(app, items, on_action);
    ensureWindowsMutex();
    windows_mutex.lock();
    defer windows_mutex.unlock();
    for (windows_list.items) |win| {
        win.app_window.setShowMenubar(1);
    }
}

/// Quit the running application with `code` as the process exit status.
pub fn quit(code: u8) void {
    exit_code = code;
    if (gtk_app) |app| gio.Application.quit(app.as(gio.Application));
}

pub fn showWindow() void {
    if (main_window) |w| w.present();
}

pub fn hideWindow() void {
    if (main_window) |w| w.as(gtk.Widget).setVisible(0);
}

/// Show the window, or hide it if it is already visible and focused.
pub fn toggleWindow() void {
    const w = main_window orelse return;
    if (w.as(gtk.Widget).getVisible() != 0 and w.isActive() != 0) hideWindow() else showWindow();
}

/// Send `payload` (any JSON-serializable value) to `ziguri.listen(name, …)`
/// listeners in all pages. Safe to call from any thread.
pub fn emit(name: []const u8, payload: anytype) void {
    emitJson(null, name, payload) catch |err| log.err("emit {s}: {s}", .{ name, @errorName(err) });
}

/// Typed events: `App.events(Events).emit(.note_added, note)` only compiles
/// if `Events` has a `note_added` field of that payload type.
pub fn events(comptime Events: type) type {
    return struct {
        pub fn emit(comptime name: std.meta.FieldEnum(Events), payload: @FieldType(Events, @tagName(name))) void {
            emitJson(null, @tagName(name), payload) catch |err| log.err("emit {s}: {s}", .{ @tagName(name), @errorName(err) });
        }
    };
}

fn emitJson(target_view: ?*webkit.WebView, name: []const u8, payload: anytype) !void {
    const gpa = std.heap.smp_allocator;
    const payload_json = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(payload_json);
    const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
    defer gpa.free(name_json);
    const script = try std.fmt.allocPrintSentinel(gpa, "window.ziguri?.__emit({s}, {s});", .{ name_json, payload_json }, 0);

    if (target_view) |tv| {
        _ = gobject.Object.ref(tv.as(gobject.Object));
    }

    const Task = struct {
        target: ?*webkit.WebView,
        script: [:0]u8,
    };
    const task = try gpa.create(Task);
    task.* = .{ .target = target_view, .script = script };
    _ = glib.idleAdd(&evalScriptTask, task);
}

fn evalScriptTask(data: ?*anyopaque) callconv(.c) c_int {
    const task: *struct { target: ?*webkit.WebView, script: [:0]u8 } = @ptrCast(@alignCast(data));
    defer {
        std.heap.smp_allocator.free(task.script);
        std.heap.smp_allocator.destroy(task);
    }
    if (task.target) |v| {
        defer v.as(gobject.Object).unref();
        if (getWindowByView(v) != null) {
            v.evaluateJavascript(task.script, -1, null, null, null, null, null);
        }
    } else {
        ensureWindowsMutex();
        windows_mutex.lock();
        defer windows_mutex.unlock();
        for (windows_list.items) |win| {
            win.web_view.evaluateJavascript(task.script, -1, null, null, null, null, null);
        }
    }
    return 0; // one-shot
}

// The generated binding marks the result non-null, but it is NULL before
// the first load.
extern fn webkit_web_view_get_uri(view: *webkit.WebView) ?[*:0]const u8;

/// Open `uri` with the user's default handler (browser, mail client, …).
pub fn openExternal(uri: [*:0]const u8) void {
    var err: ?*glib.Error = null;
    if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
        if (err) |e| {
            log.err("could not open {s}: {s}", .{ uri, e.f_message orelse "unknown error" });
            e.free();
        }
    }
}

/// Run the application until it quits. Returns the exit code.
pub fn run(comptime api: Api, comptime config: Config) u8 {
    const app_log = @import("log.zig");
    app_log.init(config.id);
    defer app_log.deinit();

    const app_io = io orelse @panic("App.io must be set before App.run; ziguri.main sets this automatically");
    const pool = ThreadPool.init(std.heap.smp_allocator, app_io, null) catch |err| {
        log.err("failed to initialize worker thread pool: {s}", .{@errorName(err)});
        return 1;
    };
    worker_pool = pool;
    defer {
        pool.deinit();
        worker_pool = null;
    }

    const S = Shell(api, config);
    // GTK apps are single-instance per ID: a dev build gets its own ID so it
    // can run next to the installed production app instead of handing off to it.
    const id = if (config.dev != null) config.id ++ ".Dev" else config.id;
    const app = gtk.Application.new(id, .{});
    defer app.unref();
    gtk_app = app;
    defer gtk_app = null;

    const dev_server = if (config.dev) |dev| startDevServer(dev) else null;
    defer if (dev_server) |p| stopDevServer(p);

    // SIGTERM/SIGINT quit through the main loop, so cleanup (dev server,
    // tray, `defer`s in main) still runs.
    _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.TERM), &onQuitSignal, null);
    _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.INT), &onQuitSignal, null);

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &S.activate, null, .{});
    const status = gio.Application.run(app.as(gio.Application), 0, null);
    main_view = null;
    main_window = null;
    return if (status != 0) @intCast(status) else exit_code;
}

// From glib-unix.h (no GIR bindings).
extern fn g_unix_signal_add(signum: c_int, handler: *const fn (?*anyopaque) callconv(.c) c_int, user_data: ?*anyopaque) c_uint;

fn onQuitSignal(_: ?*anyopaque) callconv(.c) c_int {
    quit(0);
    return 0; // remove the source; a second signal gets the default action
}

fn startDevServer(comptime dev: Dev) ?*gio.Subprocess {
    if (glib.getenv("ZIGURI_DEV_EXTERNAL") != null) {
        log.info("dev server managed externally; skipping local spawn", .{});
        return null;
    }
    const command = dev.command orelse return null;
    const argv = comptime blk: {
        var a: [command.len:null]?[*:0]const u8 = undefined;
        for (command, 0..) |arg, i| a[i] = (arg ++ "\x00")[0..arg.len :0];
        break :blk a;
    };
    const launcher = gio.SubprocessLauncher.new(.{});
    defer launcher.unref();
    if (dev.cwd) |cwd| launcher.setCwd((cwd ++ "\x00")[0..cwd.len :0]);
    // If the app dies without cleaning up (crash, SIGKILL), take the dev
    // server down with it instead of leaving it holding the port.
    launcher.setChildSetup(&dieWithParent, null, null);
    var err: ?*glib.Error = null;
    const process = launcher.spawnv(@ptrCast(&argv), &err) orelse {
        if (err) |e| {
            log.err("failed to start dev server: {s}", .{e.f_message orelse "unknown error"});
            e.free();
        }
        return null;
    };
    log.info("dev server started: {s}", .{command[0]});
    return process;
}

fn dieWithParent(_: ?*anyopaque) callconv(.c) void {
    _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @intFromEnum(std.posix.SIG.TERM), 0, 0, 0);
}

fn stopDevServer(process: *gio.Subprocess) void {
    process.sendSignal(@intFromEnum(std.posix.SIG.TERM));
    _ = process.wait(null, null);
    process.unref();
}

fn Shell(comptime api: Api, comptime config: Config) type {
    const dev_url: ?[]const u8 = if (config.dev) |d| d.url else null;
    const local: security.Local = comptime .{ .dev_origin = if (dev_url) |u| blk: {
        var buf: [512]u8 = undefined;
        const o = security.origin(&buf, u) orelse @compileError("invalid dev URL: " ++ u);
        const copy = o[0..o.len].*;
        break :blk &copy;
    } else null };
    const bridge_patterns = comptime blk: {
        const list = security.bridgePatterns(config.security, dev_url);
        var a: [list.len:null]?[*:0]const u8 = undefined;
        for (list, 0..) |p, i| a[i] = p.ptr;
        break :blk a;
    };
    const csp_z: ?[:0]const u8 = if (config.security.csp) |c| (c ++ "\x00")[0..c.len :0] else null;

    return struct {
        var scheme_registered: bool = false;

        fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
            if (main_window) |w| {
                // Second launch of a single-instance app: bring the window back.
                w.present();
                return;
            }
            open_window_fn = &doOpenWindow;

            const main_win = doOpenWindow(.{
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
                return;
            };

            main_window = main_win.gtk_window;
            main_view = main_win.web_view;

            if (config.on_close == .hide) {
                gio.Application.hold(app.as(gio.Application));
            }

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
        }

        fn doOpenWindow(options: WindowOptions) anyerror!*Window {
            const app = gtk_app orelse return error.AppNotRunning;
            const gpa = std.heap.smp_allocator;

            if (getWindow(options.label)) |existing| {
                existing.show();
                return existing;
            }

            const app_window = gtk.ApplicationWindow.new(app);
            const window = app_window.as(gtk.Window);
            window.setTitle(options.title);
            window.setDefaultSize(options.width, options.height);
            window.setResizable(@intFromBool(options.resizable));
            window.setDecorated(@intFromBool(options.decorations));

            if (options.min_width != null or options.min_height != null) {
                window.as(gtk.Widget).setSizeRequest(options.min_width orelse -1, options.min_height orelse -1);
            }

            const view = webkit.WebView.new();
            if (!scheme_registered) {
                const context = view.getContext();
                context.registerUriScheme(scheme, &serveAsset, null, null);
                context.getSecurityManager().registerUriSchemeAsSecure(scheme);
                scheme_registered = true;
            }

            const settings = view.getSettings();
            settings.setEnableDeveloperExtras(@intFromBool(config.devtools));
            settings.setEnableWriteConsoleMessagesToStdout(@intFromBool(config.devtools));
            settings.setJavascriptCanOpenWindowsAutomatically(0);
            settings.setAllowFileAccessFromFileUrls(0);
            settings.setAllowUniversalAccessFromFileUrls(0);

            const content = view.getUserContentManager();
            const script = webkit.UserScript.new(bridge_js, .top_frame, .start, @ptrCast(&bridge_patterns), null);
            content.addScript(script);
            script.unref();
            _ = content.registerScriptMessageHandlerWithReply(handler_name, null);
            _ = webkit.UserContentManager.signals.script_message_with_reply_received.connect(
                content,
                *webkit.WebView,
                &onMessage,
                view,
                .{ .detail = handler_name },
            );
            _ = webkit.WebView.signals.decide_policy.connect(view, ?*anyopaque, &onDecidePolicy, null, .{});

            window.setChild(view.as(gtk.Widget));

            const win_inst = try gpa.create(Window);
            const label_z = try gpa.dupeZ(u8, options.label);
            const title_z = try gpa.dupeZ(u8, options.title);
            var opt_copy = options;
            opt_copy.label = label_z;
            opt_copy.title = title_z;

            win_inst.* = .{
                .label = label_z,
                .app_window = app_window,
                .gtk_window = window,
                .web_view = view,
                .options = opt_copy,
                .app_id = config.id,
            };

            _ = gtk.Window.signals.close_request.connect(window, *Window, &onWindowCloseRequest, win_inst, .{});

            ensureWindowsMutex();
            windows_mutex.lock();
            try windows_list.append(gpa, win_inst);
            windows_mutex.unlock();

            if (options.remember_geometry) {
                win_inst.restoreGeometry();
            }
            if (options.fullscreen) {
                win_inst.setFullscreen(true);
            } else if (options.maximized) {
                win_inst.setMaximized(true);
            }

            if (options.url) |u| {
                if (std.mem.startsWith(u8, u, "http://") or std.mem.startsWith(u8, u, "https://")) {
                    view.loadUri(u);
                } else {
                    const trimmed = std.mem.trimStart(u8, u, "/");
                    const full_uri = try std.fmt.allocPrintSentinel(gpa, "{s}://app/{s}", .{ scheme, trimmed }, 0);
                    defer gpa.free(full_uri);
                    view.loadUri(full_uri);
                }
            } else if (config.dev) |dev| {
                dev_retries_left = dev.timeout_ms / retry_interval_ms;
                _ = webkit.WebView.signals.load_failed.connect(view, ?*anyopaque, &onLoadFailed, null, .{});
                view.loadUri(devUrl());
            } else {
                view.loadUri(scheme ++ "://app/" ++ config.start);
            }

            window.present();
            return win_inst;
        }

        fn onWindowCloseRequest(window: *gtk.Window, win: *Window) callconv(.c) c_int {
            if (std.mem.eql(u8, win.label, "main") and config.on_close == .hide) {
                window.as(gtk.Widget).setVisible(0);
                return 1;
            }

            win.saveGeometry();

            ensureWindowsMutex();
            windows_mutex.lock();
            for (windows_list.items, 0..) |w, i| {
                if (w == win) {
                    _ = windows_list.swapRemove(i);
                    break;
                }
            }
            const remaining = windows_list.items.len;
            windows_mutex.unlock();

            std.heap.smp_allocator.free(win.label);
            std.heap.smp_allocator.free(win.options.title);
            std.heap.smp_allocator.destroy(win);

            if (remaining == 0) {
                quit(0);
            }
            return 0;
        }

        // --- Navigation policy -------------------------------------------

        fn onDecidePolicy(
            _: *webkit.WebView,
            decision: *webkit.PolicyDecision,
            decision_type: webkit.PolicyDecisionType,
            _: ?*anyopaque,
        ) callconv(.c) c_int {
            switch (decision_type) {
                .navigation_action, .new_window_action => {},
                else => return 0, // default handling for responses
            }
            const nav_decision: *webkit.NavigationPolicyDecision = @ptrCast(decision);
            const action = nav_decision.getNavigationAction();
            const uri = action.getRequest().getUri();
            const verdict = security.navigation(config.security, local, std.mem.span(uri), action.isUserGesture() != 0);
            switch (verdict) {
                .allow => if (decision_type == .new_window_action) {
                    // No popups: open allowed targets in the main view.
                    decision.ignore();
                    if (main_view) |v| v.loadUri(uri);
                } else decision.use(),
                .open_external => {
                    decision.ignore();
                    openExternal(uri);
                },
                .block => {
                    decision.ignore();
                    log.warn("blocked navigation to {s}", .{uri});
                },
            }
            return 1;
        }

        // --- Dev server --------------------------------------------------

        const retry_interval_ms = 250;

        fn devUrl() [:0]const u8 {
            const url = config.dev.?.url;
            return (url ++ "\x00")[0..url.len :0];
        }

        fn onLoadFailed(view: *webkit.WebView, _: webkit.LoadEvent, _: [*:0]u8, _: *glib.Error, _: ?*anyopaque) callconv(.c) c_int {
            if (dev_retries_left == 0) return 0; // show WebKit's error page
            dev_retries_left -= 1;
            _ = glib.timeoutAdd(retry_interval_ms, &retryLoad, view);
            return 1;
        }

        fn retryLoad(data: ?*anyopaque) callconv(.c) c_int {
            const view: *webkit.WebView = @ptrCast(@alignCast(data));
            view.loadUri(devUrl());
            return 0; // one-shot
        }

        // --- app:// assets -----------------------------------------------

        fn serveAsset(request: *webkit.URISchemeRequest, _: ?*anyopaque) callconv(.c) void {
            const path = std.mem.span(request.getPath());
            const rel = std.mem.trimStart(u8, path, "/");
            const wanted = if (rel.len == 0) "index.html" else rel;
            const is_route = std.mem.indexOfScalar(u8, std.fs.path.basename(wanted), '.') == null;
            const asset = findAsset(wanted) orelse if (config.spa_fallback and is_route) findAsset("index.html") else null;
            if (asset) |a| {
                const stream = gio.MemoryInputStream.newFromData(@constCast(a.data.ptr), @intCast(a.data.len), null);
                defer stream.unref();
                const response = webkit.URISchemeResponse.new(stream.as(gio.InputStream), @intCast(a.data.len));
                defer response.unref();
                response.setContentType(a.mime);
                // set_http_headers takes ownership of `headers`.
                const headers = soup.MessageHeaders.new(.response);
                headers.append("Content-Type", a.mime);
                headers.append("X-Content-Type-Options", "nosniff");
                if (csp_z) |csp| headers.append("Content-Security-Policy", csp);
                response.setHttpHeaders(headers);
                request.finishWithResponse(response);
                return;
            }
            const err = glib.Error.newLiteral(glib.quarkFromStaticString("ziguri-asset"), 404, "asset not found");
            defer err.free();
            request.finishError(err);
        }

        fn findAsset(path: []const u8) ?Asset {
            for (config.assets) |asset| {
                if (std.mem.eql(u8, asset.path, path)) return asset;
            }
            return null;
        }

        // --- IPC ---------------------------------------------------------

        fn onMessage(
            _: *webkit.UserContentManager,
            value: *jsc.Value,
            reply: *webkit.ScriptMessageReply,
            view: *webkit.WebView,
        ) callconv(.c) c_int {
            const request_ptr = value.toString();
            defer glib.free(request_ptr);
            const req_slice = std.mem.span(request_ptr);

            var parse_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer parse_arena.deinit();
            const temp_alloc = parse_arena.allocator();

            const request = ipc.parseRequest(temp_alloc, req_slice) catch |err| {
                reply.returnErrorMessage(@errorName(err));
                return 1;
            };

            // The page currently shown decides the IPC scope.
            const page_url: []const u8 = if (webkit_web_view_get_uri(view)) |u| std.mem.span(u) else "";
            const caller_win = getWindowByView(view);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;
            if (!security.commandAllowedForWindow(config.security, local, page_url, request.cmd, win_label)) {
                log.warn("blocked command '{s}' from {s} (window: {?s})", .{ request.cmd, page_url, win_label });
                reply.returnErrorMessage("Forbidden");
                return 1;
            }

            if (!ipc.isAsync(api.commands, request.cmd)) {
                const result = ipc.dispatchRequest(api.commands, temp_alloc, request, io) catch |err| {
                    reply.returnErrorMessage(@errorName(err));
                    return 1;
                };
                const result_z = temp_alloc.dupeZ(u8, result) catch {
                    reply.returnErrorMessage("OutOfMemory");
                    return 1;
                };
                const js_value = jsc.Value.newFromJson(value.getContext(), result_z);
                defer js_value.unref();
                reply.returnValue(js_value);
                return 1;
            }

            // Async command: execute on worker pool and reply on GTK main thread.
            const pool = worker_pool orelse {
                reply.returnErrorMessage("WorkerPoolNotRunning");
                return 1;
            };

            _ = reply.ref();
            const context = value.getContext();
            _ = context.ref();

            const GtkReply = struct {
                reply: *webkit.ScriptMessageReply,
                context: *jsc.Context,
                arena_state: std.heap.ArenaAllocator,
                result: ?[:0]const u8,
                err_name: ?[:0]const u8,

                fn onWorkerDone(self: *@This(), arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                    self.arena_state = arena_state;
                    self.result = res;
                    self.err_name = err_name;
                    _ = glib.idleAdd(&idleReply, self);
                }

                fn idleReply(data: ?*anyopaque) callconv(.c) c_int {
                    const self: *@This() = @ptrCast(@alignCast(data));
                    defer {
                        self.reply.unref();
                        self.context.unref();
                        var a = self.arena_state;
                        a.deinit();
                        std.heap.smp_allocator.destroy(self);
                    }
                    if (self.err_name) |err| {
                        self.reply.returnErrorMessage(err);
                    } else if (self.result) |res_z| {
                        const js_value = jsc.Value.newFromJson(self.context, res_z);
                        defer js_value.unref();
                        self.reply.returnValue(js_value);
                    }
                    return 0; // one-shot idle callback
                }
            };

            const gtk_reply = std.heap.smp_allocator.create(GtkReply) catch {
                reply.unref();
                context.unref();
                reply.returnErrorMessage("OutOfMemory");
                return 1;
            };
            gtk_reply.* = .{
                .reply = reply,
                .context = context,
                .arena_state = undefined,
                .result = null,
                .err_name = null,
            };

            ipc.dispatchAsync(api.commands, pool, std.heap.smp_allocator, req_slice, io, gtk_reply, GtkReply.onWorkerDone) catch |err| {
                reply.unref();
                context.unref();
                std.heap.smp_allocator.destroy(gtk_reply);
                reply.returnErrorMessage(@errorName(err));
                return 1;
            };

            return 1;
        }
    };
}
