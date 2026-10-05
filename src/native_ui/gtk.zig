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
const Radii = tree_mod.Radii;

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
extern fn gtk_drawing_area_set_draw_func(area: *Widget, func: ?*const fn (*Widget, *cairo_t, c_int, c_int, ?*anyopaque) callconv(.c) void, data: ?*anyopaque, destroy: ?*anyopaque) void;
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
extern fn gtk_editable_set_editable(w: *Widget, editable: c_int) void;
extern fn gtk_text_view_set_editable(w: *Widget, editable: c_int) void;
extern fn gtk_accessible_update_property(w: *Widget, first: c_int, ...) void;
extern fn gtk_accessible_reset_property(w: *Widget, property: c_int) void;
extern fn gtk_entry_set_input_purpose(w: *Widget, purpose: c_int) void;
extern fn gtk_entry_set_input_hints(w: *Widget, hints: c_uint) void;
extern fn gtk_text_view_set_input_purpose(w: *Widget, purpose: c_int) void;
extern fn gtk_text_view_set_input_hints(w: *Widget, hints: c_uint) void;
extern fn gtk_widget_add_controller(w: *Widget, controller: *anyopaque) void;
extern fn gtk_widget_has_focus(w: *Widget) c_int;
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
extern fn gtk_event_controller_focus_new() *anyopaque;
extern fn gtk_scale_new_with_range(orientation: c_int, min: f64, max: f64, step: f64) *Widget;
extern fn gtk_range_set_value(r: *Widget, v: f64) void;
extern fn gtk_range_get_value(r: *Widget) f64;
extern fn gtk_range_set_increments(r: *Widget, step: f64, page: f64) void;
extern fn gtk_event_controller_legacy_new() *anyopaque;
extern fn gdk_event_get_event_type(e: *anyopaque) c_int;
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
extern fn g_signal_handlers_disconnect_matched(instance: *anyopaque, mask: c_int, signal_id: c_uint, detail: c_uint, closure: ?*anyopaque, func: ?*anyopaque, data: ?*anyopaque) c_uint;
extern fn gtk_style_context_remove_provider_for_display(display: *anyopaque, provider: *GtkCssProvider) void;
extern fn g_free(p: ?*anyopaque) void;
extern fn g_idle_add_full(priority: c_int, func: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque, notify: ?*anyopaque) c_uint;
extern fn g_source_remove(id: c_uint) c_int;
extern fn g_timeout_add(ms: c_uint, func: *const fn (?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
extern fn gtk_widget_add_tick_callback(w: *Widget, func: *const fn (*Widget, *anyopaque, ?*anyopaque) callconv(.c) c_int, data: ?*anyopaque, notify: ?*anyopaque) c_uint;
extern fn gtk_widget_remove_tick_callback(w: *Widget, id: c_uint) void;
extern fn gdk_frame_clock_get_frame_time(clock: *anyopaque) i64;
extern fn gdk_frame_clock_get_refresh_info(clock: *anyopaque, base_time: i64, refresh_interval: ?*i64, presentation_time: ?*i64) void;
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
extern fn cairo_set_dash(cr: *cairo_t, dashes: ?[*]const f64, n: c_int, offset: f64) void;
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
extern fn cairo_pattern_set_extend(p: *cairo_pattern_t, extend: c_int) void;
extern fn cairo_pattern_create_linear(x0: f64, y0: f64, x1: f64, y1: f64) *cairo_pattern_t;
extern fn cairo_pattern_add_color_stop_rgba(p: *cairo_pattern_t, off: f64, r: f64, g: f64, b: f64, a: f64) void;
extern fn cairo_pattern_destroy(p: *cairo_pattern_t) void;
extern fn cairo_pattern_create_radial(cx0: f64, cy0: f64, r0: f64, cx1: f64, cy1: f64, r1: f64) *cairo_pattern_t;
extern fn cairo_pattern_set_matrix(p: *cairo_pattern_t, m: *const CairoMatrix) void;
extern fn cairo_mask_surface(cr: *cairo_t, surface: *anyopaque, x: f64, y: f64) void;
extern fn cairo_get_matrix(cr: *cairo_t, m: *CairoMatrix) void;
extern fn cairo_set_matrix(cr: *cairo_t, m: *const CairoMatrix) void;
const CairoMatrix = extern struct { xx: f64, yx: f64, xy: f64, yy: f64, x0: f64, y0: f64 };

extern fn pango_layout_new(ctx: *anyopaque) ?*PangoLayout;
extern fn pango_layout_get_extents(l: *PangoLayout, ink: ?*PangoRectangle, logical: ?*PangoRectangle) void;
extern fn pango_layout_set_text(l: *PangoLayout, t: [*]const u8, len: c_int) void;
extern fn pango_layout_set_attributes(l: *PangoLayout, attrs: ?*PangoAttrList) void;
extern fn pango_layout_set_width(l: *PangoLayout, w: c_int) void;
extern fn pango_layout_set_wrap(l: *PangoLayout, wrap: c_int) void;
extern fn pango_layout_set_alignment(l: *PangoLayout, a: c_int) void;
extern fn pango_layout_set_font_description(l: *PangoLayout, d: ?*const PangoFontDescription) void;
extern fn pango_attr_line_height_new_absolute(height: c_int) *PangoAttribute;
extern fn pango_layout_get_size(l: *PangoLayout, w: *c_int, h: *c_int) void;
extern fn pango_layout_get_iter(l: *PangoLayout) ?*anyopaque;
extern fn pango_layout_iter_next_cluster(it: *anyopaque) c_int;
extern fn pango_layout_iter_free(it: *anyopaque) void;
extern fn pango_layout_iter_next_line(it: *anyopaque) c_int;
extern fn pango_layout_iter_get_line_readonly(it: *anyopaque) ?*anyopaque;
extern fn pango_layout_iter_get_line_extents(it: *anyopaque, ink: ?*PangoRectangle, logical: ?*PangoRectangle) void;
extern fn pango_layout_line_x_to_index(line: *anyopaque, x_pos: c_int, index: *c_int, trailing: *c_int) c_int;
extern fn pango_layout_iter_get_line_yrange(it: *anyopaque, y0: *c_int, y1: *c_int) void;
extern fn pango_layout_line_get_x_ranges(line: *anyopaque, start: c_int, end: c_int, ranges: *?[*]c_int, n: *c_int) void;
const PangoRectangle = extern struct { x: c_int = 0, y: c_int = 0, width: c_int = 0, height: c_int = 0 };
/// PangoLayoutLine's public head (pango-layout.h): its bytes in the text.
const PangoLayoutLineHead = extern struct { layout: ?*anyopaque, start_index: c_int, length: c_int };
extern fn pango_layout_get_text(l: *PangoLayout) [*:0]const u8;
extern fn pango_layout_get_pixel_size(l: *PangoLayout, w: *c_int, h: *c_int) void;
extern fn pango_layout_get_baseline(l: *PangoLayout) c_int;
extern fn pango_cairo_show_layout(cr: *cairo_t, l: *PangoLayout) void;
extern fn pango_cairo_show_layout_line(cr: *cairo_t, line: *anyopaque) void;
extern fn pango_attr_shape_new(ink: *const PangoRectangle, logical: *const PangoRectangle) *PangoAttribute;
extern fn pango_layout_iter_get_baseline(it: *anyopaque) c_int;
extern fn pango_layout_get_line_count(l: *PangoLayout) c_int;
extern fn pango_cairo_layout_path(cr: *cairo_t, l: *PangoLayout) void;
extern fn pango_font_description_from_string(s: [*:0]const u8) *PangoFontDescription;
extern fn pango_font_description_set_absolute_size(d: *PangoFontDescription, size: f64) void;
extern fn pango_font_description_set_weight(d: *PangoFontDescription, w: c_int) void;
extern fn pango_font_description_set_style(d: *PangoFontDescription, s: c_int) void;
extern fn pango_font_description_free(d: *PangoFontDescription) void;
const PangoFontMetrics = opaque {};
extern fn pango_context_get_metrics(ctx: *PangoContext, desc: ?*const PangoFontDescription, lang: ?*anyopaque) ?*PangoFontMetrics;
extern fn pango_font_metrics_get_ascent(m: *PangoFontMetrics) c_int;
extern fn pango_font_metrics_get_descent(m: *PangoFontMetrics) c_int;
extern fn pango_font_metrics_unref(m: *PangoFontMetrics) void;
extern fn pango_font_metrics_get_height(m: *PangoFontMetrics) c_int;
extern fn pango_font_metrics_get_approximate_digit_width(m: *PangoFontMetrics) c_int;
extern fn pango_font_description_get_size(d: *PangoFontDescription) c_int;
extern fn pango_font_description_get_size_is_absolute(d: *PangoFontDescription) c_int;
extern fn pango_font_description_get_family(d: *PangoFontDescription) ?[*:0]const u8;
extern fn gtk_widget_get_style_context(w: *Widget) *anyopaque;
extern fn gtk_style_context_lookup_color(ctx: *anyopaque, name: [*:0]const u8, color: *GdkRGBA) c_int;
const GdkRGBA = extern struct { red: f32, green: f32, blue: f32, alpha: f32 };
const PangoFontFamily = opaque {};
extern fn pango_font_map_list_families(map: *anyopaque, families: *?[*]*PangoFontFamily, n: *c_int) void;
extern fn pango_font_family_get_name(f: *PangoFontFamily) [*:0]const u8;
extern fn pango_cairo_font_map_get_default() *anyopaque;
extern fn pango_font_map_create_context(map: *anyopaque) ?*PangoContext;
extern fn pango_cairo_context_set_font_options(ctx: *PangoContext, opts: ?*const anyopaque) void;
extern fn cairo_font_options_create() ?*anyopaque;
extern fn cairo_font_options_set_hint_metrics(opts: *anyopaque, hint: c_int) void;
extern fn cairo_font_options_destroy(opts: *anyopaque) void;
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
extern fn pango_font_description_set_family(d: *PangoFontDescription, family: [*:0]const u8) void;
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
    /// Filled circles as anti-aliased masks (canvasCircle), by radius and
    /// sub-pixel position; dropped when there get to be many.
    circle_masks: CircleMasks = .empty,
    text_measurements: text_measure_cache.Cache = .{},
    /// Per font: each ASCII character's width before each other one, from
    /// Pango (fastTextSize).
    glyph_widths: std.AutoHashMapUnmanaged(FontKey, *PairWidths) = .empty,
    text_context: ?*PangoContext = null,
    text_serial: c_uint = 0,
    text_epoch: u64 = 1,
    /// The text fonts ("Sans", "Monospace"), parsed once; each layout
    /// copies one after setting its size.
    sans: ?*PangoFontDescription = null,
    mono: ?*PangoFontDescription = null,
    /// Unhinted metrics (hint-metrics off): ascent, descent and line gap as
    /// the font's tables have them, what browsers' line-height: normal is
    /// made of (normalLineHeight). By size (1/64 px) and monospace.
    metrics_ctx: ?*PangoContext = null,
    /// Unhinted [ascent, descent, line gap, digit width] by font and size.
    font_metrics: std.AutoHashMapUnmanaged(u64, [4]f32) = .empty,
    /// The installed families (lowercase), and CSS family lists resolved
    /// to the one a browser would use (resolveFamily). Keys and values owned.
    installed_families: std.StringHashMapUnmanaged(void) = .empty,
    resolved_families: std.StringHashMapUnmanaged([]const u8) = .empty,
    css: *GtkCssProvider,
    css_text: std.ArrayList(u8) = .empty,
    invoke_fn: Invoke,
    invoke_ctx: ?*anyopaque,
    /// The area's event controllers (their handlers go in `destroy`).
    controllers: [6]*anyopaque = undefined,
    /// Drags over the page (onDragEnter): one session per drag that
    /// enters, a drag is over the page now (until it leaves or drops),
    /// what it carries, and the action GTK was last told (a drop's).
    drag_session: u32 = 0,
    drag_inside: bool = false,
    drag_kinds: DragKinds = .{},
    drag_action: c_uint = 0,
    /// Names the surface for its timers (`surfaces`): one that fires after
    /// the window closed finds nothing.
    token: u64 = 0,
    /// The page asked for an animation frame (host.vsync), and the frame
    /// clock's tick callback giving it (0: none registered).
    frame_wanted: bool = false,
    tick_id: c_uint = 0,
    /// Fonts to load while idle (warmFonts), and the idle source doing it.
    warm: std.ArrayList(engine_mod.FontSpec) = .empty,
    warm_id: c_uint = 0,
    /// After a big removal: the tree's empty slabs released a while later
    /// (onTrim), if no new list took them.
    trim_id: c_uint = 0,
    pointer: [2]f32 = .{ 0, 0 },
    hovered: i64 = 0,
    /// Mouse buttons down, as the DOM's `buttons` (1 primary, 2 secondary, 4 middle).
    buttons: u32 = 0,
    /// A pointer move waiting for the next display frame (the latest wins).
    move: ?PendingMove = null,
    /// Keys down, for keydown's `repeat` (GTK reports auto-repeat as presses).
    keys_down: std.AutoHashMapUnmanaged(c_uint, void) = .empty,
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
        // The engine copies the platform JSON.
        const look = withLook(gpa, platform_json, area);
        defer if (look) |l| gpa.free(l);
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
            .request_display_frame = requestDisplayFrame,
            .warm_fonts = warmFonts,
            .font_metrics = fontMetrics,
        .font_metrics_family = fontMetricsFamily,
        .run_rects = runRects,
        .font_x_height = fontXHeight,
        }, assets, look orelse platform_json, label, url, width, height);
        s.engine.tree.reuse_text_layout = true;
        s.engine.tree.fields_sized = true;

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
        _ = g_signal_connect_data(keys, "key-released", @ptrCast(&onKeyUp), s, null, 0);
        gtk_widget_add_controller(area, keys);
        // Keys while a field has the keyboard: the page's first (keydown,
        // Tab moving the focus), as the area's controller doesn't hear them.
        const tab = gtk_event_controller_key_new();
        gtk_event_controller_set_propagation_phase(tab, 1); // capture
        _ = g_signal_connect_data(tab, "key-pressed", @ptrCast(&onFieldKey), s, null, 0);
        _ = g_signal_connect_data(tab, "key-released", @ptrCast(&onFieldKeyUp), s, null, 0);
        gtk_widget_add_controller(overlay, tab);
        // Drops into the page: on the overlay, so drags over a native
        // field come here too (GtkText's own target takes text first).
        const dnd = newDropTarget();
        _ = g_signal_connect_data(dnd, "accept", @ptrCast(&onDragAccept), s, null, 0);
        _ = g_signal_connect_data(dnd, "drag-enter", @ptrCast(&onDragEnter), s, null, 0);
        _ = g_signal_connect_data(dnd, "drag-motion", @ptrCast(&onDragMotion), s, null, 0);
        _ = g_signal_connect_data(dnd, "drag-leave", @ptrCast(&onDragLeave), s, null, 0);
        _ = g_signal_connect_data(dnd, "drop", @ptrCast(&onDrop), s, null, 0);
        gtk_widget_add_controller(overlay, dnd);
        s.controllers = .{ click, scroll, motion, keys, tab, dnd };

        s.token = next_token;
        next_token += 1;
        surfaces.put(gpa, s.token, s) catch |err| {
            s.engine.destroy();
            return err;
        };
        s.engine.boot(s.dark, false);
        return s;
    }

    /// The window is closing: the page, its fields, pictures and style go.
    /// GTK destroys the widgets with the window right after; nothing of
    /// theirs reaches the surface from here on (timers find no token).
    pub fn destroy(s: *Surface) void {
        _ = surfaces.remove(s.token);
        if (s.tick_id != 0) gtk_widget_remove_tick_callback(s.area, s.tick_id);
        s.tick_id = 0;
        if (s.warm_id != 0) _ = g_source_remove(s.warm_id);
        s.warm_id = 0;
        if (s.trim_id != 0) _ = g_source_remove(s.trim_id);
        s.trim_id = 0;
        s.warm.deinit(s.gpa);
        s.keys_down.deinit(s.gpa);
        gtk_drawing_area_set_draw_func(s.area, null, null, null);
        disconnect(s, s.area);
        disconnect(s, s.overlay);
        for (s.controllers) |c| disconnect(s, c);
        // A field emits signals while it goes (focus, text): not to us.
        var fit = s.fields.iterator();
        while (fit.next()) |e| disconnectField(s, e.key_ptr.*, e.value_ptr.*);
        // The engine: freeing its tree calls `removed` for every node,
        // which drops the fields, pictures and canvases.
        s.engine.destroy();
        var rest = s.fields.valueIterator();
        while (rest.next()) |w| gtk_overlay_remove_overlay(s.overlay, w.*);
        s.fields.deinit();
        var imgs = s.images.valueIterator();
        while (imgs.next()) |img| img.deinit();
        s.images.deinit();
        var cvs = s.canvases.valueIterator();
        while (cvs.next()) |cv| cairo_surface_destroy(cv.surf);
        s.canvases.deinit();
        clearCircleMasks(&s.circle_masks);
        s.circle_masks.deinit(s.gpa);
        gtk_style_context_remove_provider_for_display(gtk_widget_get_display(s.area), s.css);
        g_object_unref(s.css);
        s.css_text.deinit(s.gpa);
        if (s.sans) |font| pango_font_description_free(font);
        if (s.mono) |font| pango_font_description_free(font);
        if (s.metrics_ctx) |c| g_object_unref(c);
        s.font_metrics.deinit(s.gpa);
        freeFamilies(s);
        s.gpa.destroy(s);
    }

    /// The page's JS is running (a command it called closes its window):
    /// the close waits for the call to end.
    pub fn busy(engine: *anyopaque) bool {
        const e: *Engine = @ptrCast(@alignCast(engine));
        return e.in_call > 0;
    }

    /// `destroy` for the surface whose engine this is (WindowHandle.native),
    /// if it's still there.
    pub fn destroyFor(engine: *anyopaque) void {
        var it = surfaces.valueIterator();
        while (it.next()) |sp| if (@as(*anyopaque, @ptrCast(sp.*.engine)) == engine) return sp.*.destroy();
    }

    fn prefersDark() bool {
        if (g_getenv("ORIEL_COLOR_SCHEME")) |v| return std.mem.eql(u8, std.mem.span(v), "dark");
        const settings = gtk_settings_get_default() orelse return false;
        var dark: c_int = 0;
        g_object_get(settings, "gtk-application-prefer-dark-theme", &dark, @as(?*anyopaque, null));
        return dark != 0;
    }
};

/// Live surfaces by token (the UI thread's only).
var surfaces: std.AutoHashMapUnmanaged(u64, *Surface) = .empty;
var next_token: u64 = 1;

