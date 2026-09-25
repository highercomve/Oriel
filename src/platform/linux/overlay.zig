//! Overlay windows on Linux (Milestone 10): transparency, always-on-top,
//! skip-taskbar, placement on the monitor's work area and click-through.
//!
//! - Wayland with gtk4-layer-shell (`-Dlayer_shell=true`, and a compositor
//!   supporting wlr-layer-shell: Hyprland, Sway, KDE, ...): windows that ask
//!   for `always_on_top`, `skip_taskbar` or a `placement` become layer
//!   surfaces (overlay layer, anchors + margins).
//! - X11: EWMH hints (_NET_WM_STATE_ABOVE, skip taskbar) and XMoveWindow,
//!   applied when the window maps. Xlib is looked up at runtime (GTK already
//!   loads it on X11), so nothing extra is linked.
//! - Wayland without layer-shell: those three options can't be honoured by a
//!   normal window; they're ignored (logged once).
//! Transparency and click-through (an empty input region) work everywhere.

const std = @import("std");
const gtk = @import("gtk");
const webkit = @import("webkit");
const glib = @import("glib");
const build_options = @import("build_options");
const App = @import("../../core/App.zig");

const log = std.log.scoped(.oriel);

// GDK / cairo / WebKit (in libraries GTK and WebKit already link).
const GdkRGBA = extern struct { red: f32, green: f32, blue: f32, alpha: f32 };
const GdkRectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
extern fn gtk_native_get_surface(native: *anyopaque) ?*anyopaque;
extern fn gdk_surface_set_input_region(surface: *anyopaque, region: ?*anyopaque) void;
extern fn gdk_surface_get_display(surface: *anyopaque) *anyopaque;
extern fn gdk_display_get_monitor_at_surface(display: *anyopaque, surface: *anyopaque) ?*anyopaque;
extern fn gdk_display_get_default() ?*anyopaque;
extern fn gdk_monitor_get_geometry(monitor: *anyopaque, geometry: *GdkRectangle) void;
extern fn cairo_region_create() ?*anyopaque;
extern fn cairo_region_destroy(region: *anyopaque) void;
extern fn webkit_web_view_set_background_color(view: *webkit.WebView, rgba: *const GdkRGBA) void;
extern fn gtk_widget_add_css_class(widget: *anyopaque, class: [*:0]const u8) void;
extern fn gtk_css_provider_new() *anyopaque;
extern fn gtk_css_provider_load_from_string(provider: *anyopaque, css: [*:0]const u8) void;
extern fn gtk_style_context_add_provider_for_display(display: *anyopaque, provider: *anyopaque, priority: c_uint) void;
extern fn gtk_widget_get_width(widget: *anyopaque) c_int;
extern fn gtk_widget_get_height(widget: *anyopaque) c_int;
extern fn gtk_widget_get_mapped(widget: *anyopaque) c_int;

// gtk4-layer-shell (linked with -Dlayer_shell).
const layer = if (build_options.layer_shell) struct {
    extern fn gtk_layer_is_supported() c_int;
    extern fn gtk_layer_init_for_window(window: *gtk.Window) void;
    extern fn gtk_layer_is_layer_window(window: *gtk.Window) c_int;
    extern fn gtk_layer_set_layer(window: *gtk.Window, layer: c_int) void;
    extern fn gtk_layer_set_namespace(window: *gtk.Window, name: [*:0]const u8) void;
    extern fn gtk_layer_set_anchor(window: *gtk.Window, edge: c_int, anchor: c_int) void;
    extern fn gtk_layer_set_margin(window: *gtk.Window, edge: c_int, margin: c_int) void;
    extern fn gtk_layer_set_keyboard_mode(window: *gtk.Window, mode: c_int) void;
} else struct {};
const edge_left = 0;
const edge_right = 1;
const edge_top = 2;
const edge_bottom = 3;
const layer_top = 2;
const layer_overlay = 3;
const keyboard_none = 0;
const keyboard_exclusive = 1;
const keyboard_on_demand = 2;

/// What an overlay window asked for, applied again whenever it maps (X11
/// forgets hints on unmap; placement is computed from the current size).
const State = struct {
    window: *gtk.Window,
    always_on_top: bool,
    skip_taskbar: bool,
    placement: ?App.Placement,
    click_through: bool = false,
    layer_surface: bool = false,
};

