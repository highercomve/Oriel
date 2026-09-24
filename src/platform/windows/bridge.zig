//! WebView2 JS <-> Zig IPC bridge and script message handling.
//!
//! Injects `window.oriel` JS API into permitted origins and routes commands
//! through `ipc.dispatchRequest` and `ipc.dispatchAsync`. Handles synchronous
//! and asynchronous replies via `PostWebMessageAsJson`.
//!
//! COM handler lifetime note: bridge.zig implements no COM event/completion handlers directly.
//! Web message reception is handled by MessageHandler in window.zig, and script execution
//! passes null completion handlers (no callbacks registered).

const std = @import("std");
const win32 = @import("win32.zig");
const webview2 = @import("webview2.zig");
const window_mod = @import("window.zig");
const ShellMod = @import("Shell.zig");
const App = @import("../../core/App.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");

const log = std.log.scoped(.oriel);

/// Injected into allowed pages before their own scripts run.
pub const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const pending = new Map();
    \\  let nextId = 1;
    \\  window.chrome.webview.addEventListener('message', (event) => {
    \\    const data = event.data;
    \\    if (data && typeof data === 'object' && '__oriel_reply' in data) {
    \\      const p = pending.get(data.id);
    \\      if (p) {
    \\        pending.delete(data.id);
    \\        if (data.error) {
    \\          p.reject(new Error(data.error));
    \\        } else {
    \\          p.resolve(data.result);
    \\        }
    \\      }
    \\    }
    \\  });
    \\  function invoke(cmd, args) {
    \\    return new Promise((resolve, reject) => {
    \\      const id = nextId++;
    \\      pending.set(id, { resolve, reject });
    \\      window.chrome.webview.postMessage(JSON.stringify({ id, cmd, args: args ?? null }));
    \\    });
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
    \\      return () => set.delete(callback);
    \\    },
    \\    openExternal(url) {
    \\      return this.invoke("open_external", { url });
    \\    },
    \\    __emit(event, payload) {
    \\      for (const cb of listeners.get(event) ?? []) {
    \\        try { cb(payload); } catch (e) { console.error(e); }
    \\      }
    \\    },
    \\    window: Object.freeze(windowApi),
    \\  }) });
    \\})();
