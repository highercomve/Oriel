//! oriel.share on Android (the Kotlin half: OrielShare.kt).
//!
//! Receiving: ACTION_SEND and SEND_MULTIPLE intents on the main Activity
//! (declared from `.share_target`). Kotlin opens each shared stream
//! read-only (a pipe is copied into the cache first) and hands the
//! descriptors over in `NativeLib.onShare`'s JSON; they become handles here.
//!
//! Sending: Intent.createChooser from the window in front. Files go through
//! OrielFileProvider: each is written under `<cache>/oriel-shared/share-out/`
//! (the provider's directory), removed on the next send. Android reports the
//! chosen target, not a dismissal: Kotlin reports `completed: false` when an
//! Oriel window is in front again without a choice.

const std = @import("std");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const heap = @import("../../core/heap.zig");
const jni = @import("../../platform/android/jni.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const paths = @import("../../platform/android/paths.zig");

const log = std.log.scoped(.share);
const gpa = heap.gpa;
const received = &common.received;

/// Shares received and not released: id -> its files' handles. Main thread.
var shares: std.AutoHashMapUnmanaged(u32, []u32) = .empty;
var next_share: u32 = 1;
/// Received files' names by handle (a handle sent on keeps its name).
var names: std.AutoHashMapUnmanaged(u32, []u8) = .empty;

// --------------------------------------------------------------- receive

const InFile = struct { fd: i32, name: []const u8 = "file", mime: []const u8 = "application/octet-stream" };

const Incoming = struct {
    text: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    url: ?[]const u8 = null,
    files: []const InFile = &.{},
};

/// `NativeLib.onShare(json)`, on the main thread: Kotlin's description of
/// a share. Its descriptors were detached for us: ours to close from here.
fn onShare(env: *jni.Env, _: jni.jclass, data: jni.jobject) callconv(.c) void {
    const bytes = (env.bytesAlloc(gpa, data) catch null) orelse return;
    defer gpa.free(bytes);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const in = std.json.parseFromSliceLeaky(Incoming, arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch |err| {
        log.err("share: a malformed share from the runtime: {s}", .{@errorName(err)});
        return;
    };
    receive(in);
}

fn receive(in: Incoming) void {
    var files: std.ArrayList(common.File) = .empty;
    defer files.deinit(gpa);
    var handles: std.ArrayList(u32) = .empty;
    defer handles.deinit(gpa);
    for (in.files, 0..) |f, i| {
        if (!keep(f, &files, &handles)) {
            // Out of memory: the rest are closed unread.
            for (in.files[i + 1 ..]) |rest| _ = std.c.close(rest.fd);
            break;
        }
    }
    if (files.items.len == 0 and in.text == null and in.url == null) return;
    const id = next_share;
    next_share +%= 1;
    if (next_share == 0) next_share = 1;
    shares.ensureUnusedCapacity(gpa, 1) catch {
        for (handles.items) |h| dropFile(h);
        return;
    };
    const owned = handles.toOwnedSlice(gpa) catch {
        for (handles.items) |h| dropFile(h);
        return;
    };
    shares.putAssumeCapacity(id, owned);
    const r: common.Received = .{ .id = id, .source = .share, .text = in.text, .subject = in.subject, .url = in.url, .files = files.items };
    common.dispatch(&r);
}

/// One received descriptor into the table and the lists. False when out
/// of memory (the descriptor is closed either way on failure).
fn keep(f: InFile, files: *std.ArrayList(common.File), handles: *std.ArrayList(u32)) bool {
    const handle = received.addFd(f.fd) catch |e| {
        log.warn("share: a received file can't be kept: {s}", .{@errorName(e)});
        return e != error.OutOfMemory;
    };
    const size = received.info(handle).?.size;
    const name = gpa.dupe(u8, std.fs.path.basenamePosix(f.name)) catch {
        received.release(handle);
        return false;
    };
    names.ensureUnusedCapacity(gpa, 1) catch {
        gpa.free(name);
        received.release(handle);
        return false;
    };
    handles.append(gpa, handle) catch {
        gpa.free(name);
        received.release(handle);
        return false;
    };
    files.append(gpa, .{ .handle = handle, .name = name, .mime = f.mime, .size = size }) catch {
        _ = handles.pop();
        gpa.free(name);
        received.release(handle);
        return false;
    };
    names.putAssumeCapacity(handle, name);
    return true;
}

fn dropFile(h: u32) void {
    received.release(h);
    if (names.fetchRemove(h)) |n| gpa.free(n.value);
}

// --------------------------------------------------------------- send

/// A chooser is open (main thread), and who hears how it closed.
var sending = false;
var pending_done: ?common.DoneHandler = null;
/// When the open chooser was started (ms, monotonic): one that never
/// reported back (its Activity went) stops blocking new sends after a minute.
var sending_since: i64 = 0;
/// Files the last send wrote (each in its own folder), removed on the next.
var out_files: std.ArrayList([:0]u8) = .empty;
var out_seq: u32 = 0;

/// Open the system chooser with `item` from the window in front. `done`
/// runs on the main thread when it closes. `anchor` is unused (Android's
/// chooser is a sheet).
pub fn send(item: common.Outgoing, anchor: ?common.Rect, done: ?common.DoneHandler) common.SendError!void {
    _ = anchor;
    const Call = struct {
        item: common.Outgoing,
        done: ?common.DoneHandler,
        err: ?common.SendError = null,
        fn run(c: *@This()) void {
            start(c.item, c.done) catch |e| {
                c.err = e;
            };
        }
    };
    var call: Call = .{ .item = item, .done = done };
    ShellMod.runOnMainThread(Call, &call, Call.run) catch return error.Unsupported;
    if (call.err) |e| return e;
}

const OutJson = struct { path: []const u8, name: []const u8, mime: []const u8 };

fn start(item: common.Outgoing, done: ?common.DoneHandler) common.SendError!void {
    if (sending) {
        if (nowMs() - sending_since < 60_000) return error.Busy;
        // Never reported back: its `done` hears it was dismissed.
        sending = false;
        const stale = pending_done;
        pending_done = null;
        if (stale) |d| d(.{ .completed = false });
    }
    if (item.text == null and item.url == null and item.files.len == 0) return error.Unsupported;
    sweepOut();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const files = a.alloc(OutJson, item.files.len) catch return error.Unsupported;
    for (item.files, files) |f, *out| {
        out.* = writeOut(a, f) catch |e| {
            log.warn("share: a file can't be sent: {s}", .{@errorName(e)});
            return switch (e) {
                error.BadHandle, error.NotReadable => error.InvalidHandle,
                else => error.Unsupported,
            };
        };
    }
    const json = std.json.Stringify.valueAlloc(a, .{
        .title = item.title,
        .text = item.text,
        .url = item.url,
        .files = files,
    }, .{ .emit_null_optional_fields = false }) catch return error.Unsupported;
    sending = true;
    sending_since = nowMs();
    pending_done = done;
    if (!(runtime.call(.boolean, "shareSend", "([B)Z", .{json}) orelse false)) {
        sending = false;
        pending_done = null;
        return error.Unsupported;
    }
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// `NativeLib.onShareSent(completed, target)`: the chooser closed.
fn onShareSent(env: *jni.Env, _: jni.jclass, completed: jni.jboolean, target: jni.jobject) callconv(.c) void {
    if (!sending) return;
    sending = false;
    const done = pending_done;
    pending_done = null;
    const t: ?[]u8 = env.bytesAlloc(gpa, target) catch null;
    defer if (t) |x| gpa.free(x);
    if (done) |d| d(.{ .completed = completed != 0, .target = t });
}

/// A file to send, written where OrielFileProvider serves it from:
/// `<cache>/oriel-shared/share-out/<n>/<name>` (the provider serves only
/// its own directory, so a path is copied too).
fn writeOut(a: std.mem.Allocator, f: common.OutFile) !OutJson {
    switch (f) {
        .path => |p| {
            if (!std.fs.path.isAbsolutePosix(p)) return error.NotAbsolute;
            const z = try a.dupeZ(u8, p);
            const src = std.c.open(z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            if (src < 0) return error.NotReadable;
            defer _ = std.c.close(src);
            const name = std.fs.path.basenamePosix(p);
            const fd, const path = try createOut(name);
            defer _ = std.c.close(fd);
            var buf: [64 * 1024]u8 = undefined;
            while (true) {
                const n = std.c.read(src, &buf, buf.len);
                if (n < 0) return error.NotReadable;
                if (n == 0) break;
                try writeAll(fd, buf[0..@intCast(n)]);
            }
            return .{ .path = path, .name = name, .mime = common.mimeOf(name) };
        },
        .handle => |h| {
            const e = received.info(h) orelse return error.BadHandle;
            const name = names.get(h) orelse "file";
            const fd, const path = try createOut(name);
            defer _ = std.c.close(fd);
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(gpa);
            var off: u64 = 0;
            while (off < e.size) {
                buf.clearRetainingCapacity();
                received.read(h, off, @min(e.size - off, 4 << 20), &buf) catch |err| return switch (err) {
                    error.BadHandle => error.BadHandle,
                    else => error.NotReadable,
                };
                try writeAll(fd, buf.items);
                off += buf.items.len;
            }
            return .{ .path = path, .name = name, .mime = common.mimeOf(name) };
        },
        .bytes => |b| {
            const fd, const path = try createOut(b.name);
            defer _ = std.c.close(fd);
            try writeAll(fd, b.bytes);
            return .{ .path = path, .name = b.name, .mime = common.mimeOf(b.name) };
        },
    }
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var done: usize = 0;
    while (done < bytes.len) {
        const n = std.c.write(fd, bytes[done..].ptr, bytes.len - done);
        if (n <= 0) return error.WriteFailed;
        done += @intCast(n);
    }
}

/// A new file named `name` in its own folder under the provider's
/// directory: its descriptor and path (owned by `out_files`).
fn createOut(name: []const u8) !struct { std.c.fd_t, [:0]const u8 } {
    const cache = paths.cacheDir() orelse return error.NoCacheDir;
    const base = std.fs.path.basenamePosix(name);
    const safe = if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) "file" else base;
    const shared = try std.fmt.allocPrintSentinel(gpa, "{s}/oriel-shared", .{cache}, 0);
    defer gpa.free(shared);
    _ = std.c.mkdir(shared, 0o700);
    const root = try std.fmt.allocPrintSentinel(gpa, "{s}/share-out", .{shared}, 0);
    defer gpa.free(root);
    _ = std.c.mkdir(root, 0o700);
    const dir = for (0..64) |_| {
        out_seq +%= 1;
        const d = try std.fmt.allocPrintSentinel(gpa, "{s}/{d}", .{ root, out_seq }, 0);
        if (std.c.mkdir(d, 0o700) == 0) break d;
        gpa.free(d);
    } else return error.NoTempDir;
    defer gpa.free(dir);
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, safe }, 0);
    errdefer gpa.free(path);
    try out_files.ensureUnusedCapacity(gpa, 1);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) {
        _ = std.c.rmdir(dir);
        return error.CreateFailed;
    }
    out_files.appendAssumeCapacity(path);
    return .{ fd, path };
}

