//! The declared permissions and the webview's gate (internal: App.run sets
//! the declared set, the platforms' window code asks `allowForPage`; apps
//! use `oriel.permissions`, core/permissions.zig).

const std = @import("std");
const builtin = @import("builtin");
const common = @import("common.zig");
pub const Kind = common.Kind;
const Declared = common.Declared;

const log_scoped = std.log.scoped(.permissions);
/// Denials are expected in tests; the test runner fails on logged warnings.
const log = struct {
    fn warn(comptime fmt: []const u8, args: anytype) void {
        if (!builtin.is_test) log_scoped.warn(fmt, args);
    }
};

/// What the app declares (main thread writes it once, at start).
pub var declared_set: Declared = .{};

/// Set by App.run from the app's config.
pub fn setDeclared(d: Declared) void {
    declared_set = d;
}

/// Whether the webview may grant a page's request for `kind`: the app
/// declared it, and the page is the app's own (`local`) or an origin with a
/// capability allowing the `permissions:webview` command.
pub fn allowForPage(kind: Kind, local: @import("../security.zig").Local, page_url: []const u8) bool {
    if (!declared_set.has(kind)) {
        log.warn("page {s} asked for '{s}', which the app doesn't declare: denied", .{ page_url, @tagName(kind) });
        return false;
    }
    const internal = @import("../internal.zig");
    const security = @import("../security.zig");
    if (!security.commandAllowed(internal.current_security, local, page_url, "permissions:webview")) {
        log.warn("page {s} asked for '{s}' but its origin is not allowed: denied", .{ page_url, @tagName(kind) });
        return false;
    }
    return true;
}

test allowForPage {
    const security = @import("../security.zig");
    const internal = @import("../internal.zig");
    setDeclared(.{ .microphone = "" });
    defer setDeclared(.{});
    const saved = internal.current_security;
    defer internal.current_security = saved;
    internal.current_security = .{ .capabilities = &.{.{ .origin = "https://partner.example" }} };
    const local: security.Local = .{};
    try std.testing.expect(allowForPage(.microphone, local, security.app_origin ++ "/index.html"));
    try std.testing.expect(allowForPage(.microphone, local, "https://partner.example/call"));
    try std.testing.expect(!allowForPage(.microphone, local, "https://evil.example/"));
    try std.testing.expect(!allowForPage(.camera, local, security.app_origin ++ "/index.html"));
}