/// Main thread only (GTK).
var states: std.ArrayList(State) = .empty;

fn stateFor(window: *gtk.Window) ?*State {
    for (states.items) |*s| if (s.window == window) return s;
    return null;
}

fn isWayland() bool {
    const display = gdk_display_get_default() orelse return false;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(gobjectTypeName(display))));
    return std.mem.indexOf(u8, name, "Wayland") != null;
}

extern fn g_type_name_from_instance(instance: *anyopaque) ?[*:0]const u8;
fn gobjectTypeName(obj: *anyopaque) [*:0]const u8 {
    return g_type_name_from_instance(obj) orelse "";
}

var warned_wayland = false;

/// Called by createWindow before the window is presented.
pub fn setup(window: *gtk.Window, view: *webkit.WebView, options: App.WindowOptions, app_id: [:0]const u8) void {
    if (options.transparent) makeTransparent(window, view);

    const wants_overlay = options.always_on_top or options.skip_taskbar or options.placement != null;
    if (!wants_overlay) return;

    states.append(std.heap.smp_allocator, .{
        .window = window,
        .always_on_top = options.always_on_top,
        .skip_taskbar = options.skip_taskbar,
        .placement = options.placement,
    }) catch return;
    const st = &states.items[states.items.len - 1];

    if (comptime build_options.layer_shell) {
        if (layer.gtk_layer_is_supported() != 0) {
            layer.gtk_layer_init_for_window(window);
            layer.gtk_layer_set_namespace(window, app_id.ptr);
            layer.gtk_layer_set_layer(window, if (options.always_on_top) layer_overlay else layer_top);
            // A menu or dictation pill takes the keyboard while shown; captions don't.
            layer.gtk_layer_set_keyboard_mode(window, if (options.focus_on_show) keyboard_exclusive else keyboard_on_demand);
            st.layer_surface = true;
            applyLayerPlacement(window, options.placement orelse .{});
            return;
        }
    }
    if (isWayland()) {
        if (!warned_wayland) {
            warned_wayland = true;
            log.info("always_on_top/skip_taskbar/placement need layer-shell on Wayland (build Oriel with -Dlayer_shell=true); ignored", .{});
        }
        return;
    }
    _ = gtk.Widget.signals.map.connect(window.as(gtk.Widget), ?*anyopaque, &onMap, null, .{});
}

/// Forget a destroyed window.
pub fn forget(window: *gtk.Window) void {
    for (states.items, 0..) |s, i| if (s.window == window) {
        _ = states.swapRemove(i);
        return;
    };
}

var css_installed = false;

fn makeTransparent(window: *gtk.Window, view: *webkit.WebView) void {
    if (!css_installed) {
        if (gdk_display_get_default()) |display| {
            const provider = gtk_css_provider_new();
            gtk_css_provider_load_from_string(provider, "window.oriel-transparent, window.oriel-transparent > * { background: transparent; box-shadow: none; }");
            gtk_style_context_add_provider_for_display(display, provider, 800); // GTK_STYLE_PROVIDER_PRIORITY_USER
            css_installed = true;
        }
    }
    gtk_widget_add_css_class(window, "oriel-transparent");
    const clear: GdkRGBA = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
    webkit_web_view_set_background_color(view, &clear);
}

fn applyLayerPlacement(window: *gtk.Window, placement: App.Placement) void {
    if (comptime !build_options.layer_shell) return;
    const a = placement.anchor;
    const top = a == .top or a == .top_left or a == .top_right;
    const bottom = a == .bottom or a == .bottom_left or a == .bottom_right;
    const left = a == .left or a == .top_left or a == .bottom_left;
    const right = a == .right or a == .top_right or a == .bottom_right;
    const edges = [_]struct { edge: c_int, on: bool }{
        .{ .edge = edge_top, .on = top },
        .{ .edge = edge_bottom, .on = bottom },
        .{ .edge = edge_left, .on = left },
        .{ .edge = edge_right, .on = right },
    };
    for (edges) |e| {
        layer.gtk_layer_set_anchor(window, e.edge, @intFromBool(e.on));
        layer.gtk_layer_set_margin(window, e.edge, if (e.on) placement.margin else 0);
    }
}

