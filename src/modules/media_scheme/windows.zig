//! WebView2 WebResourceRequested handler for media files over `https://app.localhost/media/...`.
//!
//! Windows backend for media_scheme:
//! Serves media files from the configured media root directory using a custom read-only
//! COM IStream implementation (FileWindowStream) over the verified file HANDLE.
//!
//! Supports RFC 9110 range requests (HTTP 206) and full requests (HTTP 200) without buffering
//! file bodies in memory.

const std = @import("std");
const log = std.log.scoped(.oriel);
const win32 = @import("../../platform/windows/win32.zig");
const webview2 = @import("../../platform/windows/webview2.zig");
const open = @import("../media/open.zig");
const range = @import("../media/range.zig");
const App = @import("../../core/App.zig");
const security = @import("../../core/security.zig");

var root_handle: ?open.Root = null;
var root_policy: open.SymlinkPolicy = .inside_root;

/// Serve the files below `path` at `https://app.localhost/media/<path>`
/// (replacing any previous root). Call on the main thread, e.g. from `Config.setup`.
pub fn setRoot(path: []const u8, policy: open.SymlinkPolicy) !void {
    const root = try open.openRoot(path);
    clearRoot();
    root_handle = root;
    root_policy = policy;
}

/// Stop serving media requests (subsequent requests get 404).
pub fn clearRoot() void {
    if (root_handle) |r| open.closeRoot(r);
    root_handle = null;
}

/// Compute number of bytes to read within a window bound.
pub fn computeReadSlice(pos: u64, window_length: u64, cb: u32) u32 {
    if (pos >= window_length) return 0;
    const remaining = window_length - pos;
    return @truncate(@min(@as(u64, cb), remaining));
}

/// Compute new seek position within a window.
pub fn computeSeekPosition(origin: u32, move: i64, current_pos: u64, window_length: u64) ?u64 {
    const base: i64 = switch (origin) {
        win32.STREAM_SEEK_SET => 0,
        win32.STREAM_SEEK_CUR => @intCast(current_pos),
        win32.STREAM_SEEK_END => @intCast(window_length),
        else => return null,
    };
    const target = std.math.add(i64, base, move) catch return null;
    if (target < 0) return null;
    return @intCast(target);
}

