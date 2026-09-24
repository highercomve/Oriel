//! Windows system clipboard implementation using Win32 API.
//!
//! Formats:
//! - Text: CF_UNICODETEXT (UTF-8 <-> UTF-16, NUL-terminated)
//! - Images: registered "PNG" format and CF_DIB (BITMAPINFOHEADER + bottom-up BGRA)
//!
//! Threading:
//! Clipboard operations require access to the window/main thread. Calls from worker
//! threads are dispatched to the main thread via Shell.runOnMainThread or Shell.dispatchWithCleanup.

const std = @import("std");
const zigimg = @import("zigimg");
const win32 = @import("../../platform/windows/win32.zig");
const ShellMod = @import("../../platform/windows/Shell.zig");
const oriel = @import("../../oriel.zig");
pub const common = @import("common.zig");

const log = std.log.scoped(.oriel);

pub const TextCallback = *const fn (result: anyerror![]const u8, user_data: ?*anyopaque) void;
pub const ImageCallback = *const fn (result: anyerror!?[]const u8, user_data: ?*anyopaque) void;

var cf_png_cached: ?win32.UINT = null;

fn getCfPng() win32.UINT {
    if (cf_png_cached) |f| return f;
    const png_w = std.unicode.utf8ToUtf16LeStringLiteral("PNG");
    const f = win32.RegisterClipboardFormatW(png_w);
    cf_png_cached = f;
    return f;
}

fn openClipboard() !void {
    const hwnd = ShellMod.host_hwnd;
    var tries: usize = 0;
    while (tries < 10) : (tries += 1) {
        if (win32.OpenClipboard(hwnd) == win32.TRUE) return;
        win32.Sleep(10);
    }
    return error.ClipboardOpenFailed;
}

// ---------------------------------------------------------------------------
// Main thread direct implementations
// ---------------------------------------------------------------------------

fn readTextMain(gpa: std.mem.Allocator) ![]u8 {
    try openClipboard();
    // CloseClipboard return value ignored in defer; clipboard cannot be un-closed
    defer _ = win32.CloseClipboard();

    const handle = win32.GetClipboardData(win32.CF_UNICODETEXT) orelse return gpa.dupe(u8, "");
    const hMem: win32.HGLOBAL = @ptrCast(handle);
    const size = win32.GlobalSize(hMem);
    if (size < 2) return gpa.dupe(u8, "");

    const ptr = win32.GlobalLock(hMem) orelse return error.GlobalLockFailed;
    // GlobalUnlock returns 0 when lock count reaches zero; this is normal and not an error
    defer _ = win32.GlobalUnlock(hMem);

    const max_u16 = size / 2;
    const u16_ptr: [*]const u16 = @ptrCast(@alignCast(ptr));
    var len: usize = 0;
    while (len < max_u16 and u16_ptr[len] != 0) : (len += 1) {}

    return std.unicode.utf16LeToUtf8Alloc(gpa, u16_ptr[0..len]);
}

fn writeTextMain(text: []const u8) !void {
    const u16_slice = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, text);
    defer std.heap.smp_allocator.free(u16_slice);

    const byte_len = (u16_slice.len + 1) * @sizeOf(u16);
    const hMem = win32.GlobalAlloc(win32.GMEM_MOVEABLE, byte_len) orelse return error.OutOfMemory;
    var success = false;
    defer if (!success) {
        // GlobalFree returns NULL on success; failure during error cleanup cannot be recovered
        _ = win32.GlobalFree(hMem);
    };

    const ptr = win32.GlobalLock(hMem) orelse return error.GlobalLockFailed;
    const dest: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(dest[0..u16_slice.len], u16_slice);
    dest[u16_slice.len] = 0;
    // GlobalUnlock returns 0 when lock count reaches zero; safe to ignore
    _ = win32.GlobalUnlock(hMem);

    try openClipboard();
    // CloseClipboard return value ignored in defer; clipboard cannot be un-closed
    defer _ = win32.CloseClipboard();

    if (win32.EmptyClipboard() == win32.FALSE) return error.ClipboardEmptyFailed;
    if (win32.SetClipboardData(win32.CF_UNICODETEXT, hMem) == null) return error.SetClipboardDataFailed;
    success = true;
}

fn encodePng(gpa: std.mem.Allocator, width: u32, height: u32, rgba_pixels: []const u8) ![]u8 {
    var img = try zigimg.Image.create(gpa, width, height, .rgba32);
    defer img.deinit(gpa);
    @memcpy(img.pixels.asBytes(), rgba_pixels);

    var buf_size: usize = @max(8192, @as(usize, width) * @as(usize, height) * 4 + 4096);
    var out_buf = try gpa.alloc(u8, buf_size);
    defer gpa.free(out_buf);

    while (true) {
        if (img.writeToMemory(gpa, out_buf, .{ .png = .{} })) |res| {
            return try gpa.dupe(u8, res);
        } else |err| switch (err) {
            error.NoSpaceLeft, error.WriteFailed => {
                buf_size *= 2;
                gpa.free(out_buf);
                out_buf = try gpa.alloc(u8, buf_size);
            },
            else => return err,
        }
    }
}

