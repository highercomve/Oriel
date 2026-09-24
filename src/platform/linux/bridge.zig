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

const log = std.log.scoped(.oriel);

pub const handler_name = "oriel";

/// Injected into allowed pages before their own scripts run.
pub const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const handler = window.webkit.messageHandlers.
++ handler_name ++
    \\;
    \\  Object.defineProperty(window, "oriel", { value: Object.freeze({
    \\    invoke(cmd, args) {
    \\      return handler.postMessage(JSON.stringify({ cmd, args: args ?? null }));
    \\    },
    \\    listen(event, callback) {
    \\      let set = listeners.get(event);
    \\      if (!set) listeners.set(event, (set = new Set()));
    \\      set.add(callback);
    \\      return () => set.delete(callback);
    \\    },
    \\    __emit(event, payload) {
    \\      for (const cb of listeners.get(event) ?? []) {
    \\        try { cb(payload); } catch (e) { console.error(e); }
    \\      }
    \\    },
    \\  }) });
    \\})();
;

// The generated binding marks the result non-null, but it is NULL before
// the first load.
extern fn webkit_web_view_get_uri(view: *webkit.WebView) ?[*:0]const u8;

pub fn evalJs(target: ?@import("window.zig").WindowHandle, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const script_copy = gpa.dupeZ(u8, script) catch return;
    if (target) |tv| {
        _ = gobject.Object.ref(tv.web_view.as(gobject.Object));
    }

    const Task = struct {
        target: ?@import("window.zig").WindowHandle,
        script: [:0]u8,
    };
    const task = gpa.create(Task) catch {
        if (target) |tv| tv.web_view.as(gobject.Object).unref();
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
        defer v.web_view.as(gobject.Object).unref();
        if (App.getWindowByHandle(v) != null) {
            v.web_view.evaluateJavascript(task.script, -1, null, null, null, null, null);
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

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
    comptime bridge_patterns: anytype,
) type {
    return struct {
        pub fn setupUserContent(view: *webkit.WebView) void {
            const content = view.getUserContentManager();
            const script = webkit.UserScript.new(bridge_js, .top_frame, .start, @ptrCast(&bridge_patterns), null);
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

            const request = ipc.parseRequest(temp_alloc, req_slice) catch |err| {
                reply.returnErrorMessage(@errorName(err));
                return 1;
            };

            // The page currently shown decides the IPC scope.
            const page_url: []const u8 = if (webkit_web_view_get_uri(view)) |u| std.mem.span(u) else "";
            const caller_win = @import("window.zig").getWindowByView(view);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;
            if (!security.commandAllowedForWindow(config.security, local, page_url, request.cmd, win_label)) {
                log.warn("blocked command '{s}' from {s} (window: {?s})", .{ request.cmd, page_url, win_label });
                reply.returnErrorMessage("Forbidden");
                return 1;
            }

            const pool = App.getWorkerPool();

            if (!ipc.isAsync(api.commands, request.cmd)) {
                const result = ipc.dispatchRequest(api.commands, temp_alloc, request, if (pool) |p| p.io else null) catch |err| {
                    reply.returnErrorMessage(@errorName(err));
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

            ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, req_slice, worker_pool.io, gtk_reply, GtkReply.onWorkerDone) catch |err| {
                reply.unref();
                context.unref();
                std.heap.smp_allocator.destroy(gtk_reply);
                reply.returnErrorMessage(@errorName(err));
                return 1;
            };

            return 1;
        }
    };
}