/// Custom read-only IStream implementation over an already-verified file HANDLE
/// bounded to the byte window [start, start + length).
pub const FileWindowStream = struct {
    stream: win32.IStream,
    ref_count: std.atomic.Value(u32),
    handle: win32.HANDLE,
    window_start: u64,
    window_length: u64,
    current_offset: std.atomic.Value(u64),

    const vtable = win32.IStream.IStreamVtbl{
        .QueryInterface = &queryInterface,
        .AddRef = &addRef,
        .Release = &release,
        .Read = &read,
        .Write = &write,
        .Seek = &seek,
        .SetSize = &setSize,
        .CopyTo = &copyTo,
        .Commit = &commit,
        .Revert = &revert,
        .LockRegion = &lockRegion,
        .UnlockRegion = &unlockRegion,
        .Stat = &stat,
        .Clone = &clone,
    };

    pub fn create(file_handle: win32.HANDLE, start: u64, length: u64) !*FileWindowStream {
        const self = try std.heap.smp_allocator.create(FileWindowStream);
        self.* = .{
            .stream = .{ .lpVtbl = &vtable },
            .ref_count = std.atomic.Value(u32).init(1),
            .handle = file_handle,
            .window_start = start,
            .window_length = length,
            .current_offset = std.atomic.Value(u64).init(0),
        };
        return self;
    }

    pub fn createEmpty() !*FileWindowStream {
        return create(win32.INVALID_HANDLE_VALUE, 0, 0);
    }

    pub fn asStream(self: *FileWindowStream) *win32.IStream {
        return &self.stream;
    }

    fn fromStream(stream: *win32.IStream) *FileWindowStream {
        return @fieldParentPtr("stream", stream);
    }

    fn queryInterface(This: *win32.IStream, riid: *const win32.GUID, ppvObject: *?*anyopaque) callconv(.winapi) win32.HRESULT {
        if (std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&webview2.IID_IUnknown)) or
            std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&win32.IID_ISequentialStream)) or
            std.mem.eql(u8, std.mem.asBytes(riid), std.mem.asBytes(&win32.IID_IStream)))
        {
            ppvObject.* = @ptrCast(This);
            _ = addRef(This);
            return win32.S_OK;
        }
        ppvObject.* = null;
        return win32.E_NOINTERFACE;
    }

    fn addRef(This: *win32.IStream) callconv(.winapi) win32.ULONG {
        const self = fromStream(This);
        return self.ref_count.fetchAdd(1, .monotonic) + 1;
    }

    fn release(This: *win32.IStream) callconv(.winapi) win32.ULONG {
        const self = fromStream(This);
        const prev = self.ref_count.fetchSub(1, .release);
        if (prev == 1) {
            _ = self.ref_count.load(.acquire);
            if (self.handle != win32.INVALID_HANDLE_VALUE) {
                _ = win32.CloseHandle(self.handle);
            }
            std.heap.smp_allocator.destroy(self);
            return 0;
        }
        return prev - 1;
    }

    fn read(This: *win32.IStream, pv: [*]u8, cb: win32.ULONG, pcbRead: ?*win32.ULONG) callconv(.winapi) win32.HRESULT {
        const self = fromStream(This);
        if (cb == 0) {
            if (pcbRead) |pr| pr.* = 0;
            return win32.S_OK;
        }

        if (self.handle == win32.INVALID_HANDLE_VALUE) {
            if (pcbRead) |pr| pr.* = 0;
            return win32.S_FALSE;
        }

        var cur_offset = self.current_offset.load(.acquire);
        var to_read: u32 = 0;
        var file_offset: u64 = 0;

        while (true) {
            to_read = computeReadSlice(cur_offset, self.window_length, cb);
            if (to_read == 0) {
                if (pcbRead) |pr| pr.* = 0;
                return win32.S_FALSE;
            }
            file_offset = self.window_start + cur_offset;
            const next_offset = cur_offset + to_read;
            if (self.current_offset.cmpxchgWeak(cur_offset, next_offset, .release, .acquire)) |actual| {
                cur_offset = actual;
            } else {
                break;
            }
        }

        var ov = win32.OVERLAPPED{
            .Offset = @truncate(file_offset),
            .OffsetHigh = @truncate(file_offset >> 32),
        };

        var bytes_read: win32.DWORD = 0;
        if (win32.ReadFile(self.handle, pv, to_read, &bytes_read, @ptrCast(&ov)) == win32.FALSE) {
            // Nothing was read: undo the advance reserved above.
            _ = self.current_offset.fetchSub(to_read, .release);
            const err = win32.GetLastError();
            if (err == 38) { // ERROR_HANDLE_EOF
                if (pcbRead) |pr| pr.* = 0;
                return win32.S_FALSE;
            }
            return win32.E_FAIL;
        }

        if (bytes_read < to_read) {
            const short_fall = to_read - bytes_read;
            _ = self.current_offset.fetchSub(short_fall, .release);
        }

        if (pcbRead) |pr| pr.* = bytes_read;
        return if (bytes_read == cb) win32.S_OK else win32.S_FALSE;
    }

    fn write(_: *win32.IStream, _: [*]const u8, _: win32.ULONG, _: ?*win32.ULONG) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn seek(
        This: *win32.IStream,
        dlibMove: win32.LARGE_INTEGER,
        dwOrigin: win32.DWORD,
        plibNewPosition: ?*win32.ULARGE_INTEGER,
    ) callconv(.winapi) win32.HRESULT {
        const self = fromStream(This);
        const cur_pos = self.current_offset.load(.acquire);
        const new_pos = computeSeekPosition(dwOrigin, dlibMove, cur_pos, self.window_length) orelse return win32.E_INVALIDARG;

        self.current_offset.store(new_pos, .release);
        if (plibNewPosition) |pnp| {
            pnp.* = new_pos;
        }
        return win32.S_OK;
    }

    fn setSize(_: *win32.IStream, _: win32.ULARGE_INTEGER) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn copyTo(
        _: *win32.IStream,
        _: *win32.IStream,
        _: win32.ULARGE_INTEGER,
        _: ?*win32.ULARGE_INTEGER,
        _: ?*win32.ULARGE_INTEGER,
    ) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn commit(_: *win32.IStream, _: win32.DWORD) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn revert(_: *win32.IStream) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn lockRegion(_: *win32.IStream, _: win32.ULARGE_INTEGER, _: win32.ULARGE_INTEGER, _: win32.DWORD) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn unlockRegion(_: *win32.IStream, _: win32.ULARGE_INTEGER, _: win32.ULARGE_INTEGER, _: win32.DWORD) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }

    fn stat(This: *win32.IStream, pstatstg: *win32.STATSTG, grfStatFlag: win32.DWORD) callconv(.winapi) win32.HRESULT {
        _ = grfStatFlag;
        const self = fromStream(This);
        pstatstg.* = std.mem.zeroes(win32.STATSTG);
        pstatstg.type = win32.STGTY_STREAM;
        pstatstg.cbSize = self.window_length;
        pstatstg.grfMode = 0;
        return win32.S_OK;
    }

    fn clone(_: *win32.IStream, _: *?*win32.IStream) callconv(.winapi) win32.HRESULT {
        return win32.E_NOTIMPL;
    }
};

