//! The tools `oriel ios` needs, found or (after asking) set up:
//!
//! - The iOS SDK, to link: `$APPLE_SDK`; on a Mac, Xcode's
//!   (`xcrun --sdk iphoneos --show-sdk-path`); on Linux, the one `xtool
//!   setup` extracts from Xcode.xip into `~/.swiftpm/swift-sdks/
//!   darwin.artifactbundle` (`$XDG_CONFIG_HOME/swiftpm` when set).
//! - xtool (https://github.com/xtool-org/xtool), to sign and install on a
//!   device: from PATH, or `~/.oriel/xtool/xtool`, where `oriel ios setup`
//!   downloads its Linux AppImage.
//! - usbmuxd (Linux), through which xtool reaches the device: a system
//!   service, so it comes from the distro's package manager (`sudo apt
//!   install usbmuxd`, ...), run after asking.
//!
//! Nothing is downloaded or run without asking first (`--yes` answers yes;
//! without a terminal the answer is no). Xcode.xip itself can't be fetched
//! for the user: Apple's download page needs their Apple ID in a browser.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("Context.zig");
const zig_manager = @import("zig_manager.zig");
const doctor = @import("doctor.zig");

const Dir = std.Io.Dir;

pub const xtool_releases = "https://github.com/xtool-org/xtool/releases/latest";
const max_xtool_download: usize = 400 << 20;

/// Ask a yes/no question on the terminal; Enter means yes. `yes` answers
/// without asking; without a terminal on stdin the answer is no.
pub fn confirm(ctx: Context, yes: bool, question: []const u8) bool {
    if (yes) return true;
    const stdin = std.Io.File.stdin();
    if (!(stdin.isTty(ctx.io) catch false)) {
        ctx.err.print("{s} Not asking without a terminal: pass --yes to accept.\n", .{question}) catch {};
        return false;
    }
    ctx.out.print("{s} [Y/n] ", .{question}) catch return false;
    ctx.flush();
    var buf: [256]u8 = undefined;
    var reader = stdin.readerStreaming(ctx.io, &buf);
    const line = (reader.interface.takeDelimiter('\n') catch return false) orelse return false;
    return isYes(line);
}

pub fn isYes(answer: []const u8) bool {
    const a = std.mem.trim(u8, answer, " \t\r\n");
    return a.len == 0 or std.ascii.eqlIgnoreCase(a, "y") or std.ascii.eqlIgnoreCase(a, "yes");
}

test isYes {
    try std.testing.expect(isYes(""));
    try std.testing.expect(isYes("Y\r\n"));
    try std.testing.expect(isYes(" yes "));
    try std.testing.expect(!isYes("n"));
    try std.testing.expect(!isYes("nope"));
}

// ---------------------------------------------------------------------------
// xtool
// ---------------------------------------------------------------------------

/// `~/.oriel/xtool/xtool` (caller frees).
fn managedXtool(ctx: Context) ![]u8 {
    const home = try zig_manager.orielHome(ctx.gpa, ctx.environ);
    defer ctx.gpa.free(home);
    return std.fs.path.join(ctx.gpa, &.{ home, "xtool", "xtool" });
}

/// xtool from PATH or Oriel's own copy (caller frees), or null.
pub fn findXtool(ctx: Context) !?[]u8 {
    if (try ctx.findExecutable("xtool")) |p| return p;
    const managed = try managedXtool(ctx);
    Dir.cwd().access(ctx.io, managed, .{ .execute = true }) catch {
        ctx.gpa.free(managed);
        return null;
    };
    return managed;
}

/// The release asset for this machine (xtool ships Linux AppImages for
/// x86_64 and aarch64; on a Mac it is an app, installed by the user).
pub fn xtoolAsset(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    if (os != .linux) return null;
    return switch (arch) {
        .x86_64 => "xtool-x86_64.AppImage",
        .aarch64 => "xtool-aarch64.AppImage",
        else => null,
    };
}

