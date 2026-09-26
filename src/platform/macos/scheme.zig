//! `app://` asset scheme through a `WKURLSchemeHandler`.
//!
//! Serves the embedded frontend (`App.findAsset`, with the SPA fallback) with
//! the same response headers as the Linux and Windows backends:
//! Content-Type, `X-Content-Type-Options: nosniff` and the CSP. With
//! isolation on, the `isolation` host serves the isolation page instead
//! (`isolation.servePage`, a key minted for the requesting webview).

const std = @import("std");
const cocoa = @import("cocoa.zig");
const Object = cocoa.Object;
const security = @import("../../core/security.zig");
const App = @import("../../core/App.zig");
const isolation = @import("../../core/isolation.zig");

pub const scheme_name = "app";

const media_enabled = @import("../../oriel.zig").options.media_server;
const media_scheme = if (media_enabled) @import("../../modules/media_scheme.zig") else struct {};

pub fn Scheme(comptime config: App.Config, comptime local: security.Local, comptime csp_z: ?[:0]const u8) type {
    return struct {
        /// The handler class (one shared instance serves every webview).
        pub fn handlerClass() cocoa.Class {
            return cocoa.defineClass("OrielSchemeHandler", &.{"WKURLSchemeHandler"}, .{
                .{ "webView:startURLSchemeTask:", startTask },
                .{ "webView:stopURLSchemeTask:", stopTask },
            });
        }

        /// Answers synchronously, so a task is always finished before WebKit
        /// could stop it (calling a stopped task raises an exception).
        fn startTask(_: cocoa.id, _: cocoa.c.SEL, view: cocoa.id, task_id: cocoa.id) callconv(.c) void {
            const task: Object = .{ .value = task_id };
            const url = task.msgSend(Object, "request", .{}).msgSend(Object, "URL", .{});
            if (comptime config.security.isolation != null) {
                const host = cocoa.utf8(url.msgSend(Object, "host", .{})) orelse "";
                if (std.ascii.eqlIgnoreCase(host, isolation.host)) return serveIsolation(task, url, if (view) |v| @intFromPtr(v) else 0);
            }
            if (comptime media_enabled) {
                // Still percent-encoded: media_scheme decodes (and checks) it itself.
                const comps = cocoa.class("NSURLComponents").msgSend(Object, "componentsWithURL:resolvingAgainstBaseURL:", .{ url, cocoa.boolean(false) });
                const raw = if (comps.value != null) cocoa.utf8(comps.msgSend(Object, "percentEncodedPath", .{})) orelse "" else "";
                if (std.mem.startsWith(u8, raw, "/media/")) return media_scheme.handle(task, url, raw["/media/".len..]);
            }
            // `path` is percent-decoded and excludes the query and fragment.
            const path = cocoa.utf8(url.msgSend(Object, "path", .{})) orelse "";
            if (App.findAsset(config.assets, path, config.spa_fallback)) |asset| {
                respond(task, url, 200, asset.mime, asset.data, true);
            } else {
                respond(task, url, 404, "text/plain", "Not Found", false);
            }
        }

        /// The isolation page, with a fresh key for this webview; nothing
        /// else on that host.
        fn serveIsolation(task: Object, url: Object, view: usize) void {
            const path = cocoa.utf8(url.msgSend(Object, "path", .{})) orelse "";
            if (!isolation.isPagePath(path)) return respondWith(task, url, 404, "text/plain", "Not Found", null, &.{});
            const gpa = std.heap.smp_allocator;
            const page = (isolation.servePage(gpa, config.security, local, view) catch null) orelse return failTask(task);
            defer {
                std.crypto.secureZero(u8, page);
                gpa.free(page);
            }
            const csp = isolation.pageCsp(gpa, config.security, local) catch return failTask(task);
            defer gpa.free(csp);
            respondWith(task, url, 200, "text/html", page, csp, comptime isolation.pageHeaders(config.security));
        }

        /// Only media streams outlive `startTask`.
        fn stopTask(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, task_id: cocoa.id) callconv(.c) void {
            if (comptime media_enabled) media_scheme.impl.stop(.{ .value = task_id });
        }

        fn respond(task: Object, url: Object, status: isize, mime: []const u8, body: []const u8, with_csp: bool) void {
            respondWith(task, url, status, mime, body, if (with_csp) csp_z else null, null);
        }

        /// `extra`: null for the app's own responses (with `security.headers`),
        /// else exactly these headers (the isolation page). A body that isn't
        /// embedded (`extra` != null) is copied.
        fn respondWith(task: Object, url: Object, status: isize, mime: []const u8, body: []const u8, csp: ?[]const u8, extra: ?[]const [2][]const u8) void {
            const headers = cocoa.new(cocoa.class("NSMutableDictionary"));
            defer headers.release();
            var len_buf: [24]u8 = undefined;
            const len = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable; // 24 digits fit any usize
            setHeader(headers, "Content-Type", mime);
            setHeader(headers, "Content-Length", len);
            setHeader(headers, "X-Content-Type-Options", "nosniff");
            if (extra) |list| {
                for (list) |h| setHeader(headers, h[0], h[1]);
            } else inline for (config.security.headers) |h| {
                if (comptime security.headerUsable(h)) setHeader(headers, h.name, h.value);
            }
            if (csp) |c| setHeader(headers, "Content-Security-Policy", c);

            const version = cocoa.nsString("HTTP/1.1") orelse {
                failTask(task); // every task gets an answer
                return;
            };
            defer version.release();
            const response = cocoa.class("NSHTTPURLResponse").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithURL:statusCode:HTTPVersion:headerFields:", .{ url, status, version, headers });
            if (response.value == null) {
                failTask(task);
                return;
            }
            defer response.release();
            task.msgSend(void, "didReceiveResponse:", .{response});
            // Embedded assets live in the binary: no copy, never freed.
            const data = if (extra == null)
                cocoa.class("NSData").msgSend(Object, "dataWithBytesNoCopy:length:freeWhenDone:", .{
                    @constCast(body.ptr), @as(c_ulong, body.len), cocoa.boolean(false),
                })
            else
                cocoa.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ body.ptr, @as(c_ulong, body.len) });
            task.msgSend(void, "didReceiveData:", .{data});
            task.msgSend(void, "didFinish", .{});
        }

        fn setHeader(headers: Object, name: []const u8, value: []const u8) void {
            const key = cocoa.nsString(name) orelse return;
            defer key.release();
            const val = cocoa.nsString(value) orelse return;
            defer val.release();
            headers.msgSend(void, "setObject:forKey:", .{ val, key });
        }

        /// Out of memory building the response: fail the load instead of
        /// leaving the task open.
        fn failTask(task: Object) void {
            const domain = cocoa.nsString("oriel-asset") orelse return;
            defer domain.release();
            const err = cocoa.class("NSError").msgSend(Object, "errorWithDomain:code:userInfo:", .{ domain, @as(isize, 500), cocoa.nil });
            task.msgSend(void, "didFailWithError:", .{err});
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
