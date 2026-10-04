//! Files dropped into a native-renderer page (docs/drag-and-drop-design.md,
//! section 3): one table per engine (`Engine.drops`).
//!
//! The capability is an open read-only descriptor, never a path: a backend
//! opens each dropped file when the drop happens (`addPath`, or `addFd` for
//! a descriptor the OS handed over) and the page gets a u32 handle for it.
//! `host.fileRead(reqId, handle, offset, length)` reads through `read`;
//! nothing here opens a path the page names.
//!
//! Snapshot semantics, as browsers have them: every read checks the file's
//! size and mtime again, and a file that changed since the drop reads as
//! NotReadable.
//!
//! Linux and Android (Linux syscalls), macOS and iOS (libc: Zig's std has
//! no portable fstat). Elsewhere the table exists, so the engine compiles,
//! but nothing can be added.

const std = @import("std");
const builtin = @import("builtin");

const darwin = builtin.os.tag.isDarwin();
const supported = builtin.os.tag == .linux or darwin;
const linux = std.os.linux;

/// At most this many bytes per read (JS reads bigger blobs in chunks).
pub const max_read: u64 = 64 * 1024 * 1024;

pub const Error = error{
    /// No such handle (never given, or released).
    BadHandle,
    /// The file changed since the drop (size or mtime), or a read failed.
    NotReadable,
    /// A read longer than `max_read`.
    TooLarge,
    /// Not a regular file (a descriptor given to `addFd`).
    NotAFile,
    /// Opening the path failed.
    OpenFailed,
    /// Out of handles (4 billion live ones) or this OS has no table yet.
    Unsupported,
    OutOfMemory,
};

pub const Entry = struct {
    fd: Fd,
    size: u64,
    /// Modification time, ns since the epoch.
    mtime_ns: i128,

    /// lastModified for File: ms since the epoch.
    pub fn mtimeMs(e: Entry) i64 {
        return @intCast(@divFloor(e.mtime_ns, std.time.ns_per_ms));
    }
};

const Fd = i32;

pub const DropFiles = struct {
    gpa: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
    next: u32 = 1,

    pub fn init(gpa: std.mem.Allocator) DropFiles {
        return .{ .gpa = gpa };
    }

    /// Closes every descriptor (the engine goes).
    pub fn deinit(d: *DropFiles) void {
        var it = d.entries.valueIterator();
        while (it.next()) |e| closeFd(e.fd);
        d.entries.deinit(d.gpa);
        d.* = undefined;
    }

    /// Keep `fd` (a descriptor the OS gave for a drop: Android's
    /// ParcelFileDescriptor) and return its handle. Takes ownership: the
    /// descriptor is closed on failure too. Regular files only.
    pub fn addFd(d: *DropFiles, fd: Fd) Error!u32 {
        if (!supported) return error.Unsupported;
        errdefer closeFd(fd);
        const st = try stat(fd);
        if (!st.regular) return error.NotAFile;
        return d.keep(fd, st);
    }

    /// Open a dropped file read-only and keep it: its handle, or null when
    /// it isn't a regular file (a directory, a FIFO: skipped in phase 1).
    pub fn addPath(d: *DropFiles, path: [:0]const u8) Error!?u32 {
        if (!supported) return error.Unsupported;
        const fd = openRead(path) orelse return error.OpenFailed;
        errdefer closeFd(fd);
        const st = try stat(fd);
        if (!st.regular) {
            closeFd(fd);
            return null;
        }
        return try d.keep(fd, st);
    }

    fn keep(d: *DropFiles, fd: Fd, st: Stat) Error!u32 {
        try d.entries.ensureUnusedCapacity(d.gpa, 1);
        // Sequential, skipping 0 and handles still in use after a wrap.
        var tries: u32 = 0;
        while (d.next == 0 or d.entries.contains(d.next)) : (tries += 1) {
            if (tries == std.math.maxInt(u32)) return error.Unsupported;
            d.next +%= 1;
        }
        const handle = d.next;
        d.next +%= 1;
        d.entries.putAssumeCapacity(handle, .{ .fd = fd, .size = st.size, .mtime_ns = st.mtime_ns });
        return handle;
    }

    /// What the page is told about a handle (size, mtime).
    pub fn info(d: *const DropFiles, handle: u32) ?Entry {
        return d.entries.get(handle);
    }

    /// Append up to `len` bytes from `offset` to `out` (fewer at the end of
    /// the file). NotReadable when the file changed since the drop.
    pub fn read(d: *DropFiles, handle: u32, offset: u64, len: u64, out: *std.ArrayList(u8)) Error!void {
        const e = d.entries.get(handle) orelse return error.BadHandle;
        if (len > max_read) return error.TooLarge;
        try check(e);
        const want: usize = @intCast(if (offset >= e.size) 0 else @min(len, e.size - offset));
        try out.ensureUnusedCapacity(d.gpa, want);
        var done: usize = 0;
        while (done < want) {
            const dst = out.unusedCapacitySlice()[0 .. want - done];
            const n = try preadFd(e.fd, dst, offset + done);
            if (n == 0) return error.NotReadable; // shorter than its snapshot
            out.items.len += n;
            done += n;
        }
        // Changed while it was read: the bytes may be a mix.
        try check(e);
    }

    /// Close a handle's descriptor (its last File was collected). Unknown
    /// handles are ignored.
    pub fn release(d: *DropFiles, handle: u32) void {
        const kv = d.entries.fetchRemove(handle) orelse return;
        closeFd(kv.value.fd);
    }

    pub fn count(d: *const DropFiles) usize {
        return d.entries.count();
    }
};

