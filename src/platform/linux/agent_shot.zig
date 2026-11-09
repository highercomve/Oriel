//! Window screenshots for the dev agent (src/core/agent.zig), WebKitGTK:
//! `webkit_web_view_get_snapshot` renders the page itself (no compositor,
//! no screen capture permission, works on a hidden or covered window),
//! then GDK writes the texture as a PNG. Development builds only.

const std = @import("std");
const heap = @import("../../core/heap.zig");
const internal = @import("../../core/internal.zig");
const platform = @import("../platform.zig");
const agent = @import("../../core/agent.zig");

pub const supported = true;

const WebKitSnapshotRegion = enum(c_int) { visible = 0, full_document = 1 };
const snapshot_options_none: c_int = 0;

extern fn webkit_web_view_get_snapshot(
    view: *anyopaque,
    region: WebKitSnapshotRegion,
    options: c_int,
    cancellable: ?*anyopaque,
    callback: *const fn (source: ?*anyopaque, result: *anyopaque, user_data: ?*anyopaque) callconv(.c) void,
    user_data: ?*anyopaque,
) void;
extern fn webkit_web_view_get_snapshot_finish(view: *anyopaque, result: *anyopaque, err: *?*GError) ?*anyopaque;
extern fn gdk_texture_save_to_png(texture: *anyopaque, filename: [*:0]const u8) c_int;
extern fn gdk_texture_get_width(texture: *anyopaque) c_int;
extern fn gdk_texture_get_height(texture: *anyopaque) c_int;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_error_free(err: *GError) void;

const GError = extern struct { domain: u32, code: c_int, message: [*:0]const u8 };

const Task = struct {
    id: u32,
    label: [:0]u8,
    path: [:0]u8,
    full: bool,

    fn destroy(t: *Task) void {
        heap.gpa.free(t.label);
        heap.gpa.free(t.path);
        heap.gpa.destroy(t);
    }
};

/// Snapshot window `label` into `path` (PNG); the answer goes to
/// `agent.complete(id, ...)`. Any thread: the work runs on the main thread.
pub fn take(id: u32, label: []const u8, path: [:0]const u8, full: bool) !void {
    const t = try heap.gpa.create(Task);
    errdefer heap.gpa.destroy(t);
    const label_z = try heap.gpa.dupeZ(u8, label);
    errdefer heap.gpa.free(label_z);
    const path_z = try heap.gpa.dupeZ(u8, path);
    t.* = .{ .id = id, .label = label_z, .path = path_z, .full = full };
    platform.dispatchWithCleanup(&start, t, &drop);
}

fn drop(p: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(p.?));
    agent.complete(t.id, false, "\"the app is shutting down\"");
    t.destroy();
}

fn start(p: ?*anyopaque) void {
    const t: *Task = @ptrCast(@alignCast(p.?));
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    const view: ?*anyopaque = for (internal.windows_list.items) |w| {
        if (std.mem.eql(u8, w.label, t.label)) break if (w.handle.web_view) |v| @ptrCast(v) else null;
    } else null;
    internal.windows_mutex.unlock();
    const v = view orelse {
        agent.complete(t.id, false, "\"the window has no web view\"");
        t.destroy();
        return;
    };
    webkit_web_view_get_snapshot(v, if (t.full) .full_document else .visible, snapshot_options_none, null, &done, t);
}

fn done(source: ?*anyopaque, result: *anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const t: *Task = @ptrCast(@alignCast(user_data.?));
    defer t.destroy();
    var err: ?*GError = null;
    const texture = webkit_web_view_get_snapshot_finish(source.?, result, &err) orelse {
        var buf: [512]u8 = undefined;
        const msg = if (err) |e| std.mem.span(e.message) else "WebKit returned no image";
        const json = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(msg, .{})}) catch "\"snapshot failed\"";
        if (err) |e| g_error_free(e);
        agent.complete(t.id, false, json);
        return;
    };
    defer g_object_unref(texture);
    if (gdk_texture_save_to_png(texture, t.path.ptr) == 0) {
        agent.complete(t.id, false, "\"could not write the PNG (does the path's directory exist?)\"");
        return;
    }
    var buf: [1200]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{f}", .{std.json.fmt(.{
        .path = t.path,
        .width = gdk_texture_get_width(texture),
        .height = gdk_texture_get_height(texture),
    }, .{})}) catch {
        agent.complete(t.id, false, "\"path too long\"");
        return;
    };
    agent.complete(t.id, true, json);
}
