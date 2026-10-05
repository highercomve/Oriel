//! iOS file dialogs: UIDocumentPickerViewController (the Files picker).
//!
//! - `openFile`: the picked document is copied into the app's temporary
//!   directory (`asCopy`); returns that copy's path.
//! - `saveFile`: iOS has no save panel that yields a path, so the user picks
//!   a folder; returns `<folder>/<name>`, where name is the options' title
//!   when it looks like a file name ("report.txt") and "Untitled" otherwise.
//!   Access to the folder (security scoped) is kept for the rest of the run.
//!
//! - `openFolder`: the user picks a folder; the id is the base64 of its
//!   bookmark (a picked URL's bookmark carries its security scope), kept
//!   across launches. `saveToFolder` resolves it and copies inside
//!   start/stopAccessingSecurityScopedResource and an NSFileCoordinator
//!   write.
//!
//! The picker is presented over the window in front; waiting for it would
//! freeze the main thread, so call these from an async command (a worker
//! thread). On the main thread they return error.MainThread.

const std = @import("std");
const apple = @import("../../platform/ios/apple.zig");
const ShellMod = @import("../../platform/ios/Shell.zig");
const window = @import("../../platform/ios/window.zig");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const path_folder = @import("path_folder.zig");

const Object = apple.Object;

pub const OpenOptions = common.OpenOptions;
pub const SaveOptions = common.SaveOptions;
pub const FolderOptions = common.FolderOptions;
pub const Folder = common.Folder;

extern const UTTypeItem: apple.id;
extern const UTTypeFolder: apple.id;

/// One dialog at a time (they are modal anyway).
var busy: std.atomic.Value(bool) = .init(false);
var result_mutex: std.c.pthread_mutex_t = .{};
var result_cond: std.c.pthread_cond_t = .{};
var result_ready = false;
/// The picked URL's path (smp_allocator), or null when cancelled.
var result: ?[]u8 = null;

var delegate: Object = apple.nil; // main thread; lives for the process
var picker: Object = apple.nil; // the picker on screen (+1)
/// What the picker on screen is for (main thread).
var picking: Kind = .open;

fn finish(path: ?[]const u8) void {
    const copy: ?[]u8 = if (path) |p| std.heap.smp_allocator.dupe(u8, p) catch null else null;
    if (picker.value != null) {
        picker.release();
        picker = apple.nil;
    }
    _ = std.c.pthread_mutex_lock(&result_mutex);
    result = copy;
    result_ready = true;
    _ = std.c.pthread_cond_broadcast(&result_cond);
    _ = std.c.pthread_mutex_unlock(&result_mutex);
}

fn didPick(_: apple.id, _: apple.c.SEL, _: apple.id, urls: apple.id) callconv(.c) void {
    const list: Object = .{ .value = urls };
    if (list.value == null or list.msgSend(c_ulong, "count", .{}) == 0) return finish(null);
    const url = list.msgSend(Object, "objectAtIndex:", .{@as(c_ulong, 0)});
    // A lasting folder: its bookmark (made while it is accessible), base64.
    if (picking == .folder) return finish(bookmarkId(url));
    // A folder (save) stays accessible for the run; a copy (open) needs no scope.
    _ = url.msgSend(apple.c.BOOL, "startAccessingSecurityScopedResource", .{});
    finish(apple.utf8(url.msgSend(Object, "path", .{})));
}

fn wasCancelled(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
    finish(null);
}

const Kind = enum { open, save, folder };

const Show = struct {
    kind: Kind,
    ok: bool = false,

    fn run(self: *Show) void {
        const pool = apple.objc.AutoreleasePool.init();
        defer pool.deinit();
        const front = window.frontController() orelse return;
        if (delegate.value == null) delegate = apple.new(apple.defineClass("OrielDocumentPickerDelegate", &.{"UIDocumentPickerDelegate"}, .{
            .{ "documentPicker:didPickDocumentsAtURLs:", didPick },
            .{ "documentPickerWasCancelled:", wasCancelled },
        }));
        picking = self.kind;
        const types = apple.class("NSArray").msgSend(Object, "arrayWithObject:", .{if (self.kind == .open) UTTypeItem else UTTypeFolder});
        const p = apple.class("UIDocumentPickerViewController").msgSend(Object, "alloc", .{})
            .msgSend(Object, "initForOpeningContentTypes:asCopy:", .{ types, apple.boolean(self.kind == .open) });
        if (p.value == null) return;
        p.msgSend(void, "setDelegate:", .{delegate});
        p.msgSend(void, "setAllowsMultipleSelection:", .{apple.boolean(false)});
        picker = p;
        front.msgSend(void, "presentViewController:animated:completion:", .{ p, apple.boolean(true), apple.nil });
        self.ok = true;
    }
};