const Stat = struct { regular: bool, size: u64, mtime_ns: i128 };

/// Open `path` read-only (null on failure). NONBLOCK: a FIFO dropped by
/// mistake doesn't hang the UI thread in open (it's then refused as not
/// regular; regular files ignore it).
fn openRead(path: [*:0]const u8) ?Fd {
    if (darwin) {
        const fd = std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true });
        return if (fd < 0) null else fd;
    }
    if (!supported) return null;
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true, .NOCTTY = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

fn stat(fd: Fd) Error!Stat {
    if (!supported) return error.Unsupported;
    if (darwin) {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) return error.NotReadable;
        const m = st.mtime();
        return .{
            .regular = st.mode & std.c.S.IFMT == std.c.S.IFREG,
            .size = @intCast(@max(st.size, 0)),
            .mtime_ns = @as(i128, m.sec) * std.time.ns_per_s + m.nsec,
        };
    }
    var st: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .SIZE = true, .MTIME = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return error.NotReadable;
    return .{
        .regular = linux.S.ISREG(st.mode),
        .size = st.size,
        .mtime_ns = @as(i128, st.mtime.sec) * std.time.ns_per_s + st.mtime.nsec,
    };
}

/// The file is still what was dropped.
fn check(e: Entry) Error!void {
    const st = try stat(e.fd);
    if (st.size != e.size or st.mtime_ns != e.mtime_ns) return error.NotReadable;
}

fn preadFd(fd: Fd, buf: []u8, offset: u64) Error!usize {
    if (!supported) return error.Unsupported;
    if (darwin) while (true) {
        const rc = std.c.pread(fd, buf.ptr, buf.len, @intCast(offset));
        if (rc >= 0) return @intCast(rc);
        if (std.c.errno(rc) == .INTR) continue;
        return error.NotReadable;
    };
    while (true) {
        const rc = linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => return error.NotReadable,
        }
    }
}

fn closeFd(fd: Fd) void {
    if (darwin) _ = std.c.close(fd) else if (supported) _ = linux.close(fd);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// The absolute path of `name` in `tmp` (NUL-terminated, owned).
fn tmpPath(tmp: *testing.TmpDir, name: []const u8) ![:0]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(testing.io, &buf);
    return std.fmt.allocPrintSentinel(testing.allocator, "{s}/{s}", .{ buf[0..len], name }, 0);
}

