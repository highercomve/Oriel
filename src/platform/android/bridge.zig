//! android.webkit.WebView JS <-> Zig IPC bridge.
//!
//! Transport: an AndroidX `WebMessageListener` (`WebViewCompat.addWebMessageListener`)
//! injects `__orielNative` into the pages whose origin matches the window's
//! rules; the bridge script (added at document start with
//! `addDocumentStartJavaScript`) keeps it in its closure and talks JSON over
//! it: requests carry an `id`, replies and events come back on the same
//! channel (`JavaScriptReplyProxy`), so a command's events arrive before its
//! reply, like the WebView2 bridge (both are core/bridge_js.zig's channelTransport).
//!
//! Every call is checked like on the other platforms: the page's IPC token,
//! the isolation seal, then `commandAllowedForWindow`. Only main frames are
//! served (Kotlin refuses the others before they get here).

const std = @import("std");
const heap = @import("../../core/heap.zig");
const App = @import("../../core/App.zig");
const internal = @import("../../core/internal.zig");
const ipc = @import("../../core/ipc.zig");
const security = @import("../../core/security.zig");
const dispatch = @import("../../core/bridge_dispatch.zig");
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

const bridge = @import("../../core/bridge_js.zig");
const token_placeholder = bridge.token_placeholder;
const isolation_placeholder = bridge.isolation_placeholder;

/// The shared script over the `__orielNative` channel (JSON strings both
/// ways); a document without the channel gets no bridge.
pub const bridge_js = bridge.script(bridge.channelTransport(.{
    .setup = "  const native = globalThis.__orielNative;\n  if (!native) return;\n  native.postMessage(\"" ++ hello ++ "\");\n",
    .port = "native",
    .decode = "    let data;\n    try { data = JSON.parse(event.data); } catch (_) { return; }\n",
}));

/// Post `json` to window `id`'s page (UI thread). `load` is the page load
/// (OrielWindow's counter) a reply is for: Kotlin drops it once another
/// page has started. 0 for events, which go to whichever page is current.
fn post(id: u32, load: u32, json: []const u8) void {
    if (comptime build_opts.native_ui) if (native.engineOf(id)) |e| return e.message(json);
    _ = runtime.call(.void, "postMessage", "(II[B)V", .{ @as(i32, @intCast(id)), @as(i32, @bitCast(load)), json });
}

fn evaluate(id: u32, script: []const u8) void {
    if (comptime build_opts.native_ui) if (native.engineOf(id)) |e| {
        const z = heap.gpa.dupeZ(u8, script) catch return;
        defer heap.gpa.free(z);
        return e.evalScript(z);
    };
    _ = runtime.call(.void, "evalJs", "(I[B)V", .{ @as(i32, @intCast(id)), script });
}

