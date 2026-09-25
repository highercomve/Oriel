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
pub const default_open_external_schemes: []const []const u8 = &.{ "http", "https", "mailto" };

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
    /// Allowed URL schemes for openExternal (e.g. "http", "https", "mailto").
    open_external_schemes: []const []const u8 = default_open_external_schemes,
    /// Run `Object.freeze(Object.prototype)` at document start in the top
    /// frame, before any page script (Tauri's `freezePrototype`): blocks
    /// prototype-pollution gadgets. Off by default: some libraries patch
    /// Object.prototype, and with it frozen, assigning an inherited name on
    /// another object (`Foo.prototype.toString = ...`, `.constructor`,
    /// `.valueOf`) throws in strict code (the "override mistake"); use
    /// Object.defineProperty for those.
    freeze_prototype: bool = false,
    /// Extra headers on the app's own successful responses (`app://`
    /// assets and the media scheme), e.g. Cross-Origin-Opener-Policy or
    /// Permissions-Policy. Names are limited to `allowed_header_names`
    /// (Tauri's list), each at most once; values are printable ASCII (and
    /// tabs), at most 2047 bytes. CSP and Content-Type stay Oriel's.
    /// Checked at compile time.
    headers: []const Header = &.{},
};

pub const Header = struct { name: []const u8, value: []const u8 };

/// The response headers an app may set (Tauri's `app.security.headers`).
pub const allowed_header_names = [_][]const u8{
    "Access-Control-Allow-Credentials",
    "Access-Control-Allow-Headers",
    "Access-Control-Allow-Methods",
    "Access-Control-Expose-Headers",
    "Access-Control-Max-Age",
    "Cross-Origin-Embedder-Policy",
    "Cross-Origin-Opener-Policy",
    "Cross-Origin-Resource-Policy",
    "Permissions-Policy",
    "Service-Worker-Allowed",
    "Timing-Allow-Origin",
    "X-Content-Type-Options",
};

pub fn headerNameAllowed(name: []const u8) bool {
    for (allowed_header_names) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// Longest header value accepted (every platform can send it).
pub const max_header_value = 2047;

/// A header value is printable ASCII or tabs, at most `max_header_value`
/// bytes: no CR/LF/NUL (no injection), no other controls, no non-ASCII
/// (every platform encodes it the same way).
pub fn headerValueValid(value: []const u8) bool {
    if (value.len > max_header_value) return false;
    for (value) |ch| if (ch != '\t' and (ch < 0x20 or ch > 0x7E)) return false;
    return true;
}

/// Whether a header from `headers` is sent: allowed name, valid value, and
/// not one Oriel always sends itself.
pub fn headerUsable(h: Header) bool {
    return headerNameAllowed(h.name) and headerValueValid(h.value) and !headerBuiltIn(h.name);
}

/// Compile error for a header an app may not set (App.run calls it).
pub fn checkHeaders(comptime headers: []const Header) void {
    inline for (headers, 0..) |h, i| {
        if (comptime !headerNameAllowed(h.name)) @compileError("security.headers: '" ++ h.name ++ "' is not an allowed header (see security.allowed_header_names; CSP has its own `csp` option)");
        if (comptime !headerValueValid(h.value)) @compileError("security.headers: the value of '" ++ h.name ++ "' must be printable ASCII (or tabs), at most 2047 bytes");
        if (comptime std.ascii.eqlIgnoreCase(h.name, "X-Content-Type-Options") and !std.ascii.eqlIgnoreCase(h.value, "nosniff")) @compileError("security.headers: X-Content-Type-Options is always nosniff");
        inline for (headers[0..i]) |prev| {
            if (comptime std.ascii.eqlIgnoreCase(prev.name, h.name)) @compileError("security.headers: '" ++ h.name ++ "' is set twice");
        }
    }
}

/// Whether Oriel already sends `name` (it isn't repeated from `headers`).
pub fn headerBuiltIn(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "X-Content-Type-Options");
}

/// `Name: value\r\n` for each usable header (Windows builds header blocks
/// as text). Caller frees.
pub fn headerLines(gpa: std.mem.Allocator, headers: []const Header) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (headers) |h| {
        if (!headerUsable(h)) continue;
        try out.writer.print("{s}: {s}\r\n", .{ h.name, h.value });
    }
    return out.toOwnedSlice();
}

/// `headerLines` at compile time (for the config's own headers).
pub fn comptimeHeaderLines(comptime headers: []const Header) []const u8 {
    comptime var out: []const u8 = "";
    inline for (headers) |h| {
        if (comptime headerUsable(h)) out = out ++ h.name ++ ": " ++ h.value ++ "\r\n";
    }
    return out;
}

