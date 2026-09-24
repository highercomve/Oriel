//! Windows-specific operations for self-updater backend.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const log = std.log.scoped(.oriel);

pub fn processId() u32 {
    return win32.GetCurrentProcessId();
}

pub fn syncDir(parent_dir: std.Io.Dir) !void {
    _ = parent_dir;
    // No-op: NTFS metadata updates are journaled, and MoveFileExW with
    // MOVEFILE_WRITE_THROUGH forces data to disk before returning.
}

pub fn buildOldPath(allocator: std.mem.Allocator, exe_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.old", .{exe_path});
}

pub fn installFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    parent_dir: std.Io.Dir,
    tmp_name: []const u8,
    target_path: []const u8,
) !void {
    _ = io;
    _ = parent_dir;
    const dir = std.fs.path.dirname(target_path) orelse ".";
    const tmp_path = try std.fs.path.join(gpa, &.{ dir, tmp_name });
    defer gpa.free(tmp_path);

    const tmp_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, tmp_path);
    defer gpa.free(tmp_w);

    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, target_path);
    defer gpa.free(target_w);

    // 1. If target is not the running exe (e.g. test dest override or stopped binary),
    // a plain replace is enough.
    if (win32.MoveFileExW(tmp_w.ptr, target_w.ptr, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH) != win32.FALSE) {
        return;
    }

    // 2. If plain replace fails (e.g. target is the currently executing process image
    // locked against modification), perform the rename-the-running-exe trick:
    // Move target -> target.old (MOVEFILE_REPLACE_EXISTING),
    // then Move tmp -> target (MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH).
    const old_path = try buildOldPath(gpa, target_path);
    defer gpa.free(old_path);
    const old_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, old_path);
    defer gpa.free(old_w);

    if (win32.MoveFileExW(target_w.ptr, old_w.ptr, win32.MOVEFILE_REPLACE_EXISTING) == win32.FALSE) {
        return error.RenameRunningToOldFailed;
    }

    if (win32.MoveFileExW(tmp_w.ptr, target_w.ptr, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH) == win32.FALSE) {
        // Rollback: restore running exe from <target>.old
        if (win32.MoveFileExW(old_w.ptr, target_w.ptr, win32.MOVEFILE_REPLACE_EXISTING) == win32.FALSE) {
            log.err("updater: could not restore {s} from .old ({d})", .{ target_path, win32.GetLastError() });
        }
        return error.RenameTmpToTargetFailed;
    }
}

/// Delete `<exe>.old` left by a previous update. Called from `updater.init`.
/// Failures are only logged: right after a restart the previous process may
/// still be exiting and hold the file open; the next start removes it.
pub fn cleanupStale(io: std.Io, gpa: std.mem.Allocator) void {
    const exe_path = std.process.executablePathAlloc(io, gpa) catch |err| {
        log.warn("updater: can't resolve the executable path to clean up: {s}", .{@errorName(err)});
        return;
    };
    defer gpa.free(exe_path);
    const old_path = buildOldPath(gpa, exe_path) catch return;
    defer gpa.free(old_path);
    const old_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, old_path) catch return;
    defer gpa.free(old_w);

    if (win32.DeleteFileW(old_w.ptr) == win32.FALSE) {
        const err = win32.GetLastError();
        if (err != win32.ERROR_FILE_NOT_FOUND and err != win32.ERROR_PATH_NOT_FOUND) {
            log.warn("updater: could not delete {s} ({d})", .{ old_path, err });
        }
    }
}

pub fn runningAsAppImage(
    _: std.Io,
    _: std.mem.Allocator,
    _: bool,
    _: ?[]const u8,
) !bool {
    return false;
}

pub fn restart(io: std.Io, exe_path: []const u8) !noreturn {
    _ = io;
    const gpa = std.heap.smp_allocator;
    const exe_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, exe_path);
    defer gpa.free(exe_w);

    const raw_cmdline = win32.GetCommandLineW();
    const cmdline_len = std.mem.indexOfSentinel(u16, 0, raw_cmdline);
    const cmdline_copy = try gpa.allocSentinel(u16, cmdline_len, 0);
    defer gpa.free(cmdline_copy);
    @memcpy(cmdline_copy[0..cmdline_len], raw_cmdline[0..cmdline_len]);

    var si: win32.STARTUPINFOW = std.mem.zeroes(win32.STARTUPINFOW);
    si.cb = @sizeOf(win32.STARTUPINFOW);
    var pi: win32.PROCESS_INFORMATION = undefined;

    if (win32.CreateProcessW(exe_w.ptr, cmdline_copy.ptr, null, null, win32.FALSE, 0, null, null, &si, &pi) == win32.FALSE) {
        return error.RestartFailed;
    }
    // We don't wait for the child: nothing to undo if closing our handles fails.
    _ = win32.CloseHandle(pi.hProcess);
    _ = win32.CloseHandle(pi.hThread);

    // Like execve on Linux, the old process ends here without running the
    // app's shutdown path; the new one is already running.
    std.process.exit(0);
}

test "pure windows updater helpers" {
    const allocator = std.testing.allocator;
    const old_path = try buildOldPath(allocator, "C:\\Program Files\\App\\app.exe");
    defer allocator.free(old_path);
    try std.testing.expectEqualStrings("C:\\Program Files\\App\\app.exe.old", old_path);

}

test {
    std.testing.refAllDecls(@This());
}
