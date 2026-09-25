//! Dev runner for oriel apps.
//! Runs the frontend dev server (e.g. Vite) and keeps it alive while watching
//! `src/` for Zig file changes, rebuilding the app, and restarting it.
//!
//! Linux watches with inotify and ties its lifetime to `zig` (PDEATHSIG,
//! pidfd). macOS and Windows poll the Zig files' modification times and
//! the `zig` process instead. On POSIX every child runs in its own process
//! group so its helpers stop with it; Windows has no process groups, so
//! only the direct child is terminated there.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

const native_os = builtin.os.tag;
const is_linux = native_os == .linux;
const is_windows = native_os == .windows;

var global_dev_child: ?std.process.Child = null;
var global_app_child: ?std.process.Child = null;
var global_should_exit: std.atomic.Value(bool) = .init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    global_should_exit.store(true, .release);
}

fn sleepMs(io: Io, ms: u32) void {
    const to: Io.Timeout = .{ .duration = .{
        .raw = .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms },
        .clock = .awake,
    } };
    to.sleep(io) catch {};
}

// ---------------------------------------------------------------------------
// POSIX process groups (Linux: raw syscalls, no libc; macOS: libc)
// ---------------------------------------------------------------------------

fn isProcessGroupAlive(pgid: posix.pid_t) bool {
    if (pgid <= 0) return false;
    if (is_linux) {
        const rc = linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, -pgid))), 0);
        return linux.errno(rc) != .SRCH;
    }
    posix.kill(-pgid, @enumFromInt(0)) catch |err| return err != error.ProcessNotFound;
    return true;
}

/// `waitpid(pid, WNOHANG or 0)`: the reaped pid and its raw status, or null.
fn waitPid(pid: posix.pid_t, block: bool) ?struct { pid: posix.pid_t, status: u32 } {
    if (is_linux) {
        var status: u32 = 0;
        const res = linux.waitpid(pid, &status, if (block) 0 else linux.W.NOHANG);
        if (linux.errno(res) != .SUCCESS or @as(isize, @bitCast(res)) <= 0) return null;
        return .{ .pid = @intCast(res), .status = status };
    }
    var status: c_int = 0;
    const res = std.c.waitpid(pid, &status, if (block) 0 else std.c.W.NOHANG);
    if (res <= 0) return null;
    return .{ .pid = res, .status = @bitCast(status) };
}

fn reapZombies() void {
    while (waitPid(-1, false) != null) {}
}

fn checkChildExit(pid: posix.pid_t) ?u8 {
    const r = waitPid(pid, false) orelse return null;
    if (r.pid != pid) return null;
    return if ((r.status & 0x7f) == 0) @truncate((r.status >> 8) & 0xff) else 1;
}

fn signalPid(pid: posix.pid_t, sig: posix.SIG) error{ProcessNotFound}!void {
    if (is_linux) {
        if (linux.errno(linux.kill(pid, sig)) == .SRCH) return error.ProcessNotFound;
        return;
    }
    posix.kill(pid, sig) catch |err| if (err == error.ProcessNotFound) return error.ProcessNotFound;
}

fn killProcessGroup(io: Io, pgid: posix.pid_t, direct_pid: ?posix.pid_t) void {
    if (pgid <= 0) return;

    // Send SIGTERM to the entire process group.
    // Using a negative pgid signals every process in that process group.
    signalPid(-pgid, posix.SIG.TERM) catch {
        if (direct_pid) |p| _ = checkChildExit(p);
        reapZombies();
        return;
    };

    if (direct_pid) |p| {
        if (p > 0 and p != pgid) signalPid(p, posix.SIG.TERM) catch {};
    }

    // Grace period: wait up to ~500ms (10 * 50ms) for graceful exit
    var still_alive = true;
    for (0..10) |_| {
        reapZombies();
        if (direct_pid) |p| _ = checkChildExit(p);

        if (!isProcessGroupAlive(pgid)) {
            still_alive = false;
            break;
        }
        sleepMs(io, 50);
    }

    // Escalate to SIGKILL if processes remain alive
    if (still_alive) {
        signalPid(-pgid, posix.SIG.KILL) catch {};
        if (direct_pid) |p| {
            if (p > 0 and p != pgid) signalPid(p, posix.SIG.KILL) catch {};
        }

        for (0..10) |_| {
            reapZombies();
            if (direct_pid) |p| _ = checkChildExit(p);
            if (!isProcessGroupAlive(pgid)) break;
            sleepMs(io, 20);
        }
    }

    if (direct_pid) |p| _ = checkChildExit(p);
    reapZombies();
}

