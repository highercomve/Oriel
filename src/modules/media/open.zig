//! Opening media files strictly inside a root directory (Linux).
//!
//! Both media paths (the TCP server and the `app://` scheme) open files with
//! `openat2(2)` relative to the root directory's fd and `RESOLVE_BENEATH`: the
//! kernel refuses any resolution that leaves the root (`..`, absolute
//! symlinks, symlinks pointing outside) at open time, so there is no
//! check-then-open race. `sanitizePath` in `range.zig` still rejects `..`,
//! absolute paths and NUL before we get here (defence in depth).

const std = @import("std");
const linux = std.os.linux;

/// What to do with symbolic links below the media root.
pub const SymlinkPolicy = enum {
    /// Follow symlinks only while they resolve inside the root (default).
    /// A link pointing outside the root is refused.
    inside_root,
    /// Refuse every symlink, even ones pointing inside the root.
    refuse_all,
};

pub const OpenError = error{
    /// The path would leave the root, or hits a refused symlink.
    Forbidden,
    NotFound,
    /// Not a regular file (directory, device, FIFO...).
    NotAFile,
    /// The kernel lacks openat2 (Linux < 5.6) or another unexpected errno.
    Unexpected,
};

/// A media file opened read-only; the caller owns `fd` and must close it.
pub const Opened = struct {
    fd: linux.fd_t,
    size: u64,

    pub fn close(self: Opened) void {
        _ = linux.close(self.fd); // read-only fd: close errors carry no data loss
    }
};

// <linux/openat2.h>; std.os.linux has the syscall number but no wrapper.
const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
const RESOLVE_NO_MAGICLINKS: u64 = 0x02;
const RESOLVE_NO_SYMLINKS: u64 = 0x04;
const RESOLVE_BENEATH: u64 = 0x08;

/// Open the root directory as an `O_PATH` fd (closed by the caller with
/// `std.os.linux.close`).
pub fn openRoot(path: []const u8) OpenError!linux.fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return error.NotFound;
    const rc = linux.openat(linux.AT.FDCWD, path_z, .{ .PATH = true, .DIRECTORY = true, .CLOEXEC = true }, 0);
    return switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        .NOENT, .NOTDIR => error.NotFound,
        .ACCES, .PERM => error.Forbidden,
        else => error.Unexpected,
    };
}

/// Open `rel` (already sanitized, relative) below `root_fd` read-only and
/// return it with its size. Fails for anything but a regular file.
pub fn openInRoot(root_fd: linux.fd_t, rel: []const u8, policy: SymlinkPolicy) OpenError!Opened {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rel_z = std.fmt.bufPrintZ(&buf, "{s}", .{rel}) catch return error.NotFound;
    const flags: linux.O = .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOCTTY = true };
    var how: OpenHow = .{
        .flags = @as(u32, @bitCast(flags)),
        .mode = 0,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_MAGICLINKS | switch (policy) {
            .inside_root => 0,
            .refuse_all => RESOLVE_NO_SYMLINKS,
        },
    };
    const rc = linux.syscall4(
        .openat2,
        @as(usize, @bitCast(@as(isize, root_fd))),
        @intFromPtr(rel_z.ptr),
        @intFromPtr(&how),
        @sizeOf(OpenHow),
    );
    const fd: linux.fd_t = switch (linux.errno(rc)) {
        .SUCCESS => @intCast(rc),
        // EXDEV: resolution escaped the root; ELOOP: refused symlink.
        .XDEV, .LOOP, .ACCES, .PERM => return error.Forbidden,
        .NOENT, .NOTDIR, .NAMETOOLONG => return error.NotFound,
        else => return error.Unexpected,
    };
    errdefer _ = linux.close(fd);

    var st: linux.Statx = undefined;
    const src = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true }, &st);
    if (linux.errno(src) != .SUCCESS) return error.Unexpected;
    if (!linux.S.ISREG(st.mode)) return error.NotAFile;
    return .{ .fd = fd, .size = st.size };
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
    defer _ = linux.close(root);

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
}
