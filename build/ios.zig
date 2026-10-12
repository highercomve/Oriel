//! iOS SDK wiring for the build. Zig ships no iOS libc, so linking an iOS
//! executable needs Apple's SDK (iPhoneOS.sdk or iPhoneSimulator.sdk: from
//! Xcode, or the one `xtool setup` extracts from Xcode.xip on Linux), found
//! from `-Dapple_sdk=<path>`, else `$APPLE_SDK`, else Xcode's (`xcrun`) on a
//! Mac. Without one, iOS targets can
//! still be type-checked (`zig build check`), which links nothing: its C
//! code then sees Zig's own Darwin headers (`configureCheck`).

const std = @import("std");

/// Oriel's minimum iOS version: UIScene windows, `UTType`, WKWebView's
/// media capture permission delegate.
pub const min_os: std.SemanticVersion = .{ .major = 15, .minor = 0, .patch = 0 };

var sdk_cache: ?struct { b: *std.Build, simulator: bool, path: ?[]const u8 } = null;

/// The SDK root for `target`, or null: `-Dapple_sdk`, else `$APPLE_SDK`, else
/// (building on a Mac) Xcode's, from `xcrun`. `-Dapple_sdk` is declared on
/// first use.
pub fn sdk(b: *std.Build, target: std.Target) ?[]const u8 {
    const simulator = isSimulator(target);
    if (sdk_cache) |c| if (c.b == b and c.simulator == simulator) return c.path;
    const opt = b.option([]const u8, "apple_sdk", "iOS: the SDK to link against (iPhoneOS.sdk or iPhoneSimulator.sdk; default: $APPLE_SDK, else Xcode's on a Mac)");
    const path = opt orelse b.graph.environ_map.get("APPLE_SDK") orelse xcodeSdk(b, simulator);
    sdk_cache = .{ .b = b, .simulator = simulator, .path = path };
    return path;
}

/// `xcrun --sdk iphoneos|iphonesimulator --show-sdk-path` on a Mac with
/// Xcode; null elsewhere or when it fails.
fn xcodeSdk(b: *std.Build, simulator: bool) ?[]const u8 {
    if (b.graph.host.result.os.tag != .macos) return null;
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "xcrun", "--sdk", if (simulator) "iphonesimulator" else "iphoneos", "--show-sdk-path" }, &code, .ignore) catch return null;
    const path = std.mem.trim(u8, out, " \t\r\n");
    return if (path.len == 0) null else path;
}

pub fn isSimulator(target: std.Target) bool {
    return target.abi == .simulator;
}

/// The SDK's frameworks and libraries for `module`, and the frameworks
/// Oriel's iOS backend uses. The SDK's paths are given to the iOS module
/// (and its libc file, `configure`), not as the build's sysroot: that one is
/// every step's, and the host tools (tools/qjs_bytecode.c) link the build
/// machine's libc.
pub fn link(module: *std.Build.Module, root: []const u8, audio_capture: bool) void {
    const b = module.owner;
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) });
    // iOS 26 SDKs: UIKit's headers include <UIUtilities/UIDefines.h>, from a
    // framework that lives here (Objective-C extension sources need it).
    const sub = b.pathJoin(&.{ root, "System/Library/SubFrameworks" });
    if (std.Io.Dir.cwd().access(b.graph.io, sub, .{})) |_| module.addSystemFrameworkPath(.{ .cwd_relative = sub }) else |_| {}
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
    module.linkSystemLibrary("objc", .{});
    for ([_][]const u8{ "Foundation", "UIKit", "WebKit", "AVFoundation", "UserNotifications", "UniformTypeIdentifiers", "CoreLocation" }) |fw|
        module.linkFramework(fw, .{});
    if (audio_capture) {
        module.linkFramework("AudioToolbox", .{});
        // dictation's system engine (SFSpeechRecognizer).
        module.linkFramework("Speech", .{});
    }
}

/// The SDK's C library as a libc file: Zig ships Darwin headers for macOS
/// only, so C and C++ code (SQLite, ggml, whisper, llama, libc++ itself)
/// needs the SDK's `usr/include`.
pub fn libcFile(b: *std.Build, root: []const u8) std.Build.LazyPath {
    const files = b.addWriteFiles();
    const include = b.pathJoin(&.{ root, "usr", "include" });
    return files.add("ios-libc.txt", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ include, include, b.pathJoin(&.{ root, "usr", "lib" }) }));
}

/// An iOS executable: the SDK's libc (see `libcFile`) when there is an SDK.
pub fn configure(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (sdk(b, compile.rootModuleTarget())) |root| compile.setLibCFile(libcFile(b, root));
}

/// A type-check (`zig build check`) of an iOS compile: the SDK's libc when
/// there is an SDK, else Zig's own Darwin headers (`lib/libc/include/
/// any-darwin-any`, what Zig builds macOS code with) in its place, so C
/// headers and sources (SQLite, ggml, llama, whisper, espeak) type-check
/// on a machine without the SDK. Only for a check: nothing is emitted from
/// it, and an app's binary always comes from the SDK (`requireSdk`).
pub fn configureCheck(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (sdk(b, compile.rootModuleTarget())) |root| return compile.setLibCFile(libcFile(b, root));
    const lib = b.graph.zig_lib_directory.path orelse ".";
    const include = b.pathResolve(&.{ lib, "libc", "include", "any-darwin-any" });
    const files = b.addWriteFiles();
    compile.setLibCFile(files.add("ios-check-libc.txt", b.fmt(
        \\include_dir={s}
        \\sys_include_dir={s}
        \\crt_dir={s}
        \\msvc_lib_dir=
        \\kernel32_lib_dir=
        \\gcc_dir=
        \\
    , .{ include, include, b.pathResolve(&.{ lib, "libc", "darwin" }) })));
}

/// Fail `compile` when there is no SDK to link with.
pub fn requireSdk(b: *std.Build, compile: *std.Build.Step.Compile) void {
    if (sdk(b, compile.rootModuleTarget()) != null) return;
    compile.step.dependOn(&b.addFail("building for iOS needs the iOS SDK: pass -Dapple_sdk=<path to iPhoneOS.sdk> " ++
        "or set $APPLE_SDK (on Linux, `xtool setup` extracts it from Xcode.xip; `zig build check` works without it)").step);
}

/// `target` with Oriel's minimum iOS version when it names none.
pub fn resolveTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .ios or target.query.os_version_min != null) return target;
    var query = target.query;
    query.os_version_min = .{ .semver = min_os };
    return b.resolveTargetQuery(query);
}
