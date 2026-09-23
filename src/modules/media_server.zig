//! Local HTTP server (http.zig) for streaming large local media to the
//! webview with range requests. Binds to 127.0.0.1 only.

const std = @import("std");
const httpz = @import("httpz");
const oriel = @import("../oriel.zig");

pub const Server = struct {
    inner: httpz.Server(void),
    thread: std.Thread,
    port: u16,

    /// Start listening on 127.0.0.1:`port` in a background thread.
    pub fn start(self: *Server, io: std.Io, gpa: std.mem.Allocator, port: u16) !void {
        self.port = port;
        self.inner = try httpz.Server(void).init(io, gpa, .{ .address = .localhost(port) }, {});
        errdefer self.inner.deinit();
        var router = try self.inner.router(.{});
        router.get("/ping", ping, .{});
        self.thread = try self.inner.listenInNewThread();
    }

    pub fn stop(self: *Server) void {
        self.inner.stop();
        self.thread.join();
        self.inner.deinit();
    }
};

fn ping(_: *httpz.Request, res: *httpz.Response) !void {
    // The page is served from app://, a different origin.
    res.header("Access-Control-Allow-Origin", "*");
    try res.json(.{ .pong = true, .server = "http.zig" }, .{});
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