fn onMap(widget: *gtk.Widget, _: ?*anyopaque) callconv(.c) void {
    const window: *gtk.Window = @ptrCast(widget);
    const st = stateFor(window) orelse return;
    const surface = gtk_native_get_surface(window) orelse return;
    const x11 = X11.get() orelse return;
    if (st.skip_taskbar) {
        if (x11.gdk_x11_surface_set_skip_taskbar_hint) |f| f(surface, 1);
        if (x11.gdk_x11_surface_set_skip_pager_hint) |f| f(surface, 1);
    }
    if (st.always_on_top) x11.setAbove(surface, true);
    if (st.placement) |p| placeX11(window, surface, p);
    if (st.click_through) applyClickThrough(window, true);
}

pub fn setWindowPlacement(handle: anytype, placement: App.Placement) void {
    const window: *gtk.Window = handle.gtk_window;
    if (stateFor(window)) |st| {
        st.placement = placement;
        if (st.layer_surface) return applyLayerPlacement(window, placement);
    }
    if (isWayland()) return;
    const surface = gtk_native_get_surface(window) orelse return;
    if (gtk_widget_get_mapped(window) == 0) return; // applied on map
    placeX11(window, surface, placement);
}

pub fn setWindowClickThrough(handle: anytype, enabled: bool) void {
    const window: *gtk.Window = handle.gtk_window;
    if (stateFor(window)) |st| st.click_through = enabled;
    applyClickThrough(window, enabled);
}

fn applyClickThrough(window: *gtk.Window, enabled: bool) void {
    const surface = gtk_native_get_surface(window) orelse return; // applied on map
    if (enabled) {
        const empty = cairo_region_create() orelse return;
        defer cairo_region_destroy(empty);
        gdk_surface_set_input_region(surface, empty);
    } else {
        gdk_surface_set_input_region(surface, null);
    }
}

pub fn setWindowAlwaysOnTop(handle: anytype, enabled: bool) void {
    const window: *gtk.Window = handle.gtk_window;
    if (stateFor(window)) |st| {
        st.always_on_top = enabled;
        if (st.layer_surface) {
            if (comptime build_options.layer_shell) layer.gtk_layer_set_layer(window, if (enabled) layer_overlay else layer_top);
            return;
        }
    }
    const surface = gtk_native_get_surface(window) orelse return;
    const x11 = X11.get() orelse return;
    x11.setAbove(surface, enabled);
}

pub fn getWindowWorkArea(handle: anytype) ?App.Rect {
    const window: *gtk.Window = handle.gtk_window;
    const surface = gtk_native_get_surface(window) orelse return null;
    const display = gdk_surface_get_display(surface);
    const monitor = gdk_display_get_monitor_at_surface(display, surface) orelse return null;
    var r: GdkRectangle = undefined;
    // X11 knows the work area (without panels); elsewhere the monitor geometry.
    if (X11.get()) |x11| if (x11.gdk_x11_monitor_get_workarea) |f| {
        f(monitor, &r);
        return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
    };
    gdk_monitor_get_geometry(monitor, &r);
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}

fn placeX11(window: *gtk.Window, surface: *anyopaque, placement: App.Placement) void {
    const x11 = X11.get() orelse return;
    const area = getWindowWorkArea(.{ .gtk_window = window }) orelse return;
    const o = placement.origin(area, gtk_widget_get_width(window), gtk_widget_get_height(window));
    x11.move(surface, o.x, o.y);
}

