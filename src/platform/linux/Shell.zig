//! Linux application shell and main loop.
//!
//! Manages the `GtkApplication` lifecycle, signal handling (SIGTERM, SIGINT),
//! main-thread event loop dispatch, and application menubar integration.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const gtk = @import("gtk");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const dev_server = @import("dev_server.zig");
const window = @import("window.zig");
const WindowHandle = window.WindowHandle;

const log = std.log.scoped(.oriel);

var exit_code: u8 = 0;

pub const Mutex = struct {
    inner: glib.Mutex = undefined,
    initialized: bool = false,

    pub fn init() Mutex {
        var m = Mutex{};
        m.inner.init();
        m.initialized = true;
        return m;
    }

    pub fn lock(self: *Mutex) void {
        self.inner.lock();
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};

pub var active_create_window_fn: ?*const fn (options: App.WindowOptions, win_inst: *App.Window) anyerror!WindowHandle = null;

pub fn createWindow(options: App.WindowOptions, win_inst: *App.Window) !WindowHandle {
    if (active_create_window_fn) |f| return f(options, win_inst) else return error.AppNotRunning;
}

pub fn quit(code: u8) void {
    exit_code = code;
    if (glib.MainContext.default().isOwner() != 0) {
        quitNow();
    } else {
        _ = glib.idleAdd(&quitIdle, null);
    }
}

fn quitNow() void {
    if (App.gtk_app) |app| gio.Application.quit(app.as(gio.Application));
}

fn quitIdle(_: ?*anyopaque) callconv(.c) c_int {
    quitNow();
    return 0; // one-shot
}

// From glib-unix.h (no GIR bindings).
extern fn g_unix_signal_add(signum: c_int, handler: *const fn (?*anyopaque) callconv(.c) c_int, user_data: ?*anyopaque) c_uint;

fn onQuitSignal(_: ?*anyopaque) callconv(.c) c_int {
    quit(0);
    return 0; // remove the source; a second signal gets the default action
}

pub fn holdApp() void {
    if (App.gtk_app) |app| {
        gio.Application.hold(app.as(gio.Application));
    }
}

pub fn setMenu(items: anytype, on_action: anytype) !void {
    const app = App.gtk_app orelse return error.AppNotRunning;
    const menu_mod = @import("../../modules/menu.zig");
    try menu_mod.set(app, items, on_action);
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |win| {
        win.handle.app_window.setShowMenubar(1);
    }
}

pub fn Shell(comptime api: App.Api, comptime config: App.Config) type {
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

    const Creator = window.WindowCreator(api, config, local, bridge_patterns, csp_z);

    return struct {
        pub fn run(io: std.Io) u8 {
            _ = io;
            const id = if (config.dev != null) config.id ++ ".Dev" else config.id;
            const app = gtk.Application.new(id, .{});
            defer app.unref();
            App.gtk_app = app;
            defer App.gtk_app = null;

            const dev_server_proc = if (config.dev) |dev| dev_server.startDevServer(dev) else null;
            defer if (dev_server_proc) |p| dev_server.stopDevServer(p);

            _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.TERM), &onQuitSignal, null);
            _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.INT), &onQuitSignal, null);

            active_create_window_fn = &Creator.createWindow;
            defer active_create_window_fn = null;

            _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &activate, null, .{});
            const status = gio.Application.run(app.as(gio.Application), 0, null);
            App.main_window = null;
            return if (status != 0) @intCast(status) else exit_code;
        }

        fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
            _ = app;
            if (App.main_window) |w| {
                // Second launch of a single-instance app: bring the window back.
                w.present();
                return;
            }

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
                return;
            };

            App.main_window = main_win.handle.gtk_window;

            if (config.on_close == .hide) {
                holdApp();
            }

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
        }
    };
}
