//! Overlay windows on Linux (Milestone 10): transparency, always-on-top,
//! skip-taskbar, placement on the monitor's work area and click-through.
//!
//! - Wayland with gtk4-layer-shell (`-Dlayer_shell=true`, the library
//!   installed — it's loaded at runtime, see `preloadLayerShell` — and a compositor
//!   supporting wlr-layer-shell: Hyprland, Sway, KDE, ...): windows that ask
//!   for `always_on_top`, `skip_taskbar` or a `placement` become layer
//!   surfaces (overlay layer, anchors + margins).
//! - X11: EWMH hints (_NET_WM_STATE_ABOVE, skip taskbar) and XMoveWindow,
//!   applied when the window maps. Xlib is looked up at runtime (GTK already
//!   loads it on X11), so nothing extra is linked.
//! - Wayland without layer-shell: those three options can't be honoured by a
//!   normal window; they're ignored (logged once).
//! Transparency and click-through (an empty input region) work everywhere.
//! Dragging (`startWindowDrag`): the compositor / window manager moves a
//! normal window; a layer surface, which no compositor moves, follows the
//! pointer here by shifting its placement (its margins).

const std = @import("std");
const gtk = @import("gtk");
const glib = @import("glib");
const build_options = @import("build_options");
/// -Dnative_ui links no WebKitGTK (no_webkit.zig names the null web view).
const webkit = if (build_options.native_ui) @import("no_webkit.zig") else @import("webkit");
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
extern fn gtk_window_get_default_size(window: *anyopaque, width: *c_int, height: *c_int) void;
extern fn gdk_display_get_default_seat(display: *anyopaque) ?*anyopaque;
extern fn gdk_seat_get_pointer(seat: *anyopaque) ?*anyopaque;
extern fn gdk_surface_get_device_position(surface: *anyopaque, device: *anyopaque, x: *f64, y: *f64, mask: ?*c_uint) c_int;
extern fn gdk_toplevel_begin_move(toplevel: *anyopaque, device: *anyopaque, button: c_int, x: f64, y: f64, timestamp: u32) void;
extern fn gdk_event_get_event_type(event: *anyopaque) c_int;
extern fn gdk_event_get_position(event: *anyopaque, x: *f64, y: *f64) c_int;
extern fn gdk_event_get_modifier_state(event: *anyopaque) c_uint;
extern fn gtk_event_controller_legacy_new() *anyopaque;
extern fn gtk_event_controller_set_propagation_phase(controller: *anyopaque, phase: c_int) void;
extern fn gtk_widget_add_controller(widget: *anyopaque, controller: *anyopaque) void;
extern fn g_signal_connect_data(instance: *anyopaque, signal: [*:0]const u8, handler: *const anyopaque, data: ?*anyopaque, destroy: ?*const anyopaque, flags: c_int) c_ulong;
const gdk_motion_notify = 1;
const gdk_button_release = 3;
const gdk_button1_mask: c_uint = 1 << 8;
const gtk_phase_capture = 1;

