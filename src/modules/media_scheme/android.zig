//! Media scheme on Android: the files below the root at
//! `https://app.localhost/media/<path>` (the app's own origin), served by the
//! Kotlin runtime straight from the WebView's request interception
//! (OrielMedia.kt): Range requests for seeking, nothing read into memory, no
//! port. A `Source` set with `setSource` answers there instead of the root:
//! OrielMedia asks it through `NativeLib.mediaSize` and `mediaRead`.

const std = @import("std");
const open = @import("../media/open.zig");
const source_mod = @import("../media/source.zig");
const Source = source_mod.Source;
const heap = @import("../../core/heap.zig");
const jni = @import("../../platform/android/jni.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");

/// Where the page finds the root's files: `<base_url><path>`.
pub const base_url = "https://app.localhost/media/";

/// Serve the files below `path` (replacing any previous root). Any thread.
pub fn setRoot(path: []const u8, policy: open.SymlinkPolicy) !void {
    if (!std.fs.path.isAbsolutePosix(path)) return error.NotAbsolute;
    try call(path, policy == .refuse_all);
}

/// Stop serving `/media/` (requests get 404).
pub fn clearRoot() void {
    call("", false) catch {};
}

fn call(path: []const u8, refuse_all: bool) !void {
    const Ctx = struct {
        path: []const u8,
        refuse_all: bool,
        fn run(c: *@This()) void {
            _ = runtime.call(.void, "setMediaRoot", "([BZ)V", .{ c.path, c.refuse_all });
        }
    };
    var ctx: Ctx = .{ .path = path, .refuse_all = refuse_all };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
}

/// The registered source. Calls into it hold the lock shared, so replacing
/// or clearing it waits for them: after `clearSource` returns, nothing uses
/// the old one's ctx.
var source_lock: std.Io.RwLock = .init;
var source: ?Source = null;

/// Locks only (futexes): any thread, including the WebView's.
fn lockIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn swapSource(new: ?Source) ?Source {
    source_lock.lockUncancelable(lockIo());
    defer source_lock.unlock(lockIo());
    const old = source;
    source = new;
    return old;
}

/// Serve `src` at `<base_url><path>` instead of the root (replacing any
/// previous source). Any thread, but not while holding something the
/// source's own calls wait for: this waits for calls in progress.
pub fn setSource(src: Source) !void {
    const old = swapSource(src);
    errdefer _ = swapSource(old);
    try callSource(true);
}

/// Back to the root (or 404 without one). Returns once no call into the
/// source is in progress.
pub fn clearSource() void {
    callSource(false) catch {};
    _ = swapSource(null);
}

fn callSource(active: bool) !void {
    const Ctx = struct {
        active: bool,
        fn run(c: *@This()) void {
            _ = runtime.call(.void, "setMediaSource", "(Z)V", .{c.active});
        }
    };
    var ctx: Ctx = .{ .active = active };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
}

/// `NativeLib.mediaSize(path)`: the size, or -1 (no source, no such file).
/// The WebView's IO thread.
fn nativeMediaSize(env: *jni.Env, _: jni.jclass, path_arr: jni.jobject) callconv(.c) jni.jlong {
    const gpa = heap.gpa;
    const path = (env.bytesAlloc(gpa, path_arr) catch return -1) orelse return -1;
    defer gpa.free(path);
    source_lock.lockSharedUncancelable(lockIo());
    defer source_lock.unlockShared(lockIo());
    const src = source orelse return -1;
    return source_mod.javaSize(src, path);
}

/// `NativeLib.mediaRead(path, offset, buf)`: fills `buf` from `offset`; the
/// count, 0 at the end, -1 on error or with no source. OrielMedia's stream.
fn nativeMediaRead(env: *jni.Env, _: jni.jclass, path_arr: jni.jobject, offset: jni.jlong, buf: jni.jobject) callconv(.c) jni.jint {
    if (buf == null) return -1;
    const gpa = heap.gpa;
    const path = (env.bytesAlloc(gpa, path_arr) catch return -1) orelse return -1;
    defer gpa.free(path);
    const len: usize = @min(@as(usize, @intCast(@max(env.functions.GetArrayLength(env, buf), 0))), source_mod.chunk_size);
    if (len == 0) return 0;
    // Copied out with SetByteArrayRegion: a pinned array (GetPrimitiveArrayCritical)
    // can't be held across a source that may block on the network.
    const tmp = gpa.alloc(u8, len) catch return -1;
    defer gpa.free(tmp);
    const n = blk: {
        source_lock.lockSharedUncancelable(lockIo());
        defer source_lock.unlockShared(lockIo());
        const src = source orelse return -1;
        break :blk source_mod.javaRead(src, path, offset, tmp);
    };
    if (n > 0) env.functions.SetByteArrayRegion(env, buf, 0, n, tmp.ptr);
    return n;
}

comptime {
    @export(&nativeMediaSize, .{ .name = "Java_dev_oriel_NativeLib_mediaSize" });
    @export(&nativeMediaRead, .{ .name = "Java_dev_oriel_NativeLib_mediaRead" });
}
