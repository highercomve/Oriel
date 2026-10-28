//! Local HTTP server (http.zig) for streaming large local media to the
//! webview with HTTP range requests (RFC 9110 §14). Binds to 127.0.0.1 only.
//! Serves the files below a root folder, or an app's own `Source`.

/// Built for this target (docs/modules.md, "Availability").
pub const available = true;

const std = @import("std");
const httpz = @import("httpz");
const oriel = @import("../oriel.zig");
pub const range = @import("media/range.zig");
/// The `app://app/media/` side: `scheme.setRoot(path, policy)`.
pub const scheme = @import("media_scheme.zig");

const log = std.log.scoped(.media_server);

pub const open = @import("media/open.zig");
pub const SymlinkPolicy = open.SymlinkPolicy;
/// Bytes the app serves itself (`Options.source`).
pub const Source = @import("media/source.zig").Source;
const source_chunk = @import("media/source.zig").chunk_size;

pub const Options = struct {
    /// Directory whose files are served (`/<path>` maps to `<root_dir>/<path>`).
    /// Ignored (it may be "") when `source` is set.
    root_dir: []const u8,
    /// TCP port on 127.0.0.1.
    port: u16,
    /// Value of `Access-Control-Allow-Origin` on file responses: the page
    /// origin (`app://app` on Linux, `https://app.localhost` on Windows, for
    /// embedded assets) or the dev server origin.
    allowed_origin: []const u8 = oriel.security.app_origin,
    symlink_policy: SymlinkPolicy = .inside_root,
    /// Serve every file route from the app's own code instead of `root_dir`
    /// (`/<path>` asks the source for the sanitized `<path>`). Its ctx must
    /// outlive the server.
    source: ?Source = null,
};