/// gtk4-layer-shell, when the system has it (-Dlayer_shell; not linked:
/// Ubuntu 24.04, for one, doesn't package it). It must be loaded before
/// libwayland-client (it replaces some of its functions), which GTK loads at
/// startup, so `preloadLayerShell` restarts the app once with it in
/// LD_PRELOAD; its functions are then found here.
const Layer = struct {
    is_supported: *const fn () callconv(.c) c_int,
    init_for_window: *const fn (*gtk.Window) callconv(.c) void,
    set_layer: *const fn (*gtk.Window, c_int) callconv(.c) void,
    set_namespace: *const fn (*gtk.Window, [*:0]const u8) callconv(.c) void,
    set_anchor: *const fn (*gtk.Window, c_int, c_int) callconv(.c) void,
    set_margin: *const fn (*gtk.Window, c_int, c_int) callconv(.c) void,
    set_keyboard_mode: *const fn (*gtk.Window, c_int) callconv(.c) void,

    var cached: ?Layer = null;
    var resolved = false;

    /// The library's functions, or null when it isn't loaded. Main thread.
    fn get() ?*const Layer {
        if (comptime !build_options.layer_shell) return null;
        if (!resolved) {
            resolved = true;
            cached = resolve();
        }
        return if (cached) |*l| l else null;
    }

    fn sym(comptime T: type, name: [:0]const u8) ?T {
        const p = std.c.dlsym(null, name) orelse return null;
        return @ptrCast(@alignCast(p));
    }

    fn resolve() ?Layer {
        return .{
            .is_supported = sym(@FieldType(Layer, "is_supported"), "gtk_layer_is_supported") orelse return null,
            .init_for_window = sym(@FieldType(Layer, "init_for_window"), "gtk_layer_init_for_window") orelse return null,
            .set_layer = sym(@FieldType(Layer, "set_layer"), "gtk_layer_set_layer") orelse return null,
            .set_namespace = sym(@FieldType(Layer, "set_namespace"), "gtk_layer_set_namespace") orelse return null,
            .set_anchor = sym(@FieldType(Layer, "set_anchor"), "gtk_layer_set_anchor") orelse return null,
            .set_margin = sym(@FieldType(Layer, "set_margin"), "gtk_layer_set_margin") orelse return null,
            .set_keyboard_mode = sym(@FieldType(Layer, "set_keyboard_mode"), "gtk_layer_set_keyboard_mode") orelse return null,
        };
    }
};

const layer_shell_lib = "libgtk4-layer-shell.so.0";
/// What `LD_PRELOAD` is renamed to once it has done its job (the same length:
/// renamed in place, see `retirePreload`).
const retired_preload = "ORIEL_LDPR";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// On Wayland with gtk4-layer-shell installed, restart the app once with the
/// library in LD_PRELOAD, before GTK starts (see `Layer`). In the restarted
/// process LD_PRELOAD is retired, so the app's own child processes (helpers,
/// xdg-open, ...) don't load the library. Returns when nothing needs doing,
/// the library is missing, or the restart failed: the app then runs without
/// layer surfaces. Call first thing, on the main thread.
pub fn preloadLayerShell() void {
    if (comptime !build_options.layer_shell) return;
    const loaded = std.c.dlsym(null, "gtk_layer_init_for_window") != null;
    if (std.c.getenv("LD_PRELOAD")) |v| {
        // Ours (the restarted process): done its job.
        if (loaded and std.mem.eql(u8, std.mem.span(v), layer_shell_lib)) retirePreload();
        return; // or the user's own: left alone
    }
    if (loaded) return; // linked in, or loaded some other way
    if (std.c.getenv("WAYLAND_DISPLAY") == null) return; // X11: no layer surfaces
    if (std.c.getenv("ORIEL_NO_LAYER_SHELL") != null) return;
    const probe = std.c.dlopen(layer_shell_lib, .{ .LAZY = true }) orelse {
        log.info("{s} not found: overlays can't be placed on Wayland", .{layer_shell_lib});
        return;
    };
    _ = std.c.dlclose(probe);

    var buf: [32 * 1024]u8 = undefined;
    var argv: [256:null]?[*:0]const u8 = undefined;
    const n = readCmdline(&buf, &argv) orelse return;
    argv[n] = null;
    // A new variable: glibc copies the environment array to add it, so the
    // block std.process.Init captured at startup is untouched.
    // The executable's real path, not /proc/self/exe: the process is named
    // after the file it runs ("exe" otherwise, for ps, pgrep and task managers).
    var exe_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const exe_len = std.c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (exe_len <= 0 or exe_len >= exe_buf.len) return;
    exe_buf[@intCast(exe_len)] = 0;
    if (setenv("LD_PRELOAD", layer_shell_lib, 1) != 0) return;
    _ = execv(&exe_buf, &argv);
    // Still here: the restart failed. Carry on without layer surfaces.
    _ = unsetenv("LD_PRELOAD");
    log.warn("could not restart with {s}; overlays can't be placed on Wayland", .{layer_shell_lib});
}