/// Xlib and GDK's X11 backend, resolved at runtime (present only on X11).
const X11 = struct {
    gdk_x11_surface_get_xid: *const fn (*anyopaque) callconv(.c) c_ulong,
    gdk_x11_display_get_xdisplay: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
    gdk_x11_surface_set_skip_taskbar_hint: ?*const fn (*anyopaque, c_int) callconv(.c) void,
    gdk_x11_surface_set_skip_pager_hint: ?*const fn (*anyopaque, c_int) callconv(.c) void,
    gdk_x11_monitor_get_workarea: ?*const fn (*anyopaque, *GdkRectangle) callconv(.c) void,
    XInternAtom: *const fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) c_ulong,
    XSendEvent: *const fn (?*anyopaque, c_ulong, c_int, c_long, *XClientMessageEvent) callconv(.c) c_int,
    XDefaultRootWindow: *const fn (?*anyopaque) callconv(.c) c_ulong,
    XMoveWindow: *const fn (?*anyopaque, c_ulong, c_int, c_int) callconv(.c) c_int,
    XFlush: *const fn (?*anyopaque) callconv(.c) c_int,

    const XClientMessageEvent = extern struct {
        type: c_int,
        serial: c_ulong = 0,
        send_event: c_int = 1,
        display: ?*anyopaque,
        window: c_ulong,
        message_type: c_ulong,
        format: c_int,
        data: [5]c_long,
    };

    var cached: ?X11 = null;
    var resolved = false;

    fn get() ?*const X11 {
        if (!resolved) {
            resolved = true;
            if (!isWayland()) cached = resolve();
        }
        return if (cached) |*c| c else null;
    }

    fn sym(comptime T: type, name: [:0]const u8) ?T {
        // RTLD_DEFAULT (glibc: NULL): libraries GTK already loaded.
        const p = std.c.dlsym(null, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    fn resolve() ?X11 {
        return .{
            .gdk_x11_surface_get_xid = sym(*const fn (*anyopaque) callconv(.c) c_ulong, "gdk_x11_surface_get_xid") orelse return null,
            .gdk_x11_display_get_xdisplay = sym(*const fn (*anyopaque) callconv(.c) ?*anyopaque, "gdk_x11_display_get_xdisplay") orelse return null,
            .gdk_x11_surface_set_skip_taskbar_hint = sym(*const fn (*anyopaque, c_int) callconv(.c) void, "gdk_x11_surface_set_skip_taskbar_hint"),
            .gdk_x11_surface_set_skip_pager_hint = sym(*const fn (*anyopaque, c_int) callconv(.c) void, "gdk_x11_surface_set_skip_pager_hint"),
            .gdk_x11_monitor_get_workarea = sym(*const fn (*anyopaque, *GdkRectangle) callconv(.c) void, "gdk_x11_monitor_get_workarea"),
            .XInternAtom = sym(*const fn (?*anyopaque, [*:0]const u8, c_int) callconv(.c) c_ulong, "XInternAtom") orelse return null,
            .XSendEvent = sym(*const fn (?*anyopaque, c_ulong, c_int, c_long, *XClientMessageEvent) callconv(.c) c_int, "XSendEvent") orelse return null,
            .XDefaultRootWindow = sym(*const fn (?*anyopaque) callconv(.c) c_ulong, "XDefaultRootWindow") orelse return null,
            .XMoveWindow = sym(*const fn (?*anyopaque, c_ulong, c_int, c_int) callconv(.c) c_int, "XMoveWindow") orelse return null,
            .XFlush = sym(*const fn (?*anyopaque) callconv(.c) c_int, "XFlush") orelse return null,
        };
    }

    fn xdisplay(self: *const X11, surface: *anyopaque) ?*anyopaque {
        return self.gdk_x11_display_get_xdisplay(gdk_surface_get_display(surface));
    }

    /// EWMH: ask the window manager to add/remove _NET_WM_STATE_ABOVE.
    fn setAbove(self: *const X11, surface: *anyopaque, above: bool) void {
        const dpy = self.xdisplay(surface) orelse return;
        var ev: XClientMessageEvent = .{
            .type = 33, // ClientMessage
            .display = dpy,
            .window = self.gdk_x11_surface_get_xid(surface),
            .message_type = self.XInternAtom(dpy, "_NET_WM_STATE", 0),
            .format = 32,
            .data = .{ @intFromBool(above), @intCast(self.XInternAtom(dpy, "_NET_WM_STATE_ABOVE", 0)), 0, 1, 0 },
        };
        const mask: c_long = (1 << 19) | (1 << 20); // SubstructureNotify | SubstructureRedirect
        _ = self.XSendEvent(dpy, self.XDefaultRootWindow(dpy), 0, mask, &ev);
        _ = self.XFlush(dpy);
    }

    fn move(self: *const X11, surface: *anyopaque, x: c_int, y: c_int) void {
        const dpy = self.xdisplay(surface) orelse return;
        _ = self.XMoveWindow(dpy, self.gdk_x11_surface_get_xid(surface), x, y);
        _ = self.XFlush(dpy);
    }
};
