//! macOS application data paths and JSON settings store.
//!
//! Folder mapping (Apple's File System Programming Guide):
//! - `configDir` and `dataDir`: `~/Library/Application Support/<app_id>`
//!   (macOS has no separate config location; preferences plists are not used).
//! - `cacheDir`: `~/Library/Caches/<app_id>`.
//!
//! Atomic replacement: a sibling temp file created exclusively (O_EXCL,
//! mode 0600, no symlink following), written, fsync'ed, renamed over the
//! target, then the directory is fsync'ed.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const c = std.c;

var temp_counter: std.atomic.Value(u32) = .init(1);

/// `$HOME/<rel>/<app_id>`, created if missing. Caller frees.
fn libraryPath(gpa: std.mem.Allocator, rel: []const u8, app_id: []const u8) ![]const u8 {
    const home = c.getenv("HOME") orelse return error.HomeNotSet;
    const base = try std.fs.path.join(gpa, &.{ std.mem.span(home), rel });
    defer gpa.free(base);
    const path = try common.buildAppPath(gpa, base, app_id, null);
    errdefer gpa.free(path);
    try makePath(gpa, path);
    return path;
}

/// `mkdir -p` with mode 0755.
fn makePath(gpa: std.mem.Allocator, path: []const u8) !void {
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

/// Return the application config directory (created if missing):
/// `~/Library/Application Support/<app_id>`. Caller frees.
pub fn configDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appSupportDir(gpa, app_id);
}

fn appSupportDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return libraryPath(gpa, "Library/Application Support", app_id);
}

/// Return the application data directory (created if missing): the same
/// as `configDir` on macOS. Caller frees.
pub fn dataDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return appSupportDir(gpa, app_id);
}

/// Return the application cache directory (created if missing):
/// `~/Library/Caches/<app_id>`. Caller frees.
pub fn cacheDir(gpa: std.mem.Allocator, app_id: []const u8) ![]const u8 {
    return libraryPath(gpa, "Library/Caches", app_id);
}

const MacMutex = struct {
    inner: c.pthread_mutex_t = .{},

    pub fn init(self: *MacMutex) void {
        self.* = .{};
    }

    pub fn deinit(self: *MacMutex) void {
        _ = c.pthread_mutex_destroy(&self.inner);
    }

    pub fn lock(self: *MacMutex) void {
        _ = c.pthread_mutex_lock(&self.inner);
    }

    pub fn unlock(self: *MacMutex) void {
        _ = c.pthread_mutex_unlock(&self.inner);
    }
};

const max_store_size = 16 * 1024 * 1024;

/// The whole file, or null if it doesn't exist. Caller frees.
fn macReadFile(gpa: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
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

fn macWriteFileAtomic(path: [:0]const u8, bytes: []const u8) !void {
    const gpa = std.heap.smp_allocator;
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

pub const Backend = struct {
    pub const Mutex = MacMutex;
    pub const readFile = macReadFile;
    pub const writeFileAtomic = macWriteFileAtomic;
    pub const configDir = appSupportDir;
};

pub const Store = common.GenericStore(Backend);

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    var dir_buf: [64]u8 = undefined;
    const test_path = try std.fmt.bufPrintZ(&dir_buf, "/tmp/oriel_check_store.{d}.json", .{c.getpid()});
    _ = c.unlink(test_path.ptr);
    defer _ = c.unlink(test_path.ptr);

    {
        var w = try Store.openPath(gpa, test_path);
        defer w.deinit();
        try w.set("test_key", "check_value");
    }
    // Reopen: the value must come back from disk.
    var s = try Store.openPath(gpa, test_path);
    defer s.deinit();
    const val = s.getString("test_key") orelse return .{ .module = "store", .ok = false, .detail = "failed to read back stored key" };
    if (!std.mem.eql(u8, val, "check_value")) return .{ .module = "store", .ok = false, .detail = "stored key mismatch" };

    const dir = try dataDir(gpa, "dev.oriel.Check");
    defer gpa.free(dir);
    return .{
        .module = "store",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "JSON store roundtrip through disk ok; data dir {s}", .{dir}),
    };
}

test "Store persists across reopen, atomic writes leave no temp files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "settings.json" });
    defer gpa.free(path);

    var store = try Store.openPath(gpa, path);
    try store.set("name", "oriel");
    try store.set("version", 1);
    try store.set("active", true);
    store.deinit();

    var reopened = try Store.openPath(gpa, path);
    defer reopened.deinit();
    try std.testing.expectEqualStrings("oriel", reopened.getString("name").?);
    try std.testing.expectEqual(@as(i64, 1), reopened.getInt("version", i64).?);
    try std.testing.expectEqual(true, reopened.getBool("active").?);

    var it = tmp.dir.iterate();
    var files: usize = 0;
    while (try it.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".tmp.") == null);
        files += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), files);
}

test "dirs live under ~/Library" {
    const gpa = std.testing.allocator;
    const cache = try cacheDir(gpa, "dev.oriel.Test");
    defer gpa.free(cache);
    try std.testing.expect(std.mem.endsWith(u8, cache, "/Library/Caches/dev.oriel.Test"));
    // Created by the call; remove what we made.
    const z = try gpa.dupeZ(u8, cache);
    defer gpa.free(z);
    _ = c.rmdir(z.ptr);
    try std.testing.expectError(error.InvalidAppId, cacheDir(gpa, "../evil"));
}
