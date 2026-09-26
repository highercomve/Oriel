//! Windows: the privacy settings (Settings > Privacy & security) gate the
//! microphone, camera and location for desktop apps; nothing prompts, so the
//! status is always granted or denied. Screen capture, input (accessibility)
//! and system audio aren't gated for Win32 apps. Notifications (balloons,
//! shown as toasts) follow the global "Notifications" switch.
//!
//! The consent store (HKCU\Software\Microsoft\Windows\CurrentVersion\
//! CapabilityAccessManager\ConsentStore\<capability>) holds a "Value" of
//! Allow/Deny per switch:
//! - `<capability>`: "<Microphone> access" for this user,
//! - `<capability>\NonPackaged`: "Let desktop apps access your <microphone>",
//! - the same key in HKLM: the device-wide switch.
//! A group policy (HKLM\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy,
//! LetAppsAccess<X> = 2) forces a deny.

const std = @import("std");
const common = @import("common.zig");
const win32 = @import("../../platform/windows/win32.zig");

/// A consent-store switch: "Allow", "Deny", or missing (never set).
pub const Switch = enum { allow, deny, unset };

pub const Consent = struct {
    user: Switch = .unset,
    desktop_apps: Switch = .unset,
    device: Switch = .unset,
    /// AppPrivacy policy: 0 user decides, 1 force allow, 2 force deny.
    policy: ?u32 = null,
};

/// Any switch off (or a force-deny policy) denies; otherwise desktop apps
/// may use it. A force-allow policy wins over the user's switches, as in
/// Windows.
pub fn decide(c: Consent) common.Status {
    if (c.policy) |p| switch (p) {
        1 => return .granted,
        2 => return .denied,
        else => {},
    };
    if (c.device == .deny or c.user == .deny or c.desktop_apps == .deny) return .denied;
    return .granted;
}

pub fn parseSwitch(value: []const u8) Switch {
    if (std.ascii.eqlIgnoreCase(value, "Allow")) return .allow;
    if (std.ascii.eqlIgnoreCase(value, "Deny")) return .deny;
    return .unset;
}

/// Notifications: ToastEnabled = 0 turns them off for every app.
pub fn decideNotifications(toast_enabled: ?u32) common.Status {
    return if (toast_enabled == 0) .denied else .granted;
}

const Capability = struct {
    /// ConsentStore key name.
    store: []const u8,
    /// AppPrivacy policy value name.
    policy: []const u8,
};

fn capability(kind: common.Kind) ?Capability {
    return switch (kind) {
        .microphone => .{ .store = "microphone", .policy = "LetAppsAccessMicrophone" },
        .camera => .{ .store = "webcam", .policy = "LetAppsAccessCamera" },
        .location => .{ .store = "location", .policy = "LetAppsAccessLocation" },
        else => null,
    };
}

pub fn status(kind: common.Kind) common.Status {
    if (capability(kind)) |cap| return decide(readConsent(cap));
    return switch (kind) {
        .notifications => decideNotifications(readDword(win32.HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications", "ToastEnabled")),
        .screen_capture, .accessibility, .system_audio => .granted,
        .microphone, .camera, .location => unreachable,
    };
}

/// Nothing prompts on Windows: the result is the current status.
pub fn request(kind: common.Kind, done: *const fn (common.Kind, common.Status) void) void {
    done(kind, status(kind));
}

/// The Settings page with the switch for `kind`.
pub fn openSettings(kind: common.Kind) bool {
    const uri = settingsUri(kind) orelse return false;
    const r = win32.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), uri, null, null, win32.SW_SHOWNORMAL) orelse return false;
    // ShellExecute returns a value > 32 on success.
    return @intFromPtr(r) > 32;
}

fn settingsUri(kind: common.Kind) ?[*:0]const u16 {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    return switch (kind) {
        .microphone => L("ms-settings:privacy-microphone"),
        .camera => L("ms-settings:privacy-webcam"),
        .location => L("ms-settings:privacy-location"),
        .notifications => L("ms-settings:notifications"),
        .screen_capture, .accessibility, .system_audio => null,
    };
}

const consent_root = "Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\";

