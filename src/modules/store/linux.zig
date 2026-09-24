//! App data paths and persistent settings store (XDG-compliant).
//!
//! Provides standard XDG directory helpers (`configDir`, `dataDir`, `cacheDir`)
//! and a lightweight thread-safe JSON settings store (`Store`, Tauri `plugin-store` equivalent).

const std = @import("std");
const glib = @import("glib");
const common = @import("common.zig");

fn getConfigDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = std.mem.span(glib.getUserConfigDir());
    const path = try common.buildAppPath(gpa, base, app_id, null);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    _ = glib.mkdirWithParents(path_z, 0o755);
    return path;
}

/// Return the application config directory (creates it if missing).
///
/// Follows `$XDG_CONFIG_HOME/<app_id>`, defaulting to `~/.config/<app_id>`.
pub const configDir = getConfigDir;

/// Return the application data directory (creates it if missing).
///
/// Follows `$XDG_DATA_HOME/<app_id>`, defaulting to `~/.local/share/<app_id>`.
pub fn dataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = std.mem.span(glib.getUserDataDir());
    const path = try common.buildAppPath(gpa, base, app_id, null);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    _ = glib.mkdirWithParents(path_z, 0o755);
    return path;
}

/// Return the application cache directory (creates it if missing).
///
/// Follows `$XDG_CACHE_HOME/<app_id>`, defaulting to `~/.cache/<app_id>`.
pub fn cacheDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    const base = std.mem.span(glib.getUserCacheDir());
    const path = try common.buildAppPath(gpa, base, app_id, null);
    const path_z = try gpa.dupeZ(u8, path);
    defer gpa.free(path_z);
    _ = glib.mkdirWithParents(path_z, 0o755);
    return path;
}

const LinuxMutex = struct {
    inner: glib.Mutex = undefined,

    pub fn init(self: *LinuxMutex) void {
        self.inner.init();
    }

    pub fn deinit(self: *LinuxMutex) void {
        self.inner.clear();
    }

    pub fn lock(self: *LinuxMutex) void {
        self.inner.lock();
    }

    pub fn unlock(self: *LinuxMutex) void {
        self.inner.unlock();
    }
};

fn linuxReadFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    var file_bytes: [*]u8 = undefined;
    var file_len: usize = 0;
    var err: ?*glib.Error = null;

    if (glib.fileGetContents(path, &file_bytes, &file_len, &err) != 0) {
        defer glib.free(file_bytes);
        return try gpa.dupe(u8, file_bytes[0..file_len]);
    } else {
        if (err) |e| e.free();
        return null;
    }
}

fn linuxWriteFileAtomic(path: [:0]const u8, bytes: []const u8) !void {
    var err: ?*glib.Error = null;
    if (glib.fileSetContents(path, bytes.ptr, @intCast(bytes.len), &err) == 0) {
        if (err) |e| {
            std.log.err("failed to save store to {s}: {s}", .{ path, e.f_message orelse "unknown error" });
            e.free();
        }
        return error.SaveFailed;
    }
}

pub const Backend = struct {
    pub const Mutex = LinuxMutex;
    pub const readFile = linuxReadFile;
    pub const writeFileAtomic = linuxWriteFileAtomic;
    pub const configDir = getConfigDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: anytype) !@import("../../oriel.zig").Check {
    const test_path = "/tmp/oriel_check_store.json";
    _ = glib.unlink(test_path);
    defer _ = glib.unlink(test_path);

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
        .detail = "XDG dirs + JSON store roundtrip ok",
    };
}

test "Store operations and persistence" {
    const gpa = std.testing.allocator;
    const test_path = "/tmp/oriel_test_store.json";

    // Clean up before test
    _ = glib.unlink(test_path);

    var store = try Store.openPath(gpa, test_path);
    try store.set("name", "oriel");
    try store.set("version", 1);
    try store.set("active", true);
    try store.set("pi", 3.14);

    try std.testing.expectEqualStrings("oriel", store.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), store.getInt("version", i64).?);
    try std.testing.expectEqual(true, store.getBool("active").?);
    try std.testing.expect(store.has("pi"));

    store.deinit();

    // Reopen and verify persisted values
    var reopened = try Store.openPath(gpa, test_path);
    defer {
        reopened.deinit();
        _ = glib.unlink(test_path);
    }

    try std.testing.expectEqualStrings("oriel", reopened.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("active").?);

    _ = reopened.delete("name");
    try std.testing.expect(!reopened.has("name"));
}
