//! oriel.share on macOS and iOS. Receiving: files the system opens with the
//! app (macOS Finder's "Open With" and drops on the Dock icon, through the
//! app delegate's application:openURLs:, from CFBundleDocumentTypes).
//! Not written yet: macOS Services, iOS document types, sending through
//! NSSharingServicePicker / UIActivityViewController.

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("../../oriel.zig");
const common = @import("common.zig");

const log = std.log.scoped(.share);
const gpa = std.heap.smp_allocator;
const received = &common.received;

/// Shares received and not released: id -> its files' handles. Main thread.
var shares: std.AutoHashMapUnmanaged(u32, []u32) = .empty;
var next_share: u32 = 1;

/// Files the system handed the app (absolute paths), as one share from
/// `source`, on the main thread. Each is opened in place, read-only;
/// those that can't be (gone, a folder) are left out.
pub fn receivePaths(paths: []const []const u8, source: common.Source) void {
    var files: std.ArrayList(common.File) = .empty;
    defer files.deinit(gpa);
    var handles: std.ArrayList(u32) = .empty;
    defer handles.deinit(gpa);
    for (paths) |path| {
        const f = keepFile(path) catch |e| {
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
        };
    }
    if (files.items.len == 0) return;
    const id = next_share;
    next_share +%= 1;
    if (next_share == 0) next_share = 1;
    // Out of memory: the share is dropped, its files closed.
    shares.ensureUnusedCapacity(gpa, 1) catch {
        for (files.items) |f| received.release(f.handle);
        return;
    };
    const owned = handles.toOwnedSlice(gpa) catch {
        for (files.items) |f| received.release(f.handle);
        return;
    };
    shares.putAssumeCapacity(id, owned);
    const r: common.Received = .{ .id = id, .source = source, .files = files.items };
    common.dispatch(&r);
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

pub fn send(item: common.Outgoing, anchor: ?common.Rect, done: ?common.DoneHandler) common.SendError!void {
    _ = .{ item, anchor, done };
    return error.Unsupported;
}

pub fn capabilities() common.Capabilities {
    return .{ .receive = if (builtin.os.tag == .macos) .open_with else null };
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
    for (kv.value) |h| received.release(h);
    gpa.free(kv.value);
}

pub fn check(alloc: std.mem.Allocator, _: oriel.CheckContext) !oriel.Check {
    const detail = if (builtin.os.tag == .macos) "receive: Open with (document types); send: not implemented yet" else "receive and send: not implemented yet";
    return .{ .module = "share", .ok = true, .detail = try alloc.dupe(u8, detail) };
}
