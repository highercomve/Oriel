//! The native renderer's GTK 4 backend (docs/native-renderer.md).
//!
//! Boxes, text (Pango) and icons (GskPath) are drawn with Cairo in one
//! drawing area; text fields, text areas and selects are real GTK widgets
//! placed over it by a GtkOverlay at their nodes' frames. Clicks, scrolling
//! and keys are hit-tested on the node tree and sent to the page.

const std = @import("std");
const gtk = @import("gtk");
const engine_mod = @import("engine.zig");
const prof = @import("prof.zig");
const text_measure_cache = @import("text_measure_cache.zig");
const tree_mod = @import("tree.zig");
const Engine = engine_mod.Engine;
const Node = tree_mod.Node;
const Rect = tree_mod.Rect;

const log = std.log.scoped(.native_ui);

// ---------------------------------------------------------------------------
// C APIs (GTK, Cairo, Pango, GLib): declared here, linked through GTK.

const Widget = gtk.Widget;
const cairo_t = opaque {};
const cairo_pattern_t = opaque {};
const PangoLayout = opaque {};
const PangoContext = opaque {};
const PangoAttrList = opaque {};
const PangoFontDescription = opaque {};
const PangoAttribute = extern struct { klass: ?*anyopaque, start_index: c_uint, end_index: c_uint };
const GskPath = opaque {};
const GdkRectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };
const GtkCssProvider = opaque {};

