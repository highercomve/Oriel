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
const isolation = @import("../../core/isolation.zig");
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

/// Run `func(ctx)` on the GTK main thread (from any thread; always queued).
/// `cleanup(ctx)` runs instead if the task can't be queued.
pub fn dispatchWithCleanup(
    func: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque,
    cleanup: ?*const fn (ctx: ?*anyopaque) void,
) void {
    const Task = struct {
        func: *const fn (ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
        fn run(data: ?*anyopaque) callconv(.c) c_int {
            const self: *@This() = @ptrCast(@alignCast(data.?));
            defer std.heap.smp_allocator.destroy(self);
            self.func(self.ctx);
            return 0; // G_SOURCE_REMOVE
        }
    };
    const task = std.heap.smp_allocator.create(Task) catch {
        if (cleanup) |c| c(ctx);
        return;
    };
    task.* = .{ .func = func, .ctx = ctx };
    _ = glib.idleAdd(&Task.run, task);
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

const build_opts = @import("build_options");
const deep_link = if (build_opts.deep_link) @import("../../modules/deep_link.zig") else struct {};

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
    // With isolation on, the CSP also allows the isolation frame.
    const csp_z: ?[:0]const u8 = if (comptime isolation.appCsp(config.security)) |c| (c ++ "\x00")[0..c.len :0] else null;

    const Creator = window.WindowCreator(api, config, local, bridge_patterns, csp_z);

    return struct {
        /// GApplication hands the running instance the command line of later
        /// launches (deep links, `on_second_instance`).
        const uses_command_line = build_opts.deep_link or config.on_second_instance != null;

        pub fn run(io: std.Io) u8 {
            _ = io;
            const id = if (config.dev != null) config.id ++ ".Dev" else config.id;
            const app_flags = if (uses_command_line)
                gio.ApplicationFlags{ .handles_command_line = true }
            else
                gio.ApplicationFlags{};
            const app = gtk.Application.new(id, app_flags);
            defer app.unref();
            App.gtk_app = app;
            defer App.gtk_app = null;

            const id_z = (config.id ++ "\x00")[0..config.id.len :0];
            gtk.Window.setDefaultIconName(id_z);

            const dev_server_proc = if (config.dev) |dev| dev_server.startDevServer(dev) else null;
            defer if (dev_server_proc) |p| dev_server.stopDevServer(p);

            _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.TERM), &onQuitSignal, null);
            _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.INT), &onQuitSignal, null);

            // Under dev_runner (`zig build dev`), exit when dev_runner dies, even by
            // SIGKILL: it can't clean up then. dev_runner exports its pid, so a parent
            // that already died before prctl (we were reparented) is detected too.
            if (glib.getenv("ORIEL_DEV_RUNNER_PID")) |runner_pid| {
                const linux = std.os.linux;
                const rc = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(std.posix.SIG.TERM), 0, 0, 0);
                if (linux.errno(rc) != .SUCCESS) log.err("prctl(PR_SET_PDEATHSIG): {s}", .{@tagName(linux.errno(rc))});
                const expected = std.fmt.parseInt(linux.pid_t, std.mem.span(runner_pid), 10) catch 0;
                if (linux.getppid() != expected) {
                    log.err("dev_runner (pid {s}) is gone; exiting", .{runner_pid});
                    return 1;
                }
            }

            active_create_window_fn = &Creator.createWindow;
            defer active_create_window_fn = null;

            const gpa = std.heap.smp_allocator;
            var argv_ptrs: std.ArrayList(?[*:0]u8) = .empty;
            defer {
                for (argv_ptrs.items) |p| if (p) |ptr| gpa.free(std.mem.span(ptr));
                argv_ptrs.deinit(gpa);
            }
            if (App.process_args.len > 0) {
                for (App.process_args) |arg| {
                    const arg_z = gpa.dupeZ(u8, arg) catch break;
                    argv_ptrs.append(gpa, arg_z.ptr) catch {
                        gpa.free(arg_z);
                        break;
                    };
                }
            } else {
                if (gpa.dupeZ(u8, config.id)) |ez| {
                    argv_ptrs.append(gpa, ez.ptr) catch gpa.free(ez);
                } else |_| {}
            }

            if (uses_command_line) {
                _ = gio.Application.signals.command_line.connect(app, ?*anyopaque, &onCommandLine, null, .{});
            } else {
                _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &activate, null, .{});
            }
            var has_null = false;
            if (argv_ptrs.items.len > 0) {
                if (argv_ptrs.append(gpa, null)) |_| {
                    has_null = true;
                } else |_| {}
            }
            const argc: usize = if (has_null) argv_ptrs.items.len - 1 else argv_ptrs.items.len;
            const status = if (argc > 0)
                gio.Application.run(app.as(gio.Application), @intCast(argc), @ptrCast(argv_ptrs.items.ptr))
            else
                gio.Application.run(app.as(gio.Application), 0, null);
            App.main_window = null;
            return if (status != 0) @truncate(@as(u32, @bitCast(status))) else exit_code;
        }

        fn onCommandLine(app: *gtk.Application, cmdline: *gio.ApplicationCommandLine, _: ?*anyopaque) callconv(.c) c_int {
            var argc: c_int = 0;
            const argv = gio.ApplicationCommandLine.getArguments(cmdline, &argc);
            defer glib.strfreev(@ptrCast(argv));
            const n: usize = @intCast(@max(argc, 0));

            var maybe_url: ?[]const u8 = null;
            if (build_opts.deep_link) {
                for (1..n) |idx| {
                    const arg_slice = std.mem.span(argv[idx]);
                    if (deep_link.validate(arg_slice, config.deep_link_schemes)) |_| {
                        maybe_url = arg_slice;
                        break;
                    } else |_| {}
                }
            }

            if (App.main_window) |w| {
                // A later launch: the running instance handles it.
                if (config.on_second_instance) |handler| {
                    forwardArgs(handler, argv, n);
                } else {
                    w.present();
                }
                if (build_opts.deep_link) if (maybe_url) |url| deep_link.deliver(url);
                return 0;
            }

            if (build_opts.deep_link) if (maybe_url) |url| deep_link.setColdStartUrl(url);

            activate(app, null);

            if (build_opts.deep_link) if (maybe_url) |url| deep_link.deliver(url);

            return 0;
        }

        /// Call `handler` with the launch's arguments (without argv[0]).
        fn forwardArgs(handler: *const fn ([]const []const u8) void, argv: [*][*:0]u8, n: usize) void {
            const gpa = std.heap.smp_allocator;
            const args = gpa.alloc([]const u8, n -| 1) catch return;
            defer gpa.free(args);
            for (args, 1..) |*a, idx| a.* = std.mem.span(argv[idx]);
            handler(args);
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
                .visible = config.show_main_window,
                .transparent = config.transparent,
                .always_on_top = config.always_on_top,
                .skip_taskbar = config.skip_taskbar,
                .placement = config.placement,
            }) catch |err| {
                log.err("failed to open main window: {s}", .{@errorName(err)});
                return;
            };

            App.main_window = main_win.handle.gtk_window;

            if (config.on_close == .hide or !config.show_main_window) {
                holdApp();
            }

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
        }
    };
}
