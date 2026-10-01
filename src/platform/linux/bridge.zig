//! WebKit JS <-> Zig IPC bridge and script message handling.
//!
//! Injects `window.oriel` JS API into permitted origins and routes commands
//! through `ipc.dispatchRequest` and `ipc.dispatchAsync`. Handles synchronous
//! and asynchronous replies via WebKit's ScriptMessageReply mechanism.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const webkit = @import("webkit");
const jsc = @import("jsc");
const App = @import("../../core/App.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");
const build_target = @import("../../core/target.zig");
const isolation = @import("../../core/isolation.zig");

const log = std.log.scoped(.oriel);
const build_opts = @import("build_options");
/// -Dnative_ui: pages drawn with native views (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/engine.zig") else struct {};

pub const handler_name = "oriel";

/// Replaced by `ipc.tokenScript` (which defines `const ipcToken`) in each
/// window's copy of `bridge_js`.
const token_placeholder = "/*__ORIEL_IPC_TOKEN__*/";
/// Replaced by `isolation.bridgeScript` (which defines `invoke`).
const isolation_placeholder = "/*__ORIEL_ISOLATION__*/";

comptime {
    @setEvalBranchQuota(100_000); // the scan covers the whole script
    std.debug.assert(std.mem.count(u8, bridge_js, token_placeholder) == 1);
    std.debug.assert(std.mem.count(u8, bridge_js, isolation_placeholder) == 1);
}

/// Injected into allowed pages before their own scripts run.
pub const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const pendingEvents = new Map();
    \\  const handler = window.webkit.messageHandlers.
++ handler_name ++
    \\;
    \\
++ token_placeholder ++
    \\
    \\  function rawInvoke(cmd, args) {
    \\    return handler.postMessage(JSON.stringify({ cmd, args: args ?? null, token: ipcToken }));
    \\  }
    \\  function sendSealed(iso) {
    \\    return handler.postMessage(JSON.stringify({ cmd: "oriel:isolated", iso, token: ipcToken }));
    \\  }
    \\
++ isolation_placeholder ++
    \\
    \\  class WindowHandle {
    \\    constructor(label) {
    \\      this.label = label;
    \\    }
    \\    close() {
    \\      return invoke("oriel:window:close", { label: this.label });
    \\    }
    \\    show() {
    \\      return invoke("oriel:window:show", { label: this.label });
    \\    }
    \\    hide() {
    \\      return invoke("oriel:window:hide", { label: this.label });
    \\    }
    \\    focus() {
    \\      return invoke("oriel:window:focus", { label: this.label });
    \\    }
    \\    setTitle(title) {
    \\      return invoke("oriel:window:setTitle", { label: this.label, title });
    \\    }
    \\    setSize(width, height) {
    \\      return invoke("oriel:window:setSize", { label: this.label, width, height });
    \\    }
    \\    maximize(maximized = true) {
    \\      return invoke("oriel:window:maximize", { label: this.label, maximized });
    \\    }
    \\    fullscreen(fullscreen = true) {
    \\      return invoke("oriel:window:fullscreen", { label: this.label, fullscreen });
    \\    }
    \\    startDragging() {
    \\      return invoke("oriel:window:startDragging", { label: this.label });
    \\    }
    \\    emit(event, payload) {
    \\      return windowApi.emitTo(this.label, event, payload);
    \\    }
    \\  }
    \\  const windowApi = {
    \\    async open(options) {
    \\      const res = await invoke("oriel:window:open", options);
    \\      return new WindowHandle(res.label);
    \\    },
    \\    current() {
    \\      return new WindowHandle(window.__oriel_window_label || "main");
    \\    },
    \\    async get(label) {
    \\      const res = await invoke("oriel:window:get", { label });
    \\      return res ? new WindowHandle(res.label) : null;
    \\    },
    \\    async all() {
    \\      const list = await invoke("oriel:window:all", {});
    \\      return (list || []).map(w => new WindowHandle(w.label));
    \\    },
    \\    emitTo(label, event, payload) {
    \\      return invoke("oriel:window:emitTo", { label, event, payload: payload ?? null });
    \\    }
    \\  };
    \\  Object.defineProperty(window, "oriel", { value: Object.freeze({
    \\    platform:
++ " " ++ build_target.platform_js ++ ",\n" ++
    \\    invoke,
    \\    listen(event, callback) {
    \\      let set = listeners.get(event);
    \\      if (!set) listeners.set(event, (set = new Set()));
    \\      set.add(callback);
    \\      const queued = pendingEvents.get(event);
    \\      if (queued && queued.length > 0) {
    \\        pendingEvents.delete(event);
    \\        for (const payload of queued) {
    \\          try { callback(payload); } catch (e) { console.error(e); }
    \\        }
    \\      }
    \\      if (event === "deep-link") {
    \\        try { Promise.resolve(invoke("deep_link:ready", {})).catch(() => {}); } catch (_) {}
    \\      }
    \\      return () => set.delete(callback);
    \\    },
    \\    openExternal(url) {
    \\      return invoke("open_external", { url });
    \\    },
    \\    permissions: Object.freeze({
    \\      query(name) {
    \\        return invoke("permissions:query", { name });
    \\      },
    \\      request(name) {
    \\        return new Promise((resolve, reject) => {
    \\          let set = listeners.get("permission-changed");
    \\          if (!set) listeners.set("permission-changed", (set = new Set()));
    \\          const cb = (e) => { if (e && e.name === name) { set.delete(cb); resolve(e.status); } };
    \\          set.add(cb);
    \\          Promise.resolve(invoke("permissions:request", { name })).then((s) => {
    \\            if (s !== "prompt") { set.delete(cb); resolve(s); }
    \\          }, (err) => { set.delete(cb); reject(err); });
    \\        });
    \\      },
    \\      openSettings(name) {
    \\        return invoke("permissions:open_settings", { name });
    \\      },
    \\    }),
    \\    deepLink: Object.freeze({
    \\      current() {
    \\        return invoke("deep_link:current", {});
    \\      },
    \\    }),
    \\    __emit(event, payload) {
    \\      const set = listeners.get(event);
    \\      if (set && set.size > 0) {
    \\        for (const cb of set) {
    \\          try { cb(payload); } catch (e) { console.error(e); }
    \\        }
    \\      } else if (event === "deep-link") {
    \\        // Only deep links wait for a listener (e.g. across a reload); the
    \\        // native side queues them until the first listen(). Capped.
    \\        let queued = pendingEvents.get(event);
    \\        if (!queued) pendingEvents.set(event, (queued = []));
    \\        queued.push(payload);
    \\        if (queued.length > 16) queued.shift();
    \\      }
    \\    },
    \\    window: Object.freeze(windowApi),
    \\  }) });
    \\  // <div data-oriel-drag-region> moves the window when pressed (its buttons,
    \\  // fields and links, and anything under data-oriel-no-drag, keep their clicks).
    \\  window.addEventListener("mousedown", (e) => {
    \\    if (e.button !== 0 || !(e.target instanceof Element)) return;
    \\    if (!e.target.closest("[data-oriel-drag-region]")) return;
    \\    if (e.target.closest("button, input, textarea, select, a, [contenteditable], [data-oriel-no-drag]")) return;
    \\    e.preventDefault();
    \\    Promise.resolve(windowApi.current().startDragging()).catch(() => {});
    \\  }, true);
    \\})();
