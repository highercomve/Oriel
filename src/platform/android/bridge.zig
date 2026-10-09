//! android.webkit.WebView JS <-> Zig IPC bridge.
//!
//! Transport: an AndroidX `WebMessageListener` (`WebViewCompat.addWebMessageListener`)
//! injects `__orielNative` into the pages whose origin matches the window's
//! rules; the bridge script (added at document start with
//! `addDocumentStartJavaScript`) keeps it in its closure and talks JSON over
//! it: requests carry an `id`, replies and events come back on the same
//! channel (`JavaScriptReplyProxy`), so a command's events arrive before its
//! reply, like the WebView2 bridge whose script this one is derived from.
//!
//! Every call is checked like on the other platforms: the page's IPC token,
//! the isolation seal, then `commandAllowedForWindow`. Only main frames are
//! served (Kotlin refuses the others before they get here).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const App = @import("../../core/App.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");
const isolation = @import("../../core/isolation.zig");
const runtime = @import("runtime.zig");
const ShellMod = @import("Shell.zig");
const window_mod = @import("window.zig");
const build_opts = @import("build_options");
/// -Dnative_ui: pages drawn with native views (docs/native-renderer.md).
const native = if (build_opts.native_ui) @import("../../native_ui/android.zig") else struct {};

const log = std.log.scoped(.oriel);

/// The first message of every document, handled by Kotlin: it keeps that
/// document's reply channel for replies and events.
pub const hello = "__oriel_hello__";

const token_placeholder = "/*__ORIEL_IPC_TOKEN__*/";
const isolation_placeholder = "/*__ORIEL_ISOLATION__*/";

/// The WebView2 bridge script with the Android transport.
pub const bridge_js = blk: {
    @setEvalBranchQuota(1_000_000);
    const base = @import("../windows/bridge_script.zig").bridge_js;
    const replacements = [_][2][]const u8{
        .{
            "(() => {\n",
            "(() => {\n  const native = globalThis.__orielNative;\n  if (!native) return;\n  native.postMessage(\"" ++ hello ++ "\");\n",
        },
        .{
            "  window.chrome.webview.addEventListener('message', (event) => {\n    const data = event.data;\n",
            "  native.addEventListener('message', (event) => {\n    let data;\n    try { data = JSON.parse(event.data); } catch (_) { return; }\n",
        },
        .{
            "window.chrome.webview.postMessage(",
            "native.postMessage(",
        },
    };
    var out: []const u8 = base;
    for (replacements) |r| {
        if (std.mem.count(u8, out, r[0]) != 1) @compileError("Android bridge: the WebView2 bridge script changed; update the transport replacements");
        const i = std.mem.indexOf(u8, out, r[0]).?;
        out = out[0..i] ++ r[1] ++ out[i + r[0].len ..];
    }
    if (std.mem.indexOf(u8, out, "chrome.webview") != null) @compileError("Android bridge: WebView2 transport left in the script");
    break :blk out;
};

/// Post `json` to window `id`'s page (UI thread).
fn post(id: u32, json: []const u8) void {
    if (comptime build_opts.native_ui) if (native.engineOf(id)) |e| return e.message(json);
    _ = runtime.call(.void, "postMessage", "(I[B)V", .{ @as(i32, @intCast(id)), json });
}

fn evaluate(id: u32, script: []const u8) void {
    if (comptime build_opts.native_ui) if (native.engineOf(id)) |e| {
        const z = heap.gpa.dupeZ(u8, script) catch return;
        defer heap.gpa.free(z);
        return e.evalScript(z);
    };
    _ = runtime.call(.void, "evalJs", "(I[B)V", .{ @as(i32, @intCast(id)), script });
}

