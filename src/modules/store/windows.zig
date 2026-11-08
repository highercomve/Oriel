//! The settings store on Windows (the folder is `oriel.paths.appConfig`,
//! `%APPDATA%\<app_id>`).
//!
//! Atomic replacement:
//! Handled via writing to a temporary sibling file, flushing with FlushFileBuffers,
//! and atomically renaming with MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH).

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

var temp_counter: std.atomic.Value(u32) = .init(1);

const WindowsMutex = struct {
    inner: win32.SRWLOCK = win32.SRWLOCK_INIT,

    pub fn init(self: *WindowsMutex) void {
        self.* = .{};
    }

    pub fn deinit(_: *WindowsMutex) void {}

    pub fn lock(self: *WindowsMutex) void {
        win32.AcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *WindowsMutex) void {
        win32.ReleaseSRWLockExclusive(&self.inner);
    }
};

// Keep the OS diagnostic at the failing read; callers can leave the store unavailable.
extern "kernel32" fn FormatMessageW(flags: win32.DWORD, source: ?*const anyopaque, code: win32.DWORD, language: win32.DWORD, buffer: [*]u16, size: win32.DWORD, arguments: ?*anyopaque) callconv(.winapi) win32.DWORD;

fn readFailure(path: []const u8, code: win32.DWORD) error{ AccessDenied, OutOfMemory, ReadFailed } {
    if (!@import("builtin").is_test) {
        var message_w: [512]u16 = undefined;
        // FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS.
        const len = FormatMessageW(0x1000 | 0x200, null, code, 0, &message_w, message_w.len, null);
        var message: [1536]u8 = undefined;
        const message_len = std.unicode.utf16LeToUtf8(&message, message_w[0..len]) catch 0;
        std.log.warn("failed to read store {s}: {s} (Windows error {d})", .{
            path, if (message_len == 0) "unknown OS message" else std.mem.trim(u8, message[0..message_len], " \r\n"), code,
        });
    }
    return switch (code) {
        win32.ERROR_ACCESS_DENIED => error.AccessDenied,
        8, 14 => error.OutOfMemory, // ERROR_NOT_ENOUGH_MEMORY, ERROR_OUTOFMEMORY.
        else => error.ReadFailed,
    };
}

fn windowsReadFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);

    const hFile = win32.CreateFileW(
        path_w.ptr,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (hFile == win32.INVALID_HANDLE_VALUE) {
        const code = win32.GetLastError();
        if (code == win32.ERROR_FILE_NOT_FOUND or code == win32.ERROR_PATH_NOT_FOUND) return null;
        return readFailure(path, code);
    }
    defer _ = win32.CloseHandle(hFile);

    var file_size: win32.LARGE_INTEGER = 0;
    if (win32.GetFileSizeEx(hFile, &file_size) == win32.FALSE) return readFailure(path, win32.GetLastError());
    if (file_size < 0) {
        if (!@import("builtin").is_test) std.log.warn("failed to read store {s}: invalid file size {d}", .{ path, file_size });
        return error.InvalidFileSize;
    }
    if (file_size > 16 * 1024 * 1024) {
        if (!@import("builtin").is_test) std.log.warn("failed to read store {s}: file exceeds 16 MiB", .{path});
        return error.FileTooLarge;
    }
    if (file_size == 0) {
        return try gpa.alloc(u8, 0);
    }
    const size_usize: usize = @intCast(file_size);
    const buf = try gpa.alloc(u8, size_usize);
    errdefer gpa.free(buf);

    var bytes_read: win32.DWORD = 0;
    if (win32.ReadFile(hFile, buf.ptr, @intCast(size_usize), &bytes_read, null) == win32.FALSE) {
        return readFailure(path, win32.GetLastError());
    }
    // Never hand a partial snapshot to the parser: saving it could lose keys.
    if (bytes_read != size_usize) {
        if (!@import("builtin").is_test) std.log.warn("failed to read store {s}: short read ({d} of {d} bytes)", .{ path, bytes_read, size_usize });
        return error.UnexpectedEndOfFile;
    }
    return buf;
}

fn windowsWriteFileAtomic(path: [:0]const u8, bytes: []const u8) !void {
    const gpa = std.heap.smp_allocator;
    const pid = win32.GetCurrentProcessId();
    const seq = temp_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.allocPrint(gpa, "{s}.tmp.{d}.{d}", .{ path, pid, seq });
    defer gpa.free(tmp_path);

    const tmp_path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, tmp_path);
    defer gpa.free(tmp_path_w);

    const hFile = win32.CreateFileW(
        tmp_path_w.ptr,
        win32.GENERIC_WRITE,
        0,
        null,
        win32.CREATE_ALWAYS,
        win32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (hFile == win32.INVALID_HANDLE_VALUE) {
        return error.SaveFailed;
    }

    var bytes_written: win32.DWORD = 0;
    const write_ok = win32.WriteFile(hFile, bytes.ptr, @intCast(bytes.len), &bytes_written, null);
    const flush_ok = win32.FlushFileBuffers(hFile);
    _ = win32.CloseHandle(hFile);

    if (write_ok == win32.FALSE or flush_ok == win32.FALSE or bytes_written != bytes.len) {
        _ = win32.DeleteFileW(tmp_path_w.ptr);
        return error.SaveFailed;
    }

    const dest_path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(dest_path_w);

    if (win32.MoveFileExW(tmp_path_w.ptr, dest_path_w.ptr, win32.MOVEFILE_REPLACE_EXISTING | win32.MOVEFILE_WRITE_THROUGH) == win32.FALSE) {
        _ = win32.DeleteFileW(tmp_path_w.ptr);
        return error.SaveFailed;
    }
}

pub const Backend = struct {
    pub const Mutex = WindowsMutex;
    pub const readFile = windowsReadFile;
    pub const writeFileAtomic = windowsWriteFileAtomic;
    pub const configDir = common.configDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var temp_buf: [win32.MAX_PATH]u16 = undefined;
    const len = win32.GetTempPathW(temp_buf.len, &temp_buf);
    if (len == 0 or len >= temp_buf.len) return error.GetTempPathFailed;

    const temp_u8 = try std.unicode.utf16LeToUtf8Alloc(gpa, temp_buf[0..len]);
    defer gpa.free(temp_u8);

    const filename = try std.fmt.allocPrint(gpa, "oriel_check_store.{d}.json", .{win32.GetCurrentProcessId()});
    defer gpa.free(filename);

    const test_path = try std.fs.path.join(gpa, &.{ temp_u8, filename });
    defer gpa.free(test_path);

    const test_path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, test_path);
    defer gpa.free(test_path_w);
    _ = win32.DeleteFileW(test_path_w.ptr);
    defer _ = win32.DeleteFileW(test_path_w.ptr);

    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();

    try s.set("test_key", "check_value");
    const val = (try s.getString(gpa, "test_key")) orelse return .{
        .module = "store",
        .ok = false,
        .detail = "failed to read back stored key",
    };
    defer gpa.free(val);
    if (!std.mem.eql(u8, val, "check_value")) {
        return .{
            .module = "store",
            .ok = false,
            .detail = "stored key mismatch",
        };
    }

    return .{
        .module = "store",
        .ok = true,
        .detail = "JSON store roundtrip ok",
    };
}

test {
    std.testing.refAllDecls(@This());
}
