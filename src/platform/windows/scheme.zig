//! WebView2 resource request handling for `https://app.localhost/*`.
//!
//! Serves embedded frontend assets through `SHCreateMemStream` and
//! `CreateWebResourceResponse`, adding proper MIME type and Content-Security-Policy headers.
//!
//! COM handler lifetime note: scheme.zig implements no COM event/completion handlers directly.
//! Resource requests are handled by ResourceHandler in window.zig, which forwards to Scheme.handleRequest.

const std = @import("std");
const win32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const App = @import("../../core/App.zig");

pub const host_origin = "https://app.localhost";
pub const filter_pattern = "https://app.localhost/*";

pub fn Scheme(comptime config: App.Config, comptime csp_z: ?[:0]const u8) type {
    return struct {
        pub fn handleRequest(
            env: *webview2.ICoreWebView2Environment,
            args: *webview2.ICoreWebView2WebResourceRequestedEventArgs,
        ) void {
            var req_opt: ?*webview2.ICoreWebView2WebResourceRequest = null;
            if (args.lpVtbl.get_Request(args, &req_opt) < 0) return;
            const req = req_opt orelse return;
            defer _ = req.lpVtbl.Release(req);

            var uri_w: ?win32.LPWSTR = null;
            if (req.lpVtbl.get_Uri(req, @ptrCast(&uri_w)) < 0 or uri_w == null) return;
            defer win32.CoTaskMemFree(uri_w);

            const uri_len = std.mem.indexOfScalar(u16, std.mem.span(uri_w.?), 0) orelse std.mem.span(uri_w.?).len;
            const gpa = std.heap.smp_allocator;

            const uri = std.unicode.utf16LeToUtf8Alloc(gpa, uri_w.?[0..uri_len]) catch return;
            defer gpa.free(uri);

            // Strip origin "https://app.localhost/" to get relative asset path
            const prefix = "https://app.localhost/";
            const path = if (std.mem.startsWith(u8, uri, prefix)) uri[prefix.len..] else uri;
            // Strip query string and fragment if any
            const clean_path = if (std.mem.indexOfAny(u8, path, "?#")) |idx| path[0..idx] else path;

            const asset = App.findAsset(config.assets, clean_path, config.spa_fallback);

            if (asset) |a| {
                const stream = win32.SHCreateMemStream(a.data.ptr, @intCast(a.data.len)) orelse return;
                defer stream.release();

                // Format HTTP response headers (matching Linux: Content-Type, nosniff, CSP)
                const hdr_str = if (csp_z) |csp|
                    std.fmt.allocPrint(gpa, "Content-Type: {s}\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: {s}\r\n", .{ a.mime, csp }) catch return
                else
                    std.fmt.allocPrint(gpa, "Content-Type: {s}\r\nX-Content-Type-Options: nosniff\r\n", .{a.mime}) catch return;
                defer gpa.free(hdr_str);

                const hdr_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, hdr_str) catch return;
                defer gpa.free(hdr_w);

                const ok_w = std.unicode.utf8ToUtf16LeStringLiteral("OK");

                var resp_opt: ?*webview2.ICoreWebView2WebResourceResponse = null;
                if (env.createWebResourceResponse(stream, 200, ok_w, hdr_w.ptr, &resp_opt) >= 0) {
                    if (resp_opt) |resp| {
                        defer resp.release();
                        _ = args.lpVtbl.put_Response(args, resp);
                    }
                }
            } else {
                const not_found_w = std.unicode.utf8ToUtf16LeStringLiteral("Not Found");
                const err_hdr_w = std.unicode.utf8ToUtf16LeStringLiteral("Content-Type: text/plain\r\n");

                var resp_opt: ?*webview2.ICoreWebView2WebResourceResponse = null;
                if (env.createWebResourceResponse(null, 404, not_found_w, err_hdr_w, &resp_opt) >= 0) {
                    if (resp_opt) |resp| {
                        defer resp.release();
                        _ = args.lpVtbl.put_Response(args, resp);
                    }
                }
            }
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
