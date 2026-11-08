//! WebKit JS <-> Zig IPC bridge and script message handling.
//!
//! Injects `window.oriel` JS API into permitted origins and routes commands
//! through `ipc.dispatchRequest` and `ipc.dispatchAsync`. Handles synchronous
//! and asynchronous replies via WebKit's ScriptMessageReply mechanism.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const build_opts = @import("build_options");
/// -Dnative_ui links no WebKitGTK (no_webkit.zig names the null web view).
const webkit = if (build_opts.native_ui) @import("no_webkit.zig") else @import("webkit");
const jsc = if (build_opts.native_ui) struct {} else @import("jsc");
const App = @import("../../core/App.zig");
const ShellMod = @import("Shell.zig");
const internal = @import("../../core/internal.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");

const log = std.log.scoped(.oriel);
/// -Dnative_ui: pages drawn with native views (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/engine.zig") else struct {
    pub const Engine = struct {
        serial: u64 = 0,
    };
};

const bridge = @import("../../core/bridge_js.zig");
pub const handler_name = bridge.handler_name;
const token_placeholder = bridge.token_placeholder;
const isolation_placeholder = bridge.isolation_placeholder;

/// Injected into allowed pages before their own scripts run.
pub const bridge_js = bridge.script(bridge.webkit_transport);

// The generated binding marks the result non-null, but it is NULL before
// the first load.
extern fn webkit_web_view_get_uri(view: *webkit.WebView) ?[*:0]const u8;

/// Whether `view`'s current page may receive events (App.pageGetsEvents):
/// the bridge's own origins only, not whatever page the window shows now.
fn viewGetsEvents(view: *webkit.WebView, label: []const u8) bool {
    if (comptime build_opts.native_ui) return false; // links no WebKit
    const uri = webkit_web_view_get_uri(view) orelse return false;
    return internal.pageGetsEvents(std.mem.span(uri), label);
}

const dispatch = @import("../../core/bridge_dispatch.zig");
const NativeEngines = dispatch.NativeEngines(native.Engine, build_opts.native_ui, struct {
    fn evaluate(e: *native.Engine, script: [:0]const u8) void {
        if (comptime build_opts.native_ui) e.evalScript(script);
    }
}.evaluate);

pub fn nativeEngineAlive(e: *native.Engine, serial: u64) bool {
    return NativeEngines.alive(e, serial);
}

/// One type for the producer and the idle callback (it's cast back from
/// `?*anyopaque`; two identical auto-layout structs needn't share a layout).
const EvalTask = struct {
    target: ?@import("window.zig").WindowHandle,
    script: [:0]u8,
};

pub fn evalJs(target: ?@import("window.zig").WindowHandle, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const script_copy = gpa.dupeZ(u8, script) catch return;

    const task = gpa.create(EvalTask) catch {
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .target = target, .script = script_copy };
    // On the main thread (a sync command emitting), run it now: queued for
    // later, it would reach the page after the command's reply. Other
    // threads queue it (FIFO with their command's reply).
    if (glib.MainContext.default().isOwner() != 0) {
        _ = evalScriptTask(task);
    } else if (glib.idleAdd(&evalScriptTask, task) == 0) {
        gpa.free(script_copy);
        gpa.destroy(task);
    }
}

