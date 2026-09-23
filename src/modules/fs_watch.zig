//! File-system watching (Linux: inotify). FSEvents / ReadDirectoryChangesW
//! backends come with the macOS / Windows shells.

const std = @import("std");
const linux = std.os.linux;
const ziguri = @import("../ziguri.zig");

pub const Event = struct {
    kind: enum { created, modified, deleted, other },
    name: []const u8,
};

pub const Watcher = struct {
    fd: i32,

    pub fn init() !Watcher {
        const rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
        if (linux.errno(rc) != .SUCCESS) return error.InotifyInit;
        return .{ .fd = @intCast(rc) };
    }

    pub fn deinit(self: Watcher) void {
        _ = linux.close(self.fd);
    }

    pub fn add(self: Watcher, path: [:0]const u8) !void {
        const rc = linux.inotify_add_watch(self.fd, path.ptr, linux.IN.CREATE | linux.IN.MODIFY | linux.IN.DELETE);
        if (linux.errno(rc) != .SUCCESS) return error.InotifyAddWatch;
    }

    /// Read pending events without blocking. Names point into `buf`.
    pub fn poll(self: Watcher, buf: []align(@alignOf(linux.inotify_event)) u8, out: []Event) !usize {
        const rc = linux.read(self.fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .AGAIN => return 0,
            else => return error.InotifyRead,
        }
        var n: usize = 0;
        var off: usize = 0;
        while (off < rc and n < out.len) {
            const ev: *const linux.inotify_event = @ptrCast(@alignCast(buf[off..].ptr));
            const name = if (ev.getName()) |z| std.mem.sliceTo(z, 0) else "";
            out[n] = .{
                .kind = if (ev.mask & linux.IN.CREATE != 0) .created else if (ev.mask & linux.IN.MODIFY != 0) .modified else if (ev.mask & linux.IN.DELETE != 0) .deleted else .other,
                .name = name,
            };
            n += 1;
            off += @sizeOf(linux.inotify_event) + ev.len;
        }
        return n;
    }
};

pub fn check(gpa: std.mem.Allocator, _: ziguri.CheckContext) !ziguri.Check {
    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/ziguri-fswatch-{d}", .{linux.getpid()});
    _ = linux.mkdir(dir, 0o700);
    defer _ = linux.rmdir(dir);

    const watcher = try Watcher.init();
    defer watcher.deinit();
    try watcher.add(dir);

    var file_buf: [96]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&file_buf, "{s}/hello.txt", .{dir});
    const fd = linux.open(file, .{ .CREAT = true, .ACCMODE = .WRONLY }, 0o600);
    if (linux.errno(fd) != .SUCCESS) return error.CreateTestFile;
    _ = linux.close(@intCast(fd));
    defer _ = linux.unlink(file);

    var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    var events: [8]Event = undefined;
    const n = try watcher.poll(&buf, &events);
    const seen = n > 0 and events[0].kind == .created and std.mem.eql(u8, events[0].name, "hello.txt");
    return .{
        .module = "fs_watch",
        .ok = seen,
        .detail = try std.fmt.allocPrint(gpa, "inotify: {d} event(s), first = {s} {s}", .{
            n,
            if (n > 0) @tagName(events[0].kind) else "-",
            if (n > 0) events[0].name else "-",
        }),
    };
}
