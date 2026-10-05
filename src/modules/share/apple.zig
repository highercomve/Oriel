//! oriel.share on macOS and iOS. Receiving: files the system opens with the
//! app, from CFBundleDocumentTypes (macOS Finder's "Open With" and drops on
//! the Dock icon, through the app delegate's application:openURLs:; iOS's
//! "Open in" and Files, through the scene's URL contexts, as copies in
//! Documents/Inbox). Sending: NSSharingServicePicker (macOS) and
//! UIActivityViewController (iOS), from the main window. Not written yet:
//! macOS Services.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");
const App = @import("../../core/App.zig");

const is_macos = builtin.os.tag == .macos;
const rt = if (is_macos) @import("../../platform/macos/cocoa.zig") else @import("../../platform/ios/apple.zig");
const ShellMod = if (is_macos) @import("../../platform/macos/Shell.zig") else @import("../../platform/ios/Shell.zig");
const Object = rt.Object;

const log = std.log.scoped(.share);
const gpa = std.heap.smp_allocator;
const received = &common.received;

/// Shares received and not released: id -> its files' handles. Main thread.
var shares: std.AutoHashMapUnmanaged(u32, []u32) = .empty;
var next_share: u32 = 1;
/// Received files' names by handle (a handle sent on is copied under its
/// name: the target sees its type). Freed with the share.
var names: std.AutoHashMapUnmanaged(u32, []u8) = .empty;

/// Files the system handed the app (absolute paths), as one share from
/// `source`, on the main thread. Each is opened in place, read-only;
/// those that can't be (gone, a folder) are left out. `copies`: the files
/// may be the app's own copies (iOS's Documents/Inbox): those are unlinked
/// once open (the descriptor keeps them readable until released).
pub fn receivePaths(paths: []const []const u8, source: common.Source, copies: bool) void {
    var files: std.ArrayList(common.File) = .empty;
    defer files.deinit(gpa);
    var handles: std.ArrayList(u32) = .empty;
    defer handles.deinit(gpa);
    for (paths) |path| {
        const kept = keepFile(path);
        if (copies) removeCopy(path);
        const f = kept catch |e| {
            log.warn("share: a received file can't be opened: {s}", .{@errorName(e)});
            continue;
        } orelse continue;
        handles.append(gpa, f.handle) catch {
            received.release(f.handle);
            continue;
        };
        files.append(gpa, f) catch {
            _ = handles.pop();
            received.release(f.handle);
            continue;
        };
        if (gpa.dupe(u8, f.name)) |n| {
            names.put(gpa, f.handle, n) catch gpa.free(n);
        } else |_| {}
    }
    if (files.items.len == 0) return;
    const id = next_share;
    next_share +%= 1;
    if (next_share == 0) next_share = 1;
    // Out of memory: the share is dropped, its files closed.
    shares.ensureUnusedCapacity(gpa, 1) catch {
        for (files.items) |f| dropFile(f.handle);
        return;
    };
    const owned = handles.toOwnedSlice(gpa) catch {
        for (files.items) |f| dropFile(f.handle);
        return;
    };
    shares.putAssumeCapacity(id, owned);
    const r: common.Received = .{ .id = id, .source = source, .files = files.items };
    common.dispatch(&r);
}

fn dropFile(h: u32) void {
    received.release(h);
    if (names.fetchRemove(h)) |n| gpa.free(n.value);
}

/// Open `path` into `received`: its File (name and type for the page, no
/// path), or null when it isn't a regular file.
fn keepFile(path: []const u8) !?common.File {
    if (!std.fs.path.isAbsolutePosix(path)) return error.NotAbsolute;
    const z = try gpa.dupeZ(u8, path);
    defer gpa.free(z);
    const handle = try received.addPath(z) orelse return null;
    const e = received.info(handle).?;
    const name = std.fs.path.basenamePosix(path);
    return .{ .handle = handle, .name = name, .mime = common.mimeOf(name), .size = e.size };
}

/// Unlink an iOS Inbox copy (the app owns those; nothing else is removed).
fn removeCopy(path: []const u8) void {
    if (std.mem.indexOf(u8, path, "/Documents/Inbox/") == null) return;
    const z = gpa.dupeZ(u8, path) catch return;
    defer gpa.free(z);
    _ = std.c.unlink(z);
}

// --------------------------------------------------------------- send

