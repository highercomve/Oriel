//! The app's own directories on every platform (always built, no flag).
//!
//! `appData(gpa, .{ .name = "MyApp" })`: where the app keeps what it must
//! not lose (databases, downloaded models, settings files). Private to the
//! app, kept across updates, removed with the app on phones:
//! - Android: the app's files dir (`Context.getFilesDir()`, e.g.
//!   `/data/user/0/<package>/files`) itself. The sandbox is already per app,
//!   so `name` adds no folder.
//! - iOS: `<container>/Library/Application Support/<name>`.
//! - macOS: `~/Library/Application Support/<name>`.
//! - Linux: `$XDG_DATA_HOME/<name>` (`~/.local/share/<name>`).
//! - Windows: `%LOCALAPPDATA%\<name>`: machine-local, since databases and
//!   models shouldn't roam with the profile.
//!
//! `appCache(gpa, .{ .name = "MyApp" })`: what can be fetched or rebuilt
//! again; the system may clear it (phones, low disk):
//! - Android: the app's cache dir (`Context.getCacheDir()`) itself.
//! - iOS and macOS: `Library/Caches/<name>`.
//! - Linux: `$XDG_CACHE_HOME/<name>` (`~/.cache/<name>`).
//! - Windows: `%LOCALAPPDATA%\<name>\cache`.
//!
//! Off Android these are exactly `oriel.store.dataDir` and `cacheDir`
//! (the same folders, so an app can move between them freely); on Android
//! the store keeps `<files dir>/<app id>` (and `<cache dir>/<app id>`),
//! which existing apps' data lives in, so it can't change.

const std = @import("std");
const target = @import("target.zig");
const common = @import("../modules/store/common.zig");

pub const Kind = enum {
    /// Kept until the app is removed: `appData`.
    data,
    /// The system may clear it: `appCache`.
    cache,
};

pub const Options = struct {
    /// The app's folder name off Android ("GhostPantry", or the app id
    /// "com.example.App"): no path separators, `..`, `:` or control
    /// characters (error.InvalidAppId, error.EmptyAppId). Checked on
    /// Android too, where it isn't used, so a bad name fails everywhere.
    name: []const u8,
};

/// The app's private data directory (see the top of this file), created if
/// missing. Caller frees. error.AppNotRunning on Android before the runtime
/// started (it hands the directories over before `main`).
pub fn appData(gpa: std.mem.Allocator, options: Options) ![]const u8 {
    return appDir(gpa, .data, options);
}

/// The app's private cache directory (see the top of this file), created
/// if missing. Caller frees.
pub fn appCache(gpa: std.mem.Allocator, options: Options) ![]const u8 {
    return appDir(gpa, .cache, options);
}

/// `appData` or `appCache`.
pub fn appDir(gpa: std.mem.Allocator, kind: Kind, options: Options) ![]const u8 {
    try common.validateAppId(options.name);
    switch (target.os) {
        .android => {
            const android = @import("../platform/android/paths.zig");
            return ownedDir(gpa, switch (kind) {
                .data => android.filesDir(),
                .cache => android.cacheDir(),
            });
        },
        .linux, .macos, .ios, .windows => {
            const store = switch (target.os) {
                .linux => @import("../modules/store/linux.zig"),
                .windows => @import("../modules/store/windows.zig"),
                else => @import("../modules/store/macos.zig"),
            };
            return switch (kind) {
                .data => store.dataDir(gpa, options.name),
                .cache => store.cacheDir(gpa, options.name),
            };
        },
        .other => @compileError("oriel.paths is not supported on " ++ target.name),
    }
}

/// A copy of `base`, created if missing (Android: the runtime's directory
/// itself, no subfolder).
fn ownedDir(gpa: std.mem.Allocator, base: ?[]const u8) ![]const u8 {
    const root = base orelse return error.AppNotRunning;
    if (root.len == 0) return error.AppNotRunning;
    const path = try gpa.dupe(u8, root);
    errdefer gpa.free(path);
    if (comptime target.os != .windows) try @import("../modules/store/posix.zig").makePath(gpa, path);
    return path;
}

test "Android: the runtime's directory itself, no subfolder" {
    if (comptime target.os == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const path = try ownedDir(gpa, ".");
    defer gpa.free(path);
    try std.testing.expectEqualStrings(".", path);
    try std.testing.expectError(error.AppNotRunning, ownedDir(gpa, null));
    try std.testing.expectError(error.AppNotRunning, ownedDir(gpa, ""));
}

test "names are checked like the store's app ids" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidAppId, appData(gpa, .{ .name = "../evil" }));
    try std.testing.expectError(error.InvalidAppId, appCache(gpa, .{ .name = "a/b" }));
    try std.testing.expectError(error.EmptyAppId, appData(gpa, .{ .name = "" }));
}

test "off Android: the store's data and cache directories" {
    if (comptime target.os == .android or target.os == .other) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const name = "dev.oriel.PathsTest";
    const data = try appData(gpa, .{ .name = name });
    defer gpa.free(data);
    const cache = try appCache(gpa, .{ .name = name });
    defer gpa.free(cache);
    try std.testing.expect(std.mem.indexOf(u8, data, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, cache, name) != null);
    try std.testing.expect(!std.mem.eql(u8, data, cache));
    if (comptime target.os == .linux) {
        try std.testing.expect(std.mem.endsWith(u8, data, "/" ++ name));
        try std.testing.expect(std.mem.endsWith(u8, cache, "/" ++ name));
    }
    std.Io.Dir.deleteDirAbsolute(std.testing.io, data) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, cache) catch {};
}