fn evalScriptTask(data: ?*anyopaque) callconv(.c) c_int {
    const task: *EvalTask = @ptrCast(@alignCast(data));
    defer {
        std.heap.smp_allocator.free(task.script);
        std.heap.smp_allocator.destroy(task);
    }
    if (task.target) |v| {
        internal.ensureWindowsMutex();
        internal.windows_mutex.lock();
        var allowed = false;
        const web_view: ?*webkit.WebView = for (internal.windows_list.items) |win| {
            if (win.handle.eql(v)) {
                if (win.handle.web_view) |view| allowed = viewGetsEvents(view, win.label);
                break win.handle.web_view;
            }
        } else null;
        internal.windows_mutex.unlock();
        if (web_view) |view| {
            if (allowed) view.evaluateJavascript(task.script, -1, null, null, null, null, null);
        } else if (comptime build_opts.native_ui) {
            if (nativeEngine(v)) |e| e.evalScript(task.script);
        }
    } else {
        var engines: NativeEngines = .{};
        internal.ensureWindowsMutex();
        internal.windows_mutex.lock();
        _ = engines.reserve(std.heap.smp_allocator, internal.windows_list.items.len);
        for (internal.windows_list.items) |win| {
            // Only to pages the bridge serves (any other could read it).
            if (win.handle.web_view) |view| if (viewGetsEvents(view, win.label)) {
                view.evaluateJavascript(task.script, -1, null, null, null, null, null);
            };
            engines.add(win);
        }
        internal.windows_mutex.unlock();
        // Outside the lock: the page may open or close windows.
        // Each still open: a page's script may close another window.
        engines.eval(task.script);
    }
    return 0; // one-shot
}

const EvalByLabelTask = struct {
    label: [:0]u8,
    script: [:0]u8,
};

pub fn evalJsByLabel(label: [:0]const u8, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const label_copy = gpa.dupeZ(u8, label) catch return;
    const script_copy = gpa.dupeZ(u8, script) catch {
        gpa.free(label_copy);
        return;
    };

    const task = gpa.create(EvalByLabelTask) catch {
        gpa.free(label_copy);
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .label = label_copy, .script = script_copy };
    // See evalJs: in order with a sync command's reply.
    if (glib.MainContext.default().isOwner() != 0) {
        _ = evalScriptByLabelTask(task);
    } else if (glib.idleAdd(&evalScriptByLabelTask, task) == 0) {
        gpa.free(label_copy);
        gpa.free(script_copy);
        gpa.destroy(task);
    }
}