/// JavaScript run first in every bridged document (top frame only: the
/// Windows script also runs in frames).
pub fn bridgePrelude(comptime sec: Security) []const u8 {
    return if (sec.freeze_prototype) "if (window === window.top) Object.freeze(Object.prototype);\n" else "";
}

test headerLines {
    const a = std.testing.allocator;
    const lines = try headerLines(a, &.{
        .{ .name = "Cross-Origin-Opener-Policy", .value = "same-origin" },
        .{ .name = "X-Content-Type-Options", .value = "nosniff" }, // built in: skipped
        .{ .name = "Set-Cookie", .value = "x=1" }, // not allowed: skipped
        .{ .name = "Permissions-Policy", .value = "camera=()\r\nX: y" }, // injection: skipped
        .{ .name = "Timing-Allow-Origin", .value = "caf\xc3\xa9" }, // non-ASCII: skipped
    });
    defer a.free(lines);
    try std.testing.expectEqualStrings("Cross-Origin-Opener-Policy: same-origin\r\n", lines);
    try std.testing.expectEqualStrings("Cross-Origin-Opener-Policy: same-origin\r\n", comptimeHeaderLines(&.{.{ .name = "Cross-Origin-Opener-Policy", .value = "same-origin" }}));
    try std.testing.expect(headerValueValid("a\tb=()"));
    try std.testing.expect(!headerValueValid("a\x01"));
    try std.testing.expect(!headerValueValid("x" ** (max_header_value + 1)));
    try std.testing.expect(headerNameAllowed("permissions-policy"));
    try std.testing.expect(!headerNameAllowed("Content-Security-Policy"));
    try std.testing.expectEqualStrings("if (window === window.top) Object.freeze(Object.prototype);\n", bridgePrelude(.{ .freeze_prototype = true }));
    try std.testing.expectEqualStrings("", bridgePrelude(.{}));
}

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

fn containsPercentEncodedDot(u: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < u.len) : (i += 1) {
        if (u[i] == '%' and u[i + 1] == '2' and (u[i + 2] == 'e' or u[i + 2] == 'E')) {
            return true;
        }
    }
    return false;
}

/// Validate a target URL for a window.
/// App-local URLs (relative paths, or URLs matching local origin) are allowed by default.
/// Remote URLs are only allowed if `sec.window_api.allow_remote_urls` is true and the origin
/// matches `sec.allowed_origins` or `sec.capabilities`.
/// Dangerous schemes (javascript:, file:, data:) are always blocked.
pub fn validateWindowUrl(sec: Security, local: Local, url: ?[]const u8) !void {
    const u = url orelse return;
    if (u.len == 0) return;

    // Reject backslashes anywhere
    if (std.mem.indexOfScalar(u8, u, '\\') != null) return error.InvalidUrl;

    // Reject leading //, \\, /\, \/
    if (std.mem.startsWith(u8, u, "//") or
        std.mem.startsWith(u8, u, "\\\\") or
        std.mem.startsWith(u8, u, "/\\") or
        std.mem.startsWith(u8, u, "\\/"))
    {
        return error.InvalidUrl;
    }

    // Reject '..' segments and percent-encoded dots (%2e / %2E)
    if (std.mem.indexOf(u8, u, "..") != null) return error.InvalidUrl;
    if (containsPercentEncodedDot(u)) return error.InvalidUrl;

    // Check for dangerous schemes
    inline for (.{ "javascript:", "file:", "data:" }) |scheme| {
        if (std.ascii.startsWithIgnoreCase(u, scheme)) return error.BlockedScheme;
    }

    // Relative URLs (no valid scheme) are app-local
    if (!hasScheme(u)) return;

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

pub const ValidationError = error{
    DisallowedScheme,
    InvalidUrl,
    ControlCharactersNotAllowed,
};

/// Validate a URL intended to be opened in the default browser via openExternal.
/// Only allowed schemes (by default http:, https:, mailto:) are permitted.
/// Dangerous schemes (file:, javascript:, data:, etc.) are never allowed.
/// URL is validated for control characters, whitespace, and non-empty hosts on HTTP/HTTPS.
pub fn validateExternalUrl(sec: Security, url: []const u8) ValidationError!void {
    if (url.len == 0) return error.InvalidUrl;

    for (url) |c| {
        if (c <= 0x20 or c == 0x7f) return error.ControlCharactersNotAllowed;
    }

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (uri.scheme.len == 0) return error.InvalidUrl;

    // Dangerous schemes that must never be opened externally
    inline for (.{ "file", "javascript", "data", "blob", "about" }) |forbidden| {
        if (std.ascii.eqlIgnoreCase(uri.scheme, forbidden)) {
            return error.DisallowedScheme;
        }
    }

    var scheme_allowed = false;
    for (sec.open_external_schemes) |allowed| {
        var is_forbidden = false;
        inline for (.{ "file", "javascript", "data", "blob", "about" }) |forbidden| {
            if (std.ascii.eqlIgnoreCase(allowed, forbidden)) is_forbidden = true;
        }
        if (is_forbidden) continue;

        if (std.ascii.eqlIgnoreCase(uri.scheme, allowed)) {
            scheme_allowed = true;
            break;
        }
    }
    if (!scheme_allowed) return error.DisallowedScheme;

    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) {
        const host = uri.host orelse return error.InvalidUrl;
        if (host.percent_encoded.len == 0) return error.InvalidUrl;
    }

    var i: usize = 0;
    while (i < url.len) {
        const c = url[i];
        if (c > 0x7f) return error.InvalidUrl;

        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~', ':', '/', '?', '#', '[', ']', '@', '!', '$', '&', '(', ')', '*', '+', ',', ';', '=' => {
                i += 1;
            },
            '%' => {
                if (i + 2 >= url.len) return error.InvalidUrl;
                if (!std.ascii.isHex(url[i + 1]) or !std.ascii.isHex(url[i + 2])) {
                    return error.InvalidUrl;
                }
                i += 3;
            },
            else => return error.InvalidUrl, // Rejects quotes (' "), backslash, ^, backtick, <, >, {, }, |, etc.
        }
    }
}

