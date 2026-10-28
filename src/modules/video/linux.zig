//! The video player on Linux: a GtkVideo (its own controls) on a
//! GtkMediaFile, which plays through GStreamer whatever its plugins decode,
//! from `http(s)://` (souphttpsrc, with Range: the media server's URLs) or
//! `file://`. It goes over the window's page as an overlay: each web view
//! window's content is a GtkOverlay when the module is built
//! (src/platform/linux/window.zig). GtkVideo's graphics offload (GTK 4.14+)
//! lets the compositor show the frames without copying them.
//!
//! Everything here runs on the GTK main thread; `play` and `close` get
//! there from any thread.

const std = @import("std");
const gtk = @import("gtk");
const glib = @import("glib");
const App = @import("../../core/App.zig");
const internal = @import("../../core/internal.zig");
const heap = @import("../../core/heap.zig");
const platform = @import("../../platform/platform.zig");
const common = @import("common.zig");

const log = std.log.scoped(.oriel);

const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };

extern fn g_file_new_for_uri(uri: [*:0]const u8) *anyopaque;
extern fn g_object_unref(object: *anyopaque) void;
extern fn g_signal_connect_data(instance: *anyopaque, signal: [*:0]const u8, handler: *const anyopaque, data: ?*anyopaque, destroy: ?*const anyopaque, flags: c_int) c_ulong;
extern fn g_signal_handler_disconnect(instance: *anyopaque, id: c_ulong) void;
extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;
extern fn gtk_media_file_new_for_file(file: *anyopaque) *anyopaque;
extern fn gtk_media_file_clear(file: *anyopaque) void;
extern fn gtk_media_stream_get_ended(stream: *anyopaque) c_int;
extern fn gtk_media_stream_get_error(stream: *anyopaque) ?*const GError;
extern fn gtk_media_stream_get_playing(stream: *anyopaque) c_int;
extern fn gtk_media_stream_set_playing(stream: *anyopaque, playing: c_int) void;
extern fn gtk_video_new() *anyopaque;
extern fn gtk_video_set_autoplay(video: *anyopaque, autoplay: c_int) void;
extern fn gtk_video_set_media_stream(video: *anyopaque, stream: ?*anyopaque) void;
extern fn gtk_overlay_new() *anyopaque;
extern fn gtk_overlay_set_child(overlay: *anyopaque, child: ?*anyopaque) void;
extern fn gtk_overlay_get_child(overlay: *anyopaque) ?*anyopaque;
extern fn gtk_overlay_add_overlay(overlay: *anyopaque, widget: *anyopaque) void;
extern fn gtk_overlay_remove_overlay(overlay: *anyopaque, widget: *anyopaque) void;
extern fn gtk_overlay_get_type() usize;
extern fn gtk_window_get_child(window: *gtk.Window) ?*anyopaque;
extern fn gtk_window_is_active(window: *gtk.Window) c_int;
extern fn gtk_button_new_from_icon_name(icon: [*:0]const u8) *anyopaque;
extern fn gtk_label_new(text: ?[*:0]const u8) *anyopaque;
extern fn gtk_label_set_ellipsize(label: *anyopaque, mode: c_int) void;
extern fn gtk_widget_set_halign(widget: *anyopaque, a: c_int) void;
extern fn gtk_widget_set_valign(widget: *anyopaque, a: c_int) void;
extern fn gtk_widget_set_hexpand(widget: *anyopaque, expand: c_int) void;
extern fn gtk_widget_set_vexpand(widget: *anyopaque, expand: c_int) void;
extern fn gtk_widget_set_margin_top(widget: *anyopaque, margin: c_int) void;
extern fn gtk_widget_set_margin_start(widget: *anyopaque, margin: c_int) void;
extern fn gtk_widget_set_margin_end(widget: *anyopaque, margin: c_int) void;
extern fn gtk_widget_set_tooltip_text(widget: *anyopaque, text: ?[*:0]const u8) void;
extern fn gtk_widget_add_css_class(widget: *anyopaque, class: [*:0]const u8) void;
extern fn gtk_widget_grab_focus(widget: *anyopaque) c_int;
extern fn gtk_widget_get_display(widget: *anyopaque) *anyopaque;
extern fn gtk_widget_add_controller(widget: *anyopaque, controller: *anyopaque) void;
extern fn gtk_widget_remove_controller(widget: *anyopaque, controller: *anyopaque) void;
extern fn gtk_event_controller_key_new() *anyopaque;
extern fn gtk_event_controller_set_propagation_phase(controller: *anyopaque, phase: c_int) void;
extern fn gtk_css_provider_new() *anyopaque;
extern fn gtk_css_provider_load_from_string(provider: *anyopaque, css: [*:0]const u8) void;
extern fn gtk_style_context_add_provider_for_display(display: *anyopaque, provider: *anyopaque, priority: c_uint) void;

