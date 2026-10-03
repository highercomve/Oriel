//! The native renderer's engine, one per window (docs/native-renderer.md):
//! QuickJS running the JS side (runtime.js) and the page, the node tree with
//! its layout, and the backend (GTK, Android views) behind a small vtable.
//!
//! Everything runs on the UI thread. After every call into JavaScript the
//! engine runs the pending promise jobs, lets the page render (ops → tree),
//! lays the tree out and tells the backend.

const std = @import("std");
const tree_mod = @import("tree.zig");
const prof = @import("prof.zig");
pub const Tree = tree_mod.Tree;
pub const Node = tree_mod.Node;

const log = std.log.scoped(.native_ui);

/// The JS side, built from src/native_ui/js (npm run build) into runtime.js,
/// as QuickJS bytecode (compiled at build time: tools/qjs_bytecode.c).
const runtime_bytecode = @import("runtime_bytecode").data;

// -Dnative_dom: the native DOM's C API (dom_qjs.c calls it), and rows
// stamped from it (host.stamp).
const native_dom = @import("build_options").native_dom;
const dom_stamp = if (native_dom) @import("dom_stamp.zig") else struct {};
comptime {
    if (native_dom) {
        _ = @import("dom/capi.zig");
        @export(&stampExport, .{ .name = "oriel_nui_stamp" });
        @export(&stampListExport, .{ .name = "oriel_nui_stamp_list" });
    }
}

test {
    if (native_dom) _ = dom_stamp;
}

/// host.stamp(rowId, row, plan): row element `row` (a DOM store index in
/// `dom`) stamped as tree row `row_id` (dom_stamp.zig); 0 when declined.
fn stampExport(p: *anyopaque, row_id: f64, dom: *anyopaque, row: u32, plan: u32) callconv(.c) c_int {
    if (!native_dom) return 0;
    const e = engineOf(p);
    const ok = dom_stamp.stamp(&e.tree, @ptrCast(@alignCast(dom)), row, Tree.idOf(row_id), plan) catch return 0;
    return @intFromBool(ok);
}

/// host.stampList(listId, list, rowStyle, plan, template, kept): a list's
/// rows but its template and kept ones stamped by the tree
/// (dom_stamp.stampList); 0 when declined.
fn stampListExport(p: *anyopaque, list_id: f64, dom: *anyopaque, list: u32, row_style: f64, plan: u32, template: u32, kept: [*]const u32, kept_len: usize) callconv(.c) c_int {
    if (!native_dom) return 0;
    const e = engineOf(p);
    const ok = dom_stamp.stampList(&e.tree, @ptrCast(@alignCast(dom)), list, Tree.idOf(list_id), Tree.idOf(row_style), plan, template, kept[0..kept_len]) catch return 0;
    return @intFromBool(ok);
}

/// host.stampPlan([...]): a row plan's id (Tree.defineStampPlan), 0 if not.
export fn oriel_nui_stamp_plan(p: *anyopaque, v: [*]const f64, len: usize) u32 {
    return engineOf(p).tree.defineStampPlan(v[0..len]) catch 0;
}

extern fn oqjs_new(opaque_ptr: *anyopaque, platform_json: [*:0]const u8, label: [*:0]const u8, url: [*:0]const u8) ?*anyopaque;
extern fn oqjs_eval(h: *anyopaque, code: [*]const u8, len: usize, name: [*:0]const u8) c_int;
extern fn oqjs_eval_bytecode(h: *anyopaque, code: [*]const u8, len: usize) c_int;
extern fn oqjs_run_jobs(h: *anyopaque) void;
extern fn oqjs_memory(h: *anyopaque) usize;
extern fn oqjs_run_gc(h: *anyopaque) void;
extern fn oqjs_free(h: *anyopaque) void;

const App = @import("../core/App.zig");
pub const Asset = App.Asset;

