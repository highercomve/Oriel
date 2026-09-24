//! Dev runner for oriel apps.
//! Runs the frontend dev server (e.g. Vite) and keeps it alive while watching
//! `src/` for Zig file changes, rebuilding the app, and restarting it.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

var global_dev_child: ?std.process.Child = null;
var global_dev_pgid: ?posix.pid_t = null;
var global_app_child: ?std.process.Child = null;
var global_app_pgid: ?posix.pid_t = null;
var global_should_exit: std.atomic.Value(bool) = .init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    global_should_exit.store(true, .release);
}

fn isProcessGroupAlive(pgid: posix.pid_t) bool {
    if (pgid <= 0) return false;
    const rc = linux.syscall2(.kill, @as(usize, @bitCast(@as(isize, -pgid))), 0);
    return linux.errno(rc) != .SRCH;
}

fn reapZombies() void {
    var status: u32 = 0;
    while (true) {
        const res = linux.waitpid(-1, &status, linux.W.NOHANG);
        if (linux.errno(res) != .SUCCESS or res <= 0) break;
    }
}

fn checkChildExit(pid: posix.pid_t) ?u8 {
    var status: u32 = 0;
    const res = linux.waitpid(pid, &status, linux.W.NOHANG);
    if (linux.errno(res) == .SUCCESS and res == pid) {
        if ((status & 0x7f) == 0) {
            return @truncate((status >> 8) & 0xff);
        } else {
            return 1;
        }
    }
    return null;
}

fn waitChildExit(pid: posix.pid_t) void {
    var status: u32 = 0;
    _ = linux.waitpid(pid, &status, 0);
}

