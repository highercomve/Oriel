//! macOS application data paths and JSON settings store.
//!
//! Folder mapping (Apple's File System Programming Guide):
//! - `configDir` and `dataDir`: `~/Library/Application Support/<app_id>`
//!   (macOS has no separate config location; preferences plists are not used).
//! - `cacheDir`: `~/Library/Caches/<app_id>`.
//!
//! Files are replaced atomically (`posix.zig`).

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const posix = @import("posix.zig");

const c = std.c;
const makePath = posix.makePath;

/// `$HOME/<rel>/<app_id>`, created if missing. Caller frees.
fn libraryPath(gpa: std.mem.Allocator, rel: []const u8, app_id: []const u8) ![]const u8 {
    const home = c.getenv("HOME") orelse return error.HomeNotSet;
    const base = try std.fs.path.join(gpa, &.{ std.mem.span(home), rel });
    defer gpa.free(base);
    const path = try common.buildAppPath(gpa, base, app_id, null);
    errdefer gpa.free(path);
    try makePath(gpa, path);
    return path;
}

/// Return the application config directory (created if missing):
/// `~/Library/Application Support/<app_id>`. Caller frees.
pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appSupportDir(gpa, app_id);
}

fn appSupportDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return libraryPath(gpa, "Library/Application Support", app_id);
}

/// Return the application data directory (created if missing): the same
/// as `configDir` on macOS. Caller frees.
pub fn dataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appSupportDir(gpa, app_id);
}

/// Return the application cache directory (created if missing):
/// `~/Library/Caches/<app_id>`. Caller frees.
pub fn cacheDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return libraryPath(gpa, "Library/Caches", app_id);
}

pub const Backend = struct {
    pub const Mutex = posix.Mutex;
    pub const readFile = posix.readFile;
    pub const writeFileAtomic = posix.writeFileAtomic;
    pub const configDir = appSupportDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var dir_buf: [64]u8 = undefined;
    const test_path = try std.fmt.bufPrintZ(&dir_buf, "/tmp/oriel_check_store.{d}.json", .{c.getpid()});
    _ = c.unlink(test_path.ptr);
    defer _ = c.unlink(test_path.ptr);

    {
        var w = try Store.openPath(gpa, test_path);
        defer w.deinit();
        try w.set("test_key", "check_value");
    }
    // Reopen: the value must come back from disk.
    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();
    const val = s.getString("test_key") orelse return .{ .module = "store", .ok = false, .detail = "failed to read back stored key" };
    if (!std.mem.eql(u8, val, "check_value")) return .{ .module = "store", .ok = false, .detail = "stored key mismatch" };

    const dir = try dataDir(gpa, "dev.oriel.Check");
    defer gpa.free(dir);
    return .{
        .module = "store",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "JSON store roundtrip through disk ok; data dir {s}", .{dir}),
    };
}

test "Store persists across reopen, atomic writes leave no temp files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "settings.json" });
    defer gpa.free(path);

    var store = try Store.openPath(gpa, path);
    try store.set("name", "oriel");
    try store.set("version", 1);
    try store.set("active", true);
    store.deinit();

    var reopened = try Store.openPath(gpa, path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings("oriel", reopened.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("active").?);

    var it = tmp.dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp.") == null);
        files += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), files);
}

test "dirs live under ~/Library" {
    const gpa = std.testing.allocator;
    const cache = try cacheDir(gpa, "dev.oriel.Test");
    defer gpa.free(cache);
    try std.testing.expect(std.mem.endsWith(u8, cache, "/Library/Caches/dev.oriel.Test"));
    // Created by the call; remove what we made.
    const z = try gpa.dupeZ(u8, cache);
    defer gpa.free(z);
    _ = c.rmdir(z.ptr);
    try std.testing.expectError(error.InvalidAppId, cacheDir(gpa, "../evil"));
}
