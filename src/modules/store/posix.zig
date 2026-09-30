//! POSIX file primitives for the JSON store (macOS and Android): `mkdir -p`,
//! a pthread mutex, whole-file reads and atomic replacement.
//!
//! Atomic replacement: a sibling temp file created exclusively (O_EXCL,
//! mode 0600, no symlink following), written, fsync'ed, renamed over the
//! target, then the directory is fsync'ed.

const std = @import("std");
const heap = @import("../../core/heap.zig");

const c = std.c;

var temp_counter: std.atomic.Value(u32) = .init(1);

/// `mkdir -p` with mode 0755.
pub fn makePath(gpa: std.mem.Allocator, path: []const u8) !void {
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    var i: usize = 1;
    while (i <= z.len) : (i += 1) {
        if (i < z.len and z[i] != '/') continue;
        const saved = z[i];
        z[i] = 0;
        defer z[i] = saved;
        const rc = c.mkdir(z.ptr, 0o755);
        if (rc != 0) {
            switch (std.posix.errno(rc)) {
                .EXIST => {},
                else => return error.CreateDirectoryFailed,
            }
        }
    }
}

pub const Mutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn init(self: *Mutex) void {
        self.* = .{};
    }

    pub fn deinit(self: *Mutex) void {
        _ = c.pthread_mutex_destroy(&self.inner);
    }

    pub fn lock(self: *Mutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *Mutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

const max_store_size = 16 * 1024 * 1024;

/// The whole file, or null if it doesn't exist. Caller frees.
pub fn readFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    const fd = c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) {
        return switch (std.posix.errno(fd)) {
            .NOENT => null,
            else => error.OpenFailed,
        };
    }
    defer _ = c.close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [16 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.ReadFailed;
        }
        if (n == 0) break;
        if (out.items.len + @as(usize, @intCast(n)) > max_store_size) return error.StoreTooLarge;
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
    return try out.toOwnedSlice(gpa);
}

fn writeAll(fd: c.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) {
            if (std.posix.errno(n) == .INTR) continue;
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

pub fn writeFileAtomic(path: [:0]const u8, bytes: []const u8) !void {
    const gpa = heap.gpa;
    const n = temp_counter.fetchAdd(1, .monotonic);
    const tmp = try std.fmt.allocPrintSentinel(gpa, "{s}.tmp.{d}.{d}", .{ path, c.getpid(), n }, 0);
    defer gpa.free(tmp);

    const fd = c.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.CreateTempFailed;
    var renamed = false;
    defer if (!renamed) {
        _ = c.unlink(tmp.ptr);
    };
    {
        defer _ = c.close(fd);
        try writeAll(fd, bytes);
        if (c.fsync(fd) != 0) return error.SyncFailed;
    }
    if (c.rename(tmp.ptr, path.ptr) != 0) return error.RenameFailed;
    renamed = true;

    // Make the rename itself durable.
    const dir = std.fs.path.dirname(path) orelse ".";
    const dir_z = try gpa.dupeZ(u8, dir);
    defer gpa.free(dir_z);
    const dfd = c.open(dir_z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dfd >= 0) {
        defer _ = c.close(dfd);
        _ = c.fsync(dfd); // best effort: the data itself is already synced
    }
}
