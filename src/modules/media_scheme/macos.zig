//! `app://app/media/...` on macOS: range-aware streaming of files below a
//! media root through the WKURLSchemeHandler (src/platform/macos/scheme.zig).
//!
//! The response head (200/206/416, Content-Range, Accept-Ranges) is sent at
//! once on the main thread. The body is read by a worker thread in 256 KiB
//! chunks, each handed to WebKit on the main thread; the worker waits for
//! that before reading on, so at most one chunk is in memory per request.
//! `stopURLSchemeTask:` marks the stream stopped: after that no method of
//! the task is called (WebKit raises an exception if one is).

const std = @import("std");
const cocoa = @import("../../platform/macos/cocoa.zig");
const ShellMod = @import("../../platform/macos/Shell.zig");
const range = @import("../media/range.zig");
const open = @import("../media/open.zig");

const Object = cocoa.Object;
const c = std.c;
const log = std.log.scoped(.oriel);

const chunk_size = 256 * 1024;

/// Media root for `app://app/media/`, set by `setRoot`; main thread only.
var root_fd: ?c.fd_t = null;
var root_policy: open.SymlinkPolicy = .inside_root;

/// Serve the files below `path` at `app://app/media/<path>` (replacing any
/// previous root). Call on the main thread, e.g. from `Config.setup`.
pub fn setRoot(path: []const u8, policy: open.SymlinkPolicy) !void {
    const fd = try open.openRoot(path);
    clearRoot();
    root_fd = fd;
    root_policy = policy;
}

/// Stop serving `app://app/media/` (requests get 404). Streams already
/// running keep their own file descriptors.
pub fn clearRoot() void {
    if (root_fd) |fd| open.closeRoot(fd);
    root_fd = null;
}

/// A running body stream. Owned by its worker until it queues `finish`,
/// then by the main thread (which frees it).
const Stream = struct {
    task: cocoa.id, // retained
    fd: c.fd_t,
    remaining: u64,
    /// Set on the main thread by stopURLSchemeTask; read by the worker.
    stopped: std.atomic.Value(bool) = .init(false),
    /// Signalled by the main thread after each chunk was handed over.
    acked: cocoa.Semaphore,
    // Current chunk (worker fills, main thread reads), and whether the
    // stream ended with an error.
    buf: [chunk_size]u8 = undefined,
    len: usize = 0,
    failed: bool = false,
};

/// Streams in flight, for stopURLSchemeTask (main thread only).
var active: std.ArrayList(*Stream) = .empty;

/// Serve `rel_path` (the part after `/media/`, still percent-encoded) for a
/// WKURLSchemeTask. Called by the `app://` handler on the main thread.
pub fn handle(task: Object, url: Object, rel_path: []const u8) void {
    const root = root_fd orelse return respondEmpty(task, url, 404, "text/plain", null);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&path_buf);
    const sanitized = range.sanitizePath(fba.allocator(), rel_path) catch |err| return switch (err) {
        error.PathTraversal => respondEmpty(task, url, 403, "text/plain", null),
        error.NotFound, error.OutOfMemory => respondEmpty(task, url, 404, "text/plain", null),
    };
    const file = open.openInRoot(root, sanitized, root_policy) catch |err| return switch (err) {
        error.Forbidden => respondEmpty(task, url, 403, "text/plain", null),
        error.NotFound, error.NotAFile => respondEmpty(task, url, 404, "text/plain", null),
        error.Unexpected => respondEmpty(task, url, 500, "text/plain", null),
    };
    const mime = range.mimeForExtension(std.fs.path.extension(sanitized));

    const request = task.msgSend(Object, "request", .{});
    const range_hdr: ?[:0]const u8 = if (cocoa.nsString("Range")) |name| blk: {
        defer name.release();
        break :blk cocoa.utf8(request.msgSend(Object, "valueForHTTPHeaderField:", .{name}));
    } else null;
    const res: range.RangeResult = if (range_hdr) |h| range.parseRange(h, file.size) else .full;
    const r: range.Range = switch (res) {
        .unsatisfiable => {
            file.close();
            var cr_buf: [64]u8 = undefined;
            const cr = std.fmt.bufPrint(&cr_buf, "bytes */{d}", .{file.size}) catch unreachable; // 28 bytes max
            return respondEmpty(task, url, 416, mime, cr);
        },
        .full => .{ .start = 0, .end = file.size -| 1 },
        .range => |r| r,
    };
    const length: u64 = if (file.size == 0) 0 else r.length();
    if (c.lseek(file.fd, @intCast(r.start), c.SEEK.SET) < 0) {
        file.close();
        return respondEmpty(task, url, 500, "text/plain", null);
    }

    var cr_buf: [96]u8 = undefined;
    const content_range: ?[]const u8 = if (res == .range)
        std.fmt.bufPrint(&cr_buf, "bytes {d}-{d}/{d}", .{ r.start, r.end, file.size }) catch unreachable
    else
        null;
    if (!sendHead(task, url, if (res == .range) 206 else 200, mime, length, content_range)) {
        file.close();
        return;
    }
    if (length == 0) {
        file.close();
        task.msgSend(void, "didFinish", .{});
        return;
    }

    const gpa = std.heap.smp_allocator;
    const acked = cocoa.Semaphore.create() catch return failNow(task, file);
    const stream = gpa.create(Stream) catch {
        acked.deinit();
        return failNow(task, file);
    };
    stream.* = .{ .task = task.retain().value, .fd = file.fd, .remaining = length, .acked = acked };
    active.append(gpa, stream) catch {
        task.release();
        destroy(stream);
        return failNowTask(task);
    };
    const thread = std.Thread.spawn(.{}, worker, .{stream}) catch {
        _ = unregister(stream);
        task.release();
        destroy(stream);
        return failNowTask(task);
    };
    thread.detach();
}

