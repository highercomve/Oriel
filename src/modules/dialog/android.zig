//! File dialogs through the Storage Access Framework (`ACTION_OPEN_DOCUMENT`,
//! `ACTION_CREATE_DOCUMENT`).
//!
//! SAF hands out `content://` URIs, not paths, so:
//! - `openFile` copies the picked document into the app's cache
//!   (`<cacheDir>/picked/<name>`) and returns that path;
//! - `saveFile` returns `/proc/self/fd/<n>`, a descriptor of the created
//!   document opened for writing: write it with `dialog.writeFile`
//!   (reopening the path fails: the document's storage isn't the app's;
//!   the descriptor stays open for the rest of the run).
//!
//! The picker is an Activity: waiting for it would freeze the UI thread, so
//! call these from an async command (a worker thread). On the UI thread they
//! return error.MainThread.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const jni = @import("../../platform/android/jni.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;

/// One dialog at a time (they are modal anyway).
var busy: std.atomic.Value(bool) = .init(false);
var result_mutex: std.c.pthread_mutex_t = .{};
var result_cond: std.c.pthread_cond_t = .{};
var result_ready = false;
var result: ?[]u8 = null;

const Kind = enum(i32) { open = 0, save = 1 };

fn pick(gpa: std.mem.Allocator, kind: Kind, title: []const u8) !?[]u8 {
    if (ShellMod.isMainThread()) return error.MainThread;
    if (busy.swap(true, .acq_rel)) return error.DialogBusy;
    defer busy.store(false, .release);

    _ = std.c.pthread_mutex_lock(&result_mutex);
    result_ready = false;
    result = null;
    _ = std.c.pthread_mutex_unlock(&result_mutex);

    const Ctx = struct {
        kind: Kind,
        title: []const u8,
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, "showFileDialog", "(I[B)Z", .{ @intFromEnum(self.kind), self.title }) orelse false;
        }
    };
    var ctx: Ctx = .{ .kind = kind, .title = title };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) return error.DialogFailed;

    _ = std.c.pthread_mutex_lock(&result_mutex);
    while (!result_ready) _ = std.c.pthread_cond_wait(&result_cond, &result_mutex);
    const path = result;
    result = null;
    _ = std.c.pthread_mutex_unlock(&result_mutex);

    const p = path orelse return null;
    defer heap.gpa.free(p);
    return try gpa.dupe(u8, p);
}

/// The picked document, copied into the app's cache: its path (caller
/// frees), or null when cancelled.
pub fn openFile(gpa: std.mem.Allocator, options: OpenOptions) !?[]u8 {
    return pick(gpa, .open, options.title);
}

/// A writable `/proc/self/fd/<n>` path for the created document (caller
/// frees), or null when cancelled.
pub fn saveFile(gpa: std.mem.Allocator, options: SaveOptions) !?[]u8 {
    return pick(gpa, .save, options.title);
}

/// `NativeLib.onFileDialogResult(path)`: null when cancelled (UI thread).
fn onFileDialogResult(env: *jni.Env, _: jni.jclass, path: jni.jobject) callconv(.c) void {
    const copy = (env.bytesAlloc(heap.gpa, path) catch null) orelse null;
    _ = std.c.pthread_mutex_lock(&result_mutex);
    result = copy;
    result_ready = true;
    _ = std.c.pthread_cond_broadcast(&result_cond);
    _ = std.c.pthread_mutex_unlock(&result_mutex);
}

comptime {
    @export(&onFileDialogResult, .{ .name = "Java_dev_oriel_NativeLib_onFileDialogResult" });
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "dialog",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Storage Access Framework (open copies into the cache, save returns /proc/self/fd/N)", .{}),
    };
}