fn hasScheme(url: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, url, ':') orelse return false;
    if (colon == 0) return false;
    for (url[0..colon]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') {
            return false;
        }
    }
    return true;
}

pub const ResolveUrlError = error{
    DisallowedOrigin,
    DisallowedScheme,
    InvalidUrl,
    ControlCharactersNotAllowed,
    OutOfMemory,
};

/// Resolve a window's target URL for a given local origin ("app://app" on Linux,
/// "https://app.localhost" on Windows).
/// - Relative paths ("/settings", "settings") resolve to dev_url in dev mode, or to local_origin in production.
/// - Absolute URLs with schemes are verified against local_origin, dev_origin, allowed_origins, and capabilities.
/// - Dangerous schemes (file:, javascript:, data:) and disallowed origins are rejected.
/// The returned slice is null-terminated and owned by `allocator`.
pub fn resolveWindowUrlWithOrigin(
    allocator: std.mem.Allocator,
    local_origin: []const u8,
    sec: Security,
    local: Local,
    dev_url: ?[]const u8,
    target_url: ?[]const u8,
    start_path: []const u8,
) ResolveUrlError![:0]const u8 {
    if (target_url) |u| {
        if (u.len == 0) {
            if (dev_url) |d| {
                return try allocator.dupeZ(u8, d);
            } else {
                return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ local_origin, start_path }, 0);
            }
        }

        for (u) |c| {
            if (c < 0x20 or c == 0x7f) return error.ControlCharactersNotAllowed;
        }

        // Reject backslashes anywhere
        if (std.mem.indexOfScalar(u8, u, '\\') != null) return error.InvalidUrl;

        // Protocol-relative URLs are not local app paths
        if (std.mem.startsWith(u8, u, "//") or
            std.mem.startsWith(u8, u, "\\\\") or
            std.mem.startsWith(u8, u, "/\\") or
            std.mem.startsWith(u8, u, "\\/"))
        {
            return error.InvalidUrl;
        }

        // Path traversal rejection ('..' and percent-encoded dots %2e / %2E)
        if (std.mem.indexOf(u8, u, "..") != null) return error.InvalidUrl;
        if (containsPercentEncodedDot(u)) return error.InvalidUrl;

        if (hasScheme(u)) {
            const uri = std.Uri.parse(u) catch return error.InvalidUrl;

            // Dangerous schemes rejected
            inline for (.{ "file", "javascript", "data", "blob", "about" }) |forbidden| {
                if (std.ascii.eqlIgnoreCase(uri.scheme, forbidden)) return error.DisallowedScheme;
            }

            var buf: [512]u8 = undefined;
            const o = origin(&buf, u) orelse return error.DisallowedOrigin;

            if (local.contains(o) or std.mem.eql(u8, o, local_origin)) {
                return try allocator.dupeZ(u8, u);
            }
            for (sec.allowed_origins) |p| {
                if (originMatches(p, o)) return try allocator.dupeZ(u8, u);
            }
            for (sec.capabilities) |c| {
                if (originMatches(c.origin, o)) return try allocator.dupeZ(u8, u);
            }
            return error.DisallowedOrigin;
        } else {
            // Relative app path
            const trimmed = std.mem.trimStart(u8, u, "/");
            if (trimmed.len == 0) {
                if (dev_url) |d| {
                    return try allocator.dupeZ(u8, d);
                } else {
                    return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ local_origin, start_path }, 0);
                }
            }

            if (dev_url) |d| {
                const base = std.mem.trimEnd(u8, d, "/");
                return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ base, trimmed }, 0);
            } else {
                return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ local_origin, trimmed }, 0);
            }
        }
    } else {
        if (dev_url) |d| {
            return try allocator.dupeZ(u8, d);
        } else {
            return try std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ local_origin, start_path }, 0);
        }
    }
}

