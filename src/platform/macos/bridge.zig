//! WKWebView JS <-> Zig IPC bridge.
//!
//! Injects the `window.oriel` API (the same script as the Linux bridge:
//! `postMessage` on a handler with reply returns a Promise) and routes
//! commands through `ipc.dispatchRequest` / `ipc.dispatchAsync` via a
//! `WKScriptMessageHandlerWithReply` (macOS 11+).
//!
//! Every request is answered exactly once through WebKit's reply block,
//! which we copy (`_Block_copy`) while a command is pending. Sync commands
//! run from the main loop rather than inside the WebKit callback, so a
//! command may open or close windows (including its own) safely.

const std = @import("std");
const cocoa = @import("cocoa.zig");
const objc = cocoa.objc;
const Object = cocoa.Object;
const window_mod = @import("window.zig");
const ShellMod = @import("Shell.zig");
const App = @import("../../core/App.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");

const log = std.log.scoped(.oriel);

pub const handler_name = "oriel";

/// Replaced by `ipc.token()` in each window's copy of `bridge_js`.
const token_placeholder = "__ORIEL_IPC_TOKEN__";

/// Injected into every top-level document before its own scripts run;
/// `commandAllowedForWindow` checks the page's origin on every call.
pub const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const pendingEvents = new Map();
    \\  const handler = window.webkit.messageHandlers.
++ handler_name ++
    \\;
    \\  const ipcToken = "__ORIEL_IPC_TOKEN__";
    \\  function invoke(cmd, args) {
    \\    return handler.postMessage(JSON.stringify({ cmd, args: args ?? null, token: ipcToken }));
    \\  }
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
    \\      return handler.postMessage(JSON.stringify({ cmd: "open_external", args: { url }, token: ipcToken }));
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

fn evaluate(view: cocoa.id, script: []const u8) void {
    const str = cocoa.nsString(script) orelse return;
    defer str.release();
    (Object{ .value = view }).msgSend(void, "evaluateJavaScript:completionHandler:", .{ str, cocoa.nil });
}

pub fn evalJs(target: ?window_mod.WindowHandle, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const script_copy = gpa.dupeZ(u8, script) catch return;

    const Task = struct {
        target: ?window_mod.WindowHandle,
        script: [:0]u8,

        fn discard(self: *@This()) void {
            std.heap.smp_allocator.free(self.script);
            std.heap.smp_allocator.destroy(self);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            discard(@ptrCast(@alignCast(ctx)));
        }

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer discard(self);
            App.ensureWindowsMutex();
            App.windows_mutex.lock();
            defer App.windows_mutex.unlock();
            // Handles match by serial: use the live window's webview,
            // not the (possibly stale) copy queued with the task.
            for (App.windows_list.items) |win| {
                if (self.target == null or win.handle.eql(self.target.?)) evaluate(win.handle.webview, self.script);
            }
        }
    };

    const task = gpa.create(Task) catch {
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .target = target, .script = script_copy };
    ShellMod.dispatchWithCleanup(&Task.run, task, &Task.cleanup);
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

        fn discard(self: *@This()) void {
            std.heap.smp_allocator.free(self.label);
            std.heap.smp_allocator.free(self.script);
            std.heap.smp_allocator.destroy(self);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            discard(@ptrCast(@alignCast(ctx)));
        }

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer discard(self);
            App.ensureWindowsMutex();
            App.windows_mutex.lock();
            defer App.windows_mutex.unlock();
            for (App.windows_list.items) |win| {
                if (std.mem.eql(u8, win.label, self.label)) evaluate(win.handle.webview, self.script);
            }
        }
    };

    const task = gpa.create(Task) catch {
        gpa.free(label_copy);
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .label = label_copy, .script = script_copy };
    ShellMod.dispatchWithCleanup(&Task.run, task, &Task.cleanup);
}

/// Answer a request: `result_json` becomes the Promise's value (through
/// NSJSONSerialization, so JS gets objects, not a string).
fn replySuccess(reply: cocoa.id, result_json: []const u8) void {
    const data = cocoa.class("NSData").msgSend(Object, "dataWithBytes:length:", .{ result_json.ptr, @as(c_ulong, result_json.len) });
    const NSJSONReadingFragmentsAllowed: c_ulong = 4; // top-level strings, numbers, null
    const value = cocoa.class("NSJSONSerialization").msgSend(Object, "JSONObjectWithData:options:error:", .{ data, NSJSONReadingFragmentsAllowed, @as(?*anyopaque, null) });
    if (value.value == null) {
        replyError(reply, "InvalidReply");
        return;
    }
    cocoa.callBlock(reply, struct { cocoa.id, cocoa.id }, .{ value.value, null });
}

