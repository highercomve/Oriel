//! Media an app serves from its own code (`media_server.Options.source`,
//! `media_scheme.setSource`): files fetched block by block from another
//! device, decrypted on the fly, built in memory. The servers keep their
//! Range, HEAD and 416 handling and ask the source for the size and bytes.

const std = @import("std");

/// Bytes an app serves itself, by path (relative, sanitized, no leading '/').
/// Called from server threads: must be thread-safe. The MIME type comes from
/// the path's extension (range.mimeForExtension).
pub const Source = struct {
    ctx: *anyopaque,
    /// The size of `path`, or null if there is no such file (404).
    sizeFn: *const fn (ctx: *anyopaque, path: []const u8) ?u64,
    /// Copies up to dest.len bytes of `path` starting at `offset` into dest;
    /// returns how many (0 only at the end). An error ends the response early.
    readFn: *const fn (ctx: *anyopaque, path: []const u8, offset: u64, dest: []u8) anyerror!usize,
};

/// The most a server asks `readFn` for at once.
pub const chunk_size = 256 * 1024;

/// A path a source may be asked about: relative, not empty, no NUL or
/// backslash, no `..` segment, not a directory (trailing '/'). The HTTP
/// server checks the same with `range.sanitizePath`; this one is for paths
/// that arrive already decoded (Android's WebView).
pub fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[path.len - 1] == '/') return false;
    if (std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| if (std.mem.eql(u8, segment, "..")) return false;
    return true;
}

/// `NativeLib.mediaSize`'s answer: the size, or -1 (no such file, a bad
/// path, or a size Java's `Long` can't hold).
pub fn javaSize(source: Source, path: []const u8) i64 {
    if (!validPath(path)) return -1;
    const size = source.sizeFn(source.ctx, path) orelse return -1;
    return std.math.cast(i64, size) orelse -1;
}

/// `NativeLib.mediaRead`'s answer: the count read into `dest` (at most
/// `chunk_size`), 0 at the end, or -1 (an error, a bad path or offset, or a
/// source that claims more than it was given room for).
pub fn javaRead(source: Source, path: []const u8, offset: i64, dest: []u8) i32 {
    if (!validPath(path) or offset < 0) return -1;
    const room = dest[0..@min(dest.len, chunk_size)];
    const n = source.readFn(source.ctx, path, @intCast(offset), room) catch return -1;
    if (n > room.len) return -1;
    return @intCast(n);
}

// --- Unit Tests -----------------------------------------------------------

/// For tests: one file, "clip.mp4", held in memory.
pub const TestMemory = struct {
    data: []const u8,
    fail: bool = false,

    pub fn source(self: *TestMemory) Source {
        return .{ .ctx = self, .sizeFn = size, .readFn = read };
    }

    fn size(ctx: *anyopaque, path: []const u8) ?u64 {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, path, "clip.mp4")) return null;
        return self.data.len;
    }

    fn read(ctx: *anyopaque, path: []const u8, offset: u64, dest: []u8) anyerror!usize {
        const self: *TestMemory = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.Unreachable;
        if (!std.mem.eql(u8, path, "clip.mp4")) return error.FileNotFound;
        if (offset >= self.data.len) return 0;
        const n = @min(dest.len, self.data.len - offset);
        @memcpy(dest[0..n], self.data[@intCast(offset)..][0..n]);
        return n;
    }
};

test "source: validPath" {
    for ([_][]const u8{ "clip.mp4", "a/b/c.webm", "a..b/c", "...", "a b.mp3" }) |p| {
        try std.testing.expect(validPath(p));
    }
    for ([_][]const u8{ "", "/clip.mp4", "dir/", "..", "a/../b", "../a", "a/..", "a\\b", "a\x00b" }) |p| {
        try std.testing.expect(!validPath(p));
    }
}

test "source: javaSize" {
    var mem: TestMemory = .{ .data = "0123456789" };
    const s = mem.source();
    try std.testing.expectEqual(@as(i64, 10), javaSize(s, "clip.mp4"));
    try std.testing.expectEqual(@as(i64, -1), javaSize(s, "other.mp4"));
    try std.testing.expectEqual(@as(i64, -1), javaSize(s, "../clip.mp4"));
}

test "source: javaRead" {
    var mem: TestMemory = .{ .data = "0123456789" };
    const s = mem.source();
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 4), javaRead(s, "clip.mp4", 3, &buf));
    try std.testing.expectEqualStrings("3456", &buf);
    try std.testing.expectEqual(@as(i32, 2), javaRead(s, "clip.mp4", 8, &buf));
    try std.testing.expectEqualStrings("89", buf[0..2]);
    try std.testing.expectEqual(@as(i32, 0), javaRead(s, "clip.mp4", 10, &buf));
    try std.testing.expectEqual(@as(i32, -1), javaRead(s, "clip.mp4", -1, &buf));
    try std.testing.expectEqual(@as(i32, -1), javaRead(s, "a/../clip.mp4", 0, &buf));
    try std.testing.expectEqual(@as(i32, -1), javaRead(s, "other.mp4", 0, &buf));
    mem.fail = true;
    try std.testing.expectEqual(@as(i32, -1), javaRead(s, "clip.mp4", 0, &buf));
}

test "source: javaRead caps a read at chunk_size" {
    const big = try std.testing.allocator.alloc(u8, chunk_size + 10);
    defer std.testing.allocator.free(big);
    @memset(big, 7);
    const dest = try std.testing.allocator.alloc(u8, chunk_size + 10);
    defer std.testing.allocator.free(dest);
    var mem: TestMemory = .{ .data = big };
    try std.testing.expectEqual(@as(i32, chunk_size), javaRead(mem.source(), "clip.mp4", 0, dest));
}

test "source: javaRead refuses a source that overruns dest" {
    const Liar = struct {
        fn size(_: *anyopaque, _: []const u8) ?u64 {
            return 100;
        }
        fn read(_: *anyopaque, _: []const u8, _: u64, dest: []u8) anyerror!usize {
            return dest.len + 1;
        }
    };
    var dummy: u8 = 0;
    const s: Source = .{ .ctx = &dummy, .sizeFn = Liar.size, .readFn = Liar.read };
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(i32, -1), javaRead(s, "x.mp4", 0, &buf));
}
