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

pub const WindowApiPolicy = struct {
    /// Whether app-local pages may use the window API.
    enabled: bool = true,
    /// Whether remote origins may use the window API. Default: false.
    allow_remote: bool = false,
    /// Whether windows can load remote URLs (must also be in allowed_origins).
    /// Default: false (only app-local URLs can be opened in new windows).
    allow_remote_urls: bool = false,
    /// Maximum number of concurrently open windows.
    max_windows: usize = 16,
    /// Whether a window may modify/close other windows.
    /// Default: false (a window can only modify/close itself).
    allow_modify_other_windows: bool = false,
};

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
    /// Policy for the window API (`oriel.window`).
    window_api: WindowApiPolicy = .{},
};

pub const Capability = struct {
    origin: []const u8,
    /// Commands this origin may call; null = all of them.
    commands: ?[]const []const u8 = null,
    /// Windows allowed to use this capability; null = all windows.
    windows: ?[]const []const u8 = null,
    /// Whether this remote origin may use the window API. Default: false.
    window_api: bool = false,
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

/// Validate a window label. Labels must be 1..64 characters long and contain
/// only ASCII alphanumeric characters, hyphens ('-'), or underscores ('_').
pub fn validateLabel(label: []const u8) !void {
    if (label.len == 0 or label.len > 64) return error.InvalidLabel;
    for (label) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            return error.InvalidLabel;
        }
    }
}

