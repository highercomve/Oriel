//! Android NDK wiring for the build: Zig ships no Android libc (bionic), so
//! builds for `*-linux-android` compile and link against the NDK's sysroot
//! through a libc file (ziglang/zig#23906).
//!
//! The NDK is found from `-Dandroid_ndk=<path>`, else `$ANDROID_NDK_HOME`,
//! `$ANDROID_NDK_ROOT`, or the newest `$ANDROID_HOME/ndk/<version>`
//! (`$ANDROID_SDK_ROOT` too). Without one, Android targets can still be
//! type-checked (`zig build check`), which links nothing.

const std = @import("std");

/// Oriel's minimum Android API level: native TLS (below 29 LLVM emulates
/// it), `MediaProjection` audio capture, and AAudio's newer calls.
pub const min_api_level: u32 = 29;

/// ABI directory names in an APK (`lib/<abi>/liboriel.so`).
pub fn abiDir(target: std.Target) []const u8 {
    return switch (target.cpu.arch) {
        .aarch64 => "arm64-v8a",
        .x86_64 => "x86_64",
        .arm => "armeabi-v7a",
        .x86 => "x86",
        else => @tagName(target.cpu.arch),
    };
}

/// The NDK's target triple (its sysroot's library directory names).
pub fn triple(target: std.Target) []const u8 {
    return switch (target.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => "unknown-linux-android",
    };
}

pub fn apiLevel(target: std.Target) u32 {
    return target.os.version_range.linux.android;
}

var ndk_cache: ?struct { b: *std.Build, path: ?[]const u8 } = null;

/// The NDK root, or null. `-Dandroid_ndk` is declared on first use.
pub fn ndk(b: *std.Build) ?[]const u8 {
    if (ndk_cache) |c| if (c.b == b) return c.path;
    const opt = b.option([]const u8, "android_ndk", "Android NDK root (default: $ANDROID_NDK_HOME, $ANDROID_NDK_ROOT, or the newest $ANDROID_HOME/ndk/*)");
    const env = &b.graph.environ_map;
    const path: ?[]const u8 = opt orelse env.get("ANDROID_NDK_HOME") orelse env.get("ANDROID_NDK_ROOT") orelse newestNdk(b);
    ndk_cache = .{ .b = b, .path = path };
    return path;
}

fn newestNdk(b: *std.Build) ?[]const u8 {
    const env = &b.graph.environ_map;
    const sdk = env.get("ANDROID_HOME") orelse env.get("ANDROID_SDK_ROOT") orelse return null;
    const ndk_dir = b.pathJoin(&.{ sdk, "ndk" });
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, ndk_dir, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var best: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (best == null or versionLess(best.?, entry.name)) best = b.dupe(entry.name);
    }
    return if (best) |v| b.pathJoin(&.{ ndk_dir, v }) else null;
}

/// "27.2.12479018" < "28.0.13004108", numerically per component.
fn versionLess(a: []const u8, b: []const u8) bool {
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next();
        const y = ib.next();
        if (x == null or y == null) return x == null and y != null;
        const nx = std.fmt.parseInt(u64, x.?, 10) catch 0;
        const ny = std.fmt.parseInt(u64, y.?, 10) catch 0;
        if (nx != ny) return nx < ny;
    }
}

test versionLess {
    try std.testing.expect(versionLess("27.2.12479018", "28.0.13004108"));
    try std.testing.expect(!versionLess("28.0.1", "27.9.9"));
    try std.testing.expect(versionLess("26.1", "26.1.1"));
}

pub fn hostTag(b: *std.Build) []const u8 {
    const host = b.graph.host.result;
    return switch (host.os.tag) {
        .linux => "linux-x86_64", // the NDK ships x86_64 Linux tools only
        .macos => "darwin-x86_64", // universal binaries despite the name
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
}

pub fn sysroot(b: *std.Build, ndk_root: []const u8) []const u8 {
    return b.pathJoin(&.{ ndk_root, "toolchains", "llvm", "prebuilt", hostTag(b), "sysroot" });
}

/// The libc file describing the NDK's bionic for `target` (for
/// `Compile.setLibCFile`).
pub fn libcFile(b: *std.Build, ndk_root: []const u8, target: std.Target) std.Build.LazyPath {
    const root = sysroot(b, ndk_root);
    const files = b.addWriteFiles();
    return files.add("android-libc.txt", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{
        b.pathJoin(&.{ root, "usr", "include" }),
        b.pathJoin(&.{ root, "usr", "include", triple(target) }),
        b.pathJoin(&.{ root, "usr", "lib", triple(target), b.fmt("{d}", .{apiLevel(target)}) }),
    }));
}

/// Library and include paths of the sysroot on `module` (the NDK's
/// liblog, libandroid, libaaudio, libvulkan stubs for the API level).
pub fn addSysroot(b: *std.Build, module: *std.Build.Module, ndk_root: []const u8, target: std.Build.ResolvedTarget) void {
    const root = sysroot(b, ndk_root);
    const t = target.result;
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr", "lib", triple(t), b.fmt("{d}", .{apiLevel(t)}) }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr", "lib", triple(t) }) });
}

/// Make `compile` an Android shared library build: the NDK libc, 16 KiB
/// page alignment (required from Android 15 on 16 KiB-page devices).
pub fn configure(b: *std.Build, compile: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    if (ndk(b)) |root| compile.setLibCFile(libcFile(b, root, target.result));
    compile.link_z_max_page_size = 16384;
    compile.link_z_common_page_size = 16384;
}

/// Fail `compile` with a clear message when there's no NDK to link it
/// against (otherwise Zig reports "unable to provide libc for target").
/// Type-check-only compiles don't need one.
pub fn requireNdk(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (ndk(b) != null) return;
    compile.step.dependOn(&b.addFail("building for Android needs the NDK: set $ANDROID_NDK_HOME, " ++
        "install one under $ANDROID_HOME/ndk, or pass -Dandroid_ndk=<path> " ++
        "(`zig build check` works without it)").step);
}

/// `target` with Oriel's minimum API level if it asks for an older one.
pub fn resolveTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (!target.result.abi.isAndroid()) return target;
    if (apiLevel(target.result) >= min_api_level) return target;
    var query = target.query;
    query.android_api_level = min_api_level;
    return b.resolveTargetQuery(query);
}