/// Set a file's access and modification times to `sec` (the tests).
fn setMtime(path: [*:0]const u8, sec: i64) !void {
    if (darwin) {
        const times = [2]std.c.timespec{ .{ .sec = sec, .nsec = 0 }, .{ .sec = sec, .nsec = 0 } };
        try testing.expectEqual(@as(c_int, 0), std.c.utimensat(std.c.AT.FDCWD, path, &times, 0));
        return;
    }
    const times = [2]linux.timespec{ .{ .sec = sec, .nsec = 0 }, .{ .sec = sec, .nsec = 0 } };
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.utimensat(linux.AT.FDCWD, path, &times, 0)));
}

test "DropFiles: add, read, release" {
    if (!supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello, drop" });
    const path = try tmpPath(&tmp, "a.txt");
    defer testing.allocator.free(path);

    var d: DropFiles = .init(testing.allocator);
    defer d.deinit();
    const h = (try d.addPath(path)).?;
    try testing.expect(h != 0);
    try testing.expectEqual(@as(u64, 11), d.info(h).?.size);
    try testing.expect(d.info(h).?.mtimeMs() > 0);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try d.read(h, 0, 5, &out);
    try testing.expectEqualStrings("hello", out.items);
    out.clearRetainingCapacity();
    // Past the end: what there is; beyond it, nothing.
    try d.read(h, 7, 100, &out);
    try testing.expectEqualStrings("drop", out.items);
    out.clearRetainingCapacity();
    try d.read(h, 50, 10, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try testing.expectError(error.TooLarge, d.read(h, 0, max_read + 1, &out));

    // A second file gets its own handle; a released one reads no more.
    const h2 = (try d.addPath(path)).?;
    try testing.expect(h2 != h);
    d.release(h);
    try testing.expectError(error.BadHandle, d.read(h, 0, 1, &out));
    d.release(h); // twice: ignored
    try testing.expectEqual(@as(usize, 1), d.count());

    // addFd takes a descriptor the OS gave.
    const h3 = try d.addFd(openRead(path).?);
    try d.read(h3, 0, 5, &out);
    try testing.expectEqualStrings("hello", out.items);
}

test "DropFiles: a bad handle" {
    var d: DropFiles = .init(testing.allocator);
    defer d.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expectError(error.BadHandle, d.read(0, 0, 1, &out));
    try testing.expectError(error.BadHandle, d.read(12345, 0, 1, &out));
    try testing.expect(d.info(7) == null);
    d.release(7);
}

test "DropFiles: a file changed since the drop is not readable" {
    if (!supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.bin", .data = "0123456789" });
    const path = try tmpPath(&tmp, "b.bin");
    defer testing.allocator.free(path);

    var d: DropFiles = .init(testing.allocator);
    defer d.deinit();
    const h = (try d.addPath(path)).?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try d.read(h, 0, 4, &out);

    // Same size, another mtime.
    try setMtime(path, 1_000_000);
    try testing.expectError(error.NotReadable, d.read(h, 0, 4, &out));

    // A size change too.
    const h2 = (try d.addPath(path)).?;
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.bin", .data = "0123" });
    try testing.expectError(error.NotReadable, d.read(h2, 0, 4, &out));
}

test "DropFiles: a directory is not a file" {
    if (!supported) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "dir");
    const path = try tmpPath(&tmp, "dir");
    defer testing.allocator.free(path);

    var d: DropFiles = .init(testing.allocator);
    defer d.deinit();
    try testing.expect(try d.addPath(path) == null);
    try testing.expectEqual(@as(usize, 0), d.count());
    try testing.expectError(error.NotAFile, d.addFd(openRead(path).?));
    // A path that isn't there.
    try testing.expectError(error.OpenFailed, d.addPath("/nonexistent/oriel-drop-test"));
}
