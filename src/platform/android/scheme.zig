//! Serving the app's embedded assets to android.webkit.WebView.
//!
//! Kotlin's `shouldInterceptRequest` hands every `https://app.localhost/...`
//! (and, with isolation, `https://isolation.localhost/...`) request to
//! `serve`, on a WebView IO thread; the answer becomes a
//! `WebResourceResponse`. The host is answered here and never reaches the
//! network. Same headers as the other platforms: MIME type, nosniff, the CSP
//! with the page's inline-script hashes, and the app's extra headers.

const std = @import("std");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");
const csp_mod = @import("../../core/csp.zig");
const handlers = @import("handlers.zig");

pub const host_origin = security.app_origin;

pub fn Scheme(comptime config: App.Config, comptime local: security.Local, comptime csp_z: ?[:0]const u8) type {
    return struct {
        const not_found: handlers.Response = .{ .status = 404, .mime = "text/plain", .headers = "", .body = "Not Found" };

        pub fn serve(arena: std.mem.Allocator, id: u32, url: []const u8) ?handlers.Response {
            if (comptime config.security.isolation != null) {
                const iso_prefix = isolation.origin ++ "/";
                if (std.ascii.startsWithIgnoreCase(url, iso_prefix) or std.ascii.eqlIgnoreCase(url, isolation.origin)) {
                    const rest = if (url.len > iso_prefix.len) url[iso_prefix.len..] else "";
                    const path = if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest[0..i] else rest;
                    return serveIsolation(arena, path, id);
                }
            }
            const prefix = host_origin ++ "/";
            if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null; // not ours: the network
            const rest = url[prefix.len..];
            const path = if (std.mem.indexOfAny(u8, rest, "?#")) |i| rest[0..i] else rest;

            const asset = App.findAsset(config.assets, path, config.spa_fallback) orelse return not_found;
            const page_csp: ?[:0]u8 = if (csp_z) |c| csp_mod.withHashes(arena, c, asset.script_hashes, asset.style_hashes) catch null else null;
            const extra = comptime headerLines(security.comptimeHeaderLines(config.security.headers));
            const headers = if (page_csp orelse csp_z) |csp|
                std.fmt.allocPrint(arena, "X-Content-Type-Options: nosniff\nContent-Security-Policy: {s}\n{s}", .{ csp, extra }) catch return null
            else
                std.fmt.allocPrint(arena, "X-Content-Type-Options: nosniff\n{s}", .{extra}) catch return null;
            return .{ .status = 200, .mime = asset.mime, .headers = headers, .body = asset.data };
        }

        /// The isolation page with a fresh key for window `id`; nothing else
        /// on that host.
        fn serveIsolation(arena: std.mem.Allocator, path: []const u8, id: u32) handlers.Response {
            if (!isolation.isPagePath(path)) return not_found;
            const page = (isolation.servePage(arena, config.security, local, id) catch null) orelse return not_found;
            const csp = isolation.pageCsp(arena, config.security, local) catch return not_found;
            const headers = std.fmt.allocPrint(arena, "Content-Security-Policy: {s}\n{s}", .{ csp, comptime headerLines(isolation.pageHeaderLines(config.security)) }) catch return not_found;
            return .{ .status = 200, .mime = "text/html", .headers = headers, .body = page };
        }

        /// "Name: value\r\n" lines as "Name: value\n".
        fn headerLines(comptime crlf: []const u8) []const u8 {
            comptime {
                var out: []const u8 = "";
                var it = std.mem.splitSequence(u8, crlf, "\r\n");
                while (it.next()) |line| {
                    if (line.len > 0) out = out ++ line ++ "\n";
                }
                return out;
            }
        }
    };
}

/// The wire format of a response for Kotlin (`OrielRuntime.parseResponse`):
/// "<status>\n<mime>\n<header lines>\n" then the body.
pub fn encode(gpa: std.mem.Allocator, r: handlers.Response) ![]u8 {
    return std.mem.concat(gpa, u8, &.{
        try std.fmt.allocPrint(gpa, "{d}\n{s}\n", .{ r.status, r.mime }),
        r.headers,
        "\n",
        r.body,
    });
}

test encode {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try encode(arena_state.allocator(), .{ .status = 200, .mime = "text/html", .headers = "A: b\n", .body = "<p>" });
    try std.testing.expectEqualStrings("200\ntext/html\nA: b\n\n<p>", out);
}