// ---------------------------------------------------------------------------
// Children, per OS
// ---------------------------------------------------------------------------

const windows = struct {
    const HANDLE = std.os.windows.HANDLE;
    extern "kernel32" fn WaitForSingleObject(handle: HANDLE, ms: u32) callconv(.winapi) u32;
    const WAIT_OBJECT_0 = 0;
};

/// Exit code if `child` has exited (it is reaped then), else null.
fn childExited(io: Io, child: *std.process.Child) ?u8 {
    const id = child.id orelse return null;
    if (is_windows) {
        if (windows.WaitForSingleObject(id, 0) != windows.WAIT_OBJECT_0) return null;
        const term = child.wait(io) catch return 1; // returns at once: it has exited
        return switch (term) {
            .exited => |code| code,
            else => 1,
        };
    }
    const code = checkChildExit(id) orelse return null;
    child.id = null;
    return code;
}

/// Stop `child` (and, on POSIX, its process group) and reap it.
fn stopChild(io: Io, child: *std.process.Child) void {
    const id = child.id orelse return;
    if (is_windows) {
        child.kill(io); // TerminateProcess + wait
        return;
    }
    killProcessGroup(io, id, id); // spawned with .pgid = 0: its pgid is its pid
    child.id = null;
}

fn spawnInGroup(io: Io, argv: []const []const u8, cwd: []const u8, env: *const std.process.Environ.Map) std.process.SpawnError!std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = env,
        .pgid = if (is_windows) null else 0,
    });
}

fn getPid() i64 {
    return switch (native_os) {
        .linux => linux.getpid(),
        .windows => std.os.windows.GetCurrentProcessId(),
        else => std.c.getpid(),
    };
}

// ---------------------------------------------------------------------------
// Watching
// ---------------------------------------------------------------------------

fn skipDir(basename: []const u8) bool {
    return std.mem.startsWith(u8, basename, ".") or
        std.mem.eql(u8, basename, "node_modules") or
        std.mem.eql(u8, basename, "dist") or
        std.mem.eql(u8, basename, "zig-out") or
        std.mem.eql(u8, basename, "zig-pkg");
}

/// Portable watcher (macOS, Windows): a fingerprint of every `.zig` file's
/// path, size and modification time under the watched directories,
/// compared every poll. Cheap for an app's `src/`.
const PollWatcher = struct {
    dirs: []const []const u8,
    last: u64,
    /// Name of a changed file seen by the last `changed` call (for the log).
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,

    fn init(gpa: std.mem.Allocator, io: Io, dirs: []const []const u8) PollWatcher {
        var w: PollWatcher = .{ .dirs = dirs, .last = 0 };
        w.last = w.fingerprint(gpa, io, null);
        return w;
    }

    /// Whether any .zig file changed since the last call.
    fn changed(self: *PollWatcher, gpa: std.mem.Allocator, io: Io) bool {
        const now = self.fingerprint(gpa, io, self);
        if (now == self.last) return false;
        self.last = now;
        return true;
    }

    fn changedName(self: *const PollWatcher) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn fingerprint(self: *const PollWatcher, gpa: std.mem.Allocator, io: Io, record: ?*PollWatcher) u64 {
        var hasher = std.hash.Wyhash.init(0);
        var newest: i96 = std.math.minInt(i96);
        for (self.dirs) |dir_path| {
            var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch continue;
            defer dir.close(io);
            var walker = dir.walk(gpa) catch continue;
            defer walker.deinit();
            while (walker.next(io) catch null) |entry| {
                if (entry.kind == .directory) {
                    if (skipDir(entry.basename)) walker.leave(io);
                    continue;
                }
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                const st = dir.statFile(io, entry.path, .{}) catch continue;
                hasher.update(dir_path);
                hasher.update(entry.path);
                hasher.update(std.mem.asBytes(&st.size));
                const mtime = st.mtime.nanoseconds;
                hasher.update(std.mem.asBytes(&mtime));
                if (record) |r| if (mtime > newest) {
                    newest = mtime;
                    r.name_len = @min(entry.basename.len, r.name_buf.len);
                    @memcpy(r.name_buf[0..r.name_len], entry.basename[0..r.name_len]);
                };
            }
        }
        return hasher.final();
    }
};