/// The last send's files and their folders (the target had its chance).
fn sweepOut() void {
    for (out_files.items) |p| {
        _ = std.c.unlink(p);
        const slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse 0;
        if (slash > 0) {
            // The folder: the path cut at its last '/' (in place, then freed).
            p[slash] = 0;
            _ = std.c.rmdir(p[0..slash :0]);
        }
        gpa.free(p);
    }
    out_files.clearRetainingCapacity();
}

// --------------------------------------------------------------- the rest

pub fn capabilities() common.Capabilities {
    return .{ .receive = .share, .send = .{ .supported = true, .files = true, .text = true, .url = true, .multiple = true } };
}

/// A received file, read-only: a new descriptor for the file `handle`
/// names (the caller closes it). InvalidHandle once released.
pub fn open(handle: u32) common.OpenError!std.Io.File {
    return received.duplicate(handle) catch error.InvalidHandle;
}

/// Let a share's files go: their descriptors close.
pub fn release(id: u32) void {
    const kv = shares.fetchRemove(id) orelse return;
    for (kv.value) |h| dropFile(h);
    gpa.free(kv.value);
}

pub fn check(alloc: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{ .module = "share", .ok = true, .detail = try alloc.dupe(u8, "receive: ACTION_SEND (share_target); send: Intent.createChooser") };
}

comptime {
    @export(&onShare, .{ .name = "Java_dev_oriel_NativeLib_onShare" });
    @export(&onShareSent, .{ .name = "Java_dev_oriel_NativeLib_onShareSent" });
}