fn readImageMain(gpa: std.mem.Allocator) !?[]u8 {
    try openClipboard();
    // CloseClipboard return value ignored in defer; clipboard cannot be un-closed
    defer _ = win32.CloseClipboard();

    const cf_png = getCfPng();
    if (cf_png != 0 and win32.IsClipboardFormatAvailable(cf_png) == win32.TRUE) {
        if (win32.GetClipboardData(cf_png)) |handle| {
            const hMem: win32.HGLOBAL = @ptrCast(handle);
            const size = win32.GlobalSize(hMem);
            if (size > 0) {
                if (win32.GlobalLock(hMem)) |ptr| {
                    // GlobalUnlock returns 0 when lock count reaches zero; safe to ignore
                    defer _ = win32.GlobalUnlock(hMem);
                    const raw_bytes = @as([*]const u8, @ptrCast(ptr))[0..size];
                    // GlobalSize rounds up to heap allocation granularity; clipboard data for
                    // registered "PNG" may carry trailing padding, so trim to the PNG IEND chunk.
                    const png_trimmed = common.trimPngPadding(raw_bytes);
                    return try gpa.dupe(u8, png_trimmed);
                }
            }
        }
    }

    var format: ?win32.UINT = null;
    if (win32.IsClipboardFormatAvailable(win32.CF_DIBV5) == win32.TRUE) {
        format = win32.CF_DIBV5;
    } else if (win32.IsClipboardFormatAvailable(win32.CF_DIB) == win32.TRUE) {
        format = win32.CF_DIB;
    }

    if (format) |fmt| {
        if (win32.GetClipboardData(fmt)) |handle| {
            const hMem: win32.HGLOBAL = @ptrCast(handle);
            const size = win32.GlobalSize(hMem);
            if (size >= 40) {
                if (win32.GlobalLock(hMem)) |ptr| {
                    // GlobalUnlock returns 0 when lock count reaches zero; safe to ignore
                    defer _ = win32.GlobalUnlock(hMem);
                    const dib_bytes = @as([*]const u8, @ptrCast(ptr))[0..size];
                    var rgba = try common.dibToRgba(gpa, dib_bytes);
                    defer rgba.deinit(gpa);
                    return try encodePng(gpa, rgba.width, rgba.height, rgba.pixels);
                }
            }
        }
    }

    return null;
}

fn writeImageMain(png_bytes: []const u8) !void {
    var img = zigimg.Image.fromMemory(std.heap.smp_allocator, png_bytes) catch return error.InvalidImage;
    defer img.deinit(std.heap.smp_allocator);
    img.convert(std.heap.smp_allocator, .rgba32) catch return error.InvalidImage;

    const dib = common.rgbaToDib(std.heap.smp_allocator, @intCast(img.width), @intCast(img.height), img.pixels.asBytes()) catch return error.InvalidImage;
    defer std.heap.smp_allocator.free(dib);

    const hDib = win32.GlobalAlloc(win32.GMEM_MOVEABLE, dib.len) orelse return error.OutOfMemory;
    var dib_success = false;
    defer if (!dib_success) {
        // GlobalFree returns NULL on success; failure during error cleanup cannot be recovered
        _ = win32.GlobalFree(hDib);
    };

    const dib_ptr = win32.GlobalLock(hDib) orelse return error.GlobalLockFailed;
    @memcpy(@as([*]u8, @ptrCast(dib_ptr))[0..dib.len], dib);
    // GlobalUnlock returns 0 when lock count reaches zero; safe to ignore
    _ = win32.GlobalUnlock(hDib);

    const cf_png = getCfPng();
    var valid_hPng: ?win32.HGLOBAL = null;
    if (cf_png != 0) {
        if (win32.GlobalAlloc(win32.GMEM_MOVEABLE, png_bytes.len)) |hp| {
            if (win32.GlobalLock(hp)) |png_ptr| {
                @memcpy(@as([*]u8, @ptrCast(png_ptr))[0..png_bytes.len], png_bytes);
                // GlobalUnlock returns 0 when lock count reaches zero; safe to ignore
                _ = win32.GlobalUnlock(hp);
                valid_hPng = hp;
            } else {
                // Lock failed: free the allocated handle so uninitialized memory is not passed to SetClipboardData
                _ = win32.GlobalFree(hp);
            }
        }
    }
    var png_success = false;
    defer if (valid_hPng != null and !png_success) {
        // GlobalFree returns NULL on success; failure during error cleanup cannot be recovered
        _ = win32.GlobalFree(valid_hPng.?);
    };

    try openClipboard();
    // CloseClipboard return value ignored in defer; clipboard cannot be un-closed
    defer _ = win32.CloseClipboard();

    if (win32.EmptyClipboard() == win32.FALSE) return error.ClipboardEmptyFailed;

    if (win32.SetClipboardData(win32.CF_DIB, hDib) == null) return error.SetClipboardDataFailed;
    dib_success = true;

    if (valid_hPng) |hp| {
        if (win32.SetClipboardData(cf_png, hp) != null) {
            png_success = true;
        } else {
            log.warn("SetClipboardData for PNG format failed ({d}); DIB format was set", .{win32.GetLastError()});
        }
    }
}