/// Whether the process `pid` (the `zig` that runs `zig build dev`) is gone.
/// macOS: kill(pid, 0). (Linux uses a pidfd; Windows doesn't pass one.)
fn processGone(pid: posix.pid_t) bool {
    posix.kill(pid, @enumFromInt(0)) catch |err| return err == error.ProcessNotFound;
    return false;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    // macOS: no PDEATHSIG; the loop exits when we are re-parented instead.
    const initial_parent: posix.pid_t = if (is_windows) 0 else posix.getppid();

    if (is_linux) {
        // Capture parent pid before setting PDEATHSIG to close the race where the
        // parent already died before prctl is called.
        const initial_ppid = linux.getppid();

        // Ask Linux kernel to send SIGTERM if our parent process/thread dies.
        //
        // Note on PDEATHSIG and Zig build runner worker threads:
        // PDEATHSIG fires when the parent THREAD (not just the process/thread group leader) exits.
        // Zig's build runner (build_runner.zig) runs steps concurrently via Io.Group.async on worker
        // threads (std.Io.Threaded). For a Step.Run (such as dev_runner), the step's make function
        // calls evalGeneric, which spawns the child and then synchronously calls child.wait(io),
        // which blocks in wait4 on POSIX until dev_runner exits.
        // Because the worker thread remains blocked waiting for dev_runner for its entire run,
        // the parent thread does not exit prematurely. Thus, PDEATHSIG will only fire when the
        // worker thread terminates (i.e. when the zig build process terminates).
        const prctl_res = linux.prctl(@intFromEnum(linux.PR.SET_PDEATHSIG), @intFromEnum(posix.SIG.TERM), 0, 0, 0);
        if (linux.errno(prctl_res) != .SUCCESS) {
            std.debug.print("dev_runner: warning: prctl(PR_SET_PDEATHSIG) failed: {d}\n", .{prctl_res});
        }

        // Re-check getppid() against initial_ppid to close the race where the parent
        // died before prctl was registered. If the parent died, getppid() returns the
        // reaper/init PID (different from initial_ppid), so exit immediately.
        if (linux.getppid() != initial_ppid) {
            return 0;
        }

        // Become a child subreaper: any orphaned grandchild processes (spawned e.g. by Vite/npm/node)
        // whose direct parent exits are re-parented to dev_runner rather than init, enabling us to
        // reap them and prevent zombie leakage.
        const subreaper_res = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0);
        if (linux.errno(subreaper_res) != .SUCCESS) {
            // Not fatal (e.g. restricted containers), but keep error surfaced.
            std.debug.print("dev_runner: warning: prctl(PR_SET_CHILD_SUBREAPER) failed: {d}\n", .{subreaper_res});
        }
    }

    // Register SIGINT / SIGTERM handler for clean shutdown of child processes.
    // (Windows: Ctrl-C reaches every process on the console, children included.)
    if (!is_windows) {
        const sa = posix.Sigaction{
            .handler = .{ .handler = onSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
    }

    var zig_exe: ?[]const u8 = null;
    var project_dir: []const u8 = ".";
    var watch_dir: []const u8 = "src";
    var frontend_dir: ?[]const u8 = null;
    var app_bin: ?[]const u8 = null;
    var watch_pid: ?posix.pid_t = null;
    var dev_cmd: std.ArrayList([]const u8) = .empty;
    var app_args: std.ArrayList([]const u8) = .empty;

    var in_dev_cmd = false;
    var in_app_args = false;

    // Portable argv (WTF-16 on Windows, so not `args.vector`).
    const all_args = try init.minimal.args.toSlice(init.arena.allocator());
    for (all_args[1..]) |arg| {
        if (in_dev_cmd) {
            if (std.mem.eql(u8, arg, "--dev-cmd-end")) {
                in_dev_cmd = false;
            } else {
                try dev_cmd.append(gpa, arg);
            }
            continue;
        }
        if (in_app_args) {
            if (std.mem.eql(u8, arg, "--app-args-end")) {
                in_app_args = false;
            } else {
                try app_args.append(gpa, arg);
            }
            continue;
        }

        if (std.mem.eql(u8, arg, "--zig")) {
            // next arg handled below or via index
        } else if (std.mem.startsWith(u8, arg, "--zig=")) {
            zig_exe = arg["--zig=".len..];
        } else if (std.mem.startsWith(u8, arg, "--project-dir=")) {
            project_dir = arg["--project-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--watch-dir=")) {
            watch_dir = arg["--watch-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--frontend-dir=")) {
            frontend_dir = arg["--frontend-dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--watch-pid=")) {
            if (is_windows) continue; // not passed on Windows
            watch_pid = std.fmt.parseInt(posix.pid_t, arg["--watch-pid=".len..], 10) catch {
                std.debug.print("dev_runner: error: invalid {s}\n", .{arg});
                return 1;
            };
        } else if (std.mem.startsWith(u8, arg, "--app-bin=")) {
            app_bin = arg["--app-bin=".len..];
        } else if (std.mem.eql(u8, arg, "--dev-cmd")) {
            in_dev_cmd = true;
        } else if (std.mem.eql(u8, arg, "--app-args")) {
            in_app_args = true;
        }
    }

    const bin_path = app_bin orelse {
        std.debug.print("dev_runner: error: --app-bin required\n", .{});
        return 1;
    };
    const zig = zig_exe orelse "zig";

    // `zig build dev` runs us from the build runner, a child of `zig`. A
    // SIGTERM/SIGKILL to `zig` alone doesn't reach the build runner, so
    // PR_SET_PDEATHSIG above never fires: watch `zig` through a pidfd, which
    // becomes readable when it exits (build.zig passes its pid). Other POSIX
    // systems poll it with kill(pid, 0) in the loop below.
    const watch_fd: ?i32 = if (!is_linux) null else if (watch_pid) |pid| blk: {
        const rc = linux.pidfd_open(pid, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => break :blk @intCast(rc),
            .SRCH => return 0, // zig is already gone
            else => |e| {
                std.debug.print("dev_runner: error: pidfd_open({d}): {s}\n", .{ pid, @tagName(e) });
                return 1;
            },
        }
    } else null;
    defer if (watch_fd) |fd| {
        _ = linux.close(fd);
    };

    // Set ORIEL_DEV_EXTERNAL=1 so the app knows Vite is managed by us
    try init.environ_map.put("ORIEL_DEV_EXTERNAL", "1");
    // The app exits when dev_runner is gone: on Linux through PR_SET_PDEATHSIG
    // plus a getppid() check against this pid, on macOS by watching this pid.
    var pid_buf: [24]u8 = undefined;
    try init.environ_map.put("ORIEL_DEV_RUNNER_PID", try std.fmt.bufPrint(&pid_buf, "{d}", .{getPid()}));

    // Start frontend dev server if specified.
    //
    // Note on pre-exec hooks in Zig 0.16 std.process.spawn:
    // std.process.SpawnOptions does not provide a pre-exec callback (such as GSubprocessLauncher's
    // child_setup). Therefore, dev_runner cannot directly execute prctl(PR_SET_PDEATHSIG) inside
    // arbitrary external binaries (like Vite / npm / node) before exec.
    // Instead:
    // 1) dev_runner spawns the dev command in a separate process group (.pgid = 0), making
    //    the child a group leader.
    // 2) On shutdown or receipt of SIGTERM/SIGINT, dev_runner sends SIGTERM to the entire group
    //    via kill(-pgid, SIGTERM), followed by SIGKILL escalation if processes remain alive.
    // 3) dev_runner has PDEATHSIG set from its parent (zig build dev), so any abrupt termination
    //    of the parent causes dev_runner to receive SIGTERM and clean up the child group.
    if (dev_cmd.items.len > 0 and frontend_dir != null) {
        std.debug.print("\x1b[36m[oriel dev]\x1b[0m Starting frontend dev server: {s}...\n", .{dev_cmd.items[0]});
        global_dev_child = try spawnInGroup(io, dev_cmd.items, frontend_dir.?, init.environ_map);
    }
    defer cleanupChildren(io);

    // Linux: inotify. Elsewhere: poll modification times.
    const inotify_fd: i32 = if (!is_linux) -1 else blk: {
        const res = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(res) != .SUCCESS) {
            std.debug.print("dev_runner: inotify_init1 failed\n", .{});
            return 1;
        }
        break :blk @intCast(res);
    };
    defer if (is_linux) {
        _ = linux.close(inotify_fd);
    };
    if (is_linux) {
        try addWatchesRecursively(gpa, io, inotify_fd, watch_dir);
        try addWatchesRecursively(gpa, io, inotify_fd, project_dir);
    }
    const watched = [_][]const u8{ watch_dir, project_dir };
    var poller: ?PollWatcher = if (is_linux) null else PollWatcher.init(gpa, io, &watched);

    // Initial app launch: start in its own process group (.pgid = 0) so helper processes
    // are cleanly tracked and killed when reloading or exiting.
    std.debug.print("\x1b[36m[oriel dev]\x1b[0m Launching application: {s}\n", .{bin_path});
    var full_app_argv: std.ArrayList([]const u8) = .empty;
    try full_app_argv.append(gpa, bin_path);
    try full_app_argv.appendSlice(gpa, app_args.items);

    global_app_child = try spawnInGroup(io, full_app_argv.items, project_dir, init.environ_map);

    std.debug.print("\x1b[36m[oriel dev]\x1b[0m Watching for changes in {s}...\n", .{watch_dir});

    var event_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

    while (!global_should_exit.load(.acquire)) {
        var changed_name: []const u8 = "";
        var has_zig_change = false;

        if (is_linux) {
            // Poll inotify (and the watched `zig` pidfd; fd -1 is ignored by
            // poll) with a 200ms timeout.
            var pfd = [_]posix.pollfd{
                .{ .fd = inotify_fd, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = watch_fd orelse -1, .events = posix.POLL.IN, .revents = 0 },
            };
            _ = posix.poll(&pfd, 200) catch 0;

            if (global_should_exit.load(.acquire)) break;
            if (pfd[1].revents != 0) {
                std.debug.print("\x1b[36m[oriel dev]\x1b[0m zig exited. Stopping.\n", .{});
                break;
            }
        } else {
            sleepMs(io, 300);
            if (global_should_exit.load(.acquire)) break;
            if (!is_windows) {
                if (watch_pid) |pid| if (processGone(pid)) {
                    std.debug.print("\x1b[36m[oriel dev]\x1b[0m zig exited. Stopping.\n", .{});
                    break;
                };
                if (posix.getppid() != initial_parent) break; // our parent died
            }
        }

        // Check if app child has exited
        if (global_app_child) |*ac| {
            const app_id = ac.id; // cleared by childExited
            if (childExited(io, ac)) |exit_code| {
                // Its helpers (same process group; pgid == its pid) go too.
                if (!is_windows) if (app_id) |pgid| killProcessGroup(io, pgid, null);
                global_app_child = null;
                if (exit_code == 0) {
                    std.debug.print("\x1b[36m[oriel dev]\x1b[0m App closed. Exiting dev mode.\n", .{});
                    return 0;
                } else {
                    std.debug.print("\x1b[33m[oriel dev]\x1b[0m App exited with code {d}. Waiting for changes to restart...\n", .{exit_code});
                }
            }
        }

        if (is_linux) {
            // Check if there are inotify events
            const rc = linux.read(inotify_fd, &event_buf, event_buf.len);
            if (linux.errno(rc) != .SUCCESS or rc == 0) continue;

            var off: usize = 0;
            while (off < rc) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(event_buf[off..].ptr));
                if (ev.getName()) |name_z| {
                    const name = std.mem.sliceTo(name_z, 0);
                    if (std.mem.endsWith(u8, name, ".zig")) {
                        has_zig_change = true;
                        changed_name = name;
                    }
                }
                off += @sizeOf(linux.inotify_event) + ev.len;
            }
        } else if (poller.?.changed(gpa, io)) {
            has_zig_change = true;
            changed_name = poller.?.changedName();
        }

        if (!has_zig_change) continue;

        // Debounce: sleep 100ms and drain any remaining events
        sleepMs(io, 100);
        if (global_should_exit.load(.acquire)) break;
        if (is_linux) {
            _ = linux.read(inotify_fd, &event_buf, event_buf.len);
        } else {
            _ = poller.?.changed(gpa, io); // absorb writes that landed during the debounce
        }

        std.debug.print("\x1b[36m[oriel dev]\x1b[0m Change detected ({s}). Recompiling...\n", .{changed_name});

        // Kill currently running app and its entire process group
        if (global_app_child) |*ac| {
            stopChild(io, ac);
            global_app_child = null;
        }

        if (global_should_exit.load(.acquire)) break;

        // Run rebuild: zig build build-dev
        const build_argv = [_][]const u8{ zig, "build", "build-dev" };
        var build_child = std.process.spawn(io, .{
            .argv = &build_argv,
            .cwd = .{ .path = project_dir },
            .environ_map = init.environ_map,
        }) catch |err| {
            std.debug.print("\x1b[31m[oriel dev]\x1b[0m Failed to spawn rebuild: {s}\n", .{@errorName(err)});
            continue;
        };

        const term = build_child.wait(io) catch |err| {
            std.debug.print("\x1b[31m[oriel dev]\x1b[0m Rebuild wait error: {s}\n", .{@errorName(err)});
            continue;
        };

        if (global_should_exit.load(.acquire)) break;

        switch (term) {
            .exited => |code| {
                if (code == 0) {
                    std.debug.print("\x1b[32m[oriel dev]\x1b[0m Rebuilt successfully. Restarting app...\n", .{});
                    global_app_child = spawnInGroup(io, full_app_argv.items, project_dir, init.environ_map) catch |err| blk: {
                        std.debug.print("\x1b[31m[oriel dev]\x1b[0m Failed to restart app: {s}\n", .{@errorName(err)});
                        break :blk null;
                    };
                } else {
                    std.debug.print("\x1b[31m[oriel dev]\x1b[0m Rebuild failed with code {d}. Waiting for code changes...\n", .{code});
                }
            },
            else => {
                std.debug.print("\x1b[31m[oriel dev]\x1b[0m Rebuild terminated abnormally.\n", .{});
            },
        }
    }

    return 0;
}