/// Reject the request's Promise with `Error(err_name)`.
fn replyError(reply: cocoa.id, err_name: []const u8) void {
    const msg = cocoa.nsString(err_name) orelse cocoa.nsString("Error").?;
    defer msg.release();
    cocoa.callBlock(reply, struct { cocoa.id, cocoa.id }, .{ null, msg.value });
}

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
) type {
    const window_commands = @import("../../core/window_commands.zig");
    return struct {
        pub fn handlerClass() cocoa.Class {
            return cocoa.defineClass("OrielMessageHandler", &.{"WKScriptMessageHandlerWithReply"}, .{
                .{ "userContentController:didReceiveScriptMessage:replyHandler:", onMessage },
            });
        }

        /// Add the bridge script (with this window's label) and the message
        /// handler to a webview configuration's user content controller.
        pub fn setupUserContent(content: Object, handler: Object, label: [:0]const u8) !void {
            const gpa = std.heap.smp_allocator;
            const label_json = try std.json.Stringify.valueAlloc(gpa, label, .{});
            defer gpa.free(label_json);
            // The IPC token lives only in the bridge's closure (ipc.token).
            const with_token = try std.mem.replaceOwned(u8, gpa, bridge_js, token_placeholder, ipc.token());
            defer gpa.free(with_token);
            const source = try std.fmt.allocPrint(gpa, "window.__oriel_window_label = {s};\n{s}", .{ label_json, with_token });
            defer gpa.free(source);
            const source_ns = cocoa.nsString(source) orelse return error.OutOfMemory;
            defer source_ns.release();

            const WKUserScriptInjectionTimeAtDocumentStart: isize = 0;
            const script = cocoa.class("WKUserScript").msgSend(Object, "alloc", .{})
                .msgSend(Object, "initWithSource:injectionTime:forMainFrameOnly:", .{ source_ns, WKUserScriptInjectionTimeAtDocumentStart, cocoa.boolean(true) });
            if (script.value == null) return error.OutOfMemory;
            defer script.release();
            content.msgSend(void, "addUserScript:", .{script});

            const name = cocoa.nsString(handler_name) orelse return error.OutOfMemory;
            defer name.release();
            const world = cocoa.class("WKContentWorld").msgSend(Object, "pageWorld", .{});
            content.msgSend(void, "addScriptMessageHandlerWithReply:contentWorld:name:", .{ handler, world, name });
        }

        fn onMessage(_: cocoa.id, _: cocoa.c.SEL, _: cocoa.id, message_id: cocoa.id, reply: cocoa.id) callconv(.c) void {
            const message: Object = .{ .value = message_id };
            // Only the top frame gets the bridge; a frame reaching the
            // handler otherwise is refused.
            const frame = message.msgSend(Object, "frameInfo", .{});
            if (frame.value == null or !cocoa.isTrue(frame.msgSend(cocoa.c.BOOL, "isMainFrame", .{}))) {
                replyError(reply, "Forbidden");
                return;
            }
            const body = message.msgSend(Object, "body", .{});
            if (body.value == null or !cocoa.isTrue(body.msgSend(cocoa.c.BOOL, "isKindOfClass:", .{cocoa.class("NSString")}))) {
                replyError(reply, "InvalidRequest");
                return;
            }
            const req_slice = cocoa.utf8(body) orelse {
                replyError(reply, "InvalidRequest");
                return;
            };

            var parse_arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer parse_arena.deinit();
            const temp_alloc = parse_arena.allocator();

            const request = ipc.parseRequest(temp_alloc, req_slice) catch |err| {
                replyError(reply, @errorName(err));
                return;
            };
            // Only the bridge script knows the token (see ipc.token).
            if (!ipc.tokenValid(request.token)) {
                log.warn("refused an IPC call without the bridge's token ('{s}')", .{request.cmd});
                replyError(reply, "Forbidden");
                return;
            }

            // The page currently shown decides the IPC scope.
            const view = message.msgSend(Object, "webView", .{});
            const page_url: []const u8 = if (view.value != null) cocoa.urlString(view.msgSend(Object, "URL", .{})) orelse "" else "";
            const caller_win = window_mod.getWindowByView(view.value);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;

            if (!window_commands.isWindowCommand(request.cmd) and
                !security.commandAllowedForWindow(config.security, local, page_url, request.cmd, win_label))
            {
                log.warn("blocked command '{s}' from {s} (window: {?s})", .{ request.cmd, page_url, win_label });
                replyError(reply, "Forbidden");
                return;
            }

            const pool = App.getWorkerPool();
            if (window_commands.isWindowCommand(request.cmd) or ipc.isBuiltinCommand(request.cmd) or !ipc.isAsync(api.commands, request.cmd)) {
                SyncCall.queue(reply, request, page_url, win_label, if (pool) |p| p.io else null);
                return;
            }

            // Async command: run on the worker pool, reply on the main thread.
            const worker_pool = pool orelse {
                replyError(reply, "WorkerPoolNotRunning");
                return;
            };
            const async_ctx = std.heap.smp_allocator.create(AsyncReply) catch {
                replyError(reply, "OutOfMemory");
                return;
            };
            async_ctx.* = .{
                .reply = cocoa.copyBlock(reply),
                .arena_state = undefined,
                .result = null,
                .err_name = null,
            };
            if (async_ctx.reply == null) {
                std.heap.smp_allocator.destroy(async_ctx);
                replyError(reply, "OutOfMemory");
                return;
            }
            ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, req_slice, worker_pool.io, async_ctx, AsyncReply.onWorkerDone) catch |err| {
                cocoa.releaseBlock(async_ctx.reply);
                std.heap.smp_allocator.destroy(async_ctx);
                replyError(reply, @errorName(err));
                return;
            };
        }

        const AsyncReply = struct {
            reply: cocoa.id,
            arena_state: std.heap.ArenaAllocator,
            result: ?[:0]const u8,
            err_name: ?[:0]const u8,

            /// On the worker thread: hand the result to the main thread.
            fn onWorkerDone(self: *@This(), arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                self.arena_state = arena_state;
                self.result = res;
                self.err_name = err_name;
                ShellMod.dispatchWithCleanup(&mainReply, self, &discardReply);
            }

            fn mainReply(ctx: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                defer finish(self);
                if (self.err_name) |err| {
                    replyError(self.reply, err);
                } else if (self.result) |res| {
                    replySuccess(self.reply, res);
                } else {
                    replySuccess(self.reply, "null");
                }
            }

            /// Not queued (out of memory, or after shutdown): no reply.
            fn discardReply(ctx: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                // WebKit objects captured by the block may only be released on
                // the main thread; from a worker, leak the one reference instead.
                if (cocoa.isMainThread()) {
                    finish(self);
                } else {
                    var a = self.arena_state;
                    a.deinit();
                    std.heap.smp_allocator.destroy(self);
                }
            }

            fn finish(self: *@This()) void {
                cocoa.releaseBlock(self.reply);
                var a = self.arena_state;
                a.deinit();
                std.heap.smp_allocator.destroy(self);
            }
        };

        /// A sync command deferred to the main loop. Owns a copy of the reply
        /// block and an arena with the request.
        const SyncCall = struct {
            reply: cocoa.id,
            arena_state: std.heap.ArenaAllocator,
            request: ipc.Request,
            page_url: []const u8,
            win_label: ?[]const u8,
            io: ?std.Io,

            fn queue(reply: cocoa.id, request: ipc.Request, page_url: []const u8, win_label: ?[]const u8, io: ?std.Io) void {
                const gpa = std.heap.smp_allocator;
                const self = gpa.create(SyncCall) catch {
                    replyError(reply, "OutOfMemory");
                    return;
                };
                self.* = .{
                    .reply = reply,
                    .arena_state = .init(gpa),
                    .request = undefined,
                    .page_url = "",
                    .win_label = null,
                    .io = io,
                };
                const arena = self.arena_state.allocator();
                self.page_url = arena.dupe(u8, page_url) catch return self.fail("OutOfMemory");
                if (win_label) |wl| self.win_label = arena.dupe(u8, wl) catch return self.fail("OutOfMemory");
                // Deep-copy the request out of the caller's parse arena.
                const request_json = std.json.Stringify.valueAlloc(arena, request, .{}) catch return self.fail("OutOfMemory");
                self.request = ipc.parseRequest(arena, request_json) catch |err| return self.fail(@errorName(err));
                const copied = cocoa.copyBlock(reply);
                if (copied == null) return self.fail("OutOfMemory");
                self.reply = copied;
                // `run` or `discard` releases the block and frees the task.
                ShellMod.dispatchWithCleanup(&run, self, &discard);
            }

            /// Before the reply block was copied: answer with the borrowed one.
            fn fail(self: *SyncCall, err_name: []const u8) void {
                replyError(self.reply, err_name);
                self.arena_state.deinit();
                std.heap.smp_allocator.destroy(self);
            }

            fn run(ctx: ?*anyopaque) void {
                const self: *SyncCall = @ptrCast(@alignCast(ctx.?));
                defer finish(self);
                const arena = self.arena_state.allocator();
                const result = (if (window_commands.isWindowCommand(self.request.cmd))
                    window_commands.dispatch(config.security, local, arena, self.page_url, self.win_label, self.request.cmd, self.request.args)
                else if (ipc.isBuiltinCommand(self.request.cmd))
                    ipc.dispatchBuiltin(config.security, arena, self.request)
                else
                    ipc.dispatchRequest(api.commands, arena, self.request, self.io)) catch |err| {
                    replyError(self.reply, @errorName(err));
                    return;
                };
                replySuccess(self.reply, result);
            }

            /// Shutdown (main thread, queued from the main thread): reject
            /// the call so the page's Promise settles.
            fn discard(ctx: ?*anyopaque) void {
                const self: *SyncCall = @ptrCast(@alignCast(ctx.?));
                if (cocoa.isMainThread()) replyError(self.reply, "AppNotRunning");
                finish(self);
            }

            fn finish(self: *SyncCall) void {
                cocoa.releaseBlock(self.reply);
                self.arena_state.deinit();
                std.heap.smp_allocator.destroy(self);
            }
        };
    };
}

test {
    std.testing.refAllDecls(@This());
}
