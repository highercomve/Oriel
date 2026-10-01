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
const isolation = @import("../../core/isolation.zig");

const log = std.log.scoped(.oriel);

const build_opts = @import("build_options");
/// -Dnative_ui: pages drawn with native views (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/engine.zig") else struct {
    pub const Engine = opaque {};
};

/// Up to 16 native windows' engines, found under the windows lock and
/// called outside it (a page may open or close windows).
const NativeEngines = struct {
    items: [16]*native.Engine = undefined,
    len: usize = 0,

    fn add(self: *NativeEngines, win: *App.Window) void {
        if (comptime !build_opts.native_ui) return;
        const e = win.handle.native orelse return;
        if (self.len == self.items.len) return;
        self.items[self.len] = @ptrCast(@alignCast(e));
        self.len += 1;
    }

    fn eval(self: *const NativeEngines, script: [:0]const u8) void {
        if (comptime !build_opts.native_ui) return;
        for (self.items[0..self.len]) |e| e.evalScript(script);
    }
};

/// The engine still belongs to an open window (a reply or event for a
/// window that closed meanwhile is dropped, not run on a freed engine).
pub fn nativeEngineAlive(e: *native.Engine) bool {
    if (comptime !build_opts.native_ui) return false;
    App.ensureWindowsMutex();
    App.windows_mutex.lock();
    defer App.windows_mutex.unlock();
    for (App.windows_list.items) |win| if (win.handle.native == @as(?*anyopaque, @ptrCast(e))) return true;
    return false;
}

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

/// Injected into allowed pages before their own scripts run (shared with
/// the Android bridge, which swaps the transport).
pub const bridge_js = @import("bridge_script.zig").bridge_js;

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

            var engines: NativeEngines = .{};
            if (self.target) |v| {
                // Handles match by HWND only: use the live window's webview,
                // not the (possibly stale) copy queued with the task.
                App.ensureWindowsMutex();
                App.windows_mutex.lock();
                var webview: ?*webview2.ICoreWebView2 = null;
                for (App.windows_list.items) |win| if (win.handle.eql(v)) {
                    webview = win.handle.webview;
                    engines.add(win);
                    break;
                };
                App.windows_mutex.unlock();

                if (webview) |view| {
                    _ = view.executeScript(script_w.ptr, null);
                }
            } else {
                App.ensureWindowsMutex();
                App.windows_mutex.lock();
                for (App.windows_list.items) |win| {
                    if (win.handle.webview) |view| _ = view.executeScript(script_w.ptr, null);
                    engines.add(win);
                }
                App.windows_mutex.unlock();
            }
            engines.eval(self.script);
        }
    };

    const task = gpa.create(Task) catch {
        gpa.free(script_copy);
        return;
    };
    task.* = .{ .target = target, .script = script_copy };
    ShellMod.dispatchWithCleanup(&Task.run, task, &Task.cleanup);
}

