//! iOS .app bundles (`ios-app`): the flat layout iOS expects, written
//! without Xcode (no asset catalog: the icons are loose PNGs named in
//! CFBundleIcons, which iOS still honors).
//!
//!     <Name>.app/<exe>
//!     <Name>.app/Info.plist
//!     <Name>.app/PkgInfo
//!     <Name>.app/AppIcon60x60@2x.png, ...
//!
//! The bundle is unsigned: `xtool` (or `codesign` on a Mac) signs it with a
//! provisioning profile when installing (docs/ios.md).

const std = @import("std");
const zigimg = @import("zigimg");
const macos = @import("macos.zig");
const icons = @import("icons.zig");
const metadata = @import("metadata.zig");

const Dir = std.Io.Dir;
const Io = std.Io;

pub const PlistOptions = struct {
    id: []const u8,
    name: []const u8,
    exe_name: []const u8,
    version: []const u8,
    /// MinimumOSVersion (e.g. "15.0").
    min_os: []const u8,
    /// Built for the simulator (CFBundleSupportedPlatforms).
    simulator: bool = false,
    /// Whether the bundle has the AppIcon PNGs (`icon_files`).
    icons: bool = true,
    url_schemes: []const []const u8 = &.{},
    permissions: []const macos.Permission = &.{},
    /// UIBackgroundModes `audio`: keep capturing or playing in the background.
    background_audio: bool = false,
    /// Allow plain-HTTP loads (the dev build's dev server on the LAN).
    allow_http: bool = false,
    /// CFBundleDocumentTypes (the share sheet's "Open in" row, Files'
    /// share): `.share_target.types` as UTIs (macos.utiForMime). The app
    /// gets copies (LSSupportsOpeningDocumentsInPlace false).
    document_types: []const []const u8 = &.{},
};

/// The icon files and their sizes in pixels.
pub const icon_files = [_]struct { name: []const u8, size: u32 }{
    .{ .name = "AppIcon60x60@2x.png", .size = 120 },
    .{ .name = "AppIcon60x60@3x.png", .size = 180 },
    .{ .name = "AppIcon76x76@2x~ipad.png", .size = 152 },
    .{ .name = "AppIcon83.5x83.5@2x~ipad.png", .size = 167 },
};

/// The NSUserActivity type Oriel requests extra window scenes with
/// (src/platform/ios/Shell.zig).
const window_activity_type = "dev.oriel.window";

fn usageKeys(kind: []const u8) []const []const u8 {
    // macOS's keys, except system audio, which iOS has no way to grant.
    if (std.mem.eql(u8, kind, "system_audio")) return &.{};
    return macos.usageKeys(kind);
}