extern fn gtk_drawing_area_new() *Widget;
extern fn gtk_drawing_area_set_draw_func(area: *Widget, func: *const fn (*Widget, *cairo_t, c_int, c_int, ?*anyopaque) callconv(.c) void, data: ?*anyopaque, destroy: ?*anyopaque) void;
extern fn gtk_overlay_new() *Widget;
extern fn gtk_overlay_set_child(overlay: *Widget, child: *Widget) void;
extern fn gtk_overlay_add_overlay(overlay: *Widget, child: *Widget) void;
extern fn gtk_overlay_remove_overlay(overlay: *Widget, child: *Widget) void;
extern fn gtk_widget_queue_draw(w: *Widget) void;
extern fn gtk_widget_queue_allocate(w: *Widget) void;
extern fn gtk_widget_set_focusable(w: *Widget, focusable: c_int) void;
extern fn gtk_widget_grab_focus(w: *Widget) c_int;
extern fn gtk_widget_set_visible(w: *Widget, visible: c_int) void;
extern fn gtk_widget_set_sensitive(w: *Widget, sensitive: c_int) void;
extern fn gtk_widget_add_controller(w: *Widget, controller: *anyopaque) void;
extern fn gtk_widget_set_cursor_from_name(w: *Widget, name: ?[*:0]const u8) void;
extern fn gtk_widget_add_css_class(w: *Widget, class: [*:0]const u8) void;
extern fn gtk_widget_create_pango_layout(w: *Widget, text: ?[*:0]const u8) *PangoLayout;
extern fn gtk_widget_get_pango_context(w: *Widget) *PangoContext;
extern fn pango_context_get_serial(ctx: *PangoContext) c_uint;
extern fn pango_context_changed(ctx: *PangoContext) void;
extern fn gtk_init_check() c_int;
extern fn g_object_ref_sink(object: *anyopaque) *anyopaque;
extern fn gtk_widget_get_width(w: *Widget) c_int;
extern fn gtk_widget_get_height(w: *Widget) c_int;
extern fn gtk_widget_get_display(w: *Widget) *anyopaque;
extern fn gtk_widget_set_hexpand(w: *Widget, e: c_int) void;
extern fn gtk_widget_set_vexpand(w: *Widget, e: c_int) void;
extern fn gtk_entry_new() *Widget;
extern fn gtk_entry_set_has_frame(e: *Widget, f: c_int) void;
extern fn gtk_entry_set_placeholder_text(e: *Widget, t: [*:0]const u8) void;
extern fn gtk_text_buffer_get_char_count(buffer: *anyopaque) c_int;
extern fn gtk_entry_set_visibility(e: *Widget, v: c_int) void;
extern fn gtk_editable_set_text(e: *Widget, t: [*:0]const u8) void;
extern fn gtk_editable_get_text(e: *Widget) [*:0]const u8;
extern fn gtk_editable_set_width_chars(e: *Widget, n: c_int) void;
extern fn gtk_text_view_new() *Widget;
extern fn gtk_text_view_get_buffer(v: *Widget) *anyopaque;
extern fn gtk_text_view_set_wrap_mode(v: *Widget, mode: c_int) void;
extern fn gtk_text_view_set_accepts_tab(v: *Widget, a: c_int) void;
extern fn gtk_text_buffer_set_text(b: *anyopaque, t: [*]const u8, len: c_int) void;
extern fn gtk_text_buffer_get_start_iter(b: *anyopaque, it: *[80]u8) void;
extern fn gtk_text_buffer_get_end_iter(b: *anyopaque, it: *[80]u8) void;
extern fn gtk_text_buffer_get_text(b: *anyopaque, s: *[80]u8, e: *[80]u8, hidden: c_int) [*:0]u8;
extern fn gtk_drop_down_new_from_strings(strings: [*]const ?[*:0]const u8) *Widget;
extern fn gtk_drop_down_get_selected(d: *Widget) c_uint;
extern fn gtk_drop_down_set_selected(d: *Widget, pos: c_uint) void;
extern fn gtk_gesture_click_new() *anyopaque;
extern fn gtk_gesture_single_set_button(g: *anyopaque, button: c_uint) void;
extern fn gtk_gesture_single_get_current_button(g: *anyopaque) c_uint;
extern fn gtk_event_controller_get_current_event_state(c: *anyopaque) c_uint;
extern fn gtk_event_controller_scroll_new(flags: c_uint) *anyopaque;
extern fn gtk_event_controller_motion_new() *anyopaque;
extern fn gtk_event_controller_key_new() *anyopaque;
extern fn gtk_event_controller_set_propagation_phase(c: *anyopaque, phase: c_int) void;
extern fn gtk_css_provider_new() *GtkCssProvider;
extern fn gtk_css_provider_load_from_string(p: *GtkCssProvider, s: [*:0]const u8) void;
extern fn gtk_style_context_add_provider_for_display(display: *anyopaque, provider: *GtkCssProvider, priority: c_uint) void;
extern fn gtk_settings_get_default() ?*anyopaque;
extern fn gdk_keyval_name(keyval: c_uint) ?[*:0]const u8;
extern fn gdk_keyval_to_unicode(keyval: c_uint) u32;
extern fn g_signal_connect_data(instance: *anyopaque, signal: [*:0]const u8, handler: *const anyopaque, data: ?*anyopaque, destroy: ?*anyopaque, flags: c_int) c_ulong;
extern fn g_object_set_data(obj: *anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
extern fn g_object_get_data(obj: *anyopaque, key: [*:0]const u8) ?*anyopaque;
extern fn g_object_get(obj: *anyopaque, first: [*:0]const u8, ...) void;
extern fn g_object_unref(obj: *anyopaque) void;
extern fn g_free(p: ?*anyopaque) void;
extern fn g_timeout_add(ms: c_uint, func: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
extern fn g_getenv(name: [*:0]const u8) ?[*:0]const u8;

extern fn cairo_save(cr: *cairo_t) void;
extern fn cairo_restore(cr: *cairo_t) void;
extern fn cairo_new_path(cr: *cairo_t) void;
extern fn cairo_new_sub_path(cr: *cairo_t) void;
extern fn cairo_move_to(cr: *cairo_t, x: f64, y: f64) void;
extern fn cairo_line_to(cr: *cairo_t, x: f64, y: f64) void;
extern fn cairo_arc(cr: *cairo_t, xc: f64, yc: f64, r: f64, a1: f64, a2: f64) void;
extern fn cairo_close_path(cr: *cairo_t) void;
extern fn cairo_rectangle(cr: *cairo_t, x: f64, y: f64, w: f64, h: f64) void;
extern fn cairo_clip(cr: *cairo_t) void;
extern fn cairo_create(target: *anyopaque) ?*cairo_t;
extern fn cairo_destroy(cr: *cairo_t) void;
extern fn cairo_surface_set_device_scale(surface: *anyopaque, x: f64, y: f64) void;
extern fn gtk_widget_get_scale_factor(w: *Widget) c_int;
extern fn cairo_image_surface_create(format: c_int, w: c_int, h: c_int) ?*anyopaque;
extern fn cairo_image_surface_get_data(surface: *anyopaque) ?[*]u8;
extern fn cairo_image_surface_get_stride(surface: *anyopaque) c_int;
extern fn cairo_surface_flush(surface: *anyopaque) void;
extern fn cairo_surface_mark_dirty(surface: *anyopaque) void;
extern fn cairo_surface_destroy(surface: *anyopaque) void;
extern fn cairo_set_source_surface(cr: *cairo_t, surface: *anyopaque, x: f64, y: f64) void;
extern fn g_bytes_new(data: ?*const anyopaque, size: usize) *anyopaque;
extern fn g_bytes_unref(bytes: *anyopaque) void;
extern fn gdk_texture_new_from_bytes(bytes: *anyopaque, err: *?*anyopaque) ?*anyopaque;
extern fn gdk_texture_get_width(texture: *anyopaque) c_int;
extern fn gdk_texture_get_height(texture: *anyopaque) c_int;
extern fn gdk_texture_download(texture: *anyopaque, data: [*]u8, stride: usize) void;
extern fn g_error_free(err: *anyopaque) void;
/// glibc: return free heap pages to the system.
extern fn malloc_trim(pad: usize) c_int;
extern fn gdk_pixbuf_loader_new() *anyopaque;
extern fn gdk_pixbuf_loader_write(loader: *anyopaque, buf: [*]const u8, count: usize, err: *?*anyopaque) c_int;
extern fn gdk_pixbuf_loader_close(loader: *anyopaque, err: *?*anyopaque) c_int;
extern fn cairo_fill(cr: *cairo_t) void;
extern fn cairo_fill_preserve(cr: *cairo_t) void;
extern fn cairo_stroke(cr: *cairo_t) void;
extern fn cairo_stroke_preserve(cr: *cairo_t) void;
extern fn cairo_set_source_rgba(cr: *cairo_t, r: f64, g: f64, b: f64, a: f64) void;
extern fn cairo_set_operator(cr: *cairo_t, op: c_int) void;
const cairo_operator_clear: c_int = 0; // CAIRO_OPERATOR_CLEAR
const cairo_operator_over: c_int = 2; // CAIRO_OPERATOR_OVER
extern fn cairo_set_source(cr: *cairo_t, p: *cairo_pattern_t) void;
extern fn cairo_set_line_width(cr: *cairo_t, w: f64) void;
extern fn cairo_set_line_cap(cr: *cairo_t, cap: c_int) void;
extern fn cairo_set_line_join(cr: *cairo_t, join: c_int) void;
extern fn cairo_set_fill_rule(cr: *cairo_t, rule: c_int) void;
extern fn cairo_translate(cr: *cairo_t, x: f64, y: f64) void;
extern fn cairo_scale(cr: *cairo_t, x: f64, y: f64) void;
extern fn cairo_rotate(cr: *cairo_t, angle: f64) void;
extern fn cairo_curve_to(cr: *cairo_t, x1: f64, y1: f64, x2: f64, y2: f64, x3: f64, y3: f64) void;
const cairo_path_t = opaque {};
extern fn cairo_copy_path(cr: *cairo_t) *cairo_path_t;
extern fn cairo_append_path(cr: *cairo_t, path: *cairo_path_t) void;
extern fn cairo_path_destroy(path: *cairo_path_t) void;
const cairo_fill_rule_winding: c_int = 0;
const cairo_fill_rule_even_odd: c_int = 1;
extern fn cairo_push_group(cr: *cairo_t) void;
extern fn cairo_pop_group_to_source(cr: *cairo_t) void;
extern fn cairo_paint_with_alpha(cr: *cairo_t, a: f64) void;
extern fn cairo_paint(cr: *cairo_t) void;
extern fn cairo_pattern_create_linear(x0: f64, y0: f64, x1: f64, y1: f64) *cairo_pattern_t;
extern fn cairo_pattern_add_color_stop_rgba(p: *cairo_pattern_t, off: f64, r: f64, g: f64, b: f64, a: f64) void;
extern fn cairo_pattern_destroy(p: *cairo_pattern_t) void;
extern fn cairo_pattern_create_radial(cx0: f64, cy0: f64, r0: f64, cx1: f64, cy1: f64, r1: f64) *cairo_pattern_t;
extern fn cairo_pattern_set_matrix(p: *cairo_pattern_t, m: *const CairoMatrix) void;
const CairoMatrix = extern struct { xx: f64, yx: f64, xy: f64, yy: f64, x0: f64, y0: f64 };

extern fn pango_layout_set_text(l: *PangoLayout, t: [*]const u8, len: c_int) void;
extern fn pango_layout_set_attributes(l: *PangoLayout, attrs: ?*PangoAttrList) void;
extern fn pango_layout_set_width(l: *PangoLayout, w: c_int) void;
extern fn pango_layout_set_wrap(l: *PangoLayout, wrap: c_int) void;
extern fn pango_layout_set_alignment(l: *PangoLayout, a: c_int) void;
extern fn pango_layout_set_font_description(l: *PangoLayout, d: ?*const PangoFontDescription) void;
extern fn pango_attr_line_height_new_absolute(height: c_int) *PangoAttribute;
extern fn pango_layout_get_pixel_size(l: *PangoLayout, w: *c_int, h: *c_int) void;
extern fn pango_layout_get_baseline(l: *PangoLayout) c_int;
extern fn pango_cairo_show_layout(cr: *cairo_t, l: *PangoLayout) void;
extern fn pango_cairo_layout_path(cr: *cairo_t, l: *PangoLayout) void;
extern fn pango_font_description_from_string(s: [*:0]const u8) *PangoFontDescription;
extern fn pango_font_description_set_absolute_size(d: *PangoFontDescription, size: f64) void;
extern fn pango_font_description_set_weight(d: *PangoFontDescription, w: c_int) void;
extern fn pango_font_description_set_style(d: *PangoFontDescription, s: c_int) void;
extern fn pango_font_description_free(d: *PangoFontDescription) void;
extern fn pango_attr_list_new() *PangoAttrList;
extern fn pango_attr_list_unref(l: *PangoAttrList) void;
extern fn pango_attr_list_insert(l: *PangoAttrList, a: *PangoAttribute) void;
extern fn pango_attr_foreground_new(r: u16, g: u16, b: u16) *PangoAttribute;
extern fn pango_attr_foreground_alpha_new(a: u16) *PangoAttribute;
extern fn pango_attr_background_new(r: u16, g: u16, b: u16) *PangoAttribute;
extern fn pango_attr_background_alpha_new(a: u16) *PangoAttribute;
extern fn pango_attr_weight_new(w: c_int) *PangoAttribute;
extern fn pango_attr_style_new(s: c_int) *PangoAttribute;
extern fn pango_attr_size_new_absolute(size: c_int) *PangoAttribute;
extern fn pango_attr_family_new(family: [*:0]const u8) *PangoAttribute;
extern fn pango_attr_underline_new(u: c_int) *PangoAttribute;
extern fn pango_attr_letter_spacing_new(s: c_int) *PangoAttribute;

extern fn gsk_path_parse(s: [*:0]const u8) ?*GskPath;
extern fn gsk_path_to_cairo(p: *GskPath, cr: *cairo_t) void;
extern fn gsk_path_unref(p: *GskPath) void;

const PANGO_SCALE = 1024;

// ---------------------------------------------------------------------------

pub const Invoke = *const fn (ctx: ?*anyopaque, engine: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void;

/// A window's native page: the overlay that goes into the GtkWindow.
pub const Surface = struct {
    /// The window is transparent (WindowOptions.transparent): no white page
    /// under the content, so rounded corners and overlays show what's behind.
    transparent: bool = false,
    /// The tree's size after the last layout (laidOut trims after big drops).
    node_count: usize = 0,
    gpa: std.mem.Allocator,
    engine: *Engine = undefined,
    overlay: *Widget,
    area: *Widget,
    fields: std.AutoHashMap(i64, *Widget),
    /// Decoded <img> pictures, one per image node (a clipboard preview is a
    /// new data: URI each time: keyed by node, replaced when its src changes).
    images: std.AutoHashMap(i64, Image),
    /// Each canvas's bitmap, kept from frame to frame while its size holds.
    canvases: std.AutoHashMap(i64, CanvasBitmap),
    text_measurements: text_measure_cache.Cache = .{},
    text_context: ?*PangoContext = null,
    text_serial: c_uint = 0,
    text_epoch: u64 = 1,
    /// The text fonts ("Sans", "Monospace"), parsed once; each layout
    /// copies one after setting its size.
    sans: ?*PangoFontDescription = null,
    mono: ?*PangoFontDescription = null,
    css: *GtkCssProvider,
    css_text: std.ArrayList(u8) = .empty,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    pointer: [2]f32 = .{ 0, 0 },
    hovered: i64 = 0,
    updating: bool = false,
    dark: bool = false,

    pub fn widget(s: *Surface) *Widget {
        return s.overlay;
    }

    pub fn create(gpa: std.mem.Allocator, assets: []const engine_mod.Asset, platform_json: [:0]const u8, label: [:0]const u8, url: [:0]const u8, width: f32, height: f32, invoke_fn: Invoke, invoke_ctx: ?*anyopaque) !*Surface {
        const s = try gpa.create(Surface);
        errdefer gpa.destroy(s);
        const overlay = gtk_overlay_new();
        const area = gtk_drawing_area_new();
        gtk_widget_set_hexpand(area, 1);
        gtk_widget_set_vexpand(area, 1);
        gtk_widget_set_focusable(area, 1);
        gtk_overlay_set_child(overlay, area);
        s.* = .{
            .gpa = gpa,
            .overlay = overlay,
            .area = area,
            .fields = .init(gpa),
            .images = .init(gpa),
            .canvases = .init(gpa),
            .css = gtk_css_provider_new(),
            .invoke_fn = invoke_fn,
            .invoke_ctx = invoke_ctx,
            .dark = prefersDark(),
        };
        gtk_style_context_add_provider_for_display(gtk_widget_get_display(area), s.css, 800);
        s.engine = try Engine.create(gpa, .{
            .ctx = s,
            .measure = measure,
            .laid_out = laidOut,
            .removed = removed,
            .add_timer = addTimer,
            .invoke = invoke,
            .focus = focus,
            .props = propsChanged,
            .text = textChanged,
            .deinit = releaseTextMeasurements,
        }, assets, platform_json, label, url, width, height);
        s.engine.tree.reuse_text_layout = true;

        gtk_drawing_area_set_draw_func(area, draw, s, null);
        _ = g_signal_connect_data(@ptrCast(area), "resize", @ptrCast(&onResize), s, null, 0);
        _ = g_signal_connect_data(@ptrCast(overlay), "get-child-position", @ptrCast(&onChildPosition), s, null, 0);

        const click = gtk_gesture_click_new();
        gtk_gesture_single_set_button(click, 0);
        _ = g_signal_connect_data(click, "pressed", @ptrCast(&onPressed), s, null, 0);
        _ = g_signal_connect_data(click, "released", @ptrCast(&onReleased), s, null, 0);
        gtk_widget_add_controller(area, click);
        const scroll = gtk_event_controller_scroll_new(1); // vertical
        _ = g_signal_connect_data(scroll, "scroll", @ptrCast(&onScroll), s, null, 0);
        gtk_widget_add_controller(area, scroll);
        const motion = gtk_event_controller_motion_new();
        _ = g_signal_connect_data(motion, "motion", @ptrCast(&onMotion), s, null, 0);
        _ = g_signal_connect_data(motion, "leave", @ptrCast(&onLeave), s, null, 0);
        gtk_widget_add_controller(area, motion);
        const keys = gtk_event_controller_key_new();
        _ = g_signal_connect_data(keys, "key-pressed", @ptrCast(&onKey), s, null, 0);
        gtk_widget_add_controller(area, keys);

        s.engine.boot(s.dark, false);
        return s;
    }

    fn prefersDark() bool {
        if (g_getenv("ORIEL_COLOR_SCHEME")) |v| return std.mem.eql(u8, std.mem.span(v), "dark");
        const settings = gtk_settings_get_default() orelse return false;
        var dark: c_int = 0;
        g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, @as(?*anyopaque, null));
        return dark != 0;
    }
};

fn surfaceOf(p: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(p.?));
}

fn releaseTextMeasurements(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.text_measurements.deinit(s.gpa);
}

// ---------------------------------------------------------------------------
// Backend hooks

fn invoke(ctx: *anyopaque, engine: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
    const s = surfaceOf(ctx);
    s.invoke_fn(s.invoke_ctx, engine, call_id, cmd, args_json);
}

const TimerData = struct { engine: *Engine, id: u32 };

fn addTimer(_: *anyopaque, engine: *Engine, id: u32, ms: u32) void {
    const d = std.heap.smp_allocator.create(TimerData) catch return;
    d.* = .{ .engine = engine, .id = id };
    _ = g_timeout_add(ms, onTimer, d);
}

fn onTimer(p: ?*anyopaque) callconv(.c) c_int {
    const d: *TimerData = @ptrCast(@alignCast(p.?));
    const engine = d.engine;
    const id = d.id;
    std.heap.smp_allocator.destroy(d);
    engine.timerFired(id);
    return 0;
}

fn focus(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    if (s.fields.get(node.id)) |w| _ = gtk_widget_grab_focus(w);
}

/// New props: a text node's size is measured again.
fn propsChanged(ctx: *anyopaque, node: *Node, _: std.json.Value) void {
    textChanged(ctx, node);
}

fn textChanged(ctx: *anyopaque, node: *Node) void {
    _ = ctx;
    node.measured_text_size = null;
}

fn removed(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    if (s.fields.fetchRemove(node.id)) |kv| gtk_overlay_remove_overlay(s.overlay, kv.value);
    if (s.images.fetchRemove(node.id)) |kv| kv.value.deinit();
    if (s.canvases.fetchRemove(node.id)) |kv| cairo_surface_destroy(kv.value.surf);
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    prof.report("text cache {d} entries {d} key bytes, {d} capacity resets", .{ s.text_measurements.entries.count(), s.text_measurements.bytes, s.text_measurements.capacity_resets });
    // A render that removed many nodes (a page section rebuilt): give the
    // freed memory back to the system. glibc's malloc keeps it otherwise
    // (QuickJS and the tree both allocate there), so memory only grew.
    const count = s.engine.tree.nodes.count();
    if (s.node_count > count + 1000) _ = malloc_trim(0);
    s.node_count = count;
    syncFields(s);
    gtk_widget_queue_draw(s.area);
    gtk_widget_queue_allocate(s.overlay);
}

// ---------------------------------------------------------------------------
// Fields: native widgets for input, textarea and select

/// Whether a box with a background painted after `field` (later in the
/// tree's paint order, so not one of its ancestors) overlaps it: a sticky
/// footer over a field scrolled under it. The field is a widget above the
/// whole page and would show through, so it's hidden instead.
fn coveredLater(s: *Surface, field: *Node) bool {
    const root = s.engine.tree.root orelse return false;
    const Walk = struct {
        field: *Node,
        seen: bool = false,
        covered: bool = false,
        fn visit(w: *@This(), n: *Node) void {
            if (w.covered or n.props.vis == false) return;
            if (n == w.field) {
                w.seen = true;
                return;
            }
            if (w.seen and n.props.bg != null) {
                const r = n.clip.intersect(n.frame).intersect(w.field.frame);
                if (r.w > 1 and r.h > 1) {
                    w.covered = true;
                    return;
                }
            }
            for (n.kids.items) |k| w.visit(k);
        }
    };
    var w: Walk = .{ .field = field };
    w.visit(root);
    return w.covered;
}

fn syncFields(s: *Surface) void {
    var css_changed = false;
    var it = s.engine.tree.nodes.valueIterator();
    while (it.next()) |np| {
        const n = np.*;
        if (n.kind != .input and n.kind != .textarea and n.kind != .select) continue;
        const w = s.fields.get(n.id) orelse blk: {
            const w = makeField(s, n) catch continue;
            s.fields.put(n.id, w) catch continue;
            gtk_overlay_add_overlay(s.overlay, w);
            css_changed = true;
            break :blk w;
        };
        s.updating = true;
        defer s.updating = false;
        if (n.pending_value) |v| {
            n.pending_value = null;
            const z = s.gpa.dupeZ(u8, v) catch continue;
            defer s.gpa.free(z);
            switch (n.kind) {
                .input => gtk_editable_set_text(w, z.ptr),
                .textarea => gtk_text_buffer_set_text(gtk_text_view_get_buffer(w), z.ptr, @intCast(z.len)),
                .select => if (n.props.options) |opts| for (opts, 0..) |o, i| {
                    if (std.mem.eql(u8, o[0], v)) gtk_drop_down_set_selected(w, @intCast(i));
                },
                else => {},
            }
        }
        gtk_widget_set_sensitive(w, @intFromBool(!n.props.dis));
        // The page changes placeholders too ("Select text first…" → "Tell
        // GhostPen what to do…"); a text view's is drawn by paintPlaceholder.
        if (n.kind == .input) {
            const ph = s.gpa.dupeZ(u8, n.props.ph orelse "") catch continue;
            defer s.gpa.free(ph);
            gtk_entry_set_placeholder_text(w, ph.ptr);
        }
        // A field is a GTK widget over the page, not clipped by its scroll
        // container: shown only while it lies entirely inside the visible
        // area (else it was drawn over a sticky footer, half scrolled out).
        const shown = n.clip.intersect(n.frame);
        const visible = n.frame.w > 1 and n.frame.h > 1 and n.props.vis != false and
            shown.h >= n.frame.h - 1 and shown.w >= n.frame.w - 1 and
            !coveredLater(s, n);
        if (std.c.getenv("ORIEL_NUI_FIELDS") != null) log.info("field {d} {s}: frame {d:.0},{d:.0} {d:.0}x{d:.0} clip {d:.0},{d:.0} {d:.0}x{d:.0} visible {}", .{ n.id, @tagName(n.kind), n.frame.x, n.frame.y, n.frame.w, n.frame.h, n.clip.x, n.clip.y, n.clip.w, n.clip.h, visible });
        gtk_widget_set_visible(w, @intFromBool(visible));
        css_changed = true;
    }
    if (css_changed) updateCss(s);
}

fn makeField(s: *Surface, n: *Node) !*Widget {
    const w: *Widget = switch (n.kind) {
        .input => blk: {
            const e = gtk_entry_new();
            gtk_entry_set_has_frame(e, 0);
            gtk_editable_set_width_chars(e, 1);
            if (n.props.pw) gtk_entry_set_visibility(e, 0);
            if (n.props.ph) |ph| {
                const z = try s.gpa.dupeZ(u8, ph);
                defer s.gpa.free(z);
                gtk_entry_set_placeholder_text(e, z.ptr);
            }
            _ = g_signal_connect_data(@ptrCast(e), "changed", @ptrCast(&onEntryChanged), s, null, 0);
            _ = g_signal_connect_data(@ptrCast(e), "activate", @ptrCast(&onEntryActivate), s, null, 0);
            break :blk e;
        },
        .textarea => blk: {
            const v = gtk_text_view_new();
            gtk_text_view_set_wrap_mode(v, 3); // word-char
            gtk_text_view_set_accepts_tab(v, 0);
            _ = g_signal_connect_data(gtk_text_view_get_buffer(v), "changed", @ptrCast(&onBufferChanged), s, null, 0);
            g_object_set_data(gtk_text_view_get_buffer(v), "oriel-view", v);
            const keys = gtk_event_controller_key_new();
            gtk_event_controller_set_propagation_phase(keys, 1); // capture: before the text view
            _ = g_signal_connect_data(keys, "key-pressed", @ptrCast(&onFieldKey), s, null, 0);
            gtk_widget_add_controller(v, keys);
            break :blk v;
        },
        .select => blk: {
            var labels: std.ArrayList(?[*:0]const u8) = .empty;
            defer {
                for (labels.items) |l| if (l) |p| s.gpa.free(std.mem.span(p));
                labels.deinit(s.gpa);
            }
            if (n.props.options) |opts| for (opts) |o| try labels.append(s.gpa, (try s.gpa.dupeZ(u8, o[1])).ptr);
            try labels.append(s.gpa, null);
            const d = gtk_drop_down_new_from_strings(labels.items.ptr);
            _ = g_signal_connect_data(@ptrCast(d), "notify::selected", @ptrCast(&onSelected), s, null, 0);
            break :blk d;
        },
        else => unreachable,
    };
    g_object_set_data(@ptrCast(w), "oriel-node", @ptrFromInt(@as(usize, @intCast(n.id))));
    var buf: [32]u8 = undefined;
    const cls = try std.fmt.bufPrintSentinel(&buf, "nui-f{d}", .{n.id}, 0);
    gtk_widget_add_css_class(w, cls.ptr);
    gtk_widget_add_css_class(w, "nui-field");
    return w;
}

fn updateCss(s: *Surface) void {
    s.css_text.clearRetainingCapacity();
    const a = s.gpa;
    s.css_text.appendSlice(a,
        \\.nui-field, .nui-field text, .nui-field > text, textview.nui-field, textview.nui-field text,
        \\dropdown.nui-field > button, dropdown.nui-field > button:hover, dropdown.nui-field > button:checked {
        \\  background: none; border: none; box-shadow: none; outline: none; padding: 0; margin: 0; min-height: 0;
        \\}
        \\dropdown.nui-field > button { padding: 0 2px; }
        \\
    ) catch return;
    var it = s.fields.iterator();
    while (it.next()) |e| {
        const n = s.engine.tree.get(e.key_ptr.*) orelse continue;
        const c = n.props.col orelse tree_mod.Color{ 0, 0, 0, 1 };
        // The page's text color and size, on a dropdown's label and arrow too.
        s.css_text.print(a, ".nui-f{d}, .nui-f{d} text, .nui-f{d} label, .nui-f{d} arrow {{ color: rgba({d:.0},{d:.0},{d:.0},{d:.2}); font-size: {d:.1}px; caret-color: rgba({d:.0},{d:.0},{d:.0},1); }}\n", .{
            n.id, n.id, n.id, n.id, c[0], c[1], c[2], c[3], n.props.fz orelse 16, c[0], c[1], c[2],
        }) catch return;
    }
    s.css_text.append(a, 0) catch return;
    gtk_css_provider_load_from_string(s.css, @ptrCast(s.css_text.items.ptr));
}

fn nodeOfWidget(s: *Surface, w: *anyopaque) ?*Node {
    const id: i64 = @intCast(@intFromPtr(g_object_get_data(w, "oriel-node") orelse return null));
    return s.engine.tree.get(id);
}

fn sendValue(s: *Surface, n: *Node, kind: []const u8, text: []const u8) void {
    const json = std.json.Stringify.valueAlloc(s.gpa, text, .{}) catch return;
    defer s.gpa.free(json);
    _ = s.engine.event(n.id, kind, json);
}

fn onEntryChanged(e: *Widget, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    if (s.updating) return;
    const n = nodeOfWidget(s, e) orelse return;
    sendValue(s, n, "input", std.mem.span(gtk_editable_get_text(e)));
}

fn onEntryActivate(e: *Widget, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    const n = nodeOfWidget(s, e) orelse return;
    _ = s.engine.event(n.id, "key", "[\"Enter\",0]");
}

fn onBufferChanged(buffer: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    // The placeholder under an empty text view comes and goes with the text.
    gtk_widget_queue_draw(s.area);
    if (s.updating) return;
    const view = g_object_get_data(buffer, "oriel-view") orelse return;
    const n = nodeOfWidget(s, view) orelse return;
    var start: [80]u8 = undefined;
    var end: [80]u8 = undefined;
    gtk_text_buffer_get_start_iter(buffer, &start);
    gtk_text_buffer_get_end_iter(buffer, &end);
    const text = gtk_text_buffer_get_text(buffer, &start, &end, 0);
    defer g_free(text);
    sendValue(s, n, "input", std.mem.span(text));
}

fn onSelected(d: *Widget, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    if (s.updating) return;
    const n = nodeOfWidget(s, d) orelse return;
    const i = gtk_drop_down_get_selected(d);
    const opts = n.props.options orelse return;
    if (i >= opts.len) return;
    sendValue(s, n, "change", opts[i][0]);
}

fn onFieldKey(controller: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    const name = keyName(keyval) orelse return 0;
    // Only keys a page commonly handles in a text area: Enter and Escape.
    if (!std.mem.eql(u8, name, "Enter") and !std.mem.eql(u8, name, "Escape")) return 0;
    const view = gtkWidgetOfController(controller) orelse return 0;
    const n = nodeOfWidget(s, view) orelse return 0;
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d}]", .{ name, modFlags(state) }) catch return 0;
    return @intFromBool(s.engine.event(n.id, "key", json));
}

