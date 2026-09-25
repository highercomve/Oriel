//! OS permissions (microphone, camera, screen capture, accessibility,
//! location, notifications, system audio): declared once in `build.zig`,
//! written into each platform's package (Info.plist usage keys on macOS),
//! queried and requested here, and enforced for the webview's own requests
//! (getUserMedia, geolocation, notifications).
//!
//! Backends: Linux (not gated; portals ask on use), Windows (privacy
//! settings), macOS (TCC: AVCaptureDevice, CGPreflightScreenCaptureAccess,
//! AXIsProcessTrusted, ...).

const std = @import("std");
const builtin = @import("builtin");
pub const common = @import("permissions/common.zig");

pub const Kind = common.Kind;
pub const Status = common.Status;
pub const Declared = common.Declared;
pub const parseKind = common.parseKind;

const log_scoped = std.log.scoped(.permissions);
/// Denials are expected in tests; the test runner fails on logged warnings.
const log = struct {
    fn warn(comptime fmt: []const u8, args: anytype) void {
        if (!builtin.is_test) log_scoped.warn(fmt, args);
    }
};

pub const impl = switch (builtin.os.tag) {
    .linux => @import("permissions/linux.zig"),
    .windows => @import("permissions/windows.zig"),
    .macos => @import("permissions/macos.zig"),
    else => @compileError("permissions are not supported on " ++ @tagName(builtin.os.tag)),
};

var declared_set: Declared = .{};
var on_change: ?*const fn (Kind, Status) void = null;

/// Set by App.run from the app's config.
pub fn setDeclared(d: Declared) void {
    declared_set = d;
}

pub fn declared() Declared {
    return declared_set;
}

/// Called (on any thread) when a `request` resolves. The page also gets a
/// `permission-changed` event with `{ name, status }`.
pub fn onChange(callback: ?*const fn (Kind, Status) void) void {
    on_change = callback;
}

/// Current status. An undeclared permission is `denied`: on macOS, using one
/// without its Info.plist key would terminate the app.
pub fn status(kind: Kind) Status {
    if (!declared_set.has(kind)) return .denied;
    return impl.status(kind);
}

/// Ask the user when the OS allows asking ahead of use. The result arrives
/// through `onChange` and the `permission-changed` event; returns the status
/// at the time of the call (`prompt` while the OS dialog is open).
pub fn request(kind: Kind) Status {
    if (!declared_set.has(kind)) {
        log.warn("permission '{s}' requested but not declared: add `.permissions = .{{ .{s} = \"why\" }}` to addApp in build.zig (or `oriel permission add {s}`)", .{ @tagName(kind), @tagName(kind), @tagName(kind) });
        resolved(kind, .denied);
        return .denied;
    }
    const before = impl.status(kind);
    if (before == .granted or before == .denied) {
        resolved(kind, before);
        return before;
    }
    impl.request(kind, &resolved);
    return before;
}

/// Open the OS settings page for `kind`. False when there is none, or when
/// the app doesn't declare `kind` (no settings entry could exist for it).
pub fn openSettings(kind: Kind) bool {
    if (!declared_set.has(kind)) return false;
    return impl.openSettings(kind);
}

fn resolved(kind: Kind, s: Status) void {
    if (on_change) |cb| cb(kind, s);
    const App = @import("App.zig");
    App.emit("permission-changed", .{ .name = @tagName(kind), .status = @tagName(s) });
}

/// Whether the webview may grant a page's request for `kind`: the app
/// declared it, and the page is the app's own (`local`) or an origin with a
/// capability allowing the `permissions:webview` command.
pub fn allowForPage(kind: Kind, local: @import("security.zig").Local, page_url: []const u8) bool {
    if (!declared_set.has(kind)) {
        log.warn("page {s} asked for '{s}', which the app doesn't declare: denied", .{ page_url, @tagName(kind) });
        return false;
    }
    const App = @import("App.zig");
    const security = @import("security.zig");
    if (!security.commandAllowed(App.current_security, local, page_url, "permissions:webview")) {
        log.warn("page {s} asked for '{s}' but its origin is not allowed: denied", .{ page_url, @tagName(kind) });
        return false;
    }
    return true;
}

/// Smoke check: every status query answers (and never prompts).
pub fn check(gpa: std.mem.Allocator) !@import("../oriel.zig").Check {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (std.enums.values(Kind), 0..) |k, i| {
        const s = if (declared_set.has(k)) impl.status(k) else Status.denied;
        try out.writer.print("{s}{s}={s}", .{ if (i == 0) "" else " ", @tagName(k), @tagName(s) });
    }
    return .{ .module = "permissions", .ok = true, .detail = try out.toOwnedSlice() };
}

test {
    std.testing.refAllDecls(common);
}

test "undeclared permissions are denied" {
    setDeclared(.{ .microphone = "" });
    defer setDeclared(.{});
    try std.testing.expectEqual(Status.denied, status(.camera));
    try std.testing.expect(status(.microphone) != .denied or builtin.os.tag != .linux);
}

test allowForPage {
    const security = @import("security.zig");
    const App = @import("App.zig");
    setDeclared(.{ .microphone = "" });
    defer setDeclared(.{});
    const saved = App.current_security;
    defer App.current_security = saved;
    App.current_security = .{ .capabilities = &.{.{ .origin = "https://partner.example" }} };
    const local: security.Local = .{};
    try std.testing.expect(allowForPage(.microphone, local, security.app_origin ++ "/index.html"));
    try std.testing.expect(allowForPage(.microphone, local, "https://partner.example/call"));
    try std.testing.expect(!allowForPage(.microphone, local, "https://evil.example/"));
    try std.testing.expect(!allowForPage(.camera, local, security.app_origin ++ "/index.html"));
}
