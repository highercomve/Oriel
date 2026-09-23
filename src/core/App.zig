//! Linux shell: a GTK4 application window hosting a WebKitGTK 6.0 webview.
//!
//! - Frontend assets are embedded in the binary and served from `app://app/`
//!   with a Content-Security-Policy header.
//! - `window.ziguri.invoke(cmd, args)` in JS returns a Promise resolved by
//!   `ipc.dispatch` on the Zig side; `window.ziguri.listen(event, cb)`
//!   receives events sent with `emit`.
//! - Navigation, IPC and bridge injection follow `security.Security`.

const std = @import("std");
const glib = @import("glib");
const gobject = @import("gobject");
const gio = @import("gio");
const gtk = @import("gtk");
const webkit = @import("webkit");
const jsc = @import("jsc");
const soup = @import("soup");
const ipc = @import("ipc.zig");
const security = @import("security.zig");

const log = std.log.scoped(.ziguri);

pub const Asset = struct {
    path: []const u8,
    data: []const u8,
    mime: [:0]const u8,
};

/// The app's typed API: `commands` are callable from JS, `events` can be
/// emitted from Zig. Both are plain structs; TypeScript bindings are
/// generated from them.
pub const Api = struct {
    commands: type,
    events: type = struct {},
};

pub const Config = struct {
    id: [:0]const u8,
    title: [:0]const u8,
    width: c_int = 960,
    height: c_int = 720,
    assets: []const Asset,
    /// Path + query loaded at startup, relative to `app://app/`.
    start: [:0]const u8 = "index.html",
    /// Unknown extension-less paths serve `index.html` (client-side routing).
    spa_fallback: bool = true,
    devtools: bool = @import("builtin").mode == .Debug,
    security: security.Security = .{},
    /// Closing the window quits the app, or only hides it (e.g. when a tray
    /// icon can bring it back).
    on_close: enum { quit, hide } = .quit,
    /// Called once the window exists, on the main thread: create the tray,
    /// register shortcuts, start background work.
    setup: ?*const fn () anyerror!void = null,
    /// Development mode: load the frontend from a dev server (e.g. Vite with
    /// hot reload) instead of the embedded assets.
    dev: ?Dev = null,
};

pub const Dev = struct {
    url: []const u8,
    /// Dev server command, started with the app and stopped when it exits.
    /// Null when the dev server is managed externally.
    command: ?[]const []const u8 = null,
    cwd: ?[]const u8 = null,
    /// How long to keep retrying while the dev server starts up.
    timeout_ms: u32 = 30_000,
};

const scheme = "app";
const handler_name = "ziguri";