/// What a platform provides.
pub const Backend = struct {
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

/// A font the page may use (Backend.warm_fonts).
pub const FontSpec = struct { size: f32, weight: u16, italic: bool, mono: bool };

// usize: 32-bit targets (armv7, x86 Android) have no 64-bit atomic add. Wrapping
// would take 4 billion engines in one process.
var next_serial: std.atomic.Value(usize) = .init(0);
/// The open engines by serial (UI thread).
var live: std.AutoHashMapUnmanaged(u64, *Engine) = .empty;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    js: *anyopaque,
    tree: Tree,
    backend: Backend,
    assets: []const Asset,
    script_buf: std.ArrayList(u8) = .empty,
    booted: bool = false,
    in_call: u32 = 0,
    /// The page read its layout (offsetWidth, getBoundingClientRect…) while it
    /// rendered: the tree was laid out then, and the backend still has to
    /// draw that layout when the call settles.
    relaid: bool = false,
    /// Unique per engine for the process: an answer that outlived its window
    /// tells a new engine at the same address apart from its own.
    serial: u64 = 0,
    renders: u64 = 0,
    /// A frame was requested (`Backend.request_frame`) and hasn't run yet.
    frame_pending: bool = false,
    /// ORIEL_NUI_PAGE: the file read for index.html (tools/flatten_diff).
    page_override: ?[]u8 = null,
    /// The page asked for an animation frame (host.vsync): the next display
    /// frame runs its requestAnimationFrame callbacks.
    js_frame_wanted: bool = false,
    /// The app's Zig code at each display frame (canvas.zig onFrame).
    frame_hooks: std.ArrayList(FrameHook) = .empty,
    /// Running them: what they commit shows with this frame.
    in_frame_hooks: bool = false,

    /// A Zig callback at each display frame while it returns true.
    pub const FrameHook = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque, e: *Engine, interval_ms: f64) bool,
    };

    pub fn create(gpa: std.mem.Allocator, backend: Backend, assets: []const Asset, platform_json: [:0]const u8, label: [:0]const u8, url: [:0]const u8, width: f32, height: f32) !*Engine {
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{
            .gpa = gpa,
            .js = undefined,
            .tree = Tree.init(gpa, backend.ctx, backend.measure),
            .backend = backend,
            .assets = assets,
        };
        // On failure below: the tree (its Yoga config, and any nodes the
        // runtime already made) and the QuickJS runtime go too, as in destroy.
        errdefer e.tree.deinit();
        e.serial = @as(u64, next_serial.fetchAdd(1, .monotonic)) + 1;
        e.tree.width = width;
        e.tree.height = height;
        e.tree.on_remove = backend.removed;
        e.tree.on_props = backend.props;
        e.tree.on_text = backend.text;
        e.tree.measure_texts = backend.measure_texts;
        e.tree.on_leaf_style = backend.leaf_style;
        e.tree.on_create = backend.leaf;
        e.tree.on_paint = backend.paint;
        e.tree.on_canvas = backend.canvas;
        e.js = oqjs_new(e, platform_json.ptr, label.ptr, url.ptr) orelse return error.QuickJsInitFailed;
        errdefer oqjs_free(e.js);
        // Transform/opacity-only changes as "x" ops: unless the backend
        // mirrors props (mirrors_props) without a paint hook (it would miss them).
        if (!backend.mirrors_props or backend.paint != null) {
            const flag = "__host.paintOps = true";
            _ = oqjs_eval(e.js, flag, flag.len, "<native>");
        }
        // Canvas programs as numbers (host.canvas), likewise.
        if (!backend.mirrors_props or backend.canvas != null) {
            const flag = "__host.canvasOps = true";
            _ = oqjs_eval(e.js, flag, flag.len, "<native>");
        }
        if (oqjs_eval_bytecode(e.js, runtime_bytecode.ptr, runtime_bytecode.len) < 0) return error.RuntimeFailed;
        try live.put(std.heap.smp_allocator, e.serial, e);
        return e;
    }

    /// The engine with this serial, if its window is still open (UI
    /// thread): what a Zig handle that outlived its window finds.
    pub fn bySerial(serial: u64) ?*Engine {
        return live.get(serial);
    }

    pub fn destroy(e: *Engine) void {
        _ = live.remove(e.serial);
        e.frame_hooks.deinit(e.gpa);
        oqjs_free(e.js);
        if (e.page_override) |page| e.gpa.free(page);
        e.tree.deinit();
        if (e.backend.deinit) |deinit| deinit(e.backend.ctx);
        e.script_buf.deinit(e.gpa);
        e.gpa.destroy(e);
    }

    /// Load the page: stylesheets, scripts, the first frame.
    pub fn boot(e: *Engine, dark: bool, coarse: bool) void {
        _ = e.callf("__oriel.boot({d},{d},{},{})", .{ e.tree.width, e.tree.height, dark, coarse });
        e.booted = true;
        log.info("native ui: page booted, {d} nodes, JS heap {d} KB", .{ e.tree.nodes.count(), oqjs_memory(e.js) / 1024 });
        if (std.c.getenv("ORIEL_NUI_DUMP") != null) {
            e.tree.layout();
            e.tree.dump();
        }
    }

    /// Evaluate a script in the page (App.emit's `window.oriel.__emit(...)`).
    pub fn evalScript(e: *Engine, script: [:0]const u8) void {
        if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("native ui: eval {s}", .{script[0..@min(script.len, 120)]});
        _ = e.call(script);
    }

    /// A native event on a node. True when the page prevented the default.
    pub fn event(e: *Engine, id: i64, kind: []const u8, data_json: []const u8) bool {
        return e.callf("__oriel.event({d},\"{s}\",{s})", .{ id, kind, data_json });
    }

    /// A JSON message for the page (Android's events), see `__oriel.message`.
    pub fn message(e: *Engine, json: []const u8) void {
        _ = e.callf("__oriel.message({s})", .{json});
    }

    /// The system back button: true when the page went back.
    pub fn back(e: *Engine) bool {
        return e.callf("__oriel.event(0,\"back\",null)", .{});
    }

    pub fn timerFired(e: *Engine, id: u32) void {
        _ = e.callf("__oriel.timer({d})", .{id});
    }

    /// The display refreshes (`Backend.request_display_frame`): the page's
    /// animation frame. `interval_ms`: the display's refresh interval (0
    /// when unknown).
    pub fn displayFrame(e: *Engine, interval_ms: f64) void {
        // Scrolls since the last frame: their events first, as a browser
        // runs scroll steps before animation frames.
        e.flushScrolls();
        // The app's Zig first (a canvas it draws), then the page's frame.
        e.in_frame_hooks = true;
        var i: usize = 0;
        while (i < e.frame_hooks.items.len) {
            const h = e.frame_hooks.items[i];
            if (h.func(h.ctx, e, interval_ms)) {
                i += 1;
            } else {
                _ = e.frame_hooks.orderedRemove(i);
            }
        }
        e.in_frame_hooks = false;
        if (e.frame_hooks.items.len > 0) e.requestDisplayFrame();
        if (e.js_frame_wanted) {
            e.js_frame_wanted = false;
            _ = e.callf("__oriel.vsync({d:.3})", .{interval_ms});
        } else if (e.in_call == 0) {
            // Only Zig drew: show it without a JS render.
            e.paintNow();
        }
    }

    /// Lay out if needed and draw what changed, without the page's render
    /// (a canvas the app's Zig drew).
    pub fn paintNow(e: *Engine) void {
        if (e.tree.needsLayout()) {
            e.tree.layout();
            e.relaid = true;
        }
        if (e.relaid or e.tree.paint_dirty) {
            e.relaid = false;
            e.tree.paint_dirty = false;
            e.backend.laid_out(e.backend.ctx);
        }
    }

    /// Run `hook` at each display frame until it returns false (UI thread).
    pub fn addFrameHook(e: *Engine, hook: FrameHook) !void {
        try e.frame_hooks.append(e.gpa, hook);
        e.requestDisplayFrame();
    }

    /// Stop the hooks with this context.
    pub fn removeFrameHooks(e: *Engine, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < e.frame_hooks.items.len) {
            if (e.frame_hooks.items[i].ctx == ctx) _ = e.frame_hooks.orderedRemove(i) else i += 1;
        }
    }

    /// The next display frame, or a 60 Hz timer when the backend has none.
    fn requestDisplayFrame(e: *Engine) void {
        if (e.backend.request_display_frame) |request| request(e.backend.ctx);
    }

    /// A command's answer: `json` is its result, or the error text when !ok.
    pub fn resolve(e: *Engine, call_id: u32, ok: bool, json: []const u8) void {
        const quoted = std.json.Stringify.valueAlloc(e.gpa, json, .{}) catch return;
        defer e.gpa.free(quoted);
        _ = e.callf("__oriel.resolve({d},{},{s})", .{ call_id, ok, quoted });
    }

    pub fn resize(e: *Engine, width: f32, height: f32, dark: bool) void {
        if (width == e.tree.width and height == e.tree.height) return;
        e.tree.width = width;
        e.tree.height = height;
        e.tree.dirty = true;
        _ = e.callf("__oriel.resize({d},{d},{})", .{ width, height, dark });
    }

    /// Scroll a container by `dy`: true if it moved.
    /// Scroll a container sideways by `dx`: true if it moved.
    pub fn scrollByX(e: *Engine, node: *Node, dx: f32) bool {
        const before = node.scroll_x;
        node.scroll_x = std.math.clamp(node.scroll_x + dx, 0, @max(0, node.content_w - node.frame.w));
        if (node.scroll_x == before) return false;
        e.tree.noteScroll(node);
        e.tree.replace();
        e.backend.laid_out(e.backend.ctx);
        e.scrollsChanged();
        return true;
    }

    pub fn scrollBy(e: *Engine, node: *Node, dy: f32) bool {
        const before = node.scroll_y;
        node.scroll_y = std.math.clamp(node.scroll_y + dy, 0, @max(0, node.content_h - node.frame.h));
        if (node.scroll_y == before) return false;
        e.tree.noteScroll(node);
        e.tree.replace();
        e.backend.laid_out(e.backend.ctx);
        e.scrollsChanged();
        return true;
    }

