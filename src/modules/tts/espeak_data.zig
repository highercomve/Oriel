//! espeak-ng's compiled runtime data shipped with `-Dkokoro` apps
//! (build/espeak_data.zig compiles it; `addApp` installs and packages it),
//! and handing its location to kokoro.cpp, which passes
//! `KOKORO_ESPEAK_DATA_PATH` to `espeak_Initialize`.
//!
//! Where it is, per platform:
//! - Linux, Windows: `espeak-ng-data/` next to the executable (zig-out/bin,
//!   the deb/rpm's /usr/lib/<app>/, the AppImage's usr/bin, $INSTDIR).
//! - macOS: `<App>.app/Contents/Resources/espeak-ng-data` (also reached
//!   through the `Contents/MacOS/espeak-ng-data` symlink the bundle has).
//! - iOS: `<App>.app/espeak-ng-data` (the bundle's resource directory).
//! - Android: the APK's `assets/espeak-ng-data`, extracted by the Kotlin
//!   runtime to `<filesDir>/espeak-ng-data` before the app starts (again
//!   after an app update).

const std = @import("std");
const builtin = @import("builtin");

/// The environment variable kokoro.cpp reads for espeak-ng's data path.
pub const env_var = "KOKORO_ESPEAK_DATA_PATH";

/// The shipped directory's name.
pub const dir_name = "espeak-ng-data";

const is_android = builtin.abi.isAndroid();
const android_paths = if (is_android) @import("../../platform/android/paths.zig") else struct {};

/// The absolute path of the compiled espeak-ng data shipped with the app,
/// or null when it isn't there (an app built without `-Dkokoro`, a dev
/// build run from elsewhere, Android before `NativeLib.start`). Checked by
/// its `phondata` file. Caller frees with `gpa`.
pub fn bundledDir(gpa: std.mem.Allocator, io: std.Io) ?[]u8 {
    if (is_android) {
        const files = android_paths.filesDir() orelse return null;
        return existing(gpa, io, &.{ files, dir_name });
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executableDirPath(io, &buf) catch return null;
    const exe_dir = buf[0..n];
    if (existing(gpa, io, &.{ exe_dir, dir_name })) |dir| return dir;
    // A macOS bundle without the Contents/MacOS symlink: Contents/Resources.
    if (builtin.os.tag == .macos) return existing(gpa, io, &.{ exe_dir, "..", "Resources", dir_name });
    return null;
}

/// `parts` joined, when it holds `phondata`. Resolves `..` (macOS).
fn existing(gpa: std.mem.Allocator, io: std.Io, parts: []const []const u8) ?[]u8 {
    const joined = std.fs.path.join(gpa, parts) catch return null;
    defer gpa.free(joined);
    const dir = std.fs.path.resolve(gpa, &.{joined}) catch return null;
    const phondata = std.fs.path.join(gpa, &.{ dir, "phondata" }) catch {
        gpa.free(dir);
        return null;
    };
    defer gpa.free(phondata);
    std.Io.Dir.accessAbsolute(io, phondata, .{}) catch {
        gpa.free(dir);
        return null;
    };
    return dir;
}

const posix_env = struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
};
const windows_env = struct {
    extern "c" fn _wputenv_s(name: [*:0]const u16, value: [*:0]const u16) c_int;
};

/// Set `KOKORO_ESPEAK_DATA_PATH` to `dir` in the C runtime's environment,
/// where kokoro.cpp's `getenv` reads it. Call before the first
/// `kokoro.init` and not while other threads read the environment
/// (`setenv` isn't thread-safe).
///
/// On Windows the C library's `getenv` reads the CRT's own copy of the
/// environment, which `SetEnvironmentVariableW` doesn't update; `_wputenv_s`
/// updates it (both its wide and narrow tables) and the process
/// environment. espeak-ng then opens the files with narrow (ANSI code page)
/// paths, so a path outside that code page can't be opened.
pub fn setEnv(gpa: std.mem.Allocator, dir: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const name_w = std.unicode.utf8ToUtf16LeStringLiteral(env_var);
        const value_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, dir);
        defer gpa.free(value_w);
        if (windows_env._wputenv_s(name_w, value_w.ptr) != 0) return error.SetEnvFailed;
    } else {
        const value = try gpa.dupeZ(u8, dir);
        defer gpa.free(value);
        if (posix_env.setenv(env_var, value.ptr, 1) != 0) return error.SetEnvFailed;
    }
}

test "bundledDir is null without shipped data" {
    // The test runner's directory has no espeak-ng-data/phondata.
    const dir = bundledDir(std.testing.allocator, std.testing.io);
    defer if (dir) |d| std.testing.allocator.free(d);
    if (dir) |d| try std.testing.expect(std.mem.endsWith(u8, d, dir_name));
}

test "setEnv reaches the C library's getenv" {
    if (is_android) return error.SkipZigTest;
    const crt = struct {
        extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    // Set for the Kokoro synthesis test (src/modules/kokoro.zig): keep it.
    if (crt.getenv(env_var) != null) return error.SkipZigTest;
    try setEnv(std.testing.allocator, "/tmp/oriel-espeak-test");
    defer if (builtin.os.tag == .windows) {
        _ = windows_env._wputenv_s(std.unicode.utf8ToUtf16LeStringLiteral(env_var), std.unicode.utf8ToUtf16LeStringLiteral(""));
    } else {
        _ = crt.unsetenv(env_var);
    };
    const got = crt.getenv(env_var) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/oriel-espeak-test", std.mem.span(got));
}