/// Serve `rel_path` (subpath after `/media/`, still percent-encoded) for a WebView2 request.
/// Returns true if handled, false otherwise.
pub fn handle(
    env: *webview2.ICoreWebView2Environment,
    args: *webview2.ICoreWebView2WebResourceRequestedEventArgs,
    req: *webview2.ICoreWebView2WebResourceRequest,
    rel_path: []const u8,
) bool {
    const gpa = std.heap.smp_allocator;
    const root = root_handle orelse {
        finishWithError(env, args, 404, "Not Found");
        return true;
    };

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const sanitized = range.sanitizePath(fba.allocator(), rel_path) catch |err| {
        switch (err) {
            error.PathTraversal => finishWithError(env, args, 403, "Forbidden"),
            error.NotFound, error.OutOfMemory => finishWithError(env, args, 404, "Not Found"),
        }
        return true;
    };

    const opened = open.openInRoot(root, sanitized, root_policy) catch |err| {
        switch (err) {
            error.Forbidden => finishWithError(env, args, 403, "Forbidden"),
            error.NotFound, error.NotAFile => finishWithError(env, args, 404, "Not Found"),
            error.Unexpected => finishWithError(env, args, 500, "Internal Server Error"),
        }
        return true;
    };
    defer opened.close();

    const mime = range.mimeForExtension(std.fs.path.extension(sanitized));

    // Read Range header if present
    var range_header_val: ?[]const u8 = null;
    var req_headers_opt: ?*webview2.ICoreWebView2HttpRequestHeaders = null;
    if (req.lpVtbl.get_Headers(req, @ptrCast(&req_headers_opt)) >= 0) {
        if (req_headers_opt) |headers| {
            defer _ = headers.lpVtbl.Release(headers);
            const range_w = std.unicode.utf8ToUtf16LeStringLiteral("Range");
            var val_w: ?win32.LPWSTR = null;
            if (headers.lpVtbl.GetHeader(headers, range_w, &val_w) >= 0 and val_w != null) {
                defer win32.CoTaskMemFree(val_w);
                const v_len = std.mem.indexOfScalar(u16, std.mem.span(val_w.?), 0) orelse std.mem.span(val_w.?).len;
                range_header_val = std.unicode.utf16LeToUtf8Alloc(gpa, val_w.?[0..v_len]) catch null;
            }
        }
    }
    defer if (range_header_val) |v| gpa.free(v);

    const range_res: range.RangeResult = if (range_header_val) |h|
        range.parseRange(h, opened.size)
    else
        .full;

    switch (range_res) {
        .unsatisfiable => {
            finishWith416(env, args, opened.size, mime);
            return true;
        },
        .full => {
            const end = if (opened.size == 0) 0 else opened.size - 1;
            serveRange(env, args, opened, 0, end, opened.size, mime, false);
            return true;
        },
        .range => |r| {
            serveRange(env, args, opened, r.start, r.end, opened.size, mime, true);
            return true;
        },
    }
}

