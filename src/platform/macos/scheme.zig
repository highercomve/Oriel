//! `app://` asset scheme through a `WKURLSchemeHandler`.
//!
//! Serves the embedded frontend (`App.findAsset`, with the SPA fallback) with
//! the same response headers as the Linux and Windows backends:
//! Content-Type, `X-Content-Type-Options: nosniff` and the CSP.

const std = @import("std");
const cocoa = @import("cocoa.zig");
const Object = cocoa.Object;
const App = @import("../../core/App.zig");

pub const scheme_name = "app";

pub fn Scheme(comptime config: App.Config, comptime csp_z: ?[:0]const u8) type {
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
        fn startTask(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, task_id: cocoa.id) callconv(.c) void {
            const task: Object = .{ .value = task_id };
            const url = task.msgSend(Object, "request", .{}).msgSend(Object, "URL", .{});
            // `path` is percent-decoded and excludes the query and fragment.
            const path = cocoa.utf8(url.msgSend(Object, "path", .{})) orelse "";
            if (App.findAsset(config.assets, path, config.spa_fallback)) |asset| {
                respond(task, url, 200, asset.mime, asset.data, true);
            } else {
                respond(task, url, 404, "text/plain", "Not Found", false);
            }
        }

        fn stopTask(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, _: cocoa.id) callconv(.c) void {}

        fn respond(task: Object, url: Object, status: isize, mime: []const u8, body: []const u8, with_csp: bool) void {
            const headers = cocoa.new(cocoa.class("NSMutableDictionary"));
            defer headers.release();
            var len_buf: [24]u8 = undefined;
            const len = std.fmt.bufPrint(&len_buf, "{d}", .{body.len}) catch unreachable; // 24 digits fit any usize
            setHeader(headers, "Content-Type", mime);
            setHeader(headers, "Content-Length", len);
            setHeader(headers, "X-Content-Type-Options", "nosniff");
            if (with_csp) if (csp_z) |csp| setHeader(headers, "Content-Security-Policy", csp);

            const version = cocoa.nsString("HTTP/1.1") orelse return;
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
            const data = cocoa.class("NSData").msgSend(Object, "dataWithBytesNoCopy:length:freeWhenDone:", .{
                @constCast(body.ptr), @as(c_ulong, body.len), cocoa.boolean(false),
            });
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