/// Resolve a window's target URL using the platform's default app_origin.
/// The returned slice is null-terminated and owned by `allocator`.
pub fn resolveWindowUrl(
    allocator: std.mem.Allocator,
    sec: Security,
    local: Local,
    dev_url: ?[]const u8,
    target_url: ?[]const u8,
    start_path: []const u8,
) ResolveUrlError![:0]const u8 {
    return resolveWindowUrlWithOrigin(allocator, app_origin, sec, local, dev_url, target_url, start_path);
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
    try std.testing.expectEqual(Navigation.allow, navigation(sec, local, app_origin ++ "/settings", false));
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
    try std.testing.expect(commandAllowed(sec, local, app_origin ++ "/", "delete_all"));
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
    try std.testing.expectEqualStrings(app_origin ++ "/*", patterns[0]);
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
    try validateWindowUrl(sec, local, app_origin ++ "/settings");
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

    // Backslashes anywhere rejected
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "sub\\page.html"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/settings\\foo"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "\\\\evil.com"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/\\evil.com"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "\\/evil.com"));

    // Leading // rejected
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "//evil.com/page"));

    // Traversal (.. and percent-encoded dots) rejected
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/../settings"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "../secret"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/%2e%2e/settings"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/%2E%2E/settings"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/%2e/settings"));
    try std.testing.expectError(error.InvalidUrl, validateWindowUrl(sec, local, "/%2E/settings"));
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
    try std.testing.expect(isWindowApiAllowed(sec, local, app_origin ++ "/page", null));
    try std.testing.expect(isWindowApiAllowed(sec, local, "http://localhost:5173/page", null));

    // When window_api.enabled = false
    var sec_disabled = sec;
    sec_disabled.window_api.enabled = false;
    try std.testing.expect(!isWindowApiAllowed(sec_disabled, local, app_origin ++ "/page", null));

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

test validateExternalUrl {
    const default_sec: Security = .{};

    // Valid URLs
    try validateExternalUrl(default_sec, "https://ziglang.org");
    try validateExternalUrl(default_sec, "http://localhost:8080/path");
    try validateExternalUrl(default_sec, "https://example.com/a/b?c=d#hash");
    try validateExternalUrl(default_sec, "mailto:user@example.com");

    // Case-insensitivity in scheme
    try validateExternalUrl(default_sec, "HTTPS://Example.COM/test");
    try validateExternalUrl(default_sec, "Mailto:User@Example.Com");

    // Dangerous schemes always rejected
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "file:///etc/passwd"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "javascript:alert(1)"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "data:text/html,<h1>hi</h1>"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "blob:http://example.com/123"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "about:blank"));

    // Custom unallowed schemes rejected
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "slack://channel?id=123"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(default_sec, "custom:do_something"));

    // Dangerous schemes cannot be allowed even if listed in config
    const bypass_attempt_sec: Security = .{
        .open_external_schemes = &.{ "file", "javascript", "data", "https" },
    };
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(bypass_attempt_sec, "file:///etc/shadow"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(bypass_attempt_sec, "javascript:evil()"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(bypass_attempt_sec, "data:text/plain,bad"));
    try validateExternalUrl(bypass_attempt_sec, "https://safe.example.com");

    // Control characters and whitespace rejected
    try std.testing.expectError(error.ControlCharactersNotAllowed, validateExternalUrl(default_sec, "https://example.com/foo\nbar"));
    try std.testing.expectError(error.ControlCharactersNotAllowed, validateExternalUrl(default_sec, "https://example.com/foo\rbar"));
    try std.testing.expectError(error.ControlCharactersNotAllowed, validateExternalUrl(default_sec, "https://example.com/foo bar"));

    // Invalid formatting rejected
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, ""));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "not_a_url"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "http://"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://"));

    // Custom scheme allowlist
    const custom_sec: Security = .{
        .open_external_schemes = &.{"https"},
    };
    try validateExternalUrl(custom_sec, "https://example.com");
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(custom_sec, "http://example.com"));
    try std.testing.expectError(error.DisallowedScheme, validateExternalUrl(custom_sec, "mailto:user@example.com"));

    // RFC 3986 enforcement: reject quotes, backslash, ^, backtick, <, >, {, }, |, non-hex percent
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x\"--flag"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x\'--flag"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x\\flag"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x^flag"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x`flag"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x<flag>"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x{flag}"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x|flag"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x%"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x%2"));
    try std.testing.expectError(error.InvalidUrl, validateExternalUrl(default_sec, "https://a.com/x%2z"));

    // Valid percent-encoded URLs and sub-delims accepted
    try validateExternalUrl(default_sec, "https://a.com/x%20flag");
    try validateExternalUrl(default_sec, "https://a.com/x%2Fflag?a=1&b=2+3!$()*,-.;=@~#");
}

