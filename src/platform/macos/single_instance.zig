//! Single instance on macOS (Milestone 10), for apps with
//! `App.Config.on_second_instance`.
//!
//! Launch Services already sends a bundled app's second launch to the
//! running one (as a reopen event: Shell.zig calls the handler with no
//! arguments), but not a binary run directly (a terminal, a script, the
//! executable inside the bundle, `open -n`). So every launch takes an
//! exclusive `flock` on `<user temp dir>/oriel-<id>.lock`:
//!
//! - the first one (primary) keeps it and listens on the Unix socket
//!   `<user temp dir>/oriel-<id>.sock`; each connection carries a later
//!   launch's arguments (a JSON array of strings, at most 64 KiB), which
//!   run the handler on the main thread;
//! - a later one connects, sends its argv (without argv[0]), waits for the
//!   one-byte acknowledgement and exits.
//!
//! Safety:
//! - The files live only in the per-user temp directory (`$TMPDIR`, else
//!   `confstr(_CS_DARWIN_USER_TEMP_DIR)`, mode 0700); never `/tmp`.
//! - The lock file must belong to this user and not be writable by others;
//!   both ends check the other's uid (`getpeereid`).
//! - Every socket has 2 s send/receive timeouts and no SIGPIPE, so a
//!   stalled peer or a hung primary can't block a launch or kill the app.
//! - The primary doesn't acknowledge while it shuts down, and a waiting
//!   launch retries the lock, so it takes over once the old one exits.
//! <id> is the app id reduced to [A-Za-z0-9._-] plus a hash of the full id.

const std = @import("std");
const ShellMod = @import("Shell.zig");

const c = std.c;
const log = std.log.scoped(.oriel);

const max_message = 64 * 1024;
const io_timeout_s = 2;
/// How long a launch keeps trying to reach (or replace) the running one.
const acquire_deadline_ms = 3000;

extern "c" fn flock(fd: c_int, op: c_int) c_int;
extern "c" fn getpeereid(fd: c_int, uid: *c.uid_t, gid: *c.gid_t) c_int;
extern "c" fn confstr(name: c_int, buf: [*]u8, len: usize) usize;
const LOCK_EX = 2;
const LOCK_NB = 4;
const _CS_DARWIN_USER_TEMP_DIR = 65537;

pub const Outcome = enum {
    /// This process is the running instance (it listens now, or runs
    /// without single instance when that couldn't be set up safely).
    primary,
    /// Another instance got this launch's arguments: exit.
    forwarded,
    /// The arguments can't be forwarded (too large): exit with an error
    /// rather than start a second instance.
    failed,
};

const Paths = struct {
    lock: [:0]const u8,
    sock: [:0]const u8,
};

var handler: ?*const fn ([]const []const u8) void = null;
var listen_fd = std.atomic.Value(c_int).init(-1);
var lock_fd: c_int = -1;
var sock_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var sock_path: ?[:0]const u8 = null;

/// Up to 40 characters of the app id, [A-Za-z0-9._-] only.
fn sanitize(buf: []u8, id: []const u8) []const u8 {
    const n = @min(id.len, buf.len, 40);
    for (id[0..n], buf[0..n]) |ch, *o| {
        o.* = if (std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '_') ch else '_';
    }
    return buf[0..n];
}

/// The per-user temp directory, without a trailing slash.
fn userTempDir(buf: []u8) ?[]const u8 {
    if (c.getenv("TMPDIR")) |t| {
        const dir = std.mem.trimEnd(u8, std.mem.span(t), "/");
        if (dir.len > 0 and !std.mem.eql(u8, dir, "/tmp") and !std.mem.eql(u8, dir, "/private/tmp")) return dir;
    }
    const n = confstr(_CS_DARWIN_USER_TEMP_DIR, buf.ptr, buf.len);
    if (n == 0 or n > buf.len) return null;
    return std.mem.trimEnd(u8, buf[0 .. n - 1], "/"); // n counts the terminating 0
}

