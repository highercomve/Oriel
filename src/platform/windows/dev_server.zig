//! Dev server lifecycle for Windows dev builds: start `config.dev.command`
//! (e.g. Vite) with the app and stop it when the app exits, like the Linux
//! and macOS backends. Under `oriel dev` / `zig build dev` dev_runner already
//! runs the server and sets ORIEL_DEV_EXTERNAL, so nothing is started here.
//!
//! The server runs in a kill-on-close job object: when the app exits for any
//! reason (closed, crashed, ended from Task Manager) Windows closes the job
//! handle and ends the server with everything it started (node, esbuild).
//! It is spawned suspended and only resumed once it is in the job, so no
//! helper it starts can escape the job.
//!
//! `std.process.spawn` resolves the command through PATHEXT, so
//! `node_modules/.bin/vite` runs `vite.cmd`, and it escapes the arguments of
//! a `.cmd`/`.bat` for cmd.exe itself: config values can't inject commands.

const std = @import("std");
const win32 = @import("win32.zig");

const log = std.log.scoped(.oriel);

/// Delay between attempts to load the dev URL while the server starts.
pub const retry_interval_ms = 250;

pub const DevServer = struct {
    child: std.process.Child,
    /// Kill-on-close job holding the server and its helpers; null if it
    /// couldn't be set up (then only the direct child is stopped).
    job: ?win32.HANDLE,
};

fn managedExternally() bool {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ORIEL_DEV_EXTERNAL");
    // With no buffer: the size the value needs, or 0 when it is unset.
    return win32.GetEnvironmentVariableW(name, null, 0) != 0;
}

/// A job that ends every process in it when its last handle is closed.
fn createKillOnCloseJob() ?win32.HANDLE {
    const job = win32.CreateJobObjectW(null, null) orelse {
        log.warn("dev server: CreateJobObjectW failed ({d})", .{win32.GetLastError()});
        return null;
    };
    const info: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{ .LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE };
    if (win32.SetInformationJobObject(job, win32.JobObjectExtendedLimitInformation, &info, @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == win32.FALSE) {
        log.warn("dev server: SetInformationJobObject failed ({d})", .{win32.GetLastError()});
        _ = win32.CloseHandle(job);
        return null;
    }
    return job;
}

pub fn startDevServer(io: std.Io, dev: anytype) ?DevServer {
    if (managedExternally()) {
        log.info("dev server managed externally; skipping local spawn", .{});
        return null;
    }
    const command = dev.command orelse return null;
    if (command.len == 0) return null;

    var job = createKillOnCloseJob();
    const suspended = job != null;
    const child = std.process.spawn(io, .{
        .argv = command,
        .cwd = if (dev.cwd) |cwd| .{ .path = cwd } else .inherit,
        .start_suspended = suspended,
        // The app is a GUI program: no console window for vite.cmd / node.
        .create_no_window = true,
    }) catch |err| {
        log.err("failed to start dev server {s}: {s}", .{ command[0], @errorName(err) });
        if (job) |j| _ = win32.CloseHandle(j);
        return null;
    };

    if (job) |j| {
        if (win32.AssignProcessToJobObject(j, child.id.?) == win32.FALSE) {
            log.warn("dev server: AssignProcessToJobObject failed ({d}); it may outlive the app", .{win32.GetLastError()});
            _ = win32.CloseHandle(j);
            job = null;
        }
    }
    var server: DevServer = .{ .child = child, .job = job };
    if (suspended and win32.ResumeThread(child.thread_handle) == std.math.maxInt(win32.DWORD)) {
        log.err("dev server: ResumeThread failed ({d})", .{win32.GetLastError()});
        stopDevServer(io, &server);
        return null;
    }
    log.info("dev server started: {s}", .{command[0]});
    return server;
}

/// End the server and everything it started, reap it and release its handles.
pub fn stopDevServer(io: std.Io, server: *DevServer) void {
    if (server.job) |j| {
        if (win32.TerminateJobObject(j, 1) == win32.FALSE) {
            log.err("stopping the dev server: TerminateJobObject failed ({d})", .{win32.GetLastError()});
            server.child.kill(io); // at least the direct child
        } else {
            _ = server.child.wait(io) catch server.child.kill(io);
        }
        _ = win32.CloseHandle(j);
        server.job = null;
    } else {
        server.child.kill(io); // TerminateProcess + wait
    }
}
