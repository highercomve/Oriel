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
/// Files dropped into the page (Engine.drops).
pub const drop = @import("drop.zig");
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

extern fn oqjs_new(opaque_ptr: *anyopaque, platform_json: [*:0]const u8, label: [*:0]const u8, url: [*:0]const u8, refuse_eval: c_int) ?*anyopaque;

/// The directive governing scripts in a CSP: script-src, else default-src.
fn scriptDirective(csp: []const u8) ?[]const u8 {
    var governing: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, csp, ';');
    while (it.next()) |raw| {
        const d = std.mem.trim(u8, raw, " \t\r\n");
        const name = d[0 .. std.mem.indexOfAny(u8, d, " \t") orelse d.len];
        if (std.ascii.eqlIgnoreCase(name, "script-src")) return d;
        if (std.ascii.eqlIgnoreCase(name, "default-src")) governing = d;
    }
    return governing;
}

/// The app's CSP refusing inline event handlers (onclick="…"), as a
/// WebView does: the script directive without 'unsafe-inline' (or with a
/// nonce or a hash, which turn it off). Its message, or null when allowed.
pub fn inlineRefusal(buf: []u8, csp: ?[]const u8) ?[:0]const u8 {
    const d = scriptDirective(csp orelse return null) orelse return null;
    const unsafe_inline = std.mem.indexOf(u8, d, "'unsafe-inline'") != null;
    const keyed = std.mem.indexOf(u8, d, "'nonce-") != null or std.mem.indexOf(u8, d, "'sha256-") != null or
        std.mem.indexOf(u8, d, "'sha384-") != null or std.mem.indexOf(u8, d, "'sha512-") != null;
    if (unsafe_inline and !keyed) return null;
    return std.fmt.bufPrintSentinel(buf, "Refused to execute a script for an inline event handler because 'unsafe-inline' does not appear in the script-src directive of the Content Security Policy: \"{s}\".", .{d}, 0) catch null;
}

/// The app's CSP (security.csp) refusing the page's eval of strings, as a
/// WebView does: the directive that governs scripts (script-src, else
/// default-src) without 'unsafe-eval'. Its message (WebKit's, with the
/// directive as written), or null when the page may (no CSP, no such
/// directive, or 'unsafe-eval' in it).
pub fn evalRefusal(buf: []u8, csp: ?[]const u8) ?[:0]const u8 {
    const d = scriptDirective(csp orelse return null) orelse return null;
    if (std.mem.indexOf(u8, d, "'unsafe-eval'") != null) return null;
    return std.fmt.bufPrintSentinel(buf, "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script in the following Content Security Policy directive: \"{s}\".", .{d}, 0) catch null;
}

/// A page's checks run in an engine under the app's CSP `csp`: true when
/// the script's value is.
fn underCsp(csp: ?[]const u8, script: []const u8) !bool {
    const app = @import("../core/App.zig");
    const saved = app.current_security;
    defer app.current_security = saved;
    page_errors_expected = true;
    defer page_errors_expected = false;
    app.current_security.csp = csp;
    const Stub = struct {
        fn measure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 0, 0 };
        }
        fn none(_: *anyopaque) void {}
        fn removed(_: *anyopaque, _: *Node) void {}
        fn timer(_: *anyopaque, _: *Engine, _: u32, _: u32) void {}
        fn invoke(_: *anyopaque, _: *Engine, _: u32, _: []const u8, _: []const u8) void {}
        fn focus(_: *anyopaque, _: *Node) void {}
    };
    var ctx: u8 = 0;
    const e = try Engine.create(std.testing.allocator, .{
        .ctx = &ctx,
        .measure = Stub.measure,
        .laid_out = Stub.none,
        .removed = Stub.removed,
        .add_timer = Stub.timer,
        .invoke = Stub.invoke,
        .focus = Stub.focus,
    }, &.{}, "{}", "main", "app://app/index.html", 400, 300);
    defer e.destroy();
    return oqjs_eval(e.js, script.ptr, script.len, "<test>") == 1;
}