pub fn generateInfoPlist(gpa: std.mem.Allocator, o: PlistOptions) ![]u8 {
    for ([_][]const u8{ o.id, o.name, o.exe_name, o.version, o.min_os }) |v| try macos.checkText(v);
    for (o.url_schemes) |scheme| if (!macos.isValidSchemeFormat(scheme)) return error.InvalidUrlScheme;
    for (o.permissions) |p| try macos.checkText(p.reason);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    try macos.entry(w, "CFBundleDevelopmentRegion", "en");
    try macos.entry(w, "CFBundleDisplayName", o.name);
    try macos.entry(w, "CFBundleExecutable", o.exe_name);
    try macos.entry(w, "CFBundleIdentifier", o.id);
    try macos.entry(w, "CFBundleInfoDictionaryVersion", "6.0");
    try macos.entry(w, "CFBundleName", o.name);
    try macos.entry(w, "CFBundlePackageType", "APPL");
    try macos.entry(w, "CFBundleShortVersionString", o.version);
    try macos.entry(w, "CFBundleVersion", o.version);
    try w.print("\t<key>CFBundleSupportedPlatforms</key>\n\t<array>\n\t\t<string>{s}</string>\n\t</array>\n", .{if (o.simulator) "iPhoneSimulator" else "iPhoneOS"});
    try macos.entry(w, "DTPlatformName", if (o.simulator) "iphonesimulator" else "iphoneos");
    try macos.entry(w, "MinimumOSVersion", o.min_os);
    try w.writeAll("\t<key>LSRequiresIPhoneOS</key>\n\t<true/>\n");
    // iPhone and iPad.
    try w.writeAll("\t<key>UIDeviceFamily</key>\n\t<array>\n\t\t<integer>1</integer>\n\t\t<integer>2</integer>\n\t</array>\n");
    if (!o.simulator) try w.writeAll("\t<key>UIRequiredDeviceCapabilities</key>\n\t<array>\n\t\t<string>arm64</string>\n\t</array>\n");
    // Full screen on every device (an empty launch screen: the webview's
    // background shows while the page loads).
    try w.writeAll("\t<key>UILaunchScreen</key>\n\t<dict/>\n");
    const orientations =
        "\t\t<string>UIInterfaceOrientationPortrait</string>\n" ++
        "\t\t<string>UIInterfaceOrientationPortraitUpsideDown</string>\n" ++
        "\t\t<string>UIInterfaceOrientationLandscapeLeft</string>\n" ++
        "\t\t<string>UIInterfaceOrientationLandscapeRight</string>\n";
    try w.writeAll("\t<key>UISupportedInterfaceOrientations</key>\n\t<array>\n" ++ orientations ++ "\t</array>\n");
    try w.writeAll("\t<key>UISupportedInterfaceOrientations~ipad</key>\n\t<array>\n" ++ orientations ++ "\t</array>\n");
    // ProMotion: an iPhone's display link may go past 60 Hz (the page's
    // requestAnimationFrame follows the display; iPads need no key).
    try w.writeAll("\t<key>CADisableMinimumFrameDurationOnPhone</key>\n\t<true/>\n");
    // Scenes: the app delegate supplies the configuration; iPad windows
    // each get a scene.
    try w.writeAll("\t<key>UIApplicationSceneManifest</key>\n\t<dict>\n\t\t<key>UIApplicationSupportsMultipleScenes</key>\n\t\t<true/>\n\t</dict>\n");
    try w.writeAll("\t<key>NSUserActivityTypes</key>\n\t<array>\n\t\t<string>" ++ window_activity_type ++ "</string>\n\t</array>\n");
    if (o.icons) {
        try w.writeAll("\t<key>CFBundleIcons</key>\n\t<dict>\n\t\t<key>CFBundlePrimaryIcon</key>\n\t\t<dict>\n\t\t\t<key>CFBundleIconFiles</key>\n\t\t\t<array>\n\t\t\t\t<string>AppIcon60x60</string>\n\t\t\t</array>\n\t\t</dict>\n\t</dict>\n");
        try w.writeAll("\t<key>CFBundleIcons~ipad</key>\n\t<dict>\n\t\t<key>CFBundlePrimaryIcon</key>\n\t\t<dict>\n\t\t\t<key>CFBundleIconFiles</key>\n\t\t\t<array>\n\t\t\t\t<string>AppIcon60x60</string>\n\t\t\t\t<string>AppIcon76x76</string>\n\t\t\t\t<string>AppIcon83.5x83.5</string>\n\t\t\t</array>\n\t\t</dict>\n\t</dict>\n");
    }
    for (o.permissions) |p| {
        for (usageKeys(p.kind)) |key| try macos.entry(w, key, p.reason);
    }
    if (o.background_audio) try w.writeAll("\t<key>UIBackgroundModes</key>\n\t<array>\n\t\t<string>audio</string>\n\t</array>\n");
    if (o.allow_http) try w.writeAll("\t<key>NSAppTransportSecurity</key>\n\t<dict>\n\t\t<key>NSAllowsArbitraryLoads</key>\n\t\t<true/>\n\t\t<key>NSAllowsLocalNetworking</key>\n\t\t<true/>\n\t</dict>\n");
    if (o.document_types.len > 0) {
        try macos.documentTypes(w, o.document_types);
        try w.writeAll("\t<key>LSSupportsOpeningDocumentsInPlace</key>\n\t<false/>\n");
    }
    if (o.url_schemes.len > 0) {
        try w.writeAll("\t<key>CFBundleURLTypes</key>\n\t<array>\n\t\t<dict>\n");
        try w.writeAll("\t\t\t<key>CFBundleURLName</key>\n\t\t\t<string>");
        try macos.escape(w, o.id);
        try w.writeAll("</string>\n\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n");
        for (o.url_schemes) |s| {
            try w.writeAll("\t\t\t\t<string>");
            try macos.escape(w, s);
            try w.writeAll("</string>\n");
        }
        try w.writeAll("\t\t\t</array>\n\t\t</dict>\n\t</array>\n");
    }
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

/// Write `src_png` resized to each of `icon_files` into `dir`. iOS icons
/// must be opaque: transparent pixels are composited over white.
fn writeIcons(gpa: std.mem.Allocator, io: Io, src_png: []const u8, dir: []const u8) !void {
    const data = try Dir.cwd().readFileAlloc(io, src_png, gpa, .limited(50 * 1024 * 1024));
    defer gpa.free(data);
    var img = try zigimg.Image.fromMemory(gpa, data);
    defer img.deinit(gpa);
    try img.convert(gpa, .rgba32);
    for (icon_files) |f| {
        var dst = try zigimg.Image.create(gpa, f.size, f.size, .rgba32);
        defer dst.deinit(gpa);
        icons.downsampleRgba32(img.pixels.rgba32, img.width, img.height, dst.pixels.rgba32, f.size, f.size);
        for (dst.pixels.rgba32) |*p| {
            const a: u32 = p.a;
            inline for (.{ "r", "g", "b" }) |ch| @field(p, ch) = @intCast((@as(u32, @field(p, ch)) * a + 255 * (255 - a)) / 255);
            p.a = 255;
        }
        const sz: usize = f.size;
        const buf = try gpa.alloc(u8, sz * sz * 8 + 4096);
        defer gpa.free(buf);
        const encoded = try dst.writeToMemory(gpa, buf, .{ .png = .{} });
        const path = try std.fs.path.join(gpa, &.{ dir, f.name });
        defer gpa.free(path);
        try Dir.cwd().writeFile(io, .{ .sub_path = path, .data = encoded });
    }
}

/// `ios-app`: assemble `<out-dir>/<Name>.app`.
pub fn iosAppCmd(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !u8 {
    var out_dir: ?[]const u8 = null;
    var bin_path: ?[]const u8 = null;
    var icon: ?[]const u8 = null;
    var o: PlistOptions = .{ .id = "", .name = "", .exe_name = "", .version = "0.1.0", .min_os = "15.0" };
    var have = [_]bool{false} ** 3; // id, name, exe
    var permissions: std.ArrayList(macos.Permission) = .empty;
    defer permissions.deinit(gpa);
    var url_schemes: std.ArrayList([]const u8) = .empty;
    defer url_schemes.deinit(gpa);
    var document_types: std.ArrayList([]const u8) = .empty;
    defer document_types.deinit(gpa);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--simulator")) {
            o.simulator = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--background-audio")) {
            o.background_audio = true;
            continue;
        } else if (std.mem.eql(u8, arg, "--allow-http")) {
            o.allow_http = true;
            continue;
        }
        const v = value orelse {
            std.debug.print("error: ios-app: unknown argument {s}\n", .{arg});
            return 1;
        };
        i += 1;
        if (std.mem.eql(u8, arg, "--out-dir")) {
            out_dir = v;
        } else if (std.mem.eql(u8, arg, "--bin")) {
            bin_path = v;
        } else if (std.mem.eql(u8, arg, "--icon")) {
            icon = v;
        } else if (std.mem.eql(u8, arg, "--app-id")) {
            o.id = v;
            have[0] = true;
        } else if (std.mem.eql(u8, arg, "--name")) {
            o.name = v;
            have[1] = true;
        } else if (std.mem.eql(u8, arg, "--exe-name")) {
            o.exe_name = v;
            have[2] = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            o.version = v;
        } else if (std.mem.eql(u8, arg, "--min-os")) {
            o.min_os = v;
        } else if (std.mem.eql(u8, arg, "--url-scheme")) {
            try url_schemes.append(gpa, v);
        } else if (std.mem.eql(u8, arg, "--document-type")) {
            try document_types.append(gpa, v);
        } else if (std.mem.eql(u8, arg, "--permission")) {
            const eq = std.mem.indexOfScalar(u8, v, '=') orelse {
                std.debug.print("error: ios-app: --permission expects <kind>=<reason>, got {s}\n", .{v});
                return 1;
            };
            try permissions.append(gpa, .{ .kind = v[0..eq], .reason = v[eq + 1 ..] });
        } else {
            std.debug.print("error: ios-app: unknown argument {s}\n", .{arg});
            return 1;
        }
    }
    const missing: ?[]const u8 = if (out_dir == null) "--out-dir" else if (bin_path == null) "--bin" else if (!have[0]) "--app-id" else if (!have[1]) "--name" else if (!have[2]) "--exe-name" else null;
    if (missing) |m| {
        std.debug.print("error: ios-app: missing {s}\n", .{m});
        return 1;
    }
    metadata.validateExeName(o.exe_name) catch {
        std.debug.print("error: ios-app: invalid --exe-name '{s}'\n", .{o.exe_name});
        return 1;
    };
    o.url_schemes = url_schemes.items;
    o.document_types = document_types.items;
    o.permissions = permissions.items;

    const bundle_name = macos.bundleDirName(gpa, o.name) catch |err| {
        std.debug.print("error: ios-app: the app name \"{s}\" can't be a bundle name ({s})\n", .{ o.name, @errorName(err) });
        return 1;
    };
    defer gpa.free(bundle_name);
    const bundle = try std.fs.path.join(gpa, &.{ out_dir.?, bundle_name });
    defer gpa.free(bundle);
    Dir.cwd().deleteTree(io, bundle) catch {};
    try Dir.cwd().createDirPath(io, bundle);

    const exe_dest = try std.fs.path.join(gpa, &.{ bundle, o.exe_name });
    defer gpa.free(exe_dest);
    try Dir.cwd().copyFile(bin_path.?, Dir.cwd(), exe_dest, io, .{ .permissions = @import("main.zig").filePerms(0o755) });

    o.icons = icon != null;
    if (icon) |src| writeIcons(gpa, io, src, bundle) catch |err| {
        std.debug.print("error: ios-app: icon {s}: {s}\n", .{ src, @errorName(err) });
        return 1;
    };

    const plist = generateInfoPlist(gpa, o) catch |err| {
        std.debug.print("error: ios-app: Info.plist: {s} (package metadata must be UTF-8 without control characters; URL schemes must match [A-Za-z][A-Za-z0-9+.-]*)\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(plist);
    const plist_path = try std.fs.path.join(gpa, &.{ bundle, "Info.plist" });
    defer gpa.free(plist_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = plist_path, .data = plist });
    const pkginfo_path = try std.fs.path.join(gpa, &.{ bundle, "PkgInfo" });
    defer gpa.free(pkginfo_path);
    try Dir.cwd().writeFile(io, .{ .sub_path = pkginfo_path, .data = "APPL????" });
    return 0;
}

test generateInfoPlist {
    const a = std.testing.allocator;
    const xml = try generateInfoPlist(a, .{
        .id = "dev.oriel.Notes",
        .name = "Notes",
        .exe_name = "notes",
        .version = "1.0.0",
        .min_os = "15.0",
        .url_schemes = &.{"oriel-notes"},
        .permissions = &.{
            .{ .kind = "microphone", .reason = "Dictation" },
            .{ .kind = "system_audio", .reason = "not on iOS" },
        },
        .background_audio = true,
    });
    defer a.free(xml);
    for ([_][]const u8{
        "<key>MinimumOSVersion</key>\n\t<string>15.0</string>",
        "<key>NSMicrophoneUsageDescription</key>\n\t<string>Dictation</string>",
        "<key>NSSpeechRecognitionUsageDescription</key>\n\t<string>Dictation</string>",
        "<string>iPhoneOS</string>",
        "<key>UIApplicationSupportsMultipleScenes</key>",
        "<key>CADisableMinimumFrameDurationOnPhone</key>\n\t<true/>",
        "<string>dev.oriel.window</string>",
        "<string>AppIcon60x60</string>",
        "<string>audio</string>",
        "<string>oriel-notes</string>",
    }) |needle| {
        if (std.mem.indexOf(u8, xml, needle) == null) {
            std.debug.print("missing: {s}\n", .{needle});
            return error.TestExpectedEqual;
        }
    }
    try std.testing.expect(std.mem.indexOf(u8, xml, "not on iOS") == null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "NSAppTransportSecurity") == null);
}