// ---------------------------------------------------------------------------
// Worker thread marshaling
// ---------------------------------------------------------------------------

const WorkerCall = struct {
    op: enum { read_text, write_text, read_image, write_image },
    gpa: std.mem.Allocator,
    input: ?[]const u8 = null,
    out_data: ?[]u8 = null,
    err: ?anyerror = null,

    fn run(self: *@This()) void {
        switch (self.op) {
            .read_text => {
                if (readTextMain(self.gpa)) |data| {
                    self.out_data = data;
                } else |e| {
                    self.err = e;
                }
            },
            .write_text => {
                if (writeTextMain(self.input.?)) {} else |e| {
                    self.err = e;
                }
            },
            .read_image => {
                if (readImageMain(self.gpa)) |data| {
                    self.out_data = data;
                } else |e| {
                    self.err = e;
                }
            },
            .write_image => {
                if (writeImageMain(self.input.?)) {} else |e| {
                    self.err = e;
                }
            },
        }
    }
};

fn dispatchSync(call: *WorkerCall) !void {
    try ShellMod.runOnMainThread(WorkerCall, call, WorkerCall.run);
    if (call.err) |e| return e;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

pub fn readText(gpa: std.mem.Allocator) ![]u8 {
    var call = WorkerCall{
        .op = .read_text,
        .gpa = gpa,
    };
    try dispatchSync(&call);
    return call.out_data orelse try gpa.dupe(u8, "");
}

pub fn readImage(gpa: std.mem.Allocator) !?[]u8 {
    var call = WorkerCall{
        .op = .read_image,
        .gpa = gpa,
    };
    try dispatchSync(&call);
    return call.out_data;
}

pub fn writeText(text: []const u8) !void {
    var call = WorkerCall{
        .op = .write_text,
        .gpa = std.heap.smp_allocator,
        .input = text,
    };
    try dispatchSync(&call);
}

pub fn writeImage(png_bytes: []const u8) !void {
    var call = WorkerCall{
        .op = .write_image,
        .gpa = std.heap.smp_allocator,
        .input = png_bytes,
    };
    try dispatchSync(&call);
}

const AsyncTextReq = struct {
    callback: TextCallback,
    user_data: ?*anyopaque,

    fn run(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx orelse return));
        defer std.heap.smp_allocator.destroy(self);
        const res = readTextMain(std.heap.smp_allocator);
        if (res) |data| {
            defer std.heap.smp_allocator.free(data);
            self.callback(data, self.user_data);
        } else |err| {
            self.callback(err, self.user_data);
        }
    }

    fn cleanup(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx orelse return));
        defer std.heap.smp_allocator.destroy(self);
        self.callback(error.AppNotRunning, self.user_data);
    }
};

pub fn readTextAsync(callback: TextCallback, user_data: ?*anyopaque) void {
    if (ShellMod.main_thread_id == 0) {
        return callback(error.AppNotRunning, user_data);
    }
    const req = std.heap.smp_allocator.create(AsyncTextReq) catch |err| {
        return callback(err, user_data);
    };
    req.* = .{ .callback = callback, .user_data = user_data };
    if (ShellMod.main_thread_id != 0 and win32.GetCurrentThreadId() == ShellMod.main_thread_id) {
        AsyncTextReq.run(req);
    } else {
        ShellMod.dispatchWithCleanup(&AsyncTextReq.run, req, &AsyncTextReq.cleanup);
    }
}

const AsyncImageReq = struct {
    callback: ImageCallback,
    user_data: ?*anyopaque,

    fn run(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx orelse return));
        defer std.heap.smp_allocator.destroy(self);
        const res = readImageMain(std.heap.smp_allocator);
        if (res) |data| {
            defer if (data) |d| std.heap.smp_allocator.free(d);
            self.callback(data, self.user_data);
        } else |err| {
            self.callback(err, self.user_data);
        }
    }

    fn cleanup(ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx orelse return));
        defer std.heap.smp_allocator.destroy(self);
        self.callback(error.AppNotRunning, self.user_data);
    }
};

pub fn readImageAsync(callback: ImageCallback, user_data: ?*anyopaque) void {
    if (ShellMod.main_thread_id == 0) {
        return callback(error.AppNotRunning, user_data);
    }
    const req = std.heap.smp_allocator.create(AsyncImageReq) catch |err| {
        return callback(err, user_data);
    };
    req.* = .{ .callback = callback, .user_data = user_data };
    if (ShellMod.main_thread_id != 0 and win32.GetCurrentThreadId() == ShellMod.main_thread_id) {
        AsyncImageReq.run(req);
    } else {
        ShellMod.dispatchWithCleanup(&AsyncImageReq.run, req, &AsyncImageReq.cleanup);
    }
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    _ = getCfPng();
    return .{
        .module = "clipboard",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Win32 OpenClipboard/CF_UNICODETEXT", .{}),
    };
}

test {
    std.testing.refAllDecls(@This());
}
