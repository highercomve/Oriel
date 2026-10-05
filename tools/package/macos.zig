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
    /// CFBundleDocumentTypes (Finder's "Open With", drops on the Dock icon):
    /// `.share_target.types`, MIME types mapped to UTIs (`utiForMime`).
    document_types: []const []const u8 = &.{},
    /// The app's own usage keys (`AppOptions.macos.usage_descriptions`),
    /// written with the permissions' (`writeUsageDescriptions`).
    usage_descriptions: []const UsageDescription = &.{},
};

pub const Permission = struct { kind: []const u8, reason: []const u8 };

/// An Info.plist usage-description key the permission kinds don't cover
/// (`NSMotionUsageDescription`, ...) and its text.
pub const UsageDescription = struct { key: []const u8, text: []const u8 };

/// A usage key Oriel writes as given: `[A-Za-z0-9_.~-]` ending in
/// "UsageDescription" (so it can't collide with the bundle keys Oriel
/// writes itself).
pub fn validUsageKey(key: []const u8) bool {
    return std.mem.endsWith(u8, key, "UsageDescription") and validPlistKey(key);
}

/// A plist key written as is (no escaping needed): `[A-Za-z0-9_.~-]+`.
pub fn validPlistKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 200) return false;
    for (key) |ch| if (!std.ascii.isAlphanumeric(ch) and std.mem.indexOfScalar(u8, "_.~-", ch) == null) return false;
    return true;
}

/// The usage-description entries: each permission's keys (`keysFor`, its
/// kind's), then the app's extra keys, one entry per key. An extra key a
/// permission also has keeps the permission's place with the extra's text
/// (the last extra's when several name it).
pub fn writeUsageDescriptions(
    w: *std.Io.Writer,
    permissions: []const Permission,
    extras: []const UsageDescription,
    comptime keysFor: fn ([]const u8) []const []const u8,
) !void {
    for (permissions, 0..) |p, pi| for (keysFor(p.kind)) |key| {
        if (permissionHasKey(permissions[0..pi], key, keysFor)) continue;
        try entry(w, key, extraText(extras, key) orelse p.reason);
    };
    for (extras, 0..) |e, ei| {
        if (permissionHasKey(permissions, e.key, keysFor)) continue;
        if (extraText(extras[0..ei], e.key) != null) continue;
        try entry(w, e.key, extraText(extras, e.key).?);
    }
}

fn permissionHasKey(permissions: []const Permission, key: []const u8, comptime keysFor: fn ([]const u8) []const []const u8) bool {
    for (permissions) |p| for (keysFor(p.kind)) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// The text of the last extra naming `key`.
fn extraText(extras: []const UsageDescription, key: []const u8) ?[]const u8 {
    var i = extras.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, extras[i].key, key)) return extras[i].text;
    }
    return null;
}

/// Checks what `writeUsageDescriptions` writes: the texts, and the extra keys.
pub fn checkUsageDescriptions(permissions: []const Permission, extras: []const UsageDescription) !void {
    for (permissions) |p| try checkText(p.reason);
    for (extras) |e| {
        if (!validUsageKey(e.key)) return error.InvalidUsageKey;
        try checkText(e.text);
    }
}

/// Info.plist usage-description keys per permission kind (macOS terminates
/// an app that uses a protected resource without its key).
pub fn usageKeys(kind: []const u8) []const []const u8 {
    const map = .{
        // The microphone's text also covers speech recognition (dictation's
        // system engine asks for both; asking without the key ends the app).
        .{ "microphone", &[_][]const u8{ "NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription" } },
        .{ "camera", &[_][]const u8{"NSCameraUsageDescription"} },
        .{ "location", &[_][]const u8{ "NSLocationWhenInUseUsageDescription", "NSLocationUsageDescription" } },
        .{ "system_audio", &[_][]const u8{"NSAudioCaptureUsageDescription"} },
        .{ "bluetooth", &[_][]const u8{"NSBluetoothAlwaysUsageDescription"} },
        .{ "local_network", &[_][]const u8{"NSLocalNetworkUsageDescription"} },
    };
    inline for (map) |m| if (std.mem.eql(u8, kind, m[0])) return m[1];
    return &.{};
}