/// Injected into allowed pages before their own scripts run.
const bridge_js =
    \\(() => {
    \\  const listeners = new Map();
    \\  const handler = window.webkit.messageHandlers.
++ handler_name ++
    \\;
    \\  Object.defineProperty(window, "ziguri", { value: Object.freeze({
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

var gtk_app: ?*gtk.Application = null;
var main_window: ?*gtk.Window = null;
var main_view: ?*webkit.WebView = null;
var exit_code: u8 = 0;
var dev_retries_left: u32 = 0;

/// Quit the running application with `code` as the process exit status.
pub fn quit(code: u8) void {
    exit_code = code;
    if (gtk_app) |app| gio.Application.quit(app.as(gio.Application));
}

pub fn showWindow() void {
    if (main_window) |w| w.present();
}

pub fn hideWindow() void {
    if (main_window) |w| w.as(gtk.Widget).setVisible(0);
}

/// Show the window, or hide it if it is already visible and focused.
pub fn toggleWindow() void {
    const w = main_window orelse return;
    if (w.as(gtk.Widget).getVisible() != 0 and w.isActive() != 0) hideWindow() else showWindow();
}

/// Send `payload` (any JSON-serializable value) to `ziguri.listen(name, …)`
/// listeners in the page. Safe to call from any thread.
pub fn emit(name: []const u8, payload: anytype) void {
    emitJson(name, payload) catch |err| log.err("emit {s}: {s}", .{ name, @errorName(err) });
}

/// Typed events: `App.events(Events).emit(.note_added, note)` only compiles
/// if `Events` has a `note_added` field of that payload type.
pub fn events(comptime Events: type) type {
    return struct {
        pub fn emit(comptime name: std.meta.FieldEnum(Events), payload: @FieldType(Events, @tagName(name))) void {
            emitJson(@tagName(name), payload) catch |err| log.err("emit {s}: {s}", .{ @tagName(name), @errorName(err) });
        }
    };
}

fn emitJson(name: []const u8, payload: anytype) !void {
    const gpa = std.heap.smp_allocator;
    const payload_json = try std.json.Stringify.valueAlloc(gpa, payload, .{});
    defer gpa.free(payload_json);
    const name_json = try std.json.Stringify.valueAlloc(gpa, name, .{});
    defer gpa.free(name_json);
    const script = try std.fmt.allocPrintSentinel(gpa, "window.ziguri?.__emit({s}, {s});", .{ name_json, payload_json }, 0);
    // Evaluate on the main thread; the idle callback frees `script`.
    _ = glib.idleAdd(&evalScript, script.ptr);
}

fn evalScript(data: ?*anyopaque) callconv(.c) c_int {
    const script: [*:0]u8 = @ptrCast(data);
    defer std.heap.smp_allocator.free(std.mem.span(script));
    if (main_view) |view| view.evaluateJavascript(script, -1, null, null, null, null, null);
    return 0; // one-shot
}

// The generated binding marks the result non-null, but it is NULL before
// the first load.
extern fn webkit_web_view_get_uri(view: *webkit.WebView) ?[*:0]const u8;

/// Open `uri` with the user's default handler (browser, mail client, …).
pub fn openExternal(uri: [*:0]const u8) void {
    var err: ?*glib.Error = null;
    if (gio.AppInfo.launchDefaultForUri(uri, null, &err) == 0) {
        if (err) |e| {
            log.err("could not open {s}: {s}", .{ uri, e.f_message orelse "unknown error" });
            e.free();
        }
    }
}

/// Run the application until it quits. Returns the exit code.
pub fn run(comptime api: Api, comptime config: Config) u8 {
    const S = Shell(api, config);
    // GTK apps are single-instance per ID: a dev build gets its own ID so it
    // can run next to the installed production app instead of handing off to it.
    const id = if (config.dev != null) config.id ++ ".Dev" else config.id;
    const app = gtk.Application.new(id, .{});
    defer app.unref();
    gtk_app = app;
    defer gtk_app = null;

    const dev_server = if (config.dev) |dev| startDevServer(dev) else null;
    defer if (dev_server) |p| stopDevServer(p);

    // SIGTERM/SIGINT quit through the main loop, so cleanup (dev server,
    // tray, `defer`s in main) still runs.
    _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.TERM), &onQuitSignal, null);
    _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.INT), &onQuitSignal, null);

    _ = gio.Application.signals.activate.connect(app, ?*anyopaque, &S.activate, null, .{});
    const status = gio.Application.run(app.as(gio.Application), 0, null);
    main_view = null;
    main_window = null;
    return if (status != 0) @intCast(status) else exit_code;
}

// From glib-unix.h (no GIR bindings).
extern fn g_unix_signal_add(signum: c_int, handler: *const fn (?*anyopaque) callconv(.c) c_int, user_data: ?*anyopaque) c_uint;

fn onQuitSignal(_: ?*anyopaque) callconv(.c) c_int {
    quit(0);
    return 0; // remove the source; a second signal gets the default action
}

fn startDevServer(comptime dev: Dev) ?*gio.Subprocess {
    const command = dev.command orelse return null;
    const argv = comptime blk: {
        var a: [command.len:null]?[*:0]const u8 = undefined;
        for (command, 0..) |arg, i| a[i] = (arg ++ "\x00")[0..arg.len :0];
        break :blk a;
    };
    const launcher = gio.SubprocessLauncher.new(.{});
    defer launcher.unref();
    if (dev.cwd) |cwd| launcher.setCwd((cwd ++ "\x00")[0..cwd.len :0]);
    // If the app dies without cleaning up (crash, SIGKILL), take the dev
    // server down with it instead of leaving it holding the port.
    launcher.setChildSetup(&dieWithParent, null, null);
    var err: ?*glib.Error = null;
    const process = launcher.spawnv(@ptrCast(&argv), &err) orelse {
        if (err) |e| {
            log.err("failed to start dev server: {s}", .{e.f_message orelse "unknown error"});
            e.free();
        }
        return null;
    };
    log.info("dev server started: {s}", .{command[0]});
    return process;
}

fn dieWithParent(_: ?*anyopaque) callconv(.c) void {
    _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @intFromEnum(std.posix.SIG.TERM), 0, 0, 0);
}

fn stopDevServer(process: *gio.Subprocess) void {
    process.sendSignal(@intFromEnum(std.posix.SIG.TERM));
    _ = process.wait(null, null);
    process.unref();
}

fn Shell(comptime api: Api, comptime config: Config) type {
    const dev_url: ?[]const u8 = if (config.dev) |d| d.url else null;
    const local: security.Local = comptime .{ .dev_origin = if (dev_url) |u| blk: {
        var buf: [512]u8 = undefined;
        const o = security.origin(&buf, u) orelse @compileError("invalid dev URL: " ++ u);
        const copy = o[0..o.len].*;
        break :blk &copy;
    } else null };
    const bridge_patterns = comptime blk: {
        const list = security.bridgePatterns(config.security, dev_url);
        var a: [list.len:null]?[*:0]const u8 = undefined;
        for (list, 0..) |p, i| a[i] = p.ptr;
        break :blk a;
    };
    const csp_z: ?[:0]const u8 = if (config.security.csp) |c| (c ++ "\x00")[0..c.len :0] else null;

    return struct {
        fn activate(app: *gtk.Application, _: ?*anyopaque) callconv(.c) void {
            if (main_window) |w| {
                // Second launch of a single-instance app: bring the window back.
                w.present();
                return;
            }
            const window = gtk.ApplicationWindow.new(app).as(gtk.Window);
            window.setTitle(config.title);
            window.setDefaultSize(config.width, config.height);
            if (config.on_close == .hide) {
                _ = gtk.Window.signals.close_request.connect(window, ?*anyopaque, &onCloseRequest, null, .{});
                // A hidden window doesn't keep the application alive on its own.
                gio.Application.hold(app.as(gio.Application));
            }

            const view = webkit.WebView.new();
            const context = view.getContext();
            context.registerUriScheme(scheme, &serveAsset, null, null);
            context.getSecurityManager().registerUriSchemeAsSecure(scheme);

            const settings = view.getSettings();
            settings.setEnableDeveloperExtras(@intFromBool(config.devtools));
            settings.setJavascriptCanOpenWindowsAutomatically(0);
            settings.setAllowFileAccessFromFileUrls(0);
            settings.setAllowUniversalAccessFromFileUrls(0);

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
            _ = webkit.WebView.signals.decide_policy.connect(view, ?*anyopaque, &onDecidePolicy, null, .{});

            window.setChild(view.as(gtk.Widget));
            main_window = window;
            main_view = view;

            if (config.dev) |dev| {
                // The dev server may still be starting: retry failed loads.
                dev_retries_left = dev.timeout_ms / retry_interval_ms;
                _ = webkit.WebView.signals.load_failed.connect(view, ?*anyopaque, &onLoadFailed, null, .{});
                view.loadUri(devUrl());
            } else {
                view.loadUri(scheme ++ "://app/" ++ config.start);
            }
            window.present();

            if (config.setup) |setup| setup() catch |err| log.err("setup failed: {s}", .{@errorName(err)});
        }

        fn onCloseRequest(window: *gtk.Window, _: ?*anyopaque) callconv(.c) c_int {
            window.as(gtk.Widget).setVisible(0);
            return 1; // handled: keep the window, only hide it
        }

        // --- Navigation policy -------------------------------------------

        fn onDecidePolicy(
            _: *webkit.WebView,
            decision: *webkit.PolicyDecision,
            decision_type: webkit.PolicyDecisionType,
            _: ?*anyopaque,
        ) callconv(.c) c_int {
            switch (decision_type) {
                .navigation_action, .new_window_action => {},
                else => return 0, // default handling for responses
            }
            const nav_decision: *webkit.NavigationPolicyDecision = @ptrCast(decision);
            const action = nav_decision.getNavigationAction();
            const uri = action.getRequest().getUri();
            const verdict = security.navigation(config.security, local, std.mem.span(uri), action.isUserGesture() != 0);
            switch (verdict) {
                .allow => if (decision_type == .new_window_action) {
                    // No popups: open allowed targets in the main view.
                    decision.ignore();
                    if (main_view) |v| v.loadUri(uri);
                } else decision.use(),
                .open_external => {
                    decision.ignore();
                    openExternal(uri);
                },
                .block => {
                    decision.ignore();
                    log.warn("blocked navigation to {s}", .{uri});
                },
            }
            return 1;
        }

        // --- Dev server --------------------------------------------------

        const retry_interval_ms = 250;

        fn devUrl() [:0]const u8 {
            const url = config.dev.?.url;
            return (url ++ "\x00")[0..url.len :0];
        }

        fn onLoadFailed(view: *webkit.WebView, _: webkit.LoadEvent, _: [*:0]u8, _: *glib.Error, _: ?*anyopaque) callconv(.c) c_int {
            if (dev_retries_left == 0) return 0; // show WebKit's error page
            dev_retries_left -= 1;
            _ = glib.timeoutAdd(retry_interval_ms, &retryLoad, view);
            return 1;
        }

        fn retryLoad(data: ?*anyopaque) callconv(.c) c_int {
            const view: *webkit.WebView = @ptrCast(@alignCast(data));
            view.loadUri(devUrl());
            return 0; // one-shot
        }

        // --- app:// assets -----------------------------------------------

        fn serveAsset(request: *webkit.URISchemeRequest, _: ?*anyopaque) callconv(.c) void {
            const path = std.mem.span(request.getPath());
            const rel = std.mem.trimStart(u8, path, "/");
            const wanted = if (rel.len == 0) "index.html" else rel;
            const is_route = std.mem.indexOfScalar(u8, std.fs.path.basename(wanted), '.') == null;
            const asset = findAsset(wanted) orelse if (config.spa_fallback and is_route) findAsset("index.html") else null;
            if (asset) |a| {
                const stream = gio.MemoryInputStream.newFromData(@constCast(a.data.ptr), @intCast(a.data.len), null);
                defer stream.unref();
                const response = webkit.URISchemeResponse.new(stream.as(gio.InputStream), @intCast(a.data.len));
                defer response.unref();
                response.setContentType(a.mime);
                // set_http_headers takes ownership of `headers`.
                const headers = soup.MessageHeaders.new(.response);
                headers.append("Content-Type", a.mime);
                headers.append("X-Content-Type-Options", "nosniff");
                if (csp_z) |csp| headers.append("Content-Security-Policy", csp);
                response.setHttpHeaders(headers);
                request.finishWithResponse(response);
                return;
            }
            const err = glib.Error.newLiteral(glib.quarkFromStaticString("ziguri-asset"), 404, "asset not found");
            defer err.free();
            request.finishError(err);
        }

        fn findAsset(path: []const u8) ?Asset {
            for (config.assets) |asset| {
                if (std.mem.eql(u8, asset.path, path)) return asset;
            }
            return null;
        }

        // --- IPC ---------------------------------------------------------

        fn onMessage(
            _: *webkit.UserContentManager,
            value: *jsc.Value,
            reply: *webkit.ScriptMessageReply,
            view: *webkit.WebView,
        ) callconv(.c) c_int {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const request_ptr = value.toString();
            defer glib.free(request_ptr);
            const request = ipc.parseRequest(arena, std.mem.span(request_ptr)) catch |err| {
                reply.returnErrorMessage(@errorName(err));
                return 1;
            };

            // The page currently shown decides the IPC scope.
            const page_url: []const u8 = if (webkit_web_view_get_uri(view)) |u| std.mem.span(u) else "";
            if (!security.commandAllowed(config.security, local, page_url, request.cmd)) {
                log.warn("blocked command '{s}' from {s}", .{ request.cmd, page_url });
                reply.returnErrorMessage("Forbidden");
                return 1;
            }

            const result = ipc.dispatchRequest(api.commands, arena, request) catch |err| {
                reply.returnErrorMessage(@errorName(err));
                return 1;
            };
            const result_z = arena.dupeZ(u8, result) catch {
                reply.returnErrorMessage("OutOfMemory");
                return 1;
            };
            const js_value = jsc.Value.newFromJson(value.getContext(), result_z);
            defer js_value.unref();
            reply.returnValue(js_value);
            return 1;
        }
    };
}