/// Collect window ids matching `target` / `label` under `windows_mutex` into a
/// heap list so callers can invoke JNI outside the lock without a fixed cap.
fn collectTargetIds(gpa: std.mem.Allocator, target: ?window_mod.WindowHandle, label: ?[]const u8) ?std.ArrayList(u32) {
    var ids: std.ArrayList(u32) = .empty;
    internal.ensureWindowsMutex();
    internal.windows_mutex.lock();
    defer internal.windows_mutex.unlock();
    const reserve_count = if (target != null or label != null) @min(@as(usize, 1), internal.windows_list.items.len) else internal.windows_list.items.len;
    ids.ensureUnusedCapacity(gpa, reserve_count) catch {
        log.err("window broadcast failed: out of memory", .{});
        return null;
    };
    for (internal.windows_list.items) |win| {
        if (target) |t| if (!win.handle.eql(t)) continue;
        if (label) |l| if (!std.mem.eql(u8, win.label, l)) continue;
        ids.append(gpa, win.handle.id) catch {
            log.err("window broadcast failed: out of memory", .{});
            break;
        };
    }
    return ids;
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
        var ids = collectTargetIds(heap.gpa, self.target, self.label) orelse return;
        defer ids.deinit(heap.gpa);
        for (ids.items) |id| if (self.as_message) post(id, 0, self.text) else evaluate(id, self.text);
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

fn sendSuccessReply(id: u32, load: u32, req_id: ?u64, result_json: []const u8) void {
    const rid = req_id orelse return;
    const gpa = heap.gpa;
    const reply = std.fmt.allocPrint(gpa, "{{\"__oriel_reply\":true,\"id\":{d},\"result\":{s}}}", .{ rid, result_json }) catch return;
    defer gpa.free(reply);
    post(id, load, reply);
}

fn sendErrorReply(id: u32, load: u32, req_id: ?u64, err_name: []const u8) void {
    const rid = req_id orelse return;
    const gpa = heap.gpa;
    const err_json = std.json.Stringify.valueAlloc(gpa, err_name, .{}) catch return;
    defer gpa.free(err_json);
    const reply = std.fmt.allocPrint(gpa, "{{\"__oriel_reply\":true,\"id\":{d},\"error\":{s}}}", .{ rid, err_json }) catch return;
    defer gpa.free(reply);
    post(id, load, reply);
}

pub fn Bridge(
    comptime api: App.Api,
    comptime config: App.Config,
    comptime local: security.Local,
) type {
    const native_commands = @import("../../core/native_commands.zig");
    return struct {
        const Dispatch = dispatch.Dispatcher(api, config, local, Transport);
        const Transport = struct {
            pub const warn = log.warn;
            window: u32,
            load: u32,
            req_id: ?u64,
            pub fn retain(_: *@This()) !void {}
            pub fn release(_: @This()) void {}
            pub fn alive(_: @This()) bool {
                return true;
            } // Kotlin checks the originating page-load counter.
            pub fn settle(self: @This(), result: ?[:0]const u8, err: ?[:0]const u8) void {
                if (err) |e| sendErrorReply(self.window, self.load, self.req_id, e) else sendSuccessReply(self.window, self.load, self.req_id, result orelse "null");
            }
            pub fn discard(self: @This()) void {
                if (ShellMod.isMainThread()) self.settle(null, "AppNotRunning");
            }
            pub const post = ShellMod.dispatchWithCleanup;
        };

        /// The document-start script for window `label`: the prelude, the
        /// label, and the bridge with this origin's token and the isolation
        /// part filled in. Caller frees.
        pub fn script(gpa: std.mem.Allocator, label: []const u8) ![]u8 {
            const label_json = try std.json.Stringify.valueAlloc(gpa, label, .{});
            defer gpa.free(label_json);
            const token_js = try ipc.tokenScript(gpa, config.security, local);
            defer gpa.free(token_js);
            const with_iso = try std.mem.replaceOwned(u8, gpa, bridge_js, isolation_placeholder, comptime isolation.bridgeScript(config.app.isolation, local));
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
                const surface = native.get(window) orelse return; // the window closed
                const gpa = heap.gpa;
                const arena = self.arena_state.allocator();
                // The window's label and URL, copied (it may close during the command).
                var label: []const u8 = "";
                var url: ?[]const u8 = null;
                {
                    internal.ensureWindowsMutex();
                    internal.windows_mutex.lock();
                    defer internal.windows_mutex.unlock();
                    for (internal.windows_list.items) |w| if (w.handle.id == window) {
                        label = arena.dupe(u8, w.label) catch return;
                        url = if (w.options.url) |u| (arena.dupe(u8, u) catch return) else null;
                        break;
                    };
                }
                if (label.len == 0) return NativeReply.send(window, call_id, false, "WindowNotFound");
                const page_url = security.resolveWindowUrl(arena, config.security, local, null, url, config.start) catch "https://app.localhost/index.html";
                const args = std.json.parseFromSliceLeaky(std.json.Value, arena, self.args_json, .{}) catch .null;
                const request: ipc.Request = .{ .cmd = cmd, .args = args };
                const pool = internal.getWorkerPool();
                defer if (pool != null) internal.releaseWorkerPool();

                const result: anyerror![]const u8 = blk: {
                    if (native_commands.dispatch(api, config, local, surface.engine, arena, page_url, label, request, self.args_json, if (pool) |p| p.io else null)) |answer| break :blk answer;
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
        /// the sending document's origin ("https://app.localhost"); `load`
        /// the window's page load it came from (replies carry it back).
        pub fn onMessage(id: u32, data: []const u8, origin: []const u8, load: u32) void {
            const gpa = heap.gpa;
            // Too large to take: answer by the id at its start.
            if (data.len > ipc.max_request_len) return sendErrorReply(id, load, ipc.requestIdLenient(data), "RequestTooLarge");
            var parse_arena = std.heap.ArenaAllocator.init(gpa);
            defer parse_arena.deinit();
            const temp = parse_arena.allocator();

            const req = std.json.parseFromSliceLeaky(Message, temp, data, .{ .ignore_unknown_fields = true }) catch |err| {
                log.warn("invalid IPC message: {s}", .{@errorName(err)});
                // Still settle the page's invoke(), if its id can be read.
                return sendErrorReply(id, load, ipc.requestIdLenient(data), "InvalidRequest");
            };
            const page_url = std.fmt.allocPrint(temp, "{s}/", .{origin}) catch return sendErrorReply(id, load, req.id, "OutOfMemory");

            const caller_win = window_mod.getWindowById(id);
            const win_label: ?[]const u8 = if (caller_win) |w| w.label else null;
            const transport: Transport = .{ .window = id, .load = load, .req_id = req.id };
            Dispatch.run(transport, gpa, temp, .{ .cmd = req.cmd, .args = req.args, .token = req.token, .iso = req.iso }, data, page_url, win_label, id) catch |err| {
                transport.settle(null, ipc.errorText(err));
            };
        }
    };
}

test "bridge script: Android transport" {
    try std.testing.expect(std.mem.indexOf(u8, bridge_js, "globalThis.__orielNative") != null);
    try std.testing.expect(std.mem.indexOf(u8, bridge_js, "native.postMessage(JSON.stringify(") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bridge_js, token_placeholder));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, bridge_js, isolation_placeholder));
}

test "collectTargetIds: collects beyond 64 windows without dropping" {
    internal.ensureWindowsMutex();
    defer {
        internal.windows_mutex.lock();
        internal.windows_list.deinit(std.testing.allocator);
        internal.windows_list = .empty;
        internal.windows_mutex.unlock();
    }

    const count = 70;
    var win_storage: [count]App.Window = undefined;
    for (&win_storage, 0..) |*win, i| {
        win.* = .{
            .handle = .{ .id = @intCast(i + 1) },
            .label = if (i % 2 == 0) "even" else "odd",
            .options = .{},
            .app_id = "test",
        };
        try internal.windows_list.append(std.testing.allocator, win);
    }

    var all = collectTargetIds(std.testing.allocator, null, null) orelse return error.TestUnexpectedResult;
    defer all.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, count), all.items.len);

    var by_label = collectTargetIds(std.testing.allocator, null, "even") orelse return error.TestUnexpectedResult;
    defer by_label.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, count / 2), by_label.items.len);
}

test "web bridge transport typechecks shared dispatch" {
    const Commands = struct {
        pub fn ping(_: std.mem.Allocator) u32 {
            return 1;
        }
    };
    const B = Bridge(.{ .commands = Commands }, .{ .app = .{ .id = "test" } }, .{});
    _ = &B.onMessage;
}