/// The share sheet that is open (main thread).
const Pending = struct {
    done: ?common.DoneHandler,
    /// The picker or the activity view controller (+1).
    sheet: Object,
    /// macOS: the service the user picked (its title: the Result's target).
    target: ?[]u8 = null,
    /// macOS: a service was picked; some never report back (an extension
    /// the user closes): the next send finishes this one rather than wait.
    chosen: bool = false,
};
var pending: ?Pending = null;
/// The folders `send` wrote files into (each holds one file); removed on
/// the next send (the target may still be reading them after the sheet).
var temp_dirs: std.ArrayList([:0]u8) = .empty;
var temp_seq: u32 = 0;

/// Open the system share sheet with `item` (macOS: NSSharingServicePicker
/// over the main window, at `anchor` or its center; iOS: a
/// UIActivityViewController over the front controller, its iPad popover
/// at `anchor` or the center). `done` runs on the main thread when it
/// closes: `completed` once a target took the items.
pub fn send(item: common.Outgoing, anchor: ?common.Rect, done: ?common.DoneHandler) common.SendError!void {
    const Call = struct {
        item: common.Outgoing,
        anchor: ?common.Rect,
        done: ?common.DoneHandler,
        err: ?common.SendError = null,
        fn run(c: *@This()) void {
            start(c.item, c.anchor, c.done) catch |e| {
                c.err = e;
            };
        }
    };
    var call: Call = .{ .item = item, .anchor = anchor, .done = done };
    ShellMod.runOnMainThread(Call, &call, Call.run) catch return error.Unsupported;
    if (call.err) |e| return e;
}

fn start(item: common.Outgoing, anchor: ?common.Rect, done: ?common.DoneHandler) common.SendError!void {
    if (pending) |p| {
        if (!p.chosen) return error.Busy;
        finish(false, null);
    }
    if (item.text == null and item.url == null and item.files.len == 0) return error.Unsupported;
    const pool = rt.objc.AutoreleasePool.init();
    defer pool.deinit();
    sweepTemp();
    const items = rt.class("NSMutableArray").msgSend(Object, "array", .{});
    if (item.text) |t| if (rt.nsString(t)) |str| {
        defer str.release();
        items.msgSend(void, "addObject:", .{str});
    };
    if (item.url) |u| if (rt.nsString(u)) |str| {
        defer str.release();
        const url = rt.class("NSURL").msgSend(Object, "URLWithString:", .{str});
        if (url.value != null) items.msgSend(void, "addObject:", .{url}) else items.msgSend(void, "addObject:", .{str});
    };
    for (item.files) |f| {
        const path = filePath(f) catch |e| {
            log.warn("share: a file can't be sent: {s}", .{@errorName(e)});
            return switch (e) {
                error.BadHandle, error.NotReadable => error.InvalidHandle,
                else => error.Unsupported,
            };
        };
        defer gpa.free(path);
        const str = rt.nsString(path) orelse return error.Unsupported;
        defer str.release();
        items.msgSend(void, "addObject:", .{rt.class("NSURL").msgSend(Object, "fileURLWithPath:", .{str})});
    }
    if (items.msgSend(c_ulong, "count", .{}) == 0) return error.Unsupported;
    // Pending before it shows: an older macOS's picker is a menu whose
    // tracking (and the choice) happens inside the show.
    const sheet = ui.make(items) orelse return error.Unsupported;
    pending = .{ .done = done, .sheet = sheet };
    if (!ui.present(sheet, anchor)) {
        pending = null;
        sheet.release();
        return error.Unsupported;
    }
}

/// The sheet closed: `done` hears how.
fn finish(completed: bool, target: ?[]const u8) void {
    const p = pending orelse return;
    pending = null;
    defer {
        // Later: this may run inside the sheet's own callback (or its show).
        _ = p.sheet.msgSend(Object, "autorelease", .{});
        if (p.target) |t| gpa.free(t);
    }
    if (p.done) |d| d(.{ .completed = completed, .target = target orelse p.target });
}