;

// The generated binding marks the result non-null, but it is NULL before
// the first load.
extern fn webkit_web_view_get_uri(view: *webkit.WebView) ?[*:0]const u8;

pub fn evalJs(target: ?@import("window.zig").WindowHandle, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const script_copy = gpa.dupeZ(u8, script) catch return;

    const Task = struct {
        target: ?@import("window.zig").WindowHandle,
        script: [:0]u8,
    };
    const task = gpa.create(Task) catch {
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .target = target, .script = script_copy };
    // On the main thread (a sync command emitting), run it now: queued for
    // later, it would reach the page after the command's reply. Other
    // threads queue it (FIFO with their command's reply).
    if (glib.MainContext.default().isOwner() != 0) {
        _ = evalScriptTask(task);
    } else {
        _ = glib.idleAdd(&evalScriptTask, task);
    }
}

fn evalScriptTask(data: ?*anyopaque) callconv(.c) c_int {
    const task: *struct { target: ?@import("window.zig").WindowHandle, script: [:0]u8 } = @ptrCast(@alignCast(data));
    defer {
        std.heap.smp_allocator.free(task.script);
        std.heap.smp_allocator.destroy(task);
    }
    if (task.target) |v| {
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        const web_view: ?*webkit.WebView = for (App.windows_list.items) |win| {
            if (win.handle.eql(v)) break win.handle.web_view;
        } else null;
        App.windows_mutex.unlock();
        if (web_view) |view| {
            view.evaluateJavascript(task.script, -1, null, null, null, null, null);
        } else if (comptime build_opts.native_ui) {
            if (nativeEngine(v)) |e| e.evalScript(task.script);
        }
    } else {
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        var engines: [16]*anyopaque = undefined;
        var n_engines: usize = 0;
        for (App.windows_list.items) |win| {
            if (win.handle.web_view) |view| view.evaluateJavascript(task.script, -1, null, null, null, null, null);
            if (comptime build_opts.native_ui) if (win.handle.native) |e| if (n_engines < engines.len) {
                engines[n_engines] = e;
                n_engines += 1;
            };
        }
        App.windows_mutex.unlock();
        // Outside the lock: the page may open or close windows.
        if (comptime build_opts.native_ui) for (engines[0..n_engines]) |e| @as(*native.Engine, @ptrCast(@alignCast(e))).evalScript(task.script);
    }
    return 0; // one-shot
}

