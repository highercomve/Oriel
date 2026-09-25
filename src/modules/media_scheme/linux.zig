//! WebKit custom URI scheme handler for serving media files over `app://app/media/...`.
//!
//! Provides streaming GInputStream with seeking and range-bounded responses (HTTP 206)
//! without buffering files into memory.
//!
//! Limitation: `fetch()`/XHR (and `<img>`) can load `app://app/media/...`, but
//! `<video>`/`<audio>` cannot. WebKitGTK's GStreamer player only accepts the
//! protocols in `isProtocolAllowed` (GStreamerCommon.cpp: blob, data, file,
//! http, https, ...) and its `webkitwebsrc` element only handles http, https
//! and blob, so a custom scheme fails with MEDIA_ERR_SRC_NOT_SUPPORTED before
//! any request reaches this handler. Play media from the TCP server
//! (`media_server.Server`) instead.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const webkit = @import("webkit");
const soup = @import("soup");
const range = @import("../media/range.zig");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");
const open = @import("../media/open.zig");

/// Custom GFilterInputStream subclass that limits the number of bytes read
/// to `remaining` and returns 0 (EOF) once that limit is reached.
///
/// This is essential because WebKitGTK's internal URI scheme loader
/// (webkitURISchemeRequestReadCallback) continues reading asynchronously from
/// the response GInputStream until EOF, ignoring stream_length. Without a bounded
/// stream, WebKit would read past the requested range to the end of the file.
pub const LimitInputStream = extern struct {
    parent: gio.FilterInputStream,
    remaining: u64,
};

pub const LimitInputStreamClass = extern struct {
    parent_class: gio.FilterInputStreamClass,
};

var limit_stream_type: usize = 0;

fn limitRead(
    stream: *gio.InputStream,
    buffer: ?*anyopaque,
    count: usize,
    cancellable: ?*gio.Cancellable,
    err: ?*?*glib.Error,
) callconv(.c) isize {
    const filter: *gio.FilterInputStream = @ptrCast(@alignCast(stream));
    const self: *LimitInputStream = @ptrCast(@alignCast(stream));
    if (self.remaining == 0) return 0; // EOF reached for this range
    const to_read: usize = @intCast(@min(@as(u64, count), self.remaining));
    const base = filter.getBaseStream();
    const buf_ptr: [*]u8 = @ptrCast(buffer orelse return 0);
    const n = gio.InputStream.read(base, buf_ptr, to_read, cancellable, err);
    if (n > 0) {
        self.remaining -= @intCast(n);
    }
    return n;
}

fn classInit(klass: *gobject.TypeClass, _: ?*anyopaque) callconv(.c) void {
    const stream_class: *gio.InputStreamClass = @ptrCast(@alignCast(klass));
    // Only read_fn: GInputStream's default read_async runs it on a GTask
    // worker thread, which is what WebKit uses.
    stream_class.f_read_fn = &limitRead;
}

fn instanceInit(instance: *gobject.TypeInstance, _: *gobject.TypeClass) callconv(.c) void {
    const self: *LimitInputStream = @ptrCast(@alignCast(instance));
    self.remaining = 0;
}

pub fn getLimitInputStreamType() usize {
    if (limit_stream_type == 0) {
        limit_stream_type = gobject.typeRegisterStaticSimple(
            gio.FilterInputStream.getGObjectType(),
            "OrielLimitInputStream",
            @sizeOf(LimitInputStreamClass),
            &classInit,
            @sizeOf(LimitInputStream),
            &instanceInit,
            .{},
        );
    }
    return limit_stream_type;
}

pub fn newLimitInputStream(base: *gio.InputStream, limit: u64) *gio.InputStream {
    const obj_type = getLimitInputStreamType();
    const obj = gobject.Object.new(
        obj_type,
        "base-stream",
        base,
        "close-base-stream",
        @as(c_int, 1),
        @as(?*anyopaque, null),
    );
    const self: *LimitInputStream = @ptrCast(@alignCast(obj));
    self.remaining = limit;
    return @ptrCast(@alignCast(obj));
}

// Transfer full; the symbol is in libgio (GioUnix has no binding here).
extern fn g_unix_input_stream_new(fd: c_int, close_fd: c_int) *gio.InputStream;

/// Media root for `app://app/media/...`, set by `setRoot`; main thread only
/// (the scheme handler runs there).
var root_fd: ?std.os.linux.fd_t = null;
var root_policy: open.SymlinkPolicy = .inside_root;

/// Serve the files below `path` at `app://app/media/<path>` (replacing any
/// previous root). Call on the main thread, e.g. from `Config.setup`.
pub fn setRoot(path: []const u8, policy: open.SymlinkPolicy) !void {
    const fd = try open.openRoot(path);
    clearRoot();
    root_fd = fd;
    root_policy = policy;
}

/// Stop serving `app://app/media/` (requests get 404).
pub fn clearRoot() void {
    if (root_fd) |fd| _ = std.os.linux.close(fd); // O_PATH fd: nothing to flush
    root_fd = null;
}