/// A scroller's offset changed (Tree.scrolled): the page hears of it at
    /// the next display frame (at most once a frame), or now when the
    /// backend has none.
    fn scrollsChanged(e: *Engine) void {
        if (e.tree.scrolled.items.len == 0) return;
        if (e.backend.request_display_frame) |request| request(e.backend.ctx) else e.flushScrolls();
    }

    /// __oriel.scrolled([[id, scrollTop, scrollLeft], ...]): "scroll" on
    /// each scroller that moved since the page last heard.
    pub fn flushScrolls(e: *Engine) void {
        if (e.tree.scrolled.items.len == 0 or !e.booted) return;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(e.gpa);
        buf.appendSlice(e.gpa, "__oriel.scrolled([") catch return;
        var first = true;
        for (e.tree.scrolled.items) |id| {
            const n = e.tree.get(id) orelse continue;
            n.scroll_noted = false;
            if (!first) buf.append(e.gpa, ',') catch return;
            first = false;
            buf.print(e.gpa, "[{d},{d},{d}]", .{ id, n.scroll_y, n.scroll_x }) catch return;
        }
        e.tree.scrolled.clearRetainingCapacity();
        if (first) return;
        buf.appendSlice(e.gpa, "])") catch return;
        const script = e.gpa.dupeZ(u8, buf.items) catch return;
        defer e.gpa.free(script);
        _ = e.call(script);
    }

    fn callf(e: *Engine, comptime fmt: []const u8, args: anytype) bool {
        e.script_buf.clearRetainingCapacity();
        e.script_buf.print(e.gpa, fmt, args) catch return false;
        // QuickJS reads up to a NUL: the script must end with one.
        const script = e.gpa.dupeZ(u8, e.script_buf.items) catch return false;
        defer e.gpa.free(script);
        return e.call(script);
    }

    fn call(e: *Engine, script: [:0]const u8) bool {
        e.in_call += 1;
        const t0 = prof.now();
        const r = oqjs_eval(e.js, script.ptr, script.len, "<native>");
        if (e.in_call == 1) prof.report("call {d:.2} {s}", .{ prof.now() - t0, script[0..@min(script.len, 24)] });
        e.in_call -= 1;
        if (r < 0) log.err("native ui: in {s}", .{script[0..@min(script.len, 160)]});
        if (e.in_call == 0) e.settle();
        return r == 1;
    }

    /// After JS ran: microtasks, then the page's render and layout, now or
    /// (`Backend.request_frame`) at the next frame.
    fn settle(e: *Engine) void {
        oqjs_run_jobs(e.js);
        if (e.booted) if (e.backend.request_frame) |request| {
            if (!e.frame_pending) {
                e.frame_pending = true;
                request(e.backend.ctx);
            }
            return;
        };
        e.renderNow();
    }

    /// A frame (`Backend.request_frame`): render what changed since the last.
    pub fn frame(e: *Engine) void {
        if (!e.frame_pending) return;
        e.frame_pending = false;
        if (e.in_call > 0) return; // inside the page: its call settles
        e.renderNow();
    }

    fn renderNow(e: *Engine) void {
        // ORIEL_NUI_MEM=1: the JS heap and the tree's size every 20 renders
        // (finding what grows).
        if (std.c.getenv("ORIEL_NUI_MEM") != null) {
            e.renders += 1;
            if (e.renders % 20 == 0) log.info("native ui mem: render {d}, JS heap {d} KB, {d} nodes", .{ e.renders, e.jsMemory() / 1024, e.tree.nodes.count() });
        }
        const render = "__oriel.render()";
        e.in_call += 1;
        _ = oqjs_eval(e.js, render, render.len, "<render>");
        e.in_call -= 1;
        oqjs_run_jobs(e.js);
        if (e.tree.needsLayout()) {
            const t0 = prof.now();
            e.tree.layout();
            prof.report("layout {d:.2}", .{prof.now() - t0});
            e.relaid = true;
        }
        if (e.relaid or e.tree.paint_dirty) {
            e.relaid = false;
            e.tree.paint_dirty = false;
            e.backend.laid_out(e.backend.ctx);
        }
        // A layout that moved a scroller (its content shrank): heard too.
        e.scrollsChanged();
    }

    /// The bytes of an app asset ("assets/x.png"), or null.
    pub fn assetData(e: *Engine, path: []const u8) ?[]const u8 {
        const a = App.findAsset(e.assets, path, false) orelse return null;
        return a.data;
    }

    /// QuickJS's cycle collection now: a backend calls it when idle after a
    /// big removal, so detached trees held in cycles (their wrappers own
    /// each other, dom/store.zig) are freed then, not at the next
    /// allocation-driven collection.
    pub fn collectGarbage(e: *Engine) void {
        oqjs_run_gc(e.js);
        // The native DOM's trees the collection left without wrappers go too
        // (its finalizers only list them), not at the next render.
        if (native_dom) _ = e.callf("globalThis.__nuiDom?.collect()", .{});
    }

    pub fn jsMemory(e: *Engine) usize {
        return oqjs_memory(e.js);
    }
};