pub fn evalJsByLabel(label: [:0]const u8, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const label_copy = gpa.dupeZ(u8, label) catch return;
    const script_copy = gpa.dupeZ(u8, script) catch {
        gpa.free(label_copy);
        return;
    };

    const Task = struct {
        label: [:0]u8,
        script: [:0]u8,
    };
    const task = gpa.create(Task) catch {
        gpa.free(label_copy);
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .label = label_copy, .script = script_copy };
    // See evalJs: in order with a sync command's reply.
    if (glib.MainContext.default().isOwner() != 0) {
        _ = evalScriptByLabelTask(task);
    } else {
        _ = glib.idleAdd(&evalScriptByLabelTask, task);
    }
}

fn evalScriptByLabelTask(data: ?*anyopaque) callconv(.c) c_int {
    const task: *struct { label: [:0]u8, script: [:0]u8 } = @ptrCast(@alignCast(data));
    defer {
        std.heap.smp_allocator.free(task.label);
        std.heap.smp_allocator.free(task.script);
        std.heap.smp_allocator.destroy(task);
    }
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    const web_view = for (App.windows_list.items) |win| {
        if (std.mem.eql(u8, win.label, task.label)) break win.handle.web_view;
    } else null;
    App.windows_mutex.unlock();

    if (web_view) |view| {
        view.evaluateJavascript(task.script, -1, null, null, null, null, null);
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
    return struct {
        pub fn setupUserContent(view: *webkit.WebView, label: [:0]const u8) void {
            const gpa = std.heap.smp_allocator;
            const content = view.getUserContentManager();

            const label_json = std.json.Stringify.valueAlloc(gpa, label, .{}) catch return;
            defer gpa.free(label_json);
            // The page's IPC token lives only in the bridge's closure (ipc.tokenScript).
            const token_js = ipc.tokenScript(gpa, config.security, local) catch return;
            defer gpa.free(token_js);
            const with_iso = std.mem.replaceOwned(u8, gpa, bridge_js, isolation_placeholder, comptime isolation.bridgeScript(config.security, local)) catch return;
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
            const pool = App.getWorkerPool();

            const result: anyerror![]const u8 = blk: {
                if (window_commands.isWindowCommand(cmd))
                    break :blk window_commands.dispatch(config.security, local, arena, page_url, win.label, cmd, args);
                if (!security.commandAllowedForWindow(config.security, local, page_url, cmd, win.label)) {
                    log.warn("native page: blocked command \"{f}\" (window: {s})", .{ std.zig.fmtString(cmd[0..@min(cmd.len, 64)]), win.label });
                    break :blk error.Forbidden;
                }
                if (ipc.isBuiltinCommand(cmd)) break :blk ipc.dispatchBuiltin(config.security, arena, request);
                if (!ipc.isAsync(api.commands, cmd)) break :blk ipc.dispatchRequest(api.commands, arena, request, if (pool) |p| p.io else null);
                // Async: on the worker pool, answered from the main loop.
                const worker_pool = pool orelse break :blk error.WorkerPoolNotRunning;
                const req_json = std.fmt.allocPrint(arena, "{{\"cmd\":{f},\"args\":{s}}}", .{ std.json.fmt(cmd, .{}), if (args_json.len > 0) args_json else "null" }) catch break :blk error.OutOfMemory;
                const job = gpa.create(NativeReply) catch break :blk error.OutOfMemory;
                job.* = .{ .engine = engine, .call_id = call_id };
                ipc.dispatchAsync(api.commands, worker_pool, gpa, req_json, worker_pool.io, job, NativeReply.onWorkerDone) catch |err| {
                    gpa.destroy(job);
                    break :blk err;
                };
                return;
            };
            if (result) |json| NativeReply.post(engine, call_id, true, json) else |err| NativeReply.post(engine, call_id, false, ipc.errorText(err));
        }

        const NativeReply = struct {
            engine: *native.Engine,
            call_id: u32,
            ok: bool = true,
            text: []u8 = &.{},

            fn post(engine: *native.Engine, call_id: u32, ok: bool, text: []const u8) void {
                const gpa = std.heap.smp_allocator;
                const r = gpa.create(NativeReply) catch return;
                r.* = .{ .engine = engine, .call_id = call_id, .ok = ok, .text = gpa.dupe(u8, text) catch {
                    gpa.destroy(r);
                    return;
                } };
                _ = glib.idleAdd(&idle, r);
            }

            fn onWorkerDone(self: *NativeReply, arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                var a = arena_state;
                defer a.deinit();
                const engine = self.engine;
                const call_id = self.call_id;
                std.heap.smp_allocator.destroy(self);
                if (err_name) |e| post(engine, call_id, false, e) else post(engine, call_id, true, res orelse "null");
            }

            fn idle(data: ?*anyopaque) callconv(.c) c_int {
                const self: *NativeReply = @ptrCast(@alignCast(data));
                defer {
                    std.heap.smp_allocator.free(self.text);
                    std.heap.smp_allocator.destroy(self);
                }
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
            const checked = isolation.check(temp_alloc, config.security, local, page_url, @intFromPtr(view), message_request, req_slice) catch |err| {
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

            const pool = App.getWorkerPool();

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
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |win| {
        if (win.handle.eql(handle)) return @ptrCast(@alignCast(win.handle.native orelse return null));
    }
    return null;
}
