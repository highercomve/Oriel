//! Model downloads on iOS, through NSURLSession: Zig's TLS needs the CA
//! certificates as files (`Certificate.Bundle.rescan`), and iOS keeps its
//! trust store where apps can't read it, so every HTTPS request from
//! `std.http.Client` fails verification there. NSURLSession verifies with
//! the system's trust, follows redirects and writes to a temporary file,
//! which the completion handler moves into place; the worker waiting here
//! reports progress from the task's byte counts.

const std = @import("std");
const apple = @import("../../platform/ios/apple.zig");
const blocks = @import("../../platform/apple/blocks.zig");
const Object = apple.objc.Object;

const log = std.log.scoped(.model_download);

const Done = struct {
    /// Where the finished download goes (an NSURL, borrowed).
    dest: Object,
    finished: std.atomic.Value(bool) = .init(false),
    status: i64 = 0,
    error_code: i64 = 0,
    moved: bool = false,
};

/// The task's completion handler, on NSURLSession's queue: the temporary
/// file at `location` is deleted when it returns, so move it now.
fn completed(block: *blocks.ContextBlock, location: apple.id, response: apple.id, err: apple.id) callconv(.c) void {
    const done: *Done = @ptrCast(@alignCast(block.ctx.?));
    defer done.finished.store(true, .release);
    if (err != null) {
        done.error_code = (Object{ .value = err }).msgSend(i64, "code", .{});
        return;
    }
    const resp: Object = .{ .value = response };
    if (resp.value != null and resp.getClass().?.respondsToSelector(apple.objc.sel("statusCode")))
        done.status = resp.msgSend(i64, "statusCode", .{});
    if (done.status != 200 or location == null) return;
    const fm = apple.class("NSFileManager").msgSend(Object, "defaultManager", .{});
    _ = fm.msgSend(apple.c.BOOL, "removeItemAtURL:error:", .{ done.dest, @as(?*anyopaque, null) });
    done.moved = apple.isTrue(fm.msgSend(apple.c.BOOL, "moveItemAtURL:toURL:error:", .{ Object{ .value = location }, done.dest, @as(?*anyopaque, null) }));
}

/// Download `url` to the file `path` (absolute), calling `progress(ctx,
/// done_mb, total_mb)` as megabytes arrive. Blocks until it's done.
pub fn fetch(
    io: std.Io,
    url: []const u8,
    path: []const u8,
    expected_mb: u32,
    ctx: anytype,
    comptime progress: fn (@TypeOf(ctx), u32, u32) void,
) !void {
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();

    const ns_url = apple.nsUrl(url);
    if (ns_url.value == null) return error.InvalidUrl;
    const ns_path = apple.nsString(path) orelse return error.InvalidPath;
    defer ns_path.release();
    const dest = apple.class("NSURL").msgSend(Object, "fileURLWithPath:", .{ns_path});

    var done: Done = .{ .dest = dest };
    var handler = blocks.contextBlock(completed, &done);
    const session = apple.class("NSURLSession").msgSend(Object, "sharedSession", .{});
    const task = session.msgSend(Object, "downloadTaskWithURL:completionHandler:", .{ ns_url, handler.ptr() });
    if (task.value == null) return error.DownloadFailed;
    task.msgSend(void, "resume", .{});

    var last_mb: i64 = -1;
    while (!done.finished.load(.acquire)) {
        io.sleep(.fromMilliseconds(250), .awake) catch |e| {
            task.msgSend(void, "cancel", .{});
            // The handler still points at `done`: wait for it (cancelled
            // tasks finish at once).
            while (!done.finished.load(.acquire)) std.atomic.spinLoopHint();
            return e;
        };
        const got = task.msgSend(i64, "countOfBytesReceived", .{}) >> 20;
        const want = task.msgSend(i64, "countOfBytesExpectedToReceive", .{});
        if (got != last_mb) {
            last_mb = got;
            progress(ctx, @intCast(got), if (want > 0) @intCast(want >> 20) else expected_mb);
        }
    }
    if (done.error_code != 0) {
        log.err("download {s}: NSURLErrorDomain {d}", .{ url, done.error_code });
        return error.DownloadFailed;
    }
    if (done.status != 200) {
        log.err("download {s}: HTTP {d}", .{ url, done.status });
        return error.BadHttpStatus;
    }
    if (!done.moved) return error.DownloadFailed;
}
