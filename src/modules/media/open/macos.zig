//! Opening media files strictly inside a root directory (macOS).
//!
//! macOS has no `openat2(RESOLVE_BENEATH)`: its `O_RESOLVE_BENEATH` flag is
//! accepted but not enforced on macOS 15.2 (verified: `../x` and an
//! escaping symlink both open). So every file is opened relative to the
//! root's fd and then checked with `fcntl(F_GETPATH)`, which reports the
//! path of the file actually opened: it must lie below the root's own
//! F_GETPATH path. The check is on the opened file, so there is no
//! check-then-open race. Under `.refuse_all`, `O_NOFOLLOW_ANY` also makes
//! the kernel refuse a symlink anywhere in the path. `sanitizePath` in
//! `range.zig` rejects `..`, absolute paths and NUL before we get here.

const std = @import("std");
const c = std.c;
const common = @import("../common.zig");

pub const SymlinkPolicy = common.SymlinkPolicy;
pub const OpenError = common.OpenError;

pub const Root = c.fd_t;

/// A media file opened read-only; the caller owns `fd` and must close it.
pub const Opened = struct {
    fd: c.fd_t,
    size: u64,

    pub fn close(self: Opened) void {
        _ = c.close(self.fd); // read-only fd: close errors carry no data loss
    }

    pub fn toFile(self: Opened) std.Io.File {
        return .{ .handle = self.fd, .flags = .{ .nonblocking = false } };
    }
};

const MAXPATHLEN = 1024;

/// The path of an open file descriptor, as the kernel resolved it.
fn fdPath(fd: c.fd_t, buf: *[MAXPATHLEN]u8) OpenError![]const u8 {
    if (c.fcntl(fd, c.F.GETPATH, buf) == -1) return error.Unexpected;
    return std.mem.sliceTo(buf, 0);
}

/// Open the root directory (closed by the caller with `closeRoot`).
pub fn openRoot(path: []const u8) OpenError!Root {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.NotFound;
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (fd < 0) return switch (std.posix.errno(fd)) {
        .NOENT, .NOTDIR => error.NotFound,
        .ACCES, .PERM => error.Forbidden,
        else => error.Unexpected,
    };
    return fd;
}

pub fn closeRoot(root: Root) void {
    _ = c.close(root);
}

/// Open `rel` (already sanitized, relative) below `root_fd` read-only and
/// return it with its size. Fails for anything but a regular file, and
/// with error.Forbidden for anything that resolves outside the root.
pub fn openInRoot(root_fd: c.fd_t, rel: []const u8, policy: SymlinkPolicy) OpenError!Opened {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel_z = std.fmt.bufPrintZ(&buf, "{s}", .{rel}) catch return error.NotFound;
    if (rel.len == 0 or rel[0] == '/') return error.Forbidden;
    // NONBLOCK: opening a FIFO for reading would otherwise block until a
    // writer appears (freezing the main thread for app:// requests); it is
    // then rejected as not a regular file. No effect on regular files.
    // ALERT is O_NOFOLLOW_ANY's bit (0x20000000; Zig names the older flag).
    const fd = c.openat(root_fd, rel_z.ptr, .{
        .ACCMODE = .RDONLY,
        .CLOEXEC = true,
        .NOCTTY = true,
        .NONBLOCK = true,
        .ALERT = policy == .refuse_all,
    });
    if (fd < 0) return switch (std.posix.errno(fd)) {
        .LOOP, .ACCES, .PERM => error.Forbidden, // ELOOP: refused symlink
        .NOENT, .NOTDIR, .NAMETOOLONG => error.NotFound,
        else => error.Unexpected,
    };
    errdefer _ = c.close(fd);

    var root_buf: [MAXPATHLEN]u8 = undefined;
    var file_buf: [MAXPATHLEN]u8 = undefined;
    const root_path = try fdPath(root_fd, &root_buf);
    const file_path = try fdPath(fd, &file_buf);
    if (!isBelow(file_path, root_path)) return error.Forbidden;

    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.Unexpected;
    if (st.mode & c.S.IFMT != c.S.IFREG) return error.NotAFile;
    return .{ .fd = fd, .size = @intCast(st.size) };
}

/// `path` is strictly below `root` (`root` itself or a sibling sharing its
/// prefix, like `/media2` for `/media`, is not).
fn isBelow(path: []const u8, root: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "/");
    return path.len > r.len + 1 and std.mem.startsWith(u8, path, r) and path[r.len] == '/';
}

test isBelow {
    try std.testing.expect(isBelow("/media/a.wav", "/media"));
    try std.testing.expect(isBelow("/media/sub/a.wav", "/media/"));
    try std.testing.expect(!isBelow("/media2/a.wav", "/media"));
    try std.testing.expect(!isBelow("/media", "/media"));
    try std.testing.expect(!isBelow("/etc/passwd", "/media"));
}

test "openInRoot: files, traversal and symlink policies" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "root/sub/a.wav", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "secret.txt", .data = "secret" });
    try tmp.dir.symLink(io, "sub/a.wav", "root/inside.wav", .{});
    try tmp.dir.symLink(io, "../secret.txt", "root/outside.txt", .{});

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(io, &path_buf);
    const root_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/root", .{path_buf[0..len]});
    defer std.testing.allocator.free(root_path);

    const root = try openRoot(root_path);
    defer closeRoot(root);

    const f = try openInRoot(root, "sub/a.wav", .inside_root);
    defer f.close();
    try std.testing.expectEqual(@as(u64, 5), f.size);

    const l = try openInRoot(root, "inside.wav", .inside_root);
    l.close();
    try std.testing.expectError(error.Forbidden, openInRoot(root, "inside.wav", .refuse_all));
    try std.testing.expectError(error.Forbidden, openInRoot(root, "outside.txt", .inside_root));
    try std.testing.expectError(error.Forbidden, openInRoot(root, "../secret.txt", .inside_root));
    try std.testing.expectError(error.Forbidden, openInRoot(root, "/etc/passwd", .inside_root));
    try std.testing.expectError(error.NotFound, openInRoot(root, "missing.wav", .inside_root));
    try std.testing.expectError(error.NotAFile, openInRoot(root, "sub", .inside_root));

    // A FIFO with no writer must be rejected, not block the caller forever.
    const fifo_path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/pipe", .{root_path}, 0);
    defer std.testing.allocator.free(fifo_path);
    try std.testing.expectEqual(@as(c_int, 0), mkfifo(fifo_path.ptr, 0o600));
    try std.testing.expectError(error.NotAFile, openInRoot(root, "pipe", .inside_root));
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: c.mode_t) c_int;