const G_SIGNAL_MATCH_DATA: c_int = 1 << 4;

fn disconnect(s: *Surface, instance: *anyopaque) void {
    _ = g_signal_handlers_disconnect_matched(instance, G_SIGNAL_MATCH_DATA, 0, 0, null, null, s);
}

fn disconnectField(s: *Surface, id: i64, w: *Widget) void {
    disconnect(s, w);
    if (g_object_get_data(w, "oriel-focus")) |c| disconnect(s, c);
    const n = s.engine.tree.get(id) orelse return;
    if (n.kind == .textarea) disconnect(s, gtk_text_view_get_buffer(w));
}

fn surfaceOf(p: ?*anyopaque) *Surface {
    return @ptrCast(@alignCast(p.?));
}

fn releaseTextMeasurements(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.text_measurements.deinit(s.gpa);
    clearGlyphWidths(s);
    s.glyph_widths.deinit(s.gpa);
}

// ---------------------------------------------------------------------------
// Backend hooks

fn invoke(ctx: *anyopaque, engine: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
    const s = surfaceOf(ctx);
    s.invoke_fn(s.invoke_ctx, engine, call_id, cmd, args_json);
}

const TimerData = struct { token: u64, id: u32 };

fn addTimer(ctx: *anyopaque, _: *Engine, id: u32, ms: u32) void {
    const d = std.heap.smp_allocator.create(TimerData) catch return;
    d.* = .{ .token = surfaceOf(ctx).token, .id = id };
    _ = g_timeout_add(ms, onTimer, d);
}

fn onTimer(p: ?*anyopaque) callconv(.c) c_int {
    const d: *TimerData = @ptrCast(@alignCast(p.?));
    const token = d.token;
    const id = d.id;
    std.heap.smp_allocator.destroy(d);
    const s = surfaces.get(token) orelse return 0; // the window is gone
    s.engine.timerFired(id);
    return 0;
}

/// Backend.warm_fonts: the fonts load one per idle moment (low priority:
/// after input, drawing and the page's timers), each by laying out a
/// short text in it, as the first text in that size and weight would.
/// host.fontMetrics: the ascent, descent and line gap of the font text is
/// measured with (textLayout's), at `size` px, unhinted.
fn fontMetrics(ctx: *anyopaque, size: f32, mono: bool, out: *[3]f32) bool {
    const m = unhintedMetrics(surfaceOf(ctx), size, mono, null) orelse return false;
    out.* = m[0..3].*;
    return true;
}

/// Backend.font_metrics_family: the same for a CSS font-family list (a
/// line's strut in its block's own font).
fn fontMetricsFamily(ctx: *anyopaque, size: f32, mono: bool, family: []const u8, out: *[3]f32) bool {
    const m = unhintedMetrics(surfaceOf(ctx), size, mono, family) orelse return false;
    out.* = m[0..3].*;
    return true;
}

/// The platform JSON with the GTK theme's look, as WebKitGTK uses it for
/// its controls: `accent` (the accent color, [r, g, b]: its focus ring)
/// and `uiFont` (gtk-font-name's family and size in whole px: its form
/// controls' font). Owned by the caller; null: as is.
fn withLook(gpa: std.mem.Allocator, platform_json: [:0]const u8, w: *Widget) ?[:0]const u8 {
    const trimmed = std.mem.trimEnd(u8, platform_json, " \n");
    if (trimmed.len < 2 or trimmed[trimmed.len - 1] != '}') return null;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const body = trimmed[0 .. trimmed.len - 1];
    var sep: []const u8 = if (std.mem.trimEnd(u8, body, " \n").len > 1) "," else "";
    out.writer.writeAll(body) catch return null;
    var rgba: GdkRGBA = undefined;
    if (gtk_style_context_lookup_color(gtk_widget_get_style_context(w), "accent_bg_color", &rgba) != 0) {
        out.writer.print("{s}\"accent\":[{d},{d},{d}]", .{ sep, @round(rgba.red * 255), @round(rgba.green * 255), @round(rgba.blue * 255) }) catch return null;
        sep = ",";
    }
    if (gtk_settings_get_default()) |settings| {
        var name: ?[*:0]u8 = null;
        g_object_get(settings, "gtk-font-name", &name, @as(?*anyopaque, null));
        defer g_free(name);
        if (name) |n| {
            const desc = pango_font_description_from_string(n);
            defer pango_font_description_free(desc);
            const size = @as(f32, @floatFromInt(pango_font_description_get_size(desc))) / PANGO_SCALE;
            // Points at 96 dpi, as GTK and WebKitGTK take them.
            const px = @floor(if (pango_font_description_get_size_is_absolute(desc) != 0) size else size * 96.0 / 72.0);
            if (pango_font_description_get_family(desc)) |family| if (px > 0) {
                out.writer.print("{s}\"uiFont\":[", .{sep}) catch return null;
                std.json.Stringify.value(std.mem.span(family), .{}, &out.writer) catch return null;
                out.writer.print(",{d}]", .{px}) catch return null;
            };
        }
    }
    out.writer.writeAll("}") catch return null;
    return gpa.dupeZ(u8, out.written()) catch null;
}

fn familyHash(family: ?[]const u8) u64 {
    return if (family) |f| std.hash.Wyhash.hash(0, f) else 0;
}

/// A font description for this text: Sans or Monospace, or its CSS family
/// list, at `size` px (the surface's own, changed in place: one at a time).
/// CSS's generic families as fontconfig names them.
const generic_families = std.StaticStringMap([]const u8).initComptime(.{
    .{ "serif", "serif" },            .{ "sans-serif", "sans-serif" },    .{ "monospace", "monospace" },
    .{ "system-ui", "system-ui" },    .{ "ui-sans-serif", "sans-serif" }, .{ "ui-serif", "serif" },
    .{ "ui-monospace", "monospace" }, .{ "ui-rounded", "sans-serif" },    .{ "cursive", "cursive" },
    .{ "fantasy", "fantasy" },        .{ "emoji", "emoji" },              .{ "math", "math" },
    // No family set (render.js familyOf): WebKitGTK's default face, its
    // default-font-family setting, sans-serif (not serif, as Chromium).
    .{ "default", "sans-serif" },
});

/// The family a browser draws a CSS font-family list in: the first one
/// installed, or the first generic name (fontconfig's alias for it). Pango
/// given the whole list lets fontconfig pick, and a weak alias like
/// system-ui loses to a real family later in it (Roboto, where WebKit uses
/// Adwaita Sans).
fn resolveFamily(s: *Surface, list: []const u8) []const u8 {
    if (s.resolved_families.get(list)) |name| return name;
    if (s.installed_families.count() == 0) {
        var fams: ?[*]*PangoFontFamily = null;
        var n: c_int = 0;
        pango_font_map_list_families(pango_cairo_font_map_get_default(), &fams, &n);
        if (fams) |f| {
            for (f[0..@intCast(n)]) |fam| {
                const name = std.mem.span(pango_font_family_get_name(fam));
                const low = std.ascii.allocLowerString(s.gpa, name) catch continue;
                const got = s.installed_families.getOrPut(s.gpa, low) catch {
                    s.gpa.free(low);
                    continue;
                };
                if (got.found_existing) s.gpa.free(low);
            }
            g_free(@ptrCast(f));
        }
    }
    var chosen: []const u8 = "sans-serif";
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t\"'");
        if (name.len == 0 or name.len > 128) continue;
        var low_buf: [128]u8 = undefined;
        const low = std.ascii.lowerString(&low_buf, name);
        if (generic_families.get(low)) |g| {
            chosen = g;
            break;
        }
        if (s.installed_families.contains(low)) {
            chosen = name;
            break;
        }
    }
    const key = s.gpa.dupe(u8, list) catch return chosen;
    const value = s.gpa.dupe(u8, chosen) catch {
        s.gpa.free(key);
        return chosen;
    };
    if (s.resolved_families.count() >= 256) freeResolved(s);
    s.resolved_families.put(s.gpa, key, value) catch {
        s.gpa.free(key);
        s.gpa.free(value);
        return chosen;
    };
    return value;
}

fn freeResolved(s: *Surface) void {
    var it = s.resolved_families.iterator();
    while (it.next()) |e| {
        s.gpa.free(e.key_ptr.*);
        s.gpa.free(e.value_ptr.*);
    }
    s.resolved_families.clearRetainingCapacity();
}

fn freeFamilies(s: *Surface) void {
    freeResolved(s);
    s.resolved_families.deinit(s.gpa);
    var it = s.installed_families.keyIterator();
    while (it.next()) |k| s.gpa.free(k.*);
    s.installed_families.deinit(s.gpa);
}

fn fontDesc(s: *Surface, size: f32, mono: bool, family: ?[]const u8) *PangoFontDescription {
    const font = if (mono) &s.mono else &s.sans;
    if (font.* == null) font.* = pango_font_description_from_string(if (mono) "Monospace" else "Sans");
    const desc = font.*.?;
    var buf: [256]u8 = undefined;
    const name: [*:0]const u8 = if (family) |f| (std.fmt.bufPrintZ(&buf, "{s}", .{resolveFamily(s, f)}) catch "Sans") else if (mono) "Monospace" else "Sans";
    pango_font_description_set_family(desc, name);
    pango_font_description_set_absolute_size(desc, size * PANGO_SCALE);
    return desc;
}

fn unhintedMetrics(s: *Surface, size: f32, mono: bool, family: ?[]const u8) ?[4]f32 {
    const key: u64 = (familyHash(family) *% 31) ^ ((@as(u64, @intFromBool(mono)) << 32) | tree_mod.sat(u32, size * 64));
    if (s.font_metrics.get(key)) |m| return m;
    const ctx = s.metrics_ctx orelse blk: {
        const c = pango_font_map_create_context(pango_cairo_font_map_get_default()) orelse return null;
        if (cairo_font_options_create()) |opts| {
            cairo_font_options_set_hint_metrics(opts, 1); // CAIRO_HINT_METRICS_OFF
            pango_cairo_context_set_font_options(c, opts);
            cairo_font_options_destroy(opts);
        }
        s.metrics_ctx = c;
        break :blk c;
    };
    const desc = fontDesc(s, size, mono, family);
    const m = pango_context_get_metrics(ctx, desc, null) orelse return null;
    defer pango_font_metrics_unref(m);
    const a = @as(f32, @floatFromInt(pango_font_metrics_get_ascent(m))) / PANGO_SCALE;
    const d = @as(f32, @floatFromInt(pango_font_metrics_get_descent(m))) / PANGO_SCALE;
    const h = @as(f32, @floatFromInt(pango_font_metrics_get_height(m))) / PANGO_SCALE;
    const digit = @as(f32, @floatFromInt(pango_font_metrics_get_approximate_digit_width(m))) / PANGO_SCALE;
    const out = [4]f32{ a, d, @max(0, h - a - d), digit };
    if (s.font_metrics.count() >= 256) s.font_metrics.clearRetainingCapacity();
    s.font_metrics.put(s.gpa, key, out) catch {};
    return out;
}

/// Backend.font_x_height (vertical-align: middle): the ink height of "x"
/// in that font, unhinted.
fn fontXHeight(ctx: *anyopaque, size: f32, mono: bool, family: []const u8) ?f32 {
    const s = surfaceOf(ctx);
    _ = unhintedMetrics(s, size, mono, family) orelse return null; // makes metrics_ctx
    const mctx = s.metrics_ctx orelse return null;
    const layout = pango_layout_new(mctx) orelse return null;
    defer g_object_unref(layout);
    pango_layout_set_font_description(layout, fontDesc(s, size, mono, family));
    pango_layout_set_text(layout, "x", 1);
    var ink: PangoRectangle = .{};
    pango_layout_get_extents(layout, &ink, null);
    if (ink.height <= 0) return null;
    return @as(f32, @floatFromInt(ink.height)) / PANGO_SCALE;
}

/// The height of a line of this text, as CSS stacks its inline boxes on
/// one baseline (textExtent): every line alike, the tallest any line can
/// be (lineExtents has each line's). Null with a line-height under a pixel
/// (Pango's own lines, centered) or without the fonts' metrics.
fn lineBox(s: *Surface, props: *const tree_mod.Props) ?f32 {
    if (props.lh) |lh| if (lh < 1) return null;
    if (textExtent(s, props)) |e| return e.top + e.bottom;
    // A CSS line-height in whole pixels, as WebKit (the WebView here, and
    // WKWebView) keeps it: 145% of 16px is 23 (Chromium: 23.2).
    if (props.lh) |lh| return @floor(lh);
    return null;
}

/// Above and below a line's baseline (px).
const Extent = struct { top: f32, bottom: f32 };

/// An inline box's extent on its line as WebKit lays it out: its font's
/// ascent and descent (each rounded) and the leading around them: its
/// line-height (whole pixels) less them, or the font's line gap (rounded)
/// when normal, split with the smaller (floored) half above (line-height: normal of
/// Noto Sans at 16px: 17 + 5 + 0 = 22, where Pango's own lines are 23).
fn fontExtent(s: *Surface, size: f32, mono: bool, family: ?[]const u8, lh: ?f32) ?Extent {
    const m = unhintedMetrics(s, size, mono, family) orelse return null;
    const a = @round(m[0]);
    const d = @round(m[1]);
    if (lh) |h| if (h >= 1) {
        // The half-leading above is floored, as WebKit does (24px over
        // 14 + 5: 2 above, 3 below).
        const leading = @floor(h) - (a + d);
        const up = @floor(leading / 2);
        return .{ .top = a + up, .bottom = d + leading - up };
    };
    const gap = @round(m[2]);
    const up = @floor(gap / 2);
    return .{ .top = a + up, .bottom = d + gap - up };
}

/// The block's own font's (CSS's strut: every line has it).
fn strutExtent(s: *Surface, props: *const tree_mod.Props) ?Extent {
    return fontExtent(s, props.fz orelse 16, props.mono, props.ff, props.lh);
}

fn runExtent(s: *Surface, props: *const tree_mod.Props, r: tree_mod.Run) ?Extent {
    return fontExtent(s, r.sz, r.mono or props.mono, r.ff orelse props.ff, r.lh orelse props.lh);
}

fn widen(e: ?Extent, x: ?Extent) ?Extent {
    const b = x orelse return e;
    const a = e orelse return b;
    return .{ .top = @max(a.top, b.top), .bottom = @max(a.bottom, b.bottom) };
}

/// Every run's box with the strut's: the line box of a line that has
/// them all.
fn textExtent(s: *Surface, props: *const tree_mod.Props) ?Extent {
    var e = strutExtent(s, props);
    for (props.runs orelse &.{}) |r| e = widen(e, runExtent(s, props, r));
    return e;
}

/// Each line's extent when they differ (a bigger font on some lines
/// only), from the runs on it; null when every line is textExtent's.
fn lineExtents(s: *Surface, props: *const tree_mod.Props, layout: *PangoLayout, out: []Extent) ?[]Extent {
    const runs = props.runs orelse return null;
    if (runs.len < 2) return null;
    if (props.lh) |lh| if (lh < 1) return null;
    const all = textExtent(s, props) orelse return null;
    const count: usize = @intCast(@max(0, pango_layout_get_line_count(layout)));
    if (count < 2 or count > out.len) return null;
    const strut = strutExtent(s, props);
    const it = pango_layout_get_iter(layout) orelse return null;
    defer pango_layout_iter_free(it);
    var differ = false;
    var walk: RunBytes = .{ .runs = runs };
    var cur = walk.next(); // a run's bytes, while it's on the lines to come
    var ri: usize = 0;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const line = pango_layout_iter_get_line_readonly(it) orelse return null;
        const head: *const PangoLayoutLineHead = @ptrCast(@alignCast(line));
        const ls: usize = @intCast(@max(0, head.start_index));
        const le = ls + @as(usize, @intCast(@max(0, head.length)));
        var e = strut;
        // The runs with a part on this line.
        while (cur) |range| {
            if (range[1] > ls and range[0] < le) e = widen(e, runExtent(s, props, runs[ri]));
            if (range[1] > le) break; // goes on to the next line
            cur = walk.next();
            ri += 1;
        }
        const x = e orelse all;
        out[k] = x;
        if (x.top != all.top or x.bottom != all.bottom) differ = true;
        if (pango_layout_iter_next_line(it) == 0) break;
    }
    if (k + 1 < count) return null;
    return if (differ) out[0..count] else null;
}

/// Where paintText puts each line: lineExtents', else textExtent's on
/// every line; null without a line box (Pango's own lines).
fn textLines(s: *Surface, props: *const tree_mod.Props, layout: *PangoLayout, out: []Extent) ?[]Extent {
    if (lineExtents(s, props, layout, out)) |e| return e;
    if (lineBox(s, props) == null) return null;
    const all = textExtent(s, props) orelse return null;
    const count: usize = @intCast(@max(1, pango_layout_get_line_count(layout)));
    if (count > out.len) return null;
    @memset(out[0..count], all);
    return out[0..count];
}

/// The lines' extents laid end to end: the text's height when they differ.
fn extentsHeight(exts: []const Extent) f32 {
    var h: f32 = 0;
    for (exts) |e| h += e.top + e.bottom;
    return h;
}

fn warmFonts(ctx: *anyopaque, specs: []const engine_mod.FontSpec) void {
    const s = surfaceOf(ctx);
    s.warm.appendSlice(s.gpa, specs) catch return;
    if (s.warm_id == 0) s.warm_id = g_idle_add_full(300, onWarm, @ptrFromInt(s.token), null); // G_PRIORITY_LOW
}

fn onWarm(data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaces.get(@intFromPtr(data)) orelse return 0; // the window is gone
    if (s.warm.items.len == 0) {
        s.warm_id = 0;
        return 0;
    }
    // In the page's order: the commonest first.
    const spec = s.warm.orderedRemove(0);
    var run: tree_mod.Run = .{ .t = "Aa", .sz = spec.size, .w = @floatFromInt(spec.weight), .i = spec.italic, .mono = spec.mono };
    var props: tree_mod.Props = .{};
    props.fz = spec.size;
    props.mono = spec.mono;
    props.runs = @as(*const [1]tree_mod.Run, &run);
    if (textLayoutOf(s, &props, std.math.inf(f32))) |layout| {
        var w: c_int = 0;
        var h: c_int = 0;
        pango_layout_get_size(layout, &w, &h);
        g_object_unref(layout);
    }
    if (s.warm.items.len > 0) return 1;
    s.warm_id = 0;
    return 0;
}

/// host.vsync: the page's next animation frame comes with the frame clock's
/// next frame (the display's refresh). The tick callback stays while the
/// page keeps asking (an animation loop) and goes when it stops, so an idle
/// page doesn't keep the clock running; a hidden window gets no frames.
fn requestDisplayFrame(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    s.frame_wanted = true;
    if (s.tick_id == 0) s.tick_id = gtk_widget_add_tick_callback(s.area, onTick, @ptrFromInt(s.token), null);
}

