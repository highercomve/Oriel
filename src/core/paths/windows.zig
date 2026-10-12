//! oriel.paths on Windows (known folders):
//! - data: `%LOCALAPPDATA%\<name>` (FOLDERID_LocalAppData): machine-local,
//!   since databases and models shouldn't roam with the profile;
//! - cache: `%LOCALAPPDATA%\<name>\cache`;
//! - config: `%APPDATA%\<name>` (FOLDERID_RoamingAppData): settings that
//!   roam with the user's profile.
//!
//! SHGetKnownFolderPath's string is freed with CoTaskMemFree.

const std = @import("std");
const win32 = @import("../../platform/windows/win32.zig");
const Kind = @import("kind.zig").Kind;

/// The folder for `kind`, created if missing. Caller frees.
pub fn appDir(gpa: std.mem.Allocator, kind: Kind, name: []const u8) ![]const u8 {
    const base = try knownPath(gpa, switch (kind) {
        .data, .cache, .external => &win32.FOLDERID_LocalAppData,
        .config => &win32.FOLDERID_RoamingAppData,
    });
    defer gpa.free(base);
    const path = switch (kind) {
        .cache => try std.fs.path.join(gpa, &.{ base, name, "cache" }),
        else => try std.fs.path.join(gpa, &.{ base, name }),
    };
    errdefer gpa.free(path);
    const path_w = try std.unicode.utf8ToUtf16LeAllocZ(gpa, path);
    defer gpa.free(path_w);
    try createDirRecursive(gpa, path_w);
    return path;
}

fn knownPath(gpa: std.mem.Allocator, rfid: *const win32.GUID) ![]const u8 {
    var ppath: ?win32.LPWSTR = null;
    const hr = win32.SHGetKnownFolderPath(rfid, 0, null, &ppath);
    if (hr != win32.S_OK or ppath == null) {
        return error.KnownFolderNotFound;
    }
    defer win32.CoTaskMemFree(ppath);
    return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(ppath.?));
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
                if (win32.GetLastError() != win32.ERROR_ALREADY_EXISTS) return error.CreateDirectoryFailed;
            }
        }
    }
    if (win32.CreateDirectoryW(path_w.ptr, null) == win32.FALSE) {
        if (win32.GetLastError() != win32.ERROR_ALREADY_EXISTS) return error.CreateDirectoryFailed;
    }
}