test "the app's CSP: eval and new Function refused without 'unsafe-eval', the host hidden" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    const refused =
        \\(() => {
        \\  const refuses = (f) => { try { f(); return false; } catch (e) { return e instanceof EvalError && e.message.includes("'unsafe-eval'"); } };
        \\  return refuses(() => eval("1")) && refuses(() => (0, eval)("2")) && refuses(() => new Function("return 3")) &&
        \\    refuses(() => Function.prototype.constructor("return 4")) && eval(42) === 42 && typeof __host === "undefined" &&
        \\    (() => { try { eval("1"); } catch (e) { return e instanceof EvalError; } })();
        \\})()
    ;
    try std.testing.expect(try underCsp("default-src 'self'; script-src 'self' 'unsafe-inline'", refused));
    const allowed =
        \\eval("1 + 1") === 2 && (0, eval)("2") === 2 && new Function("return 3")() === 3 && typeof __host === "undefined"
    ;
    try std.testing.expect(try underCsp("default-src 'self'; script-src 'self' 'unsafe-eval'", allowed));
    // No way to the host's text runners: a getter on Object.prototype for
    // what the runtime reads (it never sees the host), boot again (it runs
    // the document's scripts once), or a replaced __oriel.
    const sealed =
        \\(() => {
        \\  let seen = null;
        \\  for (const p of ["prof", "paintOps", "canvasOps", "now", "warmFonts", "evalScript"])
        \\    Object.defineProperty(Object.prototype, p, { configurable: true, get() { if (this && (this.evalScript || this.ops)) seen = this; return undefined; } });
        \\  __oriel.boot(400, 300, false, false);
        \\  document.body.append(document.createElement("div"));
        \\  __oriel.render();
        \\  const again = __oriel.boot(400, 300, false, false);
        \\  try { __oriel = {}; } catch {}
        \\  return seen === null && again === undefined && typeof __oriel.boot === "function" && Object.isFrozen(__oriel);
        \\})()
    ;
    try std.testing.expect(try underCsp("default-src 'self'", sealed));
    try std.testing.expect(try underCsp(null, allowed));
}

test "drops: host.fileRead is queued for the engine's next turn, drags answer a mask" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    if (comptime !(@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows)) return error.SkipZigTest;
    const Stub = struct {
        var timers: std.ArrayList(u32) = .empty;
        fn measure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 0, 0 };
        }
        fn none(_: *anyopaque) void {}
        fn removed(_: *anyopaque, _: *Node) void {}
        fn timer(_: *anyopaque, _: *Engine, id: u32, _: u32) void {
            timers.append(std.testing.allocator, id) catch {};
        }
        fn invoke(_: *anyopaque, _: *Engine, _: u32, _: []const u8, _: []const u8) void {}
        fn focus(_: *anyopaque, _: *Node) void {}
    };
    defer Stub.timers.deinit(std.testing.allocator);
    var ctx: u8 = 0;
    const e = try Engine.create(std.testing.allocator, .{
        .ctx = &ctx,
        .measure = Stub.measure,
        .laid_out = Stub.none,
        .removed = Stub.removed,
        .add_timer = Stub.timer,
        .invoke = Stub.invoke,
        .focus = Stub.focus,
    }, &.{}, "{}", "main", "app://app/index.html", 400, 300);
    defer e.destroy();
    e.boot(false, false);
    Stub.timers.clearRetainingCapacity();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "abc" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/f.txt", .{path_buf[0..len]}, 0);
    defer std.testing.allocator.free(path);
    const handle = (try e.drops.addPath(path)).?;

    // Two reads: one turn, nothing answered inside the calls.
    oriel_nui_file_read(e, 1, handle, 0, 3);
    oriel_nui_file_read(e, 2, handle + 100, 0, 3);
    try std.testing.expectEqual(@as(usize, 2), e.file_reads.items.len);
    try std.testing.expectEqualSlices(u32, &.{Engine.task_timer_id}, Stub.timers.items);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try std.testing.expect(e.fileReadInto(e.file_reads.items[0], &buf) == null);
    try std.testing.expectEqualStrings("abc", buf.items);
    try std.testing.expectEqualStrings("NotFoundError", e.fileReadInto(e.file_reads.items[1], &buf).?);
    try std.testing.expectEqualStrings("NotReadableError", e.fileReadInto(.{ .req_id = 3, .handle = handle, .offset = null, .len = 3 }, &buf).?);
    try std.testing.expect(jsIndex(-1) == null and jsIndex(1.5) == null and jsIndex(std.math.inf(f64)) == null and jsIndex(7).? == 7);

    // The turn answers them (once the runtime has __oriel.fileData).
    const has_file_data = "typeof __oriel.fileData === \"function\"";
    if (oqjs_eval(e.js, has_file_data, has_file_data.len, "<test>") == 1) {
        e.timerFired(Engine.task_timer_id);
        try std.testing.expectEqual(@as(usize, 0), e.file_reads.items.len);
    }
    oriel_nui_file_release(e, handle);
    try std.testing.expectEqual(@as(usize, 0), e.drops.count());

    // A drag's answer is a mask (0 from a runtime without drags).
    const mask = e.dragEvent(0, "[\"enter\",10,10,7,1,0,1,[[\"file\",\"\"]]]");
    try std.testing.expect(mask & ~@as(u8, 7) == 0);
    _ = e.dragEvent(0, "[\"leave\",1]");
}