/// Validate a target URL for a window.
/// App-local URLs (relative paths, or URLs matching local origin) are allowed by default.
/// Remote URLs are only allowed if `sec.window_api.allow_remote_urls` is true and the origin
/// matches `sec.allowed_origins` or `sec.capabilities`.
/// Dangerous schemes (javascript:, file:, data:) are always blocked.
pub fn validateWindowUrl(sec: Security, local: Local, url: ?[]const u8) !void {
    const u = url orelse return;
    if (u.len == 0) return;

    // Check for dangerous schemes
    inline for (.{ "javascript:", "file:", "data:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(u, scheme)) return error.BlockedScheme;
    }

    // Relative URLs (no scheme/authority) are app-local
    const colon_idx = std.mem.indexOfScalar(u8, u, ':');
    const slash_idx = std.mem.indexOfScalar(u8, u, '/');
    const is_relative = if (colon_idx) |c| (slash_idx != null and slash_idx.? < c) else true;
    if (is_relative) return;

    var buf: [512]u8 = undefined;
    const o = origin(&buf, u) orelse return error.InvalidUrl;
    if (local.contains(o)) return;

    // Remote URL
    if (!sec.window_api.allow_remote_urls) return error.RemoteUrlsNotAllowed;

    for (sec.allowed_origins) |p| {
        if (originMatches(p, o)) return;
    }
    for (sec.capabilities) |c| {
        if (originMatches(c.origin, o)) return;
    }

    return error.DisallowedOrigin;
}

/// Validate whether a caller window is permitted to modify/close a target window.
/// A window can always modify itself. Modifying another window requires
/// `sec.window_api.allow_modify_other_windows`.
pub fn validateWindowModification(sec: Security, caller_label: ?[]const u8, target_label: []const u8) !void {
    if (sec.window_api.allow_modify_other_windows) return;
    if (caller_label) |cl| {
        if (std.mem.eql(u8, cl, target_label)) return;
    }
    return error.PermissionDenied;
}

/// Validate whether opening a new window would exceed the maximum windows cap.
pub fn validateWindowCount(sec: Security, current_count: usize) !void {
    if (current_count >= sec.window_api.max_windows) {
        return error.MaxWindowsExceeded;
    }
}

/// Whether the window API is permitted for a page at `page_url`.
pub fn isWindowApiAllowed(sec: Security, local: Local, page_url: []const u8, window_label: ?[]const u8) bool {
    var buf: [512]u8 = undefined;
    const o = origin(&buf, page_url) orelse return false;
    if (local.contains(o)) {
        return sec.window_api.enabled;
    }
    // Remote origin
    if (sec.window_api.allow_remote) return true;
    for (sec.capabilities) |c| {
        if (!c.window_api) continue;
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
        return true;
    }
    return false;
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

test validateLabel {
    try validateLabel("main");
    try validateLabel("test-sec");
    try validateLabel("smoke_child_1");
    try validateLabel("a");
    try validateLabel("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"); // 64 chars

    try std.testing.expectError(error.InvalidLabel, validateLabel(""));
    try std.testing.expectError(error.InvalidLabel, validateLabel("has space"));
    try std.testing.expectError(error.InvalidLabel, validateLabel("bad/slash"));
    try std.testing.expectError(error.InvalidLabel, validateLabel("bad\\backslash"));
    try std.testing.expectError(error.InvalidLabel, validateLabel("bad:colon"));
    try std.testing.expectError(error.InvalidLabel, validateLabel("bad.dot"));
    try std.testing.expectError(error.InvalidLabel, validateLabel("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0")); // 65 chars
}

test validateWindowUrl {
    const sec: Security = .{
        .allowed_origins = &.{"https://docs.example.com"},
        .capabilities = &.{.{ .origin = "https://partner.example" }},
    };
    const local: Local = .{ .dev_origin = "http://localhost:5173" };

    // null / empty / relative paths
    try validateWindowUrl(sec, local, null);
    try validateWindowUrl(sec, local, "");
    try validateWindowUrl(sec, local, "/settings");
    try validateWindowUrl(sec, local, "sub/page.html");

    // Blocked schemes
    try std.testing.expectError(error.BlockedScheme, validateWindowUrl(sec, local, "javascript:alert(1)"));
    try std.testing.expectError(error.BlockedScheme, validateWindowUrl(sec, local, "file:///etc/passwd"));
    try std.testing.expectError(error.BlockedScheme, validateWindowUrl(sec, local, "data:text/html,bad"));

    // App-local absolute URLs
    try validateWindowUrl(sec, local, "app://app/settings");
    try validateWindowUrl(sec, local, "http://localhost:5173/page");

    // Remote URLs with allow_remote_urls = false (default)
    try std.testing.expectError(error.RemoteUrlsNotAllowed, validateWindowUrl(sec, local, "https://docs.example.com/guide"));
    try std.testing.expectError(error.RemoteUrlsNotAllowed, validateWindowUrl(sec, local, "https://evil.example/"));

    // Remote URLs with allow_remote_urls = true
    var sec_remote = sec;
    sec_remote.window_api.allow_remote_urls = true;
    try validateWindowUrl(sec_remote, local, "https://docs.example.com/guide");
    try validateWindowUrl(sec_remote, local, "https://partner.example/");
    try std.testing.expectError(error.DisallowedOrigin, validateWindowUrl(sec_remote, local, "https://evil.example/"));
}

test validateWindowModification {
    const sec_default: Security = .{};
    // Window can modify itself
    try validateWindowModification(sec_default, "main", "main");
    try validateWindowModification(sec_default, "child", "child");

    // Window cannot modify other windows by default
    try std.testing.expectError(error.PermissionDenied, validateWindowModification(sec_default, "child", "main"));
    try std.testing.expectError(error.PermissionDenied, validateWindowModification(sec_default, "main", "child"));
    try std.testing.expectError(error.PermissionDenied, validateWindowModification(sec_default, null, "child"));

    // When allow_modify_other_windows = true
    var sec_allowed = sec_default;
    sec_allowed.window_api.allow_modify_other_windows = true;
    try validateWindowModification(sec_allowed, "main", "child");
    try validateWindowModification(sec_allowed, "child", "main");
    try validateWindowModification(sec_allowed, null, "child");
}

test validateWindowCount {
    var sec: Security = .{};
    sec.window_api.max_windows = 3;

    try validateWindowCount(sec, 0);
    try validateWindowCount(sec, 1);
    try validateWindowCount(sec, 2);
    try std.testing.expectError(error.MaxWindowsExceeded, validateWindowCount(sec, 3));
    try std.testing.expectError(error.MaxWindowsExceeded, validateWindowCount(sec, 4));
}

test isWindowApiAllowed {
    const sec: Security = .{
        .capabilities = &.{
            .{ .origin = "https://partner.example", .window_api = true },
            .{ .origin = "https://scoped.example", .window_api = true, .windows = &.{"main"} },
            .{ .origin = "https://no-win.example", .window_api = false },
        },
    };
    const local: Local = .{ .dev_origin = "http://localhost:5173" };

    // Local origins allowed by default
    try std.testing.expect(isWindowApiAllowed(sec, local, "app://app/page", null));
    try std.testing.expect(isWindowApiAllowed(sec, local, "http://localhost:5173/page", null));

    // When window_api.enabled = false
    var sec_disabled = sec;
    sec_disabled.window_api.enabled = false;
    try std.testing.expect(!isWindowApiAllowed(sec_disabled, local, "app://app/page", null));

    // Remote origins off by default unless capability grants window_api
    try std.testing.expect(!isWindowApiAllowed(sec, local, "https://no-win.example/page", null));
    try std.testing.expect(!isWindowApiAllowed(sec, local, "https://unknown.example/page", null));
    try std.testing.expect(isWindowApiAllowed(sec, local, "https://partner.example/page", null));
    try std.testing.expect(isWindowApiAllowed(sec, local, "https://scoped.example/page", "main"));
    try std.testing.expect(!isWindowApiAllowed(sec, local, "https://scoped.example/page", "child"));

    // Global allow_remote
    var sec_remote = sec;
    sec_remote.window_api.allow_remote = true;
    try std.testing.expect(isWindowApiAllowed(sec_remote, local, "https://unknown.example/page", null));
}