// ---------------------------------------------------------------------------
// __host, called from qjs_shim.c

fn engineOf(p: *anyopaque) *Engine {
    return @ptrCast(@alignCast(p));
}

export fn oriel_nui_log(p: *anyopaque, level: c_int, msg: [*]const u8, len: usize) void {
    _ = p;
    const s = msg[0..len];
    switch (level) {
        0 => log.debug("page: {s}", .{s}),
        1 => log.info("page: {s}", .{s}),
        2 => log.warn("page: {s}", .{s}),
        else => log.err("page: {s}", .{s}),
    }
}

export fn oriel_nui_asset(p: *anyopaque, path: [*]const u8, len: usize, out: *[*]const u8, out_len: *usize) c_int {
    const e = engineOf(p);
    if (pageOverride(e, path[0..len])) |page| {
        out.* = page.ptr;
        out_len.* = page.len;
        return 1;
    }
    const a = App.findAsset(e.assets, path[0..len], false) orelse return 0;
    out.* = a.data.ptr;
    out_len.* = a.data.len;
    return 1;
}

/// Debugging (Linux): ORIEL_NUI_PAGE=<file> is read for index.html instead
/// of the embedded one, so one build of an app renders any page
/// (tools/flatten_diff compares a runtime's trees step by step).
fn pageOverride(e: *Engine, path: []const u8) ?[]const u8 {
    if (comptime @import("builtin").os.tag != .linux) return null;
    if (!std.mem.eql(u8, path, "index.html")) return null;
    if (e.page_override) |page| return page;
    const file = std.c.getenv("ORIEL_NUI_PAGE") orelse return null;
    const fd = std.c.open(file, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    while (true) {
        buf.ensureUnusedCapacity(e.gpa, 64 * 1024) catch break;
        const n = std.c.read(fd, buf.unusedCapacitySlice().ptr, buf.unusedCapacitySlice().len);
        if (n <= 0) break;
        buf.items.len += @intCast(n);
    }
    e.page_override = buf.toOwnedSlice(e.gpa) catch {
        buf.deinit(e.gpa);
        return null;
    };
    return e.page_override;
}

export fn oriel_nui_invoke(p: *anyopaque, call_id: u32, cmd: [*]const u8, cmd_len: usize, args: [*]const u8, args_len: usize) void {
    const e = engineOf(p);
    e.backend.invoke(e.backend.ctx, e, call_id, cmd[0..cmd_len], args[0..args_len]);
}

export fn oriel_nui_timer(p: *anyopaque, id: u32, ms: f64) void {
    const e = engineOf(p);
    e.backend.add_timer(e.backend.ctx, e, id, @intFromFloat(@max(0, @min(ms, 1e9))));
}

export fn oriel_nui_ops(p: *anyopaque, json: [*]const u8, len: usize) void {
    const e = engineOf(p);
    if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("native ui: ops {s}", .{json[0..@min(len, 300)]});
    e.tree.apply(json[0..len]) catch |err| log.err("native ui: bad ops ({s})", .{@errorName(err)});
}

/// host.canvas(id, Float64Array, [strings]): a canvas node's program
/// (Tree.setCanvas); 0 when the node is gone.
export fn oriel_nui_canvas(p: *anyopaque, id: f64, nums: [*]const f64, len: usize, strs: [*]const [*]const u8, lens: [*]const usize, count: usize) c_int {
    const e = engineOf(p);
    const list = e.gpa.alloc([]const u8, count) catch return 0;
    defer e.gpa.free(list);
    for (list, 0..) |*l, i| l.* = strs[i][0..lens[i]];
    const ok = e.tree.setCanvas(Tree.idOf(id), nums[0..len], list) catch return 0;
    return @intFromBool(ok);
}

/// host.fontMetrics(size, mono): 0 when the backend has none.
export fn oriel_nui_font_metrics(p: *anyopaque, size: f64, mono: c_int, out: *[3]f64) c_int {
    const e = engineOf(p);
    const metrics = e.backend.font_metrics orelse return 0;
    var m: [3]f32 = undefined;
    if (!metrics(e.backend.ctx, @floatCast(std.math.clamp(size, 1, 512)), mono != 0, &m)) return 0;
    out.* = .{ m[0], m[1], m[2] };
    return 1;
}

/// host.warmFonts([[size, weight, italic, mono], ...]) as flat numbers.
export fn oriel_nui_warm_fonts(p: *anyopaque, v: [*]const f64, count: usize) void {
    const e = engineOf(p);
    const warm = e.backend.warm_fonts orelse return;
    var specs: [64]FontSpec = undefined;
    const n = @min(count, specs.len);
    for (0..n) |i| specs[i] = .{
        .size = @floatCast(std.math.clamp(v[i * 4], 1, 512)),
        .weight = tree_mod.sat(u16, v[i * 4 + 1]),
        .italic = v[i * 4 + 2] != 0,
        .mono = v[i * 4 + 3] != 0,
    };
    warm(e.backend.ctx, specs[0..n]);
}

/// host.vsync(): ask for a display frame; 0 when the backend has none.
export fn oriel_nui_vsync(p: *anyopaque) c_int {
    const e = engineOf(p);
    const request = e.backend.request_display_frame orelse return 0;
    e.js_frame_wanted = true;
    request(e.backend.ctx);
    return 1;
}

export fn oriel_nui_text(p: *anyopaque, id: f64, text: [*]const u8, len: usize) c_int {
    const e = engineOf(p);
    return if (e.tree.updateText(Tree.idOf(id), text[0..len]) catch return 0) 1 else 0;
}

export fn oriel_nui_leaf_style(p: *anyopaque, id: f64, json: [*]const u8, len: usize) c_int {
    return if (engineOf(p).tree.defineLeafStyle(Tree.idOf(id), json[0..len]) catch return 0) 1 else 0;
}

export fn oriel_nui_leaf(p: *anyopaque, id: f64, style_id: f64, text: [*]const u8, len: usize, is_text: c_int) c_int {
    return if (engineOf(p).tree.createLeaf(Tree.idOf(id), if (is_text != 0) .text else .view, Tree.idOf(style_id), text[0..len]) catch return 0) 1 else 0;
}

export fn oriel_nui_frame(p: *anyopaque, id: f64, out: *[8]f64) c_int {
    const e = engineOf(p);
    if (e.tree.needsLayout()) {
        const t0 = prof.now();
        e.tree.layout();
        prof.report("flayout {d:.2}", .{prof.now() - t0});
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return 0;
    // [x, y, w, h, scrollHeight (the padding box's content: no borders),
    // the scrollbar's room (clientWidth leaves it out), scrollTop, scrollLeft].
    const yg = tree_mod.yg;
    const bt = yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeTop);
    const bb = yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeBottom);
    out.* = .{ n.frame.x, n.frame.y, n.frame.w, n.frame.h, @max(0, @max(n.content_h, n.frame.h) - bt - bb), n.gutter, n.scroll_y, n.scroll_x };
    return 1;
}