fn evalScriptByLabelTask(data: ?*anyopaque) callconv(.c) c_int {
    const task: *EvalByLabelTask = @ptrCast(@alignCast(data));
    defer {
        std.heap.smp_allocator.free(task.label);
        std.heap.smp_allocator.free(task.script);
        std.heap.smp_allocator.destroy(task);
    }
    var engines: NativeEngines = .{};
    _ = engines.reserve(std.heap.smp_allocator, 1);
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    var web_view: ?*webkit.WebView = null;
    // A native window (-Dnative_ui) has an engine instead of a web view:
    // targeted events (internal.emitTo) must reach it too.
    for (internal.windows_list.items) |win| {
        if (!std.mem.eql(u8, win.label, task.label)) continue;
        if (win.handle.web_view) |view| if (viewGetsEvents(view, win.label)) {
            web_view = view;
        };
        engines.add(win);
        break;
    }
    internal.windows_mutex.unlock();

    if (web_view) |view| {
        view.evaluateJavascript(task.script, -1, null, null, null, null, null);
    }
    engines.eval(task.script);
    return 0; // one-shot
}

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime bridge_patterns: anytype,
) type {
    const native_commands = @import("../../core/native_commands.zig");
    return struct {
        const Dispatch = dispatch.Dispatcher(api, config, local, Transport);
        const Transport = struct {
            pub const warn = log.warn;
            reply: *webkit.ScriptMessageReply,
            context: *jsc.Context,
            pub fn retain(self: *@This()) !void {
                _ = self.reply.ref();
                _ = self.context.ref();
            }
            pub fn release(self: @This()) void {
                // WebKit objects are main-thread only. A worker-side queue
                // rejection (out of memory) leaves them for process teardown,
                // like the Windows and Apple transports.
                if (glib.MainContext.default().isOwner() == 0) {
                    log.warn("IPC reply dropped off the main thread: its WebKit reference is kept", .{});
                    return;
                }
                self.reply.unref();
                self.context.unref();
            }
            pub fn alive(_: @This()) bool {
                return true;
            } // WebKit owns the originating document's reply.
            pub fn settle(self: @This(), result: ?[:0]const u8, err: ?[:0]const u8) void {
                if (err) |e| return self.reply.returnErrorMessage(e);
                const v = jsc.Value.newFromJson(self.context, result orelse "null");
                defer v.unref();
                self.reply.returnValue(v);
            }
            pub fn discard(self: @This()) void {
                if (glib.MainContext.default().isOwner() != 0) self.settle(null, "AppNotRunning");
            }
            pub const post = ShellMod.dispatchWithCleanup;
        };

        pub fn setupUserContent(view: *webkit.WebView, label: [:0]const u8) void {
            const gpa = std.heap.smp_allocator;
            const content = view.getUserContentManager();

            const label_json = std.json.Stringify.valueAlloc(gpa, label, .{}) catch return;
            defer gpa.free(label_json);
            // The page's IPC token lives only in the bridge's closure (ipc.tokenScript).
            const token_js = ipc.tokenScript(gpa, config.security, local) catch return;
            defer gpa.free(token_js);
            const with_iso = std.mem.replaceOwned(u8, gpa, bridge_js, isolation_placeholder, comptime isolation.bridgeScript(config.app.isolation, local)) catch return;
            defer gpa.free(with_iso);
            const with_token = std.mem.replaceOwned(u8, gpa, with_iso, token_placeholder, token_js) catch return;
            defer gpa.free(with_token);
            const label_script_src = std.fmt.allocPrintSentinel(gpa, "{s}window.__oriel_window_label = {s};\n{s}", .{ comptime security.bridgePrelude(config.security), label_json, with_token }, 0) catch return;
            defer gpa.free(label_script_src);
            const script = webkit.UserScript.new(label_script_src, .top_frame, .start, @ptrCast(&bridge_patterns), null);
            content.addScript(script);
            script.unref();

            _ = content.registerScriptMessageHandlerWithReply(handler_name, null);
            _ = webkit.UserContentManager.signals.script_message_with_reply_received.connect(
                content,
                *webkit.WebView,
                &onMessage,
                view,
                .{ .detail = handler_name },
            );
        }

        /// The native renderer's `invoke` (-Dnative_ui): the same dispatch as
        /// `onMessage`, for the app's own page. No IPC token or isolation: the
        /// page is the app's embedded code running in its own engine, not web
        /// content. `ctx` is the window (*App.Window). Answers arrive on the
        /// main loop, never inside the call that asked.
        pub fn nativeInvoke(ctx: ?*anyopaque, engine: *native.Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
            const win: *App.Window = @ptrCast(@alignCast(ctx.?));
            const gpa = std.heap.smp_allocator;
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const arena = arena_state.allocator();
            const page_url = security.resolveWindowUrl(arena, config.security, local, null, win.options.url, config.start) catch "app://localhost/index.html";
            const args = std.json.parseFromSliceLeaky(std.json.Value, arena, args_json, .{}) catch .null;
            const request: ipc.Request = .{ .cmd = cmd, .args = args };
            const pool = internal.getWorkerPool();
            defer if (pool != null) internal.releaseWorkerPool();

            const result: anyerror![]const u8 = blk: {
                if (native_commands.dispatch(api, config, local, engine, arena, page_url, win.label, request, args_json, if (pool) |p| p.io else null)) |answer| break :blk answer;
                // Async: on the worker pool, answered from the main loop.
                const worker_pool = pool orelse break :blk error.WorkerPoolNotRunning;
                const req_json = std.fmt.allocPrint(arena, "{{\"cmd\":{f},\"args\":{s}}}", .{ std.json.fmt(cmd, .{}), if (args_json.len > 0) args_json else "null" }) catch break :blk error.OutOfMemory;
                const job = gpa.create(NativeReply) catch break :blk error.OutOfMemory;
                job.* = .{ .engine = engine, .serial = engine.serial, .call_id = call_id };
                ipc.dispatchAsync(api.commands, worker_pool, gpa, req_json, worker_pool.io, job, NativeReply.onWorkerDone) catch |err| {
                    gpa.destroy(job);
                    break :blk err;
                };
                return;
            };
            if (result) |json| NativeReply.post(engine, call_id, true, json) else |err| NativeReply.post(engine, call_id, false, ipc.errorText(err));
        }

        const NativeReply = struct {
            /// Not owned: the window may close (and free its engine) while a
            /// worker runs the command, so it's checked by nativeEngineAlive before use.
            engine: *native.Engine,
            serial: u64,
            call_id: u32,
            ok: bool = true,
            text: []u8 = &.{},

            fn post(engine: *native.Engine, call_id: u32, ok: bool, text: []const u8) void {
                postFor(engine, engine.serial, call_id, ok, text);
            }

            fn postFor(engine: *native.Engine, serial: u64, call_id: u32, ok: bool, text: []const u8) void {
                const gpa = std.heap.smp_allocator;
                const r = gpa.create(NativeReply) catch return;
                r.* = .{ .engine = engine, .serial = serial, .call_id = call_id, .ok = ok, .text = gpa.dupe(u8, text) catch {
                    gpa.destroy(r);
                    return;
                } };
                _ = glib.idleAdd(&idle, r);
            }

            fn onWorkerDone(self: *NativeReply, arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                var a = arena_state;
                defer a.deinit();
                // A worker thread: only the pointer and serial are copied; the
                // engine is checked on the main thread (idle) before use.
                const engine = self.engine;
                const serial = self.serial;
                const call_id = self.call_id;
                std.heap.smp_allocator.destroy(self);
                if (err_name) |e| postFor(engine, serial, call_id, false, e) else postFor(engine, serial, call_id, true, res orelse "null");
            }

            fn idle(data: ?*anyopaque) callconv(.c) c_int {
                const self: *NativeReply = @ptrCast(@alignCast(data));
                defer {
                    std.heap.smp_allocator.free(self.text);
                    std.heap.smp_allocator.destroy(self);
                }
                // The window closed while the command ran: nobody to answer.
                if (!nativeEngineAlive(self.engine, self.serial)) return 0;
                self.engine.resolve(self.call_id, self.ok, self.text);
                return 0;
            }
        };

        fn onMessage(
            _: *webkit.UserContentManager,
            value: *jsc.Value,
            reply: *webkit.ScriptMessageReply,
            view: *webkit.WebView,
        ) callconv(.c) c_int {
            const request_ptr = value.toString();
            defer glib.free(request_ptr);
            const req_slice = std.mem.span(request_ptr);
            // Refused before parsing (ipc.parseRequest would, too).
            if (req_slice.len > ipc.max_request_len) {
                reply.returnErrorMessage("RequestTooLarge");
                return 1;
            }

            var parse_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer parse_arena.deinit();
            const temp_alloc = parse_arena.allocator();

            const message_request = ipc.parseRequest(temp_alloc, req_slice) catch |err| {
                reply.returnErrorMessage(ipc.errorText(err));
                return 1;
            };

            // The page currently shown decides the IPC scope.
            const page_url: []const u8 = if (webkit_web_view_get_uri(view)) |u| std.mem.span(u) else "";
            const caller_win = @import("window.zig").getWindowByView(view);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;
            const transport: Transport = .{ .reply = reply, .context = value.getContext() };
            Dispatch.run(transport, std.heap.smp_allocator, temp_alloc, message_request, req_slice, page_url, win_label, @intFromPtr(view)) catch |err| {
                transport.settle(null, ipc.errorText(err));
            };
            return 1;
        }
    };
}

test {
    std.testing.refAllDecls(dispatch);
}

fn nativeEngine(handle: @import("window.zig").WindowHandle) ?*native.Engine {
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    for (internal.windows_list.items) |win| {
        if (win.handle.eql(handle)) return @ptrCast(@alignCast(win.handle.native orelse return null));
    }
    return null;
}

test "web bridge transport typechecks shared dispatch" {
    if (comptime build_opts.native_ui) return;
    const Commands = struct {
        pub fn ping(_: std.mem.Allocator) u32 {
            return 1;
        }
    };
    const B = Bridge(.{ .commands = Commands }, .{ .app = .{ .id = "test" } }, .{}, .{});
    _ = &B.onMessage;
}
