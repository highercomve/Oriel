//! Model downloads for `dictation`, `chat` and `tts`: an HTTPS GET into a
//! `.part` file, renamed when complete (and, with `fetchVerified`, only
//! when its SHA-256 matches), with progress per megabyte. Redirects are
//! followed by hand (Hugging Face sends to its CDN), and on Android each
//! host is resolved by `oriel.android.preconnect` first (Zig's resolver
//! needs /etc/resolv.conf, which Android doesn't have). On iOS the download
//! goes through NSURLSession (model_download/ios.zig): Zig's TLS finds no
//! CA certificates there.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("../oriel.zig");

const log = std.log.scoped(.model_download);

/// Fetch `url` to `<dir>/<file>` (the directory is created). `progress(ctx,
/// done_mb, total_mb)` runs whenever another megabyte arrived; `expected_mb`
/// stands in for the total when the server doesn't say. Blocks: call it
/// from a worker.
pub fn fetch(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    dir_path: []const u8,
    file_name: []const u8,
    expected_mb: u32,
    ctx: anytype,
    comptime progress: fn (@TypeOf(ctx), u32, u32) void,
) !void {
    return fetchVerified(io, gpa, url, dir_path, file_name, expected_mb, null, ctx, progress);
}

/// `fetch`, and when `sha256` (64 hex digits) is given the file's SHA-256
/// must match it: a mismatching download is deleted (nothing is renamed
/// into place) and `error.ChecksumMismatch` returned.
pub fn fetchVerified(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    dir_path: []const u8,
    file_name: []const u8,
    expected_mb: u32,
    sha256: ?[]const u8,
    ctx: anytype,
    comptime progress: fn (@TypeOf(ctx), u32, u32) void,
) !void {
    if (sha256) |want| if (want.len != 64) return error.InvalidChecksum;
    try validateUrl(try std.Uri.parse(url));
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    defer dir.close(io);
    const part = try std.fmt.allocPrint(gpa, "{s}.part", .{file_name});
    defer gpa.free(part);
    if (builtin.os.tag == .ios) {
        const part_path = try std.fs.path.join(gpa, &.{ dir_path, part });
        defer gpa.free(part_path);
        try @import("model_download/ios.zig").fetch(io, url, part_path, expected_mb, ctx, progress);
        if (sha256) |want| {
            errdefer dir.deleteFile(io, part) catch {};
            const got = try sha256File(io, dir, part);
            if (!std.ascii.eqlIgnoreCase(&got, want)) {
                log.err("download {s}: SHA-256 mismatch", .{file_name});
                return error.ChecksumMismatch;
            }
        }
        try dir.rename(part, dir, file_name, io);
        log.info("downloaded {s}", .{file_name});
        return;
    }

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();
    // Two buffers in turn: the next URL is resolved against the current
    // one, which points into the other buffer.
    var url_bufs: [2][8 * 1024]u8 = undefined;
    var redirect_buf: [16 * 1024]u8 = undefined;
    var uri = try std.Uri.parse(url);
    var req: std.http.Client.Request = undefined;
    var response: std.http.Client.Response = undefined;
    var hops: u8 = 0;
    while (true) : (hops += 1) {
        if (hops == 6) return error.TooManyHttpRedirects;
        try validateUrl(uri);
        if (builtin.abi.isAndroid()) try oriel.android.preconnect(&client, uri);
        req = try client.request(.GET, uri, .{
            .headers = .{ .accept_encoding = .{ .override = "identity" } },
            .redirect_behavior = .unhandled,
        });
        errdefer req.deinit();
        try req.sendBodiless();
        response = try req.receiveHead(&redirect_buf);
        if (response.head.status.class() != .redirect) break;
        const location = response.head.location orelse return error.HttpRedirectLocationMissing;
        const buf = &url_bufs[hops % 2];
        if (location.len > buf.len) return error.HttpRedirectLocationOversize;
        @memcpy(buf[0..location.len], location);
        var aux: []u8 = buf;
        uri = try uri.resolveInPlace(location.len, &aux);
        req.deinit();
    }
    defer req.deinit();
    if (response.head.status != .ok) {
        log.err("download {s}: HTTP {d}", .{ file_name, @intFromEnum(response.head.status) });
        return error.BadHttpStatus;
    }
    const total: u64 = response.head.content_length orelse @as(u64, expected_mb) << 20;
    // Without a length, a server that never stops would fill the disk.
    const limit: u64 = response.head.content_length orelse @max(total, 1 << 20) * 4;

    const file = try dir.createFile(io, part, .{});
    var file_open = true;
    defer if (file_open) file.close(io);
    errdefer dir.deleteFile(io, part) catch {};
    var file_buf: [64 * 1024]u8 = undefined;
    var writer = file.writerStreaming(io, &file_buf);
    var transfer_buf: [64 * 1024]u8 = undefined;
    const reader = response.reader(&transfer_buf);

    var chunk: [64 * 1024]u8 = undefined;
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    var done: u64 = 0;
    var last_mb: u64 = std.math.maxInt(u64);
    while (true) {
        const n = try reader.readSliceShort(&chunk);
        if (n == 0) break;
        if (done + n > limit) return error.DownloadTooLarge;
        try writer.interface.writeAll(chunk[0..n]);
        if (sha256 != null) sha.update(chunk[0..n]);
        done += n;
        if (done >> 20 != last_mb) {
            last_mb = done >> 20;
            progress(ctx, std.math.lossyCast(u32, last_mb), std.math.lossyCast(u32, total >> 20));
        }
    }
    try writer.interface.flush();
    if (response.head.content_length) |len| if (done != len) return error.Truncated;
    if (sha256) |want| {
        const got = std.fmt.bytesToHex(sha.finalResult(), .lower);
        if (!std.ascii.eqlIgnoreCase(&got, want)) {
            log.err("download {s}: SHA-256 mismatch", .{file_name});
            return error.ChecksumMismatch;
        }
    }
    file.close(io);
    file_open = false;
    try dir.rename(part, dir, file_name, io);
    log.info("downloaded {s} ({d} MB)", .{ file_name, done >> 20 });
}

