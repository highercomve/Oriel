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
const build_target = @import("../../core/target.zig");
const isolation = @import("../../core/isolation.zig");
const build_opts = @import("build_options");
/// -Dnative_ui: pages drawn with native views (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/appkit.zig") else struct {};
const native_engine = if (build_opts.native_ui) @import("../../native_ui/engine.zig") else struct {};

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

/// Injected into every top-level document before its own scripts run;
/// `commandAllowedForWindow` checks the page's origin on every call.
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

fn evaluate(view: cocoa.id, script: []const u8) void {
    const str = cocoa.nsString(script) orelse return;
    defer str.release();
    (Object{ .value = view }).msgSend(void, "evaluateJavaScript:completionHandler:", .{ str, cocoa.nil });
}

/// Native windows' engines (-Dnative_ui) to evaluate a script in, gathered
/// under the windows lock and run outside it: the page's JavaScript runs
/// synchronously and may open or close windows. By token, so a window that
/// closes on the way is skipped.
const NativeEngines = struct {
    tokens: [16]u64 = undefined,
    len: usize = 0,

    fn add(self: *NativeEngines, handle: window_mod.WindowHandle) void {
        if (comptime !build_opts.native_ui) return;
        const p = handle.native orelse return;
        if (self.len == self.tokens.len) return;
        self.tokens[self.len] = @as(*native.Surface, @ptrCast(@alignCast(p))).token;
        self.len += 1;
    }

    fn eval(self: *NativeEngines, script: [:0]const u8) void {
        if (comptime !build_opts.native_ui) return;
        for (self.tokens[0..self.len]) |t| if (native.get(t)) |surface| surface.engine.evalScript(script);
    }
};

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
            var engines: NativeEngines = .{};
            {
                App.ensureWindowsMutex();
                App.windows_mutex.lock();
                defer App.windows_mutex.unlock();
                // Handles match by serial: use the live window's webview,
                // not the (possibly stale) copy queued with the task.
                for (App.windows_list.items) |win| {
                    if (self.target != null and !win.handle.eql(self.target.?)) continue;
                    if (win.handle.webview != null) evaluate(win.handle.webview, self.script) else engines.add(win.handle);
                }
            }
            engines.eval(self.script);
        }
    };

    const task = gpa.create(Task) catch {
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .target = target, .script = script_copy };
    // On the main thread (a sync command emitting), evaluate now: queued for
    // later, it would reach the page after the command's reply. Other
    // threads queue it (in order with their command's reply).
    if (cocoa.isMainThread()) return Task.run(task);
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
            var engines: NativeEngines = .{};
            {
                App.ensureWindowsMutex();
                App.windows_mutex.lock();
                defer App.windows_mutex.unlock();
                for (App.windows_list.items) |win| {
                    if (!std.mem.eql(u8, win.label, self.label)) continue;
                    if (win.handle.webview != null) evaluate(win.handle.webview, self.script) else engines.add(win.handle);
                }
            }
            engines.eval(self.script);
        }
    };

    const task = gpa.create(Task) catch {
        gpa.free(label_copy);
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .label = label_copy, .script = script_copy };
    // See evalJs: in order with a sync command's reply.
    if (cocoa.isMainThread()) return Task.run(task);
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
        /// The native renderer's `invoke` (-Dnative_ui): the same dispatch as
        /// `onMessage`, for the app's own page. No IPC token or isolation: the
        /// page is the app's embedded code running in its own engine, not web
        /// content. `ctx` is the window (*App.Window). Every call runs from the
        /// main loop, never inside the page's JavaScript (a command may close
        /// the window and so its engine), and is answered by surface token.
        pub fn nativeInvoke(ctx: ?*anyopaque, token: u64, call_id: u32, cmd: []const u8, args_json: []const u8) void {
            _ = ctx; // the window is found again by its surface when the call runs
            const gpa = std.heap.smp_allocator;
            const call = gpa.create(NativeCall) catch return;
            call.* = .{ .token = token, .call_id = call_id, .arena_state = .init(gpa) };
            const a = call.arena_state.allocator();
            call.cmd = a.dupe(u8, cmd) catch return call.free();
            call.args_json = a.dupe(u8, args_json) catch return call.free();
            ShellMod.dispatchWithCleanup(&NativeCall.run, call, &NativeCall.discard);
        }

        const NativeCall = struct {
            token: u64,
            call_id: u32,
            arena_state: std.heap.ArenaAllocator,
            cmd: []const u8 = "",
            args_json: []const u8 = "",

            fn free(self: *NativeCall) void {
                self.arena_state.deinit();
                std.heap.smp_allocator.destroy(self);
            }

            fn discard(ctx: ?*anyopaque) void {
                free(@ptrCast(@alignCast(ctx.?)));
            }

            fn run(ctx: ?*anyopaque) void {
                const self: *NativeCall = @ptrCast(@alignCast(ctx.?));
                defer self.free();
                if (comptime !build_opts.native_ui) return;
                const surface = native.get(self.token) orelse return; // the window closed
                const arena = self.arena_state.allocator();
                // The window's label and URL, copied (it may close during the command).
                var label: []const u8 = "";
                var url: ?[]const u8 = null;
                {
                    App.ensureWindowsMutex();
                    App.windows_mutex.lock();
                    defer App.windows_mutex.unlock();
                    for (App.windows_list.items) |w| if (w.handle.native == @as(?*anyopaque, surface)) {
                        label = arena.dupe(u8, w.label) catch return;
                        url = if (w.options.url) |u| (arena.dupe(u8, u) catch return) else null;
                        break;
                    };
                }
                if (label.len == 0) return native.resolve(self.token, self.call_id, false, "WindowNotFound");
                const page_url = security.resolveWindowUrl(arena, config.security, local, null, url, config.start) catch "app://localhost/index.html";
                const args = std.json.parseFromSliceLeaky(std.json.Value, arena, self.args_json, .{}) catch .null;
                const request: ipc.Request = .{ .cmd = self.cmd, .args = args };
                const pool = App.getWorkerPool();
                const result: anyerror![]const u8 = blk: {
                    if (window_commands.isWindowCommand(self.cmd))
                        break :blk window_commands.dispatch(config.security, local, arena, page_url, label, self.cmd, args);
                    if (!security.commandAllowedForWindow(config.security, local, page_url, self.cmd, label)) {
                        log.warn("native page: blocked command \"{f}\" (window: {s})", .{ std.zig.fmtString(self.cmd[0..@min(self.cmd.len, 64)]), label });
                        break :blk error.Forbidden;
                    }
                    if (ipc.isBuiltinCommand(self.cmd)) break :blk ipc.dispatchBuiltin(config.security, arena, request);
                    if (!ipc.isAsync(api.commands, self.cmd)) break :blk ipc.dispatchRequest(api.commands, arena, request, if (pool) |p| p.io else null);
                    // Async: on the worker pool, answered from the main loop.
                    const worker_pool = pool orelse break :blk error.WorkerPoolNotRunning;
                    const req_json = std.fmt.allocPrint(arena, "{{\"cmd\":{f},\"args\":{s}}}", .{ std.json.fmt(self.cmd, .{}), if (self.args_json.len > 0) self.args_json else "null" }) catch break :blk error.OutOfMemory;
                    const job = std.heap.smp_allocator.create(NativeReply) catch break :blk error.OutOfMemory;
                    job.* = .{ .token = self.token, .call_id = self.call_id };
                    ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, req_json, worker_pool.io, job, NativeReply.onWorkerDone) catch |err| {
                        std.heap.smp_allocator.destroy(job);
                        break :blk err;
                    };
                    return;
                };
                if (result) |json| native.resolve(self.token, self.call_id, true, json) else |err| native.resolve(self.token, self.call_id, false, ipc.errorText(err));
            }
        };

        /// An async native command's answer, carried to the main loop.
        const NativeReply = struct {
            token: u64,
            call_id: u32,
            ok: bool = true,
            text: []u8 = &.{},

            fn onWorkerDone(self: *NativeReply, arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                var a = arena_state;
                defer a.deinit();
                const gpa = std.heap.smp_allocator;
                self.ok = err_name == null;
                self.text = gpa.dupe(u8, if (err_name) |e| e else res orelse "null") catch {
                    gpa.destroy(self);
                    return;
                };
                ShellMod.dispatchWithCleanup(&deliver, self, &drop);
            }

            fn deliver(ctx: ?*anyopaque) void {
                const self: *NativeReply = @ptrCast(@alignCast(ctx.?));
                defer drop(self);
                if (comptime build_opts.native_ui) native.resolve(self.token, self.call_id, self.ok, self.text);
            }

            fn drop(ctx: ?*anyopaque) void {
                const self: *NativeReply = @ptrCast(@alignCast(ctx.?));
                std.heap.smp_allocator.free(self.text);
                std.heap.smp_allocator.destroy(self);
            }
        };

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
            // The page's IPC token lives only in the bridge's closure (ipc.tokenScript).
            const token_js = try ipc.tokenScript(gpa, config.security, local);
            defer gpa.free(token_js);
            const with_iso = try std.mem.replaceOwned(u8, gpa, bridge_js, isolation_placeholder, comptime isolation.bridgeScript(config.security, local));
            defer gpa.free(with_iso);
            const with_token = try std.mem.replaceOwned(u8, gpa, with_iso, token_placeholder, token_js);
            defer gpa.free(with_token);
            const source = try std.fmt.allocPrint(gpa, "{s}window.__oriel_window_label = {s};\n{s}", .{ comptime security.bridgePrelude(config.security), label_json, with_token });
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

        /// `scheme://host[:port]/` of the frame's WKSecurityOrigin, or "" (no
        /// scope). Borrowed strings are copied into `buf`.
        fn senderOriginUrl(buf: []u8, frame: Object) []const u8 {
            const origin = frame.msgSend(Object, "securityOrigin", .{});
            if (origin.value == null) return "";
            const scheme = cocoa.utf8(origin.msgSend(Object, "protocol", .{})) orelse return "";
            const host = cocoa.utf8(origin.msgSend(Object, "host", .{})) orelse return "";
            if (scheme.len == 0 or host.len == 0) return "";
            const port = origin.msgSend(isize, "port", .{});
            return (if (port > 0)
                std.fmt.bufPrint(buf, "{s}://{s}:{d}/", .{ scheme, host, port })
            else
                std.fmt.bufPrint(buf, "{s}://{s}/", .{ scheme, host })) catch "";
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

            const message_request = ipc.parseRequest(temp_alloc, req_slice) catch |err| {
                replyError(reply, ipc.errorText(err));
                return;
            };
            // The sending document's origin decides the IPC scope (not
            // webView.URL, which already shows a provisional navigation's URL
            // while the old document still runs).
            const view = message.msgSend(Object, "webView", .{});
            var origin_buf: [512]u8 = undefined;
            const page_url = senderOriginUrl(&origin_buf, frame);
            const caller_win = window_mod.getWindowByView(view.value);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;
            // Only the bridge script has the token for this page's origin
            // (ipc.tokenScript / ipc.tokenValid).
            if (!ipc.tokenValid(message_request.token, config.security, local, page_url)) {
                log.warn("refused an IPC call without this page's token (\"{f}\")", .{std.zig.fmtString(message_request.cmd[0..@min(message_request.cmd.len, 64)])});
                replyError(reply, "Forbidden");
                return;
            }
            // With isolation on, the app's pages send only calls the
            // isolation hook signed; `request` is the call inside.
            const checked = isolation.check(temp_alloc, config.security, local, page_url, if (view.value) |v| @intFromPtr(v) else 0, message_request, req_slice) catch |err| {
                replyError(reply, isolation.errorText(err));
                return;
            };
            const request = checked.request;
            // Page-controlled: escaped and capped in logs.
            const cmd_log = std.zig.fmtString(request.cmd[0..@min(request.cmd.len, 64)]);

            if (!window_commands.isWindowCommand(request.cmd) and
                !security.commandAllowedForWindow(config.security, local, page_url, request.cmd, win_label))
            {
                log.warn("blocked command \"{f}\" from {s} (window: {?s})", .{ cmd_log, page_url, win_label });
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
            ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, checked.json, worker_pool.io, async_ctx, AsyncReply.onWorkerDone) catch |err| {
                cocoa.releaseBlock(async_ctx.reply);
                std.heap.smp_allocator.destroy(async_ctx);
                replyError(reply, ipc.errorText(err));
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
                self.request = ipc.parseRequest(arena, request_json) catch |err| return self.fail(ipc.errorText(err));
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
                    replyError(self.reply, ipc.errorText(err));
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