/// stopURLSchemeTask: for our streams, stop calling the task (main thread).
pub fn stop(task: Object) void {
    for (active.items) |s| {
        if (s.task == task.value) s.stopped.store(true, .release);
    }
}

fn worker(stream: *Stream) void {
    while (stream.remaining > 0 and !stream.stopped.load(.acquire)) {
        const want: usize = @intCast(@min(stream.remaining, chunk_size));
        const n = c.read(stream.fd, &stream.buf, want);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) { // error, or the file shrank under us
            stream.failed = true;
            break;
        }
        stream.len = @intCast(n);
        stream.remaining -= stream.len;
        ShellMod.dispatchWithCleanup(&deliverChunk, stream, &abandonChunk);
        stream.acked.wait();
    }
    // Hand the stream to the main thread; don't touch it after this.
    ShellMod.dispatchWithCleanup(&finish, stream, &abandonFinish);
}

fn deliverChunk(ctx: ?*anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(ctx.?));
    defer stream.acked.signal();
    if (stream.stopped.load(.acquire)) return;
    const data = cocoa.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ &stream.buf, @as(c_ulong, stream.len) });
    (Object{ .value = stream.task }).msgSend(void, "didReceiveData:", .{data});
}

/// Shutdown: the chunk won't be delivered; let the worker finish.
fn abandonChunk(ctx: ?*anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(ctx.?));
    stream.stopped.store(true, .release);
    stream.acked.signal();
}

fn finish(ctx: ?*anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(ctx.?));
    _ = unregister(stream);
    const task: Object = .{ .value = stream.task };
    if (!stream.stopped.load(.acquire)) {
        if (stream.failed) failTask(task) else task.msgSend(void, "didFinish", .{});
    }
    task.release();
    destroy(stream);
}

/// Queued after shutdown (from the worker). On the main thread: free it.
/// Elsewhere only the file is closed: the stream stays in `active`, which
/// the main thread may still walk (WebKit calls stopURLSchemeTask while the
/// windows close), so the struct and the task reference are leaked; the
/// process is exiting.
fn abandonFinish(ctx: ?*anyopaque) void {
    const stream: *Stream = @ptrCast(@alignCast(ctx.?));
    if (cocoa.isMainThread()) {
        _ = unregister(stream);
        (Object{ .value = stream.task }).release();
        destroy(stream);
    } else {
        _ = c.close(stream.fd);
    }
}

fn unregister(stream: *Stream) bool {
    for (active.items, 0..) |s, i| {
        if (s == stream) {
            _ = active.swapRemove(i);
            return true;
        }
    }
    return false;
}

fn destroy(stream: *Stream) void {
    _ = c.close(stream.fd);
    stream.acked.deinit();
    std.heap.smp_allocator.destroy(stream);
}

fn failNow(task: Object, file: open.Opened) void {
    file.close();
    failNowTask(task);
}

fn failNowTask(task: Object) void {
    log.err("app://app/media: out of memory", .{});
    failTask(task);
}

fn failTask(task: Object) void {
    const domain = cocoa.nsString("oriel-media") orelse return;
    defer domain.release();
    const err = cocoa.class("NSError").msgSend(Object, "errorWithDomain:code:userInfo:", .{ domain, @as(isize, 500), cocoa.nil });
    task.msgSend(void, "didFailWithError:", .{err});
}

fn setHeader(headers: Object, name: []const u8, value: []const u8) void {
    const key = cocoa.nsString(name) orelse return;
    defer key.release();
    const val = cocoa.nsString(value) orelse return;
    defer val.release();
    headers.msgSend(void, "setObject:forKey:", .{ val, key });
}

/// didReceiveResponse: with the media headers. False (task already failed)
/// if the response couldn't be built.
fn sendHead(task: Object, url: Object, status: isize, mime: []const u8, length: u64, content_range: ?[]const u8) bool {
    const headers = cocoa.new(cocoa.class("NSMutableDictionary"));
    defer headers.release();
    var len_buf: [24]u8 = undefined;
    setHeader(headers, "Content-Type", mime);
    setHeader(headers, "Content-Length", std.fmt.bufPrint(&len_buf, "{d}", .{length}) catch unreachable); // 20 digits max
    setHeader(headers, "Accept-Ranges", "bytes");
    if (content_range) |cr| setHeader(headers, "Content-Range", cr);
    const version = cocoa.nsString("HTTP/1.1") orelse {
        failTask(task);
        return false;
    };
    defer version.release();
    const response = cocoa.class("NSHTTPURLResponse").msgSend(Object, "alloc", .{})
        .msgSend(Object, "initWithURL:statusCode:HTTPVersion:headerFields:", .{ url, status, version, headers });
    if (response.value == null) {
        failTask(task);
        return false;
    }
    defer response.release();
    task.msgSend(void, "didReceiveResponse:", .{response});
    return true;
}

fn respondEmpty(task: Object, url: Object, status: isize, mime: []const u8, content_range: ?[]const u8) void {
    if (sendHead(task, url, status, mime, 0, content_range)) task.msgSend(void, "didFinish", .{});
}

test {
    std.testing.refAllDecls(@This());
}
