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
const internal = @import("../../core/internal.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");

const log = std.log.scoped(.oriel);
/// -Dnative_ui: pages drawn with native views (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/engine.zig") else struct {};

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
        internal.ensureWindowsMutex();
        internal.windows_mutex.lock();
        var engines: [16]*anyopaque = undefined;
        var n_engines: usize = 0;
        for (internal.windows_list.items) |win| {
            // Only to pages the bridge serves (any other could read it).
            if (win.handle.web_view) |view| if (viewGetsEvents(view, win.label)) {
                view.evaluateJavascript(task.script, -1, null, null, null, null, null);
            };
            if (comptime build_opts.native_ui) if (win.handle.native) |e| if (n_engines < engines.len) {
                engines[n_engines] = e;
                n_engines += 1;
            };
        }
        internal.windows_mutex.unlock();
        // Outside the lock: the page may open or close windows.
        // Each still open: a page's script may close another window.
        if (comptime build_opts.native_ui) for (engines[0..n_engines]) |e| {
            if (engineListed(e)) @as(*native.Engine, @ptrCast(@alignCast(e))).evalScript(task.script);
        };
    }
    return 0; // one-shot
}

/// Whether an open window has this native engine.
fn engineListed(e: *anyopaque) bool {
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    for (internal.windows_list.items) |win| if (win.handle.native == e) return true;
    return false;
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
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    var web_view: ?*webkit.WebView = null;
    // A native window (-Dnative_ui) has an engine instead of a web view:
    // targeted events (internal.emitTo) must reach it too.
    var engine: ?*anyopaque = null;
    for (internal.windows_list.items) |win| {
        if (!std.mem.eql(u8, win.label, task.label)) continue;
        if (win.handle.web_view) |view| if (viewGetsEvents(view, win.label)) {
            web_view = view;
        };
        if (comptime build_opts.native_ui) engine = win.handle.native;
        break;
    }
    internal.windows_mutex.unlock();

    if (web_view) |view| {
        view.evaluateJavascript(task.script, -1, null, null, null, null, null);
    } else if (comptime build_opts.native_ui) {
        // Outside the lock: the page may open or close windows.
        if (engine) |e| @as(*native.Engine, @ptrCast(@alignCast(e))).evalScript(task.script);
    }
    return 0; // one-shot
}

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime bridge_patterns: anytype,
) type {
    const window_commands = @import("../../core/window_commands.zig");
    const native_commands = @import("../../core/native_commands.zig");
    return struct {
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
            /// worker runs the command, so it's checked by engineAlive before use.
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
                if (!engineAlive(self.engine, self.serial)) return 0;
                self.engine.resolve(self.call_id, self.ok, self.text);
                return 0;
            }

            /// Whether an open window still has this engine (the same one: its
            /// serial, read only once the pointer is found among live windows).
            /// Main thread, where windows close and engines are freed.
            fn engineAlive(engine: *native.Engine, serial: u64) bool {
                internal.ensureWindowsMutex();
                internal.windows_mutex.lock();
                defer internal.windows_mutex.unlock();
                for (internal.windows_list.items) |win| {
                    const e = win.handle.native orelse continue;
                    if (e == @as(*anyopaque, @ptrCast(engine))) return engine.serial == serial;
                }
                return false;
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
            // The handler is reachable from every frame, but only the top
            // frame's bridge has this page's token (ipc.tokenScript), so a
            // frame from another origin can't act as the page.
            if (!ipc.tokenValid(message_request.token, config.security, local, page_url)) {
                log.warn("refused an IPC call without this page's token (\"{f}\")", .{std.zig.fmtString(message_request.cmd[0..@min(message_request.cmd.len, 64)])});
                reply.returnErrorMessage("Forbidden");
                return 1;
            }
            // With isolation on, the app's pages send only calls the
            // isolation hook signed; `request` is the call inside.
            const checked = isolation.check(temp_alloc, config.app.isolation, local, page_url, @intFromPtr(view), message_request, req_slice) catch |err| {
                reply.returnErrorMessage(isolation.errorText(err));
                return 1;
            };
            const request = checked.request;
            // Page-controlled: escaped and capped in logs.
            const cmd_log = std.zig.fmtString(request.cmd[0..@min(request.cmd.len, 64)]);

            if (window_commands.isWindowCommand(request.cmd)) {
                const result = window_commands.dispatch(config.security, local, temp_alloc, page_url, win_label, request.cmd, request.args) catch |err| {
                    reply.returnErrorMessage(ipc.errorText(err));
                    return 1;
                };
                const result_z = temp_alloc.dupeZ(u8, result) catch {
                    reply.returnErrorMessage("OutOfMemory");
                    return 1;
                };
                const js_value = jsc.Value.newFromJson(value.getContext(), result_z);
                defer js_value.unref();
                reply.returnValue(js_value);
                return 1;
            }

            if (!security.commandAllowedForWindow(config.security, local, page_url, request.cmd, win_label)) {
                log.warn("blocked command \"{f}\" from {s} (window: {?s})", .{ cmd_log, page_url, win_label });
                reply.returnErrorMessage("Forbidden");
                return 1;
            }

            const pool = internal.getWorkerPool();
            defer if (pool != null) internal.releaseWorkerPool();

            if (ipc.isBuiltinCommand(request.cmd)) {
                const result = ipc.dispatchBuiltin(config.security, temp_alloc, request) catch |err| {
                    reply.returnErrorMessage(ipc.errorText(err));
                    return 1;
                };
                const result_z = temp_alloc.dupeZ(u8, result) catch {
                    reply.returnErrorMessage("OutOfMemory");
                    return 1;
                };
                const js_value = jsc.Value.newFromJson(value.getContext(), result_z);
                defer js_value.unref();
                reply.returnValue(js_value);
                return 1;
            }

            if (!ipc.isAsync(api.commands, request.cmd)) {
                const result = ipc.dispatchRequest(api.commands, temp_alloc, request, if (pool) |p| p.io else null) catch |err| {
                    reply.returnErrorMessage(ipc.errorText(err));
                    return 1;
                };
                const result_z = temp_alloc.dupeZ(u8, result) catch {
                    reply.returnErrorMessage("OutOfMemory");
                    return 1;
                };
                const js_value = jsc.Value.newFromJson(value.getContext(), result_z);
                defer js_value.unref();
                reply.returnValue(js_value);
                return 1;
            }

            // Async command: execute on worker pool and reply on GTK main thread.
            const worker_pool = pool orelse {
                reply.returnErrorMessage("WorkerPoolNotRunning");
                return 1;
            };

            _ = reply.ref();
            const context = value.getContext();
            _ = context.ref();

            const GtkReply = struct {
                reply: *webkit.ScriptMessageReply,
                context: *jsc.Context,
                arena_state: std.heap.ArenaAllocator,
                result: ?[:0]const u8,
                err_name: ?[:0]const u8,

                fn onWorkerDone(self: *@This(), arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                    self.arena_state = arena_state;
                    self.result = res;
                    self.err_name = err_name;
                    _ = glib.idleAdd(&idleReply, self);
                }

                fn idleReply(data: ?*anyopaque) callconv(.c) c_int {
                    const self: *@This() = @ptrCast(@alignCast(data));
                    defer {
                        self.reply.unref();
                        self.context.unref();
                        var a = self.arena_state;
                        a.deinit();
                        std.heap.smp_allocator.destroy(self);
                    }
                    if (self.err_name) |err| {
                        self.reply.returnErrorMessage(err);
                    } else if (self.result) |res_z| {
                        const js_value = jsc.Value.newFromJson(self.context, res_z);
                        defer js_value.unref();
                        self.reply.returnValue(js_value);
                    }
                    return 0; // one-shot idle callback
                }
            };

            const gtk_reply = std.heap.smp_allocator.create(GtkReply) catch {
                reply.unref();
                context.unref();
                reply.returnErrorMessage("OutOfMemory");
                return 1;
            };
            gtk_reply.* = .{
                .reply = reply,
                .context = context,
                .arena_state = undefined,
                .result = null,
                .err_name = null,
            };

            ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, checked.json, worker_pool.io, gtk_reply, GtkReply.onWorkerDone) catch |err| {
                reply.unref();
                context.unref();
                std.heap.smp_allocator.destroy(gtk_reply);
                reply.returnErrorMessage(ipc.errorText(err));
                return 1;
            };

            return 1;
        }
    };
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