/// macOS hardened-runtime entitlements for the declared permissions (for
/// Developer ID signing / notarization; ad-hoc signing doesn't need them),
/// plus the app's own boolean entitlements (`AppOptions.macos.entitlements`,
/// keys as `validPlistKey`), each once.
pub fn generateEntitlements(gpa: std.mem.Allocator, permissions: []const Permission, extras: []const []const u8) ![]u8 {
    for (extras) |k| if (!validPlistKey(k)) return error.InvalidEntitlement;
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
        try writeEntitlement(w, out.written(), key orelse continue);
    }
    for (extras) |k| try writeEntitlement(w, out.written(), k);
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

/// `<key>` with `<true/>`, unless `written` has the key already.
fn writeEntitlement(w: *std.Io.Writer, written: []const u8, key: []const u8) !void {
    var buf: [256]u8 = undefined;
    const tag = std.fmt.bufPrint(&buf, "<key>{s}</key>", .{key}) catch return error.InvalidEntitlement;
    if (std.mem.indexOf(u8, written, tag) != null) return;
    try w.print("\t{s}\n\t<true/>\n", .{tag});
}

/// Info.plist XML; the caller owns the result. Values that XML 1.0 can't
/// carry (control characters, invalid UTF-8) and malformed schemes are
/// rejected rather than written into a plist Launch Services would ignore.
pub fn generateInfoPlist(gpa: std.mem.Allocator, o: PlistOptions) ![]u8 {
    for ([_][]const u8{ o.id, o.name, o.exe_name, o.version, o.min_os }) |v| try checkText(v);
    for (o.url_schemes) |scheme| if (!isValidSchemeFormat(scheme)) return error.InvalidUrlScheme;
    try checkUsageDescriptions(o.permissions, o.usage_descriptions);
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
    try writeUsageDescriptions(w, o.permissions, o.usage_descriptions, usageKeys);
    try documentTypes(w, o.document_types);
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

/// The UTI for a MIME type (`*/*`, `image/*`, or a known one; a subtype
/// UTIs don't name falls back to its family's), or null for none.
pub fn utiForMime(mime: []const u8) ?[]const u8 {
    const exact = .{
        .{ "*/*", "public.data" },                  .{ "text/plain", "public.plain-text" },
        .{ "text/html", "public.html" },            .{ "text/csv", "public.comma-separated-values-text" },
        .{ "application/json", "public.json" },     .{ "application/pdf", "com.adobe.pdf" },
        .{ "application/zip", "public.zip-archive" }, .{ "application/xml", "public.xml" },
        .{ "image/png", "public.png" },             .{ "image/jpeg", "public.jpeg" },
        .{ "image/gif", "com.compuserve.gif" },     .{ "image/heic", "public.heic" },
        .{ "image/svg+xml", "public.svg-image" },   .{ "video/mp4", "public.mpeg-4" },
        .{ "video/quicktime", "com.apple.quicktime-movie" }, .{ "audio/mpeg", "public.mp3" },
    };
    inline for (exact) |e| if (std.ascii.eqlIgnoreCase(mime, e[0])) return e[1];
    const slash = std.mem.indexOfScalar(u8, mime, '/') orelse return null;
    const family = .{
        .{ "image", "public.image" }, .{ "video", "public.movie" }, .{ "audio", "public.audio" },
        .{ "text", "public.text" },   .{ "application", "public.data" },
    };
    inline for (family) |f| if (std.ascii.eqlIgnoreCase(mime[0..slash], f[0])) return f[1];
    return null;
}

/// CFBundleDocumentTypes for MIME `types`: one Viewer entry, ranked
/// Alternate (the app is offered, not made the default), with their UTIs.
pub fn documentTypes(w: *std.Io.Writer, types: []const []const u8) !void {
    var utis: [32][]const u8 = undefined;
    var n: usize = 0;
    for (types) |t| {
        const u = utiForMime(t) orelse continue;
        if (n == utis.len) break;
        const seen = for (utis[0..n]) |v| {
            if (std.mem.eql(u8, v, u)) break true;
        } else false;
        if (seen) continue;
        utis[n] = u;
        n += 1;
    }
    if (n == 0) return;
    try w.writeAll("\t<key>CFBundleDocumentTypes</key>\n\t<array>\n\t\t<dict>\n");
    try w.writeAll("\t\t\t<key>CFBundleTypeName</key>\n\t\t\t<string>Shared item</string>\n");
    try w.writeAll("\t\t\t<key>CFBundleTypeRole</key>\n\t\t\t<string>Viewer</string>\n");
    try w.writeAll("\t\t\t<key>LSHandlerRank</key>\n\t\t\t<string>Alternate</string>\n");
    try w.writeAll("\t\t\t<key>LSItemContentTypes</key>\n\t\t\t<array>\n");
    for (utis[0..n]) |u| try w.print("\t\t\t\t<string>{s}</string>\n", .{u});
    try w.writeAll("\t\t\t</array>\n\t\t</dict>\n\t</array>\n");
}

pub fn entry(w: *std.Io.Writer, key: []const u8, value: []const u8) !void {
    try w.print("\t<key>{s}</key>\n\t<string>", .{key});
    try escape(w, value);
    try w.writeAll("</string>\n");
}

/// XML text escaping.
pub fn escape(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(ch),
    };
}

