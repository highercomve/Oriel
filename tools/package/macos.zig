//! macOS .app bundle metadata: Info.plist generation.
//!
//! Layout written by `package-app`:
//!
//!     <Name>.app/Contents/Info.plist
//!     <Name>.app/Contents/PkgInfo
//!     <Name>.app/Contents/MacOS/<exe>
//!     <Name>.app/Contents/Resources/icon.icns

const std = @import("std");

pub const PlistOptions = struct {
    /// CFBundleIdentifier (reverse DNS; also the notification/TCC identity).
    id: []const u8,
    /// CFBundleName / CFBundleDisplayName.
    name: []const u8,
    /// CFBundleExecutable: the file in Contents/MacOS.
    exe_name: []const u8,
    version: []const u8,
    /// LSMinimumSystemVersion, from the build target (e.g. "13.0").
    min_os: []const u8,
    /// CFBundleIconFile (in Contents/Resources), without extension.
    icon_name: ?[]const u8 = "icon",
    /// CFBundleURLTypes: deep link schemes Launch Services routes to the app.
    url_schemes: []const []const u8 = &.{},
    /// Declared permissions: each `.kind` (a permissions.Kind name) with the
    /// usage text macOS shows. Kinds without an Info.plist key (accessibility,
    /// screen_capture, notifications) are skipped.
    permissions: []const Permission = &.{},
};

pub const Permission = struct { kind: []const u8, reason: []const u8 };

/// Info.plist usage-description keys per permission kind (macOS terminates
/// an app that uses a protected resource without its key).
pub fn usageKeys(kind: []const u8) []const []const u8 {
    const map = .{
        .{ "microphone", &[_][]const u8{"NSMicrophoneUsageDescription"} },
        .{ "camera", &[_][]const u8{"NSCameraUsageDescription"} },
        .{ "location", &[_][]const u8{ "NSLocationWhenInUseUsageDescription", "NSLocationUsageDescription" } },
        .{ "system_audio", &[_][]const u8{"NSAudioCaptureUsageDescription"} },
    };
    inline for (map) |m| if (std.mem.eql(u8, kind, m[0])) return m[1];
    return &.{};
}

