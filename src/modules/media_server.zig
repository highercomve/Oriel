//! Local HTTP server (http.zig) for streaming large local media to the
//! webview with HTTP range requests (RFC 9110 §14). Binds to 127.0.0.1 only.

const std = @import("std");
const httpz = @import("httpz");
const oriel = @import("../oriel.zig");
pub const range = @import("media/range.zig");
/// The `app://app/media/` side: `scheme.setRoot(path, policy)`.
pub const scheme = @import("media_scheme.zig");

const log = std.log.scoped(.media_server);

pub const open = @import("media/open.zig");
pub const SymlinkPolicy = open.SymlinkPolicy;

pub const Options = struct {
    /// Directory whose files are served (`/<path>` maps to `<root_dir>/<path>`).
    root_dir: []const u8,
    /// TCP port on 127.0.0.1.
    port: u16,
    /// Value of `Access-Control-Allow-Origin` on file responses: the page
    /// origin (`app://app` for embedded assets) or the dev server origin.
    allowed_origin: []const u8 = "app://app",
    symlink_policy: SymlinkPolicy = .inside_root,
};

pub const Handler = struct {
    options: Options,
    /// Root directory handle; files are opened beneath it.
    root: open.Root,
    io: std.Io,

    pub fn ping(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.header("Access-Control-Allow-Origin", "*");
        try res.json(.{ .pong = true, .server = "http.zig" }, .{});
    }

    pub fn handleOptions(self: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.header("Access-Control-Allow-Origin", self.options.allowed_origin);
        res.header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
        res.header("Access-Control-Allow-Headers", "Range, Content-Type, Accept");
        res.header("Access-Control-Expose-Headers", "Content-Range, Content-Length, Accept-Ranges");
        res.header("Access-Control-Max-Age", "86400");
        res.status = 204;
    }

    pub fn handleFile(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        // CORS headers for file routes
        res.header("Access-Control-Allow-Origin", self.options.allowed_origin);
        res.header("Access-Control-Expose-Headers", "Content-Range, Content-Length, Accept-Ranges");

        const raw_path = req.url.path;
        if (raw_path.len == 0) {
            res.status = 404;
            res.body = "Not Found";
            return;
        }

        // Strip leading '/' to get relative subpath
        const rel = if (raw_path[0] == '/') raw_path[1..] else raw_path;

        const sanitized = range.sanitizePath(res.arena, rel) catch |err| switch (err) {
            error.PathTraversal => {
                log.debug("rejected path traversal attempt: {s}", .{raw_path});
                res.status = 403;
                res.body = "Forbidden";
                return;
            },
            else => {
                res.status = 404;
                res.body = "Not Found";
                return;
            },
        };

        const opened = open.openInRoot(self.root, sanitized, self.options.symlink_policy) catch |err| {
            res.status = switch (err) {
                error.Forbidden => 403,
                error.NotFound, error.NotAFile => 404,
                error.Unexpected => 500,
            };
            res.body = @errorName(err);
            return;
        };
        var file: std.Io.File = opened.toFile();
        defer file.close(self.io);
        const file_size = opened.size;

        const ext = std.fs.path.extension(sanitized);
        const mime = range.mimeForExtension(ext);
        res.header("Content-Type", mime);
        res.header("Accept-Ranges", "bytes");

        const range_hdr = req.header("range");
        const range_res = if (range_hdr) |hdr|
            range.parseRange(hdr, file_size)
        else
            .full;

        switch (range_res) {
            .unsatisfiable => {
                res.status = 416;
                try res.headerOpts("Content-Range", try std.fmt.allocPrint(res.arena, "bytes */{d}", .{file_size}), .{});
                res.header("Content-Length", "0");
                try sendHeaders(res);
                res.written = true;
                return;
            },
            .full => {
                res.status = 200;
                try res.headerOpts("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{file_size}), .{});
                try sendHeaders(res);
                if (req.method == .HEAD) {
                    res.written = true;
                    return;
                }
                try streamFile(self.io, &file, res, 0, file_size);
            },
            .range => |r| {
                res.status = 206;
                try res.headerOpts("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{r.length()}), .{});
                try res.headerOpts("Content-Range", try std.fmt.allocPrint(res.arena, "bytes {d}-{d}/{d}", .{ r.start, r.end, file_size }), .{});
                try sendHeaders(res);
                if (req.method == .HEAD) {
                    res.written = true;
                    return;
                }
                try streamFile(self.io, &file, res, r.start, r.length());
            },
        }
    }
};

/// Send the response headers. Header values must outlive the handler (httpz
/// may serialize them again, e.g. for an error response), so they are
/// allocated in `res.arena`. On failure the connection state is unknown:
/// mark the response written and drop the connection instead of letting
/// httpz write a second response on it.
fn sendHeaders(res: *httpz.Response) !void {
    res.writeHeader() catch |err| {
        res.written = true;
        res.keepalive = false;
        return err;
    };
}

pub const Server = struct {
    handler: Handler,
    inner: httpz.Server(*Handler),
    thread: std.Thread,
    port: u16,
    io: std.Io,

    /// Start serving `options.root_dir` on 127.0.0.1:`options.port` from a
    /// background thread. `self` must stay at a fixed address until `stop`.
    pub fn start(self: *Server, io: std.Io, gpa: std.mem.Allocator, options: Options) !void {
        self.io = io;
        self.port = options.port;

        const root = try open.openRoot(options.root_dir);
        errdefer open.closeRoot(root);
        self.handler = .{ .options = options, .root = root, .io = io };

        self.inner = try httpz.Server(*Handler).init(io, gpa, .{ .address = .localhost(self.port) }, &self.handler);
        errdefer self.inner.deinit();

        var router = try self.inner.router(.{});
        router.get("/ping", Handler.ping, .{});
        router.options("/*", Handler.handleOptions, .{});
        router.get("/*", Handler.handleFile, .{});
        router.head("/*", Handler.handleFile, .{});

        self.thread = try self.inner.listenInNewThread();
    }

    pub fn stop(self: *Server) void {
        self.inner.stop();
        self.thread.join();
        self.inner.deinit();
        open.closeRoot(self.handler.root);
    }
};

/// Stream file data in fixed 64 KiB chunks directly to the HTTP connection.
/// Never buffers the whole file into memory, handling files > 4 GiB safely.
fn streamFile(io: std.Io, file: *std.Io.File, res: *httpz.Response, start: u64, length: u64) !void {
    var buf: [64 * 1024]u8 = undefined;
    var remaining = length;
    var offset = start;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const n = file.readPositionalAll(io, buf[0..to_read], offset) catch |err| {
            // Headers are already sent: the only way to signal the failure
            // is to close the connection short of Content-Length.
            log.warn("read failed at offset {d}: {s}", .{ offset, @errorName(err) });
            res.conn.handover = .close;
            res.written = true;
            return;
        };
        if (n == 0) {
            // The file shrank after we sent Content-Length: close early.
            log.warn("file truncated while streaming at offset {d}", .{offset});
            res.conn.handover = .close;
            break;
        }
        res.conn.writeAll(buf[0..n]) catch {
            // Client closed connection or broken pipe
            res.conn.handover = .close;
            res.written = true;
            return;
        };
        remaining -= n;
        offset += n;
    }
    res.written = true;
}

/// Fetch `/ping` over real TCP with `std.http.Client`.
pub fn selfTest(io: std.Io, gpa: std.mem.Allocator, port: u16) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/ping", .{port});
    defer gpa.free(url);
    const result = try client.fetch(.{ .location = .{ .url = url }, .response_writer = &body.writer });
    if (result.status != .ok) return error.BadStatus;
    return body.toOwnedSlice();
}