test resolveWindowUrlWithOrigin {
    const sec: Security = .{
        .allowed_origins = &.{"https://docs.example.com"},
        .capabilities = &.{.{ .origin = "https://*.trusted.dev" }},
    };
    const local_linux: Local = .{ .dev_origin = null };
    const local_dev: Local = .{ .dev_origin = "http://localhost:5173" };

    const gpa = std.testing.allocator;

    // Production: null url -> local_origin + "/" + start_path
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, null, "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("app://app/index.html", resolved);
    }
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "https://app.localhost", sec, local_linux, null, null, "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("https://app.localhost/index.html", resolved);
    }

    // Dev mode: null url -> dev_url
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_dev, "http://localhost:5173/", null, "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("http://localhost:5173/", resolved);
    }

    // Relative path in production: Linux
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/settings", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("app://app/settings", resolved);
    }
    // Relative path without leading slash in production
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "settings", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("app://app/settings", resolved);
    }

    // Relative path in production: Windows
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "https://app.localhost", sec, local_linux, null, "/settings", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("https://app.localhost/settings", resolved);
    }

    // Relative path in dev mode: proper slash joining
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_dev, "http://localhost:5173", "/settings", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("http://localhost:5173/settings", resolved);
    }
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_dev, "http://localhost:5173/", "settings", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("http://localhost:5173/settings", resolved);
    }
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_dev, "http://localhost:5173/", "/notes/42?edit=true#title", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("http://localhost:5173/notes/42?edit=true#title", resolved);
    }

    // Allowed external origins
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "https://docs.example.com/guide", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("https://docs.example.com/guide", resolved);
    }
    {
        const resolved = try resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "https://sub.trusted.dev/api", "index.html");
        defer gpa.free(resolved);
        try std.testing.expectEqualStrings("https://sub.trusted.dev/api", resolved);
    }

    // Disallowed external origins rejected
    try std.testing.expectError(error.DisallowedOrigin, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "https://evil.example.com/", "index.html"));
    try std.testing.expectError(error.DisallowedOrigin, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "http://localhost:9999/", "index.html"));

    // Dangerous schemes rejected
    try std.testing.expectError(error.DisallowedScheme, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "file:///etc/passwd", "index.html"));
    try std.testing.expectError(error.DisallowedScheme, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "javascript:alert(1)", "index.html"));
    try std.testing.expectError(error.DisallowedScheme, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "data:text/html,bad", "index.html"));

    // Protocol-relative URLs rejected
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "//evil.com/settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "\\\\evil.com/settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/\\evil.com/settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "\\/evil.com/settings", "index.html"));

    // Backslashes anywhere rejected
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "sub\\page.html", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/settings\\foo", "index.html"));

    // Path traversal rejected
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/../settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "../secret", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "foo/../../bar", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/%2e%2e/settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/%2E%2E/settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/%2e/settings", "index.html"));
    try std.testing.expectError(error.InvalidUrl, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/%2E/settings", "index.html"));

    // Control characters rejected
    try std.testing.expectError(error.ControlCharactersNotAllowed, resolveWindowUrlWithOrigin(gpa, "app://app", sec, local_linux, null, "/settings\x00bad", "index.html"));
}
