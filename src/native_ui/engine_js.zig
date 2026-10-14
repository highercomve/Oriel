//! The native renderer's engine, one per window (docs/native-renderer.md):
//! QuickJS running the JS side (runtime.js) and the page, the node tree with
//! its layout, and the backend (GTK, Android views) behind a small vtable.
//!
//! Everything runs on the UI thread. After every call into JavaScript the
//! engine runs the pending promise jobs, lets the page render (ops → tree),
//! lays the tree out and tells the backend.

const std = @import("std");
const builtin = @import("builtin");
const exporter = @import("oriel_export.zig");
const tree_mod = @import("tree.zig");
const prof = @import("prof.zig");
const web_storage = @import("web_storage.zig");
/// Files dropped into the page (Engine.drops).
pub const drop = @import("drop.zig");
pub const Tree = tree_mod.Tree;
pub const Node = tree_mod.Node;

const log = std.log.scoped(.native_ui);

/// The JS side, built from src/native_ui/js (npm run build) into runtime.js,
/// as QuickJS bytecode (compiled at build time: tools/qjs_bytecode.c).
const runtime_bytecode = @import("runtime_bytecode").data;

// The native DOM's C API (dom_qjs.c calls it), and rows stamped from it
// (host.stamp).
const dom_stamp = @import("dom_stamp.zig");
comptime {
    _ = @import("dom/capi.zig");
}

test {
    _ = dom_stamp;
}

/// host.stamp(rowId, row, plan): row element `row` (a DOM store index in
/// `dom`) stamped as tree row `row_id` (dom_stamp.zig); 0 when declined.
export fn oriel_nui_stamp(p: *anyopaque, row_id: f64, dom: *anyopaque, row: u32, plan: u32) c_int {
    const e = engineOf(p);
    const ok = dom_stamp.stamp(&e.tree, @ptrCast(@alignCast(dom)), row, Tree.idOf(row_id), plan) catch return 0;
    return @intFromBool(ok);
}

