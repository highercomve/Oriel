//! Webview security policy, modeled on Tauri's:
//!
//! - **Navigation**: the webview may only show the app's own pages (`app://app`,
//!   plus the dev server in dev builds) and origins listed in
//!   `allowed_origins` / `capabilities`. Anything else is blocked; http(s),
//!   mailto and tel links clicked by the user open in the system browser
//!   (configurable).
//! - **IPC scope** (Tauri "capabilities"): the app's own pages may call every
//!   command. A remote origin may call commands only if a capability lists
//!   it, and only the commands that capability names.
//! - **Bridge injection**: `window.oriel` only exists on pages allowed to
//!   use IPC.
//! - **CSP**: a Content-Security-Policy header on every `app://` response.
//!
//! Origins are `scheme://host[:port]`; a host may start with `*.` to match
//! any subdomain (`https://*.example.com`).

const builtin = @import("builtin");
const std = @import("std");

pub const Security = struct {
    /// Content-Security-Policy for `app://` responses; null disables it.
    csp: ?[]const u8 = default_csp,
    /// Extra origins the webview may navigate to. Pages there get no IPC
    /// access unless a capability grants it.
    allowed_origins: []const []const u8 = &.{},
    /// Remote origins allowed to call commands (navigation to them is allowed too).
    capabilities: []const Capability = &.{},
    /// What happens to links pointing outside the allowed origins.
    external_links: ExternalLinks = .open_in_browser,
};

pub const Capability = struct {
    origin: []const u8,
    /// Commands this origin may call; null = all of them.
    commands: ?[]const []const u8 = null,
    /// Windows allowed to use this capability; null = all windows.
    windows: ?[]const []const u8 = null,
};

pub const ExternalLinks = enum {
    /// User-initiated http(s)/mailto/tel navigations open in the default app.
    open_in_browser,
    /// Blocked silently.
    deny,
};

/// Strict by default: only the app's own scripts, no eval, no inline
/// scripts, no plugins, no framing. Inline styles are allowed because most
/// UI libraries rely on them. Loopback http is allowed for the media server.
pub const default_csp = "default-src 'self'; " ++
    "script-src 'self'; " ++
    "style-src 'self' 'unsafe-inline'; " ++
    "img-src 'self' data: blob: http://127.0.0.1:*; " ++
    "media-src 'self' blob: http://127.0.0.1:*; " ++
    "font-src 'self' data:; " ++
    "connect-src 'self' http://127.0.0.1:*; " ++
    "object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'";

pub const app_origin = if (builtin.os.tag == .windows) "https://app.localhost" else "app://app";

/// `scheme://host[:port]` of `url`, lowercased scheme/host, default ports
/// dropped. Returns null for URLs without an authority (about:, data:, …).
pub fn origin(buf: []u8, url: []const u8) ?[]const u8 {
    const uri = std.Uri.parse(url) catch return null;
    const host_component = uri.host orelse return null;
    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = host_component.toRaw(&host_buf) catch return null;
    const default_port: ?u16 = if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) 80 else if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) 443 else null;
    const port = if (uri.port != null and uri.port != default_port) uri.port else null;
    var w: std.Io.Writer = .fixed(buf);
    for (uri.scheme) |c| w.writeByte(std.ascii.toLower(c)) catch return null;
    w.writeAll("://") catch return null;
    for (host) |c| w.writeByte(std.ascii.toLower(c)) catch return null;
    if (port) |p| w.print(":{d}", .{p}) catch return null;
    return w.buffered();
}

/// Whether `actual` (an origin) matches `pattern` (an origin, optionally with
/// a `*.` host wildcard).
pub fn originMatches(pattern: []const u8, actual: []const u8) bool {
    var pbuf: [512]u8 = undefined;
    const p = origin(&pbuf, pattern) orelse pattern;
    const sep = std.mem.indexOf(u8, p, "://*.") orelse return std.ascii.eqlIgnoreCase(p, actual);
    // https://*.example.com matches https://a.example.com and https://example.com
    const scheme = p[0 .. sep + 3];
    const suffix = p[sep + 5 ..];
    if (!std.ascii.startsWithIgnoreCase(actual, scheme)) return false;
    const host = actual[scheme.len..];
    return std.ascii.eqlIgnoreCase(host, suffix) or
        (host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix) and host[host.len - suffix.len - 1] == '.');
}