fn pick(kind: Kind) !?[]u8 {
    if (apple.isMainThread()) return error.MainThread;
    if (busy.swap(true, .acq_rel)) return error.DialogBusy;
    defer busy.store(false, .release);

    _ = std.c.pthread_mutex_lock(&result_mutex);
    result_ready = false;
    result = null;
    _ = std.c.pthread_mutex_unlock(&result_mutex);

    var show: Show = .{ .kind = kind };
    try ShellMod.runOnMainThread(Show, &show, Show.run);
    if (!show.ok) return error.DialogFailed;

    _ = std.c.pthread_mutex_lock(&result_mutex);
    while (!result_ready) _ = std.c.pthread_cond_wait(&result_cond, &result_mutex);
    const path = result;
    result = null;
    _ = std.c.pthread_mutex_unlock(&result_mutex);
    return path;
}

/// The picked document, copied into the app's temporary directory: its
/// path (caller frees), or null when cancelled.
pub fn openFile(gpa: std.mem.Allocator, options: OpenOptions) !?[]u8 {
    _ = options;
    const path = try pick(.open) orelse return null;
    defer std.heap.smp_allocator.free(path);
    return try gpa.dupe(u8, path);
}

/// A path in the folder the user picked (caller frees), or null when
/// cancelled. See the file comment for the name.
pub fn saveFile(gpa: std.mem.Allocator, options: SaveOptions) !?[]u8 {
    const folder = try pick(.save) orelse return null;
    defer std.heap.smp_allocator.free(folder);
    return try std.fs.path.join(gpa, &.{ folder, saveName(options.title) });
}

// --- Folders with lasting access ---------------------------------------------
//
// The id is the base64 of the picked folder's bookmark. A stale one (the
// folder moved or was renamed) still resolves: it is refreshed for the
// rest of the run (`fresh`), and the id the app stored keeps working.

/// A picked folder URL's bookmark as an id (base64), made inside its
/// security scope; null when that fails.
fn bookmarkId(url: Object) ?[]const u8 {
    const started = apple.isTrue(url.msgSend(apple.c.BOOL, "startAccessingSecurityScopedResource", .{}));
    defer if (started) url.msgSend(void, "stopAccessingSecurityScopedResource", .{});
    const data = url.msgSend(Object, "bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:", .{ @as(c_ulong, 0), apple.nil, apple.nil, @as(?*apple.id, null) });
    if (data.value == null) return null;
    return apple.utf8(data.msgSend(Object, "base64EncodedStringWithOptions:", .{@as(c_ulong, 0)}));
}

/// Fresh bookmarks for stale ids, this run: id -> base64 (smp_allocator).
var fresh: std.StringHashMapUnmanaged([]u8) = .empty;
var fresh_mutex: std.c.pthread_mutex_t = .{};

/// The folder an id names, or error.FolderUnavailable (not an id, or the
/// folder is gone). Autoreleased: call inside a pool.
fn resolve(id: []const u8) error{FolderUnavailable}!Object {
    _ = std.c.pthread_mutex_lock(&fresh_mutex);
    const current: []const u8 = fresh.get(id) orelse id;
    const str = apple.nsString(current);
    _ = std.c.pthread_mutex_unlock(&fresh_mutex);
    const s = str orelse return error.FolderUnavailable;
    defer s.release();
    const data = apple.class("NSData").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithBase64EncodedString:options:", .{ s, @as(c_ulong, 0) });
    if (data.value == null) return error.FolderUnavailable;
    defer data.release();
    var stale: apple.c.BOOL = apple.boolean(false);
    const url = apple.class("NSURL").msgSend(Object, "URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:", .{ data, @as(c_ulong, 0), apple.nil, &stale, @as(?*apple.id, null) });
    if (url.value == null) return error.FolderUnavailable;
    if (apple.isTrue(stale)) refresh(id, url);
    return url;
}

/// A stale bookmark resolved: keep a new one for `id` for this run.
fn refresh(id: []const u8, url: Object) void {
    const new = bookmarkId(url) orelse return;
    const gpa = std.heap.smp_allocator;
    const val = gpa.dupe(u8, new) catch return;
    _ = std.c.pthread_mutex_lock(&fresh_mutex);
    defer _ = std.c.pthread_mutex_unlock(&fresh_mutex);
    if (fresh.getPtr(id)) |old| {
        gpa.free(old.*);
        old.* = val;
        return;
    }
    const key = gpa.dupe(u8, id) catch return gpa.free(val);
    fresh.put(gpa, key, val) catch {
        gpa.free(key);
        gpa.free(val);
    };
}

extern const NSURLLocalizedNameKey: apple.id;

