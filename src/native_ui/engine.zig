//! The native renderer's engine, one per window (docs/native-renderer.md):
//! QuickJS running the JS side (runtime.js) and the page, the node tree with
//! its layout, and the backend (GTK, Android views) behind a small vtable.
//!
//! Everything runs on the UI thread. After every call into JavaScript the
//! engine runs the pending promise jobs, lets the page render (ops → tree),
//! lays the tree out and tells the backend.

const std = @import("std");
const tree_mod = @import("tree.zig");
pub const Tree = tree_mod.Tree;
pub const Node = tree_mod.Node;

const log = std.log.scoped(.native_ui);

/// The JS side, built from src/native_ui/js (npm run build).
const runtime_js = @embedFile("runtime.js");

extern fn oqjs_new(opaque_ptr: *anyopaque, platform_json: [*:0]const u8, label: [*:0]const u8) ?*anyopaque;
extern fn oqjs_eval(h: *anyopaque, code: [*]const u8, len: usize, name: [*:0]const u8) c_int;
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
    /// The tree was laid out (or scrolled): update the views, redraw.
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
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    js: *anyopaque,
    tree: Tree,
    backend: Backend,
    assets: []const Asset,
    script_buf: std.ArrayList(u8) = .empty,
    booted: bool = false,
    in_call: u32 = 0,

    pub fn create(gpa: std.mem.Allocator, backend: Backend, assets: []const Asset, platform_json: [:0]const u8, label: [:0]const u8, width: f32, height: f32) !*Engine {
        const e = try gpa.create(Engine);
        errdefer gpa.destroy(e);
        e.* = .{
            .gpa = gpa,
            .js = undefined,
            .tree = Tree.init(gpa, backend.ctx, backend.measure),
            .backend = backend,
            .assets = assets,
        };
        e.tree.width = width;
        e.tree.height = height;
        e.tree.on_remove = backend.removed;
        e.tree.on_props = backend.props;
        e.js = oqjs_new(e, platform_json.ptr, label.ptr) orelse return error.QuickJsInitFailed;
        if (oqjs_eval(e.js, runtime_js.ptr, runtime_js.len, "runtime.js") < 0) return error.RuntimeFailed;
        return e;
    }

    pub fn destroy(e: *Engine) void {
        oqjs_free(e.js);
        e.tree.deinit();
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
        const r = oqjs_eval(e.js, script.ptr, script.len, "<native>");
        e.in_call -= 1;
        if (r < 0) log.err("native ui: in {s}", .{script[0..@min(script.len, 160)]});
        if (e.in_call == 0) e.settle();
        return r == 1;
    }

    /// After JS ran: microtasks, the page's render, layout.
    fn settle(e: *Engine) void {
        oqjs_run_jobs(e.js);
        const render = "__oriel.render()";
        e.in_call += 1;
        _ = oqjs_eval(e.js, render, render.len, "<render>");
        e.in_call -= 1;
        oqjs_run_jobs(e.js);
        if (e.tree.dirty) {
            e.tree.layout();
            e.backend.laid_out(e.backend.ctx);
        }
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
    const a = App.findAsset(e.assets, path[0..len], false) orelse return 0;
    out.* = a.data.ptr;
    out_len.* = a.data.len;
    return 1;
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

export fn oriel_nui_frame(p: *anyopaque, id: f64, out: *[5]f64) c_int {
    const e = engineOf(p);
    if (e.tree.dirty) e.tree.layout();
    const n = e.tree.get(@intFromFloat(id)) orelse return 0;
    out.* = .{ n.frame.x, n.frame.y, n.frame.w, n.frame.h, @max(n.content_h, n.frame.h) };
    return 1;
}

export fn oriel_nui_focus(p: *anyopaque, id: f64) void {
    const e = engineOf(p);
    if (e.tree.dirty) e.tree.layout();
    const n = e.tree.get(@intFromFloat(id)) orelse return;
    e.backend.focus(e.backend.ctx, n);
}

export fn oriel_nui_scroll_into_view(p: *anyopaque, id: f64, block: [*]const u8, len: usize) void {
    const e = engineOf(p);
    if (e.tree.dirty) e.tree.layout();
    const n = e.tree.get(@intFromFloat(id)) orelse return;
    e.tree.scrollIntoView(n, block[0..len]);
    e.backend.laid_out(e.backend.ctx);
}

export fn oriel_nui_scroll_to(p: *anyopaque, id: f64, y: f64) void {
    const e = engineOf(p);
    const n = e.tree.get(@intFromFloat(id)) orelse return;
    n.scroll_y = @floatCast(y);
    e.tree.replace();
    e.backend.laid_out(e.backend.ctx);
}