pub fn check(gpa: std.mem.Allocator, ctx: oriel.CheckContext) !oriel.Check {
    const port = ctx.media_port orelse return error.MediaServerNotStarted;
    const body = try selfTest(ctx.io, gpa, port);
    return .{
        .module = "media_server",
        .ok = std.mem.indexOf(u8, body, "\"pong\":true") != null,
        .detail = try std.fmt.allocPrint(gpa, "http.zig on 127.0.0.1:{d}; std.http.Client GET /ping -> {s}", .{ port, body }),
    };
}

// --- Integration Tests ----------------------------------------------------

test "media_server: streaming over TCP with std.http.Client" {
    const ally = std.testing.allocator;
    const test_io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(test_io, &path_buf);
    const dir_path = path_buf[0..dir_len];

    // Generate 300 KiB test data (> 4 chunks of 64 KiB)
    const test_size: usize = 300 * 1024;
    const test_data = try ally.alloc(u8, test_size);
    defer ally.free(test_data);
    for (test_data, 0..) |*b, i| {
        b.* = @truncate((i *% 37) +% 13);
    }

    try tmp.dir.writeFile(test_io, .{ .sub_path = "sample.mp4", .data = test_data });

    // Pick a test port
    const test_port: u16 = 19874;

    var server: Server = undefined;
    try server.start(test_io, ally, Options{
        .root_dir = dir_path,
        .port = test_port,
        .allowed_origin = "app://app",
    });
    defer server.stop();

    var client: std.http.Client = .{ .allocator = ally, .io = test_io };
    defer client.deinit();

    // 1. GET 200 full body: verify exact byte match
    {
        var body_200: std.Io.Writer.Allocating = .init(ally);
        defer body_200.deinit();
        const res_200 = try client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:19874/sample.mp4" },
            .response_writer = &body_200.writer,
        });
        try std.testing.expectEqual(std.http.Status.ok, res_200.status);
        try std.testing.expectEqualSlices(u8, test_data, body_200.written());
    }

    // 2. GET 206 range: bytes=100-199 (100 bytes)
    {
        var body_206: std.Io.Writer.Allocating = .init(ally);
        defer body_206.deinit();
        const res_206 = try client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:19874/sample.mp4" },
            .extra_headers = &.{.{ .name = "Range", .value = "bytes=100-199" }},
            .response_writer = &body_206.writer,
        });
        try std.testing.expectEqual(std.http.Status.partial_content, res_206.status);
        try std.testing.expectEqualSlices(u8, test_data[100..200], body_206.written());
    }

    // 3. GET 206 suffix range: bytes=-50 (last 50 bytes)
    {
        var body_suffix: std.Io.Writer.Allocating = .init(ally);
        defer body_suffix.deinit();
        const res_suffix = try client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:19874/sample.mp4" },
            .extra_headers = &.{.{ .name = "Range", .value = "bytes=-50" }},
            .response_writer = &body_suffix.writer,
        });
        try std.testing.expectEqual(std.http.Status.partial_content, res_suffix.status);
        try std.testing.expectEqualSlices(u8, test_data[test_size - 50 ..], body_suffix.written());
    }

    // 4. GET 416 range not satisfiable: bytes=999999-9999999
    {
        var body_416: std.Io.Writer.Allocating = .init(ally);
        defer body_416.deinit();
        const res_416 = try client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:19874/sample.mp4" },
            .extra_headers = &.{.{ .name = "Range", .value = "bytes=999999-9999999" }},
            .response_writer = &body_416.writer,
        });
        try std.testing.expectEqual(std.http.Status.range_not_satisfiable, res_416.status);
        try std.testing.expectEqual(@as(usize, 0), body_416.written().len);
    }

    // 5. GET 404 missing file
    {
        var body_404: std.Io.Writer.Allocating = .init(ally);
        defer body_404.deinit();
        const res_404 = try client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:19874/nonexistent.mp4" },
            .response_writer = &body_404.writer,
        });
        try std.testing.expectEqual(std.http.Status.not_found, res_404.status);
    }

    // 6. GET 403 traversal attempt
    {
        var body_403: std.Io.Writer.Allocating = .init(ally);
        defer body_403.deinit();
        const res_403 = try client.fetch(.{
            .location = .{ .url = "http://127.0.0.1:19874/..%2fsecret.txt" },
            .response_writer = &body_403.writer,
        });
        try std.testing.expectEqual(std.http.Status.forbidden, res_403.status);
    }
}
