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
    /// Usage descriptions for the microphone and system audio permission
    /// prompts (audio_capture); macOS refuses access without them.
    audio_usage: bool = false,
};

/// Info.plist XML; the caller owns the result.
pub fn generateInfoPlist(gpa: std.mem.Allocator, o: PlistOptions) ![]u8 {
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
    if (o.audio_usage) {
        try usage(w, "NSMicrophoneUsageDescription", o.name, "records audio from the microphone.");
        try usage(w, "NSAudioCaptureUsageDescription", o.name, "records the audio other apps play.");
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

fn usage(w: *std.Io.Writer, key: []const u8, name: []const u8, what: []const u8) !void {
    try w.print("\t<key>{s}</key>\n\t<string>", .{key});
    try escape(w, name);
    try w.print(" {s}</string>\n", .{what});
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

/// Bundle directory name for a display name ("Notes" -> "Notes.app"); '/'
/// and ':' can't be in a file name.
pub fn bundleDirName(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try std.fmt.allocPrint(gpa, "{s}.app", .{name});
    for (out[0..name.len]) |*ch| if (ch.* == '/' or ch.* == ':') {
        ch.* = '-';
    };
    return out;
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
        .audio_usage = true,
    });
    defer a.free(xml);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>CFBundleExecutable</key>\n\t<string>notes</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<string>Notes &amp; &lt;Co&gt;</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<key>LSMinimumSystemVersion</key>\n\t<string>13.0</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<string>oriel-notes</string>\n\t\t\t\t<string>notes</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "NSAudioCaptureUsageDescription") != null);
    try std.testing.expect(std.mem.endsWith(u8, xml, "</dict>\n</plist>\n"));

    const plain = try generateInfoPlist(a, .{ .id = "x.y", .name = "Y", .exe_name = "y", .version = "1", .min_os = "13.0" });
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "CFBundleURLTypes") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "UsageDescription") == null);
}

test bundleDirName {
    const a = std.testing.allocator;
    const n = try bundleDirName(a, "A/B: C");
    defer a.free(n);
    try std.testing.expectEqualStrings("A-B- C.app", n);
}