/// A copy of a script (and optional label/target) run on the UI thread.
const EvalTask = struct {
    target: ?window_mod.WindowHandle,
    label: ?[]u8,
    text: []u8,
    /// Post as a web message (events) instead of evaluating.
    as_message: bool,

    fn create(target: ?window_mod.WindowHandle, label: ?[]const u8, text: []const u8, as_message: bool) ?*EvalTask {
        const gpa = heap.gpa;
        const self = gpa.create(EvalTask) catch return null;
        self.* = .{ .target = target, .label = null, .text = gpa.dupe(u8, text) catch {
            gpa.destroy(self);
            return null;
        }, .as_message = as_message };
        if (label) |l| self.label = gpa.dupe(u8, l) catch {
            discard(self);
            return null;
        };
        return self;
    }

    fn discard(ctx: ?*anyopaque) void {
        const self: *EvalTask = @ptrCast(@alignCast(ctx.?));
        const gpa = heap.gpa;
        if (self.label) |l| gpa.free(l);
        gpa.free(self.text);
        gpa.destroy(self);
    }

    fn run(ctx: ?*anyopaque) void {
        const self: *EvalTask = @ptrCast(@alignCast(ctx.?));
        defer discard(self);
        // Collect ids under the lock, call Java after (Java may call back).
        var ids: [64]u32 = undefined;
        var n: usize = 0;
        App.ensureWindowsMutex();
        App.windows_mutex.lock();
        for (App.windows_list.items) |win| {
            if (self.target) |t| if (!win.handle.eql(t)) continue;
            if (self.label) |l| if (!std.mem.eql(u8, win.label, l)) continue;
            if (n < ids.len) {
                ids[n] = win.handle.id;
                n += 1;
            }
        }
        App.windows_mutex.unlock();
        for (ids[0..n]) |id| if (self.as_message) post(id, self.text) else evaluate(id, self.text);
    }

    /// Now on the UI thread (in order with a sync command's reply), else queued.
    fn submit(self: *EvalTask) void {
        if (ShellMod.isMainThread()) return run(self);
        ShellMod.dispatchWithCleanup(&run, self, &discard);
    }
};

pub fn evalJs(target: ?window_mod.WindowHandle, script: [:0]const u8) void {
    const task = EvalTask.create(target, null, script, false) orelse return;
    task.submit();
}

pub fn evalJsByLabel(label: [:0]const u8, script: [:0]const u8) void {
    const task = EvalTask.create(null, label, script, false) orelse return;
    task.submit();
}

/// Deliver an event on the reply channel, so a command's events reach the
/// page before its reply. `target` or `label` picks one window; neither = all.
pub fn emitEvent(target: ?window_mod.WindowHandle, label: ?[]const u8, name_json: []const u8, payload_json: []const u8) void {
    const gpa = heap.gpa;
    const msg = std.fmt.allocPrint(gpa, "{{\"__oriel_event\":{s},\"payload\":{s}}}", .{ name_json, payload_json }) catch return;
    defer gpa.free(msg);
    const task = EvalTask.create(target, label, msg, true) orelse return;
    task.submit();
}

fn sendSuccessReply(id: u32, req_id: ?u64, result_json: []const u8) void {
    const rid = req_id orelse return;
    const gpa = heap.gpa;
    const reply = std.fmt.allocPrint(gpa, "{{\"__oriel_reply\":true,\"id\":{d},\"result\":{s}}}", .{ rid, result_json }) catch return;
    defer gpa.free(reply);
    post(id, reply);
}

