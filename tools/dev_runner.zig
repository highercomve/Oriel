//! Dev runner for ziguri apps.
//! Runs the frontend dev server (e.g. Vite) and keeps it alive while watching
//! `src/` for Zig file changes, rebuilding the app, and restarting it.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Io = std.Io;

var global_dev_child: ?std.process.Child = null;
var global_app_child: ?std.process.Child = null;
var global_should_exit: bool = false;

fn onSignal(_: posix.SIG) callconv(.c) void {
    global_should_exit = true;
}

fn checkChildExit(pid: posix.pid_t) ?u8 {
    var status: u32 = 0;
    const res = linux.waitpid(pid, &status, 1);
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

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

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
            try app_args.append(gpa, arg);
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

    // Set ZIGURI_DEV_EXTERNAL=1 so the app knows Vite is managed by us
    try init.environ_map.put("ZIGURI_DEV_EXTERNAL", "1");

    // Start frontend dev server if specified
    if (dev_cmd.items.len > 0 and frontend_dir != null) {
        std.debug.print("\x1b[36m[ziguri dev]\x1b[0m Starting frontend dev server: {s}...\n", .{dev_cmd.items[0]});
        const child = try std.process.spawn(io, .{
            .argv = dev_cmd.items,
            .cwd = .{ .path = frontend_dir.? },
            .environ_map = init.environ_map,
        });
        global_dev_child = child;
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

    // Initial app launch
    std.debug.print("\x1b[36m[ziguri dev]\x1b[0m Launching application: {s}\n", .{bin_path});
    var full_app_argv: std.ArrayList([]const u8) = .empty;
    try full_app_argv.append(gpa, bin_path);
    try full_app_argv.appendSlice(gpa, app_args.items);

    var app_child: ?std.process.Child = try std.process.spawn(io, .{
        .argv = full_app_argv.items,
        .cwd = .{ .path = project_dir },
        .environ_map = init.environ_map,
    });
    global_app_child = app_child;

    std.debug.print("\x1b[36m[ziguri dev]\x1b[0m Watching for changes in {s}...\n", .{watch_dir});

    var event_buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;

    while (!global_should_exit) {
        // Poll inotify fd with 200ms timeout
        var pfd = [_]posix.pollfd{.{
            .fd = inotify_fd,
            .events = posix.POLL.IN,
            .revents = 0,
        }};
        _ = posix.poll(&pfd, 200) catch 0;

        if (global_should_exit) break;

        // Check if app child has exited
        if (app_child) |*ac| {
            if (ac.id) |pid| {
                if (checkChildExit(pid)) |exit_code| {
                    ac.id = null;
                    if (exit_code == 0) {
                        std.debug.print("\x1b[36m[ziguri dev]\x1b[0m App closed. Exiting dev mode.\n", .{});
                        return 0;
                    } else {
                        std.debug.print("\x1b[33m[ziguri dev]\x1b[0m App exited with code {d}. Waiting for changes to restart...\n", .{exit_code});
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
        _ = linux.read(inotify_fd, &event_buf, event_buf.len);

        std.debug.print("\x1b[36m[ziguri dev]\x1b[0m Change detected ({s}). Recompiling...\n", .{changed_name});

        // Kill currently running app
        if (app_child) |*ac| {
            if (ac.id) |pid| {
                _ = posix.kill(pid, posix.SIG.TERM) catch {};
                // Wait briefly for app to exit
                var waited: usize = 0;
                while (waited < 10) : (waited += 1) {
                    if (checkChildExit(pid) != null) {
                        ac.id = null;
                        break;
                    }
                    const term_sleep: Io.Timeout = .{
                        .duration = .{
                            .raw = .{ .nanoseconds = 50 * std.time.ns_per_ms },
                            .clock = .awake,
                        },
                    };
                    term_sleep.sleep(io) catch {};
                }
                if (ac.id != null) {
                    _ = posix.kill(pid, posix.SIG.KILL) catch {};
                    waitChildExit(pid);
                    ac.id = null;
                }
            }
        }
        global_app_child = null;

        // Run rebuild: zig build build-dev
        const build_argv = [_][]const u8{ zig, "build", "build-dev" };
        var build_child = std.process.spawn(io, .{
            .argv = &build_argv,
            .cwd = .{ .path = project_dir },
            .environ_map = init.environ_map,
        }) catch |err| {
            std.debug.print("\x1b[31m[ziguri dev]\x1b[0m Failed to spawn rebuild: {s}\n", .{@errorName(err)});
            continue;
        };

        const term = build_child.wait(io) catch |err| {
            std.debug.print("\x1b[31m[ziguri dev]\x1b[0m Rebuild wait error: {s}\n", .{@errorName(err)});
            continue;
        };

        switch (term) {
            .exited => |code| {
                if (code == 0) {
                    std.debug.print("\x1b[32m[ziguri dev]\x1b[0m Rebuilt successfully. Restarting app...\n", .{});
                    app_child = std.process.spawn(io, .{
                        .argv = full_app_argv.items,
                        .cwd = .{ .path = project_dir },
                        .environ_map = init.environ_map,
                    }) catch |err| blk: {
                        std.debug.print("\x1b[31m[ziguri dev]\x1b[0m Failed to restart app: {s}\n", .{@errorName(err)});
                        break :blk null;
                    };
                    global_app_child = app_child;
                } else {
                    std.debug.print("\x1b[31m[ziguri dev]\x1b[0m Rebuild failed with code {d}. Waiting for code changes...\n", .{code});
                }
            },
            else => {
                std.debug.print("\x1b[31m[ziguri dev]\x1b[0m Rebuild terminated abnormally.\n", .{});
            },
        }
    }

    return 0;
}

fn cleanupChildren(io: Io) void {
    if (global_app_child) |*ac| {
        if (ac.id) |pid| {
            _ = posix.kill(pid, posix.SIG.TERM) catch {};
            _ = checkChildExit(pid);
        }
    }
    if (global_dev_child) |*dc| {
        if (dc.id) |pid| {
            std.debug.print("\x1b[36m[ziguri dev]\x1b[0m Stopping frontend dev server...\n", .{});
            _ = posix.kill(pid, posix.SIG.TERM) catch {};
            dc.kill(io);
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
