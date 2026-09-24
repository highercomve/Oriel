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
        log.info("dev server managed externally; skipping local spawn", .{});
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

pub fn stopDevServer(io: std.Io, child: *std.process.Child) void {
    const pid = child.id orelse return;
    std.posix.kill(-pid, .TERM) catch |err| log.err("stopping the dev server: {s}", .{@errorName(err)});
    _ = child.wait(io) catch |err| log.err("waiting for the dev server: {s}", .{@errorName(err)});
}
