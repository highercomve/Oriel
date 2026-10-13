//! Shared platform contract for the JavaScript and Zig UI engines.
const tree_mod = @import("tree.zig");
const std = @import("std");
const Node = tree_mod.Node;
pub fn Backend(comptime Engine: type) type {
    return struct {
        ctx: *anyopaque,
        /// Text size for a text or field node at a width (inf: unbounded).
        measure: tree_mod.Measure,
        /// Geometry or painting changed: update the views and redraw.
        laid_out: *const fn (ctx: *anyopaque) void,
        /// A node goes away: drop its view.
        removed: *const fn (ctx: *anyopaque, node: *Node) void,
        /// Call `Engine.timerFired(id)` after `ms`.
        add_timer: *const fn (ctx: *anyopaque, engine: *Engine, id: u32, ms: u32) void,
        /// Run a command; answer with `Engine.resolve(call_id, ...)` on the UI thread.
        invoke: *const fn (ctx: *anyopaque, engine: *Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void,
        /// Give a field the keyboard focus.
        focus: *const fn (ctx: *anyopaque, node: *Node) void,
        /// Optional: a text field's selection, start and end in UTF-16 units
        /// of its value (LF line ends); false when it has none (not made yet).
        /// host.selection, for el.selectionStart / selectionEnd.
        selection: ?*const fn (ctx: *anyopaque, node: *Node, out: *[2]u32) bool = null,
        /// Optional: select that range of a text field (host.setSelection, for
        /// el.setSelectionRange and select()).
        set_selection: ?*const fn (ctx: *anyopaque, node: *Node, start: u32, end: u32) void = null,
        /// A node's props changed (optional: backends that mirror them).
        props: ?*const fn (ctx: *anyopaque, node: *Node, props: std.json.Value) void = null,
        /// Optional: an accessibility entry changed or went (Tree.ax, the "a"
        /// op; id -2: all cleared). A backend with an accessibility tree tells
        /// its assistive technology.
        ax_changed: ?*const fn (ctx: *anyopaque, id: i64) void = null,
        /// A single text run changed through the direct bridge.
        text: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
        /// Natural text sizes for many nodes in one go (Tree.measure_texts):
        /// text updates are then measured together before the layout.
        measure_texts: ?*const fn (ctx: *anyopaque, nodes: []const *Node) void = null,
        /// A leaf style was defined, and a node made from one (Tree.on_leaf_style,
        /// Tree.on_create; optional: backends that mirror props).
        leaf_style: ?*const fn (ctx: *anyopaque, id: i64, json: []const u8) void = null,
        leaf: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
        /// Release backend caches after all native nodes have been removed.
        deinit: ?*const fn (ctx: *anyopaque) void = null,
        /// Optional: call `Engine.frame()` soon (the next display frame). With
        /// it, the page renders at most once per frame, as a browser does,
        /// however many events reach it; without it, after every call into
        /// JavaScript.
        request_frame: ?*const fn (ctx: *anyopaque) void = null,
        /// Optional: call `Engine.displayFrame(interval_ms)` once, at the
        /// display's next refresh (GTK's frame clock, CVDisplayLink /
        /// CADisplayLink, Choreographer, DWM). With it, requestAnimationFrame
        /// follows the display (120 Hz panels get 120 frames a second, a hidden
        /// window none); without it, a 60 Hz timer grid.
        request_display_frame: ?*const fn (ctx: *anyopaque) void = null,
        /// Optional: load these fonts while idle (host.warmFonts: the sizes and
        /// weights the page's rules use), so the first text in each doesn't pay
        /// for the font match and load when a page or tab is shown.
        warm_fonts: ?*const fn (ctx: *anyopaque, specs: []const FontSpec) void = null,
        /// Optional: the text font's ascent, descent and line gap in px at
        /// `size`, unhinted (host.fontMetrics: line-height: normal, where an
        /// inline image's line puts its baseline). docs/native-renderer.md.
        font_metrics: ?*const fn (ctx: *anyopaque, size: f32, mono: bool, out: *[3]f32) bool = null,
        /// Optional: the same for a CSS font-family list (render.js familyOf),
        /// a line's strut in the block's own font; font_metrics without it.
        font_metrics_family: ?*const fn (ctx: *anyopaque, size: f32, mono: bool, family: []const u8, out: *[3]f32) bool = null,
        /// Optional: the line fragments of a text node's runs `first`…`last`
        /// (an inline element's text: getClientRects) as [x, y, w, h] in the
        /// tree's coordinates (as frames are: scrolled, CSS px), each as tall as
        /// its line's font (ascent + descent); how many it wrote to `out`.
        /// Without it the page gets the text node's frame.
        run_rects: ?*const fn (ctx: *anyopaque, n: *Node, first: usize, last: usize, out: [][4]f32) usize = null,
        /// Optional: that font's x-height in px (vertical-align: middle; host.
        /// fontMetrics' fourth value). Without it the page takes half the size.
        font_x_height: ?*const fn (ctx: *anyopaque, size: f32, mono: bool, family: []const u8) ?f32 = null,
        /// Optional, for backends that mirror props (`props`): a node's
        /// transform or opacity changed alone (Tree.on_paint, the "x" op). The
        /// runtime sends such changes as "x" ops only when a backend that
        /// mirrors props has this (others read props when they draw).
        paint: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
        /// Optional, for backends that mirror props: a canvas node's program
        /// changed (Tree.on_canvas, host.canvas). The runtime sends programs
        /// that way only when a backend that mirrors props has this.
        canvas: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
        /// The backend keeps its own copy of every node's props (Android's
        /// Kotlin views), from `props`: then the runtime sends transform-only
        /// changes and canvas programs outside the props only if it has `paint`
        /// and `canvas`. (GTK's `props` only drops cached text sizes.)
        mirrors_props: bool = false,
    };
}

/// A font the page may use (Backend.warm_fonts).
pub const FontSpec = struct { size: f32, weight: u16, italic: bool, mono: bool };
