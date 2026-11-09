//! Window screenshots for the dev agent (src/core/agent.zig). The visible
//! window is rendered by GTK itself: the window's content as a
//! GtkWidgetPaintable, drawn by the window's own GSK renderer into a
//! texture, so native views over the page (the video player, oriel.video)
//! are in the picture as they are on screen. A full-page shot (`full`) is
//! WebKitGTK's `webkit_web_view_get_snapshot` of the whole document: only
//! WebKit can draw what is scrolled out of view, and only the page. Neither
//! needs the compositor or a screen capture permission, and both work on a
//! hidden or covered window; GDK writes the texture as a PNG. Development
//! builds only.

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
extern fn gtk_window_get_child(window: *anyopaque) ?*anyopaque;
extern fn gtk_widget_get_width(widget: *anyopaque) c_int;
extern fn gtk_widget_get_height(widget: *anyopaque) c_int;
extern fn gtk_widget_get_scale_factor(widget: *anyopaque) c_int;
extern fn gtk_widget_get_mapped(widget: *anyopaque) c_int;
extern fn gtk_widget_paintable_new(widget: ?*anyopaque) *anyopaque;
extern fn gtk_native_get_renderer(native: *anyopaque) ?*anyopaque;
extern fn gtk_snapshot_new() *anyopaque;
extern fn gtk_snapshot_scale(snapshot: *anyopaque, x: f32, y: f32) void;
extern fn gtk_snapshot_free_to_node(snapshot: *anyopaque) ?*anyopaque;
extern fn gdk_paintable_snapshot(paintable: *anyopaque, snapshot: *anyopaque, width: f64, height: f64) void;
extern fn gsk_renderer_render_texture(renderer: *anyopaque, root: *anyopaque, viewport: ?*const anyopaque) ?*anyopaque;
extern fn gsk_render_node_unref(node: *anyopaque) void;
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
    var view: ?*anyopaque = null;
    var window: ?*anyopaque = null;
    for (internal.windows_list.items) |w| {
        if (!std.mem.eql(u8, w.label, t.label)) continue;
        if (w.handle.web_view) |v| view = @ptrCast(v);
        window = @ptrCast(w.handle.gtk_window);
        break;
    }
    internal.windows_mutex.unlock();
    // The visible window, native views included; the page alone if GTK
    // can't render it (not shown yet, no renderer).
    if (!t.full) if (window) |win| if (renderWindow(win)) |texture| {
        defer g_object_unref(texture);
        save(t, texture);
        t.destroy();
        return;
    };
    const v = view orelse {
        agent.complete(t.id, false, "\"the window has no web view\"");
        t.destroy();
        return;
    };
    webkit_web_view_get_snapshot(v, if (t.full) .full_document else .visible, snapshot_options_none, null, &done, t);
}

/// The window's content (the page and every native view over it) as GTK
/// draws it, at the window's scale; a texture of ours, or null. Main thread.
fn renderWindow(window: *anyopaque) ?*anyopaque {
    if (gtk_widget_get_mapped(window) == 0) return null;
    const content = gtk_window_get_child(window) orelse return null;
    const renderer = gtk_native_get_renderer(window) orelse return null;
    const width = gtk_widget_get_width(content);
    const height = gtk_widget_get_height(content);
    if (width <= 0 or height <= 0) return null;
    const scale: f32 = @floatFromInt(@max(gtk_widget_get_scale_factor(window), 1));
    const paintable = gtk_widget_paintable_new(content);
    defer g_object_unref(paintable);
    const snapshot = gtk_snapshot_new();
    gtk_snapshot_scale(snapshot, scale, scale);
    gdk_paintable_snapshot(paintable, snapshot, @floatFromInt(width), @floatFromInt(height));
    const node = gtk_snapshot_free_to_node(snapshot) orelse return null;
    defer gsk_render_node_unref(node);
    return gsk_renderer_render_texture(renderer, node, null);
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
    save(t, texture);
}

/// Write `texture` to the task's path and answer the agent.
fn save(t: *Task, texture: *anyopaque) void {
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