fn cleanupChildren(io: Io) void {
    if (global_app_child) |*ac| {
        stopChild(io, ac);
        global_app_child = null;
    }
    if (global_dev_child) |*dc| {
        if (dc.id != null) std.debug.print("\x1b[36m[oriel dev]\x1b[0m Stopping frontend dev server...\n", .{});
        stopChild(io, dc);
        global_dev_child = null;
    }
}

fn addWatchesRecursively(gpa: std.mem.Allocator, io: Io, inotify_fd: i32, dir_path: []const u8) !void {
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    // Watch dir itself
    const root_z = try gpa.dupeZ(u8, dir_path);
    defer gpa.free(root_z);
    _ = linux.inotify_add_watch(inotify_fd, root_z.ptr, linux.IN.CREATE | linux.IN.MODIFY | linux.IN.DELETE | linux.IN.MOVED_TO);

    var walker = dir.walk(gpa) catch return;
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind == .directory) {
            // Ignore hidden and build directories
            if (skipDir(entry.basename)) continue;
            const full = try std.fs.path.join(gpa, &.{ dir_path, entry.path });
            defer gpa.free(full);
            const full_z = try gpa.dupeZ(u8, full);
            defer gpa.free(full_z);
            _ = linux.inotify_add_watch(inotify_fd, full_z.ptr, linux.IN.CREATE | linux.IN.MODIFY | linux.IN.DELETE | linux.IN.MOVED_TO);
        }
    }
}

