//! Single instance on macOS (Milestone 10), for apps with
//! `App.Config.on_second_instance`.
//!
//! Launch Services already sends a bundled app's second launch to the
//! running one (as a reopen event: Shell.zig calls the handler with no
//! arguments), but not a binary run directly (a terminal, a script, the
//! executable inside the bundle, `open -n`). So every launch takes an
//! exclusive `flock` on `$TMPDIR/oriel-<app id>.lock`:
//!
//! - the first one (primary) keeps it and listens on the Unix socket
//!   `$TMPDIR/oriel-<app id>.sock`; each connection carries a later
//!   launch's arguments (a JSON array of strings, at most 64 KiB), which
//!   run the handler on the main thread;
//! - a later one connects, sends its argv (without argv[0]), waits for the
//!   one-byte acknowledgement and exits.
//!
//! `$TMPDIR` is per user (0700) on macOS, and the primary also checks the
//! peer's uid, so other users can't inject arguments.

const std = @import("std");
const App = @import("../../core/App.zig");
const ShellMod = @import("Shell.zig");

const c = std.c;
const log = std.log.scoped(.oriel);

const max_message = 64 * 1024;

extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn getpeereid(fd: c_int, uid: *c.uid_t, gid: *c.gid_t) c_int;
const LOCK_EX = 2;
const LOCK_NB = 4;

pub const Outcome = enum {
    /// This process is the running instance (it listens now).
    primary,
    /// Another instance got this launch's arguments: exit.
    forwarded,
};

const Paths = struct {
    lock: [:0]const u8,
    sock: [:0]const u8,
};

var handler: ?*const fn ([]const []const u8) void = null;
var listen_fd: c_int = -1;
var lock_fd: c_int = -1;
var sock_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var sock_path: ?[:0]const u8 = null;

/// Only [A-Za-z0-9._-] of the app id reach the file names.
fn sanitize(buf: []u8, id: []const u8) []const u8 {
    const n = @min(id.len, buf.len);
    for (id[0..n], buf[0..n]) |ch, *o| {
        o.* = if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') ch else '_';
    }
    return buf[0..n];
}

fn paths(buf_lock: []u8, buf_sock: []u8, app_id: []const u8) !Paths {
    const tmp = if (c.getenv("TMPDIR")) |t| std.mem.trimEnd(u8, std.mem.span(t), "/") else "/tmp";
    var id_buf: [64]u8 = undefined;
    const id = sanitize(&id_buf, app_id);
    const lock = try std.fmt.bufPrintZ(buf_lock, "{s}/oriel-{s}.lock", .{ tmp, id });
    // sun_path holds 104 bytes on macOS: fall back to a hashed name in /tmp.
    var sock = try std.fmt.bufPrintZ(buf_sock, "{s}/oriel-{s}.sock", .{ tmp, id });
    if (sock.len >= @sizeOf(@FieldType(c.sockaddr.un, "path"))) {
        sock = try std.fmt.bufPrintZ(buf_sock, "/tmp/oriel-{d}-{x}.sock", .{ c.getuid(), std.hash.Wyhash.hash(0, app_id) });
    }
    return .{ .lock = lock, .sock = sock };
}

fn unixAddress(path: [:0]const u8) c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// Decide at startup, before any UI: primary (listening from now on) or
/// forwarded (this launch's `args` went to the running instance).
pub fn acquire(app_id: []const u8, args: []const []const u8, on_second: *const fn ([]const []const u8) void) Outcome {
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = paths(&lock_buf, &sock_path_buf, app_id) catch return .primary;

    const fd = c.open(p.lock.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) {
        log.warn("single instance: can't open {s}; running without it", .{p.lock});
        return .primary;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        _ = c.close(fd);
        // Another instance runs (it may still be starting: retry briefly).
        var attempt: usize = 0;
        while (attempt < 20) : (attempt += 1) {
            if (forward(p.sock, args)) return .forwarded;
            sleepMs(100);
        }
        log.warn("single instance: the running instance doesn't answer on {s}; starting anyway", .{p.sock});
        return .primary;
    }
    lock_fd = fd; // held until the process exits
    handler = on_second;
    listen(p.sock) catch |err| log.warn("single instance: can't listen on {s}: {s}", .{ p.sock, @errorName(err) });
    return .primary;
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, &ts);
}

