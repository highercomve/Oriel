//! WebKit custom URI scheme handler for `app://`.
//!
//! Serves embedded frontend assets through `gio.MemoryInputStream` and
//! `webkit.URISchemeResponse`, adding proper MIME type and Content-Security-Policy headers.
//! With isolation on, the `isolation` host serves the isolation page instead
//! (`isolation.servePage`, a key minted for the requesting webview).

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const webkit = @import("webkit");
const soup = @import("soup");
const security = @import("../../core/security.zig");
const App = @import("../../core/App.zig");
const isolation = @import("../../core/isolation.zig");
const csp_mod = @import("../../core/csp.zig");

pub const scheme_name = "app";

pub fn Scheme(comptime config: App.Config, comptime local: security.Local, comptime csp_z: ?[:0]const u8) type {
    return struct {
        var scheme_registered: bool = false;

        pub fn register(view: *webkit.WebView) void {
            if (!scheme_registered) {
                const context = view.getContext();
                context.registerUriScheme(scheme_name, &serveAsset, null, null);
                context.getSecurityManager().registerUriSchemeAsSecure(scheme_name);
                scheme_registered = true;
            }
        }

        fn serveAsset(request: *webkit.URISchemeRequest, _: ?*anyopaque) callconv(.c) void {
            const path = std.mem.span(request.getPath());
            if (comptime config.security.isolation != null) {
                const uri = std.Uri.parse(std.mem.span(request.getUri())) catch null;
                var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
                const host: []const u8 = if (uri) |u| (if (u.host) |h| (h.toRaw(&host_buf) catch "") else "") else "";
                if (std.ascii.eqlIgnoreCase(host, isolation.host)) return serveIsolation(request, path);
            }
            if (@import("../../oriel.zig").options.media_server and std.mem.startsWith(u8, path, "/media/")) {
                return @import("../../modules/media_scheme.zig").handle(request, path["/media/".len..]);
            }
            const asset = App.findAsset(config.assets, path, config.spa_fallback);
            if (asset) |a| {
                const stream = gio.MemoryInputStream.newFromData(@constCast(a.data.ptr), @intCast(a.data.len), null);
                defer stream.unref();
                const response = webkit.URISchemeResponse.new(stream.as(gio.InputStream), @intCast(a.data.len));
                defer response.unref();
                response.setContentType(a.mime);
                // set_http_headers takes ownership of `headers`.
                const headers = soup.MessageHeaders.new(.response);
                headers.append("Content-Type", a.mime);
                headers.append("X-Content-Type-Options", "nosniff");
                // The page's own inline scripts (and styles) are allowed by hash.
                const gpa = std.heap.smp_allocator;
                const page_csp: ?[:0]u8 = if (csp_z) |c| csp_mod.withHashes(gpa, c, a.script_hashes, a.style_hashes) catch null else null;
                defer if (page_csp) |p| gpa.free(p);
                if (page_csp orelse csp_z) |csp| headers.append("Content-Security-Policy", csp);
                inline for (config.security.headers) |h| {
                    if (comptime security.headerUsable(h)) {
                        headers.append((h.name ++ "\x00")[0..h.name.len :0], (h.value ++ "\x00")[0..h.value.len :0]);
                    }
                }
                response.setHttpHeaders(headers);
                request.finishWithResponse(response);
                return;
            }
            const err = glib.Error.newLiteral(glib.quarkFromStaticString("oriel-asset"), 404, "asset not found");
            defer err.free();
            request.finishError(err);
        }

        /// The isolation page, with a fresh key for the requesting webview;
        /// nothing else on that host.
        fn serveIsolation(request: *webkit.URISchemeRequest, path: []const u8) void {
            const gpa = std.heap.smp_allocator;
            const page: ?[]u8 = if (isolation.isPagePath(path))
                isolation.servePage(gpa, config.security, local, @intFromPtr(request.getWebView())) catch null
            else
                null;
            const csp: ?[:0]u8 = if (page != null) blk: {
                const c = isolation.pageCsp(gpa, config.security, local) catch break :blk null;
                defer gpa.free(c);
                break :blk gpa.dupeZ(u8, c) catch null;
            } else null;
            defer if (csp) |c| gpa.free(c);
            if (page == null or csp == null) {
                if (page) |p| {
                    std.crypto.secureZero(u8, p);
                    gpa.free(p);
                }
                const err = glib.Error.newLiteral(glib.quarkFromStaticString("oriel-asset"), 404, "not found");
                defer err.free();
                request.finishError(err);
                return;
            }
            // The stream owns the page (a copy the GLib way) and frees it.
            const body = glib.memdup2(page.?.ptr, page.?.len) orelse {
                std.crypto.secureZero(u8, page.?);
                gpa.free(page.?);
                const err = glib.Error.newLiteral(glib.quarkFromStaticString("oriel-asset"), 500, "out of memory");
                defer err.free();
                request.finishError(err);
                return;
            };
            const len = page.?.len;
            std.crypto.secureZero(u8, page.?);
            gpa.free(page.?);
            const stream = gio.MemoryInputStream.newFromData(@ptrCast(body), @intCast(len), &glib.free);
            defer stream.unref();
            const response = webkit.URISchemeResponse.new(stream.as(gio.InputStream), @intCast(len));
            defer response.unref();
            response.setContentType("text/html");
            const headers = soup.MessageHeaders.new(.response);
            headers.append("Content-Type", "text/html");
            headers.append("Content-Security-Policy", csp.?);
            inline for (comptime isolation.pageHeaders(config.security)) |h| headers.append((h[0] ++ "\x00")[0..h[0].len :0], (h[1] ++ "\x00")[0..h[1].len :0]);
            response.setHttpHeaders(headers);
            request.finishWithResponse(response);
        }
    };
}
