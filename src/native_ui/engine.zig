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
    /// A node's props changed (optional: backends that mirror them).
    props: ?*const fn (ctx: *anyopaque, node: *Node, props: std.json.Value) void = null,
    /// A single text run changed through the direct bridge.
    text: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
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
    /// Optional, for backends that mirror props (`props`): a node's
    /// transform or opacity changed alone (Tree.on_paint, the "x" op). The
    /// runtime sends such changes as "x" ops only when a backend that
    /// mirrors props has this (others read props when they draw).
    paint: ?*const fn (ctx: *anyopaque, node: *Node) void = null,
};

/// A font the page may use (Backend.warm_fonts).
pub const FontSpec = struct { size: f32, weight: u16, italic: bool, mono: bool };

// usize: 32-bit targets (armv7, x86 Android) have no 64-bit atomic add. Wrapping
// would take 4 billion engines in one process.
var next_serial: std.atomic.Value(usize) = .init(0);

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
        e.tree.on_leaf_style = backend.leaf_style;
        e.tree.on_create = backend.leaf;
        e.tree.on_paint = backend.paint;
        e.js = oqjs_new(e, platform_json.ptr, label.ptr, url.ptr) orelse return error.QuickJsInitFailed;
        errdefer oqjs_free(e.js);
        // Transform/opacity-only changes as "x" ops: unless the backend
        // mirrors props without a paint hook (it would miss them).
        if (backend.props == null or backend.paint != null) {
            const flag = "__host.paintOps = true";
            _ = oqjs_eval(e.js, flag, flag.len, "<native>");
        }
        if (oqjs_eval_bytecode(e.js, runtime_bytecode.ptr, runtime_bytecode.len) < 0) return error.RuntimeFailed;
        return e;
    }

    pub fn destroy(e: *Engine) void {
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
        _ = e.callf("__oriel.vsync({d:.3})", .{interval_ms});
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
        e.tree.replace();
        e.backend.laid_out(e.backend.ctx);
        return true;
    }

    pub fn scrollBy(e: *Engine, node: *Node, dy: f32) bool {
        const before = node.scroll_y;
        node.scroll_y = std.math.clamp(node.scroll_y + dy, 0, @max(0, node.content_h - node.frame.h));
        if (node.scroll_y == before) return false;
        e.tree.replace();
        e.backend.laid_out(e.backend.ctx);
        return true;
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
        if (e.tree.dirty) {
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
    }

    /// The bytes of an app asset ("assets/x.png"), or null.
    pub fn assetData(e: *Engine, path: []const u8) ?[]const u8 {
        const a = App.findAsset(e.assets, path, false) orelse return null;
        return a.data;
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

export fn oriel_nui_frame(p: *anyopaque, id: f64, out: *[5]f64) c_int {
    const e = engineOf(p);
    if (e.tree.dirty) {
        const t0 = prof.now();
        e.tree.layout();
        prof.report("flayout {d:.2}", .{prof.now() - t0});
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return 0;
    out.* = .{ n.frame.x, n.frame.y, n.frame.w, n.frame.h, @max(n.content_h, n.frame.h) };
    return 1;
}

export fn oriel_nui_focus(p: *anyopaque, id: f64) void {
    const e = engineOf(p);
    if (e.tree.dirty) {
        e.tree.layout();
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    e.backend.focus(e.backend.ctx, n);
}

export fn oriel_nui_scroll_into_view(p: *anyopaque, id: f64, block: [*]const u8, len: usize) void {
    const e = engineOf(p);
    if (e.tree.dirty) {
        e.tree.layout();
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    e.tree.scrollIntoView(n, block[0..len]);
    e.backend.laid_out(e.backend.ctx);
}

export fn oriel_nui_scroll_to(p: *anyopaque, id: f64, y: f64) void {
    const e = engineOf(p);
    if (e.tree.dirty) e.tree.layout();
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    n.scroll_y = std.math.clamp(@as(f32, @floatCast(y)), 0, @max(0, n.content_h - n.frame.h));
    e.tree.replace();
    e.backend.laid_out(e.backend.ctx);
}

test {
    _ = @import("prof.zig");
    // Pure Zig, used by the Apple backends (apple_draw.zig): tested everywhere.
    _ = @import("svg_path.zig");
    _ = @import("tree.zig");
    // The Apple drawing (ImageIO, CoreText): tested where it runs.
    if (comptime @import("builtin").os.tag == .macos) _ = @import("apple_draw.zig");
}