/// host.selection(id): the field's [start, end], or 0 (none).
export fn oriel_nui_selection(p: *anyopaque, id: f64, out: *[2]f64) c_int {
    const e = engineOf(p);
    const get = e.backend.selection orelse return 0;
    const n = e.tree.get(Tree.idOf(id)) orelse return 0;
    var r: [2]u32 = undefined;
    if (!get(e.backend.ctx, n, &r)) return 0;
    out.* = .{ @floatFromInt(r[0]), @floatFromInt(r[1]) };
    return 1;
}

/// host.setSelection(id, start, end).
export fn oriel_nui_set_selection(p: *anyopaque, id: f64, start: f64, end: f64) void {
    const e = engineOf(p);
    const set = e.backend.set_selection orelse return;
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    const clamp = struct {
        fn u(v: f64) u32 {
            return if (std.math.isFinite(v) and v > 0) @intFromFloat(@min(v, 1e9)) else 0;
        }
    }.u;
    set(e.backend.ctx, n, clamp(start), clamp(end));
}

export fn oriel_nui_focus(p: *anyopaque, id: f64) void {
    const e = engineOf(p);
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    e.backend.focus(e.backend.ctx, n);
}

export fn oriel_nui_scroll_into_view(p: *anyopaque, id: f64, block: [*]const u8, len: usize) void {
    const e = engineOf(p);
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    e.tree.scrollIntoView(n, block[0..len]);
    e.backend.laid_out(e.backend.ctx);
    e.scrollsChanged();
}

/// host.scrollTo(id, y, x): either NaN leaves that axis.
export fn oriel_nui_scroll_to(p: *anyopaque, id: f64, y: f64, x: f64) void {
    const e = engineOf(p);
    if (e.tree.needsLayout()) e.tree.layout();
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    const before = .{ n.scroll_y, n.scroll_x };
    if (!std.math.isNan(y)) n.scroll_y = std.math.clamp(@as(f32, @floatCast(y)), 0, @max(0, n.content_h - n.frame.h));
    if (!std.math.isNan(x)) n.scroll_x = std.math.clamp(@as(f32, @floatCast(x)), 0, @max(0, n.content_w - n.frame.w));
    if (n.scroll_y != before[0] or n.scroll_x != before[1]) e.tree.noteScroll(n);
    e.tree.replace();
    e.backend.laid_out(e.backend.ctx);
    e.scrollsChanged();
}

test {
    _ = @import("prof.zig");
    // Pure Zig, used by the Apple backends (apple_draw.zig): tested everywhere.
    _ = @import("svg_path.zig");
    _ = @import("tree.zig");
    // The Apple drawing (ImageIO, CoreText): tested where it runs.
    if (comptime @import("builtin").os.tag == .macos) _ = @import("apple_draw.zig");
}