const align_start = 1;
const align_end = 2;
const phase_capture = 1;
const ellipsize_end = 3;
const key_escape = 0xff1b;
const key_space = 0x020;
/// GTK_STYLE_PROVIDER_PRIORITY_APPLICATION.
const css_priority = 600;
const css =
    \\.oriel-video { background-color: black; }
    \\.oriel-video-title { padding: 6px 12px; border-radius: 9px; }
;

/// The player showing, if any (main thread).
const Player = struct {
    window: *gtk.Window,
    /// The window's GtkOverlay (its content), which holds `root` over the page.
    overlay: *anyopaque,
    /// The player's own GtkOverlay: the video, the title and the close button.
    root: *anyopaque,
    /// The GtkMediaFile (a reference of ours; the GtkVideo holds another).
    stream: *anyopaque,
    /// Esc and Space, on the window (capture phase: before the page).
    keys: *anyopaque,
    ended_id: c_ulong,
    error_id: c_ulong,
    destroy_id: c_ulong,
};

var current: ?Player = null;
/// Bumped by each teardown: a queued close for an earlier player is a no-op.
var generation: u32 = 0;
var css_display: ?*anyopaque = null;

pub fn play(window: ?*App.Window, options: common.Options) common.Error!void {
    _ = try common.validate(options, common.linux_rules);
    // Prepared before the main thread changes anything.
    const gpa = heap.gpa;
    const url = try gpa.dupeZ(u8, options.url);
    errdefer gpa.free(url);
    const title = try gpa.dupeZ(u8, options.title);
    defer gpa.free(title);
    const Ctx = struct {
        window: ?*App.Window,
        url: [:0]u8,
        title: [:0]const u8,
        result: common.Error!void = error.AppNotRunning,
        fn run(c: *@This()) void {
            c.result = show(c.window, c.url, c.title);
        }
    };
    var ctx: Ctx = .{ .window = window, .url = url, .title = title };
    try onMain(Ctx, &ctx, Ctx.run);
    try ctx.result; // on success the url belongs to common (adopt)
}

pub fn close() void {
    const Ctx = struct {
        fn run(_: *@This()) void {
            teardown(.close);
        }
    };
    var ctx: Ctx = .{};
    onMain(Ctx, &ctx, Ctx.run) catch {};
}

/// The window the player covers: `win`, else the focused one, else "main",
/// else the first.
fn pickWindow(win: ?*App.Window) ?*gtk.Window {
    if (win) |w| return w.handle.gtk_window;
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    var main: ?*gtk.Window = null;
    var first: ?*gtk.Window = null;
    for (internal.windows_list.items) |w| {
        const gw = w.handle.gtk_window;
        if (gtk_window_is_active(gw) != 0) return gw;
        if (main == null and std.mem.eql(u8, w.label, "main")) main = gw;
        if (first == null) first = gw;
    }
    return main orelse first;
}