fn paths(buf_lock: []u8, buf_sock: []u8, tmp: []const u8, app_id: []const u8) !Paths {
    var id_buf: [40]u8 = undefined;
    const id = sanitize(&id_buf, app_id);
    const hash = std.hash.Wyhash.hash(0, app_id);
    const lock = try std.fmt.bufPrintZ(buf_lock, "{s}/oriel-{s}-{x:0>16}.lock", .{ tmp, id, hash });
    // sun_path holds 104 bytes: a long directory gets the hash alone.
    const max_sock = @sizeOf(@FieldType(c.sockaddr.un, "path"));
    var sock = try std.fmt.bufPrintZ(buf_sock, "{s}/oriel-{s}-{x:0>16}.sock", .{ tmp, id, hash });
    if (sock.len >= max_sock) sock = try std.fmt.bufPrintZ(buf_sock, "{s}/oriel-{x:0>16}.sock", .{ tmp, hash });
    if (sock.len >= max_sock) return error.NameTooLong;
    return .{ .lock = lock, .sock = sock };
}

fn unixAddress(path: [:0]const u8) c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .family = c.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

/// 2 s send/receive timeouts and no SIGPIPE on `fd`.
fn hardenSocket(fd: c_int) void {
    const tv: c.timeval = .{ .sec = io_timeout_s, .usec = 0 };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(c.timeval));
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.SNDTIMEO, std.mem.asBytes(&tv), @sizeOf(c.timeval));
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, std.mem.asBytes(&one), @sizeOf(c_int));
}

/// A stream Unix socket, close-on-exec (macOS has no SOCK_CLOEXEC flag).
fn unixSocket() c_int {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd >= 0) _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    return fd;
}

fn samePeer(fd: c_int) bool {
    var uid: c.uid_t = undefined;
    var gid: c.gid_t = undefined;
    return getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
}

/// Decide at startup, before any UI: primary (listening from now on),
/// forwarded (this launch's `args` went to the running instance) or failed.
pub fn acquire(app_id: []const u8, args: []const []const u8, on_second: *const fn ([]const []const u8) void) Outcome {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = userTempDir(&tmp_buf) orelse {
        log.warn("single instance: no per-user temp directory; running without it", .{});
        return .primary;
    };
    var lock_buf: [std.fs.max_path_bytes]u8 = undefined;
    const p = paths(&lock_buf, &sock_path_buf, tmp, app_id) catch {
        log.warn("single instance: temp directory path too long; running without it", .{});
        return .primary;
    };

    const message = encode(args) catch |err| {
        log.err("single instance: can't forward this launch's arguments ({s})", .{@errorName(err)});
        return .failed;
    };
    defer std.heap.smp_allocator.free(message);

    const fd = c.open(p.lock.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) {
        log.warn("single instance: can't open {s}; running without it", .{p.lock});
        return .primary;
    }
    if (!ownedLockFile(fd)) {
        _ = c.close(fd);
        log.warn("single instance: {s} isn't owned by this user or is writable by others; running without it", .{p.lock});
        return .primary;
    }

    // Take the lock, or hand the arguments to whoever holds it. Both are
    // retried: the running one may be starting, or shutting down.
    var waited: u32 = 0;
    while (true) : (waited += 100) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            lock_fd = fd; // held until release / exit
            handler = on_second;
            listen(p.sock) catch |err| log.warn("single instance: can't listen on {s}: {s}", .{ p.sock, @errorName(err) });
            return .primary;
        }
        if (forward(p.sock, message)) {
            _ = c.close(fd);
            return .forwarded;
        }
        if (waited >= acquire_deadline_ms) break;
        sleepMs(100);
    }
    _ = c.close(fd);
    log.warn("single instance: the running instance doesn't answer on {s}; starting anyway", .{p.sock});
    return .primary;
}

/// The lock file belongs to this user and nobody else may write it.
fn ownedLockFile(fd: c_int) bool {
    var st: c.Stat = undefined;
    if (c.fstat(fd, &st) != 0) return false;
    return st.uid == c.getuid() and (st.mode & 0o022) == 0;
}

fn encode(args: []const []const u8) ![]u8 {
    var buf: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    errdefer buf.deinit();
    try std.json.Stringify.value(args, .{}, &buf.writer);
    if (buf.written().len > max_message) return error.ArgumentsTooLarge;
    return buf.toOwnedSlice();
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = 0, .nsec = @as(c_long, ms) * std.time.ns_per_ms };
    _ = c.nanosleep(&ts, &ts);
}