fn sendErrorReply(id: u32, req_id: ?u64, err_name: []const u8) void {
    const rid = req_id orelse return;
    const gpa = heap.gpa;
    const err_json = std.json.Stringify.valueAlloc(gpa, err_name, .{}) catch return;
    defer gpa.free(err_json);
    const reply = std.fmt.allocPrint(gpa, "{{\"__oriel_reply\":true,\"id\":{d},\"error\":{s}}}", .{ rid, err_json }) catch return;
    defer gpa.free(reply);
    post(id, reply);
}

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
) type {
    const window_commands = @import("../../core/window_commands.zig");
    return struct {
        /// The document-start script for window `label`: the prelude, the
        /// label, and the bridge with this origin's token and the isolation
        /// part filled in. Caller frees.
        pub fn script(gpa: std.mem.Allocator, label: []const u8) ![]u8 {
            const label_json = try std.json.Stringify.valueAlloc(gpa, label, .{});
            defer gpa.free(label_json);
            const token_js = try ipc.tokenScript(gpa, config.security, local);
            defer gpa.free(token_js);
            const with_iso = try std.mem.replaceOwned(u8, gpa, bridge_js, isolation_placeholder, comptime isolation.bridgeScript(config.security, local));
            defer gpa.free(with_iso);
            const with_token = try std.mem.replaceOwned(u8, gpa, with_iso, token_placeholder, token_js);
            defer gpa.free(with_token);
            return std.fmt.allocPrint(gpa, "{s}window.__oriel_window_label = {s};\n{s}", .{ comptime security.bridgePrelude(config.security), label_json, with_token });
        }

        /// The native renderer's `invoke` (-Dnative_ui): the same dispatch as
        /// `onMessage`, for the app's own page. No IPC token or isolation: the
        /// page is the app's embedded code running in its own engine, not web
        /// content. Every call runs from the task queue, never inside the
        /// page's JavaScript (a command may close the window and so its
        /// engine), and finds its window again by id (ids aren't reused).
        pub fn nativeInvoke(ctx: ?*anyopaque, window: u32, call_id: u32, cmd: []const u8, args_json: []const u8) void {
            _ = ctx; // the window is found again by id when the call runs
            const gpa = heap.gpa;
            const call = gpa.create(NativeCall) catch return;
            call.* = .{ .window = window, .call_id = call_id, .arena_state = .init(gpa) };
            const a = call.arena_state.allocator();
            call.cmd = a.dupe(u8, cmd) catch return call.free();
            call.args_json = a.dupe(u8, args_json) catch return call.free();
            ShellMod.dispatchWithCleanup(&NativeCall.run, call, &NativeCall.discard);
        }

        const NativeCall = struct {
            window: u32,
            call_id: u32,
            arena_state: std.heap.ArenaAllocator,
            cmd: []const u8 = "",
            args_json: []const u8 = "",

            fn free(self: *NativeCall) void {
                self.arena_state.deinit();
                heap.gpa.destroy(self);
            }

            fn discard(ctx: ?*anyopaque) void {
                free(@ptrCast(@alignCast(ctx.?)));
            }

            fn run(ctx: ?*anyopaque) void {
                const self: *NativeCall = @ptrCast(@alignCast(ctx.?));
                defer self.free();
                if (comptime !build_opts.native_ui) return;
                const window = self.window;
                const call_id = self.call_id;
                const cmd = self.cmd;
                if (native.get(window) == null) return; // the window closed
                const gpa = heap.gpa;
                const arena = self.arena_state.allocator();
                // The window's label and URL, copied (it may close during the command).
                var label: []const u8 = "";
                var url: ?[]const u8 = null;
                {
                    App.ensureWindowsMutex();
                    App.windows_mutex.lock();
                    defer App.windows_mutex.unlock();
                    for (App.windows_list.items) |w| if (w.handle.id == window) {
                        label = arena.dupe(u8, w.label) catch return;
                        url = if (w.options.url) |u| (arena.dupe(u8, u) catch return) else null;
                        break;
                    };
                }
                if (label.len == 0) return NativeReply.send(window, call_id, false, "WindowNotFound");
                const page_url = security.resolveWindowUrl(arena, config.security, local, null, url, config.start) catch "https://app.localhost/index.html";
                const args = std.json.parseFromSliceLeaky(std.json.Value, arena, self.args_json, .{}) catch .null;
                const request: ipc.Request = .{ .cmd = cmd, .args = args };
                const pool = App.getWorkerPool();
                defer if (pool != null) App.releaseWorkerPool();

                const result: anyerror![]const u8 = blk: {
                    if (window_commands.isWindowCommand(cmd))
                        break :blk window_commands.dispatch(config.security, local, arena, page_url, label, cmd, args);
                    if (!security.commandAllowedForWindow(config.security, local, page_url, cmd, label)) {
                        log.warn("native page: blocked command \"{f}\" (window: {s})", .{ std.zig.fmtString(cmd[0..@min(cmd.len, 64)]), label });
                        break :blk error.Forbidden;
                    }
                    if (ipc.isBuiltinCommand(cmd)) break :blk ipc.dispatchBuiltin(config.security, arena, request);
                    if (!ipc.isAsync(api.commands, cmd)) break :blk ipc.dispatchRequest(api.commands, arena, request, if (pool) |p| p.io else null);
                    const worker_pool = pool orelse break :blk error.WorkerPoolNotRunning;
                    const req_json = std.json.Stringify.valueAlloc(arena, request, .{}) catch break :blk error.OutOfMemory;
                    const job = gpa.create(NativeReply) catch break :blk error.OutOfMemory;
                    job.* = .{ .window = window, .call_id = call_id };
                    ipc.dispatchAsync(api.commands, worker_pool, gpa, req_json, worker_pool.io, job, NativeReply.onWorkerDone) catch |err| {
                        gpa.destroy(job);
                        break :blk err;
                    };
                    return;
                };
                if (result) |json| NativeReply.send(window, call_id, true, json) else |err| NativeReply.send(window, call_id, false, ipc.errorText(err));
            }
        };

        const NativeReply = struct {
            window: u32,
            call_id: u32,
            ok: bool = true,
            text: []u8 = &.{},

            fn send(window: u32, call_id: u32, ok: bool, text: []const u8) void {
                const gpa = heap.gpa;
                const r = gpa.create(NativeReply) catch return;
                r.* = .{ .window = window, .call_id = call_id, .ok = ok, .text = gpa.dupe(u8, text) catch {
                    gpa.destroy(r);
                    return;
                } };
                ShellMod.dispatchWithCleanup(&run, r, &drop);
            }

            fn onWorkerDone(self: *NativeReply, arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                var a = arena_state;
                defer a.deinit();
                const window = self.window;
                const call_id = self.call_id;
                heap.gpa.destroy(self);
                if (err_name) |e| send(window, call_id, false, e) else send(window, call_id, true, res orelse "null");
            }

            fn run(ctx: ?*anyopaque) void {
                const self: *NativeReply = @ptrCast(@alignCast(ctx.?));
                defer drop(self);
                native.resolve(self.window, self.call_id, self.ok, self.text);
            }

            fn drop(ctx: ?*anyopaque) void {
                const self: *NativeReply = @ptrCast(@alignCast(ctx.?));
                heap.gpa.free(self.text);
                heap.gpa.destroy(self);
            }
        };

        const Message = struct {
            id: ?u64 = null,
            cmd: []const u8,
            args: std.json.Value = .null,
            token: ?[]const u8 = null,
            iso: ?isolation.Sealed = null,
        };

        /// A message from window `id`'s main frame (UI thread). `origin` is
        /// the sending document's origin ("https://app.localhost").
        pub fn onMessage(id: u32, data: []const u8, origin: []const u8) void {
            const gpa = heap.gpa;
            var parse_arena = std.heap.ArenaAllocator.init(gpa);
            defer parse_arena.deinit();
            const temp = parse_arena.allocator();

            const req = std.json.parseFromSliceLeaky(Message, temp, data, .{ .ignore_unknown_fields = true }) catch |err| {
                log.warn("invalid IPC message: {s}", .{@errorName(err)});
                return;
            };
            const page_url = std.fmt.allocPrint(temp, "{s}/", .{origin}) catch return sendErrorReply(id, req.id, "OutOfMemory");

            // The call must carry the token of the document that sent it.
            if (!ipc.tokenValid(req.token, config.security, local, page_url)) {
                log.warn("refused an IPC call without this page's token (\"{f}\")", .{std.zig.fmtString(req.cmd[0..@min(req.cmd.len, 64)])});
                return sendErrorReply(id, req.id, "Forbidden");
            }
            const checked = isolation.check(temp, config.security, local, page_url, id, .{ .cmd = req.cmd, .args = req.args, .token = req.token, .iso = req.iso }, data) catch |err| {
                return sendErrorReply(id, req.id, isolation.errorText(err));
            };
            const call = checked.request;
            const cmd_log = std.zig.fmtString(call.cmd[0..@min(call.cmd.len, 64)]);

            const caller_win = window_mod.getWindowById(id);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;

            if (window_commands.isWindowCommand(call.cmd)) {
                return SyncCall.queue(id, req.id, call.cmd, call.args, page_url, win_label, null);
            }
            if (!security.commandAllowedForWindow(config.security, local, page_url, call.cmd, win_label)) {
                log.warn("blocked command \"{f}\" from {s} (window: {?s})", .{ cmd_log, page_url, win_label });
                return sendErrorReply(id, req.id, "Forbidden");
            }

            const pool = App.getWorkerPool();
            defer if (pool != null) App.releaseWorkerPool();
            if (ipc.isBuiltinCommand(call.cmd) or !ipc.isAsync(api.commands, call.cmd)) {
                return SyncCall.queue(id, req.id, call.cmd, call.args, page_url, win_label, if (pool) |p| p.io else null);
            }

            const worker_pool = pool orelse return sendErrorReply(id, req.id, "WorkerPoolNotRunning");
            // The worker gets just `{cmd, args}` (ipc.Request has no `id`).
            const request_json = std.json.Stringify.valueAlloc(temp, ipc.Request{ .cmd = call.cmd, .args = call.args }, .{}) catch |err| {
                return sendErrorReply(id, req.id, ipc.errorText(err));
            };
            const async_ctx = gpa.create(AsyncReply) catch return sendErrorReply(id, req.id, "OutOfMemory");
            async_ctx.* = .{ .window = id, .req_id = req.id, .arena_state = undefined, .result = null, .err_name = null };
            ipc.dispatchAsync(api.commands, worker_pool, gpa, request_json, worker_pool.io, async_ctx, AsyncReply.onWorkerDone) catch |err| {
                gpa.destroy(async_ctx);
                return sendErrorReply(id, req.id, ipc.errorText(err));
            };
        }

        const AsyncReply = struct {
            window: u32,
            req_id: ?u64,
            arena_state: std.heap.ArenaAllocator,
            result: ?[:0]const u8,
            err_name: ?[:0]const u8,

            /// On the worker: hand the result to the UI thread.
            fn onWorkerDone(self: *@This(), arena_state: std.heap.ArenaAllocator, res: ?[:0]const u8, err_name: ?[:0]const u8) void {
                self.arena_state = arena_state;
                self.result = res;
                self.err_name = err_name;
                ShellMod.dispatchWithCleanup(&reply, self, &drop);
            }

            fn reply(ctx: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                defer drop(self);
                if (self.err_name) |err| {
                    sendErrorReply(self.window, self.req_id, err);
                } else {
                    sendSuccessReply(self.window, self.req_id, self.result orelse "null");
                }
            }

            fn drop(ctx: ?*anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                var a = self.arena_state;
                a.deinit();
                heap.gpa.destroy(self);
            }
        };

        /// A sync command, run from the task queue rather than inside the
        /// WebView callback: a command may then open or close windows
        /// (including its own). Replies keep the order of the requests.
        const SyncCall = struct {
            window: u32,
            req_id: ?u64,
            arena_state: std.heap.ArenaAllocator,
            request: ipc.Request,
            page_url: []const u8,
            win_label: ?[]const u8,
            io: ?std.Io,

            fn queue(window: u32, req_id: ?u64, cmd: []const u8, args: std.json.Value, page_url: []const u8, win_label: ?[]const u8, io: ?std.Io) void {
                const gpa = heap.gpa;
                const self = gpa.create(SyncCall) catch return sendErrorReply(window, req_id, "OutOfMemory");
                self.* = .{
                    .window = window,
                    .req_id = req_id,
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
                const request_json = std.json.Stringify.valueAlloc(arena, ipc.Request{ .cmd = cmd, .args = args }, .{}) catch return self.fail("OutOfMemory");
                self.request = ipc.parseRequest(arena, request_json) catch |err| return self.fail(ipc.errorText(err));
                ShellMod.dispatchWithCleanup(&run, self, &discard);
            }

            fn fail(self: *SyncCall, err_name: []const u8) void {
                sendErrorReply(self.window, self.req_id, err_name);
                self.arena_state.deinit();
                heap.gpa.destroy(self);
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
                    sendErrorReply(self.window, self.req_id, ipc.errorText(err));
                    return;
                };
                sendSuccessReply(self.window, self.req_id, result);
            }

            /// Shutdown: reject the call so the page's Promise settles.
            fn discard(ctx: ?*anyopaque) void {
                const self: *SyncCall = @ptrCast(@alignCast(ctx.?));
                if (ShellMod.isMainThread()) sendErrorReply(self.window, self.req_id, "AppNotRunning");
                finish(self);
            }

            fn finish(self: *SyncCall) void {
                self.arena_state.deinit();
                heap.gpa.destroy(self);
            }
        };
    };
}

test "bridge script: Android transport" {
    try std.testing.expect(std.mem.indexOf(u8, bridge_js, "globalThis.__orielNative") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_js, "native.postMessage(JSON.stringify(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bridge_js, token_placeholder));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bridge_js, isolation_placeholder));
}