/// Main thread. On success `url` belongs to common (the URL playing).
fn show(win: ?*App.Window, url: [:0]u8, title: [:0]const u8) common.Error!void {
    const window = pickWindow(win) orelse return error.NoWindow;
    // A web view window's content (window.zig wraps it while the module
    // is built); anything else has nowhere to put the player.
    const overlay = gtk_window_get_child(window) orelse return error.NoWindow;
    if (g_type_check_instance_is_a(overlay, gtk_overlay_get_type()) == 0) return error.NoWindow;

    // Nothing below fails: replace the player showing, if any.
    teardown(.replace);
    installCss(overlay);

    const file = g_file_new_for_uri(url.ptr);
    defer g_object_unref(file);
    const stream = gtk_media_file_new_for_file(file);

    const video = gtk_video_new();
    gtk_video_set_autoplay(video, 1);
    enableOffload(video);
    gtk_video_set_media_stream(video, stream);
    gtk_widget_set_hexpand(video, 1);
    gtk_widget_set_vexpand(video, 1);

    const root = gtk_overlay_new();
    gtk_widget_add_css_class(root, "oriel-video");
    gtk_overlay_set_child(root, video);
    if (title.len > 0) {
        const label = gtk_label_new(title.ptr);
        gtk_label_set_ellipsize(label, ellipsize_end);
        gtk_widget_add_css_class(label, "osd");
        gtk_widget_add_css_class(label, "oriel-video-title");
        gtk_widget_set_halign(label, align_start);
        gtk_widget_set_valign(label, align_start);
        gtk_widget_set_margin_top(label, 12);
        gtk_widget_set_margin_start(label, 12);
        gtk_widget_set_margin_end(label, 64); // clear of the close button
        gtk_overlay_add_overlay(root, label);
    }
    const close_button = gtk_button_new_from_icon_name("window-close-symbolic");
    gtk_widget_add_css_class(close_button, "osd");
    gtk_widget_add_css_class(close_button, "circular");
    gtk_widget_set_halign(close_button, align_end);
    gtk_widget_set_valign(close_button, align_start);
    gtk_widget_set_margin_top(close_button, 12);
    gtk_widget_set_margin_end(close_button, 12);
    gtk_widget_set_tooltip_text(close_button, "Close (Esc)");
    _ = g_signal_connect_data(close_button, "clicked", @ptrCast(&onCloseClicked), null, null, 0);
    gtk_overlay_add_overlay(root, close_button);

    gtk_overlay_add_overlay(overlay, root);

    const keys = gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(keys, phase_capture);
    _ = g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKeyPressed), null, null, 0);
    gtk_widget_add_controller(@ptrCast(window), keys); // the window owns it

    current = .{
        .window = window,
        .overlay = overlay,
        .root = root,
        .stream = stream,
        .keys = keys,
        .ended_id = g_signal_connect_data(stream, "notify::ended", @ptrCast(&onEnded), null, null, 0),
        .error_id = g_signal_connect_data(stream, "notify::error", @ptrCast(&onError), null, null, 0),
        .destroy_id = g_signal_connect_data(root, "destroy", @ptrCast(&onRootDestroyed), null, null, 0),
    };
    common.adopt(url);
    // Keys reach the controls (Space, arrows) rather than the page.
    if (gtk_widget_grab_focus(video) == 0) _ = gtk_widget_grab_focus(close_button);
}

const Teardown = enum {
    /// Closed (button, Esc, `close`): the page shows again, `video:closed`.
    close,
    /// Another `play`: the new player replaces this one, no event.
    replace,
    /// The window went away with the player in it: `video:closed`.
    destroyed,
};

fn teardown(how: Teardown) void {
    const p = current orelse return;
    current = null;
    generation +%= 1;
    g_signal_handler_disconnect(p.stream, p.ended_id);
    g_signal_handler_disconnect(p.stream, p.error_id);
    g_signal_handler_disconnect(p.root, p.destroy_id);
    if (how != .destroyed) {
        gtk_widget_remove_controller(@ptrCast(p.window), p.keys);
        gtk_overlay_remove_overlay(p.overlay, p.root);
    }
    // Stops GStreamer now, not whenever the last reference goes.
    gtk_media_file_clear(p.stream);
    g_object_unref(p.stream);
    if (how == .close) if (gtk_overlay_get_child(p.overlay)) |page| {
        _ = gtk_widget_grab_focus(page);
    };
    if (how != .replace) common.closed();
}