/// A file to send as a path: its own, or a copy in a temporary folder (a
/// received file, which may have no path any more, and bytes). Owned.
fn filePath(f: common.OutFile) ![:0]u8 {
    switch (f) {
        .path => |p| {
            if (!std.fs.path.isAbsolutePosix(p)) return error.NotAbsolute;
            return gpa.dupeZ(u8, p);
        },
        .handle => |h| {
            const e = received.info(h) orelse return error.BadHandle;
            const fd, const path = try createTemp(names.get(h) orelse "file");
            defer _ = std.c.close(fd);
            errdefer gpa.free(path);
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
            return path;
        },
        .bytes => |b| {
            const fd, const path = try createTemp(b.name);
            defer _ = std.c.close(fd);
            errdefer gpa.free(path);
            try writeAll(fd, b.bytes);
            return path;
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

extern "c" fn NSTemporaryDirectory() rt.id;

/// A new file named `name` in its own folder under the temporary
/// directory (oriel-share/<n>/): its descriptor and path (owned).
fn createTemp(name: []const u8) !struct { std.c.fd_t, [:0]u8 } {
    const tmp = rt.utf8(.{ .value = NSTemporaryDirectory() }) orelse return error.NoTempDir;
    const base = std.fs.path.basenamePosix(name);
    const safe = if (base.len == 0 or std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) "file" else base;
    const root = try std.fmt.allocPrintSentinel(gpa, "{s}/oriel-share", .{std.mem.trimEnd(u8, tmp, "/")}, 0);
    defer gpa.free(root);
    _ = std.c.mkdir(root, 0o700);
    if (!swept_stale) {
        swept_stale = true;
        sweepStale(root);
    }
    // A new folder (one left by an earlier process with this pid: the next).
    const dir = for (0..64) |_| {
        temp_seq +%= 1;
        const d = try std.fmt.allocPrintSentinel(gpa, "{s}/{d}-{d}", .{ root, std.c.getpid(), temp_seq }, 0);
        if (std.c.mkdir(d, 0o700) == 0) break d;
        gpa.free(d);
    } else return error.NoTempDir;
    try temp_dirs.ensureUnusedCapacity(gpa, 1);
    temp_dirs.appendAssumeCapacity(dir); // owns it from here (removed by sweepTemp)
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, safe }, 0);
    errdefer gpa.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.CreateFailed;
    return .{ fd, path };
}

var swept_stale = false;

/// Folders a process that is gone wrote (`<pid>-<n>`; it quit before its
/// next send removed them): removed once, at this process's first send.
fn sweepStale(root: [:0]const u8) void {
    const d = std.c.opendir(root) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        const dash = std.mem.indexOfScalar(u8, name, '-') orelse continue;
        const pid = std.fmt.parseInt(std.c.pid_t, name[0..dash], 10) catch continue;
        _ = std.fmt.parseInt(u32, name[dash + 1 ..], 10) catch continue;
        // Alive (or not ours to signal): left alone. This process has
        // made none yet: its pid's are an earlier process's.
        if (pid != std.c.getpid() and (std.c.kill(pid, @enumFromInt(0)) == 0 or std.c._errno().* == @intFromEnum(std.c.E.PERM))) continue;
        const dir = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ root, name }, 0) catch continue;
        defer gpa.free(dir);
        removeFolderFiles(dir);
        _ = std.c.rmdir(dir);
    }
}

/// Remove the files the last sends wrote (each folder holds one).
fn sweepTemp() void {
    for (temp_dirs.items) |dir| {
        removeFolderFiles(dir);
        _ = std.c.rmdir(dir);
        gpa.free(dir);
    }
    temp_dirs.clearRetainingCapacity();
}

fn removeFolderFiles(dir: [:0]const u8) void {
    const d = std.c.opendir(dir) orelse return;
    defer _ = std.c.closedir(d);
    while (std.c.readdir(d)) |ent| {
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&ent.name)), 0);
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const full = std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0) catch continue;
        defer gpa.free(full);
        _ = std.c.unlink(full);
    }
}

const ui = if (is_macos) Mac else Ios;