extern fn gtk_event_controller_get_widget(c: *anyopaque) ?*Widget;
fn gtkWidgetOfController(c: *anyopaque) ?*Widget {
    return gtk_event_controller_get_widget(c);
}

fn onChildPosition(_: *Widget, child: *Widget, alloc: *GdkRectangle, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    const n = nodeOfWidget(s, child) orelse return 0;
    const r = n.content();
    alloc.* = .{ .x = @intFromFloat(@round(r.x)), .y = @intFromFloat(@round(r.y)), .width = @max(1, @as(c_int, @intFromFloat(@round(r.w)))), .height = @max(1, @as(c_int, @intFromFloat(@round(r.h)))) };
    return 1;
}

// ---------------------------------------------------------------------------
// Input

fn modFlags(state: c_uint) u32 {
    var f: u32 = 0;
    if (state & 1 != 0) f |= 1; // shift
    if (state & 4 != 0) f |= 2; // control
    if (state & 8 != 0) f |= 4; // alt
    if (state & (1 << 28) != 0) f |= 8; // super/meta
    return f;
}

fn keyName(keyval: c_uint) ?[]const u8 {
    const name = std.mem.span(gdk_keyval_name(keyval) orelse return null);
    const map = .{
        .{ "Return", "Enter" },        .{ "KP_Enter", "Enter" },     .{ "Escape", "Escape" }, .{ "Tab", "Tab" },
        .{ "BackSpace", "Backspace" }, .{ "Delete", "Delete" },      .{ "Up", "ArrowUp" },    .{ "Down", "ArrowDown" },
        .{ "Left", "ArrowLeft" },      .{ "Right", "ArrowRight" },   .{ "Home", "Home" },     .{ "End", "End" },
        .{ "Page_Up", "PageUp" },      .{ "Page_Down", "PageDown" }, .{ "space", " " },
    };
    inline for (map) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
    if (name.len == 1) return name;
    return null;
}