/// GtkVideo's graphics offload (GTK 4.14+, looked up: older GTKs run the
/// app too): frames go to the compositor as they are, where it can.
fn enableOffload(video: *anyopaque) void {
    const Fn = *const fn (*anyopaque, c_int) callconv(.c) void;
    const sym = std.c.dlsym(null, "gtk_video_set_graphics_offload") orelse return;
    const set: Fn = @ptrCast(@alignCast(sym));
    set(video, 0); // GTK_GRAPHICS_OFFLOAD_ENABLED
}

fn installCss(widget: *anyopaque) void {
    const display = gtk_widget_get_display(widget);
    if (css_display == display) return;
    const provider = gtk_css_provider_new();
    gtk_css_provider_load_from_string(provider, css);
    gtk_style_context_add_provider_for_display(display, provider, css_priority);
    g_object_unref(provider); // the display keeps it
    css_display = display;
}

fn onEnded(stream: *anyopaque, _: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (gtk_media_stream_get_ended(stream) != 0) common.ended();
}

fn onError(stream: *anyopaque, _: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const err = gtk_media_stream_get_error(stream) orelse return;
    const message: []const u8 = if (err.message) |m| std.mem.span(m) else "playback failed";
    log.warn("video: {s}", .{message});
    common.failed(message);
}

fn onRootDestroyed(root: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    const p = current orelse return;
    if (p.root == root) teardown(.destroyed);
}

fn onCloseClicked(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
    closeLater();
}

fn onKeyPressed(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    const p = current orelse return 0;
    // Shift, Lock and the mouse buttons aside, no modifiers.
    const modifiers: c_uint = state & ~@as(c_uint, 1 | 2 | (0x1f << 8));
    if (modifiers != 0) return 0;
    switch (keyval) {
        key_escape => {
            closeLater();
            return 1;
        },
        key_space => {
            gtk_media_stream_set_playing(p.stream, @intFromBool(gtk_media_stream_get_playing(p.stream) == 0));
            return 1;
        },
        else => return 0,
    }
}

/// Close from inside the player's own signals (the button's click, the
/// controller's key): after they return, not while they run.
fn closeLater() void {
    const Gen = struct {
        fn run(data: ?*anyopaque) callconv(.c) c_int {
            const gen: u32 = @intCast(@intFromPtr(data) - 1);
            if (gen == generation) teardown(.close);
            return 0; // G_SOURCE_REMOVE
        }
    };
    _ = glib.idleAdd(&Gen.run, @ptrFromInt(@as(usize, generation) + 1));
}

/// One-shot event for one waiter.
const Event = struct {
    mutex: std.c.pthread_mutex_t = .{},
    cond: std.c.pthread_cond_t = .{},
    set: bool = false,

    fn signal(self: *Event) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        self.set = true;
        _ = std.c.pthread_cond_broadcast(&self.cond);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    fn wait(self: *Event) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        while (!self.set) _ = std.c.pthread_cond_wait(&self.cond, &self.mutex);
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }
};

/// `func(ctx)` on the GTK main thread, waiting for it: at once there.
fn onMain(comptime Ctx: type, ctx: *Ctx, comptime func: fn (*Ctx) void) error{AppNotRunning}!void {
    if (internal.gtk_app == null) return error.AppNotRunning;
    if (glib.MainContext.default().isOwner() != 0) {
        func(ctx);
        return;
    }
    const Call = struct {
        ctx: *Ctx,
        done: Event = .{},
        ran: bool = false,
        fn run(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            func(self.ctx);
            self.ran = true;
            self.done.signal();
        }
        fn cleanup(p: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(p.?));
            self.done.signal();
        }
    };
    var c: Call = .{ .ctx = ctx };
    platform.dispatchWithCleanup(&Call.run, &c, &Call.cleanup);
    c.done.wait();
    if (!c.ran) return error.AppNotRunning;
}

test "play before the app runs" {
    try std.testing.expectError(error.InvalidUrl, play(null, .{ .url = "javascript:x" }));
    try std.testing.expectError(error.AppNotRunning, play(null, .{ .url = "file:///tmp/a.mp4" }));
    close();
}
