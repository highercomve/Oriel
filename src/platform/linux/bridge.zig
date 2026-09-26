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
const isolation = @import("../../core/isolation.zig");

const log = std.log.scoped(.oriel);

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
    _ = glib.idleAdd(&evalScriptTask, task);
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
        const web_view = for (App.windows_list.items) |win| {
            if (win.handle.eql(v)) break win.handle.web_view;
        } else null;
        App.windows_mutex.unlock();
        if (web_view) |view| {
            view.evaluateJavascript(task.script, -1, null, null, null, null, null);
        }
    } else {
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        defer App.windows_mutex.unlock();
        for (App.windows_list.items) |win| {
            win.handle.web_view.evaluateJavascript(task.script, -1, null, null, null, null, null);
        }
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
    _ = glib.idleAdd(&evalScriptByLabelTask, task);
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