test xtoolAsset {
    try std.testing.expectEqualStrings("xtool-x86_64.AppImage", xtoolAsset(.linux, .x86_64).?);
    try std.testing.expectEqualStrings("xtool-aarch64.AppImage", xtoolAsset(.linux, .aarch64).?);
    try std.testing.expect(xtoolAsset(.macos, .aarch64) == null);
}

/// xtool, asking to download it when it is missing (caller frees), or null.
pub fn ensureXtool(ctx: Context, yes: bool) !?[]u8 {
    if (try findXtool(ctx)) |p| return p;
    const asset = xtoolAsset(builtin.os.tag, builtin.cpu.arch) orelse {
        try ctx.err.print("xtool is not installed. Install it from {s} (on a Mac, its instructions), then run this again.\n", .{xtool_releases});
        return null;
    };
    const dest = try managedXtool(ctx);
    defer ctx.gpa.free(dest);
    const question = try std.fmt.allocPrint(ctx.gpa, "xtool signs the app with your Apple ID and installs it on your device, and isn't installed.\nDownload {s} (latest release, {s}) into {s}?", .{ asset, xtool_releases, dest });
    defer ctx.gpa.free(question);
    if (!confirm(ctx, yes, question)) return null;

    const dir = std.fs.path.dirname(dest).?;
    try Dir.cwd().createDirPath(ctx.io, dir);
    const part = try std.fmt.allocPrint(ctx.gpa, "{s}.part", .{dest});
    defer ctx.gpa.free(part);
    const url = try std.fmt.allocPrint(ctx.gpa, "{s}/download/{s}", .{ xtool_releases, asset });
    defer ctx.gpa.free(url);
    try ctx.err.print("downloading {s}\n", .{url});
    ctx.flush();
    var arena_state = std.heap.ArenaAllocator.init(ctx.gpa);
    defer arena_state.deinit();
    var client: std.http.Client = .{ .allocator = arena_state.allocator(), .io = ctx.io };
    defer client.deinit();
    zig_manager.downloadToFile(ctx, &client, url, part, max_xtool_download, null) catch |err| {
        Dir.cwd().deleteFile(ctx.io, part) catch {};
        try ctx.err.print("error: downloading xtool failed ({s}); get it from {s}\n", .{ @errorName(err), xtool_releases });
        return null;
    };
    const file = try Dir.cwd().openFile(ctx.io, part, .{});
    if (builtin.os.tag != .windows) {
        file.setPermissions(ctx.io, std.Io.File.Permissions.fromMode(0o755)) catch {};
    }
    file.close(ctx.io);
    try Dir.rename(Dir.cwd(), part, Dir.cwd(), dest, ctx.io);
    try ctx.out.print("installed xtool in {s}\n", .{dest});
    return try ctx.gpa.dupe(u8, dest);
}

// ---------------------------------------------------------------------------
// usbmuxd
// ---------------------------------------------------------------------------

/// Whether usbmuxd is installed: on PATH, or in an sbin directory (often
/// not on a user's PATH).
pub fn hasUsbmuxd(ctx: Context) bool {
    if (ctx.hasExecutable("usbmuxd") catch false) return true;
    for ([_][]const u8{ "/usr/sbin/usbmuxd", "/usr/bin/usbmuxd", "/sbin/usbmuxd", "/usr/local/sbin/usbmuxd" }) |p| {
        Dir.cwd().access(ctx.io, p, .{}) catch continue;
        return true;
    }
    return false;
}

/// The command installing usbmuxd with `distro`'s package manager (caller
/// frees the list; the strings are static).
pub fn usbmuxdInstallArgv(gpa: std.mem.Allocator, distro: doctor.Distro) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(gpa);
    var words = std.mem.tokenizeScalar(u8, doctor.installPrefix(distro), ' ');
    while (words.next()) |w| try argv.append(gpa, w);
    try argv.append(gpa, "usbmuxd");
    return argv.toOwnedSlice(gpa);
}