fn onResize(_: *Widget, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    s.engine.resize(@floatFromInt(width), @floatFromInt(height), s.dark);
}

fn onPressed(gesture: *anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gesture;
    const s = surfaceOf(data);
    _ = gtk_widget_grab_focus(s.area);
    // :active while the button is down.
    if (s.engine.tree.hit(@floatCast(x), @floatCast(y))) |n| _ = s.engine.event(n.id, "press", "null");
}

fn onReleased(gesture: *anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    _ = s.engine.event(0, "release", "null");
    const n = s.engine.tree.hit(@floatCast(x), @floatCast(y)) orelse return;
    const button = gtk_gesture_single_get_current_button(gesture);
    if (button == 3) {
        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0}]", .{ x, y }) catch return;
        _ = s.engine.event(n.id, "contextmenu", json);
        return;
    }
    if (button != 1) return;
    if (disabledUp(n)) return;
    var buf: [16]u8 = undefined;
    const flags = std.fmt.bufPrint(&buf, "{d}", .{modFlags(gtk_event_controller_get_current_event_state(gesture))}) catch return;
    _ = s.engine.event(n.id, "click", flags);
}

fn disabledUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.dis) return true;
    return false;
}

fn clickableUp(start: *Node) bool {
    var n: ?*Node = start;
    while (n) |x| : (n = x.parent) if (x.props.click) return !x.props.dis;
    return false;
}

fn onScroll(_: *anyopaque, _: f64, dy: f64, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    const n = s.engine.tree.hit(s.pointer[0], s.pointer[1]);
    var target = s.engine.tree.scroller(n);
    while (target) |t| {
        if (s.engine.scrollBy(t, @as(f32, @floatCast(dy)) * 48)) return 1;
        target = s.engine.tree.scroller(t.parent);
    }
    return 0;
}

fn onLeave(_: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    if (s.hovered == 0) return;
    s.hovered = 0;
    _ = s.engine.event(0, "hover", "null");
}

fn onMotion(_: *anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    s.pointer = .{ @floatCast(x), @floatCast(y) };
    const n = s.engine.tree.hit(s.pointer[0], s.pointer[1]);
    gtk_widget_set_cursor_from_name(s.area, if (n != null and clickableUp(n.?)) "pointer" else null);
    // :hover: the page hears when the node under the pointer changes.
    const id: i64 = if (n) |node| node.id else 0;
    if (id != s.hovered) {
        s.hovered = id;
        _ = s.engine.event(id, "hover", "null");
    }
}

fn onKey(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    const name = keyName(keyval) orelse return 0;
    var buf: [64]u8 = undefined;
    const key = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return 0;
    defer s.gpa.free(key);
    const json = std.fmt.bufPrint(&buf, "[{s},{d}]", .{ key, modFlags(state) }) catch return 0;
    return @intFromBool(s.engine.event(0, "key", json));
}

// ---------------------------------------------------------------------------
// Text

fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const s = surfaceOf(ctx);
    const fz = n.props.fz orelse 16;
    switch (n.kind) {
        .text => {
            const context = gtk_widget_get_pango_context(s.area);
            const serial = pango_context_get_serial(context);
            if (s.text_context != context or s.text_serial != serial) {
                s.text_measurements.clear(s.gpa);
                s.text_epoch +%= 1;
                s.text_context = context;
                s.text_serial = serial;
            }
            // Its natural size; at a width it fits in, that's the answer.
            const nat = if (n.measured_text_size != null and n.text_measure_epoch == s.text_epoch) n.measured_text_size.? else blk: {
                const size = measuredText(s, n, std.math.inf(f32)) orelse return;
                n.measured_text_size = size;
                n.text_measure_epoch = s.text_epoch;
                break :blk size;
            };
            if (n.props.nowrap or max_width >= nat[0]) {
                out.* = nat;
                return;
            }
            out.* = measuredText(s, n, max_width) orelse return;
        },
        .image => {
            // Its natural size, scaled down to the width it may take.
            const img = imageOf(s, n) orelse return;
            if (img.w <= 0 or img.h <= 0) return;
            const k: f32 = if (!std.math.isInf(max_width) and max_width < img.w) max_width / img.w else 1;
            out.* = .{ img.w * k, img.h * k };
        },
        .input, .select => out.* = .{ if (std.math.isInf(max_width)) 150 else @min(max_width, 150), @round(fz * 1.45) },
        .textarea => out.* = .{ if (std.math.isInf(max_width)) 200 else max_width, @round(fz * 1.45 * 2) },
        else => out.* = .{ 0, 0 },
    }
}

fn measuredText(s: *Surface, n: *Node, width: f32) ?[2]f32 {
    const actual_width = if (n.props.nowrap or std.math.isInf(width)) std.math.inf(f32) else @max(1, width);
    var buf: [1024]u8 = undefined;
    const key = text_measure_cache.keyFor(&buf, &n.props, actual_width);
    if (key) |k| if (s.text_measurements.get(k)) |size| return size;
    const layout = textLayout(s, n, actual_width) orelse return null;
    defer g_object_unref(layout);
    var w: c_int = 0;
    var h: c_int = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    const size: [2]f32 = .{ @floatFromInt(w + 1), @floatFromInt(h) };
    if (key) |k| s.text_measurements.put(s.gpa, k, size) catch {};
    return size;
}

fn textLayout(s: *Surface, n: *Node, width: f32) ?*PangoLayout {
    const runs = n.props.runs orelse return null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.gpa);
    const attrs = pango_attr_list_new();
    defer pango_attr_list_unref(attrs);
    for (runs) |r| {
        const start: c_uint = @intCast(text.items.len);
        text.appendSlice(s.gpa, r.t) catch return null;
        const end: c_uint = @intCast(text.items.len);
        const add = struct {
            fn f(list: *PangoAttrList, a: *PangoAttribute, st: c_uint, en: c_uint) void {
                a.start_index = st;
                a.end_index = en;
                pango_attr_list_insert(list, a);
            }
        }.f;
        add(attrs, pango_attr_foreground_new(c16(r.c[0]), c16(r.c[1]), c16(r.c[2])), start, end);
        if (r.c[3] < 1) add(attrs, pango_attr_foreground_alpha_new(@intFromFloat(@max(0, @min(1, r.c[3])) * 65535)), start, end);
        add(attrs, pango_attr_size_new_absolute(@intFromFloat(r.sz * PANGO_SCALE)), start, end);
        add(attrs, pango_attr_weight_new(@intFromFloat(r.w)), start, end);
        if (r.i) add(attrs, pango_attr_style_new(2), start, end);
        if (r.mono) add(attrs, pango_attr_family_new("Monospace"), start, end);
        if (r.u) add(attrs, pango_attr_underline_new(1), start, end);
        if (r.bg) |bg| if (bg[3] > 0) {
            add(attrs, pango_attr_background_new(c16(bg[0]), c16(bg[1]), c16(bg[2])), start, end);
            if (bg[3] < 1) add(attrs, pango_attr_background_alpha_new(@intFromFloat(bg[3] * 65535)), start, end);
        };
    }
    if (n.props.ls) |ls| add0(attrs, pango_attr_letter_spacing_new(@intFromFloat(ls * PANGO_SCALE)));
    // CSS line-height: each line box is that tall and the glyphs sit in its
    // middle (half-leading above and below, negative when it's smaller than
    // the font, as `line-height: 1` on an icon glyph). Pango >= 1.50.
    if (n.props.lh) |lh| add0(attrs, pango_attr_line_height_new_absolute(@intFromFloat(lh * PANGO_SCALE)));
    const layout = gtk_widget_create_pango_layout(s.area, null);
    const font = if (n.props.mono) &s.mono else &s.sans;
    if (font.* == null) font.* = pango_font_description_from_string(if (n.props.mono) "Monospace" else "Sans");
    const desc = font.*.?;
    pango_font_description_set_absolute_size(desc, (n.props.fz orelse 16) * PANGO_SCALE);
    pango_layout_set_font_description(layout, desc);
    pango_layout_set_text(layout, text.items.ptr, @intCast(text.items.len));
    pango_layout_set_attributes(layout, attrs);
    if (n.props.nowrap or std.math.isInf(width)) {
        pango_layout_set_width(layout, -1);
    } else {
        pango_layout_set_width(layout, @intFromFloat(@max(1, width) * PANGO_SCALE));
        pango_layout_set_wrap(layout, 2); // word-char
    }
    if (n.props.ta) |ta| {
        if (std.mem.eql(u8, ta, "center")) pango_layout_set_alignment(layout, 1);
        if (std.mem.eql(u8, ta, "right")) pango_layout_set_alignment(layout, 2);
    }
    return layout;
}