/// The app's own origins: `app://app` and, in dev builds, the dev server.
pub const Local = struct {
    dev_origin: ?[]const u8 = null,

    pub fn contains(self: Local, o: []const u8) bool {
        if (std.mem.eql(u8, o, app_origin)) return true;
        if (self.dev_origin) |d| return std.mem.eql(u8, o, d);
        return false;
    }
};

pub const Navigation = enum { allow, open_external, block };

pub fn navigation(sec: Security, local: Local, url: []const u8, user_gesture: bool) Navigation {
    if (std.mem.eql(u8, url, "about:blank") or std.mem.startsWith(u8, url, "about:srcdoc")) return .allow;
    var buf: [512]u8 = undefined;
    if (origin(&buf, url)) |o| {
        if (local.contains(o)) return .allow;
        for (sec.allowed_origins) |p| if (originMatches(p, o)) return .allow;
        for (sec.capabilities) |c| if (originMatches(c.origin, o)) return .allow;
    }
    if (sec.external_links == .open_in_browser and user_gesture and isExternalScheme(url)) return .open_external;
    return .block;
}

/// Whether a page at `page_url` may call `command`, optionally scoping by window label.
pub fn commandAllowedForWindow(sec: Security, local: Local, page_url: []const u8, command: []const u8, window_label: ?[]const u8) bool {
    var buf: [512]u8 = undefined;
    const o = origin(&buf, page_url) orelse return false;
    if (local.contains(o)) return true;
    for (sec.capabilities) |c| {
        if (!originMatches(c.origin, o)) continue;
        if (c.windows) |allowed_windows| {
            const w = window_label orelse return false;
            var win_match = false;
            for (allowed_windows) |aw| {
                if (std.mem.eql(u8, aw, w)) {
                    win_match = true;
                    break;
                }
            }
            if (!win_match) continue;
        }
        const cmds = c.commands orelse return true;
        for (cmds) |allowed| if (std.mem.eql(u8, allowed, command)) return true;
    }
    return false;
}

/// Whether a page at `page_url` may call `command`.
pub fn commandAllowed(sec: Security, local: Local, page_url: []const u8, command: []const u8) bool {
    return commandAllowedForWindow(sec, local, page_url, command, null);
}

fn isExternalScheme(url: []const u8) bool {
    inline for (.{ "http://", "https://", "mailto:", "tel:" }) |s| {
        if (std.ascii.startsWithIgnoreCase(url, s)) return true;
    }
    return false;
}

/// WebKit user-script URL patterns (`scheme://host/*`) for the pages that
/// get the `window.oriel` bridge. Match patterns can't express ports, so a
/// port is dropped here; `commandAllowed` still checks the exact origin on
/// every call.
pub fn bridgePatterns(comptime sec: Security, comptime dev_url: ?[]const u8) []const [:0]const u8 {
    comptime {
        var list: []const [:0]const u8 = &.{app_origin ++ "/*"};
        if (dev_url) |u| list = list ++ .{matchPattern(u)};
        for (sec.capabilities) |c| list = list ++ .{matchPattern(c.origin)};
        return list;
    }
}

fn matchPattern(comptime url: []const u8) [:0]const u8 {
    comptime {
        var buf: [512]u8 = undefined;
        const o = origin(&buf, url) orelse url; // wildcard origins pass through
        const host_start = std.mem.indexOf(u8, o, "://").? + 3;
        const port_sep = std.mem.lastIndexOfScalar(u8, o, ':');
        const without_port = if (port_sep != null and port_sep.? > host_start) o[0..port_sep.?] else o;
        return toZ(without_port ++ "/*");
    }
}

fn toZ(comptime s: []const u8) [:0]const u8 {
    return (s ++ "\x00")[0..s.len :0];
}

test origin {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("app://app", origin(&buf, "app://app/index.html?x=1").?);
    try std.testing.expectEqualStrings("http://localhost:5173", origin(&buf, "http://localhost:5173/src/main.tsx").?);
    try std.testing.expectEqualStrings("https://example.com", origin(&buf, "HTTPS://Example.COM:443/a").?);
    try std.testing.expectEqualStrings("http://127.0.0.1:8080", origin(&buf, "http://127.0.0.1:8080").?);
    try std.testing.expect(origin(&buf, "about:blank") == null);
    try std.testing.expect(origin(&buf, "data:text/html,hi") == null);
}