/// A plist string value: valid UTF-8, no control characters.
pub fn checkText(v: []const u8) !void {
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
    }, &.{ "com.apple.security.device.bluetooth", "com.apple.security.device.camera", "com.apple.security.device.bluetooth" });
    defer a.free(ent);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ent, "com.apple.security.device.audio-input"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ent, "com.apple.security.device.camera"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, ent, "<key>com.apple.security.device.bluetooth</key>\n\t<true/>"));
    try std.testing.expectError(error.InvalidEntitlement, generateEntitlements(a, &.{}, &.{"a<b"}));
    try std.testing.expect(std.mem.indexOf(u8, ent, "com.apple.security.device.camera") != null);
    try std.testing.expect(std.mem.endsWith(u8, xml, "</dict>\n</plist>\n"));

    const plain = try generateInfoPlist(a, .{ .id = "x.y", .name = "Y", .exe_name = "y", .version = "1", .min_os = "13.0" });
    defer a.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "CFBundleURLTypes") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "UsageDescription") == null);
}

test "generateInfoPlist: extra usage keys, one entry per key" {
    const a = std.testing.allocator;
    const xml = try generateInfoPlist(a, .{
        .id = "x.y",
        .name = "Y",
        .exe_name = "y",
        .version = "1",
        .min_os = "13.0",
        .permissions = &.{
            .{ .kind = "microphone", .reason = "Y uses the microphone" },
            .{ .kind = "bluetooth", .reason = "Y uses Bluetooth" },
        },
        .usage_descriptions = &.{
            .{ .key = "NSMotionUsageDescription", .text = "Counts steps & <stairs>" },
            // A permission's key: the extra's text, in the permission's place.
            .{ .key = "NSSpeechRecognitionUsageDescription", .text = "first" },
            .{ .key = "NSSpeechRecognitionUsageDescription", .text = "Transcribes notes" },
            .{ .key = "NSMotionUsageDescription", .text = "Counts steps" },
        },
    });
    defer a.free(xml);
    const expected =
        "\t<key>NSMicrophoneUsageDescription</key>\n\t<string>Y uses the microphone</string>\n" ++
        "\t<key>NSSpeechRecognitionUsageDescription</key>\n\t<string>Transcribes notes</string>\n" ++
        "\t<key>NSBluetoothAlwaysUsageDescription</key>\n\t<string>Y uses Bluetooth</string>\n" ++
        "\t<key>NSMotionUsageDescription</key>\n\t<string>Counts steps</string>\n";
    try std.testing.expect(std.mem.indexOf(u8, xml, expected) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, xml, "NSMotionUsageDescription"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, xml, "NSSpeechRecognitionUsageDescription"));

    // Escaped text; keys must be usage keys plists can carry as is.
    const escaped = try generateInfoPlist(a, .{ .id = "x.y", .name = "Y", .exe_name = "y", .version = "1", .min_os = "13.0", .usage_descriptions = &.{
        .{ .key = "NSMotionUsageDescription", .text = "Steps & <stairs>" },
    } });
    defer a.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "<string>Steps &amp; &lt;stairs&gt;</string>") != null);
    const base: PlistOptions = .{ .id = "x.y", .name = "Y", .exe_name = "y", .version = "1", .min_os = "13.0" };
    for ([_][]const u8{ "CFBundleIdentifier", "NS<Motion>UsageDescription", "UsageDescription\"", "" }) |bad| {
        var o = base;
        o.usage_descriptions = &.{.{ .key = bad, .text = "x" }};
        try std.testing.expectError(error.InvalidUsageKey, generateInfoPlist(a, o));
    }
    var o = base;
    o.usage_descriptions = &.{.{ .key = "NSMotionUsageDescription", .text = "" }};
    try std.testing.expectError(error.InvalidPlistValue, generateInfoPlist(a, o));
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

