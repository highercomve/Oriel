//! Linux dev server lifecycle management.
//!
//! Spawns and manages external dev server processes (e.g. Vite) using
//! GIO's SubprocessLauncher, and handles automatic load retries in WebKit.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const webkit = @import("webkit");

const log = std.log.scoped(.oriel);

pub const retry_interval_ms = 250;

pub fn startDevServer(dev: anytype) ?*gio.Subprocess {
    if (glib.getenv("ORIEL_DEV_EXTERNAL") != null) {
        log.info("dev server managed externally; skipping local spawn", .{});
        return null;
    }
    const command = dev.command orelse return null;
    const gpa = std.heap.smp_allocator;
    const argv = gpa.alloc(?[*:0]const u8, command.len + 1) catch return null;
    defer gpa.free(argv);

    for (command, 0..) |arg, i| {
        const arg_z = gpa.dupeZ(u8, arg) catch return null;
        argv[i] = arg_z.ptr;
    }
    defer for (argv[0..command.len]) |arg_ptr| {
        if (arg_ptr) |p| gpa.free(std.mem.span(p));
    };
    argv[command.len] = null;

    const launcher = gio.SubprocessLauncher.new(.{});
    defer launcher.unref();
    if (dev.cwd) |cwd| {
        const cwd_z = gpa.dupeZ(u8, cwd) catch return null;
        defer gpa.free(cwd_z);
        launcher.setCwd(cwd_z.ptr);
    }
    // If the app dies without cleaning up (crash, SIGKILL), take the dev
    // server down with it instead of leaving it holding the port.
    launcher.setChildSetup(&dieWithParent, null, null);
    var err: ?*glib.Error = null;
    const process = launcher.spawnv(@ptrCast(argv.ptr), &err) orelse {
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

pub fn stopDevServer(process: *gio.Subprocess) void {
    process.sendSignal(@intFromEnum(std.posix.SIG.TERM));
    _ = process.wait(null, null);
    process.unref();
}

pub fn DevRetryContext(comptime dev_url_fn: *const fn () [:0]const u8) type {
    return struct {
        pub var dev_retries_left: u32 = 0;

        pub fn initRetries(timeout_ms: u32) void {
            dev_retries_left = timeout_ms / retry_interval_ms;
        }

        pub fn onLoadFailed(view: *webkit.WebView, _: webkit.LoadEvent, _: [*:0]u8, _: *glib.Error, _: ?*anyopaque) callconv(.c) c_int {
            if (dev_retries_left == 0) return 0; // show WebKit's error page
            dev_retries_left -= 1;
            _ = glib.timeoutAdd(retry_interval_ms, &retryLoad, view);
            return 1;
        }

        fn retryLoad(data: ?*anyopaque) callconv(.c) c_int {
            const view: *webkit.WebView = @ptrCast(@alignCast(data));
            view.loadUri(dev_url_fn());
            return 0; // one-shot
        }
    };
}