fn serveRange(
    env: *webview2.ICoreWebView2Environment,
    args: *webview2.ICoreWebView2WebResourceRequestedEventArgs,
    opened: open.Opened,
    start: u64,
    end: u64,
    file_size: u64,
    mime: []const u8,
    is_partial: bool,
) void {
    const gpa = std.heap.smp_allocator;

    const length: u64 = if (file_size == 0 or start > end) 0 else end - start + 1;

    // Duplicate handle for the stream; stream takes ownership on success
    var dup_handle: win32.HANDLE = win32.INVALID_HANDLE_VALUE;
    const cur_proc = win32.GetCurrentProcess();
    if (win32.DuplicateHandle(
        cur_proc,
        opened.handle,
        cur_proc,
        &dup_handle,
        0,
        win32.FALSE,
        win32.DUPLICATE_SAME_ACCESS,
    ) == win32.FALSE) {
        finishWithError(env, args, 500, "Internal Server Error");
        return;
    }
    // The stream owns dup_handle once created (closed on its last Release).
    const stream = FileWindowStream.create(dup_handle, start, length) catch {
        _ = win32.CloseHandle(dup_handle); // unused duplicate: nothing else to undo
        finishWithError(env, args, 500, "Internal Server Error");
        return;
    };
    defer stream.asStream().release();

    const status_code: c_int = if (is_partial) 206 else 200;
    const status_text_w = if (status_code == 206)
        std.unicode.utf8ToUtf16LeStringLiteral("Partial Content")
    else
        std.unicode.utf8ToUtf16LeStringLiteral("OK");

    // The app's extra headers (security.headers), as on app:// responses.
    const extra = security.headerLines(gpa, App.current_security.headers) catch return;
    defer gpa.free(extra);
    var hdr_str: []u8 = undefined;
    if (status_code == 206) {
        hdr_str = std.fmt.allocPrint(
            gpa,
            "Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\nContent-Range: bytes {d}-{d}/{d}\r\n{s}",
            .{ mime, length, start, end, file_size, extra },
        ) catch return;
    } else {
        hdr_str = std.fmt.allocPrint(
            gpa,
            "Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: {d}\r\n{s}",
            .{ mime, length, extra },
        ) catch return;
    }
    defer gpa.free(hdr_str);

    const hdr_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, hdr_str) catch return;
    defer gpa.free(hdr_w);

    var resp_opt: ?*webview2.ICoreWebView2WebResourceResponse = null;
    const hr = env.createWebResourceResponse(stream.asStream(), status_code, status_text_w, hdr_w.ptr, &resp_opt);
    if (hr >= 0) {
        if (resp_opt) |resp| {
            defer resp.release();
            const put_hr = args.lpVtbl.put_Response(args, resp);
            if (put_hr < 0) log.err("media: put_Response failed (0x{X})", .{@as(u32, @bitCast(put_hr))});
        }
    } else {
        finishWithError(env, args, 500, "Internal Server Error");
    }
}

fn finishWithError(
    env: *webview2.ICoreWebView2Environment,
    args: *webview2.ICoreWebView2WebResourceRequestedEventArgs,
    status: c_int,
    reason: []const u8,
) void {
    const gpa = std.heap.smp_allocator;
    const reason_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, reason) catch return;
    defer gpa.free(reason_w);
    const err_hdr_w = std.unicode.utf8ToUtf16LeStringLiteral("Content-Type: text/plain\r\nContent-Length: 0\r\n");

    const empty_stream = FileWindowStream.createEmpty() catch return;
    defer empty_stream.asStream().release();

    var resp_opt: ?*webview2.ICoreWebView2WebResourceResponse = null;
    const hr = env.createWebResourceResponse(empty_stream.asStream(), status, reason_w.ptr, err_hdr_w.ptr, &resp_opt);
    if (hr >= 0) {
        if (resp_opt) |resp| {
            defer resp.release();
            const put_hr = args.lpVtbl.put_Response(args, resp);
            if (put_hr < 0) log.err("media: put_Response failed (0x{X})", .{@as(u32, @bitCast(put_hr))});
        }
    }
}