test usbmuxdInstallArgv {
    const gpa = std.testing.allocator;
    const apt = try usbmuxdInstallArgv(gpa, .apt);
    defer gpa.free(apt);
    try std.testing.expectEqual(4, apt.len);
    try std.testing.expectEqualStrings("sudo", apt[0]);
    try std.testing.expectEqualStrings("usbmuxd", apt[3]);
    const arch = try usbmuxdInstallArgv(gpa, .pacman);
    defer gpa.free(arch);
    try std.testing.expectEqualStrings("--needed", arch[3]);
}

/// Linux: make sure usbmuxd is there, asking to install it with the
/// distro's package manager. Only in a terminal (sudo asks for the
/// password). Returns whether it is installed; missing isn't fatal (xtool
/// reports the device it can't reach).
pub fn ensureUsbmuxd(ctx: Context, yes: bool) !bool {
    if (builtin.os.tag != .linux or hasUsbmuxd(ctx)) return true;
    const os_release = Dir.cwd().readFileAlloc(ctx.io, "/etc/os-release", ctx.gpa, .limited(64 * 1024)) catch "";
    defer if (os_release.len > 0) ctx.gpa.free(os_release);
    const distro = doctor.distroFromOsRelease(os_release) orelse {
        try ctx.err.print("usbmuxd isn't installed: xtool needs it to reach your device. Install it with your package manager (the package is usually `usbmuxd`).\n", .{});
        return false;
    };
    const argv = try usbmuxdInstallArgv(ctx.gpa, distro);
    defer ctx.gpa.free(argv);
    const line = try std.mem.join(ctx.gpa, " ", argv);
    defer ctx.gpa.free(line);
    if (!(std.Io.File.stdin().isTty(ctx.io) catch false)) {
        try ctx.err.print("usbmuxd isn't installed: xtool needs it to reach your device. Run `{s}` in a terminal.\n", .{line});
        return false;
    }
    const question = try std.fmt.allocPrint(ctx.gpa, "usbmuxd isn't installed: xtool needs it to reach your device (a system service).\nInstall it with `{s}`?", .{line});
    defer ctx.gpa.free(question);
    if (!confirm(ctx, yes, question)) return false;
    const code = ctx.run(argv, null) orelse return false;
    if (code != 0) {
        try ctx.err.print("error: `{s}` failed (exit code {d})\n", .{ line, code });
        return false;
    }
    return hasUsbmuxd(ctx);
}

// ---------------------------------------------------------------------------
// The iOS SDK
// ---------------------------------------------------------------------------

pub const Platform = enum {
    device,
    simulator,

    fn name(p: Platform) []const u8 {
        return switch (p) {
            .device => "iPhoneOS",
            .simulator => "iPhoneSimulator",
        };
    }
};

/// Whether `path` is an SDK directory of `platform` inside an Xcode tree:
/// `.../Platforms/<P>.platform/Developer/SDKs/<P><version>.sdk` (not the
/// unversioned `<P>.sdk` symlink).
pub fn isSdkPath(path: []const u8, platform: Platform) bool {
    const base = std.fs.path.basename(path);
    const p = platform.name();
    if (!std.mem.startsWith(u8, base, p) or !std.mem.endsWith(u8, base, ".sdk")) return false;
    const version = base[p.len .. base.len - ".sdk".len];
    if (version.len == 0 or !std.ascii.isDigit(version[0])) return false;
    var parent_buf: [64]u8 = undefined;
    const parent = std.fmt.bufPrint(&parent_buf, "{s}.platform/Developer/SDKs", .{p}) catch return false;
    const dir = std.fs.path.dirname(path) orelse return false;
    return std.mem.endsWith(u8, dir, parent);
}

test isSdkPath {
    try std.testing.expect(isSdkPath("/x/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk", .device));
    try std.testing.expect(!isSdkPath("/x/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk", .device));
    try std.testing.expect(!isSdkPath("/x/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk", .simulator));
    try std.testing.expect(isSdkPath("/x/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk", .simulator));
}

