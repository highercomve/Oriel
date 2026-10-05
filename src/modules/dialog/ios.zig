//! iOS file dialogs: UIDocumentPickerViewController (the Files picker).
//!
//! - `openFile`: the picked document is copied into the app's temporary
//!   directory (`asCopy`); returns that copy's path.
//! - `saveFile`: iOS has no save panel that yields a path, so the user picks
//!   a folder; returns `<folder>/<name>`, where name is the options' title
//!   when it looks like a file name ("report.txt") and "Untitled" otherwise.
//!   Access to the folder (security scoped) is kept for the rest of the run.
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
    // A folder (save) stays accessible for the run; a copy (open) needs no scope.
    _ = url.msgSend(apple.c.BOOL, "startAccessingSecurityScopedResource", .{});
    finish(apple.utf8(url.msgSend(Object, "path", .{})));
}

fn wasCancelled(_: apple.id, _: apple.c.SEL, _: apple.id) callconv(.c) void {
    finish(null);
}

const Kind = enum { open, save };

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
// TODO(ios): not written yet; every call returns error.Unsupported.
// - openFolder: present UIDocumentPickerViewController
//   `initForOpeningContentTypes:@[UTTypeFolder]` (asCopy NO) through `pick`,
//   then on the picked URL: startAccessingSecurityScopedResource,
//   `bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil
//   relativeToURL:nil error:` (iOS has no `withSecurityScope` option: a
//   picked URL's bookmark carries its scope), stopAccessing. id = the
//   bookmark's base64 (`base64EncodedStringWithOptions:0`); name =
//   `lastPathComponent` (or NSURLLocalizedNameKey).
// - folderName / saveToFolder: decode the id, `URLByResolvingBookmarkData:
//   options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:`; nil ->
//   error.FolderUnavailable. Wrap the work in start/stopAccessing...; if
//   startAccessing returns NO -> error.FolderUnavailable. A stale bookmark
//   still resolves: the id can't change under the app, so it keeps working
//   until the next openFolder.
// - saveToFolder: write `<folder>/<name>` with no-clobber numbering, like
//   path_folder.saveToFolder (createFile exclusive, `common.numberedName`),
//   ideally inside an NSFileCoordinator `coordinateWritingItemAtURL:` for
//   iCloud/provider folders.
// - forgetFolder: nothing to release (a bookmark isn't a grant the system
//   counts); the app drops the id.

pub fn openFolder(gpa: std.mem.Allocator, options: FolderOptions) !?Folder {
    _ = .{ gpa, options };
    return error.Unsupported;
}

pub fn folderName(gpa: std.mem.Allocator, io: std.Io, id: []const u8) ![]u8 {
    _ = .{ gpa, io, id };
    return error.Unsupported;
}

pub fn saveToFolder(gpa: std.mem.Allocator, io: std.Io, id: []const u8, src_path: []const u8, name: []const u8, mime: ?[]const u8) ![]u8 {
    _ = .{ gpa, io, id, src_path, name, mime };
    return error.Unsupported;
}

pub fn forgetFolder(id: []const u8) void {
    _ = id;
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
        .detail = if (ok) "UIDocumentPickerViewController (open copies into tmp, save picks a folder)" else "UIDocumentPickerViewController missing",
    };
}