fn finishWith416(
    env: *webview2.ICoreWebView2Environment,
    args: *webview2.ICoreWebView2WebResourceRequestedEventArgs,
    file_size: u64,
    mime: []const u8,
) void {
    const gpa = std.heap.smp_allocator;
    const reason_w = std.unicode.utf8ToUtf16LeStringLiteral("Range Not Satisfiable");
    const hdr_str = std.fmt.allocPrint(
        gpa,
        "Content-Type: {s}\r\nAccept-Ranges: bytes\r\nContent-Length: 0\r\nContent-Range: bytes */{d}\r\n",
        .{ mime, file_size },
    ) catch return;
    defer gpa.free(hdr_str);
    const hdr_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, hdr_str) catch return;
    defer gpa.free(hdr_w);

    const empty_stream = FileWindowStream.createEmpty() catch return;
    defer empty_stream.asStream().release();

    var resp_opt: ?*webview2.ICoreWebView2WebResourceResponse = null;
    const hr = env.createWebResourceResponse(empty_stream.asStream(), 416, reason_w, hdr_w.ptr, &resp_opt);
    if (hr >= 0) {
        if (resp_opt) |resp| {
            defer resp.release();
            const put_hr = args.lpVtbl.put_Response(args, resp);
            if (put_hr < 0) log.err("media: put_Response failed (0x{X})", .{@as(u32, @bitCast(put_hr))});
        }
    }
}

test "media_scheme windows: pure window and seek arithmetic" {
    // Read slice calculations
    try std.testing.expectEqual(@as(u32, 100), computeReadSlice(0, 1000, 100));
    try std.testing.expectEqual(@as(u32, 50), computeReadSlice(950, 1000, 100));
    try std.testing.expectEqual(@as(u32, 0), computeReadSlice(1000, 1000, 100));
    try std.testing.expectEqual(@as(u32, 0), computeReadSlice(1050, 1000, 100));
    try std.testing.expectEqual(@as(u32, 10), computeReadSlice(0, 10, 100));

    // Seek SET calculations
    try std.testing.expectEqual(@as(?u64, 0), computeSeekPosition(win32.STREAM_SEEK_SET, 0, 50, 100));
    try std.testing.expectEqual(@as(?u64, 25), computeSeekPosition(win32.STREAM_SEEK_SET, 25, 50, 100));
    try std.testing.expectEqual(@as(?u64, null), computeSeekPosition(win32.STREAM_SEEK_SET, -1, 50, 100));

    // Seek CUR calculations
    try std.testing.expectEqual(@as(?u64, 60), computeSeekPosition(win32.STREAM_SEEK_CUR, 10, 50, 100));
    try std.testing.expectEqual(@as(?u64, 40), computeSeekPosition(win32.STREAM_SEEK_CUR, -10, 50, 100));
    try std.testing.expectEqual(@as(?u64, null), computeSeekPosition(win32.STREAM_SEEK_CUR, -51, 50, 100));

    // Seek END calculations
    try std.testing.expectEqual(@as(?u64, 100), computeSeekPosition(win32.STREAM_SEEK_END, 0, 50, 100));
    try std.testing.expectEqual(@as(?u64, 90), computeSeekPosition(win32.STREAM_SEEK_END, -10, 50, 100));
    try std.testing.expectEqual(@as(?u64, null), computeSeekPosition(win32.STREAM_SEEK_END, -101, 50, 100));
}

test {
    std.testing.refAllDecls(@This());
}