pub const Handler = struct {
    options: Options,
    /// Root directory handle; files are opened beneath it. Null when
    /// `options.source` serves the files.
    root: ?open.Root,
    io: std.Io,

    pub fn ping(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        if (!self.validateHost(req, res)) return;
        res.header("Access-Control-Allow-Origin", self.options.allowed_origin);
        try res.json(.{ .pong = true, .server = "http.zig" }, .{});
    }

    pub fn handleOptions(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        if (!self.validateHost(req, res)) return;
        res.header("Access-Control-Allow-Origin", self.options.allowed_origin);
        res.header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
        res.header("Access-Control-Allow-Headers", "Range, Content-Type, Accept");
        res.header("Access-Control-Expose-Headers", "Content-Range, Content-Length, Accept-Ranges");
        res.header("Access-Control-Max-Age", "86400");
        res.status = 204;
    }

    fn validateHost(self: *Handler, req: *httpz.Request, res: *httpz.Response) bool {
        if (hostAllowed(req.header("host"), self.options.port)) return true;
        res.status = 403;
        res.body = "Forbidden";
        return false;
    }

    pub fn handleFile(self: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
        if (!self.validateHost(req, res)) return;
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

        if (self.options.source) |source| {
            const size = source.sizeFn(source.ctx, sanitized) orelse {
                res.status = 404;
                res.body = "Not Found";
                return;
            };
            return respond(req, res, sanitized, size, .{ .source = .{ .source = source, .path = sanitized } });
        }

        const opened = open.openInRoot(self.root.?, sanitized, self.options.symlink_policy) catch |err| {
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
        return respond(req, res, sanitized, opened.size, .{ .file = .{ .io = self.io, .file = &file } });
    }
};

/// Where a response's bytes come from.
const Body = union(enum) {
    file: struct { io: std.Io, file: *std.Io.File },
    source: struct { source: Source, path: []const u8 },
};

/// Headers, Range (200, 206, 416) and HEAD for a file of `size` bytes, then
/// the body streamed from `body`.
fn respond(req: *httpz.Request, res: *httpz.Response, path: []const u8, size: u64, body: Body) !void {
    const ext = std.fs.path.extension(path);
    const mime = range.mimeForExtension(ext);
    res.header("Content-Type", mime);
    res.header("Accept-Ranges", "bytes");

    const range_hdr = req.header("range");
    const range_res = if (range_hdr) |hdr|
        range.parseRange(hdr, size)
    else
        .full;

    const start: u64, const length: u64 = switch (range_res) {
        .unsatisfiable => {
            res.status = 416;
            try res.headerOpts("Content-Range", try std.fmt.allocPrint(res.arena, "bytes */{d}", .{size}), .{});
            res.header("Content-Length", "0");
            try sendHeaders(res);
            res.written = true;
            return;
        },
        .full => blk: {
            res.status = 200;
            try res.headerOpts("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{size}), .{});
            break :blk .{ 0, size };
        },
        .range => |r| blk: {
            res.status = 206;
            try res.headerOpts("Content-Length", try std.fmt.allocPrint(res.arena, "{d}", .{r.length()}), .{});
            try res.headerOpts("Content-Range", try std.fmt.allocPrint(res.arena, "bytes {d}-{d}/{d}", .{ r.start, r.end, size }), .{});
            break :blk .{ r.start, r.length() };
        },
    };
    try sendHeaders(res);
    if (req.method == .HEAD) {
        res.written = true;
        return;
    }
    switch (body) {
        .file => |f| try streamFile(f.io, f.file, res, start, length),
        .source => |src| try streamSource(src.source, src.path, res, start, length),
    }
}

/// Reject DNS-rebinding hostnames before exposing any local endpoint.
fn hostAllowed(host: ?[]const u8, port: u16) bool {
    const value = host orelse return false;
    var buf: [32]u8 = undefined;
    const ip = std.fmt.bufPrint(&buf, "127.0.0.1:{d}", .{port}) catch unreachable;
    if (std.mem.eql(u8, value, ip)) return true;
    const local = std.fmt.bufPrint(&buf, "localhost:{d}", .{port}) catch unreachable;
    return std.ascii.eqlIgnoreCase(value, local);
}

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

    /// Start serving `options.root_dir` (or `options.source`) on
    /// 127.0.0.1:`options.port` from a background thread. `self` must stay
    /// at a fixed address until `stop`.
    pub fn start(self: *Server, io: std.Io, gpa: std.mem.Allocator, options: Options) !void {
        self.io = io;
        self.port = options.port;

        const root: ?open.Root = if (options.source == null) try open.openRoot(options.root_dir) else null;
        errdefer if (root) |r| open.closeRoot(r);
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
        if (self.handler.root) |r| open.closeRoot(r);
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

/// Stream a source's bytes in chunks of up to 256 KiB (allocated in the
/// request's arena, not on the worker's stack).
fn streamSource(source: Source, path: []const u8, res: *httpz.Response, start: u64, length: u64) !void {
    const buf = try res.arena.alloc(u8, @intCast(@min(@as(u64, source_chunk), @max(length, 1))));
    var remaining = length;
    var offset = start;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const n = source.readFn(source.ctx, path, offset, buf[0..to_read]) catch |err| {
            // Headers are already sent: close short of Content-Length.
            log.warn("source read of {s} failed at offset {d}: {s}", .{ path, offset, @errorName(err) });
            res.conn.handover = .close;
            res.written = true;
            return;
        };
        if (n == 0 or n > to_read) {
            // Shorter than the size it gave, or a bad count: close early.
            log.warn("source ended {s} early at offset {d}", .{ path, offset });
            res.conn.handover = .close;
            break;
        }
        res.conn.writeAll(buf[0..n]) catch {
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

    for ([_]struct { method: std.http.Method, path: []const u8 }{
        .{ .method = .GET, .path = "/ping" },
        .{ .method = .GET, .path = "/sample.mp4" },
        .{ .method = .HEAD, .path = "/sample.mp4" },
        .{ .method = .OPTIONS, .path = "/sample.mp4" },
    }) |request| {
        const url = try std.fmt.allocPrint(ally, "http://127.0.0.1:19874{s}", .{request.path});
        defer ally.free(url);
        var body: std.Io.Writer.Allocating = .init(ally);
        defer body.deinit();
        const response = try client.fetch(.{
            .location = .{ .url = url },
            .method = request.method,
            .headers = .{ .host = .{ .override = "attacker.example:19874" } },
            .response_writer = &body.writer,
        });
        try std.testing.expectEqual(std.http.Status.forbidden, response.status);
    }

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

/// A port nothing listens on right now: bind port 0, read it, close.
fn freePort(io: std.Io) !u16 {
    const any: std.Io.net.IpAddress = try .parseIp4("127.0.0.1", 0);
    var probe = try any.listen(io, .{});
    defer probe.deinit(io);
    return probe.socket.address.getPort();
}

test "media_server: a Source over std.http.Client" {
    const ally = std.testing.allocator;
    const test_io = std.testing.io;

    // 300 KiB: more than one 256 KiB source read.
    const test_size: usize = 300 * 1024;
    const test_data = try ally.alloc(u8, test_size);
    defer ally.free(test_data);
    for (test_data, 0..) |*b, i| b.* = @truncate((i *% 31) +% 7);
    var mem: @import("media/source.zig").TestMemory = .{ .data = test_data };

    const port = try freePort(test_io);
    var server: Server = undefined;
    try server.start(test_io, ally, .{ .root_dir = "", .port = port, .source = mem.source() });
    defer server.stop();

    var client: std.http.Client = .{ .allocator = ally, .io = test_io };
    defer client.deinit();

    const Case = struct {
        method: std.http.Method = .GET,
        path: []const u8 = "/clip.mp4",
        range: ?[]const u8 = null,
        status: std.http.Status,
        body: []const u8 = "",
        content_range: ?[]const u8 = null,
    };
    const content_range_suffix = try std.fmt.allocPrint(ally, "bytes {d}-{d}/{d}", .{ test_size - 50, test_size - 1, test_size });
    defer ally.free(content_range_suffix);
    const content_range_416 = try std.fmt.allocPrint(ally, "bytes */{d}", .{test_size});
    defer ally.free(content_range_416);
    const content_range_10 = try std.fmt.allocPrint(ally, "bytes 10-19/{d}", .{test_size});
    defer ally.free(content_range_10);

    for ([_]Case{
        .{ .status = .ok, .body = test_data },
        .{ .range = "bytes=10-19", .status = .partial_content, .body = test_data[10..20], .content_range = content_range_10 },
        .{ .range = "bytes=-50", .status = .partial_content, .body = test_data[test_size - 50 ..], .content_range = content_range_suffix },
        .{ .method = .HEAD, .status = .ok },
        .{ .range = "bytes=999999-", .status = .range_not_satisfiable, .content_range = content_range_416 },
        .{ .path = "/missing.mp4", .status = .not_found, .body = "Not Found" },
        .{ .path = "/..%2fclip.mp4", .status = .forbidden, .body = "Forbidden" },
    }) |case| {
        const url = try std.fmt.allocPrint(ally, "http://127.0.0.1:{d}{s}", .{ port, case.path });
        defer ally.free(url);
        var req = try client.request(case.method, try std.Uri.parse(url), .{
            .extra_headers = if (case.range) |r| &.{.{ .name = "Range", .value = r }} else &.{},
        });
        defer req.deinit();
        try req.sendBodiless();
        var response = try req.receiveHead(&.{});
        try std.testing.expectEqual(case.status, response.head.status);

        var content_range: ?[]const u8 = null;
        var content_type: ?[]const u8 = null;
        var content_length: ?[]const u8 = null;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-range")) content_range = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) content_type = h.value;
            if (std.ascii.eqlIgnoreCase(h.name, "content-length")) content_length = h.value;
        }
        if (case.content_range) |want| try std.testing.expectEqualStrings(want, content_range.?);
        if (case.status == .ok or case.status == .partial_content) {
            try std.testing.expectEqualStrings("video/mp4", content_type.?);
        }
        if (case.method == .HEAD) {
            const want = try std.fmt.allocPrint(ally, "{d}", .{test_size});
            defer ally.free(want);
            try std.testing.expectEqualStrings(want, content_length.?);
            continue;
        }

        var body: std.Io.Writer.Allocating = .init(ally);
        defer body.deinit();
        var transfer_buf: [64]u8 = undefined;
        const reader = response.reader(&transfer_buf);
        _ = try reader.streamRemaining(&body.writer);
        try std.testing.expectEqualSlices(u8, case.body, body.written());
    }
}