fn onTick(_: *Widget, clock: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const token: u64 = @intFromPtr(data);
    var s = surfaces.get(token) orelse return 0; // G_SOURCE_REMOVE: the window is gone
    // Input first, then the frame (as a browser): the page's handler can ask
    // for the frame that shows it.
    if (s.move != null) {
        flushMove(s);
        s = surfaces.get(token) orelse return 0; // the page closed its window
    }
    if (!s.frame_wanted) {
        s.tick_id = 0;
        return 0;
    }
    s.frame_wanted = false;
    var interval_us: i64 = 0;
    gdk_frame_clock_get_refresh_info(clock, gdk_frame_clock_get_frame_time(clock), &interval_us, null);
    s.engine.displayFrame(@as(f64, @floatFromInt(@max(interval_us, 0))) / 1000);
    // The page may have closed its window during the frame.
    const still = surfaces.get(token) orelse return 0;
    if (still.frame_wanted) return 1; // G_SOURCE_CONTINUE: the loop asked again
    still.tick_id = 0;
    return 0;
}

fn focus(ctx: *anyopaque, node: *Node) void {
    const s = surfaceOf(ctx);
    // A drawn element (a button, a link, tabindex): the keys go to the
    // page's view, not to the field that had them.
    _ = gtk_widget_grab_focus(s.fields.get(node.id) orelse s.area);
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

fn onTrim(data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaces.get(@intFromPtr(data)) orelse return 0; // the window is gone
    s.trim_id = 0;
    // The removed trees still in cycles first, then the memory back.
    s.engine.collectGarbage();
    _ = s.engine.tree.trimPools();
    _ = malloc_trim(0);
    return 0;
}

fn laidOut(ctx: *anyopaque) void {
    const s = surfaceOf(ctx);
    prof.report("text cache {d} entries {d} key bytes, {d} capacity resets", .{ s.text_measurements.entries.count(), s.text_measurements.bytes, s.text_measurements.capacity_resets });
    // A render that removed many nodes (a page section rebuilt): give the
    // freed memory back to the system. glibc's malloc keeps it otherwise
    // (QuickJS and the tree both allocate there), so memory only grew.
    const count = s.engine.tree.nodes.count();
    if (s.node_count > count + 1000) {
        _ = malloc_trim(0);
        if (s.trim_id == 0) s.trim_id = g_timeout_add(2000, onTrim, @ptrFromInt(s.token));
    }
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
                .input => if (n.props.range != null) {
                    gtk_range_set_value(w, tree_mod.Range.of(n).parse(v));
                } else gtk_editable_set_text(w, z.ptr),
                .textarea => gtk_text_buffer_set_text(gtk_text_view_get_buffer(w), z.ptr, @intCast(z.len)),
                .select => if (n.props.options) |opts| for (opts, 0..) |o, i| {
                    if (std.mem.eql(u8, o[0], v)) gtk_drop_down_set_selected(w, @intCast(i));
                },
                else => {},
            }
        }
        gtk_widget_set_sensitive(w, @intFromBool(!n.props.dis));
        // readonly: selectable and focusable, not editable.
        switch (n.kind) {
            .input => if (n.props.range == null) gtk_editable_set_editable(w, @intFromBool(!n.props.ro)),
            .textarea => gtk_text_view_set_editable(w, @intFromBool(!n.props.ro)),
            else => {},
        }
        // Its accessible name (Props.al: its label, aria-label, title).
        accessibleLabel(s, w, n.props.al);
        // What it takes (an on-screen keyboard's layout, spell checking).
        if (n.kind == .input and n.props.range == null) {
            gtk_entry_set_input_purpose(w, inputPurpose(n));
            gtk_entry_set_input_hints(w, inputHints(n));
        } else if (n.kind == .textarea) {
            gtk_text_view_set_input_purpose(w, inputPurpose(n));
            gtk_text_view_set_input_hints(w, inputHints(n));
        }
        // The page changes placeholders too ("Select text first…" → "Tell
        // GhostPen what to do…"); a text view's is drawn by paintPlaceholder.
        if (n.kind == .input and n.props.range == null) {
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

const GTK_ACCESSIBLE_PROPERTY_LABEL: c_int = 4;

fn accessibleLabel(s: *Surface, w: *Widget, al: ?[]const u8) void {
    const text = al orelse return gtk_accessible_reset_property(w, GTK_ACCESSIBLE_PROPERTY_LABEL);
    const z = s.gpa.dupeZ(u8, text) catch return;
    defer s.gpa.free(z);
    gtk_accessible_update_property(w, GTK_ACCESSIBLE_PROPERTY_LABEL, @as([*:0]const u8, z.ptr), @as(c_int, -1));
}

/// GtkInputPurpose from the field's type and inputmode (Props itype, im, pw).
fn inputPurpose(n: *const Node) c_int {
    if (n.props.pw) return 8; // PASSWORD
    const t = n.props.im orelse n.props.itype orelse return 0;
    const eq = std.mem.eql;
    if (eq(u8, t, "email")) return 6;
    if (eq(u8, t, "url")) return 5;
    if (eq(u8, t, "tel")) return 4;
    if (eq(u8, t, "numeric")) return 2; // DIGITS
    if (eq(u8, t, "number") or eq(u8, t, "decimal")) return 3;
    return 0; // FREE_FORM
}

/// GtkInputHints from spellcheck, autocapitalize and inputmode=none.
fn inputHints(n: *const Node) c_uint {
    var h: c_uint = if (n.props.spellcheck) 1 else 2; // SPELLCHECK, NO_SPELLCHECK
    if (n.props.cap) |c| {
        if (std.mem.eql(u8, c, "sentences")) h |= 1 << 6 else if (std.mem.eql(u8, c, "words")) h |= 1 << 5 else if (std.mem.eql(u8, c, "characters")) h |= 1 << 4;
    }
    if (n.props.im) |m| if (std.mem.eql(u8, m, "none")) {
        h |= 1 << 7; // INHIBIT_OSK
    };
    return h;
}

fn makeField(s: *Surface, n: *Node) !*Widget {
    const w: *Widget = switch (n.kind) {
        .input => if (n.props.range != null) blk: {
            // <input type=range>: a GtkScale on the page's min/max/step;
            // values snap to the step (Range, shared with the other
            // backends) and go out as the page's text ("0.25").
            const r = tree_mod.Range.of(n);
            const sc = gtk_scale_new_with_range(0, r.min, r.max, r.step);
            gtk_range_set_increments(sc, r.step, r.step * 10);
            _ = g_signal_connect_data(@ptrCast(sc), "value-changed", @ptrCast(&onSlid), s, null, 0);
            // "change" when the drag or key press ends, as in a browser;
            // the wheel doesn't move a slider (the page scrolls past it).
            const legacy = gtk_event_controller_legacy_new();
            gtk_event_controller_set_propagation_phase(legacy, 1); // capture
            _ = g_signal_connect_data(legacy, "event", @ptrCast(&onSliderEvent), s, null, 0);
            gtk_widget_add_controller(sc, legacy);
            break :blk sc;
        } else blk: {
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
            stripDropTargets(e);
            break :blk e;
        },
        .textarea => blk: {
            const v = gtk_text_view_new();
            gtk_text_view_set_wrap_mode(v, 3); // word-char
            gtk_text_view_set_accepts_tab(v, 0);
            _ = g_signal_connect_data(gtk_text_view_get_buffer(v), "changed", @ptrCast(&onBufferChanged), s, null, 0);
            g_object_set_data(gtk_text_view_get_buffer(v), "oriel-view", v);
            stripDropTargets(v);
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
    // The page hears which field has the keyboard (:focus, :focus-visible,
    // document.activeElement), as on the other backends.
    const focus_ctrl = gtk_event_controller_focus_new();
    _ = g_signal_connect_data(focus_ctrl, "enter", @ptrCast(&onFieldFocus), s, null, 0);
    _ = g_signal_connect_data(focus_ctrl, "leave", @ptrCast(&onFieldBlur), s, null, 0);
    gtk_widget_add_controller(w, focus_ctrl);
    g_object_set_data(@ptrCast(w), "oriel-focus", focus_ctrl);
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
        if (n.props.range != null) {
            // A slider: the page's accent-color on the filled part and knob.
            const ac = n.props.acc orelse tree_mod.Color{ 59, 108, 255, 1 };
            s.css_text.print(a, ".nui-f{d} highlight {{ background: rgba({d:.0},{d:.0},{d:.0},{d:.2}); border-color: transparent; }} .nui-f{d} slider {{ background: rgba({d:.0},{d:.0},{d:.0},1); border-color: transparent; }}\n", .{
                n.id, ac[0], ac[1], ac[2], ac[3], n.id, ac[0], ac[1], ac[2],
            }) catch return;
            continue;
        }
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

fn onFieldFocus(ctrl: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    fieldFocus(ctrl, data, "focus");
}

fn onFieldBlur(ctrl: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    fieldFocus(ctrl, data, "blur");
}

fn fieldFocus(ctrl: *anyopaque, data: ?*anyopaque, what: []const u8) void {
    const s = surfaceOf(data);
    const w = gtk_event_controller_get_widget(ctrl) orelse return;
    const n = nodeOfWidget(s, w) orelse return;
    // Not while the field goes (`removed` takes it out first): the page
    // isn't called back in the middle of its own change.
    if (s.fields.get(n.id) != w) return;
    _ = s.engine.event(n.id, what, "null");
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

/// The slider moved: "input" with the snapped value, once per step.
fn onSlid(sc: *Widget, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    if (s.updating) return;
    const n = nodeOfWidget(s, sc) orelse return;
    const r = tree_mod.Range.of(n);
    const v = r.snap(gtk_range_get_value(sc));
    // GtkScale moves continuously; keep it on the step the page sees.
    if (v != gtk_range_get_value(sc)) {
        s.updating = true;
        gtk_range_set_value(sc, v);
        s.updating = false;
    }
    const steps: usize = tree_mod.sat(u32, @round((v - r.min) / r.step));
    const last: usize = @intFromPtr(g_object_get_data(@ptrCast(sc), "oriel-step"));
    if (last == steps + 1) return; // same step as the last "input"
    g_object_set_data(@ptrCast(sc), "oriel-step", @ptrFromInt(steps + 1));
    var buf: [64]u8 = undefined;
    sendValue(s, n, "input", r.text(&buf, v));
}

/// A drag or key press on a slider ended: "change". A wheel turn is
/// swallowed (it would move the slider under a page being scrolled).
fn onSliderEvent(controller: *anyopaque, event: *anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    const kind = gdk_event_get_event_type(event);
    const scroll = 15; // GDK_SCROLL
    if (kind == scroll) return 1;
    // GDK_BUTTON_RELEASE, GDK_KEY_RELEASE, GDK_TOUCH_END
    if (kind != 3 and kind != 5 and kind != 19) return 0;
    const sc = gtkWidgetOfController(controller) orelse return 0;
    const n = nodeOfWidget(s, sc) orelse return 0;
    const r = tree_mod.Range.of(n);
    var buf: [64]u8 = undefined;
    sendValue(s, n, "change", r.text(&buf, gtk_range_get_value(sc)));
    return 0;
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

/// A key as the DOM names it (KeyboardEvent.key): the named keys, the
/// modifiers, else the character it types (in `buf`).
fn keyName(keyval: c_uint, buf: *[8]u8) ?[]const u8 {
    const name = std.mem.span(gdk_keyval_name(keyval) orelse return null);
    const map = .{
        .{ "Return", "Enter" },        .{ "KP_Enter", "Enter" }, .{ "Escape", "Escape" },             .{ "Tab", "Tab" },            .{ "ISO_Left_Tab", "Tab" },
        .{ "BackSpace", "Backspace" }, .{ "Delete", "Delete" },  .{ "Up", "ArrowUp" },                .{ "Down", "ArrowDown" },     .{ "Left", "ArrowLeft" },
        .{ "Right", "ArrowRight" },    .{ "Home", "Home" },      .{ "End", "End" },                   .{ "Page_Up", "PageUp" },     .{ "Page_Down", "PageDown" },
        .{ "space", " " },             .{ "Insert", "Insert" },  .{ "Shift_L", "Shift" },             .{ "Shift_R", "Shift" },      .{ "Control_L", "Control" },
        .{ "Control_R", "Control" },   .{ "Alt_L", "Alt" },      .{ "Alt_R", "Alt" },                 .{ "Meta_L", "Meta" },        .{ "Meta_R", "Meta" },
        .{ "Super_L", "Meta" },        .{ "Super_R", "Meta" },   .{ "ISO_Level3_Shift", "AltGraph" }, .{ "Caps_Lock", "CapsLock" }, .{ "Menu", "ContextMenu" },
    };
    inline for (map) |m| if (std.mem.eql(u8, name, m[0])) return m[1];
    // F1 … F24.
    if (name.len >= 2 and name.len <= 3 and name[0] == 'F' and std.ascii.isDigit(name[1])) return name;
    const cp = gdk_keyval_to_unicode(keyval);
    if (cp >= 0x20 and cp != 0x7f) {
        const len = std.unicode.utf8Encode(@intCast(cp), buf) catch return null;
        return buf[0..len];
    }
    return null;
}

/// The modifier a modifier key is (modFlags' bit), or 0.
fn modifierBit(name: []const u8) u32 {
    if (std.mem.eql(u8, name, "Shift")) return 1;
    if (std.mem.eql(u8, name, "Control")) return 2;
    if (std.mem.eql(u8, name, "Alt")) return 4;
    if (std.mem.eql(u8, name, "Meta")) return 8;
    return 0;
}

fn onResize(_: *Widget, width: c_int, height: c_int, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    s.engine.resize(@floatFromInt(width), @floatFromInt(height), s.dark);
}

fn onPressed(gesture: *anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    _ = gtk_widget_grab_focus(s.area);
    const token = s.token;
    // :active while the button is down.
    const at = targetAt(s, @floatCast(x), @floatCast(y));
    if (at.node != null) _ = s.engine.event(at.id, "press", "null");
    if (surfaces.get(token) == null) return;
    // A move still waiting goes before the down.
    if (s.move != null) flushMove(s);
    if (surfaces.get(token) == null) return;
    s.buttons |= buttonBit(gtk_gesture_single_get_current_button(gesture));
    _ = sendPointer(s, "down", .{ @floatCast(x), @floatCast(y) }, s.buttons, modFlags(gtk_event_controller_get_current_event_state(gesture)));
}

/// GDK's button number as the DOM's `buttons` bit.
fn buttonBit(button: c_uint) u32 {
    return switch (button) {
        1 => 1,
        3 => 2,
        2 => 4,
        else => 0,
    };
}

const PendingMove = struct { at: [2]f32, buttons: u32, mods: u32 };

/// A pointer event for the page (main.js pointerEvent; docs/native-renderer.md
/// "Pointer and key events"): `phase` down, move, up or cancel at `p` (the
/// widget's coordinates: CSS px), on the node there. True when the page took
/// it (prevented the default).
fn sendPointer(s: *Surface, phase: []const u8, p: [2]f32, buttons: u32, mods: u32) bool {
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return false;
    const nid = targetAt(s, p[0], p[1]).id;
    var buf: [96]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"{s}\",{d:.2},{d:.2},{d},1,\"mouse\",{d}]", .{ phase, p[0], p[1], buttons, mods }) catch return false;
    return s.engine.event(nid, "pointer", json);
}

/// A move waits for the next display frame (the latest one wins), so a
/// 1000 Hz mouse doesn't flood the page.
fn queueMove(s: *Surface, p: [2]f32, buttons: u32, mods: u32) void {
    s.move = .{ .at = p, .buttons = buttons, .mods = mods };
    if (s.tick_id == 0) s.tick_id = gtk_widget_add_tick_callback(s.area, onTick, @ptrFromInt(s.token), null);
}

fn flushMove(s: *Surface) void {
    const m = s.move orelse return;
    s.move = null;
    _ = sendPointer(s, "move", m.at, m.buttons, m.mods);
}

fn onReleased(gesture: *anyopaque, _: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    const token = s.token;
    const button = gtk_gesture_single_get_current_button(gesture);
    // A move still waiting goes first, then the up, then the click.
    if (s.move != null) flushMove(s);
    if (surfaces.get(token) == null) return;
    s.buttons &= ~buttonBit(button);
    _ = sendPointer(s, "up", .{ @floatCast(x), @floatCast(y) }, s.buttons, modFlags(gtk_event_controller_get_current_event_state(gesture)));
    if (surfaces.get(token) == null) return;
    _ = s.engine.event(0, "release", "null");
    const at = targetAt(s, @floatCast(x), @floatCast(y));
    const n = at.node orelse return;
    if (button == 3) {
        var buf: [64]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "[{d:.0},{d:.0}]", .{ x, y }) catch return;
        _ = s.engine.event(at.id, "contextmenu", json);
        return;
    }
    if (button != 1) return;
    if (!at.link and disabledUp(n)) return;
    var buf: [16]u8 = undefined;
    const flags = std.fmt.bufPrint(&buf, "{d}", .{modFlags(gtk_event_controller_get_current_event_state(gesture))}) catch return;
    _ = s.engine.event(at.id, "click", flags);
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

/// What the pointer is over: the node hit, or a link amid its text (Run.k,
/// the link's own id: render.js inlineRuns).
const Target = struct { node: ?*Node, id: i64, link: bool = false };

fn targetAt(s: *Surface, x: f32, y: f32) Target {
    const n = s.engine.tree.hit(x, y) orelse return .{ .node = null, .id = 0 };
    if (n.kind == .text) if (linkAt(s, n, x, y)) |k| return .{ .node = n, .id = k, .link = true };
    return .{ .node = n, .id = n.id };
}

/// A text node's layout as paintText places it: its lines (null: Pango's
/// own, moved down by `dy`).
const Laid = struct {
    layout: *PangoLayout,
    exts: [64]Extent = undefined,
    lines: ?[]const Extent = null,
    dy: f32 = 0,

    fn of(s: *Surface, n: *Node, out: *Laid) bool {
        const c = n.content();
        out.layout = textLayout(s, n, paintWidth(c.w)) orelse return false;
        out.lines = textLines(s, &n.props, out.layout, &out.exts);
        if (out.lines == null) if (cssHeight(s, &n.props, pango_layout_get_line_count(out.layout))) |css_h| {
            var w: c_int = 0;
            var h: c_int = 0;
            pango_layout_get_size(out.layout, &w, &h);
            const pango_h = @as(f32, @floatFromInt(h)) / PANGO_SCALE;
            if (pango_h > css_h) out.dy = (css_h - pango_h) / 2;
        };
        return true;
    }
};

/// Each line of a laid text: its Pango line, its top and bottom and its
/// baseline (y down, the text's coordinates as paintText draws them).
const LaidLines = struct {
    laid: *const Laid,
    it: *anyopaque,
    y: f32,
    k: usize = 0,
    top: f32,
    done: bool = false,

    const Line = struct { line: *anyopaque, top: f32, bottom: f32, base: f32 };

    fn init(laid: *const Laid, y: f32) ?LaidLines {
        const it = pango_layout_get_iter(laid.layout) orelse return null;
        return .{ .laid = laid, .it = it, .y = y + laid.dy, .top = y + laid.dy };
    }
    fn deinit(w: *LaidLines) void {
        pango_layout_iter_free(w.it);
    }
    fn next(w: *LaidLines) ?Line {
        if (w.done) return null;
        const line = pango_layout_iter_get_line_readonly(w.it) orelse return null;
        var out: Line = undefined;
        if (w.laid.lines) |e| {
            if (w.k >= e.len) return null;
            out = .{ .line = line, .top = w.top, .bottom = w.top + e[w.k].top + e[w.k].bottom, .base = w.top + e[w.k].top };
            w.top = out.bottom;
        } else {
            var y0: c_int = 0;
            var y1: c_int = 0;
            pango_layout_iter_get_line_yrange(w.it, &y0, &y1);
            const P: f32 = PANGO_SCALE;
            out = .{ .line = line, .top = w.y + @as(f32, @floatFromInt(y0)) / P, .bottom = w.y + @as(f32, @floatFromInt(y1)) / P, .base = w.y + @as(f32, @floatFromInt(pango_layout_iter_get_baseline(w.it))) / P };
        }
        w.k += 1;
        if (pango_layout_iter_next_line(w.it) == 0) w.done = true;
        return out;
    }
};

/// The link (Run.k) under (x, y) in text node `n`, as paintText lays it out.
fn linkAt(s: *Surface, n: *Node, x: f32, y: f32) ?u32 {
    const runs = n.props.runs orelse return null;
    for (runs) |r| {
        if (r.k != null) break;
    } else return null;
    var laid: Laid = undefined;
    if (!Laid.of(s, n, &laid)) return null;
    defer g_object_unref(laid.layout);
    const c = n.content();
    var lines = LaidLines.init(&laid, c.y) orelse return null;
    defer lines.deinit();
    while (lines.next()) |l| {
        if (y < l.top or y >= l.bottom) continue;
        var index: c_int = 0;
        var trailing: c_int = 0;
        if (pango_layout_line_x_to_index(l.line, tree_mod.sat(c_int, (x - c.x) * PANGO_SCALE), &index, &trailing) == 0) return null;
        var walk: RunBytes = .{ .runs = runs };
        var i: usize = 0;
        while (walk.next()) |range| : (i += 1) {
            if (index >= range[0] and index < range[1]) return runs[i].k;
        }
        return null;
    }
    return null;
}

/// Backend.run_rects: the line fragments of runs [first..last] of text node
/// `n` (an inline element's getClientRects): per line, from the first run's
/// start to the last's end (not the space it wraps at), as tall as the
/// runs' own fonts there (ascent and descent, rounded), not the line box.
fn runRects(ctx: *anyopaque, n: *Node, first: usize, last: usize, out: [][4]f32) usize {
    const s = surfaceOf(ctx);
    const runs = n.props.runs orelse return 0;
    if (first > last or last >= runs.len) return 0;
    var bytes: [2]usize = .{ 0, 0 };
    var spans: [64][2]usize = undefined; // each run's bytes, first..last
    {
        var walk: RunBytes = .{ .runs = runs };
        var i: usize = 0;
        while (walk.next()) |range| : (i += 1) {
            if (i == first) bytes[0] = range[0];
            if (i >= first and i <= last and i - first < spans.len) spans[i - first] = range;
            if (i == last) {
                bytes[1] = range[1];
                break;
            }
        }
    }
    if (bytes[1] <= bytes[0]) return 0;
    var laid: Laid = undefined;
    if (!Laid.of(s, n, &laid)) return 0;
    defer g_object_unref(laid.layout);
    const text = std.mem.span(pango_layout_get_text(laid.layout));
    const c = n.content();
    var lines = LaidLines.init(&laid, c.y) orelse return 0;
    defer lines.deinit();
    var k: usize = 0;
    while (lines.next()) |l| {
        if (k >= out.len) break;
        const head: *const PangoLayoutLineHead = @ptrCast(@alignCast(l.line));
        const ls: usize = @intCast(@max(0, head.start_index));
        const le: usize = @min(text.len, ls + @as(usize, @intCast(@max(0, head.length))));
        const a = @max(bytes[0], ls);
        var b = @min(bytes[1], le);
        if (a >= b) continue;
        // A fragment that wraps: not the space it wraps after.
        if (b < bytes[1]) while (b > a and (text[b - 1] == ' ' or text[b - 1] == '\n')) {
            b -= 1;
        };
        if (a >= b) continue;
        var ranges: ?[*]c_int = null;
        var count: c_int = 0;
        pango_layout_line_get_x_ranges(l.line, tree_mod.sat(c_int, a), tree_mod.sat(c_int, b), &ranges, &count);
        const rs = ranges orelse continue;
        defer g_free(@ptrCast(rs));
        var x0: f32 = std.math.floatMax(f32);
        var x1: f32 = -std.math.floatMax(f32);
        for (0..@intCast(@max(0, count))) |q| {
            x0 = @min(x0, @as(f32, @floatFromInt(rs[2 * q])) / PANGO_SCALE);
            x1 = @max(x1, @as(f32, @floatFromInt(rs[2 * q + 1])) / PANGO_SCALE);
        }
        if (!(x1 >= x0)) continue;
        // The runs' own fonts on this line.
        var ascent: f32 = 0;
        var descent: f32 = 0;
        for (first..last + 1) |ri| {
            if (ri - first >= spans.len) break;
            const sp = spans[ri - first];
            if (sp[1] <= a or sp[0] >= b) continue;
            const r = runs[ri];
            const m = unhintedMetrics(s, r.sz, r.mono or n.props.mono, r.ff orelse n.props.ff) orelse continue;
            ascent = @max(ascent, @round(m[0]));
            descent = @max(descent, @round(m[1]));
        }
        out[k] = .{ c.x + x0, l.base - ascent, x1 - x0, ascent + descent };
        k += 1;
    }
    return k;
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

fn onMotion(controller: *anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    s.pointer = .{ @floatCast(x), @floatCast(y) };
    queueMove(s, s.pointer, s.buttons, modFlags(gtk_event_controller_get_current_event_state(controller)));
    const at = targetAt(s, s.pointer[0], s.pointer[1]);
    const n = at.node;
    gtk_widget_set_cursor_from_name(s.area, if (at.link or (n != null and clickableUp(n.?))) "pointer" else null);
    // :hover: the page hears when the node under the pointer changes.
    const id: i64 = at.id;
    if (id != s.hovered) {
        s.hovered = id;
        _ = s.engine.event(id, "hover", "null");
    }
}

// ---------------------------------------------------------------------------
// Drag and drop (docs/drag-and-drop-design.md, sections 1 and 5): drops
// into the page. The page answers each enter and motion with an effect
// mask (Engine.dragEvent), which GTK gets as one action. A drop's data
// comes asynchronously: it's read (files opened into the engine's table,
// drop.zig), then sent to the page as "drop", and the drop is finished
// with the last motion's action: on GTK the page can't change its mind
// at drop time.

const GSList = extern struct { data: ?*anyopaque, next: ?*GSList };
const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };
const GAsyncReadyCallback = *const fn (?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void;
extern fn gtk_widget_observe_controllers(w: *Widget) *anyopaque;
extern fn gtk_widget_remove_controller(w: *Widget, controller: *anyopaque) void;
extern fn gtk_widget_get_first_child(w: *Widget) ?*Widget;
extern fn gtk_widget_get_next_sibling(w: *Widget) ?*Widget;
extern fn g_list_model_get_n_items(list: *anyopaque) c_uint;
extern fn g_list_model_get_item(list: *anyopaque, position: c_uint) ?*anyopaque;
extern fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;
extern fn gtk_drop_target_get_type() usize;
extern fn gtk_drop_target_async_get_type() usize;

/// A native field's own drop targets (GtkText's, GtkTextView's) go: they
/// took a file drag's text, the file's path, into the field without the
/// page seeing the drag. Drags over a field now reach the overlay's target,
/// and a text drop goes in through the page's drop (dnd.js default insert).
fn stripDropTargets(w: *Widget) void {
    var found: [8]*anyopaque = undefined;
    var n: usize = 0;
    const list = gtk_widget_observe_controllers(w);
    const count = g_list_model_get_n_items(list);
    var i: c_uint = 0;
    while (i < count and n < found.len) : (i += 1) {
        const c = g_list_model_get_item(list, i) orelse continue;
        defer g_object_unref(c);
        if (g_type_check_instance_is_a(c, gtk_drop_target_get_type()) != 0 or
            g_type_check_instance_is_a(c, gtk_drop_target_async_get_type()) != 0)
        {
            found[n] = c;
            n += 1;
        }
    }
    // Removed after the walk: removing changes the observed list. The
    // widget still holds them until then, so the pointers stay valid.
    for (found[0..n]) |c| gtk_widget_remove_controller(w, c);
    g_object_unref(list);
    var child = gtk_widget_get_first_child(w);
    while (child) |ch| : (child = gtk_widget_get_next_sibling(ch)) stripDropTargets(ch);
}

extern fn gtk_drop_target_async_new(formats: ?*anyopaque, actions: c_uint) *anyopaque;
extern fn gdk_content_formats_builder_new() *anyopaque;
extern fn gdk_content_formats_builder_add_gtype(b: *anyopaque, gtype: usize) void;
extern fn gdk_content_formats_builder_add_mime_type(b: *anyopaque, mime: [*:0]const u8) void;
extern fn gdk_content_formats_builder_free_to_formats(b: *anyopaque) *anyopaque;
extern fn gdk_content_formats_contain_gtype(formats: *anyopaque, gtype: usize) c_int;
extern fn gdk_content_formats_contain_mime_type(formats: *anyopaque, mime: [*:0]const u8) c_int;
extern fn gdk_file_list_get_type() usize;
extern fn gdk_file_list_get_files(list: *anyopaque) ?*GSList;
extern fn gdk_drop_get_formats(drop: *anyopaque) *anyopaque;
extern fn gdk_drop_get_actions(drop: *anyopaque) c_uint;
extern fn gdk_drop_finish(drop: *anyopaque, action: c_uint) void;
extern fn gdk_drop_read_async(drop: *anyopaque, mime_types: [*]const ?[*:0]const u8, io_priority: c_int, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, data: ?*anyopaque) void;
extern fn gdk_drop_read_finish(drop: *anyopaque, result: *anyopaque, out_mime_type: ?*?[*:0]const u8, err: *?*GError) ?*anyopaque;
extern fn gdk_drop_read_value_async(drop: *anyopaque, gtype: usize, io_priority: c_int, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, data: ?*anyopaque) void;
extern fn gdk_drop_read_value_finish(drop: *anyopaque, result: *anyopaque, err: *?*GError) ?*const anyopaque;
extern fn g_value_get_boxed(value: *const anyopaque) ?*anyopaque;
extern fn g_object_ref(obj: *anyopaque) *anyopaque;
extern fn g_input_stream_read_bytes_async(stream: *anyopaque, count: usize, io_priority: c_int, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, data: ?*anyopaque) void;
extern fn g_input_stream_read_bytes_finish(stream: *anyopaque, result: *anyopaque, err: *?*GError) ?*anyopaque;
extern fn g_bytes_get_data(bytes: *anyopaque, size: *usize) ?[*]const u8;
extern fn g_file_get_path(file: *anyopaque) ?[*:0]u8;
extern fn g_content_type_guess(filename: ?[*:0]const u8, data: ?[*]const u8, size: usize, uncertain: ?*c_int) ?[*:0]u8;
extern fn g_content_type_get_mime_type(content_type: [*:0]const u8) ?[*:0]u8;
extern fn g_slist_free(list: ?*GSList) void;

/// GdkDragAction's bits are the page's (copy 1, move 2, link 4); ask 8.
const gdk_action_ask: c_uint = 8;
/// At most this many items in a drop, and this long a string (larger
/// ones are left out and logged).
const drag_max_items = 4096;
const drag_max_string = 16 * 1024 * 1024;

/// The text types a drop target takes besides the file list; each list
/// is one read (gdk_drop_read_async takes the first the drag has).
const drop_plain_mimes = [_]?[*:0]const u8{ "text/plain;charset=utf-8", "text/plain", null };
const drop_uri_mimes = [_]?[*:0]const u8{ "text/uri-list", null };
const drop_html_mimes = [_]?[*:0]const u8{ "text/html", null };

fn newDropTarget() *anyopaque {
    const b = gdk_content_formats_builder_new();
    gdk_content_formats_builder_add_gtype(b, gdk_file_list_get_type());
    for ([_][*:0]const u8{ "text/plain;charset=utf-8", "text/plain", "text/uri-list", "text/html" }) |m| gdk_content_formats_builder_add_mime_type(b, m);
    // The target owns the formats.
    return gtk_drop_target_async_new(gdk_content_formats_builder_free_to_formats(b), 1 | 2 | 4);
}

/// What a drag carries, as the page's DataTransfer types.
const DragKinds = struct {
    files: bool = false,
    plain: bool = false,
    uri_list: bool = false,
    html: bool = false,

    fn of(formats: *anyopaque) DragKinds {
        const has = struct {
            fn f(fm: *anyopaque, mime: [*:0]const u8) bool {
                return gdk_content_formats_contain_mime_type(fm, mime) != 0;
            }
        }.f;
        const uri_list = has(formats, "text/uri-list");
        // A link dragged out of a browser is a text/uri-list too, with
        // Mozilla's types beside it (Firefox and Chromium both offer them).
        const link = has(formats, "text/x-moz-url") or has(formats, "_NETSCAPE_URL");
        return .{
            .files = gdk_content_formats_contain_gtype(formats, gdk_file_list_get_type()) != 0 or
                has(formats, "application/vnd.portal.filetransfer") or has(formats, "application/vnd.portal.files") or
                (uri_list and !link),
            .plain = has(formats, "text/plain;charset=utf-8") or has(formats, "text/plain"),
            .uri_list = uri_list,
            .html = has(formats, "text/html"),
        };
    }

    /// The strings the page sees: none with files, as in Chrome, since a
    /// file manager's text/plain and text/uri-list are the files' paths.
    fn strings(k: DragKinds) [3]?[]const u8 {
        if (k.files) return .{ null, null, null };
        return .{
            if (k.plain) "text/plain" else null,
            if (k.uri_list) "text/uri-list" else null,
            if (k.html) "text/html" else null,
        };
    }

    /// enter's items: [[kind, type], ...].
    fn writeItems(k: DragKinds, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.append(gpa, '[');
        var first = true;
        if (k.files) {
            try out.appendSlice(gpa, "[\"file\",\"\"]");
            first = false;
        }
        for (k.strings()) |mime| if (mime) |m| {
            if (!first) try out.append(gpa, ',');
            first = false;
            try out.print(gpa, "[\"string\",\"{s}\"]", .{m});
        };
        try out.append(gpa, ']');
    }
};

/// The drop's allowed actions as the page's mask. GDK reports one action
/// (the source picked it with the modifiers) unless the source asks.
fn allowedActions(actions: c_uint) u8 {
    const m: u8 = @intCast(actions & 7);
    if (m == 0 and actions & gdk_action_ask != 0) return 7;
    return m;
}

/// The OS's preferred operation: the one allowed action, else the
/// modifiers' (ctrl+shift link, ctrl copy, shift move), else copy, move,
/// link in that order.
fn suggestedAction(allowed: u8, mods: u32) u8 {
    if (allowed == 0) return 0;
    if (std.math.isPowerOfTwo(allowed)) return allowed;
    const ctrl = mods & 2 != 0;
    const shift = mods & 1 != 0;
    const wanted: u8 = if (ctrl and shift) 4 else if (ctrl) 1 else if (shift) 2 else 0;
    if (wanted & allowed != 0) return wanted;
    return firstAction(allowed);
}

fn firstAction(mask: u8) u8 {
    inline for (.{ 1, 2, 4 }) |a| if (mask & a != 0) return a;
    return 0;
}

/// The page's effect mask as the one action GTK is told: the suggested
/// one if the page allows it, else its first (0: no drop here).
fn pickAction(mask: u8, allowed: u8, suggested: u8) c_uint {
    const m = mask & allowed;
    if (m & suggested != 0) return suggested;
    return firstAction(m);
}

fn onDragAccept(_: *anyopaque, _: *anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    // Every drag: the page decides (its dragover), not the formats.
    return 1;
}

fn onDragEnter(target: *anyopaque, drop: *anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_uint {
    const s = surfaceOf(data);
    s.drag_session +%= 1;
    s.drag_inside = true;
    s.drag_kinds = DragKinds.of(gdk_drop_get_formats(drop));
    return dragOver(s, target, drop, x, y, true);
}

fn onDragMotion(target: *anyopaque, drop: *anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_uint {
    const s = surfaceOf(data);
    if (!s.drag_inside) return onDragEnter(target, drop, x, y, data);
    return dragOver(s, target, drop, x, y, false);
}

/// "enter" or "over" on the node under the pointer: the page's answer as
/// GTK's action (0 when it doesn't take the drag there).
fn dragOver(s: *Surface, target: *anyopaque, drop: *anyopaque, x: f64, y: f64, enter: bool) c_uint {
    const token = s.token;
    const p: [2]f32 = .{ @floatCast(x), @floatCast(y) };
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return s.drag_action;
    const allowed = allowedActions(gdk_drop_get_actions(drop));
    const mods = modFlags(gtk_event_controller_get_current_event_state(target));
    const suggested = suggestedAction(allowed, mods);
    const nid: i64 = if (s.engine.tree.hit(p[0], p[1])) |n| n.id else 0;
    // Not s.gpa in the defer: the page may close its window (freeing `s`)
    // inside dragEvent.
    const gpa = s.gpa;
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    json.print(gpa, "[\"{s}\",{d:.2},{d:.2},{d},{d},{d},{d}", .{ if (enter) "enter" else "over", p[0], p[1], allowed, suggested, mods, s.drag_session }) catch return 0;
    if (enter) {
        json.append(gpa, ',') catch return 0;
        s.drag_kinds.writeItems(gpa, &json) catch return 0;
    }
    json.append(gpa, ']') catch return 0;
    const mask = s.engine.dragEvent(nid, json.items);
    if (surfaces.get(token) == null) return 0; // the page closed its window
    s.drag_action = pickAction(mask, allowed, suggested);
    return s.drag_action;
}

fn onDragLeave(_: *anyopaque, _: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    // GTK emits drag-leave after a drop too: that drag ends with its drop.
    if (!s.drag_inside) return;
    s.drag_inside = false;
    s.drag_action = 0;
    sendDragLeave(s, s.drag_session);
}

fn sendDragLeave(s: *Surface, session: u32) void {
    var buf: [32]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[\"leave\",{d}]", .{session}) catch return;
    _ = s.engine.dragEvent(0, json);
}

fn onDrop(target: *anyopaque, drop: *anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    if (!s.drag_inside) return 0;
    s.drag_inside = false;
    const action = s.drag_action;
    s.drag_action = 0;
    // The page took no drop here: the drag just leaves.
    if (action == 0 or !std.math.isFinite(x) or !std.math.isFinite(y)) {
        sendDragLeave(s, s.drag_session);
        return 0;
    }
    const allowed = allowedActions(gdk_drop_get_actions(drop));
    const mods = modFlags(gtk_event_controller_get_current_event_state(target));
    const job = s.gpa.create(DropJob) catch {
        sendDragLeave(s, s.drag_session);
        return 0;
    };
    job.* = .{
        .gpa = s.gpa,
        .token = s.token,
        .drop = g_object_ref(drop),
        .at = .{ @floatCast(x), @floatCast(y) },
        .allowed = allowed,
        .suggested = suggestedAction(allowed, mods),
        .mods = mods,
        .session = s.drag_session,
        .action = action,
        .kinds = s.drag_kinds,
    };
    dropNext(job);
    return 1;
}

/// A drop being read: the file list, then each string, then "drop" to
/// the page and gdk_drop_finish. Each callback finds its surface by
/// token: a window that closed meanwhile gets nothing (the drop is
/// finished with no action).
const DropJob = struct {
    gpa: std.mem.Allocator,
    token: u64,
    drop: *anyopaque,
    at: [2]f32,
    allowed: u8,
    suggested: u8,
    mods: u32,
    session: u32,
    action: c_uint,
    kinds: DragKinds,
    /// The next step to try, and the string being read (its type).
    step: Step = .files,
    reading: []const u8 = "",
    /// The items' JSON so far, comma-separated, and how many.
    items: std.ArrayList(u8) = .empty,
    count: usize = 0,
    stream: ?*anyopaque = null,
    text: std.ArrayList(u8) = .empty,

    const Step = enum { files, plain, uri_list, html, done };

    fn deinit(job: *DropJob) void {
        if (job.stream) |st| g_object_unref(st);
        job.items.deinit(job.gpa);
        job.text.deinit(job.gpa);
        g_object_unref(job.drop);
        job.gpa.destroy(job);
    }

    /// Room for one more item (a comma before it).
    fn startItem(job: *DropJob) !bool {
        if (job.count >= drag_max_items) {
            if (job.count == drag_max_items) log.warn("native ui: a drop of more than {d} items: the rest left out", .{drag_max_items});
            job.count = drag_max_items + 1;
            return false;
        }
        if (job.count > 0) try job.items.append(job.gpa, ',');
        job.count += 1;
        return true;
    }
};

fn dropNext(job: *DropJob) void {
    while (true) {
        const step = job.step;
        if (step != .done) job.step = @enumFromInt(@intFromEnum(step) + 1);
        const strings = job.kinds.strings();
        switch (step) {
            .files => if (job.kinds.files) {
                gdk_drop_read_value_async(job.drop, gdk_file_list_get_type(), 0, null, onDropFiles, job);
                return;
            },
            .plain => if (strings[0]) |m| return dropReadText(job, m, &drop_plain_mimes),
            .uri_list => if (strings[1]) |m| return dropReadText(job, m, &drop_uri_mimes),
            .html => if (strings[2]) |m| return dropReadText(job, m, &drop_html_mimes),
            .done => return dropDeliver(job),
        }
    }
}

fn logGError(what: []const u8, err: ?*GError) void {
    const e = err orelse return;
    log.warn("native ui: a drop's {s}: {s}", .{ what, if (e.message) |m| std.mem.span(m) else "?" });
    g_error_free(e);
}

fn onDropFiles(_: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const job: *DropJob = @ptrCast(@alignCast(data.?));
    var err: ?*GError = null;
    const value = gdk_drop_read_value_finish(job.drop, result, &err);
    logGError("files", err);
    const s = surfaces.get(job.token) orelse return dropAbandon(job);
    if (value) |v| if (g_value_get_boxed(v)) |list| dropAddFiles(job, s, list);
    dropNext(job);
}

/// Each file with a path (gvfs ones without are skipped) opened into the
/// engine's table: ["file", mime, name, size, lastModifiedMs, handle].
fn dropAddFiles(job: *DropJob, s: *Surface, list: *anyopaque) void {
    const files = gdk_file_list_get_files(list);
    defer g_slist_free(files);
    var it = files;
    while (it) |node| : (it = node.next) {
        const file = node.data orelse continue;
        const path_c = g_file_get_path(file) orelse continue;
        defer g_free(path_c);
        const path = std.mem.span(path_c);
        const handle = (s.engine.drops.addPath(path) catch |err| {
            log.warn("native ui: a dropped file: {s}", .{@errorName(err)});
            continue;
        }) orelse continue; // not a regular file (a directory)
        const info = s.engine.drops.info(handle).?;
        const name = std.fs.path.basename(path);
        const added = dropFileItem(job, name, info, handle) catch false;
        if (!added) s.engine.drops.release(handle);
        if (job.count > drag_max_items) break;
    }
}

fn dropFileItem(job: *DropJob, name: []const u8, info: engine_mod.drop.Entry, handle: u32) !bool {
    if (!try job.startItem()) return false;
    const mime = try guessMime(job.gpa, name);
    defer job.gpa.free(mime);
    try job.items.appendSlice(job.gpa, "[\"file\",");
    try appendJsonString(job.gpa, &job.items, mime);
    try job.items.append(job.gpa, ',');
    try appendJsonString(job.gpa, &job.items, name);
    try job.items.print(job.gpa, ",{d},{d},{d}]", .{ info.size, info.mtimeMs(), handle });
    return true;
}

/// A file's MIME type from its name, as browsers give it ("" when unknown).
fn guessMime(gpa: std.mem.Allocator, name: []const u8) ![]u8 {
    const name_z = try gpa.dupeZ(u8, name);
    defer gpa.free(name_z);
    var uncertain: c_int = 0;
    const ct = g_content_type_guess(name_z, null, 0, &uncertain) orelse return gpa.dupe(u8, "");
    defer g_free(ct);
    const mime = g_content_type_get_mime_type(ct) orelse return gpa.dupe(u8, "");
    defer g_free(mime);
    const m = std.mem.span(mime);
    if (std.mem.eql(u8, m, "application/octet-stream")) return gpa.dupe(u8, "");
    return gpa.dupe(u8, m);
}

fn dropReadText(job: *DropJob, label: []const u8, mimes: [*]const ?[*:0]const u8) void {
    job.reading = label;
    gdk_drop_read_async(job.drop, mimes, 0, null, onDropStream, job);
}

fn onDropStream(_: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const job: *DropJob = @ptrCast(@alignCast(data.?));
    var err: ?*GError = null;
    job.stream = gdk_drop_read_finish(job.drop, result, null, &err);
    logGError(job.reading, err);
    if (surfaces.get(job.token) == null) return dropAbandon(job);
    if (job.stream == null) return dropNext(job);
    job.text.clearRetainingCapacity();
    g_input_stream_read_bytes_async(job.stream.?, 64 * 1024, 0, null, onDropChunk, job);
}

fn onDropChunk(_: ?*anyopaque, result: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    const job: *DropJob = @ptrCast(@alignCast(data.?));
    var err: ?*GError = null;
    const bytes = g_input_stream_read_bytes_finish(job.stream.?, result, &err);
    logGError(job.reading, err);
    defer if (bytes) |b| g_bytes_unref(b);
    if (surfaces.get(job.token) == null) return dropAbandon(job);
    var size: usize = 0;
    const ptr = if (bytes) |b| g_bytes_get_data(b, &size) else null;
    const done = bytes == null or size == 0;
    var keep = bytes != null;
    if (!done) {
        if (job.text.items.len + size > drag_max_string) {
            log.warn("native ui: a dropped {s} over {d} MiB left out", .{ job.reading, drag_max_string >> 20 });
            keep = false;
        } else if (job.text.appendSlice(job.gpa, ptr.?[0..size])) |_| {
            return g_input_stream_read_bytes_async(job.stream.?, 64 * 1024, 0, null, onDropChunk, job);
        } else |_| keep = false;
    }
    g_object_unref(job.stream.?);
    job.stream = null;
    if (keep) dropStringItem(job) catch {};
    dropNext(job);
}

/// ["string", type, value]: the text as UTF-8 (UTF-16 with a BOM, as
/// Firefox gives text/html, converted; invalid bytes as U+FFFD).
fn dropStringItem(job: *DropJob) !void {
    const text = try dropText(job.gpa, job.text.items);
    defer job.gpa.free(text);
    if (!try job.startItem()) return;
    try job.items.appendSlice(job.gpa, "[\"string\",");
    try appendJsonString(job.gpa, &job.items, job.reading);
    try job.items.append(job.gpa, ',');
    try appendJsonString(job.gpa, &job.items, text);
    try job.items.append(job.gpa, ']');
}

/// Dropped text as UTF-8 (owned): UTF-16LE when it starts with its BOM,
/// a UTF-8 BOM and trailing NULs dropped.
fn dropText(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var bytes = raw;
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe) {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var i: usize = 2;
        while (i + 1 < bytes.len) {
            const u: u21 = std.mem.readInt(u16, bytes[i..][0..2], .little);
            i += 2;
            var cp: u21 = u;
            if (u >= 0xd800 and u < 0xdc00 and i + 1 < bytes.len) {
                const lo: u21 = std.mem.readInt(u16, bytes[i..][0..2], .little);
                if (lo >= 0xdc00 and lo < 0xe000) {
                    cp = 0x10000 + ((u - 0xd800) << 10) + (lo - 0xdc00);
                    i += 2;
                } else cp = 0xfffd;
            } else if (u >= 0xd800 and u < 0xe000) cp = 0xfffd;
            if (cp == 0 and i >= bytes.len) break; // a trailing NUL
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
            try out.appendSlice(gpa, buf[0..n]);
        }
        while (out.items.len > 0 and out.items[out.items.len - 1] == 0) out.items.len -= 1;
        return out.toOwnedSlice(gpa);
    }
    if (std.mem.startsWith(u8, bytes, "\xef\xbb\xbf")) bytes = bytes[3..];
    while (bytes.len > 0 and bytes[bytes.len - 1] == 0) bytes = bytes[0 .. bytes.len - 1];
    return utf8Lossy(gpa, bytes);
}

/// A copy of `s` with each invalid UTF-8 sequence as U+FFFD.
fn utf8Lossy(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(s)) return gpa.dupe(u8, s);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch 0;
        if (len > 0 and i + len <= s.len and !std.meta.isError(std.unicode.utf8Decode(s[i .. i + len]))) {
            try out.appendSlice(gpa, s[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// `s` as a JSON string (valid UTF-8: invalid bytes as U+FFFD).
fn appendJsonString(gpa: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    const clean = try utf8Lossy(gpa, s);
    defer gpa.free(clean);
    const quoted = try std.json.Stringify.valueAlloc(gpa, clean, .{});
    defer gpa.free(quoted);
    try out.appendSlice(gpa, quoted);
}

/// Everything read: "drop" on the node under the drop point, then the
/// drop finished with the action GTK was last told.
fn dropDeliver(job: *DropJob) void {
    const s = surfaces.get(job.token) orelse return dropAbandon(job);
    const gpa = job.gpa; // the job goes before the JSON
    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    json.print(gpa,"[\"drop\",{d:.2},{d:.2},{d},{d},{d},{d},[{s}]]", .{ job.at[0], job.at[1], job.allowed, job.suggested, job.mods, job.session, job.items.items }) catch {
        sendDragLeave(s, job.session);
        return dropAbandon(job);
    };
    const nid: i64 = if (s.engine.tree.hit(job.at[0], job.at[1])) |n| n.id else 0;
    // Async here: the page's answer can't change the action any more.
    _ = s.engine.dragEvent(nid, json.items);
    gdk_drop_finish(job.drop, job.action);
    job.deinit();
}

/// The window went (or the drop couldn't be read): finished, no action.
fn dropAbandon(job: *DropJob) void {
    gdk_drop_finish(job.drop, 0);
    job.deinit();
}

fn onKey(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    return @intFromBool(keyDown(surfaceOf(data), keyval, state));
}

/// A key pressed: keydown on the focused element (the page's view's or a
/// native field's), true when the page prevented it (the key is used up).
fn keyDown(s: *Surface, keyval: c_uint, state: c_uint) bool {
    var name_buf: [8]u8 = undefined;
    const name = keyName(keyval, &name_buf) orelse return false;
    const key = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return false;
    defer s.gpa.free(key);
    // GTK reports auto-repeat as more presses: a key already down repeats.
    const repeat = s.keys_down.contains(keyval);
    s.keys_down.put(s.gpa, keyval, {}) catch {};
    // A modifier's own keydown has its flag set, as in browsers (GTK's
    // state is from before the press).
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{s},{d},{}]", .{ key, modFlags(state) | modifierBit(name), repeat }) catch return false;
    return s.engine.event(0, "key", json);
}

/// Keys while a native field has the keyboard (the overlay's capture
/// controller hears them before the field): keydown on the page first, as
/// a WebView's field sends them; a prevented key doesn't reach the field.
/// The page's view hears its own keys (onKey). An input method composing
/// in the field still gets its keys unless the page prevents them.
fn onFieldKey(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const s = surfaceOf(data);
    if (gtk_widget_has_focus(s.area) != 0) return 0;
    return @intFromBool(keyDown(s, keyval, state));
}

fn onFieldKeyUp(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) void {
    const s = surfaceOf(data);
    if (gtk_widget_has_focus(s.area) != 0) return;
    keyUp(s, keyval, state);
}

fn onKeyUp(_: *anyopaque, keyval: c_uint, _: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) void {
    keyUp(surfaceOf(data), keyval, state);
}

fn keyUp(s: *Surface, keyval: c_uint, state: c_uint) void {
    _ = s.keys_down.remove(keyval);
    var name_buf: [8]u8 = undefined;
    const name = keyName(keyval, &name_buf) orelse return;
    const key = std.json.Stringify.valueAlloc(s.gpa, name, .{}) catch return;
    defer s.gpa.free(key);
    // A modifier's keyup has its flag cleared.
    var buf: [64]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "[{s},{d}]", .{ key, modFlags(state) & ~modifierBit(name) }) catch return;
    _ = s.engine.event(0, "keyup", json);
}

// ---------------------------------------------------------------------------
// Text

fn measure(ctx: *anyopaque, n: *Node, max_width: f32, out: *[2]f32) void {
    const s = surfaceOf(ctx);
    switch (n.kind) {
        .text => {
            const context = gtk_widget_get_pango_context(s.area);
            const serial = pango_context_get_serial(context);
            if (s.text_context != context or s.text_serial != serial) {
                s.text_measurements.clear(s.gpa);
                clearGlyphWidths(s);
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
        .input, .select, .textarea => {
            out.* = fieldSize(s, n, max_width);
            // A one-line field's baseline from its middle (tree.zig
            // baselineFn): its font's line centered there, as WebKitGTK
            // lays out a text field's line in a line of text.
            if (n.kind != .textarea) n.baseline = fieldBaseline(s, n) orelse std.math.nan(f32);
        },
        else => out.* = .{ 0, 0 },
    }
}

fn fieldBaseline(s: *Surface, n: *const Node) ?f32 {
    const m = unhintedMetrics(s, n.props.fz orelse 13.333, n.props.mono, n.props.ff) orelse return null;
    const asc = @round(m[0]);
    const desc = @round(m[1]);
    const line = asc + desc + @round(m[2]);
    return @floor((line - (asc + desc)) / 2) + asc - line / 2;
}

/// Also sets `Node.baseline`: the first line's, where paintText puts it
/// (the top of its extent), for rows that line items up on it.
fn measuredText(s: *Surface, n: *Node, width: f32) ?[2]f32 {
    const actual_width = if (n.props.nowrap or std.math.isInf(width)) std.math.inf(f32) else @max(1, width);
    // Every line's extent alike (no bigger font on some lines only): the
    // first baseline whatever the width, and sizes the cache can keep.
    const all = if (lineBox(s, &n.props) != null) textExtent(s, &n.props) else null;
    const even = if (all) |e| if (strutExtent(s, &n.props)) |st| st.top == e.top and st.bottom == e.bottom else false else true;
    n.baseline = if (all) |e| e.top else std.math.nan(f32);
    // One line of plain text: its width from the glyph widths, no layout.
    if (fastTextSize(s, &n.props)) |size| if (std.math.isInf(actual_width) or size[0] <= actual_width) {
        if (std.c.getenv("ORIEL_NUI_TEXT_CHECK") != null) checkTextSize(s, n, actual_width, size);
        return size;
    };
    var buf: [1024]u8 = undefined;
    const key = if (even) text_measure_cache.keyFor(&buf, &n.props, actual_width) else null;
    if (key) |k| if (s.text_measurements.get(k)) |size| return size;
    const layout = textLayout(s, n, actual_width) orelse return null;
    defer g_object_unref(layout);
    var w: c_int = 0;
    var h: c_int = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    var wu: c_int = 0;
    var hu: c_int = 0;
    pango_layout_get_size(layout, &wu, &hu);
    var exts: [64]Extent = undefined;
    const css_h = if (lineExtents(s, &n.props, layout, &exts)) |e| blk: {
        n.baseline = e[0].top;
        break :blk extentsHeight(e);
    } else cssHeight(s, &n.props, pango_layout_get_line_count(layout));
    const size: [2]f32 = .{ textWidth(wu), css_h orelse @floatFromInt(h) };
    if (key) |k| s.text_measurements.put(s.gpa, k, size) catch {};
    return size;
}

/// CSS's line-height makes each line box exactly that tall, the glyphs
/// centered in it, even when that's less than the font (a 36px heading
/// with 23.2px lines). Pango keeps lines no shorter than its own minimum,
/// so the height is the lines times the line-height (null without one),
/// and paintText centers Pango's lines in it.
/// A field's content box as WebKitGTK sizes it: a text field `cols`
/// (size, 20) digits wide and 6 px more, a textarea `cols` digits by `rows`
/// lines, a select its longest option and its arrow, a line of the font's
/// normal height.
fn fieldSize(s: *Surface, n: *Node, max_width: f32) [2]f32 {
    const fz = n.props.fz orelse 16;
    const m = unhintedMetrics(s, fz, n.props.mono, n.props.ff) orelse [4]f32{ fz * 0.8, fz * 0.25, 0, fz * 0.55 };
    const line = @round(m[0]) + @round(m[1]) + @round(m[2]);
    const cols = n.props.cols orelse 20;
    var size: [2]f32 = switch (n.kind) {
        .textarea => .{ cols * m[3], line * (n.props.rows orelse 2) },
        .select => .{ longestOption(s, n) + 16, line },
        else => .{ cols * m[3] + 6, line },
    };
    if (!std.math.isInf(max_width) and n.kind != .textarea) size[0] = @min(size[0], max_width);
    return size;
}

/// The widest option label of a select, in its font.
fn longestOption(s: *Surface, n: *Node) f32 {
    const opts = n.props.options orelse return 0;
    const layout = gtk_widget_create_pango_layout(s.area, null);
    defer g_object_unref(layout);
    pango_layout_set_font_description(layout, fontDesc(s, n.props.fz orelse 16, n.props.mono, n.props.ff));
    var widest: f32 = 0;
    for (opts) |o| {
        pango_layout_set_text(layout, o[1].ptr, @intCast(o[1].len));
        var w: c_int = 0;
        var h: c_int = 0;
        pango_layout_get_size(layout, &w, &h);
        widest = @max(widest, @as(f32, @floatFromInt(w)) / PANGO_SCALE);
    }
    return @ceil(widest);
}

fn cssHeight(s: *Surface, props: *const tree_mod.Props, lines: c_int) ?f32 {
    const lh = lineBox(s, props) orelse return null;
    return lh * @as(f32, @floatFromInt(@max(1, lines)));
}

// ---------------------------------------------------------------------------
// Plain text without a layout: one run of printable ASCII on one line is as
// wide as its glyphs, each as wide as Pango makes it before the next one
// (its advance with the pair's kerning, rounded to whole pixels as Pango's
// positions are by default). Those widths are measured once per font and
// pair, with Pango itself: width("ab") - width("b"). A pair Pango makes one
// glyph (a ligature), more than one run, letter spacing, other characters
// or a text that wraps take Pango's layout. ORIEL_NUI_TEXT_CHECK=1 measures
// both and logs any difference.

const FontKey = struct { mono: bool, italic: bool, weight: u16, size: u32, fz: u32, lh: i32, family: u64 };
const pair_unknown: i32 = -1;
const pair_ligature: i32 = -2;
const PairWidths = struct {
    /// Single-line height in pixels (0: not measured yet).
    height: c_int = 0,
    /// [a][b]: a's width in Pango units before b (b = 128: at the end).
    w: [128][129]i32 = @splat(@splat(pair_unknown)),
};

fn clearGlyphWidths(s: *Surface) void {
    var it = s.glyph_widths.valueIterator();
    while (it.next()) |t| s.gpa.destroy(t.*);
    s.glyph_widths.clearRetainingCapacity();
}

fn fastTextSize(s: *Surface, props: *const tree_mod.Props) ?[2]f32 {
    const runs = props.runs orelse return null;
    if (runs.len != 1 or props.ls != null) return null;
    const r = runs[0];
    // An inline box's room is a layout's (textLayoutOf).
    if (r.ib != null) return null;
    const t = r.t;
    if (t.len == 0 or t.len > 512) return null;
    for (t) |c| if (c < 0x20 or c >= 0x7f) return null;
    const key: FontKey = .{
        .mono = r.mono or props.mono,
        .italic = r.i,
        .weight = tree_mod.sat(u16, r.w),
        .size = tree_mod.sat(u32, r.sz * 64),
        .fz = tree_mod.sat(u32, (props.fz orelse 16) * 64),
        .lh = if (props.lh) |lh| tree_mod.sat(i32, lh * 64) else -1,
        .family = familyHash(r.ff orelse props.ff),
    };
    const table = s.glyph_widths.get(key) orelse blk: {
        if (s.glyph_widths.count() >= 64) clearGlyphWidths(s);
        const tbl = s.gpa.create(PairWidths) catch return null;
        tbl.* = .{};
        s.glyph_widths.put(s.gpa, key, tbl) catch {
            s.gpa.destroy(tbl);
            return null;
        };
        break :blk tbl;
    };
    if (table.height == 0) {
        const size = probeTextSize(s, props, r, "A") orelse return null;
        table.height = @intCast(@divTrunc(size[1] + PANGO_SCALE - 1, PANGO_SCALE));
    }
    var units: i64 = 0;
    for (t, 0..) |c, i| {
        const next: u8 = if (i + 1 < t.len) t[i + 1] else 128;
        const w = pairWidth(s, props, r, table, c, next) orelse return null;
        units += w;
    }
    return .{ textWidth(units), cssHeight(s, props, 1) orelse @floatFromInt(table.height) };
}

fn pairWidth(s: *Surface, props: *const tree_mod.Props, r: tree_mod.Run, table: *PairWidths, a: u8, b: u8) ?i32 {
    const known = table.w[a][b];
    if (known == pair_ligature) return null;
    if (known != pair_unknown) return known;
    var w: i32 = undefined;
    if (b == 128) {
        const one = [1]u8{a};
        w = (probeTextSize(s, props, r, &one) orelse return null)[0];
    } else {
        const two = [2]u8{ a, b };
        const pair = probe(s, props, r, &two) orelse return null;
        const after = pairWidth(s, props, r, table, b, 128) orelse return null;
        if (pair[2] != 2) {
            table.w[a][b] = pair_ligature;
            return null;
        }
        w = pair[0] - after;
    }
    table.w[a][b] = w;
    return w;
}

/// `text` laid out on one line with the run's style: its size in Pango
/// units.
fn probeTextSize(s: *Surface, props: *const tree_mod.Props, r: tree_mod.Run, text: []const u8) ?[2]i32 {
    const p = probe(s, props, r, text) orelse return null;
    return .{ p[0], p[1] };
}

/// Width, height (Pango units) and clusters of `text` on one line.
fn probe(s: *Surface, props: *const tree_mod.Props, r: tree_mod.Run, text: []const u8) ?[3]i32 {
    var run = r;
    run.t = text;
    var p = props.*;
    p.runs = @as(*const [1]tree_mod.Run, &run);
    const layout = textLayoutOf(s, &p, std.math.inf(f32)) orelse return null;
    defer g_object_unref(layout);
    var w: c_int = 0;
    var h: c_int = 0;
    pango_layout_get_size(layout, &w, &h);
    var clusters: i32 = 0;
    if (pango_layout_get_iter(layout)) |it| {
        defer pango_layout_iter_free(it);
        clusters = 1;
        while (pango_layout_iter_next_cluster(it) != 0) clusters += 1;
    }
    return .{ w, h, clusters };
}

/// ORIEL_NUI_TEXT_CHECK: the fast size against Pango's layout.
fn checkTextSize(s: *Surface, n: *Node, width: f32, fast: [2]f32) void {
    const layout = textLayout(s, n, width) orelse return;
    defer g_object_unref(layout);
    var w: c_int = 0;
    var h: c_int = 0;
    pango_layout_get_pixel_size(layout, &w, &h);
    var wu: c_int = 0;
    var hu: c_int = 0;
    pango_layout_get_size(layout, &wu, &hu);
    if (textWidth(wu) != fast[0] or @as(f32, @floatFromInt(h)) != fast[1]) {
        const t = if (n.props.runs) |runs| runs[0].t else "";
        log.warn("text size: fast {d}x{d}, Pango {d}x{d}: \"{s}\"", .{ fast[0], fast[1], textWidth(wu), h, t[0..@min(t.len, 60)] });
    }
}

/// A text's width as browsers keep it: rounded up to a LayoutUnit (1/64 px;
/// 0.001 px of slack for glyph-pair sums), from Pango units.
fn textWidth(units: i64) f32 {
    const px = @as(f32, @floatFromInt(units)) / PANGO_SCALE;
    return @ceil((px - 0.001) * 64) / 64;
}

/// The width a text is laid out at to draw it: its box's, plus a LayoutUnit
/// for float error (its lines break where they were measured).
fn paintWidth(w: f32) f32 {
    return w + 1.0 / 64.0;
}

fn textLayout(s: *Surface, n: *Node, width: f32) ?*PangoLayout {
    return textLayoutOf(s, &n.props, width);
}

fn textLayoutOf(s: *Surface, props: *const tree_mod.Props, width: f32) ?*PangoLayout {
    const n = struct { props: *const tree_mod.Props }{ .props = props };
    const runs = n.props.runs orelse return null;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(s.gpa);
    const attrs = pango_attr_list_new();
    defer pango_attr_list_unref(attrs);
    const add = struct {
        fn f(list: *PangoAttrList, a: *PangoAttribute, st: c_uint, en: c_uint) void {
            a.start_index = st;
            a.end_index = en;
            pango_attr_list_insert(list, a);
        }
    }.f;
    for (runs, 0..) |r, ri| {
        const room = boxRoom(runs, ri);
        if (room[0] > 0) {
            const at: c_uint = @intCast(text.items.len);
            text.appendSlice(s.gpa, room_mark) catch return null;
            add(attrs, roomShape(room[0]), at, at + mark_len);
        }
        const start: c_uint = @intCast(text.items.len);
        text.appendSlice(s.gpa, r.t) catch return null;
        const end: c_uint = @intCast(text.items.len);
        add(attrs, pango_attr_foreground_new(c16(r.c[0]), c16(r.c[1]), c16(r.c[2])), start, end);
        if (r.c[3] < 1) add(attrs, pango_attr_foreground_alpha_new(@intFromFloat(@max(0, @min(1, r.c[3])) * 65535)), start, end);
        add(attrs, pango_attr_size_new_absolute(tree_mod.sat(c_int, r.sz * PANGO_SCALE)), start, end);
        add(attrs, pango_attr_weight_new(tree_mod.sat(c_int, r.w)), start, end);
        if (r.i) add(attrs, pango_attr_style_new(2), start, end);
        if (r.ff) |ff| {
            // Its CSS family list (Pango copies the name).
            var buf: [256]u8 = undefined;
            if (std.fmt.bufPrintZ(&buf, "{s}", .{resolveFamily(s, ff)})) |name| add(attrs, pango_attr_family_new(name), start, end) else |_| {}
        } else if (r.mono) add(attrs, pango_attr_family_new("Monospace"), start, end);
        if (r.u) add(attrs, pango_attr_underline_new(1), start, end);
        if (r.bg) |bg| if (bg[3] > 0) {
            add(attrs, pango_attr_background_new(c16(bg[0]), c16(bg[1]), c16(bg[2])), start, end);
            if (bg[3] < 1) add(attrs, pango_attr_background_alpha_new(tree_mod.sat(u16, bg[3] * 65535)), start, end);
        };
        if (room[1] > 0) {
            const at: c_uint = @intCast(text.items.len);
            text.appendSlice(s.gpa, room_mark) catch return null;
            add(attrs, roomShape(room[1]), at, at + mark_len);
        }
    }
    if (n.props.ls) |ls| add0(attrs, pango_attr_letter_spacing_new(tree_mod.sat(c_int, ls * PANGO_SCALE)));
    // CSS line-height: each line box is that tall and the glyphs sit in its
    // middle (half-leading above and below, negative when it's smaller than
    // the font, as `line-height: 1` on an icon glyph). Pango >= 1.50.
    // Without one, line-height: normal as browsers make it (lineBox).
    if (lineBox(s, n.props)) |lh| add0(attrs, pango_attr_line_height_new_absolute(tree_mod.sat(c_int, lh * PANGO_SCALE)));
    const layout = gtk_widget_create_pango_layout(s.area, null);
    // (The layout keeps a copy of the description.)
    const desc = fontDesc(s, n.props.fz orelse 16, n.props.mono, n.props.ff);
    pango_layout_set_font_description(layout, desc);
    pango_layout_set_text(layout, text.items.ptr, @intCast(text.items.len));
    pango_layout_set_attributes(layout, attrs);
    if (n.props.nowrap or std.math.isInf(width)) {
        pango_layout_set_width(layout, -1);
    } else {
        pango_layout_set_width(layout, tree_mod.sat(c_int, @max(1, width) * PANGO_SCALE));
        pango_layout_set_wrap(layout, 2); // word-char
    }
    if (n.props.ta) |ta| {
        if (std.mem.eql(u8, ta, "center")) pango_layout_set_alignment(layout, 1);
        if (std.mem.eql(u8, ta, "right")) pango_layout_set_alignment(layout, 2);
    }
    return layout;
}

// An inline box's room in the line (its margin, border and padding on
// the start and end sides, docs "Inline boxes"): an invisible character
// shaped that wide before its first run and after its last. U+2061 breaks
// as a letter does, so the room stays with the box's text (a line can
// break before the box, not between the room and its text).
const room_mark = "\u{2061}";
const mark_len: c_uint = room_mark.len;

fn roomShape(w: f32) *PangoAttribute {
    const rect: PangoRectangle = .{ .width = tree_mod.sat(c_int, w * PANGO_SCALE) };
    return pango_attr_shape_new(&rect, &rect);
}

/// Run i's inline box's room before it (its first run) and after it (its
/// last): 0 elsewhere.
fn boxRoom(runs: []const tree_mod.Run, i: usize) [2]f32 {
    const ib = runs[i].ib orelse return .{ 0, 0 };
    const same = struct {
        fn f(r: tree_mod.Run, k: u32) bool {
            return if (r.ib) |o| o.k == k else false;
        }
    }.f;
    const first = i == 0 or !same(runs[i - 1], ib.k);
    const last = i + 1 == runs.len or !same(runs[i + 1], ib.k);
    return .{ if (first) ib.start() else 0, if (last) ib.end() else 0 };
}

/// The runs' byte ranges in their layout's text (textLayoutOf: the room
/// marks between them), one after another.
const RunBytes = struct {
    runs: []const tree_mod.Run,
    i: usize = 0,
    at: usize = 0,

    fn next(w: *RunBytes) ?[2]usize {
        if (w.i >= w.runs.len) return null;
        const room = boxRoom(w.runs, w.i);
        if (room[0] > 0) w.at += room_mark.len;
        const start = w.at;
        w.at += w.runs[w.i].t.len;
        const end = w.at;
        if (room[1] > 0) w.at += room_mark.len;
        w.i += 1;
        return .{ start, end };
    }
};

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
    if (s.engine.tree.needsLayout()) s.engine.tree.layout();
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

    // Elliptical corners, as CSS draws them (tree.zig radiusXY).
    const r = n.radiusXY();
    if (p.sh) |sh| shadow(cr, f, r, sh);
    if (p.bg) |bg| {
        // The color under the gradient (CSS layers).
        if (bg.color) |c| {
            roundRectXY(cr, f, r);
            setColor(cr, c);
            cairo_fill(cr);
        }
        if (bg.gradient) |g| {
            roundRectXY(cr, f, r);
            const pat = gradient(f, g);
            cairo_set_source(cr, pat);
            cairo_fill(cr);
            cairo_pattern_destroy(pat);
        }
    }
    if (p.bw) |bw| if (p.bs) |style| dashedBorder(cr, f, r, bw, p.bc, style) else border(cr, f, r, bw, p.bc);
    switch (n.kind) {
        .text => paintText(s, cr, n),
        .icon => paintIcon(cr, n),
        .image => paintImage(s, cr, n),
        .textarea => paintPlaceholder(s, cr, n),
        .canvas => paintCanvas(s, cr, n),
        .view => if (n.props.ctl != null) paintControl(cr, n),
        else => {},
    }
    // A box that clips its content (overflow hidden, or a scroller) with
    // rounded corners: the children are clipped to its rounded padding box.
    const round_clip = n.roundClips();
    if (round_clip) {
        cairo_save(cr);
        const pb = n.paddingClipXY();
        roundRectXY(cr, pb.rect, pb.radii);
        cairo_clip(cr);
    }
    // CSS paint order: a sticky header over the rows scrolled under it.
    var it: tree_mod.PaintIter = .{ .kids = n.kids.items };
    while (it.next()) |k| paint(s, cr, k);
    if (round_clip) cairo_restore(cr);
    if (p.ol) |ol| outline(cr, f, r, ol);
    if (alpha < 1) {
        cairo_pop_group_to_source(cr);
        cairo_paint_with_alpha(cr, alpha);
    }
}

/// CSS outline: a border of its own around the box grown by offset +
/// width, its corners the box's radius grown as much (square ones stay
/// square), solid, dashed or dotted.
fn outline(cr: *cairo_t, f: Rect, r: Radii, ol: tree_mod.Outline) void {
    if (!(ol.w > 0) or !(ol.c[3] > 0)) return;
    const grow = ol.o + ol.w;
    const box: Rect = .{ .x = f.x - grow, .y = f.y - grow, .w = f.w + 2 * grow, .h = f.h + 2 * grow };
    if (box.w <= 2 * ol.w or box.h <= 2 * ol.w) return;
    // A focus ring's own corners round at least `r` (win32.zig's too).
    var radii = r.grown(grow);
    for (&radii.x) |*x| x.* = @max(x.*, ol.r);
    for (&radii.y) |*y| y.* = @max(y.*, ol.r);
    cairo_save(cr);
    defer cairo_restore(cr);
    // A focus ring's halo: 1px around it, its corners 1px rounder.
    if (ol.h) |h| if (h[3] > 0) {
        const halo: Rect = .{ .x = box.x - 1, .y = box.y - 1, .w = box.w + 2, .h = box.h + 2 };
        border(cr, halo, radii.grown(1), .{ 1, 1, 1, 1 }, .{ h, h, h, h });
    };
    const bw = [4]f32{ ol.w, ol.w, ol.w, ol.w };
    const bc = [4]tree_mod.Color{ ol.c, ol.c, ol.c, ol.c };
    if (ol.s) |style| dashedBorder(cr, box, radii, bw, bc, style) else border(cr, box, radii, bw, bc);
}

fn setColor(cr: *cairo_t, c: tree_mod.Color) void {
    cairo_set_source_rgba(cr, c[0] / 255, c[1] / 255, c[2] / 255, c[3]);
}

/// A rectangle with elliptical corners (tree.zig Radii) as the current
/// path; a corner with either axis 0 square.
fn roundRectXY(cr: *cairo_t, f: Rect, r: Radii) void {
    cairo_new_path(cr);
    if (r.square()) {
        cairo_rectangle(cr, f.x, f.y, f.w, f.h);
        return;
    }
    ellipseRect(cr, f, r.x, r.y);
}

/// Each corner less `d` on both axes (a stroke's middle inside the box).
fn shrunk(r: Radii, d: f32) Radii {
    var out = r;
    for (&out.x) |*x| x.* = @max(0, x.* - d);
    for (&out.y) |*y| y.* = @max(0, y.* - d);
    return out;
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

/// A gradient's pattern: its stops resolved over the gradient line (px
/// and calc() positions, missing ones: Gradient.resolve); a repeating one
/// is one period long and repeats (CAIRO_EXTEND_REPEAT).
fn gradient(f: Rect, g: tree_mod.Gradient) *cairo_pattern_t {
    var buf: [260]tree_mod.Gradient.Stop = undefined;
    if (g.radialIn(f.w, f.h)) |rad| {
        // A unit circle at the origin, mapped onto the ellipse; its ray
        // (the x radius) is the gradient line.
        const cx = f.x + rad[0];
        const cy = f.y + rad[1];
        const rx = rad[2];
        const ry = rad[3];
        const res = g.resolve(rx, &buf);
        const pat = cairo_pattern_create_radial(0, 0, 0, 0, 0, res.period orelse 1);
        cairo_pattern_set_matrix(pat, &.{ .xx = 1 / rx, .yx = 0, .xy = 0, .yy = 1 / ry, .x0 = -cx / rx, .y0 = -cy / ry });
        addStops(pat, res);
        return pat;
    }
    const a = g.angle * std.math.pi / 180.0;
    const dx = @sin(a);
    const dy = -@cos(a);
    const len = @abs(f.w * dx) + @abs(f.h * dy);
    const cx = f.x + f.w / 2;
    const cy = f.y + f.h / 2;
    const res = g.resolve(len, &buf);
    const span = len * (res.period orelse 1);
    const x0 = cx - dx * len / 2;
    const y0 = cy - dy * len / 2;
    const pat = cairo_pattern_create_linear(x0, y0, x0 + dx * span, y0 + dy * span);
    addStops(pat, res);
    return pat;
}

fn addStops(pat: *cairo_pattern_t, res: tree_mod.Gradient.Resolved) void {
    for (res.stops) |st| cairo_pattern_add_color_stop_rgba(pat, st[4], st[0] / 255, st[1] / 255, st[2] / 255, st[3]);
    if (res.period != null) cairo_pattern_set_extend(pat, 1); // CAIRO_EXTEND_REPEAT
}

fn border(cr: *cairo_t, f: Rect, r: Radii, bw: [4]f32, bc: ?[4]tree_mod.Color) void {
    const colors = bc orelse return;
    const uniform = bw[0] == bw[1] and bw[1] == bw[2] and bw[2] == bw[3];
    if (uniform and bw[0] > 0) {
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        const ri = shrunk(r, half);
        cairo_set_line_width(cr, bw[0]);
        const same = for (colors[1..]) |c| {
            if (!std.mem.eql(f32, &c, &colors[0])) break false;
        } else true;
        if (same) {
            roundRectXY(cr, inner, ri);
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
            roundRectXY(cr, inner, ri);
            setColor(cr, colors[i]);
            cairo_stroke(cr);
            cairo_restore(cr);
        }
        return;
    }
    if (!r.square()) {
        roundedSides(cr, f, r, bw, colors);
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

/// Rounded corners and sides of different widths (a card's
/// border-left: 6px): the area between the border box and the padding
/// box, whose corners are ellipses (the radius less each side's width, as
/// CSS makes them), each side's color clipped to its wedge: the lines
/// from its outer corners through its inner corners (where browsers join
/// two colors), up to the middle.
fn roundedSides(cr: *cairo_t, f: Rect, r: Radii, bw: [4]f32, colors: [4]tree_mod.Color) void {
    const pb = tree_mod.paddingBoxXY(f, r, bw);
    const inner = pb.rect;
    // One color where every drawn side has the same: one fill.
    var first: ?tree_mod.Color = null;
    const same = for (0..4) |i| {
        if (bw[i] <= 0) continue;
        if (first) |c| {
            if (!std.mem.eql(f32, &c, &colors[i])) break false;
        } else first = colors[i];
    } else true;
    const outer = [4][2]f32{ .{ f.x, f.y }, .{ f.x + f.w, f.y }, .{ f.x + f.w, f.y + f.h }, .{ f.x, f.y + f.h } };
    const in = [4][2]f32{ .{ inner.x, inner.y }, .{ inner.x + inner.w, inner.y }, .{ inner.x + inner.w, inner.y + inner.h }, .{ inner.x, inner.y + inner.h } };
    const mid = [2]f32{ inner.x + inner.w / 2, inner.y + inner.h / 2 };
    // Each corner's join, from the outer corner through the inner one,
    // stopped where it reaches the middle's row or column.
    var join: [4][2]f32 = undefined;
    for (0..4) |k| {
        const dx = in[k][0] - outer[k][0];
        const dy = in[k][1] - outer[k][1];
        var t: f32 = std.math.floatMax(f32);
        if (dx != 0) t = @min(t, (mid[0] - outer[k][0]) / dx);
        if (dy != 0) t = @min(t, (mid[1] - outer[k][1]) / dy);
        if (dx == 0 and dy == 0) t = 0;
        join[k] = .{ outer[k][0] + @max(0, t) * dx, outer[k][1] + @max(0, t) * dy };
    }
    for (0..4) |i| {
        if (bw[i] <= 0 or colors[i][3] <= 0) continue;
        // A color already drawn with an earlier side.
        const done = for (0..i) |k| {
            if (bw[k] > 0 and std.mem.eql(f32, &colors[k], &colors[i])) break true;
        } else false;
        if (done) continue;
        cairo_save(cr);
        if (!same) {
            // Every side of this color in one clip (their wedges' union):
            // two neighbours of one color meet without a seam.
            cairo_new_path(cr);
            for (i..4) |k| {
                if (bw[k] <= 0 or !std.mem.eql(f32, &colors[k], &colors[i])) continue;
                const j = (k + 1) % 4;
                cairo_move_to(cr, outer[k][0], outer[k][1]);
                cairo_line_to(cr, outer[j][0], outer[j][1]);
                cairo_line_to(cr, join[j][0], join[j][1]);
                cairo_line_to(cr, mid[0], mid[1]);
                cairo_line_to(cr, join[k][0], join[k][1]);
                cairo_close_path(cr);
            }
            cairo_clip(cr);
        }
        cairo_new_path(cr);
        ellipseRect(cr, f, r.x, r.y);
        ellipseRect(cr, inner, pb.radii.x, pb.radii.y);
        cairo_set_fill_rule(cr, 1); // even-odd: the ring
        setColor(cr, colors[i]);
        cairo_fill(cr);
        cairo_restore(cr);
        if (same) return;
    }
}

/// A rectangle with elliptical corners (`rx`, `ry` each: top left, top
/// right, bottom right, bottom left), added to the current path.
fn ellipseRect(cr: *cairo_t, f: Rect, rx: [4]f32, ry: [4]f32) void {
    const pi = std.math.pi;
    const x: f64 = f.x;
    const y: f64 = f.y;
    const w: f64 = f.w;
    const h: f64 = f.h;
    cairo_new_sub_path(cr);
    ellipseArc(cr, x + w - rx[1], y + ry[1], rx[1], ry[1], -pi / 2.0, 0, x + w, y);
    ellipseArc(cr, x + w - rx[2], y + h - ry[2], rx[2], ry[2], 0, pi / 2.0, x + w, y + h);
    ellipseArc(cr, x + rx[3], y + h - ry[3], rx[3], ry[3], pi / 2.0, pi, x, y + h);
    ellipseArc(cr, x + rx[0], y + ry[0], rx[0], ry[0], pi, 3 * pi / 2.0, x, y);
    cairo_close_path(cr);
}

/// A quarter ellipse, or its square corner (`px`, `py`) when it has no
/// radius along either axis.
fn ellipseArc(cr: *cairo_t, cx: f64, cy: f64, rx: f32, ry: f32, a0: f64, a1: f64, px: f64, py: f64) void {
    if (rx <= 0 or ry <= 0) {
        cairo_line_to(cr, px, py);
        return;
    }
    cairo_save(cr);
    cairo_translate(cr, cx, cy);
    cairo_scale(cr, rx, ry);
    cairo_arc(cr, 0, 0, 1, a0, a1);
    cairo_restore(cr);
}

/// The dash pattern for one dashed or dotted line of `len` px drawn `w`
/// wide, as Chromium draws it (and win32.zig): dashes 3×w (dots 1×w) at
/// both ends, a whole number of them, the gaps stretched to fit.
fn dashPattern(len: f64, w: f64, style: tree_mod.BorderStyle) [2]f64 {
    const d: f64 = if (style == .dotted) w else 3 * w;
    if (len <= d or d <= 0) return .{ len, 0 };
    const k = @max(2, @round((len + d) / (2 * d)));
    const gap = (len - k * d) / (k - 1);
    // Round dots (3 px and up): a zero-length dash with round caps, the
    // period unchanged.
    if (style == .dotted and w >= 3) return .{ 0, d + gap };
    return .{ d, gap };
}

/// border-style: dashed or dotted (the first side styled so, Props.bs).
fn dashedBorder(cr: *cairo_t, f: Rect, r: Radii, bw: [4]f32, bc: ?[4]tree_mod.Color, style: tree_mod.BorderStyle) void {
    const colors = bc orelse return;
    const round_dots = style == .dotted;
    cairo_save(cr);
    defer cairo_restore(cr);
    const uniform = bw[0] == bw[1] and bw[1] == bw[2] and bw[2] == bw[3];
    const rounded = !r.square();
    if (uniform and rounded and bw[0] > 0 and colors[0][3] > 0) {
        // Rounded: one dash pattern along the whole rounded stroke.
        const w: f64 = bw[0];
        const half = bw[0] / 2;
        const inner: Rect = .{ .x = f.x + half, .y = f.y + half, .w = f.w - bw[0], .h = f.h - bw[0] };
        const ri = shrunk(r, half);
        const d: f64 = if (style == .dotted) w else 3 * w;
        const pat = if (style == .dotted and w >= 3) [2]f64{ 0, 2 * d } else [2]f64{ d, d };
        cairo_set_line_width(cr, w);
        cairo_set_line_cap(cr, if (round_dots and w >= 3) 1 else 0);
        cairo_set_dash(cr, &pat, 2, 0);
        roundRectXY(cr, inner, ri);
        setColor(cr, colors[0]);
        cairo_stroke(cr);
        return;
    }
    // Square corners: each side its own line along its middle, with whole
    // dashes at both ends.
    for (0..4) |i| {
        const w: f64 = bw[i];
        if (w <= 0 or colors[i][3] <= 0) continue;
        const hw = w / 2;
        const x0: f64 = f.x;
        const y0: f64 = f.y;
        const x1: f64 = f.x + f.w;
        const y1: f64 = f.y + f.h;
        const seg: [4]f64 = switch (i) {
            0 => .{ x0, y0 + hw, x1, y0 + hw },
            1 => .{ x1 - hw, y0, x1 - hw, y1 },
            2 => .{ x1, y1 - hw, x0, y1 - hw },
            else => .{ x0 + hw, y1, x0 + hw, y0 },
        };
        const len = @abs(seg[2] - seg[0]) + @abs(seg[3] - seg[1]);
        var pat = dashPattern(len, w, style);
        const round = style == .dotted and w >= 3;
        var a = seg;
        if (round) {
            // Dots centred on their slots: the line starts half a dot in.
            const dx = std.math.sign(seg[2] - seg[0]) * hw;
            const dy = std.math.sign(seg[3] - seg[1]) * hw;
            a = .{ seg[0] + dx, seg[1] + dy, seg[2] - dx, seg[3] - dy };
            pat = dashPattern(len, w, style);
        }
        cairo_new_path(cr);
        cairo_move_to(cr, a[0], a[1]);
        cairo_line_to(cr, a[2], a[3]);
        cairo_set_line_width(cr, w);
        cairo_set_line_cap(cr, if (round) 1 else 0);
        cairo_set_dash(cr, &pat, 2, 0);
        setColor(cr, colors[i]);
        cairo_stroke(cr);
    }
}

test "dashPattern: whole dashes at both ends" {
    // 100 px, 1 px dashed: 3 px dashes, k = round(103/6) = 17, gaps 3.25.
    const p = dashPattern(100, 1, .dashed);
    try std.testing.expectEqual(@as(f64, 3), p[0]);
    try std.testing.expect(@abs(17 * p[0] + 16 * p[1] - 100) < 1e-9);
    // Too short for two dashes: solid.
    try std.testing.expectEqual(@as(f64, 0), dashPattern(2, 1, .dashed)[1]);
    // Round dots from 3 px: zero-length dashes.
    try std.testing.expectEqual(@as(f64, 0), dashPattern(60, 4, .dotted)[0]);
}

fn shadow(cr: *cairo_t, f: Rect, r: Radii, sh: tree_mod.Shadow) void {
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
        roundRectXY(cr, rect, r.grown(grow));
        var c = sh.color;
        c[3] = sh.color[3] / @as(f32, @floatFromInt(steps));
        setColor(cr, c);
        cairo_fill(cr);
    }
}

fn paintText(s: *Surface, cr: *cairo_t, n: *Node) void {
    const c = n.content();
    const layout = textLayout(s, n, paintWidth(c.w)) orelse return;
    defer g_object_unref(layout);
    // Lines of different heights (a bigger font on some): each on its own
    // baseline, below the lines before it.
    var exts: [64]Extent = undefined;
    var dy: f32 = 0;
    const lines = textLines(s, &n.props, layout, &exts);
    paintInlineBoxes(s, cr, layout, c.x, c.y, lines, n);
    if (lines) |e| {
        paintLines(cr, layout, c.x, c.y, e);
    } else {
        // Pango's lines centered in CSS's line boxes when those are shorter.
        if (cssHeight(s, &n.props, pango_layout_get_line_count(layout))) |css_h| {
            var w: c_int = 0;
            var h: c_int = 0;
            pango_layout_get_size(layout, &w, &h);
            const pango_h = @as(f32, @floatFromInt(h)) / PANGO_SCALE;
            if (pango_h > css_h) dy = (css_h - pango_h) / 2;
        }
        cairo_move_to(cr, c.x, c.y + dy);
        pango_cairo_show_layout(cr, layout);
    }
    // A focused inline link's ring, around each of its line fragments.
    const runs = n.props.runs orelse return;
    var walk: RunBytes = .{ .runs = runs };
    var i: usize = 0;
    while (walk.next()) |range| : (i += 1) {
        var end = range[1];
        if (runs[i].ol) |ol| {
            // The link's runs (a <b> in it) under one ring.
            while (i + 1 < runs.len and runs[i + 1].ol != null and std.meta.eql(runs[i + 1].ol.?, ol)) : (i += 1) end = (walk.next() orelse break)[1];
            runRing(cr, layout, c.x, c.y + dy, range[0], end, ol);
        }
    }
}

/// The inline boxes' decoration (docs "Inline boxes"), under the text: on
/// each line fragment of a box's text, its background, then its border, as
/// tall as its font's content area (ascent and descent) and its padding
/// and border; its start side on its first fragment only, its end side on
/// its last. `lines`: where paintText puts each line (null: Pango's own).
fn paintInlineBoxes(s: *Surface, cr: *cairo_t, layout: *PangoLayout, x: f32, y: f32, lines: ?[]const Extent, n: *Node) void {
    const runs = n.props.runs orelse return;
    const text = std.mem.span(pango_layout_get_text(layout));
    var walk: RunBytes = .{ .runs = runs };
    var i: usize = 0;
    while (walk.next()) |range| : (i += 1) {
        const ib = runs[i].ib orelse continue;
        // The box's runs, and its font (its first run's).
        const r = runs[i];
        var end = range[1];
        while (i + 1 < runs.len and runs[i + 1].ib != null and runs[i + 1].ib.?.k == ib.k) : (i += 1) end = (walk.next() orelse break)[1];
        const start = range[0];
        if (end <= start) continue;
        const m = unhintedMetrics(s, r.sz, r.mono or n.props.mono, r.ff orelse n.props.ff) orelse continue;
        const ascent = @round(m[0]);
        const descent = @round(m[1]);
        const bw = ib.bw orelse [4]f32{ 0, 0, 0, 0 };
        const it = pango_layout_get_iter(layout) orelse return;
        defer pango_layout_iter_free(it);
        var top: f32 = y; // line k's top, when paintText places the lines
        var k: usize = 0;
        while (true) : (k += 1) {
            const base = if (lines) |e| (if (k < e.len) top + e[k].top else break) else y + @as(f32, @floatFromInt(pango_layout_iter_get_baseline(it))) / PANGO_SCALE;
            if (lines) |e| top += e[k].top + e[k].bottom;
            if (pango_layout_iter_get_line_readonly(it)) |line| blk: {
                const head: *const PangoLayoutLineHead = @ptrCast(@alignCast(line));
                const ls: usize = @intCast(@max(0, head.start_index));
                const le: usize = @min(text.len, ls + @as(usize, @intCast(@max(0, head.length))));
                const a = @max(start, ls);
                var b = @min(end, le);
                if (a >= b) break :blk;
                const first = a == start;
                const last = b == end;
                // A fragment that wraps: up to the line's text, not over
                // the space it wraps after.
                if (!last) while (b > a and (text[b - 1] == ' ' or text[b - 1] == '\n')) {
                    b -= 1;
                };
                if (a >= b) break :blk;
                var ranges: ?[*]c_int = null;
                var count: c_int = 0;
                pango_layout_line_get_x_ranges(line, tree_mod.sat(c_int, a), tree_mod.sat(c_int, b), &ranges, &count);
                const rs = ranges orelse break :blk;
                defer g_free(@ptrCast(rs));
                var x0: f32 = std.math.floatMax(f32);
                var x1: f32 = -std.math.floatMax(f32);
                for (0..@intCast(@max(0, count))) |q| {
                    x0 = @min(x0, @as(f32, @floatFromInt(rs[2 * q])) / PANGO_SCALE);
                    x1 = @max(x1, @as(f32, @floatFromInt(rs[2 * q + 1])) / PANGO_SCALE);
                }
                if (!(x1 > x0)) break :blk;
                if (first) x0 -= bw[3] + ib.p[3];
                if (last) x1 += ib.p[1] + bw[1];
                const box: Rect = .{
                    .x = x + x0,
                    .y = base - ascent - ib.p[0] - bw[0],
                    .w = x1 - x0,
                    .h = ascent + descent + ib.p[0] + ib.p[2] + bw[0] + bw[2],
                };
                var radii: Radii = .{};
                if (ib.br) |br| {
                    const keep = [4]bool{ first, last, last, first };
                    for (0..4) |q| if (keep[q]) {
                        radii.x[q] = br[q];
                        radii.y[q] = br[q];
                    };
                    radii = radii.fitted(box.w, box.h);
                }
                if (ib.bg) |bg| if (bg[3] > 0) {
                    roundRectXY(cr, box, radii);
                    setColor(cr, bg);
                    cairo_fill(cr);
                };
                if (ib.bw != null) {
                    const sides = [4]f32{ bw[0], if (last) bw[1] else 0, bw[2], if (first) bw[3] else 0 };
                    border(cr, box, radii, sides, .{ ib.bc, ib.bc, ib.bc, ib.bc });
                }
            }
            if (pango_layout_iter_next_line(it) == 0) break;
        }
    }
}

/// A layout's lines drawn one by one at (x, y), line k's baseline its
/// extent's top below the lines before it.
fn paintLines(cr: *cairo_t, layout: *PangoLayout, x: f32, y: f32, exts: []const Extent) void {
    const it = pango_layout_get_iter(layout) orelse return;
    defer pango_layout_iter_free(it);
    var top = y;
    for (exts) |e| {
        const line = pango_layout_iter_get_line_readonly(it) orelse return;
        var logical: PangoRectangle = .{};
        pango_layout_iter_get_line_extents(it, null, &logical);
        cairo_move_to(cr, x + @as(f32, @floatFromInt(logical.x)) / PANGO_SCALE, top + e.top);
        pango_cairo_show_layout_line(cr, line);
        top += e.top + e.bottom;
        if (pango_layout_iter_next_line(it) == 0) return;
    }
}

/// An outline around the text from byte `start` to `end` of a layout drawn
/// at (x, y): one box per line it's on (the spaces where a line wraps
/// left out), as tall as that line.
fn runRing(cr: *cairo_t, layout: *PangoLayout, x: f32, y: f32, start: usize, end: usize, ol: tree_mod.Outline) void {
    const text = std.mem.span(pango_layout_get_text(layout));
    const it = pango_layout_get_iter(layout) orelse return;
    defer pango_layout_iter_free(it);
    while (true) {
        if (pango_layout_iter_get_line_readonly(it)) |line| {
            // This line's part of the run, without spaces at its ends.
            const head: *const PangoLayoutLineHead = @ptrCast(@alignCast(line));
            const ls: usize = @intCast(@max(0, head.start_index));
            const le: usize = @min(text.len, ls + @as(usize, @intCast(@max(0, head.length))));
            var a = @max(start, ls);
            var b = @min(end, le);
            while (a < b and text[a] == ' ') a += 1;
            while (b > a and (text[b - 1] == ' ' or text[b - 1] == '\n')) b -= 1;
            if (a < b) {
                var logical: PangoRectangle = .{};
                pango_layout_iter_get_line_extents(it, null, &logical);
                var ranges: ?[*]c_int = null;
                var count: c_int = 0;
                pango_layout_line_get_x_ranges(line, tree_mod.sat(c_int, a), tree_mod.sat(c_int, b), &ranges, &count);
                if (ranges) |rs| {
                    defer g_free(@ptrCast(rs));
                    // One box over the ranges (they split where the style does).
                    var x0: f32 = std.math.floatMax(f32);
                    var x1: f32 = -std.math.floatMax(f32);
                    for (0..@intCast(@max(0, count))) |i| {
                        x0 = @min(x0, @as(f32, @floatFromInt(rs[2 * i])) / PANGO_SCALE);
                        x1 = @max(x1, @as(f32, @floatFromInt(rs[2 * i + 1])) / PANGO_SCALE);
                    }
                    if (x1 > x0) {
                        const box: Rect = .{ .x = x + x0, .y = y + @as(f32, @floatFromInt(logical.y)) / PANGO_SCALE, .w = x1 - x0, .h = @as(f32, @floatFromInt(logical.height)) / PANGO_SCALE };
                        outline(cr, box, .{}, ol);
                    }
                }
            }
        }
        if (pango_layout_iter_next_line(it) == 0) break;
    }
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
    if (n.props.mix and !radio) {
        // Indeterminate: the accent box with a dash.
        setColor(cr, .{ acc[0], acc[1], acc[2], acc[3] * alpha });
        cairo_fill(cr);
        setColor(cr, .{ 255, 255, 255, alpha });
        cairo_set_line_width(cr, @max(1.5, size * 0.13));
        cairo_set_line_cap(cr, 1);
        cairo_move_to(cr, x + size * 0.28, y + size / 2);
        cairo_line_to(cr, x + size * 0.72, y + size / 2);
        cairo_stroke(cr);
    } else if (n.props.on) {
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
    pango_layout_set_width(layout, tree_mod.sat(c_int, @max(1, c.w) * PANGO_SCALE));
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

/// A circle mask's radius (1/16 px) and position within its pixel (1/16 px).
const CircleKey = struct { r16: u32, qx: u8, qy: u8 };
const circle_subpixels = 16;
const max_circle_masks = 2048;
const max_circle_radius = 64;

/// A path that is one whole circle, in the bitmap's pixels (canvasCircle).
const PixelCircle = struct { x: f64, y: f64, r: f64 };

const CircleMasks = std.AutoHashMapUnmanaged(CircleKey, *anyopaque);

fn clearCircleMasks(masks: *CircleMasks) void {
    var it = masks.valueIterator();
    while (it.next()) |m| cairo_surface_destroy(m.*);
    masks.clearRetainingCapacity();
}

/// The circle `arc` draws as a whole path, in pixels (`sf`: the bitmap's
/// pixels per unit), when the transform keeps circles round and upright;
/// null otherwise (or too big for a mask).
fn pixelCircle(cr: *cairo_t, x: f32, y: f32, r: f32, sf: f64) ?PixelCircle {
    var m: CairoMatrix = undefined;
    cairo_get_matrix(cr, &m);
    if (m.xy != 0 or m.yx != 0 or m.xx != m.yy or !(m.xx > 0)) return null;
    const pr = @as(f64, r) * m.xx * sf;
    if (!(pr > 0) or pr > max_circle_radius) return null;
    return .{ .x = (m.xx * x + m.x0) * sf, .y = (m.yy * y + m.y0) * sf, .r = pr };
}

/// Fill a whole circle with the current source: its mask (anti-aliased by
/// cairo once per radius and 1/16-pixel position) painted where it goes.
/// Rasterizing the path every time was most of a game's frame (1000 balls:
/// 3.1 ms of cairo's fills vs 0.5 ms of masks). False: no mask (no memory).
fn canvasCircle(gpa: std.mem.Allocator, masks: *CircleMasks, cr: *cairo_t, c: PixelCircle, sf: f64) bool {
    const left = c.x - c.r - 1;
    const top = c.y - c.r - 1;
    const bx = @floor(left);
    const by = @floor(top);
    const sub: f64 = circle_subpixels;
    const key: CircleKey = .{
        .r16 = @intFromFloat(@round(c.r * 16)),
        .qx = @intFromFloat(@min(sub - 1, @floor((left - bx) * sub))),
        .qy = @intFromFloat(@min(sub - 1, @floor((top - by) * sub))),
    };
    const mask = masks.get(key) orelse blk: {
        if (masks.count() >= max_circle_masks) clearCircleMasks(masks);
        const r = @as(f64, @floatFromInt(key.r16)) / 16;
        const d: c_int = @intFromFloat(@ceil(2 * r) + 3);
        const m = cairo_image_surface_create(2, d, d) orelse return false; // A8
        const mc = cairo_create(m) orelse {
            cairo_surface_destroy(m);
            return false;
        };
        // Centered in its bucket of positions.
        const off = 1 + r;
        cairo_arc(mc, off + (@as(f64, @floatFromInt(key.qx)) + 0.5) / sub, off + (@as(f64, @floatFromInt(key.qy)) + 0.5) / sub, r, 0, 2 * std.math.pi);
        cairo_fill(mc);
        cairo_destroy(mc);
        masks.put(gpa, key, m) catch {
            cairo_surface_destroy(m);
            return false;
        };
        break :blk m;
    };
    // In pixels: the transform for a moment as the bitmap's own.
    var saved: CairoMatrix = undefined;
    cairo_get_matrix(cr, &saved);
    const px: CairoMatrix = .{ .xx = 1 / sf, .yx = 0, .xy = 0, .yy = 1 / sf, .x0 = 0, .y0 = 0 };
    cairo_set_matrix(cr, &px);
    cairo_mask_surface(cr, mask, bx, by);
    cairo_set_matrix(cr, &saved);
    return true;
}

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

/// The largest canvas bitmap: 4096 x 4096 px (64 MB as ARGB).
const max_canvas_pixels: f64 = 4096 * 4096;

fn paintCanvas(s: *Surface, win_cr: *cairo_t, n: *Node) void {
    const cmds = n.canvas orelse return;
    const f = n.frame;
    if (f.w <= 0 or f.h <= 0) return;
    // The program draws into its own surface, then that is painted on the
    // page: cairo's errors are sticky (a scale(0), an infinite coordinate),
    // an unbalanced restore() would pop the window's own states, and a
    // clearRect must clear the canvas, not the page behind it. All of that
    // now stays in the canvas's surface.
    var sf: f64 = @floatFromInt(@max(1, gtk_widget_get_scale_factor(s.area)));
    // At most max_canvas_pixels (as on Apple): a bigger canvas gets a
    // bitmap of fewer pixels per point, scaled up on the page.
    const area = f.w * sf * f.h * sf;
    if (area > max_canvas_pixels) sf *= @sqrt(max_canvas_pixels / area);
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
        roundRectXY(win_cr, f, n.radiusXY());
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
    // The current path when it is one whole circle (a ball, a particle):
    // filled as a mask (canvasCircle). Anything else added drops it.
    var circle: ?PixelCircle = null;
    var path_parts: u32 = 0;
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
            .begin_path => {
                cairo_new_path(cr);
                circle = null;
                path_parts = 0;
            },
            .close_path, .move_to, .line_to, .rect, .bezier_to => {
                circle = null;
                path_parts += 1;
                switch (cmd) {
                    .close_path => cairo_close_path(cr),
                    .move_to => |p| cairo_move_to(cr, p[0], p[1]),
                    .line_to => |p| cairo_line_to(cr, p[0], p[1]),
                    .rect => |r| cairo_rectangle(cr, r[0], r[1], r[2], r[3]),
                    .bezier_to => |b| cairo_curve_to(cr, b[0], b[1], b[2], b[3], b[4], b[5]),
                    else => unreachable,
                }
            },
            .arc => |a| {
                const whole = @abs(a.a1 - a.a0) >= 2 * std.math.pi;
                circle = if (path_parts == 0 and whole) pixelCircle(cr, a.x, a.y, a.r, sf) else null;
                path_parts += 1;
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
            .fill => |even| {
                canvasSource(cr, st.fill, st.alpha, &grads);
                if (circle) |c| if (st.fill == .color and canvasCircle(s.gpa, &s.circle_masks, cr, c, sf)) continue;
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

    /// What its decoded pixels take (ARGB).
    fn bytes(img: Image) u64 {
        if (img.surface == null) return 0;
        return @as(u64, @intFromFloat(img.w)) * @as(u64, @intFromFloat(img.h)) * 4;
    }
};

/// All of a window's decoded pictures together: past it, the others go
/// before a new one is kept (they're decoded again when painted).
const max_image_cache_bytes: u64 = 256 * 1024 * 1024;

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
    var total = stored.bytes();
    var it = s.images.valueIterator();
    while (it.next()) |other| total += other.bytes();
    if (total > max_image_cache_bytes) {
        var rest = s.images.valueIterator();
        while (rest.next()) |other| other.deinit();
        s.images.clearRetainingCapacity();
    }
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
        clearGlyphWidths(&s);
        s.glyph_widths.deinit(gpa);
        if (s.sans) |font| pango_font_description_free(font);
        if (s.mono) |font| pango_font_description_free(font);
        if (s.metrics_ctx) |c| g_object_unref(c);
        s.font_metrics.deinit(s.gpa);
        freeFamilies(&s);
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
        var wu: c_int = 0;
        var hu: c_int = 0;
        pango_layout_get_size(fresh, &wu, &hu);
        try std.testing.expectEqual(textWidth(wu), cached[0]);
        try std.testing.expectEqual(cssHeight(&s, &n.props, pango_layout_get_line_count(fresh)) orelse @as(f32, @floatFromInt(h)), cached[1]);
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
    var wu: c_int = 0;
    var hu: c_int = 0;
    pango_layout_get_size(fresh, &wu, &hu);
    try std.testing.expectEqual(textWidth(wu), cached[0]);
    try std.testing.expectEqual(cssHeight(&s, &n.props, pango_layout_get_line_count(fresh)) orelse @as(f32, @floatFromInt(h)), cached[1]);
    const old_count = s.text_measurements.entries.count();
    pango_context_changed(gtk_widget_get_pango_context(area));
    measure(&s, n, 80, &cached);
    try std.testing.expect(s.text_measurements.entries.count() < old_count);
}

test "a circle filled from its mask matches cairo's own fill" {
    const gpa = std.testing.allocator;
    var masks: CircleMasks = .empty;
    defer {
        clearCircleMasks(&masks);
        masks.deinit(gpa);
    }
    const w = 64;
    var worst: u8 = 0;
    var diff_sum: u64 = 0;
    var edge_pixels: u64 = 0;
    var prng = std.Random.DefaultPrng.init(7);
    const rnd = prng.random();
    for (0..200) |_| {
        const x = 20 + rnd.float(f32) * 24;
        const y = 20 + rnd.float(f32) * 24;
        const r = 2 + rnd.float(f32) * 14;
        const sf: f64 = if (rnd.boolean()) 1 else 2;
        var out: [2][]const u8 = undefined;
        var surfs: [2]*anyopaque = undefined;
        for (0..2) |way| {
            const px: c_int = @intFromFloat(w * sf);
            const img = cairo_image_surface_create(0, px, px).?;
            cairo_surface_set_device_scale(img, sf, sf);
            const cr = cairo_create(img).?;
            cairo_set_source_rgba(cr, 0, 0, 0, 1);
            if (way == 0) {
                cairo_arc(cr, x, y, r, 0, 2 * std.math.pi);
                cairo_fill(cr);
            } else {
                const c = pixelCircle(cr, x, y, r, sf).?;
                try std.testing.expect(canvasCircle(gpa, &masks, cr, c, sf));
            }
            cairo_destroy(cr);
            cairo_surface_flush(img);
            surfs[way] = img;
            const stride: usize = @intCast(cairo_image_surface_get_stride(img));
            out[way] = cairo_image_surface_get_data(img).?[0 .. stride * @as(usize, @intCast(px))];
        }
        // ARGB32: compare the alpha bytes (coverage).
        var i: usize = 3;
        while (i < out[0].len) : (i += 4) {
            const d = if (out[0][i] > out[1][i]) out[0][i] - out[1][i] else out[1][i] - out[0][i];
            worst = @max(worst, d);
            // Edge pixels (partly covered either way).
            if ((out[0][i] != 0 and out[0][i] != 255) or (out[1][i] != 0 and out[1][i] != 255)) {
                diff_sum += d;
                edge_pixels += 1;
            }
        }
        for (surfs) |img| cairo_surface_destroy(img);
    }
    // Edge pixels only: a position off by at most 1/32 px, and cairo's
    // coverage steps (its rasterizer samples a coarse sub-pixel grid; at 2x
    // the path's own flattening differs too). On average, a few levels.
    try std.testing.expect(worst <= 100);
    try std.testing.expect(diff_sum <= edge_pixels * 8);
}

test "drag actions: allowed, suggested from the modifiers, the page's mask as one action" {
    try std.testing.expectEqual(@as(u8, 1), allowedActions(1));
    try std.testing.expectEqual(@as(u8, 7), allowedActions(gdk_action_ask));
    try std.testing.expectEqual(@as(u8, 3), allowedActions(3 | gdk_action_ask));
    // One allowed action is the suggestion whatever the keys.
    try std.testing.expectEqual(@as(u8, 2), suggestedAction(2, 2));
    try std.testing.expectEqual(@as(u8, 1), suggestedAction(7, 0));
    try std.testing.expectEqual(@as(u8, 2), suggestedAction(7, 1)); // shift
    try std.testing.expectEqual(@as(u8, 1), suggestedAction(7, 2)); // ctrl
    try std.testing.expectEqual(@as(u8, 4), suggestedAction(7, 3)); // ctrl+shift
    try std.testing.expectEqual(@as(u8, 2), suggestedAction(6, 2)); // ctrl without copy
    try std.testing.expectEqual(@as(u8, 0), suggestedAction(0, 0));
    try std.testing.expectEqual(@as(c_uint, 2), pickAction(3, 7, 2));
    try std.testing.expectEqual(@as(c_uint, 1), pickAction(1, 7, 2));
    try std.testing.expectEqual(@as(c_uint, 4), pickAction(4 | 8, 4, 4));
    try std.testing.expectEqual(@as(c_uint, 0), pickAction(2, 1, 1));
    try std.testing.expectEqual(@as(c_uint, 0), pickAction(0, 7, 1));
}

test "drag items: files alone (their paths stay hidden), else the strings" {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try (DragKinds{ .files = true, .plain = true, .uri_list = true, .html = true }).writeItems(gpa, &out);
    try std.testing.expectEqualStrings("[[\"file\",\"\"]]", out.items);
    out.clearRetainingCapacity();
    try (DragKinds{ .plain = true, .uri_list = true, .html = true }).writeItems(gpa, &out);
    try std.testing.expectEqualStrings("[[\"string\",\"text/plain\"],[\"string\",\"text/uri-list\"],[\"string\",\"text/html\"]]", out.items);
    out.clearRetainingCapacity();
    try (DragKinds{}).writeItems(gpa, &out);
    try std.testing.expectEqualStrings("[]", out.items);
}

test "dropped text: UTF-16 with a BOM, a UTF-8 BOM, NULs, invalid bytes" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "\xff\xfeh\x00\xe9\x00<\x00\x3d\xd8\x00\xde\x00\x00", "hé<\u{1F600}" },
        .{ "\xff\xfe\x00\xd8x\x00", "\u{FFFD}x" },
        .{ "\xef\xbb\xbfplain\x00", "plain" },
        .{ "a\xffb", "a\u{FFFD}b" },
        .{ "", "" },
    };
    for (cases) |c| {
        const t = try dropText(gpa, c[0]);
        defer gpa.free(t);
        try std.testing.expectEqualStrings(c[1], t);
    }
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try appendJsonString(gpa, &out, "a\"b\n\xff");
    try std.testing.expectEqualStrings("\"a\\\"b\\n\u{FFFD}\"", out.items);
}