/// Deliver an event as a web message, the channel IPC replies use, so a
/// command's events reach the page before its reply (ExecuteScript runs
/// later, and out of order with web messages). On the main thread (where
/// sync commands run) it posts at once; from other threads through the
/// dispatch queue, which the command's reply also goes through, later.
/// `target` or `label` picks one window; neither = every window.
pub fn emitEvent(target: ?window_mod.WindowHandle, label: ?[]const u8, name_json: []const u8, payload_json: []const u8) void {
    const gpa = std.heap.smp_allocator;
    const msg = std.fmt.allocPrint(gpa, "{{\"__oriel_event\":{s},\"payload\":{s}}}", .{ name_json, payload_json }) catch return;
    defer gpa.free(msg);
    const msg_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, msg) catch return;
    // Native pages (-Dnative_ui) get the event as a call, like App.emit's
    // script on platforms without web messages.
    const script: ?[:0]u8 = if (comptime build_opts.native_ui)
        (std.fmt.allocPrintSentinel(gpa, "window.oriel?.__emit({s}, {s});", .{ name_json, payload_json }, 0) catch {
            gpa.free(msg_w);
            return;
        })
    else
        null;

    const Task = struct {
        target: ?window_mod.WindowHandle,
        label: ?[]u8,
        msg_w: [:0]u16,
        script: ?[:0]u8,

        fn discard(self: *@This()) void {
            const a = std.heap.smp_allocator;
            if (self.label) |l| a.free(l);
            if (self.script) |s| a.free(s);
            a.free(self.msg_w);
            a.destroy(self);
        }

        fn cleanup(ctx: ?*anyopaque) void {
            discard(@ptrCast(@alignCast(ctx)));
        }

        fn run(ctx: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            defer discard(self);
            var engines: NativeEngines = .{};
            App.ensureWindowsMutex();
            App.windows_mutex.lock();
            for (App.windows_list.items) |win| {
                // Handles match by HWND: the live window's webview, not a stale copy.
                if (self.target) |t| if (!win.handle.eql(t)) continue;
                if (self.label) |l| if (!std.mem.eql(u8, win.label, l)) continue;
                if (win.handle.webview) |view| _ = view.postWebMessageAsJson(self.msg_w.ptr);
                engines.add(win);
            }
            App.windows_mutex.unlock();
            if (self.script) |s| engines.eval(s);
        }
    };

    const task = gpa.create(Task) catch {
        gpa.free(msg_w);
        if (script) |s| gpa.free(s);
        return;
    };
    task.* = .{ .target = target, .label = null, .msg_w = msg_w, .script = script };
    if (label) |l| task.label = gpa.dupe(u8, l) catch {
        Task.discard(task);
        return;
    };
    if (win32.GetCurrentThreadId() == ShellMod.main_thread_id) {
        Task.run(task);
    } else {
        ShellMod.dispatchWithCleanup(&Task.run, task, &Task.cleanup);
    }
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

            const script_w = std.unicode.utf8ToUtf16LeAllocZ(std.heap.smp_allocator, self.script) catch return;
            defer std.heap.smp_allocator.free(script_w);

            App.ensureWindowsMutex();
            App.windows_mutex.lock();
            var webview: ?*webview2.ICoreWebView2 = null;
            // A native window (-Dnative_ui) has an engine instead of a web
            // view: targeted events (App.emitTo) must reach it too.
            var engines: NativeEngines = .{};
            for (App.windows_list.items) |win| if (std.mem.eql(u8, win.label, self.label)) {
                webview = win.handle.webview;
                engines.add(win);
                break;
            };
            App.windows_mutex.unlock();

            if (webview) |view| {
                _ = view.executeScript(script_w.ptr, null);
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

        /// Register the bridge script for every document of `view`. The
        /// registration is asynchronous: `done` is invoked once it applies,
        /// and only then may the first page load (else it can miss the
        /// bridge). False when registration couldn't start (`done` is not
        /// kept or called).
        pub fn setupUserContent(view: *webview2.ICoreWebView2, label: [:0]const u8, done: *webview2.ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler) bool {
            const gpa = std.heap.smp_allocator;
            const label_json = std.json.Stringify.valueAlloc(gpa, label, .{}) catch return false;
            defer gpa.free(label_json);
            // The page's IPC token lives only in the bridge's closure
            // (ipc.tokenScript picks it by the document's own origin, so a
            // frame from another origin, which also gets this script, has none).
            const token_js = ipc.tokenScript(gpa, config.security, local) catch return false;
            defer gpa.free(token_js);
            const with_iso = std.mem.replaceOwned(u8, gpa, bridge_js, isolation_placeholder, comptime isolation.bridgeScript(config.security, local)) catch return false;
            defer gpa.free(with_iso);
            const with_token = std.mem.replaceOwned(u8, gpa, with_iso, token_placeholder, token_js) catch return false;
            defer gpa.free(with_token);
            const script = std.fmt.allocPrintSentinel(gpa, "{s}window.__oriel_window_label = {s};\n{s}", .{ comptime security.bridgePrelude(config.security), label_json, with_token }, 0) catch return false;
            defer gpa.free(script);
            const script_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, script) catch return false;
            defer gpa.free(script_w);

            const hr = view.addScriptToExecuteOnDocumentCreated(script_w.ptr, done);
            if (hr < 0) {
                log.err("the bridge script could not be registered (0x{X}): pages get no window.oriel", .{@as(u32, @bitCast(hr))});
                return false;
            }
            return true;
        }

        /// The native renderer's `invoke` (-Dnative_ui): the same dispatch as
        /// `onMessage`, for the app's own page. No IPC token or isolation:
        /// the page is the app's embedded code running in its own engine, not
        /// web content. Runs from the message loop (queued, as sync web
        /// commands are: a command that pumps messages must not nest inside
        /// the page's JavaScript), and answers only engines still open.
        pub fn nativeInvoke(_: ?*anyopaque, engine: *native.Engine, call_id: u32, cmd: []const u8, args_json: []const u8) void {
            const gpa = std.heap.smp_allocator;
            const call = gpa.create(NativeCall) catch return;
            call.* = .{ .engine = engine, .call_id = call_id, .cmd = gpa.dupe(u8, cmd) catch {
                gpa.destroy(call);
                return;
            }, .args = gpa.dupe(u8, args_json) catch {
                gpa.free(call.cmd);
                gpa.destroy(call);
                return;
            } };
            ShellMod.dispatchWithCleanup(&NativeCall.run, call, &NativeCall.cleanup);
        }

        const NativeCall = struct {
            engine: *native.Engine,
            call_id: u32,
            cmd: []u8,
            args: []u8,

            fn cleanup(ctx: ?*anyopaque) void {
                const self: *NativeCall = @ptrCast(@alignCast(ctx));
                const gpa = std.heap.smp_allocator;
                gpa.free(self.cmd);
                gpa.free(self.args);
                gpa.destroy(self);
            }

            fn run(ctx: ?*anyopaque) void {
                if (comptime !build_opts.native_ui) return;
                const self: *NativeCall = @ptrCast(@alignCast(ctx));
                defer cleanup(ctx);
                const gpa = std.heap.smp_allocator;
                var arena_state = std.heap.ArenaAllocator.init(gpa);
                defer arena_state.deinit();
                const arena = arena_state.allocator();

                // The window by its engine (it may have closed since the call).
                App.ensureWindowsMutex();
                App.windows_mutex.lock();
                var label: ?[]const u8 = null;
                var url: ?[]const u8 = null;
                for (App.windows_list.items) |win| if (win.handle.native == @as(?*anyopaque, @ptrCast(self.engine))) {
                    label = arena.dupe(u8, win.label) catch null;
                    url = if (win.options.url) |u| arena.dupe(u8, u) catch null else null;
                    break;
                };
                App.windows_mutex.unlock();
                const win_label = label orelse return;

                const page_url = security.resolveWindowUrl(arena, config.security, local, null, url, config.start) catch "app://localhost/index.html";
                const args = std.json.parseFromSliceLeaky(std.json.Value, arena, self.args, .{}) catch .null;
                const request: ipc.Request = .{ .cmd = self.cmd, .args = args };
                const pool = App.getWorkerPool();

                const result: anyerror![]const u8 = blk: {
                    if (window_commands.isWindowCommand(self.cmd))
                        break :blk window_commands.dispatch(config.security, local, arena, page_url, win_label, self.cmd, args);
                    if (!security.commandAllowedForWindow(config.security, local, page_url, self.cmd, win_label)) {
                        log.warn("native page: blocked command \"{f}\" (window: {s})", .{ std.zig.fmtString(self.cmd[0..@min(self.cmd.len, 64)]), win_label });
                        break :blk error.Forbidden;
                    }
                    if (ipc.isBuiltinCommand(self.cmd)) break :blk ipc.dispatchBuiltin(config.security, arena, request);
                    if (!ipc.isAsync(api.commands, self.cmd)) break :blk ipc.dispatchRequest(api.commands, arena, request, if (pool) |p| p.io else null);
                    // Async: on the worker pool, answered from the message loop.
                    const worker_pool = pool orelse break :blk error.WorkerPoolNotRunning;
                    const req_json = std.fmt.allocPrint(arena, "{{\"cmd\":{f},\"args\":{s}}}", .{ std.json.fmt(self.cmd, .{}), if (self.args.len > 0) self.args else "null" }) catch break :blk error.OutOfMemory;
                    const job = gpa.create(NativeReply) catch break :blk error.OutOfMemory;
                    job.* = .{ .engine = self.engine, .call_id = self.call_id };
                    ipc.dispatchAsync(api.commands, worker_pool, gpa, req_json, worker_pool.io, job, NativeReply.onWorkerDone) catch |err| {
                        gpa.destroy(job);
                        break :blk err;
                    };
                    return;
                };
                // A sync command may have closed the window.
                if (!nativeEngineAlive(self.engine)) return;
                if (result) |json| self.engine.resolve(self.call_id, true, json) else |err| self.engine.resolve(self.call_id, false, ipc.errorText(err));
            }
        };

        /// An async command's answer, from a worker to the message loop.
        const NativeReply = struct {
            engine: *native.Engine,
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
                ShellMod.dispatchWithCleanup(&deliver, self, &discard);
            }

            fn discard(ctx: ?*anyopaque) void {
                const self: *NativeReply = @ptrCast(@alignCast(ctx));
                std.heap.smp_allocator.free(self.text);
                std.heap.smp_allocator.destroy(self);
            }

            fn deliver(ctx: ?*anyopaque) void {
                if (comptime !build_opts.native_ui) return;
                const self: *NativeReply = @ptrCast(@alignCast(ctx));
                defer discard(ctx);
                // The window may have closed while the command ran.
                if (!nativeEngineAlive(self.engine)) return;
                self.engine.resolve(self.call_id, self.ok, self.text);
            }
        };

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
                token: ?[]const u8 = null,
                iso: ?isolation.Sealed = null,
            };

            const req = std.json.parseFromSliceLeaky(WinReq, temp_alloc, msg_u8, .{
                .ignore_unknown_fields = true,
            }) catch |err| {
                sendErrorReply(view, null, ipc.errorText(err));
                return;
            };

            var src_w: ?win32.LPWSTR = null;
            const src_hr = args.lpVtbl.get_Source(args, @ptrCast(&src_w));
            defer if (src_w != null) win32.CoTaskMemFree(src_w);

            const page_url: []const u8 = if (src_hr >= 0 and src_w != null) blk: {
                const slen = std.mem.indexOfScalar(u16, std.mem.span(src_w.?), 0) orelse std.mem.span(src_w.?).len;
                break :blk std.unicode.utf16LeToUtf8Alloc(temp_alloc, src_w.?[0..slen]) catch "";
            } else "";

            // Before anything else: the call must carry the token of the
            // document that sent it (page_url is the sender's URL), which only
            // that origin's bridge closure has.
            if (!ipc.tokenValid(req.token, config.security, local, page_url)) {
                log.warn("refused an IPC call without this page's token (\"{f}\")", .{std.zig.fmtString(req.cmd[0..@min(req.cmd.len, 64)])});
                sendErrorReply(view, req.id, "Forbidden");
                return;
            }
            // With isolation on, the app's pages send only calls the
            // isolation hook signed; `call` is the call inside.
            const checked = isolation.check(temp_alloc, config.security, local, page_url, @intFromPtr(view), .{ .cmd = req.cmd, .args = req.args, .token = req.token, .iso = req.iso }, msg_u8) catch |err| {
                sendErrorReply(view, req.id, isolation.errorText(err));
                return;
            };
            const call = checked.request;
            // Page-controlled: escaped and capped in logs.
            const cmd_log = std.zig.fmtString(call.cmd[0..@min(call.cmd.len, 64)]);

            const caller_win = window_mod.getWindowByHwnd(hwnd) orelse window_mod.getWindowByView(view);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;

            if (window_commands.isWindowCommand(call.cmd)) {
                SyncCall.queue(view, req.id, call.cmd, call.args, page_url, win_label, null);
                return;
            }

            if (!security.commandAllowedForWindow(config.security, local, page_url, call.cmd, win_label)) {
                log.warn("blocked command \"{f}\" from {s} (window: {?s})", .{ cmd_log, page_url, win_label });
                sendErrorReply(view, req.id, "Forbidden");
                return;
            }

            const pool = App.getWorkerPool();

            if (!ipc.isAsync(api.commands, call.cmd)) {
                // Run sync commands from the message loop, not inside this
                // WebView2 event handler: a command that pumps messages (e.g.
                // openWindow waiting for a new WebView2 controller, or a modal
                // file dialog) would otherwise nest a message loop inside the
                // handler, which WebView2 doesn't support (it hangs). Tasks run
                // in order, so replies keep the order of the requests.
                SyncCall.queue(view, req.id, call.cmd, call.args, page_url, win_label, if (pool) |p| p.io else null);
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
            const request_json = std.json.Stringify.valueAlloc(temp_alloc, ipc.Request{ .cmd = call.cmd, .args = call.args }, .{}) catch |err| {
                sendErrorReply(view, req.id, ipc.errorText(err));
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
                sendErrorReply(view, req.id, ipc.errorText(err));
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
                    self.fail(ipc.errorText(err));
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
                        sendErrorReply(self.view, self.id, ipc.errorText(err));
                        return;
                    };
                    sendSuccessReply(self.view, self.id, result);
                    return;
                }
                const result = (if (ipc.isBuiltinCommand(self.request.cmd))
                    ipc.dispatchBuiltin(config.security, self.arena_state.allocator(), self.request)
                else
                    ipc.dispatchRequest(api.commands, self.arena_state.allocator(), self.request, self.io)) catch |err| {
                    sendErrorReply(self.view, self.id, ipc.errorText(err));
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