fn add0(list: *PangoAttrList, a: *PangoAttribute) void {
    a.start_index = 0;
    a.end_index = std.math.maxInt(c_uint);
    pango_attr_list_insert(list, a);
}

fn c16(v: f32) u16 {
    return @intFromFloat(@max(0, @min(255, v)) * 257);
}

// ---------------------------------------------------------------------------
// Drawing

fn draw(_: *Widget, cr: *cairo_t, _: c_int, _: c_int, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    if (s.engine.tree.dirty) s.engine.tree.layout();
    const root = s.engine.tree.root orelse return;
    // Under the page: white, as in a browser (the root's background, if
    // any, is painted over it); nothing in a transparent window.
    if (s.transparent) {
        cairo_set_operator(cr, cairo_operator_clear);
        cairo_paint(cr);
        cairo_set_operator(cr, cairo_operator_over);
    } else {
        cairo_set_source_rgba(cr, 1, 1, 1, 1);
        cairo_paint(cr);
    }
    const t0 = prof.now();
    paint(s, cr, root);
    prof.report("draw {d:.2}", .{prof.now() - t0});
}

fn paint(s: *Surface, cr: *cairo_t, n: *Node) void {
    const p = n.props;
    if (p.vis == false) return;
    const f = n.frame;
    const visible = n.clip.intersect(.{ .x = f.x - 40, .y = f.y - 40, .w = f.w + 80, .h = f.h + 80 });
    if (visible.w <= 0 or visible.h <= 0) {
        // Off screen: its children may still be (absolute ones).
        if (n.kids.items.len == 0) return;
    }
    cairo_save(cr);
    defer cairo_restore(cr);
    cairo_rectangle(cr, n.clip.x, n.clip.y, n.clip.w, n.clip.h);
    cairo_clip(cr);
    // scale and rotate: around the box's center, for it and its children.
    const sc = p.sc orelse 1;
    const rot = p.rot orelse 0;
    if (sc != 1 or rot != 0) {
        const cx = f.x + f.w / 2;
        const cy = f.y + f.h / 2;
        cairo_translate(cr, cx, cy);
        if (rot != 0) cairo_rotate(cr, rot * std.math.pi / 180.0);
        if (sc != 1) cairo_scale(cr, sc, sc);
        cairo_translate(cr, -cx, -cy);
    }
    const alpha = p.op orelse 1;
    if (alpha < 1) cairo_push_group(cr);

    const r = n.radius();
    if (p.sh) |sh| shadow(cr, f, r, sh);
    if (p.bg) |bg| {
        // The color under the gradient (CSS layers).
        if (bg.color) |c| {
            roundRect(cr, f, r);
            setColor(cr, c);
            cairo_fill(cr);
        }
        if (bg.gradient) |g| {
            roundRect(cr, f, r);
            const pat = gradient(f, g);
            cairo_set_source(cr, pat);
            cairo_fill(cr);
            cairo_pattern_destroy(pat);
        }
    }
    if (p.bw) |bw| border(cr, f, r, bw, p.bc);
    switch (n.kind) {
        .text => paintText(s, cr, n),
        .icon => paintIcon(cr, n),
        .image => paintImage(s, cr, n),
        .textarea => paintPlaceholder(s, cr, n),
        .canvas => paintCanvas(s, cr, n),
        .view => if (n.props.ctl != null) paintControl(cr, n),
        else => {},
    }
    // CSS paint order: a sticky header over the rows scrolled under it.
    var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
    while (it.next()) |k| paint(s, cr, k);
    if (alpha < 1) {
        cairo_pop_group_to_source(cr);
        cairo_paint_with_alpha(cr, alpha);
    }
}

fn setColor(cr: *cairo_t, c: tree_mod.Color) void {
    cairo_set_source_rgba(cr, c[0] / 255, c[1] / 255, c[2] / 255, c[3]);
}

fn roundRect(cr: *cairo_t, f: Rect, r: [4]f32) void {
    const x: f64 = f.x;
    const y: f64 = f.y;
    const w: f64 = f.w;
    const h: f64 = f.h;
    const pi = std.math.pi;
    cairo_new_path(cr);
    if (r[0] == 0 and r[1] == 0 and r[2] == 0 and r[3] == 0) {
        cairo_rectangle(cr, x, y, w, h);
        return;
    }
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r[1], y + r[1], r[1], -pi / 2.0, 0);
    cairo_arc(cr, x + w - r[2], y + h - r[2], r[2], 0, pi / 2.0);
    cairo_arc(cr, x + r[3], y + h - r[3], r[3], pi / 2.0, pi);
    cairo_arc(cr, x + r[0], y + r[0], r[0], pi, 3 * pi / 2.0);
    cairo_close_path(cr);
}

fn gradient(f: Rect, g: tree_mod.Gradient) *cairo_pattern_t {
    if (g.radial) |rad| {
        // A unit circle at the origin, mapped onto the ellipse.
        const cx = f.x + boxLen(rad[0], f.w);
        const cy = f.y + boxLen(rad[1], f.h);
        const rx = @max(0.01, boxLen(rad[2], f.w));
        const ry = @max(0.01, boxLen(rad[3], f.h));
        const pat = cairo_pattern_create_radial(0, 0, 0, 0, 0, 1);
        cairo_pattern_set_matrix(pat, &.{ .xx = 1 / rx, .yx = 0, .xy = 0, .yy = 1 / ry, .x0 = -cx / rx, .y0 = -cy / ry });
        for (g.stops) |st| cairo_pattern_add_color_stop_rgba(pat, st[4], st[0] / 255, st[1] / 255, st[2] / 255, st[3]);
        return pat;
    }
    const a = g.angle * std.math.pi / 180.0;
    const dx = @sin(a);
    const dy = -@cos(a);
    const len = @abs(f.w * dx) + @abs(f.h * dy);
    const cx = f.x + f.w / 2;
    const cy = f.y + f.h / 2;
    const pat = cairo_pattern_create_linear(cx - dx * len / 2, cy - dy * len / 2, cx + dx * len / 2, cy + dy * len / 2);
    for (g.stops) |st| cairo_pattern_add_color_stop_rgba(pat, st[4], st[0] / 255, st[1] / 255, st[2] / 255, st[3]);
    return pat;
}

/// A gradient length: px, or "50%" of `total`.
fn boxLen(v: tree_mod.Dim, total: f32) f32 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |x| @floatCast(x),
        .string => |s| if (std.mem.endsWith(u8, s, "%")) (std.fmt.parseFloat(f32, s[0 .. s.len - 1]) catch 0) / 100 * total else 0,
        else => 0,
    };
}

fn border(cr: *cairo_t, f: Rect, r: [4]f32, bw: [4]f32, bc: ?[4]tree_mod.Color) void {
    const colors = bc orelse return;
    const uniform = bw[0] == bw[1] and bw[1] == bw[2] and bw[2] == bw[3];
    if (uniform and bw[0] > 0) {
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        var ri = r;
        for (&ri) |*x| x.* = @max(0, x.* - half);
        cairo_set_line_width(cr, bw[0]);
        const same = for (colors[1..]) |c| {
            if (!std.mem.eql(f32, &c, &colors[0])) break false;
        } else true;
        if (same) {
            roundRect(cr, inner, ri);
            setColor(cr, colors[0]);
            cairo_stroke(cr);
            return;
        }
        // Sides in different colors (a spinner: border-top-color on a grey
        // ring): the rounded border stroked once per side, clipped to that
        // side's wedge (its two corners and the box's center), so the
        // colors meet on the diagonals, as in CSS.
        const cx = f.x + f.w / 2;
        const cy = f.y + f.h / 2;
        const corners = [4][2]f32{ .{ f.x, f.y }, .{ f.x + f.w, f.y }, .{ f.x + f.w, f.y + f.h }, .{ f.x, f.y + f.h } };
        for (0..4) |i| {
            if (colors[i][3] <= 0) continue;
            const a0 = corners[i];
            const a1 = corners[(i + 1) % 4];
            cairo_save(cr);
            cairo_new_path(cr);
            cairo_move_to(cr, a0[0], a0[1]);
            cairo_line_to(cr, a1[0], a1[1]);
            cairo_line_to(cr, cx, cy);
            cairo_close_path(cr);
            cairo_clip(cr);
            roundRect(cr, inner, ri);
            setColor(cr, colors[i]);
            cairo_stroke(cr);
            cairo_restore(cr);
        }
        return;
    }
    // Per side (straight edges).
    const sides = [4]Rect{
        .{ .x = f.x, .y = f.y, .w = f.w, .h = bw[0] },
        .{ .x = f.x + f.w - bw[1], .y = f.y, .w = bw[1], .h = f.h },
        .{ .x = f.x, .y = f.y + f.h - bw[2], .w = f.w, .h = bw[2] },
        .{ .x = f.x, .y = f.y, .w = bw[3], .h = f.h },
    };
    for (sides, 0..) |sd, i| {
        if (bw[i] <= 0 or colors[i][3] <= 0) continue;
        cairo_new_path(cr);
        cairo_rectangle(cr, sd.x, sd.y, sd.w, sd.h);
        setColor(cr, colors[i]);
        cairo_fill(cr);
    }
}