/// Send `args` to the running instance; true once it acknowledged them.
fn forward(path: [:0]const u8, args: []const []const u8) bool {
    const fd = unixSocket();
    if (fd < 0) return false;
    defer _ = c.close(fd);
    var addr = unixAddress(path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return false;

    var buf: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer buf.deinit();
    std.json.Stringify.value(args, .{}, &buf.writer) catch return false;
    const msg = buf.written();
    if (msg.len > max_message) return false;
    if (!writeAll(fd, msg)) return false;
    _ = c.shutdown(fd, c.SHUT.WR);
    var ack: [1]u8 = undefined;
    return c.read(fd, &ack, 1) == 1;
}

/// A stream Unix socket, close-on-exec (macOS has no SOCK_CLOEXEC flag).
fn unixSocket() c_int {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd >= 0) _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    return fd;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n <= 0) return false;
        off += @intCast(n);
    }
    return true;
}

fn listen(path: [:0]const u8) !void {
    _ = c.unlink(path.ptr); // a stale socket from a crashed primary (we hold the lock)
    const fd = unixSocket();
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var addr = unixAddress(path);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return error.BindFailed;
    _ = c.chmod(path.ptr, 0o600);
    if (c.listen(fd, 8) != 0) return error.ListenFailed;
    listen_fd = fd;
    sock_path = path;
    const thread = try std.Thread.spawn(.{}, acceptLoop, .{fd});
    thread.detach();
}

/// Remove the socket at exit (the lock goes with the process).
pub fn release() void {
    if (sock_path) |p| _ = c.unlink(p.ptr);
    sock_path = null;
}

fn acceptLoop(fd: c_int) void {
    while (true) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) {
            if (std.posix.errno(conn) == .INTR) continue;
            return;
        }
        serve(conn);
        _ = c.close(conn);
    }
}

/// One later launch: read its arguments, hand them to the main thread, ack.
fn serve(conn: c_int) void {
    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    if (getpeereid(conn, &uid, &gid) != 0 or uid != c.getuid()) return;
    const gpa = std.heap.smp_allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(conn, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        if (data.items.len + @as(usize, @intCast(n)) > max_message) return;
        data.appendSlice(gpa, buf[0..@intCast(n)]) catch return;
    }
    // alloc_always: the strings must outlive `data` (freed on return) until
    // the main thread ran the handler.
    const parsed = std.json.parseFromSlice([]const []const u8, gpa, data.items, .{ .allocate = .alloc_always }) catch return;
    // Owned by the task until it ran (or was dropped at shutdown).
    const task = gpa.create(Delivery) catch {
        parsed.deinit();
        return;
    };
    task.* = .{ .parsed = parsed };
    ShellMod.dispatchWithCleanup(&Delivery.run, task, &Delivery.cleanup);
    _ = c.write(conn, "1", 1);
}

const Delivery = struct {
    parsed: std.json.Parsed([]const []const u8),

    fn run(ctx: ?*anyopaque) void {
        const self: *Delivery = @ptrCast(@alignCast(ctx.?));
        defer cleanup(ctx);
        if (handler) |h| h(self.parsed.value);
    }

    fn cleanup(ctx: ?*anyopaque) void {
        const self: *Delivery = @ptrCast(@alignCast(ctx.?));
        self.parsed.deinit();
        std.heap.smp_allocator.destroy(self);
    }
};

test sanitize {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("dev.oriel.My_App-2", sanitize(&buf, "dev.oriel.My App-2"));
    // No path separators survive, so the name stays in $TMPDIR.
    try std.testing.expectEqualStrings(".._etc_passwd", sanitize(&buf, "../etc/passwd"));
}

test "paths fit a Unix socket address" {
    var a: [std.fs.max_path_bytes]u8 = undefined;
    var b: [std.fs.max_path_bytes]u8 = undefined;
    const p = try paths(&a, &b, "dev.oriel.a-rather-long-application-identifier-that-goes-on-and-on-and-on");
    try std.testing.expect(p.sock.len < @sizeOf(@FieldType(c.sockaddr.un, "path")));
    try std.testing.expect(std.mem.endsWith(u8, p.lock, ".lock"));
}
