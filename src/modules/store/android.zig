//! Android application data paths and JSON settings store.
//!
//! Folder mapping (the app's private storage, given by the Kotlin runtime at
//! start, `platform/android/paths.zig`):
//! - `configDir` and `dataDir`: `<filesDir>/<app_id>`, e.g.
//!   `/data/user/0/<package>/files/<app_id>` (backed up, removed with the app).
//! - `cacheDir`: `<cacheDir>/<app_id>` (the system may clear it).
//! Large files such as models belong in `externalDataDir` instead.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const posix = @import("posix.zig");
const paths = @import("../../platform/android/paths.zig");

/// `<base>/<app_id>`, created if missing. Caller frees.
fn appPath(gpa: std.mem.Allocator, base: ?[]const u8, app_id: []const u8) ![]const u8 {
    const root = base orelse return error.AppNotRunning; // before NativeLib.start
    const path = try common.buildAppPath(gpa, root, app_id, null);
    errdefer gpa.free(path);
    try posix.makePath(gpa, path);
    return path;
}

/// The application config directory (created if missing). Caller frees.
pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appPath(gpa, paths.filesDir(), app_id);
}

/// The application data directory: the same as `configDir`. Caller frees.
pub fn dataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appPath(gpa, paths.filesDir(), app_id);
}

/// The application cache directory (created if missing). Caller frees.
pub fn cacheDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appPath(gpa, paths.cacheDir(), app_id);
}

/// App-specific external storage, for large files (downloaded models):
/// `/storage/emulated/0/Android/data/<package>/files/<app_id>`, else
/// `dataDir`. Android only. Caller frees.
pub fn externalDataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appPath(gpa, paths.externalFilesDir(), app_id);
}

pub const Backend = struct {
    pub const Mutex = posix.Mutex;
    pub const readFile = posix.readFile;
    pub const writeFileAtomic = posix.writeFileAtomic;
    pub const configDir = @This().configDirFn;
    fn configDirFn(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
        return appPath(gpa, paths.filesDir(), app_id);
    }
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const dir = try cacheDir(gpa, "dev.oriel.Check");
    defer gpa.free(dir);
    const test_path = try std.fmt.allocPrintSentinel(gpa, "{s}/check_store.json", .{dir}, 0);
    defer gpa.free(test_path);
    _ = std.c.unlink(test_path.ptr);
    defer _ = std.c.unlink(test_path.ptr);
    {
        var w = try Store.openPath(gpa, test_path);
        defer w.deinit();
        try w.set("test_key", "check_value");
    }
    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();
    const val = s.getString("test_key") orelse return .{ .module = "store", .ok = false, .detail = "failed to read back stored key" };
    if (!std.mem.eql(u8, val, "check_value")) return .{ .module = "store", .ok = false, .detail = "stored key mismatch" };
    const data = try dataDir(gpa, "dev.oriel.Check");
    defer gpa.free(data);
    return .{
        .module = "store",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "JSON store roundtrip through disk ok; data dir {s}", .{data}),
    };
}