/// Send `message` to the running instance; true once it acknowledged it.
fn forward(path: [:0]const u8, message: []const u8) bool {
    const fd = unixSocket();
    if (fd < 0) return false;
    defer _ = c.close(fd);
    hardenSocket(fd);
    var addr = unixAddress(path);
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.un)) != 0) return false;
    if (!samePeer(fd)) {
        log.warn("single instance: {s} belongs to another user; not forwarding", .{path});
        return false;
    }
    if (!writeAll(fd, message)) return false;
    _ = c.shutdown(fd, c.SHUT.WR);
    var ack: [1]u8 = undefined;
    return readRetry(fd, &ack) == 1;
}

fn readRetry(fd: c_int, buf: []u8) isize {
    while (true) {
        const n = c.read(fd, buf.ptr, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        return n;
    }
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
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
    listen_fd.store(fd, .release);
    sock_path = path;
    const thread = try std.Thread.spawn(.{}, acceptLoop, .{fd});
    thread.detach();
}

/// Stop listening (a later launch then retries the lock and takes over
/// once this process exits), remove the socket and drop the lock.
pub fn release() void {
    const fd = listen_fd.swap(-1, .acq_rel);
    if (fd >= 0) {
        _ = c.shutdown(fd, c.SHUT.RDWR);
        _ = c.close(fd);
    }
    if (sock_path) |p| _ = c.unlink(p.ptr);
    sock_path = null;
    if (lock_fd >= 0) {
        _ = c.close(lock_fd);
        lock_fd = -1;
    }
}

fn acceptLoop(fd: c_int) void {
    while (listen_fd.load(.acquire) == fd) {
        const conn = c.accept(fd, null, null);
        if (conn < 0) {
            switch (std.posix.errno(conn)) {
                .INTR, .CONNABORTED, .AGAIN => continue,
                .MFILE, .NFILE, .NOBUFS, .NOMEM => {
                    sleepMs(100);
                    continue;
                },
                else => return, // closed by release
            }
        }
        _ = c.fcntl(conn, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        hardenSocket(conn);
        serve(conn);
        _ = c.close(conn);
    }
}

/// One later launch: read its arguments, hand them to the main thread, ack.
fn serve(conn: c_int) void {
    if (!samePeer(conn)) return;
    const gpa = std.heap.smp_allocator;
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(gpa);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = readRetry(conn, &buf);
        if (n < 0) return; // timed out (a stalled peer) or failed
        if (n == 0) break;
        if (data.items.len + @as(usize, @intCast(n)) > max_message) return;
        data.appendSlice(gpa, buf[0..@intCast(n)]) catch return;
    }
    // Shutting down: no ack, so the launch retries the lock and takes over.
    if (!ShellMod.isRunning()) return;
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
    _ = writeAll(conn, "1");
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
    // No path separators survive, so the name stays in the temp directory.
    try std.testing.expectEqualStrings(".._etc_passwd", sanitize(&buf, "../etc/passwd"));
}

test "paths: distinct ids stay distinct, and fit a Unix socket address" {
    var a1: [std.fs.max_path_bytes]u8 = undefined;
    var b1: [std.fs.max_path_bytes]u8 = undefined;
    var a2: [std.fs.max_path_bytes]u8 = undefined;
    var b2: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = "/var/folders/wn/_3bg02915k39rp_4tx72vqkm0000gn/T";
    const p1 = try paths(&a1, &b1, tmp, "a b");
    const p2 = try paths(&a2, &b2, tmp, "a_b");
    try std.testing.expect(!std.mem.eql(u8, p1.sock, p2.sock));
    const long = try paths(&a1, &b1, tmp, "dev.oriel.a-rather-long-application-identifier-that-goes-on-and-on-and-on");
    try std.testing.expect(long.sock.len < @sizeOf(@FieldType(c.sockaddr.un, "path")));
    try std.testing.expect(std.mem.startsWith(u8, long.sock, tmp));
    try std.testing.expect(std.mem.endsWith(u8, long.lock, ".lock"));
}

test userTempDir {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = userTempDir(&buf) orelse return error.SkipZigTest;
    try std.testing.expect(!std.mem.eql(u8, dir, "/tmp"));
}

test encode {
    const small = try encode(&.{ "a", "b c" });
    defer std.heap.smp_allocator.free(small);
    try std.testing.expectEqualStrings("[\"a\",\"b c\"]", small);
    const big = [_][]const u8{"x" ** (max_message + 1)};
    try std.testing.expectError(error.ArgumentsTooLarge, encode(&big));
}