test originMatches {
    try std.testing.expect(originMatches("https://example.com", "https://example.com"));
    try std.testing.expect(!originMatches("https://example.com", "http://example.com"));
    try std.testing.expect(originMatches("https://*.example.com", "https://api.example.com"));
    try std.testing.expect(originMatches("https://*.example.com", "https://example.com"));
    try std.testing.expect(!originMatches("https://*.example.com", "https://badexample.com"));
    try std.testing.expect(!originMatches("https://*.example.com", "https://example.com.evil.io"));
}

test navigation {
    const sec: Security = .{
        .allowed_origins = &.{"https://docs.example.com"},
        .capabilities = &.{.{ .origin = "https://*.trusted.dev" }},
    };
    const local: Local = .{ .dev_origin = "http://localhost:5173" };
    try std.testing.expectEqual(Navigation.allow, navigation(sec, local, "app://app/settings", false));
    try std.testing.expectEqual(Navigation.allow, navigation(sec, local, "http://localhost:5173/", false));
    try std.testing.expectEqual(Navigation.allow, navigation(sec, local, "https://docs.example.com/guide", false));
    try std.testing.expectEqual(Navigation.allow, navigation(sec, local, "https://x.trusted.dev/", false));
    try std.testing.expectEqual(Navigation.allow, navigation(sec, local, "about:blank", false));
    try std.testing.expectEqual(Navigation.open_external, navigation(sec, local, "https://evil.example/", true));
    try std.testing.expectEqual(Navigation.block, navigation(sec, local, "https://evil.example/", false)); // scripted redirect
    try std.testing.expectEqual(Navigation.block, navigation(sec, local, "file:///etc/passwd", true));
    try std.testing.expectEqual(Navigation.block, navigation(sec, local, "data:text/html,<script>", true));
    try std.testing.expectEqual(Navigation.block, navigation(.{ .external_links = .deny }, .{}, "https://evil.example/", true));
}

test commandAllowed {
    const sec: Security = .{
        .allowed_origins = &.{"https://docs.example.com"},
        .capabilities = &.{
            .{ .origin = "https://partner.example", .commands = &.{"greet"} },
            .{ .origin = "https://*.trusted.dev" },
        },
    };
    const local: Local = .{};
    try std.testing.expect(commandAllowed(sec, local, "app://app/", "delete_all"));
    try std.testing.expect(commandAllowed(sec, local, "https://partner.example/page", "greet"));
    try std.testing.expect(!commandAllowed(sec, local, "https://partner.example/page", "delete_all"));
    try std.testing.expect(commandAllowed(sec, local, "https://a.trusted.dev/", "delete_all"));
    try std.testing.expect(!commandAllowed(sec, local, "https://docs.example.com/", "greet")); // navigable, no IPC
    try std.testing.expect(!commandAllowed(sec, local, "http://localhost:5173/", "greet")); // not a dev build
    try std.testing.expect(!commandAllowed(sec, local, "about:blank", "greet"));

    const sec_win: Security = .{
        .capabilities = &.{
            .{ .origin = "https://partner.example", .commands = &.{"greet"}, .windows = &.{"main"} },
        },
    };
    try std.testing.expect(commandAllowedForWindow(sec_win, local, "https://partner.example/page", "greet", "main"));
    try std.testing.expect(!commandAllowedForWindow(sec_win, local, "https://partner.example/page", "greet", "settings"));
    try std.testing.expect(!commandAllowedForWindow(sec_win, local, "https://partner.example/page", "greet", null));
}

test bridgePatterns {
    const patterns = comptime bridgePatterns(.{ .capabilities = &.{.{ .origin = "https://partner.example" }} }, "http://localhost:5173/");
    try std.testing.expectEqual(3, patterns.len);
    try std.testing.expectEqualStrings("app://app/*", patterns[0]);
    try std.testing.expectEqualStrings("http://localhost/*", patterns[1]);
    try std.testing.expectEqualStrings("https://partner.example/*", patterns[2]);
}