// --- Deployment target (Mach-O LC_BUILD_VERSION) -------------------------------------

/// A macOS version from a Mach-O load command (`xxxx.yy.zz` nibbles).
pub const OsVersion = struct {
    major: u16,
    minor: u8,
    patch: u8,

    fn fromPacked(v: u32) OsVersion {
        return .{ .major = @intCast(v >> 16), .minor = @truncate(v >> 8), .patch = @truncate(v) };
    }

    pub fn order(a: OsVersion, b: OsVersion) std.math.Order {
        if (a.major != b.major) return std.math.order(a.major, b.major);
        if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
        return std.math.order(a.patch, b.patch);
    }

    /// "13.0", or "13.0.1" when there is a patch level.
    pub fn format(self: OsVersion, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}", .{ self.major, self.minor });
        if (self.patch != 0) try w.print(".{d}", .{self.patch});
    }
};

const lc_build_version = 0x32;
const lc_version_min_macosx = 0x24;
const platform_macos = 1;

/// The minimum macOS a Mach-O file declares (LC_BUILD_VERSION, or the older
/// LC_VERSION_MIN_MACOSX), from the start of the file (`head`: the header and
/// load commands). A universal file: its first slice. Null when `head` isn't
/// a Mach-O file or declares none.
pub fn machoMinOs(head: []const u8) ?OsVersion {
    if (head.len < 8) return null;
    const fat_magic = std.mem.readInt(u32, head[0..4], .big);
    if (fat_magic == 0xcafebabe or fat_magic == 0xcafebabf) {
        // fat_header, then fat_arch (32-bit offsets) / fat_arch_64.
        if (std.mem.readInt(u32, head[4..8], .big) == 0) return null;
        const off: usize = if (fat_magic == 0xcafebabe) blk: {
            if (head.len < 8 + 20) return null;
            break :blk std.mem.readInt(u32, head[16..20], .big);
        } else blk: {
            if (head.len < 8 + 32) return null;
            break :blk std.math.cast(usize, std.mem.readInt(u64, head[16..24], .big)) orelse return null;
        };
        // A slice starts past the fat header, and isn't itself fat.
        if (off < 8 or off >= head.len) return null;
        const slice = head[off..];
        if (slice.len >= 4 and (std.mem.readInt(u32, slice[0..4], .big) & 0xfffffffe) == 0xcafebabe) return null;
        return machoMinOs(slice);
    }
    const magic = std.mem.readInt(u32, head[0..4], .little);
    const header_size: usize = switch (magic) {
        0xfeedfacf => 32, // 64-bit
        0xfeedface => 28,
        else => return null,
    };
    if (head.len < header_size) return null;
    const ncmds = std.mem.readInt(u32, head[16..20], .little);
    var off = header_size;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        if (off + 8 > head.len) return null;
        const cmd = std.mem.readInt(u32, head[off..][0..4], .little);
        const size = std.mem.readInt(u32, head[off + 4 ..][0..4], .little);
        if (size < 8 or size > head.len - off) return null;
        if (cmd == lc_build_version and size >= 16) {
            if (std.mem.readInt(u32, head[off + 8 ..][0..4], .little) == platform_macos)
                return .fromPacked(std.mem.readInt(u32, head[off + 12 ..][0..4], .little));
        } else if (cmd == lc_version_min_macosx and size >= 16) {
            return .fromPacked(std.mem.readInt(u32, head[off + 8 ..][0..4], .little));
        }
        off += size;
    }
    return null;
}

