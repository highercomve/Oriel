//! WebKit custom URI scheme handler for `app://`.
//!
//! Serves embedded frontend assets through `gio.MemoryInputStream` and
//! `webkit.URISchemeResponse`, adding proper MIME type and Content-Security-Policy headers.

const std = @import("std");
const glib = @import("glib");
const gio = @import("gio");
const webkit = @import("webkit");
const soup = @import("soup");
const security = @import("../../core/security.zig");
const App = @import("../../core/App.zig");

pub const scheme_name = "app";

pub fn Scheme(comptime config: App.Config, comptime csp_z: ?[:0]const u8) type {
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
                if (csp_z) |csp| headers.append("Content-Security-Policy", csp);
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
    };
}