fn readConsent(cap: Capability) Consent {
    var key_buf: [192]u8 = undefined;
    const user_key = std.fmt.bufPrint(&key_buf, consent_root ++ "{s}", .{cap.store}) catch return .{};
    var c: Consent = .{
        .user = readSwitch(win32.HKEY_CURRENT_USER, user_key),
        .device = readSwitch(win32.HKEY_LOCAL_MACHINE, user_key),
        .policy = readDword(win32.HKEY_LOCAL_MACHINE, "SOFTWARE\\Policies\\Microsoft\\Windows\\AppPrivacy", cap.policy),
    };
    var np_buf: [224]u8 = undefined;
    const np_key = std.fmt.bufPrint(&np_buf, "{s}\\NonPackaged", .{user_key}) catch return c;
    c.desktop_apps = readSwitch(win32.HKEY_CURRENT_USER, np_key);
    return c;
}

fn readSwitch(root: win32.HKEY, sub_key: []const u8) Switch {
    var buf: [32]u16 = undefined;
    const n = readValue(root, sub_key, "Value", std.mem.sliceAsBytes(&buf)) orelse return .unset;
    var chars: []const u16 = buf[0 .. n / 2];
    if (chars.len > 0 and chars[chars.len - 1] == 0) chars = chars[0 .. chars.len - 1];
    var text: [32]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&text, chars) catch return .unset;
    return parseSwitch(text[0..len]);
}

fn readDword(root: win32.HKEY, sub_key: []const u8, name: []const u8) ?u32 {
    var buf: [4]u8 = undefined;
    const n = readValue(root, sub_key, name, &buf) orelse return null;
    if (n != 4) return null;
    return std.mem.readInt(u32, &buf, .little);
}

/// The raw data of `root\sub_key` value `name` in `out`; its length, or null
/// when the key or value is missing (or doesn't fit).
fn readValue(root: win32.HKEY, sub_key: []const u8, name: []const u8, out: []u8) ?usize {
    var key_w: [256:0]u16 = undefined;
    const key_len = std.unicode.utf8ToUtf16Le(&key_w, sub_key) catch return null;
    key_w[key_len] = 0;
    var name_w: [64:0]u16 = undefined;
    const name_len = std.unicode.utf8ToUtf16Le(&name_w, name) catch return null;
    name_w[name_len] = 0;

    var key: win32.HKEY = undefined;
    if (win32.RegOpenKeyExW(root, &key_w, 0, win32.KEY_READ, &key) != 0) return null;
    defer _ = win32.RegCloseKey(key);
    var size: win32.DWORD = @intCast(out.len);
    if (win32.RegQueryValueExW(key, &name_w, null, null, out.ptr, &size) != 0) return null;
    return size;
}

test decide {
    try std.testing.expectEqual(common.Status.granted, decide(.{}));
    try std.testing.expectEqual(common.Status.granted, decide(.{ .user = .allow, .desktop_apps = .allow, .device = .allow }));
    try std.testing.expectEqual(common.Status.denied, decide(.{ .user = .deny, .desktop_apps = .allow }));
    try std.testing.expectEqual(common.Status.denied, decide(.{ .user = .allow, .desktop_apps = .deny }));
    try std.testing.expectEqual(common.Status.denied, decide(.{ .device = .deny }));
    try std.testing.expectEqual(common.Status.denied, decide(.{ .policy = 2 }));
    try std.testing.expectEqual(common.Status.granted, decide(.{ .user = .deny, .policy = 1 }));
    try std.testing.expectEqual(common.Status.denied, decide(.{ .user = .deny, .policy = 0 }));
}

test parseSwitch {
    try std.testing.expectEqual(Switch.allow, parseSwitch("Allow"));
    try std.testing.expectEqual(Switch.deny, parseSwitch("Deny"));
    try std.testing.expectEqual(Switch.deny, parseSwitch("deny"));
    try std.testing.expectEqual(Switch.unset, parseSwitch("Prompt"));
    try std.testing.expectEqual(Switch.unset, parseSwitch(""));
}

test decideNotifications {
    try std.testing.expectEqual(common.Status.denied, decideNotifications(0));
    try std.testing.expectEqual(common.Status.granted, decideNotifications(1));
    try std.testing.expectEqual(common.Status.granted, decideNotifications(null));
}

test "status reads this machine's settings without prompting" {
    // Whatever the switches say, the answer is decided (never prompt/unknown).
    for (std.enums.values(common.Kind)) |k| {
        const s = status(k);
        try std.testing.expect(s == .granted or s == .denied);
    }
}