/// host.stampList(listId, list, rowStyle, plan, template, kept): a list's
/// rows but its template and kept ones stamped by the tree
/// (dom_stamp.stampList); 0 when declined.
export fn oriel_nui_stamp_list(p: *anyopaque, list_id: f64, dom: *anyopaque, list: u32, row_style: f64, plan: u32, template: u32, kept: [*]const u32, kept_len: usize) c_int {
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
    const app = @import("../core/internal.zig");
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

test "location.reload starts the page again on its own turn; the old page's timers stay out" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    if (comptime !(@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows)) return error.SkipZigTest;
    const Stub = struct {
        var timers: std.ArrayList(u32) = .empty;
        var removed_count: usize = 0;
        fn measure(_: *anyopaque, _: *Node, _: f32, out: *[2]f32) void {
            out.* = .{ 0, 0 };
        }
        fn none(_: *anyopaque) void {}
        fn removed(_: *anyopaque, _: *Node) void {
            removed_count += 1;
        }
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

    // The old page: state, nodes, and a timer still pending.
    Stub.timers.clearRetainingCapacity();
    try std.testing.expect(e.call("globalThis.mark = 1; for (let i = 0; i < 5; i++) document.body.append(document.createElement('div')); setTimeout(() => { globalThis.fired = 1; }, 10); true"));
    try std.testing.expect(Stub.timers.items.len >= 1);
    const old_timer = Stub.timers.items[Stub.timers.items.len - 1];
    const old_serial = e.serial;

    // Asked from inside the page: nothing happens until its own turn.
    Stub.timers.clearRetainingCapacity();
    _ = e.call("location.reload()");
    try std.testing.expect(e.call("globalThis.mark === 1"));
    try std.testing.expectEqual(Engine.reload_timer_id, Stub.timers.items[Stub.timers.items.len - 1]);

    Stub.removed_count = 0;
    e.timerFired(Engine.reload_timer_id);
    try std.testing.expect(e.serial != old_serial);
    try std.testing.expect(Stub.removed_count > 0); // the old views went
    try std.testing.expect(e.call("typeof globalThis.mark === 'undefined'"));
    try std.testing.expect(e.call("document.body.children.length === 0"));

    // The old page's timer fires after the reload: not the new page's.
    e.timerFired(old_timer);
    try std.testing.expect(e.call("typeof globalThis.fired === 'undefined'"));
    // The new page's own timers still work.
    Stub.timers.clearRetainingCapacity();
    try std.testing.expect(e.call("setTimeout(() => { globalThis.fired2 = 1; }, 10); true"));
    const new_timer = Stub.timers.items[Stub.timers.items.len - 1];
    try std.testing.expect(new_timer > old_timer);
    e.timerFired(new_timer);
    try std.testing.expect(e.call("globalThis.fired2 === 1"));
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

test "drops: drop:path answers the file's path, then null once it is gone" {
    if (!@import("build_options").native_ui) return error.SkipZigTest;
    if (comptime !(@import("builtin").os.tag == .linux or @import("builtin").os.tag == .windows)) return error.SkipZigTest;
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
    e.boot(false, false);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f.txt", .data = "abc" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}" ++ std.fs.path.sep_str ++ "f.txt", .{path_buf[0..len]}, 0);
    defer std.testing.allocator.free(path);
    const handle = (try e.drops.addPath(path)).?;

    const args_known = try std.fmt.allocPrint(arena, "{{\"handle\":{d}}}", .{handle});
    const answer = try e.dropPathCommand(arena, args_known);
    try std.testing.expect(std.mem.startsWith(u8, answer, "\""));
    // The platform's separator, JSON-escaped on Windows ("C:\\...\\f.txt").
    const tail = if (comptime @import("builtin").os.tag == .windows) "\\\\f.txt\"" else "/f.txt\"";
    try std.testing.expect(std.mem.endsWith(u8, answer, tail));

    // Unknown, malformed and released handles answer null, not an error.
    try std.testing.expectEqualStrings("null", try e.dropPathCommand(arena, "{\"handle\":99}"));
    try std.testing.expectEqualStrings("null", try e.dropPathCommand(arena, "{}"));
    try std.testing.expectEqualStrings("null", try e.dropPathCommand(arena, "nonsense"));
    e.drops.release(handle);
    const args_released = try std.fmt.allocPrint(arena, "{{\"handle\":{d}}}", .{handle});
    try std.testing.expectEqualStrings("null", try e.dropPathCommand(arena, args_released));
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
extern fn oqjs_run_jobs(h: *anyopaque) c_int;
extern fn oqjs_memory(h: *anyopaque) usize;
extern fn oqjs_run_gc(h: *anyopaque) void;
extern fn oqjs_free(h: *anyopaque) void;

const App = @import("../core/App.zig");
const internal = @import("../core/internal.zig");
pub const Asset = App.Asset;

/// What a platform provides.
pub const Backend = @import("backend.zig").Backend(Engine);
pub const FontSpec = @import("backend.zig").FontSpec;

const core = @import("engine_core.zig");
const interaction = @import("interaction.zig");
const registry = core.Registry(Engine);

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
    frame_hooks: core.FrameHooks(Engine) = .{},
    /// The platform's input rules' facts (interaction.zig), and a key
    /// scroll's glide.
    platform: interaction.Platform = .{},
    glide: interaction.Glide = .{},
    /// Files dropped into the page, by the handles the page holds
    /// (docs/design/drag-and-drop-design.md, section 3). Closed with the engine.
    drops: drop.DropFiles,
    /// host.fileRead calls waiting for their turn (runFileReads), and
    /// whether that turn is scheduled.
    file_reads: std.ArrayList(FileRead) = .empty,
    file_task_pending: bool = false,
    /// What the page was started with, for location.reload() (owned).
    start_platform: [:0]const u8 = "",
    start_label: [:0]const u8 = "",
    start_url: [:0]const u8 = "",
    coarse: bool = false,
    /// location.reload() asked for a new page: it starts on its own turn
    /// (reload_timer_id), never inside the call that asked.
    reload_pending: bool = false,
    /// Promise jobs are left for a turn of their own (jobs_timer_id).
    jobs_pending: bool = false,
    /// The page's timer ids reach the backend offset by this: a reload
    /// moves it past every id the old page used, so an old timer that
    /// fires afterwards is told apart from the new page's.
    timer_base: u32 = 0,
    timer_next: u32 = 1,
    /// ORIEL_NUI_EXPORT: the views exported so far, each with its
    /// variants (views.zig lists them), and the answers exports wait to
    /// give on a turn of their own.
    exports: std.ArrayList(*ExportView) = .empty,
    export_answers: std.ArrayList(ExportAnswer) = .empty,

    const ExportAnswer = struct { call_id: u32, ok: bool, json: []u8 };
    const ExportView = struct {
        name: []u8,
        /// The default first, once it's exported.
        variants: std.ArrayList(ExportVariant) = .empty,
    };
    /// A view as the page was at one export: `label` "" the default.
    const ExportVariant = struct {
        arena: std.heap.ArenaAllocator,
        label: []const u8,
        media: ?[]const u8,
        when: ?[]const u8 = null,
        snap: exporter.Snap,
        /// The page's names for its node ids then (the default's name the
        /// view: a variant's row was made anew, its ids aligned to them).
        names: exporter.Names = .empty,
        header: []const u8,
    };

    /// A host.fileRead: `len` bytes of `handle` from `offset`. Null
    /// `offset` or `len`: the page passed something that isn't an index.
    pub const FileRead = struct { req_id: u32, handle: u32, offset: ?u64, len: ?u64 };

    /// The timer id of the engine's own turn (runFileReads): the page's
    /// timers count from 1.
    pub const task_timer_id: u32 = 0;
    /// The timer id of a reload's turn (reloadNow).
    pub const reload_timer_id: u32 = std.math.maxInt(u32);
    /// The timer id of a turn for the promise jobs one settle left (runJobs).
    pub const jobs_timer_id: u32 = std.math.maxInt(u32) - 1;
    // (std.math.maxInt(u32) - 2: core.display_frame_timer; - 3: core.dump_timer.)
    /// The timer id of a turn for the answers exports left (exportAnswers).
    pub const export_timer_id: u32 = std.math.maxInt(u32) - 4;

    /// Drag effects (the "drag" event's masks), as Win32's DROPEFFECT_*.
    pub const drag_copy: u8 = 1;
    pub const drag_move: u8 = 2;
    pub const drag_link: u8 = 4;

    /// A Zig callback at each display frame while it returns true.
    pub const FrameHook = core.FrameHooks(Engine).Hook;

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
        e.serial = registry.newSerial();
        e.hookTree(width, height);
        e.start_platform = try gpa.dupeZ(u8, platform_json);
        e.platform = interaction.Platform.parse(gpa, platform_json);
        errdefer gpa.free(e.start_platform);
        e.start_label = try gpa.dupeZ(u8, label);
        errdefer gpa.free(e.start_label);
        e.start_url = try gpa.dupeZ(u8, url);
        errdefer gpa.free(e.start_url);
        // The app's CSP: eval and new Function refused, as its WebView would.
        const csp = @import("../core/internal.zig").current_security.csp;
        var refusal_buf: [1024]u8 = undefined;
        if (evalRefusal(&refusal_buf, csp)) |r| e.csp_eval = try gpa.dupeZ(u8, r);
        errdefer if (e.csp_eval) |r| gpa.free(r);
        var inline_buf: [1024]u8 = undefined;
        if (inlineRefusal(&inline_buf, csp)) |r| e.csp_handlers = try gpa.dupeZ(u8, r);
        errdefer if (e.csp_handlers) |r| gpa.free(r);
        e.js = try e.newRuntime();
        errdefer oqjs_free(e.js);
        try registry.add(e);
        return e;
    }

    /// The tree's size and the backend's hooks (create, and a reload's new tree).
    fn hookTree(e: *Engine, width: f32, height: f32) void {
        core.hookTree(e, width, height);
    }

    /// A QuickJS runtime with Oriel's runtime loaded, for this window.
    fn newRuntime(e: *Engine) !*anyopaque {
        const js = oqjs_new(e, e.start_platform.ptr, e.start_label.ptr, e.start_url.ptr, @intFromBool(e.csp_eval != null)) orelse return error.QuickJsInitFailed;
        errdefer oqjs_free(js);
        // Transform/opacity-only changes as "x" ops: unless the backend
        // mirrors props (mirrors_props) without a paint hook (it would miss them).
        if (!e.backend.mirrors_props or e.backend.paint != null) {
            const flag = "__host.paintOps = true";
            _ = oqjs_eval(js, flag, flag.len, "<native>");
        }
        // Canvas programs as numbers (host.canvas), likewise.
        if (!e.backend.mirrors_props or e.backend.canvas != null) {
            const flag = "__host.canvasOps = true";
            _ = oqjs_eval(js, flag, flag.len, "<native>");
        }
        if (oqjs_eval_bytecode(js, runtime_bytecode.ptr, runtime_bytecode.len) < 0) return error.RuntimeFailed;
        return js;
    }

    /// location.reload(): the page starts again in this window, from a turn
    /// of its own. The old page's runtime, nodes (the backend drops their
    /// views through `removed`), dropped files and frame hooks go; the
    /// engine takes a new serial, so answers to the old page's calls are
    /// dropped, and old timers are told apart by `timer_base`.
    fn reloadNow(e: *Engine) void {
        if (e.busy()) {
            e.backend.add_timer(e.backend.ctx, e, reload_timer_id, 0);
            return;
        }
        e.reload_pending = false;
        // The new runtime first: if it can't start, the old page stays.
        const js = e.newRuntime() catch |err| {
            log.err("native ui: reload failed ({s}); the page stays", .{@errorName(err)});
            return;
        };
        registry.remove(e.serial);
        oqjs_free(e.js);
        e.js = js;
        e.frame_hooks.clear();
        e.glide = .{};
        e.js_frame_wanted = false;
        e.frame_pending = false;
        e.relaid = false;
        e.booted = false;
        e.drops.deinit();
        e.drops = .init(e.gpa);
        e.file_reads.clearRetainingCapacity();
        e.file_task_pending = false;
        const width = e.tree.width;
        const height = e.tree.height;
        e.tree.deinit();
        e.tree = Tree.init(e.gpa, e.backend.ctx, e.backend.measure);
        e.hookTree(width, height);
        e.serial = registry.newSerial();
        e.timer_base = e.timer_next;
        registry.add(e) catch {};
        log.info("native ui: reloading the page", .{});
        e.boot(e.dark orelse false, e.coarse);
    }

    /// The engine with this serial, if its window is still open (UI
    /// thread): what a Zig handle that outlived its window finds.
    pub fn bySerial(serial: u64) ?*Engine {
        return registry.get(serial);
    }

    /// The page's JS or the app's frame hooks are on the stack: the engine
    /// can't go yet (they'd return into it). A window closed from there
    /// closes once they've returned (the backends' busy, or destroy).
    pub fn busy(e: *const Engine) bool {
        return e.in_call > 0 or e.frame_hooks.running;
    }

    pub fn destroy(e: *Engine) void {
        registry.remove(e.serial);
        // The page's last localStorage changes, if its flush hadn't come.
        web_storage.flush();
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
        e.gpa.free(e.start_platform);
        e.gpa.free(e.start_label);
        e.gpa.free(e.start_url);
        for (e.exports.items) |v| {
            for (v.variants.items) |*variant| variant.arena.deinit();
            v.variants.deinit(e.gpa);
            e.gpa.free(v.name);
            e.gpa.destroy(v);
        }
        e.exports.deinit(e.gpa);
        for (e.export_answers.items) |a| e.gpa.free(a.json);
        e.export_answers.deinit(e.gpa);
        e.gpa.destroy(e);
    }

    /// Load the page: stylesheets, scripts, the first frame.
    pub fn boot(e: *Engine, dark: bool, coarse: bool) void {
        e.dark = dark;
        e.coarse = coarse;
        _ = e.callf("__oriel.boot({d},{d},{},{})", .{ e.tree.width, e.tree.height, dark, coarse });
        e.booted = true;
        core.scheduleDump(e);
        log.info("native ui: page booted, {d} nodes, JS heap {d} KB", .{ e.tree.nodes.count(), oqjs_memory(e.js) / 1024 });
        if (std.c.getenv("ORIEL_NUI_DUMP") != null) {
            e.tree.layout();
            e.tree.dump();
        }
        e.runExportScript();
    }

    // --- ORIEL_NUI_EXPORT: the page written as .oriel views (Linux) -----

    /// ORIEL_NUI_EXPORT_SCRIPT=<file>: run once the page booted, in an
    /// async function, to bring the page to each state and export it
    /// (`await __orielExport("name")`).
    fn runExportScript(e: *Engine) void {
        if (comptime builtin.os.tag != .linux) return;
        const path = std.c.getenv("ORIEL_NUI_EXPORT_SCRIPT") orelse return;
        const code = readFileC(e.gpa, path) orelse return log.err("native ui: can't read the export script {s}", .{path});
        defer e.gpa.free(code);
        const script = std.fmt.allocPrintSentinel(e.gpa, "(async () => {{\n{s}\n}})().catch((err) => console.error(\"export script: \" + err + (err && err.stack ? \"\\n\" + err.stack : \"\")));", .{code}, 0) catch return;
        defer e.gpa.free(script);
        e.evalScript(script);
    }

    /// `__oriel:export` (the page's __orielExport): the tree written to
    /// <ORIEL_NUI_EXPORT>/<name>.oriel and <name>.props.json, views.zig
    /// listing every view written. Answered on a turn of its own.
    fn exportCommand(e: *Engine, call_id: u32, args: []const u8) void {
        var ok = true;
        const json = e.writeExport(args) catch |err| blk: {
            ok = false;
            break :blk std.fmt.allocPrint(e.gpa, "export failed: {s}", .{@errorName(err)}) catch return;
        };
        e.export_answers.append(e.gpa, .{ .call_id = call_id, .ok = ok, .json = json }) catch {
            e.gpa.free(json);
            return;
        };
        e.backend.add_timer(e.backend.ctx, e, export_timer_id, 0);
    }

    fn exportAnswers(e: *Engine) void {
        const answers = e.export_answers.toOwnedSlice(e.gpa) catch return;
        defer e.gpa.free(answers);
        for (answers) |a| {
            defer e.gpa.free(a.json);
            e.resolve(a.call_id, a.ok, a.json);
        }
    }

    fn writeExport(e: *Engine, args: []const u8) ![]u8 {
        if (comptime builtin.os.tag != .linux) return error.Unsupported;
        const dir = std.mem.span(std.c.getenv("ORIEL_NUI_EXPORT") orelse return error.ExportFolderNotSet);
        const Viewport = struct { width: f32 = 0, height: f32 = 0, dark: bool = false };
        const Args = struct { name: []const u8, names: std.json.Value, root: ?i64 = null, hollow: []const i64 = &.{}, variant: ?[]const u8 = null, media: ?[]const u8 = null, when: ?[]const u8 = null, viewport: Viewport = .{} };
        const parsed = try std.json.parseFromSlice(Args, e.gpa, args, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        const a = parsed.value;
        if (!exportName(a.name)) return error.BadViewName;
        const label = a.variant orelse "";
        if (label.len > 0 and !exportName(label)) return error.BadVariantName;
        if ((label.len > 0) != (a.media != null or a.when != null)) return error.VariantNeedsMediaOrWhen;
        if (a.when) |w| if (!exportName(w)) return error.BadState;
        if (a.media) |m| for (m) |c| if (!(std.ascii.isAlphanumeric(c) or c == ':' or c == ' ' or c == '-' or c == '.')) return error.BadMedia;
        var names: exporter.Names = .empty;
        defer names.deinit(e.gpa);
        if (a.names == .object) {
            var it = a.names.object.iterator();
            while (it.next()) |entry| {
                const id = std.fmt.parseInt(i64, entry.key_ptr.*, 10) catch continue;
                if (entry.value_ptr.* == .string) try names.put(e.gpa, id, entry.value_ptr.string);
            }
        }
        const root = if (a.root) |id| e.tree.get(id) orelse return error.ElementNotRendered else e.tree.root orelse return error.NoPage;

        // This variant as the page is now (replacing an earlier export of it).
        var variant: ExportVariant = .{ .arena = .init(e.gpa), .label = "", .media = null, .snap = undefined, .header = "" };
        // Owned by the view once it's in its list.
        var owned = false;
        errdefer if (!owned) variant.arena.deinit();
        const va = variant.arena.allocator();
        variant.label = try va.dupe(u8, label);
        variant.media = if (a.media) |m| try va.dupe(u8, m) else null;
        variant.when = if (a.when) |w| try va.dupe(u8, w) else null;
        variant.snap = try exporter.snapshot(va, root, a.hollow);
        {
            var it = names.iterator();
            while (it.next()) |entry| try variant.names.put(va, entry.key_ptr.*, try va.dupe(u8, entry.value_ptr.*));
        }
        // An element's export (a list's row) is made anew for each variant,
        // its ids new or reused for other elements: the default's, by place.
        if (label.len > 0 and a.root != null) for (e.exports.items) |v| if (std.mem.eql(u8, v.name, a.name)) {
            if (v.variants.items.len > 0 and v.variants.items[0].label.len == 0) {
                try exporter.alignIds(&v.variants.items[0].snap, &variant.snap);
            }
        };
        variant.header = try std.json.Stringify.valueAlloc(va, .{
            .controls = .{ .check = e.tree.controls.check, .button = e.tree.controls.button },
            .width = if (a.viewport.width > 0) a.viewport.width else e.tree.width,
            .dark = a.viewport.dark,
            .states = if (a.when) |w| @as([]const []const u8, &.{w}) else &.{},
        }, .{});
        const view = for (e.exports.items) |v| {
            if (std.mem.eql(u8, v.name, a.name)) break v;
        } else blk: {
            const v = try e.gpa.create(ExportView);
            v.* = .{ .name = try e.gpa.dupe(u8, a.name) };
            try e.exports.append(e.gpa, v);
            break :blk v;
        };
        const replaced = for (view.variants.items) |*old| {
            if (std.mem.eql(u8, old.label, label)) {
                old.arena.deinit();
                old.* = variant;
                break true;
            }
        } else false;
        if (!replaced) {
            if (label.len == 0) try view.variants.insert(e.gpa, 0, variant) else try view.variants.append(e.gpa, variant);
        }
        owned = true;

        // This variant's props, for check-views.
        var props: std.Io.Writer.Allocating = .init(e.gpa);
        defer props.deinit();
        try props.writer.writeAll(variant.header);
        try props.writer.writeAll("\n");
        try exporter.props(e.gpa, &variant.snap, &props.writer);
        const props_file = if (label.len == 0) try std.fmt.allocPrint(e.gpa, "{s}.props.json", .{a.name}) else try std.fmt.allocPrint(e.gpa, "{s}@{s}.props.json", .{ a.name, label });
        defer e.gpa.free(props_file);
        try writeFileC(e.gpa, dir, props_file, props.written());

        // The view, its variants merged, once its default is exported.
        var count: usize = 0;
        if (view.variants.items.len > 0 and view.variants.items[0].label.len == 0) {
            var variants: [exporter.max_variants]exporter.Variant = undefined;
            if (view.variants.items.len > variants.len) return error.TooManyVariants;
            for (view.variants.items, 0..) |v, i| variants[i] = .{ .root = v.snap, .media = v.media, .when = v.when };
            var text: std.Io.Writer.Allocating = .init(e.gpa);
            defer text.deinit();
            count = try exporter.view(e.gpa, variants[0..view.variants.items.len], &view.variants.items[0].names, &text.writer);
            const view_file = try std.fmt.allocPrint(e.gpa, "{s}.oriel", .{a.name});
            defer e.gpa.free(view_file);
            try writeFileC(e.gpa, dir, view_file, text.written());
        }

        var index: std.Io.Writer.Allocating = .init(e.gpa);
        defer index.deinit();
        try index.writer.writeAll("//! The views ORIEL_NUI_EXPORT wrote (zig build check-views -Dviews=<this folder>).\npub const list = .{\n");
        for (e.exports.items) |v| {
            if (v.variants.items.len == 0 or v.variants.items[0].label.len > 0) continue;
            for (v.variants.items) |vv| {
                if (vv.label.len == 0) {
                    try index.writer.print("    .{{ \"{s}\", @embedFile(\"{s}.oriel\"), @embedFile(\"{s}.props.json\") }},\n", .{ v.name, v.name, v.name });
                } else try index.writer.print("    .{{ \"{s}@{s}\", @embedFile(\"{s}.oriel\"), @embedFile(\"{s}@{s}.props.json\") }},\n", .{ v.name, vv.label, v.name, v.name, vv.label });
            }
        }
        try index.writer.writeAll("};\n");
        try writeFileC(e.gpa, dir, "views.zig", index.written());
        log.info("native ui: exported {s}{s}{s} ({d} nodes)", .{ a.name, if (label.len > 0) "@" else "", label, count });
        return std.fmt.allocPrint(e.gpa, "{{\"nodes\":{d}}}", .{count});
    }

    fn exportName(name: []const u8) bool {
        if (name.len == 0 or name.len > 64) return false;
        for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return false;
        return true;
    }

    /// Evaluate a script in the page (internal.emit's `window.oriel.__emit(...)`).
    pub fn evalScript(e: *Engine, script: [:0]const u8) void {
        if (std.c.getenv("ORIEL_NUI_TRACE") != null) log.info("native ui: eval {s}", .{script[0..@min(script.len, 120)]});
        _ = e.call(script);
    }

    /// A native event on a node. True when the page prevented the default.
    /// An assistive technology came (or went): the page sends its
    /// accessibility tree (Tree.ax, the "a" ops) whole, from inside this
    /// call, and then its changes after each render; off clears it.
    pub fn setA11y(e: *Engine, on: bool) void {
        _ = e.event(0, "a11y", if (on) "1" else "0");
    }

    pub fn event(e: *Engine, id: i64, kind: []const u8, data_json: []const u8) bool {
        e.glide.stopOnTouch(kind, data_json);
        e.in_call += 1;
        const t0 = prof.now();
        const r = oqjs_event(e.js, id, kind.ptr, kind.len, data_json.ptr, data_json.len);
        return e.finishDispatch(r, t0, kind);
    }

    /// A drag over the page, or a drop (docs/design/drag-and-drop-design.md,
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

    /// The page asks where a dropped file lives now (`drop:path`, the
    /// drop-table handle it got in `drop`'s File). Answers the path as a
    /// JSON string, or `null` when the handle is unknown, its file was
    /// deleted or changed, or the platform can't resolve paths. Built for a
    /// trusted app that sends dropped files on (the design's open question
    /// #1, Electron's webUtils.getPathForFile being the precedent);
    /// `native_commands.dispatch` calls it after the command policy check.
    pub fn dropPathCommand(e: *Engine, arena: std.mem.Allocator, args_json: []const u8) ![]u8 {
        const Args = struct { handle: u32 };
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch return arena.dupe(u8, "null");
        const parsed = std.json.parseFromValueLeaky(Args, arena, value, .{}) catch return arena.dupe(u8, "null");
        const path = e.drops.nativePath(arena, parsed.handle) catch return arena.dupe(u8, "null");
        return std.fmt.allocPrint(arena, "{f}", .{std.json.fmt(path, .{})}) catch error.OutOfMemory;
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
        if (id == core.display_frame_timer) return e.displayFrame(1000.0 / 60.0);
        if (id == core.dump_timer) return core.dumpNow(e);
        if (id == reload_timer_id) return e.reloadNow();
        if (id == export_timer_id) return e.exportAnswers();
        if (id == jobs_timer_id) {
            e.jobs_pending = false;
            if (e.in_call == 0) e.settle(); // else that call's settle runs them
            return;
        }
        // Set by a page this window had before a reload: not this one's.
        if (id < e.timer_base) return;
        _ = e.callNumber("timer", @floatFromInt(id - e.timer_base));
    }

    /// The display refreshes (`Backend.request_display_frame`): the page's
    /// animation frame. `interval_ms`: the display's refresh interval (0
    /// when unknown).
    pub fn displayFrame(e: *Engine, interval_ms: f64) void {
        // Scrolls since the last frame: their events first, as a browser
        // runs scroll steps before animation frames.
        e.flushScrolls();
        // The app's Zig first (a canvas it draws), then the page's frame.
        e.frame_hooks.run(e, interval_ms);
        if (e.frame_hooks.any()) e.requestDisplayFrame();
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
        core.layoutAndShow(e);
    }

    /// Run `hook` at each display frame until it returns false (UI thread).
    pub fn addFrameHook(e: *Engine, hook: FrameHook) !void {
        try e.frame_hooks.add(e.gpa, hook);
        e.requestDisplayFrame();
    }

    /// Stop the hooks with this context (one running may cancel itself).
    pub fn removeFrameHooks(e: *Engine, ctx: *anyopaque) void {
        e.frame_hooks.remove(ctx);
    }

    /// The next display frame.
    fn requestDisplayFrame(e: *Engine) void {
        core.requestDisplayFrame(e);
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

    /// Scroll a container sideways by `dx`: true if it moved.
    pub fn scrollByX(e: *Engine, node: *Node, dx: f32) bool {
        e.glide.stopFor(node.id);
        return e.scrolled(core.moveScroll(e, node, .x, dx));
    }

    /// Scroll a container by `dy` (a wheel, a touch): true if it moved. A
    /// key scroll's glide there stops.
    pub fn scrollBy(e: *Engine, node: *Node, dy: f32) bool {
        e.glide.stopFor(node.id);
        return e.scrolled(core.moveScroll(e, node, .y, dy));
    }

    /// The glide's own scroll (interaction.Glider).
    pub fn setScrollY(e: *Engine, node: *Node, y: f32) void {
        _ = e.scrolled(core.moveScroll(e, node, .y, y - node.scroll_y));
    }

    /// Drawn now; the page hears at the next display frame (scrollsChanged).
    fn scrolled(e: *Engine, moved: bool) bool {
        if (!moved) return false;
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
        e.runJobs();
        if (!core.deferToFrame(e)) e.renderNow();
    }

    /// The pending promise jobs, as a call into the page (in_call: a job
    /// that closes the window waits for it, see busy). A chain that keeps
    /// requeuing itself goes on in a turn of its own (oqjs_run_jobs stops
    /// after so many), so the UI thread isn't held forever.
    fn runJobs(e: *Engine) void {
        e.in_call += 1;
        const left = oqjs_run_jobs(e.js) != 0;
        e.in_call -= 1;
        if (!left or e.jobs_pending) return;
        e.jobs_pending = true;
        e.backend.add_timer(e.backend.ctx, e, jobs_timer_id, 0);
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
        e.runJobs();
        const t0 = prof.now();
        core.layoutAndShow(e);
        prof.report("layout {d:.2}", .{prof.now() - t0});
        // A layout that moved a scroller (its content shrank): heard too.
        e.scrollsChanged();
    }

    /// The bytes of an app asset ("assets/x.png"), or null.
    pub fn assetData(e: *Engine, path: []const u8) ?[]const u8 {
        const a = internal.findAsset(e.assets, path, false) orelse return null;
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
        _ = e.callf("globalThis.__nuiDom?.collect()", .{});
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
    const a = internal.findAsset(e.assets, path[0..len], false) orelse return 0;
    out.* = a.data.ptr;
    out_len.* = a.data.len;
    return 1;
}

/// Debugging (Linux): ORIEL_NUI_PAGE=<file> is read for index.html instead
/// of the embedded one, so one build of an app renders any page
/// (tools/flatten_diff compares a runtime's trees step by step).
/// A whole file (debugging aids; Linux): null when it can't be read.
fn readFileC(gpa: std.mem.Allocator, file: [*:0]const u8) ?[]u8 {
    const fd = std.c.open(file, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    while (true) {
        buf.ensureUnusedCapacity(gpa, 64 * 1024) catch {
            buf.deinit(gpa);
            return null;
        };
        const n = std.c.read(fd, buf.unusedCapacitySlice().ptr, buf.unusedCapacitySlice().len);
        if (n < 0) {
            buf.deinit(gpa);
            return null;
        }
        if (n == 0) break;
        buf.items.len += @intCast(n);
    }
    return buf.toOwnedSlice(gpa) catch {
        buf.deinit(gpa);
        return null;
    };
}

/// `bytes` as <dir>/<name>, replacing it (ORIEL_NUI_EXPORT; Linux).
fn writeFileC(gpa: std.mem.Allocator, dir: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ dir, name }, 0);
    defer gpa.free(path);
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.ExportWriteFailed;
    defer _ = std.c.close(fd);
    var at: usize = 0;
    while (at < bytes.len) {
        const n = std.c.write(fd, bytes[at..].ptr, bytes.len - at);
        if (n <= 0) return error.ExportWriteFailed;
        at += @intCast(n);
    }
}

fn pageOverride(e: *Engine, path: []const u8) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    if (!std.mem.eql(u8, path, "index.html")) return null;
    if (e.page_override) |page| return page;
    const file = std.c.getenv("ORIEL_NUI_PAGE") orelse return null;
    e.page_override = readFileC(e.gpa, file);
    return e.page_override;
}

export fn oriel_nui_invoke(p: *anyopaque, call_id: u32, cmd: [*]const u8, cmd_len: usize, args: [*]const u8, args_len: usize) void {
    const e = engineOf(p);
    if (std.mem.eql(u8, cmd[0..cmd_len], "__oriel:export")) return e.exportCommand(call_id, args[0..args_len]);
    if (std.mem.eql(u8, cmd[0..cmd_len], "__oriel:export-done") and std.c.getenv("ORIEL_NUI_EXPORT") != null) {
        log.info("native ui: export done", .{});
        std.process.exit(0);
    }
    e.backend.invoke(e.backend.ctx, e, call_id, cmd[0..cmd_len], args[0..args_len]);
}

export fn oriel_nui_timer(p: *anyopaque, id: u32, ms: f64) void {
    const e = engineOf(p);
    // Past the ids every earlier page used (timer_base), clear of the
    // engine's own (task 0, the display frame's, jobs and reload).
    const backend_id = std.math.add(u32, e.timer_base, id) catch return;
    if (backend_id >= Engine.export_timer_id) return;
    if (backend_id >= e.timer_next) e.timer_next = backend_id + 1;
    e.backend.add_timer(e.backend.ctx, e, backend_id, @intFromFloat(@max(0, @min(ms, 1e9))));
}

/// host.reload(): location.reload(), on a turn of its own (reloadNow).
export fn oriel_nui_reload(p: *anyopaque) void {
    const e = engineOf(p);
    if (e.reload_pending) return;
    e.reload_pending = true;
    e.backend.add_timer(e.backend.ctx, e, Engine.reload_timer_id, 0);
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

// localStorage (web_storage.zig): the page's calls, synchronous. A value
// handed out is the engine's copy, freed by oriel_nui_storage_free.

/// host.storageGet(key): 1 and the value, or 0 when there's no such key.
export fn oriel_nui_storage_get(p: *anyopaque, key: [*]const u8, key_len: usize, out: *[*]u8, out_len: *usize) c_int {
    const v = web_storage.get(engineOf(p).gpa, key[0..key_len]) orelse return 0;
    out.* = v.ptr;
    out_len.* = v.len;
    return 1;
}

/// host.storageKey(i): 1 and the i-th key, or 0 past the end.
export fn oriel_nui_storage_key(p: *anyopaque, index: u32, out: *[*]u8, out_len: *usize) c_int {
    const k = web_storage.keyAt(engineOf(p).gpa, index) orelse return 0;
    out.* = k.ptr;
    out_len.* = k.len;
    return 1;
}

export fn oriel_nui_storage_free(p: *anyopaque, ptr: [*]u8, len: usize) void {
    engineOf(p).gpa.free(ptr[0..len]);
}

/// host.storageSet(key, value): 0 past the quota (the page throws
/// QuotaExceededError, as a browser does).
export fn oriel_nui_storage_set(_: *anyopaque, key: [*]const u8, key_len: usize, value: [*]const u8, value_len: usize) c_int {
    web_storage.set(key[0..key_len], value[0..value_len]) catch return 0;
    return 1;
}

export fn oriel_nui_storage_remove(_: *anyopaque, key: [*]const u8, key_len: usize) void {
    web_storage.remove(key[0..key_len]);
}

export fn oriel_nui_storage_clear(_: *anyopaque) void {
    web_storage.clear();
}

export fn oriel_nui_storage_length(_: *anyopaque) u32 {
    return @intCast(web_storage.count());
}

/// host.storageFlush(): the changes saved (the page asks a moment after
/// a change, so a burst of them is one write).
export fn oriel_nui_storage_flush(_: *anyopaque) void {
    web_storage.flush();
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
    e.glide.active = false;
    e.tree.scrollIntoView(n, block[0..len]);
    e.backend.laid_out(e.backend.ctx);
    e.scrollsChanged();
}

/// host.scrollTo(id, y, x): either NaN leaves that axis.
export fn oriel_nui_scroll_to(p: *anyopaque, id: f64, y: f64, x: f64) void {
    const e = engineOf(p);
    if (e.tree.needsLayout()) e.tree.layout();
    const n = e.tree.get(Tree.idOf(id)) orelse return;
    e.glide.stopFor(n.id);
    const before = .{ n.scroll_y, n.scroll_x };
    if (!std.math.isNan(y)) n.scroll_y = std.math.clamp(@as(f32, @floatCast(y)), 0, @max(0, n.content_h - n.frame.h));
    if (!std.math.isNan(x)) n.scroll_x = std.math.clamp(@as(f32, @floatCast(x)), 0, @max(0, n.content_w - n.frame.w));
    if (n.scroll_y != before[0] or n.scroll_x != before[1]) e.tree.noteScroll(n);
    e.tree.replace();
    e.backend.laid_out(e.backend.ctx);
    e.scrollsChanged();
}

/// host.keyScroll(id, key, shift): the key scrolls from node `id`'s nearest
/// scroller, else the window's (interaction.zig), gliding there.
export fn oriel_nui_key_scroll(p: *anyopaque, id: f64, key: [*]const u8, len: usize, shift: c_int) c_int {
    const e = engineOf(p);
    return @intFromBool(core.keyScroll(Engine, e, e.tree.get(Tree.idOf(id)), e.tree.get(-1), key[0..len], shift != 0) catch false);
}

/// host.isScrollKey(key): a key that scrolls (interaction.scrollStep), so
/// the page renders and looks for a scroller only for those.
export fn oriel_nui_is_scroll_key(_: *anyopaque, key: [*]const u8, len: usize) c_int {
    return @intFromBool(interaction.scrollStep(key[0..len], false) != null);
}

/// host.tabNext(json, active, back): `json` the candidates in document
/// order, `[kind, tabindex | null, group, checked]` each; the index Tab
/// moves to from index `active` (-1: none), or -1.
export fn oriel_nui_tab_next(p: *anyopaque, json: [*]const u8, len: usize, active: f64, back: c_int) f64 {
    const e = engineOf(p);
    const at: ?usize = if (active >= 0 and active < 1e9) @intFromFloat(active) else null;
    const next = interaction.tabNextJson(e.gpa, interaction.tabRule(e.platform), json[0..len], at, back != 0) catch return -1;
    return if (next) |n| @floatFromInt(n) else -1;
}

/// host.clickFocuses(kind): a click focuses an element of that kind
/// (without a tabindex) on this platform.
export fn oriel_nui_click_focuses(p: *anyopaque, kind: f64) c_int {
    const e = engineOf(p);
    const k = interaction.kindFrom(if (kind >= 0 and kind < 3) @as(u8, @intFromFloat(kind)) else 2);
    return @intFromBool(interaction.clickFocuses(interaction.tabRule(e.platform), k, false));
}

/// host.activates(key, down, repeat, button, link, checkable).
export fn oriel_nui_activates(_: *anyopaque, key: [*]const u8, len: usize, down: c_int, repeat: c_int, button: c_int, link: c_int, checkable: c_int) c_int {
    return @intFromBool(interaction.activates(key[0..len], down != 0, repeat != 0, button != 0, link != 0, checkable != 0));
}

/// host.focusRing(kind, accent): the platform's ring, `[w, o, r, red,
/// green, blue, alpha, halo]`, in the page's accent (platform.accent: the
/// page keeps it, from the platform JSON and "accent" events).
export fn oriel_nui_focus_ring(p: *anyopaque, kind: f64, has_accent: c_int, red: f64, green: f64, blue: f64, out: *[8]f64) void {
    var platform = engineOf(p).platform;
    platform.accent = if (has_accent != 0) interaction.accentOf(red, green, blue) else null;
    const r = interaction.ring(platform, interaction.ringKindFrom(if (kind >= 0 and kind < 5) @as(u8, @intFromFloat(kind)) else 4));
    out.* = interaction.ringNumbers(r);
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
    _ = @import("web_storage.zig");
    // Pure Zig, used by the Apple backends (apple_draw.zig): tested everywhere.
    _ = @import("svg_path.zig");
    _ = @import("tree.zig");
    // The Apple drawing (ImageIO, CoreText): tested where it runs.
    if (comptime @import("builtin").os.tag == .macos) _ = @import("apple_draw.zig");
}
