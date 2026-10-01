//! The OS family Oriel builds for, with Android split out of Linux.
//!
//! Zig treats Android as Linux (`os.tag == .linux`, `abi == .android`), so a
//! plain `switch (builtin.os.tag)` would quietly pick the GTK, PulseAudio or
//! X11 backend for Android. Backend selectors switch on `os` instead, which
//! has its own `.android` case.

const builtin = @import("builtin");

/// Android (bionic, the NDK): `aarch64-linux-android`, `x86_64-linux-android`.
pub const is_android = builtin.abi.isAndroid();
/// Desktop Linux: GTK4 + WebKitGTK.
pub const is_desktop_linux = builtin.os.tag == .linux and !is_android;

/// iOS and iPadOS (UIKit, WKWebView): `aarch64-ios`, `aarch64-ios-simulator`.
pub const is_ios = builtin.os.tag == .ios;

pub const Os = enum { linux, android, windows, macos, ios, other };

pub const os: Os = if (is_android) .android else switch (builtin.os.tag) {
    .linux => .linux,
    .windows => .windows,
    .macos => .macos,
    .ios => .ios,
    else => .other,
};

/// For error messages: "linux", "android", "windows", "macos", "ios" or the Zig OS tag.
pub const name: []const u8 = if (os == .other) @tagName(builtin.os.tag) else @tagName(os);

/// `window.oriel.platform` in every page: `{ os, arch }`, e.g.
/// `{ os: "android", arch: "aarch64" }`. `os` is `name`; `arch` is Zig's CPU
/// architecture name ("x86_64", "aarch64").
pub const platform_js = "Object.freeze({ os: \"" ++ name ++ "\", arch: \"" ++ @tagName(builtin.cpu.arch) ++ "\" })";
/// The same as JSON, for the native renderer (docs/native-renderer.md).
pub const platform_json = "{\"os\":\"" ++ name ++ "\",\"arch\":\"" ++ @tagName(builtin.cpu.arch) ++ "\"}";

test "platform_js names the OS the way target.name does" {
    const std = @import("std");
    try std.testing.expect(std.mem.startsWith(u8, platform_js, "Object.freeze({ os: \"" ++ name ++ "\", arch: \""));
    try std.testing.expect(std.mem.endsWith(u8, platform_js, "\" })"));
}