test {
    std.testing.refAllDecls(@This());
}

test "isProcessGroupAlive invalid pgid" {
    if (is_windows) return error.SkipZigTest;
    try std.testing.expect(!isProcessGroupAlive(0));
    try std.testing.expect(!isProcessGroupAlive(-1));
}

test "PollWatcher sees a .zig change and ignores other files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "src/sub");
    try tmp.dir.createDirPath(io, "src/zig-out");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "a" });
    const src = try tmp.dir.realPathFileAlloc(io, "src", gpa);
    defer gpa.free(src);

    const dirs = [_][]const u8{src};
    var w = PollWatcher.init(gpa, io, &dirs);
    try std.testing.expect(!w.changed(gpa, io));

    try tmp.dir.writeFile(io, .{ .sub_path = "src/notes.txt", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "src/zig-out/gen.zig", .data = "x" });
    try std.testing.expect(!w.changed(gpa, io));

    try tmp.dir.writeFile(io, .{ .sub_path = "src/sub/new.zig", .data = "b" });
    try std.testing.expect(w.changed(gpa, io));
    try std.testing.expectEqualStrings("new.zig", w.changedName());
    try std.testing.expect(!w.changed(gpa, io));

    try tmp.dir.writeFile(io, .{ .sub_path = "src/main.zig", .data = "longer" }); // size changes too
    try std.testing.expect(w.changed(gpa, io));
}
