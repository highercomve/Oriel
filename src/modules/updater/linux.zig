//! Linux-specific operations for self-updater backend.

const std = @import("std");
const updater = @import("../../updater_core.zig");

pub fn processId() u32 {
    return @intCast(std.os.linux.getpid());
}

pub fn syncDir(parent_dir: std.Io.Dir) !void {
    switch (std.posix.errno(std.posix.system.fsync(parent_dir.handle))) {
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

pub fn runningAsAppImage(
    io: std.Io,
    gpa: std.mem.Allocator,
    has_appimage: bool,
    appdir: ?[]const u8,
) !bool {
    const dir = appdir orelse return false;
    if (!has_appimage) return false;

    const exe_path = try std.process.executablePathAlloc(io, gpa);
    defer gpa.free(exe_path);
    return updater.isUnderDir(exe_path, dir);
}

pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    const cwd = std.Io.Dir.cwd();
    const cmdline_file = cwd.openFile(io, "/proc/self/cmdline", .{}) catch return error.CannotReadCmdline;
    defer cmdline_file.close(io);

    // Read up to MAX_CMDLINE_LEN + 1 bytes to detect truncation
    var cmdline_buf: [updater.MAX_CMDLINE_LEN + 1]u8 = undefined;
    var reader_buf: [2048]u8 = undefined;
    var stream_reader = cmdline_file.readerStreaming(io, &reader_buf);
    const bytes_read = stream_reader.interface.readSliceShort(&cmdline_buf) catch return error.CannotReadCmdline;
    if (bytes_read == 0) return error.CannotReadCmdline;
    if (bytes_read > updater.MAX_CMDLINE_LEN) return error.CmdlineTooLarge;

    var argv_storage: [updater.MAX_ARGV_COUNT][]const u8 = undefined;
    const argv = try updater.splitCmdline(cmdline_buf[0..bytes_read], exe_path, &argv_storage);

    return std.process.replace(io, .{ .argv = argv });
}

test {
    std.testing.refAllDecls(@This());
}
