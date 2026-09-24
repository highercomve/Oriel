//! Opening media files strictly inside a root directory (Windows).
//!
//! Windows equivalent of Linux openat2(RESOLVE_BENEATH):
//! 1. Pure lexical validation rejecting `..`, absolute paths, drive letters, `:`, `\`, NUL, and DOS device names.
//! 2. Open beneath root with CreateFileW (FILE_FLAG_BACKUP_SEMANTICS omitted so directories fail to open,
//!    FILE_FLAG_OPEN_REPARSE_POINT added when symlinks are refused).
//! 3. Enforce disk file (GetFileType == FILE_TYPE_DISK and not a directory via GetFileInformationByHandle)
//!    to refuse named pipes without blocking.
//! 4. Canonical path prefix verification with GetFinalPathNameByHandleW to ensure the resolved target
//!    is strictly beneath the root directory on a separator boundary.
//! 5. Under SymlinkPolicy.refuse_all, additionally compare the final target path with the lexical target path
//!    to ensure no intermediate reparse points / directory junctions were traversed.

const std = @import("std");
const win32 = @import("../../../platform/windows/win32.zig");
const common = @import("../common.zig");

pub const SymlinkPolicy = common.SymlinkPolicy;
pub const OpenError = common.OpenError;

pub const Root = win32.HANDLE;

/// A media file opened read-only; caller owns `handle` and must close it.
pub const Opened = struct {
    handle: win32.HANDLE,
    size: u64,

    pub fn close(self: Opened) void {
        _ = win32.CloseHandle(self.handle);
    }

    pub fn toFile(self: Opened) std.Io.File {
        return .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
    }
};

/// Open the root directory as a Win32 directory HANDLE.
/// Requires FILE_FLAG_BACKUP_SEMANTICS to open a directory handle in Win32.
pub fn openRoot(path: []const u8) OpenError!Root {
    const gpa = std.heap.smp_allocator;
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch return error.NotFound;
    defer gpa.free(path_w);

    const handle = win32.CreateFileW(
        path_w.ptr,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE | win32.FILE_SHARE_DELETE,
        null,
        win32.OPEN_EXISTING,
        win32.FILE_FLAG_BACKUP_SEMANTICS,
        null,
    );
    if (handle == win32.INVALID_HANDLE_VALUE) {
        const err = win32.GetLastError();
        return switch (err) {
            win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND => error.NotFound,
            win32.ERROR_ACCESS_DENIED => error.Forbidden,
            else => error.Unexpected,
        };
    }
    errdefer _ = win32.CloseHandle(handle);

    var info: win32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win32.GetFileInformationByHandle(handle, &info) == win32.FALSE) return error.Unexpected;
    if (info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotFound;

    return handle;
}

pub fn closeRoot(root: Root) void {
    _ = win32.CloseHandle(root);
}

/// Open `rel` (relative subpath) beneath `root` directory handle read-only.
/// Enforces lexical bounds, non-directory, non-pipe disk file, and canonical prefix verification.
pub fn openInRoot(root: Root, rel: []const u8, policy: SymlinkPolicy) OpenError!Opened {
    // 1. Security-critical lexical validation
    try common.validateWindowsPath(rel);

    const gpa = std.heap.smp_allocator;

    // 2. Query canonical path of the root directory (heap buffer to avoid stack overflow)
    const root_final_w = gpa.alloc(u16, 32768) catch return error.Unexpected;
    defer gpa.free(root_final_w);

    const root_len = win32.GetFinalPathNameByHandleW(
        root,
        root_final_w.ptr,
        32768,
        win32.FILE_NAME_NORMALIZED | win32.VOLUME_NAME_DOS,
    );
    if (root_len == 0 or root_len >= 32768) return error.Unexpected;
    const root_path_w = root_final_w[0..root_len];

    // 3. Convert relative subpath from UTF-8 to UTF-16, replacing '/' with '\'
    const rel_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, rel) catch return error.NotFound;
    defer gpa.free(rel_w);
    for (rel_w) |*c| {
        if (c.* == '/') c.* = '\\';
    }

    // 4. Construct candidate lexical file path: root_path_w + '\' + rel_w
    const needs_sep = root_path_w.len > 0 and root_path_w[root_path_w.len - 1] != '\\';
    const target_len = root_path_w.len + (if (needs_sep) @as(usize, 1) else 0) + rel_w.len;
    const target_w = gpa.allocSentinel(u16, target_len, 0) catch return error.Unexpected;
    defer gpa.free(target_w);

    @memcpy(target_w[0..root_path_w.len], root_path_w);
    var t_idx = root_path_w.len;
    if (needs_sep) {
        target_w[t_idx] = '\\';
        t_idx += 1;
    }
    @memcpy(target_w[t_idx..target_len], rel_w);

    // 5. Open file without FILE_FLAG_BACKUP_SEMANTICS (so opening directories fails)
    var flags: win32.DWORD = win32.FILE_ATTRIBUTE_NORMAL;
    if (policy == .refuse_all) {
        flags |= win32.FILE_FLAG_OPEN_REPARSE_POINT;
    }

    const hFile = win32.CreateFileW(
        target_w.ptr,
        win32.GENERIC_READ,
        win32.FILE_SHARE_READ,
        null,
        win32.OPEN_EXISTING,
        flags,
        null,
    );
    if (hFile == win32.INVALID_HANDLE_VALUE) {
        const err = win32.GetLastError();
        return switch (err) {
            win32.ERROR_FILE_NOT_FOUND, win32.ERROR_PATH_NOT_FOUND => error.NotFound,
            win32.ERROR_ACCESS_DENIED => error.Forbidden,
            else => error.Unexpected,
        };
    }
    errdefer _ = win32.CloseHandle(hFile);

    // 6. Must be a disk file (refuses pipes, character devices without blocking)
    if (win32.GetFileType(hFile) != win32.FILE_TYPE_DISK) {
        return error.NotAFile;
    }

    // 7. Must be a regular file, not a directory
    var info: win32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (win32.GetFileInformationByHandle(hFile, &info) == win32.FALSE) return error.Unexpected;

    if (info.dwFileAttributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0) {
        return error.NotAFile;
    }

    // If policy refuses all symlinks, refuse reparse points on the final component
    if (policy == .refuse_all and (info.dwFileAttributes & win32.FILE_ATTRIBUTE_REPARSE_POINT != 0)) {
        return error.Forbidden;
    }

    // 8. Verify the opened file's final canonical path
    const file_final_w = gpa.alloc(u16, 32768) catch return error.Unexpected;
    defer gpa.free(file_final_w);

    const file_len = win32.GetFinalPathNameByHandleW(
        hFile,
        file_final_w.ptr,
        32768,
        win32.FILE_NAME_NORMALIZED | win32.VOLUME_NAME_DOS,
    );
    if (file_len == 0 or file_len >= 32768) return error.Unexpected;
    const file_path_w = file_final_w[0..file_len];

    // Must always resolve strictly inside root
    if (!common.isSubpathCaseInsensitive(file_path_w, root_path_w)) {
        return error.Forbidden;
    }

    // Under refuse_all, intermediate junctions/symlinks must also be refused:
    // compare final path with candidate lexical target path. Any difference means
    // an intermediate reparse point / junction was traversed.
    if (policy == .refuse_all) {
        if (!common.isPathLexicallyEqual(file_path_w, target_w[0..target_len])) {
            return error.Forbidden;
        }
    }

    const size = (@as(u64, info.nFileSizeHigh) << 32) | @as(u64, info.nFileSizeLow);
    return Opened{ .handle = hFile, .size = size };
}

test {
    std.testing.refAllDecls(@This());
}