/// Rename `LD_PRELOAD` in place so child processes don't inherit it. Not
/// unsetenv: that shifts the entries of the environment array, which Zig's
/// std.process.Init also holds with its original length, and the next
/// std.process.spawn read a null entry (a crash). The same-length rename
/// changes only the entry's bytes, seen alike by libc and Zig.
fn retirePreload() void {
    const key = "LD_PRELOAD=";
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const s = std.mem.span(entry);
        if (!std.mem.startsWith(u8, s, key)) continue;
        comptime std.debug.assert(retired_preload.len == key.len - 1);
        @memcpy(entry[0..retired_preload.len], retired_preload);
    }
}

/// This process's arguments from /proc/self/cmdline, NUL-separated in
/// `buf`, pointed to from `argv`. Their count, or null.
fn readCmdline(buf: []u8, argv: [:null]?[*:0]const u8) ?usize {
    const fd = std.c.open("/proc/self/cmdline", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var len: usize = 0;
    while (len < buf.len - 1) {
        const r = std.c.read(fd, buf[len..].ptr, buf.len - 1 - len);
        if (r <= 0) break;
        len += @intCast(r);
    }
    if (len == 0 or len >= buf.len - 1) return null; // empty, or too long to trust
    if (buf[len - 1] != 0) {
        buf[len] = 0;
        len += 1;
    }
    var n: usize = 0;
    var start: usize = 0;
    for (buf[0..len], 0..) |c, i| {
        if (c != 0) continue;
        if (n == argv.len) return null;
        argv[n] = @ptrCast(buf[start..i :0].ptr);
        n += 1;
        start = i + 1;
    }
    return n;
}
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
    /// Layer surfaces: where the pointer grabbed the window (surface
    /// coordinates) while the user drags it.
    drag: ?struct { x: f64, y: f64 } = null,
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
pub fn setup(window: *gtk.Window, view: ?*webkit.WebView, options: App.WindowOptions, app_id: [:0]const u8) void {
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

    if (Layer.get()) |l| {
        if (l.is_supported() != 0) {
            l.init_for_window(window);
            l.set_namespace(window, app_id.ptr);
            l.set_layer(window, if (options.always_on_top) layer_overlay else layer_top);
            // A menu or dictation pill takes the keyboard while shown; captions don't.
            l.set_keyboard_mode(window, if (options.focus_on_show) keyboard_exclusive else keyboard_on_demand);
            st.layer_surface = true;
            applyLayerPlacement(window, options.placement orelse .{});
            // Sees the pointer before the webview does, for startWindowDrag.
            const ctrl = gtk_event_controller_legacy_new();
            gtk_event_controller_set_propagation_phase(ctrl, gtk_phase_capture);
            _ = g_signal_connect_data(ctrl, "event", @ptrCast(&onLayerEvent), window, null, 0);
            gtk_widget_add_controller(window, ctrl);
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

fn makeTransparent(window: *gtk.Window, view: ?*webkit.WebView) void {
    if (!css_installed) {
        if (gdk_display_get_default()) |display| {
            const provider = gtk_css_provider_new();
            gtk_css_provider_load_from_string(provider, "window.oriel-transparent, window.oriel-transparent > * { background: transparent; box-shadow: none; }");
            gtk_style_context_add_provider_for_display(display, provider, 800); // GTK_STYLE_PROVIDER_PRIORITY_USER
            css_installed = true;
        }
    }
    gtk_widget_add_css_class(window, "oriel-transparent");
    // A native window (-Dnative_ui) has no web view: its surface clears to
    // transparent itself (native_ui/gtk.zig, Surface.transparent).
    const v = view orelse return;
    const clear: GdkRGBA = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };
    webkit_web_view_set_background_color(v, &clear);
}

fn applyLayerPlacement(window: *gtk.Window, placement: App.Placement) void {
    const l = Layer.get() orelse return;
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
    const m = layerMargins(placement);
    const margins = [_]c_int{ m.top, m.bottom, m.left, m.right };
    for (edges, margins) |e, margin| {
        l.set_anchor(window, e.edge, @intFromBool(e.on));
        l.set_margin(window, e.edge, if (e.on) margin else 0);
    }
}

const Margins = struct { left: c_int, right: c_int, top: c_int, bottom: c_int };

/// Layer margins for `p`: its margin, shifted by its offset (x right, y down).
fn layerMargins(p: App.Placement) Margins {
    return .{
        .left = p.margin + p.offset_x,
        .right = p.margin - p.offset_x,
        .top = p.margin + p.offset_y,
        .bottom = p.margin - p.offset_y,
    };
}

const HEdge = enum { none, left, right };
const VEdge = enum { none, top, bottom };

fn hEdge(a: App.Placement.Anchor) HEdge {
    return switch (a) {
        .left, .top_left, .bottom_left => .left,
        .right, .top_right, .bottom_right => .right,
        else => .none,
    };
}

fn vEdge(a: App.Placement.Anchor) VEdge {
    return switch (a) {
        .top, .top_left, .top_right => .top,
        .bottom, .bottom_left, .bottom_right => .bottom,
        else => .none,
    };
}

fn anchorOf(h: HEdge, v: VEdge) App.Placement.Anchor {
    return switch (v) {
        .none => switch (h) {
            .none => .center,
            .left => .left,
            .right => .right,
        },
        .top => switch (h) {
            .none => .top,
            .left => .top_left,
            .right => .top_right,
        },
        .bottom => switch (h) {
            .none => .bottom,
            .left => .bottom_left,
            .right => .bottom_right,
        },
    };
}

/// `p` anchored on both axes, at the same spot: a layer surface centred on
/// an axis can't be shifted along it, so that axis gets its start edge.
fn anchoredForDrag(p: App.Placement, area: App.Rect, w: c_int, h: c_int) App.Placement {
    var q = p;
    var he = hEdge(p.anchor);
    var ve = vEdge(p.anchor);
    if (he == .none) {
        he = .left;
        q.offset_x = @divTrunc(area.width - w, 2) + p.offset_x - p.margin;
    }
    if (ve == .none) {
        ve = .top;
        q.offset_y = @divTrunc(area.height - h, 2) + p.offset_y - p.margin;
    }
    q.anchor = anchorOf(he, ve);
    return q;
}

/// `p` shifted by (dx, dy), kept inside `area` (for a `w`×`h` window).
fn dragged(p: App.Placement, dx: c_int, dy: c_int, area: App.Rect, w: c_int, h: c_int) App.Placement {
    var q = p;
    const max_x = @max(0, area.width - w);
    const max_y = @max(0, area.height - h);
    switch (hEdge(p.anchor)) {
        .left => q.offset_x = std.math.clamp(p.margin + p.offset_x + dx, 0, max_x) - p.margin,
        .right => q.offset_x = p.margin - std.math.clamp(p.margin - p.offset_x - dx, 0, max_x),
        .none => {},
    }
    switch (vEdge(p.anchor)) {
        .top => q.offset_y = std.math.clamp(p.margin + p.offset_y + dy, 0, max_y) - p.margin,
        .bottom => q.offset_y = p.margin - std.math.clamp(p.margin - p.offset_y - dy, 0, max_y),
        .none => {},
    }
    return q;
}

fn windowSize(window: *gtk.Window) struct { w: c_int, h: c_int } {
    var w = gtk_widget_get_width(window);
    var h = gtk_widget_get_height(window);
    if (w <= 0 or h <= 0) gtk_window_get_default_size(window, &w, &h);
    return .{ .w = w, .h = h };
}

/// Move `window` with the pointer while the primary button is down.
pub fn startWindowDrag(handle: anytype) App.DragMode {
    const window: *gtk.Window = handle.gtk_window;
    const surface = gtk_native_get_surface(window) orelse return .unsupported;
    const display = gdk_surface_get_display(surface);
    const seat = gdk_display_get_default_seat(display) orelse return .unsupported;
    const pointer = gdk_seat_get_pointer(seat) orelse return .unsupported;
    var x: f64 = 0;
    var y: f64 = 0;
    _ = gdk_surface_get_device_position(surface, pointer, &x, &y, null);

    const st = stateFor(window);
    if (st) |s| if (s.layer_surface) {
        const area = getWindowWorkArea(.{ .gtk_window = window }) orelse return .unsupported;
        const size = windowSize(window);
        s.placement = anchoredForDrag(s.placement orelse .{}, area, size.w, size.h);
        applyLayerPlacement(window, s.placement.?);
        s.drag = .{ .x = x, .y = y };
        return .placement;
    };
    // X11 or a normal Wayland window: the window manager moves it. It keeps
    // no placement, so showing it again leaves it where the user put it.
    if (st) |s| s.placement = null;
    gdk_toplevel_begin_move(surface, pointer, 1, x, y, 0);
    return .native;
}

/// Layer surfaces: follow the pointer while dragging (see startWindowDrag).
fn onLayerEvent(_: *anyopaque, event: *anyopaque, window: *gtk.Window) callconv(.c) c_int {
    const st = stateFor(window) orelse return 0;
    const grab = st.drag orelse return 0;
    switch (gdk_event_get_event_type(event)) {
        gdk_button_release => st.drag = null,
        gdk_motion_notify => {
            if (gdk_event_get_modifier_state(event) & gdk_button1_mask == 0) {
                st.drag = null; // the release went elsewhere
                return 0;
            }
            var x: f64 = 0;
            var y: f64 = 0;
            if (gdk_event_get_position(event, &x, &y) == 0) return 0;
            const dx: c_int = @intFromFloat(@round(x - grab.x));
            const dy: c_int = @intFromFloat(@round(y - grab.y));
            if (dx == 0 and dy == 0) return 1;
            const area = getWindowWorkArea(.{ .gtk_window = window }) orelse return 1;
            const size = windowSize(window);
            // The surface moves under the pointer, which then sits at the
            // grab point again: the next motion is the next step.
            st.placement = dragged(st.placement orelse .{}, dx, dy, area, size.w, size.h);
            applyLayerPlacement(window, st.placement.?);
            return 1; // the page doesn't see the drag
        },
        else => {},
    }
    return 0;
}

test "layer drag: a centred axis gets its start edge, moves stay on the monitor" {
    const area: App.Rect = .{ .x = 0, .y = 0, .width = 1000, .height = 800 };
    const p = anchoredForDrag(.{ .anchor = .bottom, .margin = 64 }, area, 200, 100);
    try std.testing.expectEqual(App.Placement.Anchor.bottom_left, p.anchor);
    // Same spot: x = 400 from the left; still 64 from the bottom.
    try std.testing.expectEqual(@as(c_int, 400), layerMargins(p).left);
    try std.testing.expectEqual(@as(c_int, 64), layerMargins(p).bottom);
    try std.testing.expectEqual(App.Rect{ .x = 400, .y = 636, .width = 200, .height = 100 }, rectOf(p, area));

    const up = dragged(p, -50, -30, area, 200, 100);
    try std.testing.expectEqual(@as(c_int, 350), layerMargins(up).left);
    try std.testing.expectEqual(@as(c_int, 94), layerMargins(up).bottom);
    try std.testing.expectEqual(App.Rect{ .x = 350, .y = 606, .width = 200, .height = 100 }, rectOf(up, area));

    const far = dragged(up, 5000, 5000, area, 200, 100);
    try std.testing.expectEqual(@as(c_int, 800), layerMargins(far).left);
    try std.testing.expectEqual(@as(c_int, 0), layerMargins(far).bottom);
}

fn rectOf(p: App.Placement, area: App.Rect) App.Rect {
    const o = p.origin(area, 200, 100);
    return .{ .x = o.x, .y = o.y, .width = 200, .height = 100 };
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
            if (Layer.get()) |l| l.set_layer(window, if (enabled) layer_overlay else layer_top);
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
    // At map time GTK may not have allocated the window yet (0x0): use its default size.
    var w = gtk_widget_get_width(window);
    var h = gtk_widget_get_height(window);
    if (w <= 0 or h <= 0) gtk_window_get_default_size(window, &w, &h);
    const o = placement.origin(area, w, h);
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