/// Serve `rel_path` (the part after `/media/`, still percent-encoded) for a
/// scheme request. Called by the `app://` handler on the main thread.
pub fn handle(request: *webkit.URISchemeRequest, rel_path: []const u8) void {
    const root = root_fd orelse return finishWithError(request, 404, "Not Found");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const sanitized = range.sanitizePath(fba.allocator(), rel_path) catch |err| return switch (err) {
        error.PathTraversal => finishWithError(request, 403, "Forbidden"),
        error.NotFound, error.OutOfMemory => finishWithError(request, 404, "Not Found"),
    };
    const file = open.openInRoot(root, sanitized, root_policy) catch |err| return switch (err) {
        error.Forbidden => finishWithError(request, 403, "Forbidden"),
        error.NotFound, error.NotAFile => finishWithError(request, 404, "Not Found"),
        error.Unexpected => finishWithError(request, 500, "Internal Server Error"),
    };
    const mime = range.mimeForExtension(std.fs.path.extension(sanitized));

    const range_hdr: ?[]const u8 = if (request.getHttpHeaders().getOne("Range")) |r| std.mem.span(r) else null;
    const res: range.RangeResult = if (range_hdr) |h| range.parseRange(h, file.size) else .full;
    const r: range.Range = switch (res) {
        .unsatisfiable => {
            file.close();
            return finishWith416(request, file.size, mime);
        },
        .full => .{ .start = 0, .end = file.size -| 1 },
        .range => |r| r,
    };
    const length: u64 = if (file.size == 0) 0 else r.length();
    // The stream reads sequentially from the fd's offset: position it first.
    const seek_rc = std.os.linux.lseek(file.fd, @intCast(r.start), std.os.linux.SEEK.SET);
    if (std.os.linux.errno(seek_rc) != .SUCCESS) {
        file.close();
        return finishWithError(request, 500, "Internal Server Error");
    }

    const base = g_unix_input_stream_new(file.fd, 1); // owns the fd from here
    defer base.unref();
    const limited = newLimitInputStream(base, length);
    defer limited.unref();
    const response = webkit.URISchemeResponse.new(limited, @intCast(length));
    defer response.unref();
    response.setContentType(mime);

    // set_http_headers takes ownership of `headers`; custom headers replace
    // the defaults, so Content-Type goes in too.
    const headers = soup.MessageHeaders.new(.response);
    headers.append("Content-Type", mime);
    headers.append("Accept-Ranges", "bytes");
    var cl_buf: [32]u8 = undefined;
    headers.append("Content-Length", std.fmt.bufPrintZ(&cl_buf, "{d}", .{length}) catch unreachable);
    if (res == .range) {
        var cr_buf: [96]u8 = undefined;
        headers.append("Content-Range", std.fmt.bufPrintZ(&cr_buf, "bytes {d}-{d}/{d}", .{ r.start, r.end, file.size }) catch unreachable);
        response.setStatus(206, null);
    } else {
        response.setStatus(200, null);
    }
    appendAppHeaders(headers);
    response.setHttpHeaders(headers);
    request.finishWithResponse(response);
}

/// The app's extra headers (security.headers), as on app:// responses.
/// soup copies the strings; ones too long for the buffers are skipped.
fn appendAppHeaders(headers: *soup.MessageHeaders) void {
    for (App.current_security.headers) |h| {
        if (security.headerBuiltIn(h.name) or !security.headerValueValid(h.value)) continue;
        var name_buf: [128]u8 = undefined;
        var value_buf: [2048]u8 = undefined;
        const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{h.name}) catch continue;
        const value = std.fmt.bufPrintZ(&value_buf, "{s}", .{h.value}) catch continue;
        headers.append(name, value);
    }
}

fn finishWithError(request: *webkit.URISchemeRequest, status: c_uint, reason: [:0]const u8) void {
    var empty_buf: [1]u8 = undefined;
    const empty_stream = gio.MemoryInputStream.newFromData(&empty_buf, 0, null);
    defer empty_stream.unref();
    const response = webkit.URISchemeResponse.new(empty_stream.as(gio.InputStream), 0);
    defer response.unref();

    const headers = soup.MessageHeaders.new(.response);
    headers.append("Content-Type", "text/plain");
    headers.append("Content-Length", "0");
    response.setHttpHeaders(headers);
    response.setStatus(status, reason);
    request.finishWithResponse(response);
}

fn finishWith416(request: *webkit.URISchemeRequest, file_size: u64, mime: [:0]const u8) void {
    var empty_buf: [1]u8 = undefined;
    const empty_stream = gio.MemoryInputStream.newFromData(&empty_buf, 0, null);
    defer empty_stream.unref();
    const response = webkit.URISchemeResponse.new(empty_stream.as(gio.InputStream), 0);
    defer response.unref();

    const headers = soup.MessageHeaders.new(.response);
    headers.append("Content-Type", mime);
    headers.append("Accept-Ranges", "bytes");
    headers.append("Content-Length", "0");
    var cr_buf: [64:0]u8 = undefined;
    const cr = std.fmt.bufPrintZ(&cr_buf, "bytes */{d}", .{file_size}) catch unreachable; // 28 bytes max
    headers.append("Content-Range", cr);
    response.setHttpHeaders(headers);
    response.setStatus(416, "Range Not Satisfiable");
    request.finishWithResponse(response);
}