/// Where xtool installs its Darwin SDK bundle (caller frees).
fn xtoolSdkBundle(ctx: Context) ![]u8 {
    if (ctx.environ.get("XDG_CONFIG_HOME")) |x| if (std.fs.path.isAbsolute(x))
        return std.fs.path.join(ctx.gpa, &.{ x, "swiftpm", "swift-sdks", "darwin.artifactbundle" });
    const home = ctx.environ.get("HOME") orelse return error.NoHomeDirectory;
    return std.fs.path.join(ctx.gpa, &.{ home, ".swiftpm", "swift-sdks", "darwin.artifactbundle" });
}

/// The SDK for `platform` (caller frees), or null.
pub fn findSdk(ctx: Context, platform: Platform) !?[]u8 {
    if (ctx.environ.get("APPLE_SDK")) |s| if (s.len > 0) return try ctx.gpa.dupe(u8, s);
    if (builtin.os.tag == .macos) {
        const got = ctx.capture(&.{ "xcrun", "--sdk", if (platform == .device) "iphoneos" else "iphonesimulator", "--show-sdk-path" }, 30_000) orelse return null;
        defer got.deinit(ctx.gpa);
        const path = std.mem.trim(u8, got.text(), " \r\n");
        if (path.len == 0 or !std.fs.path.isAbsolute(path)) return null;
        return try ctx.gpa.dupe(u8, path);
    }
    const bundle = xtoolSdkBundle(ctx) catch return null;
    defer ctx.gpa.free(bundle);
    var dir = Dir.cwd().openDir(ctx.io, bundle, .{ .iterate = true }) catch return null;
    defer dir.close(ctx.io);
    var walker = try dir.walk(ctx.gpa);
    defer walker.deinit();
    while (walker.next(ctx.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        if (!isSdkPath(entry.path, platform)) continue;
        return try std.fs.path.join(ctx.gpa, &.{ bundle, entry.path });
    }
    return null;
}

/// The SDK for `platform`, offering `xtool setup` (Linux) when there is
/// none (caller frees), or null with the reason printed.
pub fn ensureSdk(ctx: Context, platform: Platform, yes: bool) !?[]u8 {
    if (try findSdk(ctx, platform)) |s| return s;
    if (builtin.os.tag == .macos) {
        try ctx.err.print("error: no iOS SDK: install Xcode (App Store), open it once, then run this again; or set $APPLE_SDK.\n", .{});
        return null;
    }
    if (builtin.os.tag != .linux) {
        try ctx.err.print("error: no iOS SDK: set $APPLE_SDK to an iPhoneOS.sdk (xtool's `xtool setup` extracts one on Linux).\n", .{});
        return null;
    }
    try ctx.out.print(
        \\The iOS SDK isn't set up. On Linux it comes from Xcode.xip, which Apple only
        \\lets you download yourself: https://developer.apple.com/download/all/?q=Xcode
        \\(sign in with your Apple ID). `xtool setup` then logs in to your Apple ID
        \\(for signing) and extracts the SDK from the .xip.
        \\
    , .{});
    const xtool = try ensureXtool(ctx, yes) orelse return null;
    defer ctx.gpa.free(xtool);
    // `xtool setup` is an interactive login (Apple ID, 2FA): it needs a
    // terminal whatever --yes says.
    if (!(std.Io.File.stdin().isTty(ctx.io) catch false)) {
        try ctx.err.print("Run `{s} setup` in a terminal (it asks for your Apple ID and the path to Xcode.xip), or set $APPLE_SDK.\n", .{xtool});
        return null;
    }
    if (!confirm(ctx, yes, "Run `xtool setup` now (it asks for your Apple ID and the path to Xcode.xip)?")) {
        try ctx.err.print("Run `{s} setup` when you have Xcode.xip, or set $APPLE_SDK.\n", .{xtool});
        return null;
    }
    const code = ctx.run(&.{ xtool, "setup" }, null) orelse return null;
    if (code != 0) {
        try ctx.err.print("error: `xtool setup` failed (exit code {d})\n", .{code});
        return null;
    }
    return try findSdk(ctx, platform) orelse {
        try ctx.err.print("error: `xtool setup` finished but no {s} SDK is in its bundle; set $APPLE_SDK.\n", .{platform.name()});
        return null;
    };
}