test "evalRefusal: script-src, else default-src, without 'unsafe-eval'" {
    var buf: [512]u8 = undefined;
    try std.testing.expect(evalRefusal(&buf, null) == null);
    try std.testing.expect(evalRefusal(&buf, "img-src 'self'") == null);
    try std.testing.expect(evalRefusal(&buf, "script-src 'self' 'unsafe-eval'") == null);
    try std.testing.expect(evalRefusal(&buf, "default-src 'self'; script-src 'self' 'unsafe-eval'") == null);
    try std.testing.expectEqualStrings(
        "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script in the following Content Security Policy directive: \"script-src 'self' 'unsafe-inline'\".",
        evalRefusal(&buf, "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self'").?,
    );
    try std.testing.expect(std.mem.indexOf(u8, evalRefusal(&buf, "default-src 'self'").?, "directive: \"default-src 'self'\"") != null);
    // Inline handlers: 'unsafe-inline' (unless a nonce or hash turns it off).
    try std.testing.expect(inlineRefusal(&buf, null) == null);
    try std.testing.expect(inlineRefusal(&buf, "script-src 'self' 'unsafe-inline'") == null);
    try std.testing.expect(inlineRefusal(&buf, "script-src 'self'") != null);
    try std.testing.expect(inlineRefusal(&buf, "script-src 'self' 'unsafe-inline' 'sha256-abc='") != null);
}
extern fn oqjs_eval(h: *anyopaque, code: [*]const u8, len: usize, name: [*:0]const u8) c_int;
extern fn oqjs_event(h: *anyopaque, id: i64, kind: [*]const u8, kind_len: usize, json: [*]const u8, json_len: usize) c_int;
extern fn oqjs_event_code(h: *anyopaque, id: i64, kind: [*]const u8, kind_len: usize, json: [*]const u8, json_len: usize, out: *i32) c_int;
extern fn oqjs_file_data(h: *anyopaque, req_id: u32, data: [*]const u8, len: usize, has_data: c_int, err: [*]const u8, err_len: usize) c_int;
extern fn oqjs_number_call(h: *anyopaque, name: [*:0]const u8, value: f64) c_int;
extern fn oqjs_render(h: *anyopaque) c_int;
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
    /// The app's CSP refusing the page's eval, and inline event handlers:
    /// the messages (owned), null where it allows them.
    csp_eval: ?[:0]u8 = null,
    csp_handlers: ?[:0]u8 = null,
    booted: bool = false,
    in_call: u32 = 0,
    /// The color scheme the page last heard (resize's `dark`): a theme
    /// switch at the same size still reaches it.
    dark: ?bool = null,
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
    /// Files dropped into the page, by the handles the page holds
    /// (docs/drag-and-drop-design.md, section 3). Closed with the engine.
    drops: drop.DropFiles,
    /// host.fileRead calls waiting for their turn (runFileReads), and
    /// whether that turn is scheduled.
    file_reads: std.ArrayList(FileRead) = .empty,
    file_task_pending: bool = false,

    /// A host.fileRead: `len` bytes of `handle` from `offset`. Null
    /// `offset` or `len`: the page passed something that isn't an index.
    pub const FileRead = struct { req_id: u32, handle: u32, offset: ?u64, len: ?u64 };

    /// The timer id of the engine's own turn (runFileReads): the page's
    /// timers count from 1.
    pub const task_timer_id: u32 = 0;

    /// Drag effects (the "drag" event's masks), as Win32's DROPEFFECT_*.
    pub const drag_copy: u8 = 1;
    pub const drag_move: u8 = 2;
    pub const drag_link: u8 = 4;

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
            .drops = .init(gpa),
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
        // The app's CSP: eval and new Function refused, as its WebView would.
        const csp = @import("../core/App.zig").current_security.csp;
        var refusal_buf: [1024]u8 = undefined;
        if (evalRefusal(&refusal_buf, csp)) |r| e.csp_eval = try gpa.dupeZ(u8, r);
        errdefer if (e.csp_eval) |r| gpa.free(r);
        var inline_buf: [1024]u8 = undefined;
        if (inlineRefusal(&inline_buf, csp)) |r| e.csp_handlers = try gpa.dupeZ(u8, r);
        errdefer if (e.csp_handlers) |r| gpa.free(r);
        e.js = oqjs_new(e, platform_json.ptr, label.ptr, url.ptr, @intFromBool(e.csp_eval != null)) orelse return error.QuickJsInitFailed;
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
        // After the page: nothing reads them any more.
        e.drops.deinit();
        e.file_reads.deinit(e.gpa);
        if (e.page_override) |page| e.gpa.free(page);
        e.tree.deinit();
        if (e.backend.deinit) |deinit| deinit(e.backend.ctx);
        e.script_buf.deinit(e.gpa);
        if (e.csp_eval) |r| e.gpa.free(r);
        if (e.csp_handlers) |r| e.gpa.free(r);
        e.gpa.destroy(e);
    }

    /// Load the page: stylesheets, scripts, the first frame.
    pub fn boot(e: *Engine, dark: bool, coarse: bool) void {
        e.dark = dark;
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
        e.in_call += 1;
        const t0 = prof.now();
        const r = oqjs_event(e.js, id, kind.ptr, kind.len, data_json.ptr, data_json.len);
        return e.finishDispatch(r, t0, kind);
    }

    /// A drag over the page, or a drop (docs/drag-and-drop-design.md,
    /// section 1): `__oriel.event(id, "drag", data)` on the hit-tested
    /// node (0: none), `data` the phase's JSON array. The page's effect
    /// mask (copy 1, move 2, link 4); 0 when it threw.
    pub fn dragEvent(e: *Engine, id: i64, data_json: []const u8) u8 {
        e.in_call += 1;
        const t0 = prof.now();
        const kind = "drag";
        var code: i32 = 0;
        const r = oqjs_event_code(e.js, id, kind.ptr, kind.len, data_json.ptr, data_json.len, &code);
        _ = e.finishDispatch(if (r < 0) -1 else 0, t0, kind);
        if (r < 0) return 0;
        return @as(u8, @truncate(@as(u32, @bitCast(code)))) & (drag_copy | drag_move | drag_link);
    }

    /// A JSON message for the page (Android's events), see `__oriel.message`.
    pub fn message(e: *Engine, json: []const u8) void {
        _ = e.callf("__oriel.message({s})", .{json});
    }

    /// The system back button: true when the page went back.
    pub fn back(e: *Engine) bool {
        return e.event(0, "back", "null");
    }

    pub fn timerFired(e: *Engine, id: u32) void {
        if (id == task_timer_id) return e.runFileReads();
        _ = e.callNumber("timer", @floatFromInt(id));
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
            _ = e.callNumber("vsync", interval_ms);
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

    /// host.fileRead: queued, and answered on the engine's next turn
    /// (never inside the call: reads are asynchronous, as a browser's are).
    fn queueFileRead(e: *Engine, read: FileRead) void {
        e.file_reads.append(e.gpa, read) catch {
            log.err("native ui: no memory for a file read", .{});
            return;
        };
        if (e.file_task_pending) return;
        e.file_task_pending = true;
        e.backend.add_timer(e.backend.ctx, e, task_timer_id, 0);
    }

    /// The queued reads, each answered through __oriel.fileData. Reads the
    /// page asks for while these are answered wait for the next turn.
    fn runFileReads(e: *Engine) void {
        e.file_task_pending = false;
        if (e.file_reads.items.len == 0) return;
        var reads = e.file_reads;
        e.file_reads = .empty;
        defer reads.deinit(e.gpa);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(e.gpa);
        e.in_call += 1;
        const t0 = prof.now();
        var failed = false;
        for (reads.items) |r| {
            buf.clearRetainingCapacity();
            const err_name = fileReadInto(e, r, &buf);
            const name = err_name orelse "";
            if (oqjs_file_data(e.js, r.req_id, buf.items.ptr, buf.items.len, @intFromBool(err_name == null), name.ptr, name.len) < 0) failed = true;
        }
        _ = e.finishDispatch(if (failed) -1 else 0, t0, "fileData");
    }

    /// One read into `buf`: null, or the DOMException name the page gets.
    fn fileReadInto(e: *Engine, r: FileRead, buf: *std.ArrayList(u8)) ?[]const u8 {
        const offset = r.offset orelse return "NotReadableError";
        const len = r.len orelse return "NotReadableError";
        e.drops.read(r.handle, offset, len, buf) catch |err| switch (err) {
            error.BadHandle => return "NotFoundError",
            error.NotReadable => return "NotReadableError",
            else => {
                log.warn("native ui: a dropped file's read: {s}", .{@errorName(err)});
                return "NotReadableError";
            },
        };
        return null;
    }

    /// A command's answer: `json` is its result, or the error text when !ok.
    pub fn resolve(e: *Engine, call_id: u32, ok: bool, json: []const u8) void {
        const quoted = std.json.Stringify.valueAlloc(e.gpa, json, .{}) catch return;
        defer e.gpa.free(quoted);
        _ = e.callf("__oriel.resolve({d},{},{s})", .{ call_id, ok, quoted });
    }

    pub fn resize(e: *Engine, width: f32, height: f32, dark: bool) void {
        if (width == e.tree.width and height == e.tree.height and e.dark == dark) return;
        e.dark = dark;
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

    fn callNumber(e: *Engine, name: [:0]const u8, value: f64) bool {
        e.in_call += 1;
        const t0 = prof.now();
        return e.finishDispatch(oqjs_number_call(e.js, name.ptr, value), t0, name);
    }

    /// Direct calls keep the same nesting, microtask and rendering semantics.
    fn finishDispatch(e: *Engine, result: c_int, started: f64, name: []const u8) bool {
        if (e.in_call == 1) prof.report("call {d:.2} {s}", .{ prof.now() - started, name });
        e.in_call -= 1;
        if (result < 0) log.err("native ui: in {s}", .{name});
        if (e.in_call == 0) e.settle();
        return result == 1;
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
        e.in_call += 1;
        _ = oqjs_render(e.js);
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

/// The app's CSP's refusal for this engine (qjs_shim.c): 0 of the page's
/// eval, 1 of inline event handlers; null where it allows them.
export fn oriel_nui_csp(p: *anyopaque, which: c_int) ?[*:0]const u8 {
    const e = engineOf(p);
    const r = if (which == 0) e.csp_eval else e.csp_handlers;
    return if (r) |m| m.ptr else null;
}

/// Tests that expect the page's errors (a CSP violation) hear them as info.
var page_errors_expected = false;

export fn oriel_nui_log(p: *anyopaque, level: c_int, msg: [*]const u8, len: usize) void {
    _ = p;
    const s = msg[0..len];
    if (page_errors_expected and level >= 3) return log.info("page: {s}", .{s});
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

/// host.paint(Float64Array): the "x" channel as numbers (Tree.applyPaint):
/// transform and opacity changes without JSON.
export fn oriel_nui_paint(p: *anyopaque, nums: [*]const f64, len: usize) void {
    const e = engineOf(p);
    e.tree.applyPaint(nums[0..len]);
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

/// host.runRects(id, first, last): the line fragments of a text node's
/// runs (Backend.run_rects), [x, y, w, h] each into `out` (at most `max`);
/// how many, -1 when the backend has none (the caller takes the node's
/// frame).
export fn oriel_nui_run_rects(p: *anyopaque, id: f64, first: f64, last: f64, out: [*]f64, max: usize) c_int {
    const e = engineOf(p);
    const run_rects = e.backend.run_rects orelse return -1;
    if (e.tree.needsLayout()) {
        e.tree.layout();
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return 0;
    if (n.kind != .text or !(first >= 0) or !(last >= first) or last > 1 << 20) return 0;
    var buf: [64][4]f32 = undefined;
    const k = run_rects(e.backend.ctx, n, @intFromFloat(first), @intFromFloat(last), buf[0..@min(max, buf.len)]);
    for (buf[0..k], 0..) |r, i| for (r, 0..) |v, j| {
        out[i * 4 + j] = v;
    };
    return @intCast(k);
}

/// host.fontMetrics(size, mono, family?): [ascent, descent, gap] and, from
/// font_metrics_family, the x-height (returns 4; 3 without it); 0 when
/// the backend has none.
export fn oriel_nui_font_metrics(p: *anyopaque, size: f64, mono: c_int, family: ?[*]const u8, family_len: usize, out: *[4]f64) c_int {
    const e = engineOf(p);
    var m: [3]f32 = undefined;
    const sz: f32 = @floatCast(std.math.clamp(size, 1, 512));
    if (family != null and family_len > 0) if (e.backend.font_metrics_family) |metrics| {
        if (metrics(e.backend.ctx, sz, mono != 0, family.?[0..family_len], &m)) {
            out.* = .{ m[0], m[1], m[2], 0 };
            const xh = if (e.backend.font_x_height) |f| f(e.backend.ctx, sz, mono != 0, family.?[0..family_len]) else null;
            if (xh) |v| {
                out[3] = v;
                return 4;
            }
            return 3;
        }
    };
    const metrics = e.backend.font_metrics orelse return 0;
    if (!metrics(e.backend.ctx, sz, mono != 0, &m)) return 0;
    out.* = .{ m[0], m[1], m[2], 0 };
    return 3;
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

export fn oriel_nui_frame(p: *anyopaque, id: f64, out: *[9]f64) c_int {
    const e = engineOf(p);
    if (e.tree.needsLayout()) {
        const t0 = prof.now();
        e.tree.layout();
        prof.report("flayout {d:.2}", .{prof.now() - t0});
        e.relaid = true;
    }
    const n = e.tree.get(Tree.idOf(id)) orelse return 0;
    // [x, y, w, h, scrollHeight (the padding box's content: no borders),
    // the scrollbar's room (clientWidth leaves it out), scrollTop, scrollLeft,
    // scrollWidth (as scrollHeight; at least the clientWidth)].
    const yg = tree_mod.yg;
    const bt = yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeTop);
    const bb = yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeBottom);
    const bl = yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeLeft);
    const br = yg.YGNodeLayoutGetBorder(n.yn, yg.YGEdgeRight);
    const scroll_w = @max(n.content_w - bl - br, n.frame.w - bl - br - n.gutter);
    out.* = .{ n.frame.x, n.frame.y, n.frame.w, n.frame.h, @max(0, @max(n.content_h, n.frame.h) - bt - bb), n.gutter, n.scroll_y, n.scroll_x, @max(0, scroll_w) };
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

/// host.fileRead(reqId, handle, offset, length): queued (Engine.queueFileRead).
export fn oriel_nui_file_read(p: *anyopaque, req_id: u32, handle: u32, offset: f64, length: f64) void {
    engineOf(p).queueFileRead(.{ .req_id = req_id, .handle = handle, .offset = jsIndex(offset), .len = jsIndex(length) });
}

/// host.fileRelease(handle): the page holds no File for it any more.
export fn oriel_nui_file_release(p: *anyopaque, handle: u32) void {
    engineOf(p).drops.release(handle);
}

/// A JS number that is a whole, non-negative safe integer; else null.
fn jsIndex(v: f64) ?u64 {
    if (!std.math.isFinite(v) or v < 0 or v > 9007199254740991 or @floor(v) != v) return null;
    return @intFromFloat(v);
}

test {
    _ = @import("prof.zig");
    // Pure Zig, used by the Apple backends (apple_draw.zig): tested everywhere.
    _ = @import("svg_path.zig");
    _ = @import("tree.zig");
    // The Apple drawing (ImageIO, CoreText): tested where it runs.
    if (comptime @import("builtin").os.tag == .macos) _ = @import("apple_draw.zig");
}