/// macOS hardened-runtime entitlements for the declared permissions (for
/// Developer ID signing / notarization; ad-hoc signing doesn't need them).
pub fn generateEntitlements(gpa: std.mem.Allocator, permissions: []const Permission) ![]u8 {
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
    for (permissions) |p| {
        const key: ?[]const u8 = if (std.mem.eql(u8, p.kind, "microphone") or std.mem.eql(u8, p.kind, "system_audio"))
            "com.apple.security.device.audio-input"
        else if (std.mem.eql(u8, p.kind, "camera"))
            "com.apple.security.device.camera"
        else if (std.mem.eql(u8, p.kind, "location"))
            "com.apple.security.personal-information.location"
        else
            null;
        const k = key orelse continue;
        if (std.mem.indexOf(u8, out.written(), k) != null) continue;
        try w.print("\t<key>{s}</key>\n\t<true/>\n", .{k});
    }
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

/// Info.plist XML; the caller owns the result. Values that XML 1.0 can't
/// carry (control characters, invalid UTF-8) and malformed schemes are
/// rejected rather than written into a plist Launch Services would ignore.
pub fn generateInfoPlist(gpa: std.mem.Allocator, o: PlistOptions) ![]u8 {
    for ([_][]const u8{ o.id, o.name, o.exe_name, o.version, o.min_os }) |v| try checkText(v);
    for (o.url_schemes) |scheme| if (!isValidSchemeFormat(scheme)) return error.InvalidUrlScheme;
    for (o.permissions) |p| try checkText(p.reason);
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
    try entry(w, "CFBundleDevelopmentRegion", "en");
    try entry(w, "CFBundleDisplayName", o.name);
    try entry(w, "CFBundleExecutable", o.exe_name);
    if (o.icon_name) |icon| try entry(w, "CFBundleIconFile", icon);
    try entry(w, "CFBundleIdentifier", o.id);
    try entry(w, "CFBundleInfoDictionaryVersion", "6.0");
    try entry(w, "CFBundleName", o.name);
    try entry(w, "CFBundlePackageType", "APPL");
    try entry(w, "CFBundleShortVersionString", o.version);
    try entry(w, "CFBundleVersion", o.version);
    try entry(w, "LSMinimumSystemVersion", o.min_os);
    try w.writeAll("\t<key>NSHighResolutionCapable</key>\n\t<true/>\n");
    try entry(w, "NSPrincipalClass", "NSApplication");
    for (o.permissions) |p| {
        for (usageKeys(p.kind)) |key| try entry(w, key, p.reason);
    }
    if (o.url_schemes.len > 0) {
        try w.writeAll("\t<key>CFBundleURLTypes</key>\n\t<array>\n\t\t<dict>\n");
        try w.writeAll("\t\t\t<key>CFBundleURLName</key>\n\t\t\t<string>");
        try escape(w, o.id);
        try w.writeAll("</string>\n\t\t\t<key>CFBundleURLSchemes</key>\n\t\t\t<array>\n");
        for (o.url_schemes) |s| {
            try w.writeAll("\t\t\t\t<string>");
            try escape(w, s);
            try w.writeAll("</string>\n");
        }
        try w.writeAll("\t\t\t</array>\n\t\t</dict>\n\t</array>\n");
    }
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

fn entry(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.print("\t<key>{s}</key>\n\t<string>", .{key});
    try escape(w, value);
    try w.writeAll("</string>\n");
}

/// XML text escaping.
fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

/// A plist string value: valid UTF-8, no control characters.
fn checkText(v: []const u8) !void {
    if (v.len == 0 or !std.unicode.utf8ValidateSlice(v)) return error.InvalidPlistValue;
    for (v) |ch| if (ch < 0x20 or ch == 0x7F) return error.InvalidPlistValue;
}

/// RFC 3986 scheme syntax (the check in src/modules/deep_link/common.zig,
/// which this host tool can't import).
pub fn isValidSchemeFormat(scheme: []const u8) bool {
    if (scheme.len == 0 or !std.ascii.isAlphabetic(scheme[0])) return false;
    for (scheme[1..]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

/// Bundle directory name for a display name ("Notes" -> "Notes.app"). The
/// name must be usable as one file name as is (the build graph expects
/// `<name>.app`): no path separators or ':', not empty, not starting with '.'.
pub fn bundleDirName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    try checkText(name);
    if (name[0] == '.' or std.mem.indexOfAny(u8, name, "/\\:") != null) return error.InvalidBundleName;
    return std.fmt.allocPrint(gpa, "{s}.app", .{name});
}

test generateInfoPlist {
    const a = std.testing.allocator;
    const xml = try generateInfoPlist(a, .{
        .id = "dev.oriel.Notes",
        .name = "Notes & <Co>",
        .exe_name = "notes",
        .version = "1.2.3",
        .min_os = "13.0",
        .url_schemes = &.{ "oriel-notes", "notes" },
        .permissions = &.{
            .{ .kind = "system_audio", .reason = "Notes records the audio other apps play." },
            .{ .kind = "location", .reason = "To tag notes & places" },
            .{ .kind = "accessibility", .reason = "no plist key" },
        },
    });
    defer a.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>CFBundleExecutable</key>\n\t<string>notes</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<string>Notes &amp; &lt;Co&gt;</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>LSMinimumSystemVersion</key>\n\t<string>13.0</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<string>oriel-notes</string>\n\t\t\t\t<string>notes</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>NSAudioCaptureUsageDescription</key>\n\t<string>Notes records the audio other apps play.</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>NSLocationWhenInUseUsageDescription</key>\n\t<string>To tag notes &amp; places</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "NSLocationUsageDescription") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "no plist key") == null);

    const ent = try generateEntitlements(a, &.{
        .{ .kind = "microphone", .reason = "x" },
        .{ .kind = "system_audio", .reason = "x" },
        .{ .kind = "camera", .reason = "x" },
        .{ .kind = "accessibility", .reason = "x" },
    });
    defer a.free(ent);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ent, "com.apple.security.device.audio-input"));
    try std.testing.expect(std.mem.indexOf(u8, ent, "com.apple.security.device.camera") != null);
    try std.testing.expect(std.mem.endsWith(u8, xml, "</dict>\n</plist>\n"));

    const plain = try generateInfoPlist(a, .{ .id = "x.y", .name = "Y", .exe_name = "y", .version = "1", .min_os = "13.0" });
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "CFBundleURLTypes") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "UsageDescription") == null);
}

test bundleDirName {
    const a = std.testing.allocator;
    const n = try bundleDirName(a, "Oriel Notes (Beta)");
    defer a.free(n);
    try std.testing.expectEqualStrings("Oriel Notes (Beta).app", n);
    for ([_][]const u8{ "A/B", "..\\x", "a:b", ".hidden", "", "tab\there" }) |bad| {
        try std.testing.expect(std.meta.isError(bundleDirName(a, bad)));
    }
}

test "generateInfoPlist rejects values XML can't carry" {
    const a = std.testing.allocator;
    const base: PlistOptions = .{ .id = "x.y", .name = "Y", .exe_name = "y", .version = "1", .min_os = "13.0" };
    var o = base;
    o.name = "bad\x01name";
    try std.testing.expectError(error.InvalidPlistValue, generateInfoPlist(a, o));
    o = base;
    o.id = "\xff\xfe";
    try std.testing.expectError(error.InvalidPlistValue, generateInfoPlist(a, o));
    o = base;
    o.url_schemes = &.{"my app"};
    try std.testing.expectError(error.InvalidUrlScheme, generateInfoPlist(a, o));
    try std.testing.expect(isValidSchemeFormat("oriel-notes+x.y"));
    try std.testing.expect(!isValidSchemeFormat("1abc"));
}