fn killProcessGroup(io: Io, pgid: posix.pid_t, direct_pid: ?posix.pid_t) void {
    if (pgid <= 0) return;

    // Send SIGTERM to the entire process group.
    // Using a negative pgid signals every process in that process group.
    const term_rc = linux.kill(-pgid, posix.SIG.TERM);
    if (linux.errno(term_rc) == .SRCH) {
        if (direct_pid) |p| _ = checkChildExit(p);
        reapZombies();
        return;
    }

    if (direct_pid) |p| {
        if (p > 0 and p != pgid) _ = linux.kill(p, posix.SIG.TERM);
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

        const sleep_to: Io.Timeout = .{
            .duration = .{
                .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
                .clock = .awake,
            },
        };
        sleep_to.sleep(io) catch {};
    }

    // Escalate to SIGKILL if processes remain alive
    if (still_alive) {
        _ = linux.kill(-pgid, posix.SIG.KILL);
        if (direct_pid) |p| {
            if (p > 0 and p != pgid) _ = linux.kill(p, posix.SIG.KILL);
        }

        for (0..10) |_| {
            reapZombies();
            if (direct_pid) |p| _ = checkChildExit(p);

            if (!isProcessGroupAlive(pgid)) break;

            const sleep_to: Io.Timeout = .{
                .duration = .{
                    .raw = .{ .nanoseconds = 20 * std.time.ns_per_ms },
                    .clock = .awake,
                },
            };
            sleep_to.sleep(io) catch {};
        }
    }

    if (direct_pid) |p| _ = checkChildExit(p);
    reapZombies();
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

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

    // Register SIGINT / SIGTERM handler for clean shutdown of child processes
    const sa = posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.INT, &sa, null);
    posix.sigaction(posix.SIG.TERM, &sa, null);

    var zig_exe: ?[]const u8 = null;
    var project_dir: []const u8 = ".";
    var watch_dir: []const u8 = "src";
    var frontend_dir: ?[]const u8 = null;
    var app_bin: ?[]const u8 = null;
    var watch_pid: ?linux.pid_t = null;
    var dev_cmd: std.ArrayList([]const u8) = .empty;
    var app_args: std.ArrayList([]const u8) = .empty;

    var in_dev_cmd = false;
    var in_app_args = false;

    for (init.minimal.args.vector[1..]) |arg_z| {
        const arg = std.mem.span(arg_z);
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
            watch_pid = std.fmt.parseInt(linux.pid_t, arg["--watch-pid=".len..], 10) catch {
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
    // becomes readable when it exits (build.zig passes its pid).
    const watch_fd: ?i32 = if (watch_pid) |pid| blk: {
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
    // The app sets PR_SET_PDEATHSIG and compares getppid() with this pid to
    // exit if dev_runner is already gone (src/core/App.zig, `run`).
    var pid_buf: [16]u8 = undefined;
    try init.environ_map.put("ORIEL_DEV_RUNNER_PID", try std.fmt.bufPrint(&pid_buf, "{d}", .{linux.getpid()}));

    // Start frontend dev server if specified.
    //
    // Note on pre-exec hooks in Zig 0.16 std.process.spawn:
    // std.process.SpawnOptions does not provide a pre-exec callback (such as GSubprocessLauncher's
    // child_setup). Therefore, dev_runner cannot directly execute prctl(PR_SET_PDEATHSIG) inside
    // arbitrary external binaries (like Vite / npm / node) before exec.
    // Instead:
    // 1) dev_runner spawns the dev command in a separate process group (.pgid = 0), making
    //    the child a group leader, and tracks global_dev_pgid.
    // 2) On shutdown or receipt of SIGTERM/SIGINT, dev_runner sends SIGTERM to the entire group
    //    via kill(-pgid, SIGTERM), followed by SIGKILL escalation if processes remain alive.
    // 3) dev_runner has PDEATHSIG set from its parent (zig build dev), so any abrupt termination
    //    of the parent causes dev_runner to receive SIGTERM and clean up the child group.
    if (dev_cmd.items.len > 0 and frontend_dir != null) {
        std.debug.print("\x1b[36m[oriel dev]\x1b[0m Starting frontend dev server: {s}...\n", .{dev_cmd.items[0]});
        const child = try std.process.spawn(io, .{
            .argv = dev_cmd.items,
            .cwd = .{ .path = frontend_dir.? },
            .environ_map = init.environ_map,
            .pgid = 0,
        });
        global_dev_child = child;
        global_dev_pgid = child.id;
    }
    defer cleanupChildren(io);

    // Initialize inotify
    const inotify_fd_res = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    if (linux.errno(inotify_fd_res) != .SUCCESS) {
        std.debug.print("dev_runner: inotify_init1 failed\n", .{});
        return 1;
    }
    const inotify_fd: i32 = @intCast(inotify_fd_res);
    defer _ = linux.close(inotify_fd);

    // Add watches recursively
    try addWatchesRecursively(gpa, io, inotify_fd, watch_dir);
    try addWatchesRecursively(gpa, io, inotify_fd, project_dir);

    // Initial app launch: start in its own process group (.pgid = 0) so helper processes
    // are cleanly tracked and killed when reloading or exiting.
    std.debug.print("\x1b[36m[oriel dev]\x1b[0m Launching application: {s}\n", .{bin_path});
    var full_app_argv: std.ArrayList([]const u8) = .empty;
    try full_app_argv.append(gpa, bin_path);
    try full_app_argv.appendSlice(gpa, app_args.items);

    var app_child: ?std.process.Child = try std.process.spawn(io, .{
        .argv = full_app_argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = init.environ_map,
        .pgid = 0,
    });
    global_app_child = app_child;
    global_app_pgid = if (app_child) |ac| ac.id else null;

    std.debug.print("\x1b[36m[oriel dev]\x1b[0m Watching for changes in {s}...\n", .{watch_dir});

    var event_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

    while (!global_should_exit.load(.acquire)) {
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

        // Check if app child has exited
        if (app_child) |*ac| {
            if (ac.id) |pid| {
                if (checkChildExit(pid)) |exit_code| {
                    ac.id = null;
                    if (global_app_pgid) |pgid| {
                        killProcessGroup(io, pgid, null);
                    }
                    global_app_child = null;
                    global_app_pgid = null;
                    if (exit_code == 0) {
                        std.debug.print("\x1b[36m[oriel dev]\x1b[0m App closed. Exiting dev mode.\n", .{});
                        return 0;
                    } else {
                        std.debug.print("\x1b[33m[oriel dev]\x1b[0m App exited with code {d}. Waiting for changes to restart...\n", .{exit_code});
                    }
                }
            }
        }

        // Check if there are inotify events
        const rc = linux.read(inotify_fd, &event_buf, event_buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) continue;

        var off: usize = 0;
        var has_zig_change = false;
        var changed_name: []const u8 = "";

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

        if (!has_zig_change) continue;

        // Debounce: sleep 100ms and drain any remaining events
        const sleep_to: Io.Timeout = .{
            .duration = .{
                .raw = .{ .nanoseconds = 100 * std.time.ns_per_ms },
                .clock = .awake,
            },
        };
        sleep_to.sleep(io) catch {};
        if (global_should_exit.load(.acquire)) break;
        _ = linux.read(inotify_fd, &event_buf, event_buf.len);

        std.debug.print("\x1b[36m[oriel dev]\x1b[0m Change detected ({s}). Recompiling...\n", .{changed_name});

        // Kill currently running app and its entire process group
        if (global_app_pgid) |pgid| {
            const app_pid = if (app_child) |ac| ac.id else null;
            killProcessGroup(io, pgid, app_pid);
            app_child = null;
            global_app_child = null;
            global_app_pgid = null;
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
                    app_child = std.process.spawn(io, .{
                        .argv = full_app_argv.items,
                        .cwd = .{ .path = project_dir },
                        .environ_map = init.environ_map,
                        .pgid = 0,
                    }) catch |err| blk: {
                        std.debug.print("\x1b[31m[oriel dev]\x1b[0m Failed to restart app: {s}\n", .{@errorName(err)});
                        break :blk null;
                    };
                    global_app_child = app_child;
                    global_app_pgid = if (app_child) |ac| ac.id else null;
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
    if (global_app_pgid) |pgid| {
        const app_pid = if (global_app_child) |ac| ac.id else null;
        killProcessGroup(io, pgid, app_pid);
        global_app_child = null;
        global_app_pgid = null;
    } else if (global_app_child) |*ac| {
        if (ac.id) |pid| {
            killProcessGroup(io, pid, pid);
            global_app_child = null;
        }
    }

    if (global_dev_pgid) |pgid| {
        std.debug.print("\x1b[36m[oriel dev]\x1b[0m Stopping frontend dev server...\n", .{});
        const dev_pid = if (global_dev_child) |dc| dc.id else null;
        killProcessGroup(io, pgid, dev_pid);
        global_dev_child = null;
        global_dev_pgid = null;
    } else if (global_dev_child) |*dc| {
        if (dc.id) |pid| {
            std.debug.print("\x1b[36m[oriel dev]\x1b[0m Stopping frontend dev server...\n", .{});
            killProcessGroup(io, pid, pid);
            global_dev_child = null;
        }
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
            if (std.mem.startsWith(u8, entry.basename, ".") or
                std.mem.eql(u8, entry.basename, "node_modules") or
                std.mem.eql(u8, entry.basename, "dist") or
                std.mem.eql(u8, entry.basename, "zig-out") or
                std.mem.eql(u8, entry.basename, "zig-pkg"))
            {
                continue;
            }
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
    try std.testing.expect(!isProcessGroupAlive(0));
    try std.testing.expect(!isProcessGroupAlive(-1));
}