/// The name Files shows for a folder ("On My iPhone"), else its last path
/// component. Autoreleased.
fn displayName(url: Object) ?[]const u8 {
    var name: apple.id = null;
    if (apple.isTrue(url.msgSend(apple.c.BOOL, "getResourceValue:forKey:error:", .{ &name, NSURLLocalizedNameKey, @as(?*apple.id, null) })) and name != null) {
        if (apple.utf8(.{ .value = name })) |n| return n;
    }
    return apple.utf8(url.msgSend(Object, "lastPathComponent", .{}));
}

/// Let the user pick a folder: its id and name, or null when cancelled.
/// Off the main thread (as the other pickers).
pub fn openFolder(gpa: std.mem.Allocator, options: FolderOptions) !?Folder {
    _ = options; // the Files picker has no title
    const id = try pick(.folder) orelse return null;
    defer std.heap.smp_allocator.free(id);
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const url = try resolve(id);
    const name = displayName(url) orelse "Folder";
    const owned_id = try gpa.dupe(u8, id);
    errdefer gpa.free(owned_id);
    return .{ .id = owned_id, .name = try gpa.dupe(u8, name) };
}

/// The folder's name (caller frees); error.FolderUnavailable when gone.
pub fn folderName(gpa: std.mem.Allocator, io: std.Io, id: []const u8) ![]u8 {
    _ = io;
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const url = try resolve(id);
    return gpa.dupe(u8, displayName(url) orelse return error.FolderUnavailable);
}

/// Copy `src_path` into folder `id` as `name` (or "name (n)": never
/// replacing a file). Returns the name used (caller frees).
pub fn saveToFolder(gpa: std.mem.Allocator, io: std.Io, id: []const u8, src_path: []const u8, name: []const u8, mime: ?[]const u8) ![]u8 {
    _ = mime;
    if (!common.validName(name)) return error.InvalidName;
    const pool = apple.objc.AutoreleasePool.init();
    defer pool.deinit();
    const url = try resolve(id);
    if (!apple.isTrue(url.msgSend(apple.c.BOOL, "startAccessingSecurityScopedResource", .{}))) return error.FolderUnavailable;
    defer url.msgSend(void, "stopAccessingSecurityScopedResource", .{});

    // Inside a coordinated write of the folder (iCloud and provider
    // folders): the accessor runs before the call returns.
    const Write = struct {
        gpa: std.mem.Allocator,
        io: std.Io,
        src_path: []const u8,
        name: []const u8,
        result: anyerror![]u8 = error.FolderUnavailable,

        fn invoke(block: *apple.ContextBlock, new_url: apple.id) callconv(.c) void {
            const w: *@This() = @ptrCast(@alignCast(block.ctx.?));
            const dir = apple.utf8((Object{ .value = new_url }).msgSend(Object, "path", .{})) orelse return;
            w.result = path_folder.saveToFolder(w.gpa, w.io, dir, w.src_path, w.name);
        }
    };
    var write: Write = .{ .gpa = gpa, .io = io, .src_path = src_path, .name = name };
    var block = apple.contextBlock(Write.invoke, &write);
    const coordinator = apple.class("NSFileCoordinator").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithFilePresenter:", .{apple.nil});
    defer coordinator.release();
    coordinator.msgSend(void, "coordinateWritingItemAtURL:options:error:byAccessor:", .{ url, @as(c_ulong, 0), @as(?*apple.id, null), block.ptr() });
    return write.result;
}

/// Forget a folder: nothing to release (a bookmark is no grant the
/// system counts); this run's refreshed bookmark goes.
pub fn forgetFolder(id: []const u8) void {
    _ = std.c.pthread_mutex_lock(&fresh_mutex);
    defer _ = std.c.pthread_mutex_unlock(&fresh_mutex);
    if (fresh.fetchRemove(id)) |kv| {
        std.heap.smp_allocator.free(kv.key);
        std.heap.smp_allocator.free(kv.value);
    }
}

fn saveName(title: []const u8) []const u8 {
    const ok = title.len > 0 and std.mem.indexOfScalar(u8, title, '.') != null and
        std.mem.indexOfAny(u8, title, "/\\:") == null and title[0] != '.';
    return if (ok) title else "Untitled";
}

test saveName {
    try std.testing.expectEqualStrings("report.txt", saveName("report.txt"));
    try std.testing.expectEqualStrings("Untitled", saveName("Save File"));
    try std.testing.expectEqualStrings("Untitled", saveName("../x.txt"));
}

pub fn check(_: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const ok = apple.objc.getClass("UIDocumentPickerViewController") != null;
    return .{
        .module = "dialog",
        .ok = ok,
        .detail = if (ok) "UIDocumentPickerViewController (open copies into tmp, save picks a folder, folders as bookmarks)" else "UIDocumentPickerViewController missing",
    };
}