test machoMinOs {
    // mach_header_64 + LC_SEGMENT-ish filler + LC_BUILD_VERSION(macOS, 13.0).
    var buf: [32 + 16 + 24]u8 = @splat(0);
    std.mem.writeInt(u32, buf[0..4], 0xfeedfacf, .little);
    std.mem.writeInt(u32, buf[16..20], 2, .little); // ncmds
    std.mem.writeInt(u32, buf[32..36], 0x19, .little); // some other command
    std.mem.writeInt(u32, buf[36..40], 16, .little);
    std.mem.writeInt(u32, buf[48..52], lc_build_version, .little);
    std.mem.writeInt(u32, buf[52..56], 24, .little);
    std.mem.writeInt(u32, buf[56..60], platform_macos, .little);
    std.mem.writeInt(u32, buf[60..64], 0x000d0000, .little); // 13.0
    const v = machoMinOs(&buf).?;
    try std.testing.expectEqual(@as(u16, 13), v.major);
    try std.testing.expectEqual(@as(u8, 0), v.minor);
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("13.0", try std.fmt.bufPrint(&out, "{f}", .{v}));
    std.mem.writeInt(u32, buf[60..64], 0x001a0602, .little); // 26.6.2
    try std.testing.expectEqualStrings("26.6.2", try std.fmt.bufPrint(&out, "{f}", .{machoMinOs(&buf).?}));
    try std.testing.expect(machoMinOs(&buf).?.order(v) == .gt);
    // A fat header whose slice points at itself (or at another fat header).
    var fat: [48]u8 = @splat(0);
    std.mem.writeInt(u32, fat[0..4], 0xcafebabe, .big);
    std.mem.writeInt(u32, fat[4..8], 1, .big);
    std.mem.writeInt(u32, fat[16..20], 0, .big);
    try std.testing.expect(machoMinOs(&fat) == null);
    // Not Mach-O / truncated.
    try std.testing.expect(machoMinOs("#!/bin/sh\n") == null);
    try std.testing.expect(machoMinOs(buf[0..40]) == null);
}

test "document types: MIME types as UTIs, once each" {
    const gpa = std.testing.allocator;
    const plist = try generateInfoPlist(gpa, .{
        .id = "dev.oriel.Share",
        .name = "Share",
        .exe_name = "share",
        .version = "1.0",
        .min_os = "13.0",
        .document_types = &.{ "image/*", "image/png", "text/plain", "*/*", "image/x-unknown", "nonsense" },
    });
    defer gpa.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleDocumentTypes</key>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>Alternate</string>") != null);
    for ([_][]const u8{ "public.image", "public.png", "public.plain-text", "public.data" }) |u| {
        const tag = try std.fmt.allocPrint(gpa, "<string>{s}</string>", .{u});
        defer gpa.free(tag);
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, plist, tag));
    }
    const none = try generateInfoPlist(gpa, .{ .id = "a.b", .name = "n", .exe_name = "n", .version = "1", .min_os = "13.0" });
    defer gpa.free(none);
    try std.testing.expect(std.mem.indexOf(u8, none, "CFBundleDocumentTypes") == null);
}
