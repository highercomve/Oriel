//! macOS SDK wiring for the app's Objective-C and Swift sources
//! (`.macos.hooks`). Oriel's own macOS backend needs no explicit SDK: it is
//! built on a Mac, where zig-objc finds Xcode's (cross-building the macOS
//! framework from another OS isn't supported). Sources that `#import
//! <Foundation/Foundation.h>` need the SDK's headers on their own module,
//! and swiftc needs `-sdk`: `-Dmacos_sdk=<path>`, else `$SDKROOT` when it
//! names a MacOSX SDK, else `xcrun --sdk macosx --show-sdk-path` on a Mac.

const std = @import("std");

var sdk_cache: ?struct { b: *std.Build, path: ?[]const u8 } = null;

/// The macOS SDK root, or null. `-Dmacos_sdk` is declared on first use.
pub fn sdk(b: *std.Build) ?[]const u8 {
    if (sdk_cache) |c| if (c.b == b) return c.path;
    const opt = b.option([]const u8, "macos_sdk", "macOS: the SDK for the app's Objective-C and Swift hooks (default: $SDKROOT, else Xcode's from xcrun on a Mac)");
    const path = opt orelse fromSdkRoot(b) orelse xcrunSdk(b);
    sdk_cache = .{ .b = b, .path = path };
    return path;
}

/// `$SDKROOT` (what xcrun and Xcode set) when it is a MacOSX SDK: an iOS one
/// there is for another build.
fn fromSdkRoot(b: *std.Build) ?[]const u8 {
    const root = b.graph.environ_map.get("SDKROOT") orelse return null;
    return if (isMacSdkPath(root)) root else null;
}

pub fn isMacSdkPath(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    const base = std.fs.path.basename(trimmed);
    return std.mem.startsWith(u8, base, "MacOSX") and std.mem.endsWith(u8, base, ".sdk");
}

test isMacSdkPath {
    try std.testing.expect(isMacSdkPath("/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"));
    try std.testing.expect(isMacSdkPath("/Library/Developer/CommandLineTools/SDKs/MacOSX15.2.sdk/"));
    try std.testing.expect(!isMacSdkPath("/sdk/iPhoneOS.sdk"));
    try std.testing.expect(!isMacSdkPath(""));
}

fn xcrunSdk(b: *std.Build) ?[]const u8 {
    if (b.graph.host.result.os.tag != .macos) return null;
    var code: u8 = 0;
    const out = b.runAllowFail(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }, &code, .ignore) catch return null;
    const path = std.mem.trim(u8, out, " \t\r\n");
    return if (path.len == 0) null else path;
}

/// The SDK's headers, frameworks and libraries for `module`, a module with
/// Objective-C sources (the app's root module): its own paths, so Oriel's
/// and the other modules' C code keeps the toolchain's libc.
pub fn addPaths(module: *std.Build.Module, root: []const u8) void {
    const b = module.owner;
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/include" }) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System/Library/Frameworks" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr/lib" }) });
}

/// Fail `compile` (its `what` needs an SDK and there is none).
pub fn requireSdk(b: *std.Build, compile: *std.Build.Step.Compile, what: []const u8) void {
    compile.step.dependOn(&b.addFail(b.fmt("{s} need the macOS SDK and there is none: build on a Mac with Xcode or the Command Line Tools " ++
        "(xcode-select --install), or pass -Dmacos_sdk=<path to MacOSX.sdk> (docs/platform-hooks.md)", .{what})).step);
}