const Mac = struct {
    const NSRect = rt.NSRect;
    var delegate: Object = rt.nil;

    fn make(items: Object) ?Object {
        if (delegate.value == null) delegate = rt.new(rt.defineClass("OrielSharingPickerDelegate", &.{ "NSSharingServicePickerDelegate", "NSSharingServiceDelegate" }, .{
            .{ "sharingServicePicker:didChooseSharingService:", didChoose },
            .{ "sharingServicePicker:delegateForSharingService:", delegateFor },
            .{ "sharingService:didShareItems:", didShare },
            .{ "sharingService:didFailToShareItems:error:", didFail },
        }));
        const picker = rt.class("NSSharingServicePicker").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithItems:", .{items});
        if (picker.value == null) return null;
        picker.msgSend(void, "setDelegate:", .{delegate});
        return picker;
    }

    fn present(picker: Object, anchor: ?common.Rect) bool {
        const w = App.getWindow("main") orelse return false;
        const view = (Object{ .value = w.handle.window }).msgSend(Object, "contentView", .{});
        if (view.value == null) return false;
        const b = view.msgSend(NSRect, "bounds", .{});
        var r: NSRect = if (anchor) |a| .{ .origin = .{ .x = @floatFromInt(a.x), .y = @floatFromInt(a.y) }, .size = .{ .width = @floatFromInt(@max(1, a.width)), .height = @floatFromInt(@max(1, a.height)) } } else .{ .origin = .{ .x = b.size.width / 2, .y = b.size.height / 2 }, .size = .{ .width = 1, .height = 1 } };
        // The anchor is from the top; an unflipped view counts from the bottom.
        if (anchor != null and !rt.isTrue(view.msgSend(rt.c.BOOL, "isFlipped", .{}))) r.origin.y = b.size.height - r.origin.y - r.size.height;
        picker.msgSend(void, "showRelativeToRect:ofView:preferredEdge:", .{ r, view, @as(c_ulong, 1) }); // NSMinYEdge
        return true;
    }

    fn didChoose(_: rt.id, _: rt.c.SEL, _: rt.id, service: rt.id) callconv(.c) void {
        // Dismissed without a choice.
        if (service == null) return finish(false, null);
        // Its title is the Result's target once it shares.
        const p = if (pending) |*pp| pp else return;
        p.chosen = true;
        if (p.target) |old| gpa.free(old);
        p.target = null;
        if (rt.utf8((Object{ .value = service }).msgSend(Object, "title", .{}))) |t| p.target = gpa.dupe(u8, t) catch null;
    }

    fn delegateFor(self: rt.id, _: rt.c.SEL, _: rt.id, _: rt.id) callconv(.c) rt.id {
        return self;
    }

    fn didShare(_: rt.id, _: rt.c.SEL, _: rt.id, _: rt.id) callconv(.c) void {
        finish(true, null);
    }

    fn didFail(_: rt.id, _: rt.c.SEL, _: rt.id, _: rt.id, _: rt.id) callconv(.c) void {
        finish(false, null);
    }
};

const Ios = struct {
    const CGRect = rt.CGRect;
    const window = @import("../../platform/ios/window.zig");

    fn make(items: Object) ?Object {
        const vc = rt.class("UIActivityViewController").msgSend(Object, "alloc", .{}).msgSend(Object, "initWithActivityItems:applicationActivities:", .{ items, rt.nil });
        if (vc.value == null) return null;
        vc.msgSend(void, "setCompletionWithItemsHandler:", .{rt.globalBlock(completed)});
        return vc;
    }

    fn present(vc: Object, anchor: ?common.Rect) bool {
        const front = window.frontController() orelse return false;
        // iPad: a popover, which needs a place (or UIKit raises).
        const pc = vc.msgSend(Object, "popoverPresentationController", .{});
        if (pc.value != null) {
            const view = front.msgSend(Object, "view", .{});
            const b = view.msgSend(CGRect, "bounds", .{});
            const r: CGRect = if (anchor) |a| .{ .origin = .{ .x = @floatFromInt(a.x), .y = @floatFromInt(a.y) }, .size = .{ .width = @floatFromInt(@max(1, a.width)), .height = @floatFromInt(@max(1, a.height)) } } else .{ .origin = .{ .x = b.size.width / 2, .y = b.size.height / 2 }, .size = .{ .width = 1, .height = 1 } };
            pc.msgSend(void, "setSourceView:", .{view});
            pc.msgSend(void, "setSourceRect:", .{r});
        }
        front.msgSend(void, "presentViewController:animated:completion:", .{ vc, rt.boolean(true), rt.nil });
        return true;
    }

    /// completionWithItemsHandler: (activityType, completed, returnedItems, error).
    fn completed(_: *anyopaque, activity: rt.id, done: rt.c.BOOL, _: rt.id, _: rt.id) callconv(.c) void {
        // A share extension the user closed: the sheet is still up.
        if (!rt.isTrue(done) and activity != null) return;
        const target = if (activity != null) rt.utf8(.{ .value = activity }) else null;
        finish(rt.isTrue(done), target);
    }
};

pub fn capabilities() common.Capabilities {
    return .{ .receive = .open_with, .send = .{ .supported = true, .files = true, .text = true, .url = true, .multiple = true } };
}

/// A received file, read-only: a new descriptor for the file `handle`
/// names (the caller closes it). InvalidHandle once released.
pub fn open(handle: u32) common.OpenError!std.Io.File {
    const e = received.info(handle) orelse return error.InvalidHandle;
    const fd = std.c.dup(e.fd);
    if (fd < 0) return error.InvalidHandle;
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

/// Let a share's files go: their descriptors close.
pub fn release(id: u32) void {
    const kv = shares.fetchRemove(id) orelse return;
    for (kv.value) |h| dropFile(h);
    gpa.free(kv.value);
}

pub fn check(alloc: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const detail = if (is_macos) "receive: Open with (document types); send: NSSharingServicePicker" else "receive: Open in (document types); send: UIActivityViewController";
    return .{ .module = "share", .ok = true, .detail = try alloc.dupe(u8, detail) };
}