/// The SHA-256 of `<dir>/<name>`, as lowercase hex.
pub fn sha256File(io: std.Io, dir: std.Io.Dir, name: []const u8) ![64]u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var read_buf: [64 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &read_buf);
    var sha: std.crypto.hash.sha2.Sha256 = .init(.{});
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try reader.interface.readSliceShort(&chunk);
        if (n == 0) break;
        sha.update(chunk[0..n]);
    }
    return std.fmt.bytesToHex(sha.finalResult(), .lower);
}

test sha256File {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "abc", .data = "abc" });
    const got = try sha256File(io, tmp.dir, "abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &got);
}

fn validateUrl(uri: std.Uri) !void {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InsecureModelUrl;
    if (uri.host == null or uri.user != null or uri.password != null) return error.InvalidModelUrl;
}

test "model downloads reject cleartext redirects and URL credentials" {
    try validateUrl(try std.Uri.parse("https://cdn.example/model.gguf"));
    try std.testing.expectError(error.InsecureModelUrl, validateUrl(try std.Uri.parse("http://cdn.example/model.gguf")));
    try std.testing.expectError(error.InvalidModelUrl, validateUrl(try std.Uri.parse("https://user:password@cdn.example/model.gguf")));
}

/// Remove `<dir>/<file>` and a download of it that stopped half way.
pub fn remove(io: std.Io, dir_path: []const u8, file_name: []const u8) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return;
    defer dir.close(io);
    dir.deleteFile(io, file_name) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var part_buf: [std.fs.max_name_bytes + 8]u8 = undefined;
    dir.deleteFile(io, try std.fmt.bufPrint(&part_buf, "{s}.part", .{file_name})) catch {};
}

/// Whether `<dir>/<file>` is there and complete (a download that stopped
/// half way leaves only the .part file).
pub fn present(io: std.Io, dir_path: []const u8, file_name: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const path = std.fs.path.join(fba.allocator(), &.{ dir_path, file_name }) catch return false;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.size > 1 << 20;
}

/// The backend a module's `compare` found faster per model, one
/// "<model> gpu|cpu" line each in `<dir>/<file>`.
pub const Preferences = struct {
    file: []const u8,

    pub fn get(self: Preferences, io: std.Io, dir_path: []const u8, model: []const u8) ?bool {
        var buf: [2048]u8 = undefined;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return null;
        defer dir.close(io);
        const data = dir.readFile(io, self.file, &buf) catch return null;
        var lines = std.mem.tokenizeScalar(u8, data, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            if (!std.mem.eql(u8, f.next() orelse continue, model)) continue;
            return std.mem.eql(u8, f.next() orelse continue, "gpu");
        }
        return null;
    }

    /// Record `gpu` for `model`, keeping the other models' lines.
    pub fn set(self: Preferences, io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8, model: []const u8, gpu: bool) void {
        var buf: [2048]u8 = undefined;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var dir = std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{}) catch return;
        defer dir.close(io);
        if (dir.readFile(io, self.file, &buf)) |data| {
            var lines = std.mem.tokenizeScalar(u8, data, '\n');
            while (lines.next()) |line| {
                var f = std.mem.tokenizeScalar(u8, line, ' ');
                if (std.mem.eql(u8, f.next() orelse continue, model)) continue;
                out.print(gpa, "{s}\n", .{line}) catch return;
            }
        } else |_| {}
        out.print(gpa, "{s} {s}\n", .{ model, if (gpu) "gpu" else "cpu" }) catch return;
        dir.writeFile(io, .{ .sub_path = self.file, .data = out.items }) catch |err| log.warn("cannot save {s}: {s}", .{ self.file, @errorName(err) });
    }
};
