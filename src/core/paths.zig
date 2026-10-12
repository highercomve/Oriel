//! The app's own directories on every platform (always built, no flag).
//! The one place Oriel and apps get them from: the store keeps its files
//! in `appConfig` (on Android in an `<app id>` folder inside it, where
//! existing apps' settings already are).
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
//! `appConfig(gpa, .{ .name = "MyApp" })`: settings (the store's files):
//! - Linux: `$XDG_CONFIG_HOME/<name>` (`~/.config/<name>`).
//! - Windows: `%APPDATA%\<name>` (roams with the profile).
//! - macOS, iOS, Android: the same folder as `appData`.
//!
//! `appExternal(gpa, .{ .name = "MyApp" })`: large files the user (and
//! `adb`) can reach, such as downloaded models:
//! - Android: the app-specific external storage
//!   (`Context.getExternalFilesDir(null)`,
//!   `/storage/emulated/0/Android/data/<package>/files`), or the files dir
//!   when there is none. Removed with the app.
//! - Everywhere else: the same folder as `appData`.

const std = @import("std");
const target = @import("target.zig");

const Kind = @import("paths/kind.zig").Kind;

pub const Options = struct {
    /// The app's folder name off Android ("GhostPantry", or the app id
    /// "com.example.App"): no path separators, `..`, `:` or control
    /// characters (error.InvalidAppId, error.EmptyAppId). Checked on
    /// Android too, where it isn't used, so a bad name fails everywhere.
    name: []const u8,
};

const NameError = error{ EmptyAppId, InvalidAppId };

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

/// The app's settings directory (see the top of this file), created if
/// missing. Caller frees.
pub fn appConfig(gpa: std.mem.Allocator, options: Options) ![]const u8 {
    return appDir(gpa, .config, options);
}

/// The directory for large files the user can reach (see the top of this
/// file), created if missing. Caller frees.
pub fn appExternal(gpa: std.mem.Allocator, options: Options) ![]const u8 {
    return appDir(gpa, .external, options);
}

fn appDir(gpa: std.mem.Allocator, kind: Kind, options: Options) ![]const u8 {
    try validateName(options.name);
    switch (target.os) {
        .android => {
            const android = @import("../platform/android/paths.zig");
            return ownedDir(gpa, switch (kind) {
                .data, .config => android.filesDir(),
                .cache => android.cacheDir(),
                .external => android.externalFilesDir(),
            });
        },
        .linux => return @import("paths/linux.zig").appDir(gpa, kind, options.name),
        .windows => return @import("paths/windows.zig").appDir(gpa, kind, options.name),
        .macos, .ios => return @import("paths/apple.zig").appDir(gpa, kind, options.name),
        .other => @compileError("oriel.paths is not supported on " ++ target.name),
    }
}

/// A folder name can't leave its parent: no path separators, traversal
/// (`..`), colons (Windows drive letters and streams), NUL or control
/// characters.
fn validateName(name: []const u8) NameError!void {
    if (name.len == 0) return error.EmptyAppId;
    if (std.mem.indexOfAny(u8, name, "/\\:") != null) return error.InvalidAppId;
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidAppId;
    for (name) |c| {
        if (c < 0x20 or c == 0x7F) return error.InvalidAppId;
    }
}

/// A copy of `base`, created if missing (Android: the runtime's directory
/// itself, no subfolder).
fn ownedDir(gpa: std.mem.Allocator, base: ?[]const u8) ![]const u8 {
    const root = base orelse return error.AppNotRunning;
    if (root.len == 0) return error.AppNotRunning;
    const path = try gpa.dupe(u8, root);
    errdefer gpa.free(path);
    if (comptime target.os != .windows) try @import("paths/posix.zig").makePath(gpa, path);
    return path;
}

test validateName {
    try validateName("com.example.App");
    try validateName("dev.oriel.demo");
    try validateName("my-app_1.0");
    try validateName("singleword");

    try std.testing.expectError(error.EmptyAppId, validateName(""));
    const bad = [_][]const u8{ "foo/bar", "foo\\bar", "/root", "..", "../foo", "foo..bar", "C:app", "app:stream", "foo\x00bar", "foo\nbar", "foo\tbar", "a\x7f" };
    for (bad) |name| try std.testing.expectError(error.InvalidAppId, validateName(name));
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

test "names are checked on every call" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.InvalidAppId, appData(gpa, .{ .name = "../evil" }));
    try std.testing.expectError(error.InvalidAppId, appCache(gpa, .{ .name = "a/b" }));
    try std.testing.expectError(error.InvalidAppId, appConfig(gpa, .{ .name = "a:b" }));
    try std.testing.expectError(error.EmptyAppId, appExternal(gpa, .{ .name = "" }));
}

test "off Android: a folder named after the app per kind" {
    if (comptime target.os == .android or target.os == .other) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const name = "dev.oriel.PathsTest";
    const data = try appData(gpa, .{ .name = name });
    defer gpa.free(data);
    const cache = try appCache(gpa, .{ .name = name });
    defer gpa.free(cache);
    const config = try appConfig(gpa, .{ .name = name });
    defer gpa.free(config);
    const external = try appExternal(gpa, .{ .name = name });
    defer gpa.free(external);
    try std.testing.expect(std.mem.indexOf(u8, data, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, cache, name) != null);
    try std.testing.expect(std.mem.indexOf(u8, config, name) != null);
    try std.testing.expect(!std.mem.eql(u8, data, cache));
    try std.testing.expectEqualStrings(data, external);
    if (comptime target.os == .linux) {
        try std.testing.expect(std.mem.endsWith(u8, data, "/" ++ name));
        try std.testing.expect(std.mem.endsWith(u8, cache, "/" ++ name));
        try std.testing.expect(std.mem.endsWith(u8, config, "/" ++ name));
        try std.testing.expect(!std.mem.eql(u8, data, config));
    }
    std.Io.Dir.deleteDirAbsolute(std.testing.io, data) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, cache) catch {};
    std.Io.Dir.deleteDirAbsolute(std.testing.io, config) catch {};
}

test {
    switch (target.os) {
        .macos, .ios => _ = @import("paths/apple.zig"),
        else => {},
    }
}
