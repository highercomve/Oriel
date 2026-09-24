//! Windows application data paths and JSON settings store.
//!
//! Folder mapping (documented design):
//! - `configDir`: `%APPDATA%\<app_id>` (Roaming AppData, FOLDERID_RoamingAppData)
//!   Used for user configuration that roams with user profile across machines.
//! - `dataDir`: `%LOCALAPPDATA%\<app_id>` (Local AppData, FOLDERID_LocalAppData)
//!   Used for application data, databases, and persistent state specific to the local machine.
//! - `cacheDir`: `%LOCALAPPDATA%\<app_id>\cache` (Local AppData, FOLDERID_LocalAppData)
//!   Used for throwaway temporary / cached state.
//!
//! Path resolution:
//! SHGetKnownFolderPath returns a wide string (PWSTR) which is freed with CoTaskMemFree on every path.
//!
//! Atomic replacement:
//! Handled via writing to a temporary sibling file, flushing with FlushFileBuffers,
//! and atomically renaming with MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH).

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

var temp_counter: std.atomic.Value(u32) = .init(1);

fn getKnownPath(gpa: std.mem.Allocator, rfid: *const win32.GUID) ![]const u8 {
    var ppath: ?win32.LPWSTR = null;
    const hr = win32.SHGetKnownFolderPath(rfid, 0, null, &ppath);
    if (hr != win32.S_OK or ppath == null) {
        return error.KnownFolderNotFound;
    }
    defer win32.CoTaskMemFree(ppath);

    const span = std.mem.span(ppath.?);
    return try std.unicode.utf16LeToUtf8Alloc(gpa, span);
}

fn createDirRecursive(gpa: std.mem.Allocator, path_w: [:0]const u16) !void {
    const sub_z = try gpa.allocSentinel(u16, path_w.len, 0);
    defer gpa.free(sub_z);

    var i: usize = 0;
    while (i < path_w.len) : (i += 1) {
        if (path_w[i] == '\\' or path_w[i] == '/') {
            if (i > 0 and path_w[i - 1] == ':') continue; // Skip drive letter root C:\
            @memcpy(sub_z[0..i], path_w[0..i]);
            sub_z[i] = 0;
            if (win32.CreateDirectoryW(sub_z.ptr, null) == win32.FALSE) {
                const err = win32.GetLastError();
                if (err != win32.ERROR_ALREADY_EXISTS) {
                    return error.CreateDirectoryFailed;
                }
            }
        }
    }
    if (win32.CreateDirectoryW(path_w.ptr, null) == win32.FALSE) {
        const err = win32.GetLastError();
        if (err != win32.ERROR_ALREADY_EXISTS) {
            return error.CreateDirectoryFailed;
        }
    }
}

fn getConfigDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = try getKnownPath(gpa, &win32.FOLDERID_RoamingAppData);
    defer gpa.free(base);
    const path = try common.buildAppPath(gpa, base, app_id, null);
    errdefer gpa.free(path);

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);
    try createDirRecursive(gpa, path_w);
    return path;
}

/// Return the application config directory (%APPDATA%\<app_id>), creating it if missing.
pub const configDir = getConfigDir;

/// Return the application data directory (%LOCALAPPDATA%\<app_id>), creating it if missing.
pub fn dataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = try getKnownPath(gpa, &win32.FOLDERID_LocalAppData);
    defer gpa.free(base);
    const path = try common.buildAppPath(gpa, base, app_id, null);
    errdefer gpa.free(path);

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);
    try createDirRecursive(gpa, path_w);
    return path;
}

/// Return the application cache directory (%LOCALAPPDATA%\<app_id>\cache), creating it if missing.
pub fn cacheDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = try getKnownPath(gpa, &win32.FOLDERID_LocalAppData);
    defer gpa.free(base);
    const path = try common.buildAppPath(gpa, base, app_id, "cache");
    errdefer gpa.free(path);

    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);
    try createDirRecursive(gpa, path_w);
    return path;
}

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
        return null;
    }
    defer _ = win32.CloseHandle(hFile);

    var file_size: win32.LARGE_INTEGER = 0;
    if (win32.GetFileSizeEx(hFile, &file_size) == win32.FALSE or file_size < 0 or file_size > 16 * 1024 * 1024) {
        return null;
    }
    if (file_size == 0) {
        return try gpa.alloc(u8, 0);
    }
    const size_usize: usize = @intCast(file_size);
    const buf = try gpa.alloc(u8, size_usize);
    errdefer gpa.free(buf);

    var bytes_read: win32.DWORD = 0;
    if (win32.ReadFile(hFile, buf.ptr, @intCast(size_usize), &bytes_read, null) == win32.FALSE) {
        gpa.free(buf);
        return null;
    }
    if (bytes_read < size_usize) {
        return try gpa.realloc(buf, bytes_read);
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
    pub const configDir = getConfigDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var temp_buf: [win32.MAX_PATH]u16 = undefined;
    const len = win32.GetTempPathW(temp_buf.len, &temp_buf);
    if (len == 0 or len >= temp_buf.len) return error.GetTempPathFailed;

    const temp_u8 = try std.unicode.utf16LeToUtf8Alloc(gpa, temp_buf[0..len]);
    defer gpa.free(temp_u8);

    const test_path = try std.fs.path.join(gpa, &.{ temp_u8, "oriel_check_store.json" });
    defer gpa.free(test_path);

    const test_path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, test_path);
    defer gpa.free(test_path_w);
    _ = win32.DeleteFileW(test_path_w.ptr);
    defer _ = win32.DeleteFileW(test_path_w.ptr);

    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();

    try s.set("test_key", "check_value");
    const val = s.getString("test_key") orelse return .{
        .module = "store",
        .ok = false,
        .detail = "failed to read back stored key",
    };
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
        .detail = "Win32 known folders + JSON store roundtrip ok",
    };
}

test {
    std.testing.refAllDecls(@This());
}
