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
//!
//! Folders (`openFolder`): ACTION_OPEN_DOCUMENT_TREE, then
//! takePersistableUriPermission (read and write), so access survives
//! restarts; the id is the tree URI. `saveToFolder` creates the document
//! with DocumentsContract.createDocument (the provider adds " (1)" to a
//! taken name) and copies the file in on a Kotlin thread; `forgetFolder`
//! releases the grant. These run on Kotlin threads and only wait here, so
//! `folderName` and `saveToFolder` work on any thread (better not the UI
//! one: a cloud provider can be slow).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const runtime = @import("../../platform/android/runtime.zig");
const ShellMod = @import("../../platform/android/Shell.zig");
const jni = @import("../../platform/android/jni.zig");

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;
pub const FolderOptions = common.FolderOptions;
pub const Folder = common.Folder;

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

// --- Folders ---------------------------------------------------------------

/// One call into Kotlin's folder methods, answered once through
/// `NativeLib.onFolderResult(request, status, data)` from any thread.
/// `request` is this struct's address; it lives on the waiting caller's stack.
const Request = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    done: bool = false,
    status: Status = .failed,
    /// heap.gpa
    data: ?[]u8 = null,

    /// Kotlin's statuses (OrielRuntime.FOLDER_*).
    const Status = enum(i32) { ok = 0, unavailable = 1, failed = 2, not_found = 3, _ };

    fn handle(self: *Request) i64 {
        return @intCast(@intFromPtr(self));
    }

    fn wait(self: *Request) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        while (!self.done) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// The answer's data (caller frees with `gpa`), or the status's error.
    fn take(self: *Request, gpa: std.mem.Allocator) ![]u8 {
        const data = self.data;
        self.data = null;
        defer if (data) |d| heap.gpa.free(d);
        switch (self.status) {
            .ok => return gpa.dupe(u8, data orelse return error.FolderFailed),
            .unavailable => return error.FolderUnavailable,
            .not_found => return error.FileNotFound,
            else => return error.FolderFailed,
        }
    }
};

/// Start `OrielRuntime.<name>` (it answers on its own thread) and wait for
/// the answer. `args` follow the request handle.
fn ask(comptime name: [:0]const u8, comptime sig: [:0]const u8, req: *Request, args: anytype) !void {
    const Ctx = struct {
        req: *Request,
        args: @TypeOf(args),
        ok: bool = false,
        fn run(self: *@This()) void {
            self.ok = runtime.call(.boolean, name, sig, .{self.req.handle()} ++ self.args) orelse false;
        }
    };
    var ctx: Ctx = .{ .req = req, .args = args };
    try ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run);
    if (!ctx.ok) return error.FolderFailed;
    req.wait();
}

/// Ask for a folder (ACTION_OPEN_DOCUMENT_TREE) and keep read and write
/// access to it across restarts. Null if cancelled. Not on the UI thread.
pub fn openFolder(gpa: std.mem.Allocator, options: FolderOptions) !?Folder {
    if (ShellMod.isMainThread()) return error.MainThread;
    if (busy.swap(true, .acq_rel)) return error.DialogBusy;
    defer busy.store(false, .release);

    var req: Request = .{};
    try ask("showFolderDialog", "(J[B)Z", &req, .{options.title});
    if (req.status == .ok and req.data == null) return null; // cancelled
    const data = try req.take(heap.gpa);
    defer heap.gpa.free(data);
    const picked = common.splitPicked(data) orelse return error.FolderFailed;
    const id = try gpa.dupe(u8, picked.id);
    errdefer gpa.free(id);
    return .{ .id = id, .name = try gpa.dupe(u8, picked.name) };
}

/// The folder's display name (caller frees).
pub fn folderName(gpa: std.mem.Allocator, io: std.Io, id: []const u8) ![]u8 {
    _ = io;
    if (!common.isTreeUri(id)) return error.FolderUnavailable;
    var req: Request = .{};
    try ask("folderName", "(J[B)Z", &req, .{id});
    return req.take(gpa);
}

/// Copy `src_path` (a file of the app's) into the folder as `name`; returns
/// the name the provider gave it (caller frees). `mime` null: from the
/// extension (MimeTypeMap), which keeps the provider from adding one.
pub fn saveToFolder(gpa: std.mem.Allocator, io: std.Io, id: []const u8, src_path: []const u8, name: []const u8, mime: ?[]const u8) ![]u8 {
    _ = io;
    if (!common.validName(name)) return error.InvalidName;
    if (!common.isTreeUri(id)) return error.FolderUnavailable;
    var req: Request = .{};
    try ask("saveToFolder", "(J[B[B[B[B)Z", &req, .{ id, src_path, name, mime });
    return req.take(gpa);
}

/// Release the persisted grant (releasePersistableUriPermission).
pub fn forgetFolder(id: []const u8) void {
    if (!common.isTreeUri(id)) return;
    const Ctx = struct {
        id: []const u8,
        fn run(self: *@This()) void {
            runtime.call(.void, "forgetFolder", "([B)V", .{self.id}) orelse {};
        }
    };
    var ctx: Ctx = .{ .id = id };
    ShellMod.runOnMainThread(Ctx, &ctx, Ctx.run) catch {};
}

/// `NativeLib.onFolderResult(request, status, data)`: any thread, once per request.
fn onFolderResult(env: *jni.Env, _: jni.jclass, request: jni.jlong, status: jni.jint, data: jni.jobject) callconv(.c) void {
    const req: *Request = @ptrFromInt(@as(usize, @intCast(request)));
    const copy = (env.bytesAlloc(heap.gpa, data) catch null) orelse null;
    _ = std.c.pthread_mutex_lock(&req.mutex);
    req.status = @enumFromInt(status);
    req.data = copy;
    req.done = true;
    _ = std.c.pthread_cond_broadcast(&req.cond);
    _ = std.c.pthread_mutex_unlock(&req.mutex);
}

comptime {
    @export(&onFileDialogResult, .{ .name = "Java_dev_oriel_NativeLib_onFileDialogResult" });
    @export(&onFolderResult, .{ .name = "Java_dev_oriel_NativeLib_onFolderResult" });
}

pub fn check(gpa: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    return .{
        .module = "dialog",
        .ok = true,
        .detail = try std.fmt.allocPrint(gpa, "Storage Access Framework (open copies into the cache, save returns /proc/self/fd/N)", .{}),
    };
}