fn shadow(cr: *cairo_t, f: Rect, r: [4]f32, sh: tree_mod.Shadow) void {
    // A soft shadow from stacked layers, from half the blur inside the box
    // to half outside: like CSS's blur, the box's edge gets half the color
    // and the shadow fades out over the blur distance.
    const steps: usize = 8;
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        const t: f32 = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(steps));
        const grow = sh.spread + sh.blur * (t - 0.5);
        const rect: Rect = .{ .x = f.x + sh.x - grow, .y = f.y + sh.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
        if (rect.w <= 0 or rect.h <= 0) continue;
        var rr = r;
        for (&rr) |*x| x.* = @max(0, x.* + grow);
        roundRect(cr, rect, rr);
        var c = sh.color;
        c[3] = sh.color[3] / @as(f32, @floatFromInt(steps));
        setColor(cr, c);
        cairo_fill(cr);
    }
}

fn paintText(s: *Surface, cr: *cairo_t, n: *Node) void {
    const c = n.content();
    const layout = textLayout(s, n, c.w + 1) orelse return;
    defer g_object_unref(layout);
    cairo_move_to(cr, c.x, c.y);
    pango_cairo_show_layout(cr, layout);
}

/// A default checkbox or radio: an outlined box/circle, filled with the accent
/// color (or a blue default) and a white mark when checked; dimmed disabled.
fn paintControl(cr: *cairo_t, n: *Node) void {
    const c = n.frame;
    const size = @min(c.w, c.h);
    if (size <= 0) return;
    const x = c.x + (c.w - size) / 2;
    const y = c.y + (c.h - size) / 2;
    const radio = std.mem.eql(u8, n.props.ctl.?, "radio");
    const acc = n.props.acc orelse tree_mod.Color{ 59, 108, 255, 1 };
    const alpha: f32 = if (n.props.dis) 0.45 else 1;
    cairo_save(cr);
    defer cairo_restore(cr);
    cairo_new_path(cr);
    if (radio) {
        cairo_arc(cr, x + size / 2, y + size / 2, size / 2 - 0.5, 0, 2 * std.math.pi);
    } else {
        roundRect(cr, .{ .x = x + 0.5, .y = y + 0.5, .w = size - 1, .h = size - 1 }, .{ 2.5, 2.5, 2.5, 2.5 });
    }
    if (n.props.on) {
        setColor(cr, .{ acc[0], acc[1], acc[2], acc[3] * alpha });
        cairo_fill(cr);
        setColor(cr, .{ 255, 255, 255, alpha });
        if (radio) {
            cairo_new_path(cr);
            cairo_arc(cr, x + size / 2, y + size / 2, size * 0.2, 0, 2 * std.math.pi);
            cairo_fill(cr);
        } else {
            cairo_set_line_width(cr, @max(1.5, size * 0.13));
            cairo_set_line_cap(cr, 1);
            cairo_set_line_join(cr, 1);
            cairo_move_to(cr, x + size * 0.25, y + size * 0.52);
            cairo_line_to(cr, x + size * 0.43, y + size * 0.7);
            cairo_line_to(cr, x + size * 0.76, y + size * 0.32);
            cairo_stroke(cr);
        }
    } else {
        setColor(cr, .{ 255, 255, 255, alpha });
        cairo_fill_preserve(cr);
        setColor(cr, .{ 118, 118, 118, alpha });
        cairo_set_line_width(cr, 1);
        cairo_stroke(cr);
    }
}

/// A <textarea>'s placeholder: GtkTextView has none, so it's drawn under the
/// (transparent) view while the buffer is empty, in the text color at half
/// strength, as a browser does.
fn paintPlaceholder(s: *Surface, cr: *cairo_t, n: *Node) void {
    const ph = n.props.ph orelse return;
    if (ph.len == 0) return;
    const w = s.fields.get(n.id) orelse return;
    if (gtk_text_buffer_get_char_count(gtk_text_view_get_buffer(w)) > 0) return;
    const c = n.content();
    const layout = gtk_widget_create_pango_layout(s.area, null);
    defer g_object_unref(layout);
    const desc = pango_font_description_from_string("Sans");
    defer pango_font_description_free(desc);
    pango_font_description_set_absolute_size(desc, (n.props.fz orelse 16) * PANGO_SCALE);
    pango_layout_set_font_description(layout, desc);
    pango_layout_set_text(layout, ph.ptr, @intCast(ph.len));
    pango_layout_set_width(layout, @intFromFloat(@max(1, c.w) * PANGO_SCALE));
    pango_layout_set_wrap(layout, 2);
    var col = n.props.col orelse tree_mod.Color{ 0, 0, 0, 1 };
    col[3] *= 0.5;
    setColor(cr, col);
    cairo_move_to(cr, c.x, c.y);
    pango_cairo_show_layout(cr, layout);
}

// ---------------------------------------------------------------------------
// <canvas>: the recorded program (src/native_ui/js/src/canvas.js) replayed
// into cairo. Every paint replays the whole program from the context's
// defaults; save/restore keeps the state on a stack here as in the page.

const CanvasBitmap = struct { surf: *anyopaque, w: c_int, h: c_int };

const CanvasState = struct {
    fill: tree_mod.CanvasPaint = .{ .color = .{ 0, 0, 0, 1 } },
    stroke: tree_mod.CanvasPaint = .{ .color = .{ 0, 0, 0, 1 } },
    lw: f32 = 1,
    cap: u2 = 0, // butt, round, square
    join: u2 = 0, // miter, round, bevel
    alpha: f32 = 1,
    font: tree_mod.CanvasFont = .{ .size = 10 },
    talign: u2 = 0, // left, center, right
    tbase: u3 = 0, // alphabetic, top, hanging, middle, bottom
    // A scale by 0: nothing drawn until the restore() that undoes it. Cairo
    // can't take that matrix (its error would end the whole program).
    singular: bool = false,
};

fn paintCanvas(s: *Surface, win_cr: *cairo_t, n: *Node) void {
    const cmds = n.canvas orelse return;
    const f = n.frame;
    if (f.w <= 0 or f.h <= 0) return;
    // The program draws into its own surface, then that is painted on the
    // page: cairo's errors are sticky (a scale(0), an infinite coordinate),
    // an unbalanced restore() would pop the window's own states, and a
    // clearRect must clear the canvas, not the page behind it. All of that
    // now stays in the canvas's surface.
    const sf: f64 = @floatFromInt(@max(1, gtk_widget_get_scale_factor(s.area)));
    const pw: c_int = @intFromFloat(@min(16384, @ceil(f.w * sf)));
    const ph: c_int = @intFromFloat(@min(16384, @ceil(f.h * sf)));
    if (pw <= 0 or ph <= 0) return;
    // The bitmap from the last frame when the size is the same (a game
    // loop redraws every frame), cleared; else a new one.
    var owned: ?*anyopaque = null; // not cached: destroyed after this frame
    defer if (owned) |o| cairo_surface_destroy(o);
    const img = blk: {
        if (s.canvases.get(n.id)) |b| if (b.w == pw and b.h == ph) break :blk b.surf;
        if (s.canvases.fetchRemove(n.id)) |kv| cairo_surface_destroy(kv.value.surf);
        const fresh = cairo_image_surface_create(0, pw, ph) orelse return;
        cairo_surface_set_device_scale(fresh, sf, sf);
        s.canvases.put(n.id, .{ .surf = fresh, .w = pw, .h = ph }) catch {
            owned = fresh;
        };
        break :blk fresh;
    };
    const cr = cairo_create(img) orelse return;
    cairo_set_operator(cr, cairo_operator_clear);
    cairo_paint(cr);
    cairo_set_operator(cr, cairo_operator_over);
    defer {
        cairo_destroy(cr);
        cairo_save(win_cr);
        // Clipped to the box's rounded corners, as a browser clips a
        // replaced element's content to its border-radius.
        roundRect(win_cr, f, n.radius());
        cairo_clip(win_cr);
        cairo_set_source_surface(win_cr, img, f.x, f.y);
        cairo_paint(win_cr);
        cairo_restore(win_cr);
    }
    // The drawing's coordinate space: the bitmap, scaled to the box (CSS
    // width/height stretch it, as in a browser).
    const cw = n.props.cw orelse f.w;
    const ch = n.props.ch orelse f.h;
    var st: CanvasState = .{};
    var states: std.ArrayList(CanvasState) = .empty;
    defer states.deinit(s.gpa);
    var grads: std.AutoHashMap(u16, *cairo_pattern_t) = .init(s.gpa);
    defer {
        var it = grads.valueIterator();
        while (it.next()) |p| cairo_pattern_destroy(p.*);
        grads.deinit();
    }
    // The surface is the element's box; the bitmap's space is scaled to it.
    if (cw > 0 and ch > 0) cairo_scale(cr, f.w / cw, f.h / ch);
    for (cmds) |cmd| {
        if (st.singular) switch (cmd) {
            .translate, .scale, .rotate, .begin_path, .close_path, .move_to, .line_to, .rect, .arc, .bezier_to, .fill, .stroke, .clip, .fill_rect, .stroke_rect, .clear_rect, .fill_text, .stroke_text => continue,
            else => {},
        };
        switch (cmd) {
            .save => {
                // Saved together or not at all, so restore stays balanced.
                states.append(s.gpa, st) catch continue;
                cairo_save(cr);
            },
            .restore => {
                // Only what this program saved: an extra restore() is ignored,
                // as in a browser (cairo would put the context in error).
                if (states.pop()) |prev| {
                    st = prev;
                    cairo_restore(cr);
                }
            },
            .translate => |t| cairo_translate(cr, t[0], t[1]),
            .scale => |t| if (t[0] == 0 or t[1] == 0) {
                st.singular = true;
            } else cairo_scale(cr, t[0], t[1]),
            .rotate => |a| cairo_rotate(cr, a),
            .begin_path => cairo_new_path(cr),
            .close_path => cairo_close_path(cr),
            .move_to => |p| cairo_move_to(cr, p[0], p[1]),
            .line_to => |p| cairo_line_to(cr, p[0], p[1]),
            .rect => |r| cairo_rectangle(cr, r[0], r[1], r[2], r[3]),
            .arc => |a| {
                // A sweep from a0 to a1: increasing angles (cairo, in the
                // y-down user space, draws a canvas's clockwise arc); the
                // other way round draws the same segment from a1 up to a0.
                var a1 = a.a1;
                const two_pi: f32 = 2.0 * std.math.pi;
                if (a.ccw) {
                    if (a1 > a.a0) a1 -= two_pi;
                    cairo_arc(cr, a.x, a.y, a.r, a1, a.a0);
                } else {
                    if (a1 < a.a0) a1 += two_pi;
                    cairo_arc(cr, a.x, a.y, a.r, a.a0, a1);
                }
            },
            .bezier_to => |b| cairo_curve_to(cr, b[0], b[1], b[2], b[3], b[4], b[5]),
            .fill => |even| {
                canvasSource(cr, st.fill, st.alpha, &grads);
                cairo_set_fill_rule(cr, if (even) cairo_fill_rule_even_odd else cairo_fill_rule_winding);
                cairo_fill_preserve(cr);
            },
            .stroke => {
                canvasSource(cr, st.stroke, st.alpha, &grads);
                cairo_set_line_width(cr, @max(0.1, st.lw));
                cairo_set_line_cap(cr, st.cap);
                cairo_set_line_join(cr, st.join);
                cairo_stroke_preserve(cr);
            },
            .clip => |even| {
                // cairo_clip eats the current path; a canvas keeps it.
                const p = cairo_copy_path(cr);
                cairo_set_fill_rule(cr, if (even) cairo_fill_rule_even_odd else cairo_fill_rule_winding);
                cairo_clip(cr);
                cairo_append_path(cr, p);
                cairo_path_destroy(p);
            },
            .fill_rect => |r| canvasRect(cr, r, st, &grads, .fill),
            .stroke_rect => |r| canvasRect(cr, r, st, &grads, .stroke),
            .clear_rect => |r| {
                // Out of the bitmap: to whatever's behind (the element's own
                // CSS background is under the program; a browser's would be
                // too, as its bitmap is transparent there).
                const p = cairo_copy_path(cr);
                cairo_new_path(cr);
                cairo_rectangle(cr, r[0], r[1], r[2], r[3]);
                cairo_set_operator(cr, cairo_operator_clear);
                cairo_fill(cr);
                cairo_set_operator(cr, cairo_operator_over);
                cairo_append_path(cr, p);
                cairo_path_destroy(p);
            },
            .fill_text => |t| canvasShowText(s, cr, t.t, t.x, t.y, st, false, &grads),
            .stroke_text => |t| canvasShowText(s, cr, t.t, t.x, t.y, st, true, &grads),
            .fill_style => |src| st.fill = src,
            .stroke_style => |src| st.stroke = src,
            .line_width => |w| st.lw = @max(0, w),
            .line_cap => |cap| st.cap = cap,
            .line_join => |join| st.join = join,
            .global_alpha => |a| st.alpha = a,
            .font => |fnt| st.font = fnt,
            .text_align => |a| st.talign = a,
            .text_baseline => |b| st.tbase = b,
            .linear_gradient => |g| canvasPattern(&grads, g.id, cairo_pattern_create_linear(g.x0, g.y0, g.x1, g.y1)),
            .radial_gradient => |g| canvasPattern(&grads, g.id, cairo_pattern_create_radial(g.x0, g.y0, @max(0.001, g.r0), g.x1, g.y1, @max(0.001, g.r1))),
            .color_stop => |c| if (grads.get(c.id)) |pat| {
                cairo_pattern_add_color_stop_rgba(pat, c.off, c.c[0] / 255, c.c[1] / 255, c.c[2] / 255, c.c[3]);
            },
        }
    }
}

