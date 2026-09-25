//! Permission kinds, statuses and the app's declaration (shared by every OS).

const std = @import("std");

/// The OS permissions an app can declare and request.
pub const Kind = enum {
    microphone,
    camera,
    /// Recording the screen (macOS Screen Recording; portals on Wayland).
    screen_capture,
    /// Controlling other apps: synthetic input, reading UI (macOS Accessibility).
    accessibility,
    location,
    notifications,
    /// Recording the audio other apps play (macOS 14.4+ audio capture).
    system_audio,
};

pub const Status = enum {
    /// Allowed, or not gated by this OS.
    granted,
    denied,
    /// Not decided yet: `request` (or the first use) asks the user.
    prompt,
    /// This OS can't report it; the first use may ask.
    unknown,
};

/// What the app declares in `build.zig` (`.permissions = .{ .microphone = "..." }`):
/// each non-null field is a declared permission, its text the reason the OS
/// shows the user ("" uses a default text).
pub const Declared = struct {
    microphone: ?[]const u8 = null,
    camera: ?[]const u8 = null,
    screen_capture: ?[]const u8 = null,
    accessibility: ?[]const u8 = null,
    location: ?[]const u8 = null,
    notifications: ?[]const u8 = null,
    system_audio: ?[]const u8 = null,

    pub fn has(self: Declared, kind: Kind) bool {
        return self.reason(kind) != null;
    }

    /// The declared reason ("" when declared without one), or null.
    pub fn reason(self: Declared, kind: Kind) ?[]const u8 {
        return switch (kind) {
            inline else => |k| @field(self, @tagName(k)),
        };
    }

    /// `defaultReason` by field name (for build scripts).
    pub fn defaultReasonFor(comptime name: []const u8) []const u8 {
        return defaultReason(@field(Kind, name));
    }

    /// The reason to show: the declared text, or the default one.
    pub fn reasonOrDefault(self: Declared, kind: Kind) ?[]const u8 {
        const r = self.reason(kind) orelse return null;
        return if (r.len == 0) defaultReason(kind) else r;
    }
};

/// Default usage text, completed as "<App> <text>".
pub fn defaultReason(kind: Kind) []const u8 {
    return switch (kind) {
        .microphone => "records audio from the microphone.",
        .camera => "uses the camera.",
        .screen_capture => "records the screen.",
        .accessibility => "controls other apps (keyboard input, copy and paste).",
        .location => "uses your location.",
        .notifications => "shows notifications.",
        .system_audio => "records the audio other apps play.",
    };
}

pub fn parseKind(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

test Declared {
    const d: Declared = .{ .microphone = "", .camera = "For video calls" };
    try std.testing.expect(d.has(.microphone));
    try std.testing.expect(!d.has(.location));
    try std.testing.expectEqualStrings(defaultReason(.microphone), d.reasonOrDefault(.microphone).?);
    try std.testing.expectEqualStrings("For video calls", d.reasonOrDefault(.camera).?);
    try std.testing.expect(d.reasonOrDefault(.location) == null);
    try std.testing.expectEqual(Kind.screen_capture, parseKind("screen_capture").?);
    try std.testing.expect(parseKind("nope") == null);
}
