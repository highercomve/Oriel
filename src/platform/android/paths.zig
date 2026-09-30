//! The app's directories on Android, handed over by the Kotlin runtime
//! (`NativeLib.start`) before the app's `main` runs: `Context.getFilesDir()`,
//! `getCacheDir()` and `getExternalFilesDir(null)`. No JNI here, so logging
//! and the store can use them without the rest of the backend.

const std = @import("std");

var files_buf: [1024]u8 = undefined;
var cache_buf: [1024]u8 = undefined;
var external_buf: [1024]u8 = undefined;
var files_len: usize = 0;
var cache_len: usize = 0;
var external_len: usize = 0;

/// Private app storage (`/data/user/0/<package>/files`); survives updates,
/// removed with the app.
pub fn filesDir() ?[]const u8 {
    return if (files_len == 0) null else files_buf[0..files_len];
}

/// Private cache (`/data/user/0/<package>/cache`); the system may clear it.
pub fn cacheDir() ?[]const u8 {
    return if (cache_len == 0) null else cache_buf[0..cache_len];
}

/// App-specific external storage (`/storage/emulated/0/Android/data/<package>/files`):
/// large files such as downloaded models. Falls back to `filesDir`.
pub fn externalFilesDir() ?[]const u8 {
    return if (external_len == 0) filesDir() else external_buf[0..external_len];
}

fn store(buf: []u8, len: *usize, value: []const u8) void {
    if (value.len > buf.len) {
        len.* = 0;
        return;
    }
    @memcpy(buf[0..value.len], value);
    len.* = value.len;
}

/// Called once by the runtime at start, before the app's `main`.
pub fn set(files: []const u8, cache: []const u8, external: []const u8) void {
    store(&files_buf, &files_len, files);
    store(&cache_buf, &cache_len, cache);
    store(&external_buf, &external_len, external);
}

test "paths" {
    set("/data/user/0/dev.oriel.x/files", "/data/user/0/dev.oriel.x/cache", "");
    try std.testing.expectEqualStrings("/data/user/0/dev.oriel.x/files", filesDir().?);
    try std.testing.expectEqualStrings("/data/user/0/dev.oriel.x/files", externalFilesDir().?);
    try std.testing.expectEqualStrings("/data/user/0/dev.oriel.x/cache", cacheDir().?);
}
