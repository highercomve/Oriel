//! Updater backend for Android, where the store updates the app:
//! checking for a release still works (`checkForUpdate`, so an app can
//! say a new version is out), installing one fails with
//! `error.Unsupported`.

const std = @import("std");

pub fn processId() u32 {
    return 0;
}

pub fn syncDir(parent_dir: std.Io.Dir) !void {
    _ = parent_dir;
}

pub fn installFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent_dir: std.Io.Dir,
    tmp_name: []const u8,
    target_path: []const u8,
) !void {
    _ = io;
    _ = gpa;
    _ = parent_dir;
    _ = tmp_name;
    _ = target_path;
    return error.Unsupported;
}

pub fn cleanupStale(_: std.Io, _: std.mem.Allocator) void {}

pub fn runningAsAppImage(_: std.Io, _: std.mem.Allocator, _: bool, _: ?[]const u8) !bool {
    return false;
}

pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    _ = io;
    _ = exe_path;
    return error.Unsupported;
}
