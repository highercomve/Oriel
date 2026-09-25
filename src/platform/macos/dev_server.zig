//! Dev server lifecycle for macOS dev builds: start `config.dev.command`
//! (e.g. Vite) with the app and stop it when the app exits, like the Linux
//! backend. `zig build dev`'s runner (tools/dev_runner.zig) is Linux-only,
//! so on macOS run the dev executable (`zig build build-dev`) directly.
//!
//! Known limit: macOS has no PR_SET_PDEATHSIG, so if the app is killed
//! (SIGKILL, crash) the dev server keeps running and holds its port.

const std = @import("std");

const log = std.log.scoped(.oriel);

pub fn startDevServer(io: std.Io, dev: anytype) ?std.process.Child {
    if (std.c.getenv("ORIEL_DEV_EXTERNAL") != null) {
        return null;
    }
    const command = dev.command orelse return null;
    if (command.len == 0) return null;
    const child = std.process.spawn(io, .{
        .argv = command,
        .cwd = if (dev.cwd) |cwd| .{ .path = cwd } else .inherit,
        // Its own process group, so stopping it also stops what it spawned.
        .pgid = 0,
    }) catch |err| {
        log.err("failed to start dev server {s}: {s}", .{ command[0], @errorName(err) });
        return null;
    };
    log.info("dev server started: {s}", .{command[0]});
    return child;
}

/// SIGTERM to the dev server's process group; SIGKILL if it hasn't exited
/// after 3 s, so quitting never hangs on a server that ignores SIGTERM.
pub fn stopDevServer(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    std.posix.kill(-pid, .TERM) catch |err| log.err("stopping the dev server: {s}", .{@errorName(err)});
    var waited_ms: u32 = 0;
    while (waited_ms < 3000) : (waited_ms += 50) {
        var status: c_int = 0;
        const WNOHANG = 1;
        if (std.c.waitpid(pid, &status, WNOHANG) == pid) {
            child.id = null; // reaped here: `wait` must not wait again
            return;
        }
        const ts: std.c.timespec = .{ .sec = 0, .nsec = 50 * std.time.ns_per_ms };
        _ = std.c.nanosleep(&ts, null);
    }
    log.warn("dev server ignored SIGTERM; killing it", .{});
    std.posix.kill(-pid, .KILL) catch |err| log.err("killing the dev server: {s}", .{@errorName(err)});
    _ = child.wait(io) catch |err| log.err("waiting for the dev server: {s}", .{@errorName(err)});
}
