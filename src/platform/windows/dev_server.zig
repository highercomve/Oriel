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

fn getEnvAlloc(gpa: std.mem.Allocator, name_u8: []const u8) ?[:0]u16 {
    const name_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, name_u8) catch return null;
    defer gpa.free(name_w);
    // The first call returns the size including the terminator; allocate
    // exactly `len - 1` characters (+ sentinel) and return that same slice,
    // so the caller's `gpa.free` frees the allocated size.
    const len = win32.GetEnvironmentVariableW(name_w.ptr, null, 0);
    if (len <= 1) return null;
    const buf = gpa.allocSentinel(u16, len - 1, 0) catch return null;
    const written = win32.GetEnvironmentVariableW(name_w.ptr, buf.ptr, len);
    if (written != len - 1) { // changed between the calls
        gpa.free(buf);
        return null;
    }
    return buf;
}

fn utf16ToUtf8Alloc(gpa: std.mem.Allocator, s: []const u16) ?[]u8 {
    return std.unicode.utf16LeToUtf8Alloc(gpa, s) catch null;
}

fn findNodeDir(io: std.Io, gpa: std.mem.Allocator) ?[]const u8 {
    // 1. Check ~/.oriel/node/<v>
    const userprofile_w = getEnvAlloc(gpa, "USERPROFILE") orelse getEnvAlloc(gpa, "HOME");
    if (userprofile_w) |up_w| {
        defer gpa.free(up_w);
        if (utf16ToUtf8Alloc(gpa, up_w)) |up_u8| {
            defer gpa.free(up_u8);
            const oriel_node = std.fs.path.join(gpa, &.{ up_u8, ".oriel", "node" }) catch null;
            if (oriel_node) |node_root| {
                defer gpa.free(node_root);
                if (std.Io.Dir.cwd().openDir(io, node_root, .{ .iterate = true })) |dir| {
                    var d = dir;
                    defer d.close(io);
                    // The newest installed version (`oriel setup node`).
                    var best: ?[]const u8 = null;
                    var best_ver: std.SemanticVersion = undefined;
                    var it = d.iterate();
                    while (it.next(io) catch null) |entry| {
                        if (entry.kind != .directory) continue;
                        _ = std.SemanticVersion.parse(std.mem.trimStart(u8, entry.name, "v")) catch continue;
                        const sub = std.fs.path.join(gpa, &.{ node_root, entry.name }) catch continue;
                        const node_exe = std.fs.path.join(gpa, &.{ sub, "node.exe" }) catch {
                            gpa.free(sub);
                            continue;
                        };
                        defer gpa.free(node_exe);
                        std.Io.Dir.cwd().access(io, node_exe, .{}) catch {
                            gpa.free(sub);
                            continue;
                        };
                        // Parsed from `sub` (owned): `pre`/`build` slice into it.
                        const ver = std.SemanticVersion.parse(std.mem.trimStart(u8, std.fs.path.basename(sub), "v")) catch unreachable;
                        if (best == null or ver.order(best_ver) == .gt) {
                            if (best) |prev| gpa.free(prev);
                            best = sub;
                            best_ver = ver;
                        } else gpa.free(sub);
                    }
                    if (best) |b| return b;
                } else |_| {}
            }
        }
    }

    // 2. Common install dirs
    const candidates = [_]struct { env: []const u8, sub: []const u8 }{
        .{ .env = "ProgramFiles", .sub = "nodejs" },
        .{ .env = "ProgramFiles(x86)", .sub = "nodejs" },
        .{ .env = "LOCALAPPDATA", .sub = "Programs\\nodejs" },
    };
    for (candidates) |c| {
        if (getEnvAlloc(gpa, c.env)) |env_w| {
            defer gpa.free(env_w);
            if (utf16ToUtf8Alloc(gpa, env_w)) |env_u8| {
                defer gpa.free(env_u8);
                const full = std.fs.path.join(gpa, &.{ env_u8, c.sub }) catch continue;
                const node_exe = std.fs.path.join(gpa, &.{ full, "node.exe" }) catch {
                    gpa.free(full);
                    continue;
                };
                defer gpa.free(node_exe);
                if (std.Io.Dir.cwd().access(io, node_exe, .{})) |_| {
                    return full;
                } else |_| {
                    gpa.free(full);
                }
            }
        }
    }

    return null;
}

/// A copy of the environment with `dir` prepended to PATH, for the child
/// only (changing this process's PATH would race other threads' spawns).
fn environWithPath(gpa: std.mem.Allocator, dir: []const u8) ?std.process.Environ.Map {
    const env: std.process.Environ = .{ .block = .global };
    var map = env.createMap(gpa) catch return null;
    const new_path = if (map.get("PATH")) |old|
        std.fmt.allocPrint(gpa, "{s};{s}", .{ dir, old }) catch {
            map.deinit();
            return null;
        }
    else
        gpa.dupe(u8, dir) catch {
            map.deinit();
            return null;
        };
    defer gpa.free(new_path);
    map.put("PATH", new_path) catch {
        map.deinit();
        return null;
    };
    return map;
}

/// `<dir>\<name>` with the first of .cmd/.exe/.bat that exists, or null.
fn resolveIn(io: std.Io, gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ?[]u8 {
    if (std.mem.indexOfAny(u8, name, "\\/:") != null) return null;
    const has_ext = std.fs.path.extension(name).len != 0;
    for ([_][]const u8{ "", ".cmd", ".exe", ".bat" }) |ext| {
        if (has_ext != (ext.len == 0)) continue;
        const full = std.fmt.allocPrint(gpa, "{s}\\{s}{s}", .{ dir, name, ext }) catch return null;
        std.Io.Dir.cwd().access(io, full, .{}) catch {
            gpa.free(full);
            continue;
        };
        return full;
    }
    return null;
}

pub fn startDevServer(io: std.Io, dev: anytype) ?DevServer {
    if (managedExternally()) {
        return null;
    }
    const command = dev.command orelse return null;
    if (command.len == 0) return null;

    var job = createKillOnCloseJob();
    const suspended = job != null;
    const spawn_cfg: std.process.SpawnOptions = .{
        .argv = command,
        .cwd = if (dev.cwd) |cwd| .{ .path = cwd } else .inherit,
        .start_suspended = suspended,
        // The app is a GUI program: no console window for vite.cmd / node.
        .create_no_window = true,
    };

    const child = std.process.spawn(io, spawn_cfg) catch |first_err| blk: {
        // Node installed but not on PATH (e.g. by `oriel setup node`): run
        // the command from its directory, with that directory on the child's PATH.
        if (first_err == error.FileNotFound) retry: {
            const gpa = std.heap.smp_allocator;
            const node_dir = findNodeDir(io, gpa) orelse break :retry;
            defer gpa.free(node_dir);
            const exe = resolveIn(io, gpa, node_dir, command[0]) orelse break :retry;
            defer gpa.free(exe);
            const argv = gpa.alloc([]const u8, command.len) catch break :retry;
            defer gpa.free(argv);
            argv[0] = exe;
            @memcpy(argv[1..], command[1..]);
            var env = environWithPath(gpa, node_dir) orelse break :retry;
            defer env.deinit();
            var cfg = spawn_cfg;
            cfg.argv = argv;
            cfg.environ_map = &env;
            if (std.process.spawn(io, cfg)) |c| {
                log.debug("dev server: using Node from {s}", .{node_dir});
                break :blk c;
            } else |_| {}
        }
        log.err("failed to start dev server '{s}': {s} (dev command not found in PATH; ensure Node.js is installed or run 'oriel setup node')", .{ command[0], @errorName(first_err) });
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