;

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

            const script_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, self.script) catch return;
            defer std.heap.smp_allocator.free(script_w);

            if (self.target) |v| {
                // Handles match by HWND only: use the live window's webview,
                // not the (possibly stale) copy queued with the task.
                if (App.getWindowByHandle(v)) |win| {
                    _ = win.handle.webview.executeScript(script_w.ptr, null);
                }
            } else {
                App.ensureWindowsMutex();
                App.windows_mutex.lock();
                defer App.windows_mutex.unlock();
                for (App.windows_list.items) |win| {
                    _ = win.handle.webview.executeScript(script_w.ptr, null);
                }
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

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
) type {
    const window_commands = @import("../../core/window_commands.zig");
    return struct {
        const Self = @This();

        pub fn setupUserContent(view: *webview2.ICoreWebView2, label: [:0]const u8) void {
            const gpa = std.heap.smp_allocator;
            const label_json = std.json.Stringify.valueAlloc(gpa, label, .{}) catch return;
            defer gpa.free(label_json);
            const script = std.fmt.allocPrintSentinel(gpa, "window.__oriel_window_label = {s};\n{s}", .{ label_json, bridge_js }, 0) catch return;
            defer gpa.free(script);
            const script_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, script) catch return;
            defer gpa.free(script_w);

            _ = view.addScriptToExecuteOnDocumentCreated(script_w.ptr, null);
        }

        pub fn onMessage(
            view: *webview2.ICoreWebView2,
            args: *webview2.ICoreWebView2WebMessageReceivedEventArgs,
            hwnd: win32.HWND,
        ) void {
            var msg_w: ?win32.LPWSTR = null;
            if (args.lpVtbl.TryGetWebMessageAsString(args, @ptrCast(&msg_w)) < 0 or msg_w == null) return;
            defer win32.CoTaskMemFree(msg_w);

            const gpa = std.heap.smp_allocator;
            const msg_len = std.mem.indexOfScalar(u16, std.mem.span(msg_w.?), 0) orelse std.mem.span(msg_w.?).len;
            const msg_u8 = std.unicode.utf16LeToUtf8Alloc(gpa, msg_w.?[0..msg_len]) catch return;
            defer gpa.free(msg_u8);

            var parse_arena = std.heap.ArenaAllocator.init(gpa);
            defer parse_arena.deinit();
            const temp_alloc = parse_arena.allocator();

            const WinReq = struct {
                id: ?u64 = null,
                cmd: []const u8,
                args: std.json.Value = .null,
            };

            const req = std.json.parseFromSliceLeaky(WinReq, temp_alloc, msg_u8, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                sendErrorReply(view, null, @errorName(err));
                return;
            };

            var src_w: ?win32.LPWSTR = null;
            const src_hr = args.lpVtbl.get_Source(args, @ptrCast(&src_w));
            defer if (src_w != null) win32.CoTaskMemFree(src_w);

            const page_url: []const u8 = if (src_hr >= 0 and src_w != null) blk: {
                const slen = std.mem.indexOfScalar(u16, std.mem.span(src_w.?), 0) orelse std.mem.span(src_w.?).len;
                break :blk std.unicode.utf16LeToUtf8Alloc(temp_alloc, src_w.?[0..slen]) catch "";
            } else "";

            const caller_win = window_mod.getWindowByHwnd(hwnd) orelse window_mod.getWindowByView(view);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;

            if (window_commands.isWindowCommand(req.cmd)) {
                SyncCall.queue(view, req.id, req.cmd, req.args, page_url, win_label, null);
                return;
            }

            if (!security.commandAllowedForWindow(config.security, local, page_url, req.cmd, win_label)) {
                log.warn("blocked command '{s}' from {s} (window: {?s})", .{ req.cmd, page_url, win_label });
                sendErrorReply(view, req.id, "Forbidden");
                return;
            }

            const pool = App.getWorkerPool();

            if (!ipc.isAsync(api.commands, req.cmd)) {
                // Run sync commands from the message loop, not inside this
                // WebView2 event handler: a command that pumps messages (e.g.
                // openWindow waiting for a new WebView2 controller, or a modal
                // file dialog) would otherwise nest a message loop inside the
                // handler, which WebView2 doesn't support (it hangs). Tasks run
                // in order, so replies keep the order of the requests.
                SyncCall.queue(view, req.id, req.cmd, req.args, page_url, win_label, if (pool) |p| p.io else null);
                return;
            }

            // Async command: execute on worker pool and reply on main thread.
            const worker_pool = pool orelse {
                sendErrorReply(view, req.id, "WorkerPoolNotRunning");
                return;
            };

            // The Windows bridge message also carries the reply `id`, which
            // ipc.Request (and its strict parser) doesn't know: hand the
            // worker just `{cmd, args}`.
            const request_json = std.json.Stringify.valueAlloc(temp_alloc, ipc.Request{ .cmd = req.cmd, .args = req.args }, .{}) catch |err| {
                sendErrorReply(view, req.id, @errorName(err));
                return;
            };

            _ = view.lpVtbl.AddRef(view);

            const AsyncReplyContext = struct {
                view: *webview2.ICoreWebView2,
                id: ?u64,
                arena_state: std.heap.ArenaAllocator,
                result: ?[:0]const u8,
                err_name: ?[:0]const u8,

                fn onWorkerDone(self: *@This(), arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                    self.arena_state = arena_state;
                    self.result = res;
                    self.err_name = err_name;
                    ShellMod.dispatchWithCleanup(&idleReply, self, &discardReply);
                }

                /// The reply couldn't be queued, or the app shut down first.
                fn discardReply(ctx: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    // COM objects may only be released on their own (main)
                    // thread; from a worker, leak the one reference instead.
                    if (win32.GetCurrentThreadId() == ShellMod.main_thread_id) {
                        _ = self.view.lpVtbl.Release(self.view);
                    }
                    var a = self.arena_state;
                    a.deinit();
                    std.heap.smp_allocator.destroy(self);
                }

                fn idleReply(ctx: ?*anyopaque) void {
                    const self: *@This() = @ptrCast(@alignCast(ctx));
                    defer {
                        _ = self.view.lpVtbl.Release(self.view);
                        var a = self.arena_state;
                        a.deinit();
                        std.heap.smp_allocator.destroy(self);
                    }

                    if (self.err_name) |err| {
                        sendErrorReply(self.view, self.id, err);
                    } else if (self.result) |res| {
                        sendSuccessReply(self.view, self.id, res);
                    }
                }
            };

            const async_ctx = std.heap.smp_allocator.create(AsyncReplyContext) catch {
                sendErrorReply(view, req.id, "OutOfMemory");
                _ = view.lpVtbl.Release(view);
                return;
            };
            async_ctx.* = .{
                .view = view,
                .id = req.id,
                .arena_state = undefined,
                .result = null,
                .err_name = null,
            };

            ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, request_json, worker_pool.io, async_ctx, AsyncReplyContext.onWorkerDone) catch |err| {
                std.heap.smp_allocator.destroy(async_ctx);
                sendErrorReply(view, req.id, @errorName(err));
                _ = view.lpVtbl.Release(view);
                return;
            };
        }

        /// A sync command deferred to the main thread's message loop. Owns a
        /// reference on the webview and an arena with the request.
        const SyncCall = struct {
            view: *webview2.ICoreWebView2,
            id: ?u64,
            arena_state: std.heap.ArenaAllocator,
            request: ipc.Request,
            page_url: []const u8,
            win_label: ?[]const u8,
            io: ?std.Io,

            fn queue(
                view: *webview2.ICoreWebView2,
                id: ?u64,
                cmd: []const u8,
                args: std.json.Value,
                page_url: []const u8,
                win_label: ?[]const u8,
                io: ?std.Io,
            ) void {
                const gpa = std.heap.smp_allocator;
                const self = gpa.create(SyncCall) catch {
                    sendErrorReply(view, id, "OutOfMemory");
                    return;
                };
                self.* = .{
                    .view = view,
                    .id = id,
                    .arena_state = .init(gpa),
                    .request = undefined,
                    .page_url = "",
                    .win_label = null,
                    .io = io,
                };
                const arena = self.arena_state.allocator();
                self.page_url = arena.dupe(u8, page_url) catch {
                    self.fail("OutOfMemory");
                    return;
                };
                if (win_label) |wl| {
                    self.win_label = arena.dupe(u8, wl) catch {
                        self.fail("OutOfMemory");
                        return;
                    };
                }
                // Deep-copy the request out of the caller's parse arena.
                const request_json = std.json.Stringify.valueAlloc(arena, ipc.Request{ .cmd = cmd, .args = args }, .{}) catch {
                    self.fail("OutOfMemory");
                    return;
                };
                self.request = ipc.parseRequest(arena, request_json) catch |err| {
                    self.fail(@errorName(err));
                    return;
                };
                _ = view.lpVtbl.AddRef(view);
                // `run` or `discard` releases the reference and frees the task.
                ShellMod.dispatchWithCleanup(&run, self, &discard);
            }

            fn fail(self: *SyncCall, err_name: []const u8) void {
                sendErrorReply(self.view, self.id, err_name);
                self.arena_state.deinit();
                std.heap.smp_allocator.destroy(self);
            }

            fn run(ctx: ?*anyopaque) void {
                const self: *SyncCall = @ptrCast(@alignCast(ctx.?));
                defer finish(self);
                if (window_commands.isWindowCommand(self.request.cmd)) {
                    const result = window_commands.dispatch(
                        config.security,
                        local,
                        self.arena_state.allocator(),
                        self.page_url,
                        self.win_label,
                        self.request.cmd,
                        self.request.args,
                    ) catch |err| {
                        sendErrorReply(self.view, self.id, @errorName(err));
                        return;
                    };
                    sendSuccessReply(self.view, self.id, result);
                    return;
                }
                const result = (if (ipc.isBuiltinCommand(self.request.cmd))
                    ipc.dispatchBuiltin(config.security, self.arena_state.allocator(), self.request)
                else
                    ipc.dispatchRequest(api.commands, self.arena_state.allocator(), self.request, self.io)) catch |err| {
                    sendErrorReply(self.view, self.id, @errorName(err));
                    return;
                };
                sendSuccessReply(self.view, self.id, result);
            }

            /// Queue failure (on the calling thread, which is the main thread
            /// here) or shutdown: no reply, just release.
            fn discard(ctx: ?*anyopaque) void {
                finish(@ptrCast(@alignCast(ctx.?)));
            }

            fn finish(self: *SyncCall) void {
                _ = self.view.lpVtbl.Release(self.view);
                self.arena_state.deinit();
                std.heap.smp_allocator.destroy(self);
            }
        };

        fn sendSuccessReply(view: *webview2.ICoreWebView2, id: ?u64, result_json: []const u8) void {
            if (id == null) return;
            const gpa = std.heap.smp_allocator;
            const reply = std.fmt.allocPrint(gpa, "{{\"__oriel_reply\":true,\"id\":{d},\"result\":{s}}}", .{ id.?, result_json }) catch return;
            defer gpa.free(reply);

            const reply_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, reply) catch return;
            defer gpa.free(reply_w);

            _ = view.postWebMessageAsJson(reply_w.ptr);
        }

        fn sendErrorReply(view: *webview2.ICoreWebView2, id: ?u64, err_name: []const u8) void {
            if (id == null) return;
            const gpa = std.heap.smp_allocator;
            const err_json = std.json.Stringify.valueAlloc(gpa, err_name, .{}) catch return;
            defer gpa.free(err_json);
            const reply = std.fmt.allocPrint(gpa, "{{\"__oriel_reply\":true,\"id\":{d},\"error\":{s}}}", .{ id.?, err_json }) catch return;
            defer gpa.free(reply);

            const reply_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, reply) catch return;
            defer gpa.free(reply_w);

            _ = view.postWebMessageAsJson(reply_w.ptr);
        }
    };
}

test {
    std.testing.refAllDecls(@This());
}
