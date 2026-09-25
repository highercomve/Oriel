//! macOS-specific operations for the self-updater core: replaces a plain
//! executable (the `oriel` CLI). Replacing a signed `.app` bundle is
//! PLAN.md Milestone 7 step 2, so the app-level updater module stays off
//! on macOS.

const std = @import("std");
const updater = @import("../../updater_core.zig");

pub fn processId() u32 {
    return @intCast(std.c.getpid()); // raw Linux syscalls are SIGSYS here
}

pub fn syncDir(parent_dir: std.Io.Dir) !void {
    switch (std.posix.errno(std.c.fsync(parent_dir.handle))) {
        .SUCCESS => {},
        else => return error.DirSyncFailed,
    }
}

pub fn installFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent_dir: std.Io.Dir,
    tmp_name: []const u8,
    target_path: []const u8,
) !void {
    _ = gpa;
    const target_name = std.fs.path.basename(target_path);
    try parent_dir.rename(tmp_name, parent_dir, target_name, io);
}

/// Nothing to clean up: rename(2) replaces the running binary in place.
pub fn cleanupStale(_: std.Io, _: std.mem.Allocator) void {}

/// No AppImages on macOS.
pub fn runningAsAppImage(_: std.Io, _: std.mem.Allocator, _: bool, _: ?[]const u8) !bool {
    return false;
}

// <crt_externs.h>: the process's own argc/argv (no /proc on macOS).
extern "c" fn _NSGetArgc() *c_int;
extern "c" fn _NSGetArgv() *[*][*:0]u8;

pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    const argc: usize = @intCast(_NSGetArgc().*);
    if (argc == 0) return error.CannotReadCmdline;
    if (argc > updater.MAX_ARGV_COUNT) return error.CmdlineTooLarge;
    const raw = _NSGetArgv().*;

    var argv_storage: [updater.MAX_ARGV_COUNT][]const u8 = undefined;
    // argv[0] becomes the new binary's path, like splitCmdline does on Linux.
    argv_storage[0] = exe_path;
    for (1..argc) |i| argv_storage[i] = std.mem.span(raw[i]);
    return std.process.replace(io, .{ .argv = argv_storage[0..argc] });
}

test {
    std.testing.refAllDecls(@This());
}