/// fillRect / strokeRect: they draw their own path and leave the page's
/// one intact (cairo's fill and stroke would eat it).
fn canvasRect(cr: *cairo_t, r: [4]f32, st: CanvasState, grads: *std.AutoHashMap(u16, *cairo_pattern_t), comptime what: enum { fill, stroke }) void {
    const p = cairo_copy_path(cr);
    cairo_new_path(cr);
    cairo_rectangle(cr, r[0], r[1], r[2], r[3]);
    switch (what) {
        .fill => {
            canvasSource(cr, st.fill, st.alpha, grads);
            cairo_fill(cr);
        },
        .stroke => {
            canvasSource(cr, st.stroke, st.alpha, grads);
            cairo_set_line_width(cr, @max(0.1, st.lw));
            cairo_set_line_cap(cr, st.cap);
            cairo_set_line_join(cr, st.join);
            cairo_stroke(cr);
        },
    }
    cairo_append_path(cr, p);
    cairo_path_destroy(p);
}

/// The source: a color (with the global alpha in), or a gradient's pattern
/// (its stops already carry their alphas; the global alpha isn't applied).
fn canvasSource(cr: *cairo_t, src: tree_mod.CanvasPaint, alpha: f32, grads: *std.AutoHashMap(u16, *cairo_pattern_t)) void {
    switch (src) {
        .color => |c| setColor(cr, .{ c[0], c[1], c[2], c[3] * alpha }),
        .grad => |id| if (grads.get(id)) |pat| cairo_set_source(cr, pat),
    }
}

fn canvasPattern(grads: *std.AutoHashMap(u16, *cairo_pattern_t), id: u16, pat: *cairo_pattern_t) void {
    if (grads.fetchRemove(id)) |old| cairo_pattern_destroy(old.value);
    grads.put(id, pat) catch cairo_pattern_destroy(pat);
}

fn canvasShowText(s: *Surface, cr: *cairo_t, text: []const u8, x: f32, y: f32, st: CanvasState, stroke: bool, grads: *std.AutoHashMap(u16, *cairo_pattern_t)) void {
    // The font family: canvas's, or Pango's generic ones.
    var owned: ?[:0]u8 = null;
    defer if (owned) |o| s.gpa.free(o);
    const family = st.font.family;
    const name: [*:0]const u8 = if (family.len == 0 or std.ascii.endsWithIgnoreCase(family, "sans-serif"))
        "Sans"
    else if (std.ascii.endsWithIgnoreCase(family, "monospace"))
        "Monospace"
    else if (std.ascii.endsWithIgnoreCase(family, "serif"))
        "Serif"
    else blk: {
        const z = s.gpa.dupeZ(u8, family) catch return;
        owned = z;
        break :blk z.ptr;
    };
    const layout = gtk_widget_create_pango_layout(s.area, null);
    defer g_object_unref(layout);
    const desc = pango_font_description_from_string(name);
    defer pango_font_description_free(desc);
    pango_font_description_set_absolute_size(desc, st.font.size * PANGO_SCALE);
    pango_font_description_set_weight(desc, @intFromFloat(@min(900, @max(100, st.font.weight))));
    if (st.font.italic) pango_font_description_set_style(desc, 2); // italic
    pango_layout_set_font_description(layout, desc);
    pango_layout_set_text(layout, text.ptr, @intCast(text.len));
    pango_layout_set_width(layout, -1); // no wrap: canvas text draws one line
    var w: c_int = 0;
    var h: c_int = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);
    const baseline: f32 = @as(f32, @floatFromInt(pango_layout_get_baseline(layout))) / PANGO_SCALE;
    // The layout's top-left from the anchor (x, y).
    var px = x;
    var py = y;
    switch (st.talign) {
        1 => px -= fw / 2,
        2 => px -= fw,
        else => {},
    }
    switch (st.tbase) {
        1 => {}, // top
        3 => py -= fh / 2, // middle
        4 => py -= fh, // bottom
        else => py -= baseline, // alphabetic / hanging
    }
    if (stroke) {
        // The glyphs' outlines as a path of their own (the page's current
        // path stays out of it), stroked with the stroke style.
        const p = cairo_copy_path(cr);
        cairo_new_path(cr);
        cairo_move_to(cr, px, py);
        pango_cairo_layout_path(cr, layout);
        canvasSource(cr, st.stroke, st.alpha, grads);
        cairo_set_line_width(cr, @max(0.5, st.lw));
        cairo_set_line_join(cr, st.join);
        cairo_stroke(cr);
        cairo_append_path(cr, p);
        cairo_path_destroy(p);
    } else {
        canvasSource(cr, st.fill, st.alpha, grads);
        cairo_move_to(cr, px, py);
        pango_cairo_show_layout(cr, layout);
    }
}

const Image = struct {
    src_hash: u64,
    /// Cairo ARGB32 surface; null when the picture couldn't be decoded.
    surface: ?*anyopaque,
    w: f32,
    h: f32,

    fn deinit(img: Image) void {
        if (img.surface) |sf| cairo_surface_destroy(sf);
    }
};

/// The node's decoded picture (decoded on first use and when src changes).
fn imageOf(s: *Surface, n: *Node) ?Image {
    const src = n.props.src orelse return null;
    const hash = std.hash.Wyhash.hash(0, src);
    if (s.images.get(n.id)) |img| if (img.src_hash == hash) return img;
    if (s.images.fetchRemove(n.id)) |kv| kv.value.deinit();
    const img = decodeImage(s, src) catch |err| blk: {
        log.warn("native ui: image {s}: {s}", .{ src[0..@min(src.len, 48)], @errorName(err) });
        break :blk Image{ .src_hash = hash, .surface = null, .w = 0, .h = 0 };
    };
    var stored = img;
    stored.src_hash = hash;
    s.images.put(n.id, stored) catch {
        stored.deinit();
        return null;
    };
    return stored;
}

