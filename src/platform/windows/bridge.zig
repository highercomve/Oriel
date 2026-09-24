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
    \\  Object.defineProperty(window, "oriel", { value: Object.freeze({
    \\    invoke(cmd, args) {
    \\      return new Promise((resolve, reject) => {
    \\        const id = nextId++;
    \\        pending.set(id, { resolve, reject });
    \\        window.chrome.webview.postMessage(JSON.stringify({ id, cmd, args: args ?? null }));
    \\      });
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

pub fn evalJs(target: ?window_mod.WindowHandle, script: [:0]const u8) void {
    const gpa = std.heap.smp_allocator;
    const script_copy = gpa.dupeZ(u8, script) catch return;

    const Task = struct {
        target: ?window_mod.WindowHandle,
        script: [:0]u8,

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer {
                std.heap.smp_allocator.free(self.script);
                std.heap.smp_allocator.destroy(self);
            }

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
    ShellMod.dispatchToMainThread(&Task.run, task);
}

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
) type {
    return struct {
        const Self = @This();

        pub fn setupUserContent(view: *webview2.ICoreWebView2) void {
            const gpa = std.heap.smp_allocator;
            const script_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, bridge_js) catch return;
            defer gpa.free(script_w);

            _ = view.addScriptToExecuteOnDocumentCreated(script_w.ptr, null);
        }

        pub fn onMessage(
            view: *webview2.ICoreWebView2,
            args: *webview2.ICoreWebView2WebMessageReceivedEventArgs,
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

            const caller_win = window_mod.getWindowByView(view);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;

            if (!security.commandAllowedForWindow(config.security, local, page_url, req.cmd, win_label)) {
                log.warn("blocked command '{s}' from {s} (window: {?s})", .{ req.cmd, page_url, win_label });
                sendErrorReply(view, req.id, "Forbidden");
                return;
            }

            const pool = App.getWorkerPool();

            if (!ipc.isAsync(api.commands, req.cmd)) {
                const request = ipc.Request{ .cmd = req.cmd, .args = req.args };
                const result = ipc.dispatchRequest(api.commands, temp_alloc, request, if (pool) |p| p.io else null) catch |err| {
                    sendErrorReply(view, req.id, @errorName(err));
                    return;
                };
                sendSuccessReply(view, req.id, result);
                return;
            }

            // Async command: execute on worker pool and reply on main thread.
            const worker_pool = pool orelse {
                sendErrorReply(view, req.id, "WorkerPoolNotRunning");
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
                    ShellMod.dispatchToMainThread(&idleReply, self);
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
                _ = view.lpVtbl.Release(view);
                sendErrorReply(view, req.id, "OutOfMemory");
                return;
            };
            async_ctx.* = .{
                .view = view,
                .id = req.id,
                .arena_state = undefined,
                .result = null,
                .err_name = null,
            };

            ipc.dispatchAsync(api.commands, worker_pool, std.heap.smp_allocator, msg_u8, worker_pool.io, async_ctx, AsyncReplyContext.onWorkerDone) catch |err| {
                _ = view.lpVtbl.Release(view);
                std.heap.smp_allocator.destroy(async_ctx);
                sendErrorReply(view, req.id, @errorName(err));
                return;
            };
        }

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