fn decodeImage(s: *Surface, src: []const u8) !Image {
    var owned: ?[]u8 = null;
    defer if (owned) |o| s.gpa.free(o);
    const bytes: []const u8 = if (std.mem.startsWith(u8, src, "data:")) blk: {
        const comma = std.mem.indexOfScalar(u8, src, ',') orelse return error.BadDataUri;
        if (std.mem.indexOf(u8, src[0..comma], ";base64") == null) return error.NotBase64;
        const b64 = std.mem.trim(u8, src[comma + 1 ..], " \t\r\n");
        const dec = std.base64.standard.Decoder;
        const buf = try s.gpa.alloc(u8, try dec.calcSizeForSlice(b64));
        owned = buf;
        try dec.decode(buf, b64);
        break :blk buf;
    } else s.engine.assetData(src) orelse return error.AssetNotFound;

    // The declared size first: a few header bytes are enough. A tiny file can
    // declare 30000x30000 px, and decoding it would allocate gigabytes (PNG
    // can't be decoded smaller: the loader's size hint scales afterwards).
    // Such a picture keeps its size for layout and isn't drawn.
    const declared = probeSize(bytes) orelse return error.UnknownFormat;
    if (@as(u64, @intCast(declared[0])) * @as(u64, @intCast(declared[1])) > max_image_pixels) {
        log.warn("native ui: image {d}x{d} px is over the {d}-pixel limit: not drawn", .{ declared[0], declared[1], max_image_pixels });
        return .{ .src_hash = 0, .surface = null, .w = @floatFromInt(declared[0]), .h = @floatFromInt(declared[1]) };
    }

    const gbytes = g_bytes_new(bytes.ptr, bytes.len); // copies
    defer g_bytes_unref(gbytes);
    var gerr: ?*anyopaque = null;
    const texture = gdk_texture_new_from_bytes(gbytes, &gerr) orelse {
        if (gerr) |e| g_error_free(e);
        return error.DecodeFailed;
    };
    defer g_object_unref(texture);
    const w = gdk_texture_get_width(texture);
    const h = gdk_texture_get_height(texture);
    if (w <= 0 or h <= 0) return error.EmptyImage;
    // CAIRO_FORMAT_ARGB32 is GDK_MEMORY_DEFAULT (premultiplied, native endian).
    const sf = cairo_image_surface_create(0, w, h) orelse return error.OutOfMemory;
    errdefer cairo_surface_destroy(sf);
    cairo_surface_flush(sf);
    const data = cairo_image_surface_get_data(sf) orelse return error.OutOfMemory;
    gdk_texture_download(texture, data, @intCast(cairo_image_surface_get_stride(sf)));
    cairo_surface_mark_dirty(sf);
    return .{ .src_hash = 0, .surface = sf, .w = @floatFromInt(w), .h = @floatFromInt(h) };
}

/// The largest picture decoded: 4096 x 4096 px (64 MB as ARGB, and the same
/// again while it's converted).
const max_image_pixels: u64 = 4096 * 4096;

/// The width and height an image file declares, read by feeding a
/// GdkPixbufLoader header bytes until it reports them (size-prepared), or
/// null when it isn't an image it knows.
fn probeSize(bytes: []const u8) ?[2]c_int {
    const loader = gdk_pixbuf_loader_new();
    defer g_object_unref(loader);
    var size: [2]c_int = .{ 0, 0 };
    const S = struct {
        fn onSize(_: *anyopaque, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
            const out: *[2]c_int = @ptrCast(@alignCast(data.?));
            out.* = .{ w, h };
        }
    };
    _ = g_signal_connect_data(loader, "size-prepared", @ptrCast(&S.onSize), &size, null, 0);
    var err: ?*anyopaque = null;
    var off: usize = 0;
    // Headers come first; 256 KiB is far more than any needs (and bounds
    // what a broken file can make the loader decode).
    while (off < bytes.len and off < 256 * 1024 and size[0] == 0) {
        const n = @min(1024, bytes.len - off);
        if (gdk_pixbuf_loader_write(loader, bytes.ptr + off, n, &err) == 0) break;
        off += n;
    }
    if (err) |e| {
        g_error_free(e);
        err = null;
    }
    // Closing a partly written loader reports an error: expected, ignored.
    _ = gdk_pixbuf_loader_close(loader, &err);
    if (err) |e| g_error_free(e);
    if (size[0] <= 0 or size[1] <= 0) return null;
    return size;
}

/// Drawn in its content box per CSS object-fit (fill by default).
fn paintImage(s: *Surface, cr: *cairo_t, n: *Node) void {
    const img = imageOf(s, n) orelse return;
    const sf = img.surface orelse return;
    const c = n.content();
    if (c.w <= 0 or c.h <= 0) return;
    const fit = n.props.fit orelse "fill";
    var kx: f64 = c.w / img.w;
    var ky: f64 = c.h / img.h;
    if (std.mem.eql(u8, fit, "contain")) {
        kx = @min(kx, ky);
        ky = kx;
    } else if (std.mem.eql(u8, fit, "cover")) {
        kx = @max(kx, ky);
        ky = kx;
    } else if (std.mem.eql(u8, fit, "none")) {
        kx = 1;
        ky = 1;
    } else if (std.mem.eql(u8, fit, "scale-down")) {
        kx = @min(1, @min(kx, ky));
        ky = kx;
    }
    cairo_save(cr);
    defer cairo_restore(cr);
    cairo_rectangle(cr, c.x, c.y, c.w, c.h);
    cairo_clip(cr);
    cairo_translate(cr, c.x + (c.w - img.w * kx) / 2, c.y + (c.h - img.h * ky) / 2);
    cairo_scale(cr, kx, ky);
    cairo_set_source_surface(cr, sf, 0, 0);
    cairo_paint(cr);
}

fn paintIcon(cr: *cairo_t, n: *Node) void {
    const icon = n.props.icon orelse return;
    const c = n.content();
    if (c.w <= 0 or c.h <= 0 or icon.vb[2] <= 0 or icon.vb[3] <= 0) return;
    const scale = @min(c.w / icon.vb[2], c.h / icon.vb[3]);
    cairo_save(cr);
    defer cairo_restore(cr);
    cairo_translate(cr, c.x + (c.w - icon.vb[2] * scale) / 2, c.y + (c.h - icon.vb[3] * scale) / 2);
    cairo_scale(cr, scale, scale);
    cairo_translate(cr, -icon.vb[0], -icon.vb[1]);
    var buf: [4096]u8 = undefined;
    for (icon.shapes) |sh| {
        const d = std.fmt.bufPrintSentinel(&buf, "{s}", .{sh.d}, 0) catch continue;
        const path = gsk_path_parse(d.ptr) orelse continue;
        defer gsk_path_unref(path);
        cairo_new_path(cr);
        gsk_path_to_cairo(path, cr);
        if (sh.fill) |fill| {
            cairo_set_fill_rule(cr, if (sh.evenodd) 1 else 0);
            setColor(cr, fill);
            if (sh.stroke != null) cairo_fill_preserve(cr) else cairo_fill(cr);
        }
        if (sh.stroke) |stroke| {
            setColor(cr, stroke);
            cairo_set_line_width(cr, sh.sw);
            cairo_set_line_cap(cr, if (std.mem.eql(u8, sh.cap, "round")) 1 else if (std.mem.eql(u8, sh.cap, "square")) 2 else 0);
            cairo_set_line_join(cr, if (std.mem.eql(u8, sh.join, "round")) 1 else if (std.mem.eql(u8, sh.join, "bevel")) 2 else 0);
            cairo_stroke(cr);
        }
    }
}

test "probeSize reads a PNG's declared size without decoding it" {
    // A PNG signature, an IHDR chunk declaring 30000 x 30000 px, and the
    // start of an IDAT chunk (libpng reports the size when it reaches the
    // image data): a few bytes that would decode to 3.6 GB.
    var png: [8 + 25 + 12]u8 = undefined;
    @memcpy(png[0..8], "\x89PNG\r\n\x1a\n");
    std.mem.writeInt(u32, png[8..12], 13, .big);
    @memcpy(png[12..16], "IHDR");
    std.mem.writeInt(u32, png[16..20], 30000, .big);
    std.mem.writeInt(u32, png[20..24], 30000, .big);
    png[24] = 8; // bit depth
    png[25] = 6; // RGBA
    png[26] = 0;
    png[27] = 0;
    png[28] = 0;
    std.mem.writeInt(u32, png[29..33], std.hash.Crc32.hash(png[12..29]), .big);
    std.mem.writeInt(u32, png[33..37], 0, .big);
    @memcpy(png[37..41], "IDAT");
    std.mem.writeInt(u32, png[41..45], std.hash.Crc32.hash(png[37..41]), .big);
    const size = probeSize(&png) orelse return error.NoSize;
    try std.testing.expectEqual(@as(c_int, 30000), size[0]);
    try std.testing.expectEqual(@as(c_int, 30000), size[1]);
    try std.testing.expect(@as(u64, @intCast(size[0])) * @as(u64, @intCast(size[1])) > max_image_pixels);
}

test "shared measurements match fresh Pango layouts after text, width and font changes" {
    if (gtk_init_check() == 0) return error.SkipZigTest;
    const area = gtk_drawing_area_new();
    _ = g_object_ref_sink(area);
    defer g_object_unref(area);
    const gpa = std.testing.allocator;
    var s = Surface{
        .gpa = gpa,
        .area = area,
        .overlay = area,
        .fields = .init(gpa),
        .images = .init(gpa),
        .canvases = .init(gpa),
        .css = undefined,
        .invoke_fn = undefined,
        .invoke_ctx = null,
    };
    defer {
        s.fields.deinit();
        s.images.deinit();
        s.canvases.deinit();
        s.text_measurements.deinit(gpa);
        if (s.sans) |font| pango_font_description_free(font);
        if (s.mono) |font| pango_font_description_free(font);
    }
    var t = tree_mod.Tree.init(gpa, &s, measure);
    defer t.deinit();
    t.on_props = propsChanged;
    t.on_text = textChanged;
    try t.apply(
        \\[["c",1,"text"],["p",1,{"fz":14,"runs":[{"t":"Latin Ω مرحبا repeated text","sz":14}]}]]
    );
    const n = t.get(1).?;
    for ([_]f32{ 40, 1000, 40 }) |width| {
        var cached: [2]f32 = undefined;
        measure(&s, n, width, &cached);
        const fresh = textLayout(&s, n, width).?;
        defer g_object_unref(fresh);
        var w: c_int = 0;
        var h: c_int = 0;
        pango_layout_get_pixel_size(fresh, &w, &h);
        try std.testing.expectEqual(@as(f32, @floatFromInt(w + 1)), cached[0]);
        try std.testing.expectEqual(@as(f32, @floatFromInt(h)), cached[1]);
    }
    try std.testing.expect(try t.updateText(1, "updated Ω text"));
    try t.apply(
        \\[["p",1,{"fz":24,"ls":2,"lh":32,"runs":[{"t":"updated Ω text","sz":24,"w":700,"i":true}]}]]
    );
    var cached: [2]f32 = undefined;
    measure(&s, n, 80, &cached);
    const fresh = textLayout(&s, n, 80).?;
    defer g_object_unref(fresh);
    var w: c_int = 0;
    var h: c_int = 0;
    pango_layout_get_pixel_size(fresh, &w, &h);
    try std.testing.expectEqual(@as(f32, @floatFromInt(w + 1)), cached[0]);
    try std.testing.expectEqual(@as(f32, @floatFromInt(h)), cached[1]);
    const old_count = s.text_measurements.entries.count();
    pango_context_changed(gtk_widget_get_pango_context(area));
    measure(&s, n, 80, &cached);
    try std.testing.expect(s.text_measurements.entries.count() < old_count);
}
