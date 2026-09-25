//! Smoke-test app: opens a oriel window whose page calls into Zig to run the
//! check of every enabled module and shows the results.
//!
//!   oriel-smoke              GUI
//!   oriel-smoke --auto-quit  GUI, quits once the page reports (exit 1 on failure)
//!   oriel-smoke --check      headless: run the checks, print them, exit

const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const app = @import("oriel_app");

const media_port: u16 = 17893;
/// A second origin for the `ipc frame` check (the navigation policy admits it).
const probe_port: u16 = 17894;
const probe_origin = std.fmt.comptimePrint("http://127.0.0.1:{d}", .{probe_port});

/// Loaded in an iframe by the page: tries to call IPC straight through the
/// native handler (the frame never gets the bridge script) and reports the
/// outcome to the parent. Refused on every OS thanks to the IPC token.
const probe_html =
    \\<!doctype html><meta charset="utf-8"><script>
    \\(async () => {
    \\  let result;
    \\  try {
    \\    const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.oriel;
    \\    if (h) {
    \\      result = "reached IPC: " + (await h.postMessage(JSON.stringify({ cmd: "sync_ping", args: null })));
    \\    } else if (window.chrome && window.chrome.webview) {
    \\      window.chrome.webview.postMessage(JSON.stringify({ id: 999999, cmd: "sync_ping", args: null }));
    \\      result = "posted";
    \\    } else {
    \\      result = "no handler";
    \\    }
    \\  } catch (e) {
    \\    result = "refused: " + ((e && e.message) || e);
    \\  }
    \\  parent.postMessage({ ipcProbe: result }, "*");
    \\})();
    \\</script>
;

var servers_gpa: std.mem.Allocator = undefined;
var media_running = false;

/// The media server (and `app://app/media/`) and the IPC probe origin.
fn startServers() !void {
    if (oriel.options.media_server) {
        test_media_root = try createTestMediaFile(io, servers_gpa);
        errdefer servers_gpa.free(test_media_root);
        try media.start(io, servers_gpa, oriel.media_server.Options{
            .port = media_port,
            .root_dir = test_media_root,
        });
        media_running = true;
        errdefer stopServers();
        // The same directory at app://app/media/ (no TCP port involved).
        try oriel.media_server.scheme.setRoot(test_media_root, .inside_root);
    }
    if (std.Thread.spawn(.{}, probeServer, .{io})) |t| t.detach() else |err| std.log.warn("ipc probe server: {s}", .{@errorName(err)});
}

fn stopServers() void {
    if (!media_running) return;
    media_running = false;
    oriel.media_server.scheme.clearRoot();
    media.stop();
    servers_gpa.free(test_media_root);
}

fn setupGui() anyerror!void {
    try startServers();
}

/// Serves `probe_html` on 127.0.0.1:probe_port for the app's lifetime.
fn probeServer(local_io: std.Io) void {
    const addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", probe_port) catch return;
    // SO_REUSEADDR on Windows would let another socket share the port.
    var server = addr.listen(local_io, .{ .reuse_address = @import("builtin").os.tag != .windows }) catch |err| {
        std.log.warn("ipc probe server: {s}", .{@errorName(err)});
        return;
    };
    defer server.deinit(local_io);
    while (true) {
        const stream = server.accept(local_io) catch return;
        defer stream.close(local_io);
        var rbuf: [4096]u8 = undefined;
        var r = stream.reader(local_io, &rbuf);
        // Skip the request head: this server has one page.
        while (r.interface.takeDelimiterInclusive('\n')) |line| {
            if (std.mem.eql(u8, line, "\r\n") or std.mem.eql(u8, line, "\n")) break;
        } else |_| continue;
        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(local_io, &wbuf);
        w.interface.print("HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ probe_html.len, probe_html }) catch continue;
        w.interface.flush() catch {};
    }
}
const app_id = "dev.oriel.Smoke";
const icon_png = @embedFile("web/icon.png");

var io: std.Io = undefined;
var media: if (oriel.options.media_server) oriel.media_server.Server else void = undefined;
var test_media_root: []const u8 = "";
var expected_sample_hex: [200]u8 = undefined;
const test_total_file_size: u64 = 44 + 1024 * 1024;

fn createTestMediaFile(local_io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    var tmp_path: []const u8 = ".zig-cache/tmp/smoke-media";
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    std.Io.Dir.cwd().createDirPath(local_io, tmp_path) catch |err| {
        // A macOS .app started by Launch Services runs in "/" (read-only).
        const tmpdir = if (@import("builtin").os.tag == .windows) null else std.c.getenv("TMPDIR");
        const base = if (tmpdir) |t| std.mem.span(t) else return err;
        tmp_path = try std.fmt.bufPrint(&tmp_buf, "{s}/oriel-smoke-media", .{std.mem.trimEnd(u8, base, "/")});
        try std.Io.Dir.cwd().createDirPath(local_io, tmp_path);
    };
    var tmp_dir = try std.Io.Dir.cwd().openDir(local_io, tmp_path, .{});
    defer tmp_dir.close(local_io);

    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_len = try tmp_dir.realPath(local_io, &real_buf);
    const media_root = try gpa.dupe(u8, real_buf[0..real_len]);
    errdefer gpa.free(media_root);

    // 44-byte WAV header + 1048576 bytes of PCM data = 1048620 bytes total
    const pcm_len: u32 = 1024 * 1024;
    const total_file_size: u32 = 44 + pcm_len;
    const file_bytes = try gpa.alloc(u8, total_file_size);
    defer gpa.free(file_bytes);

    @memcpy(file_bytes[0..4], "RIFF");
    std.mem.writeInt(u32, file_bytes[4..8], total_file_size - 8, .little);
    @memcpy(file_bytes[8..12], "WAVE");

    @memcpy(file_bytes[12..16], "fmt ");
    std.mem.writeInt(u32, file_bytes[16..20], 16, .little);
    std.mem.writeInt(u16, file_bytes[20..22], 1, .little);
    std.mem.writeInt(u16, file_bytes[22..24], 1, .little);
    std.mem.writeInt(u32, file_bytes[24..28], 44100, .little);
    std.mem.writeInt(u32, file_bytes[28..32], 88200, .little);
    std.mem.writeInt(u16, file_bytes[32..34], 2, .little);
    std.mem.writeInt(u16, file_bytes[34..36], 16, .little);

    @memcpy(file_bytes[36..40], "data");
    std.mem.writeInt(u32, file_bytes[40..44], pcm_len, .little);

    const num_samples = pcm_len / 2;
    var i: usize = 0;
    while (i < num_samples) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / 44100.0;
        const val: i16 = @intFromFloat(@sin(2.0 * std.math.pi * 440.0 * t) * 16000.0);
        std.mem.writeInt(i16, file_bytes[44 + i * 2 ..][0..2], val, .little);
    }

    const hex = std.fmt.bytesToHex(file_bytes[100..200].*, .lower);
    expected_sample_hex = hex;

    try tmp_dir.writeFile(local_io, .{ .sub_path = "test.wav", .data = file_bytes });

    return media_root;
}

const Commands = struct {
    pub fn greet(gpa: std.mem.Allocator, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(gpa, "Hello, {s}! (from Zig {s})", .{ args.name, @import("builtin").zig_version_string });
    }

    pub fn status(gpa: std.mem.Allocator) !struct {
        checks: []oriel.Check,
        ping_url: ?[]const u8,
        probe_url: []const u8,
        media_url: ?[]const u8,
        media_app_url: ?[]const u8,
        expected_sample_hex: ?[]const u8,
        total_file_size: u64,
    } {
        return .{
            .checks = try oriel.checkAll(gpa, context()),
            .probe_url = probe_origin ++ "/probe.html",
            .ping_url = if (oriel.options.media_server)
                try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/ping", .{media_port})
            else
                null,
            .media_url = if (oriel.options.media_server)
                try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/test.wav", .{media_port})
            else
                null,
            .media_app_url = if (oriel.options.media_server)
                oriel.security.app_origin ++ "/media/test.wav"
            else
                null,
            .expected_sample_hex = if (oriel.options.media_server)
                &expected_sample_hex
            else
                null,
            .total_file_size = test_total_file_size,
        };
    }

    // test_second_instance waits for a second launch that the main thread must
    // be free to answer.
    pub const async_commands = .{ "async_sleep", "clipboard_roundtrip", "main_thread_hop", "test_second_instance" };

    /// Runs on a worker; hands work to the UI thread with App.runOnMain,
    /// which touches a window and emits "main_hop" to the page.
    pub fn main_thread_hop(_: std.mem.Allocator, args: struct { n: u32 }) void {
        oriel.App.runOnMain(args.n, struct {
            fn onMain(n: u32) void {
                const has_main = oriel.App.getWindow("main") != null;
                oriel.App.emit("main_hop", .{ .n = n, .main_window = has_main });
            }
        }.onMain);
    }

    /// Write then read back the clipboard in-process, from a worker thread
    /// (the path async commands and hotkey handlers use). Must not hang:
    /// this process owns the selection it reads.
    pub fn clipboard_roundtrip(gpa: std.mem.Allocator) !struct { ok: bool, detail: []const u8 } {
        if (!oriel.options.clipboard) return .{ .ok = true, .detail = "clipboard plugin disabled" };
        const pid = if (builtin.os.tag == .windows)
            std.os.windows.GetCurrentProcessId()
        else
            std.c.getpid();
        const text = try std.fmt.allocPrint(gpa, "oriel smoke clipboard {d}", .{pid});
        try oriel.clipboard.writeText(text);
        const back = try oriel.clipboard.readText(gpa);
        return .{
            .ok = std.mem.eql(u8, back, text),
            .detail = try std.fmt.allocPrint(gpa, "wrote \"{s}\", read back \"{s}\" from a worker thread", .{ text, back }),
        };
    }

    pub fn async_sleep(_: std.mem.Allocator, local_io: std.Io, args: struct { ms: u32 }) ![]const u8 {
        const timeout: std.Io.Timeout = .{
            .duration = .{
                .raw = .{ .nanoseconds = @as(i96, args.ms) * std.time.ns_per_ms },
                .clock = .awake,
            },
        };
        try timeout.sleep(local_io);
        return "slept";
    }

    pub fn sync_ping(_: std.mem.Allocator) []const u8 {
        return "pong";
    }

    /// Round-trip for the events check: Zig -> JS `ping` event.
    pub fn emit_ping(_: std.mem.Allocator, args: struct { n: i64 }) void {
        oriel.App.emit("ping", .{ .n = args.n });
    }

    pub fn test_windows_and_menu(gpa: std.mem.Allocator) !struct { ok: bool, detail: []const u8 } {
        if (oriel.options.menu) {
            const menu_items = [_]oriel.menu.MenuItem{
                .{
                    .submenu = .{
                        .label = "File",
                        .items = &.{
                            .{ .item = .{ .id = "new", .label = "New", .shortcut = "<Control>n" } },
                            .{ .separator = {} },
                            .{ .item = .{ .id = "quit", .label = "Quit", .shortcut = "<Control>q" } },
                        },
                    },
                },
            };
            const Handler = struct {
                fn onAction(_: []const u8, _: ?bool) void {}
            };
            try oriel.App.setMenu(&menu_items, Handler.onAction);
        }

        const win = try oriel.App.openWindow(.{
            .label = "test-sec",
            .title = "Test Secondary Window",
            .width = 400,
            .height = 300,
            .resizable = false,
        });

        const found = oriel.App.getWindow("test-sec");
        if (found == null or found.? != win) {
            return .{ .ok = false, .detail = "failed to get window by label" };
        }

        win.setTitle("Updated Title");
        const geom = win.getSize();
        if (geom.width != 400 or geom.height != 300) {
            return .{ .ok = false, .detail = "window size mismatch" };
        }

        win.emit("test_event", .{ .ok = true });

        oriel.App.closeWindow("test-sec");
        if (oriel.App.getWindow("test-sec") != null) {
            return .{ .ok = false, .detail = "window still exists after close" };
        }

        return .{
            .ok = true,
            .detail = try std.fmt.allocPrint(gpa, "menu bar set, secondary window opened, verified, and closed", .{}),
        };
    }

    /// Rejects with a message for the page (oriel.ipc.fail).
    pub fn fail_with_message(_: std.mem.Allocator, args: struct { what: []const u8 }) !void {
        return oriel.ipc.fail("could not {s}", .{args.what});
    }

    /// Overlay window (Milestone 10): created hidden with overlay options,
    /// then shown, placed, made click-through, and hidden on close.
    pub fn test_overlay_window(gpa: std.mem.Allocator) !struct { ok: bool, detail: []const u8 } {
        const win = try oriel.App.openWindow(.{
            .label = "test-overlay",
            .title = "Overlay",
            // It stays open (hide_on_close): an idle page, not another run of
            // the whole smoke suite.
            .url = "index.html?overlay=1",
            .width = 300,
            .height = 120,
            .decorations = false,
            .visible = false,
            .transparent = true,
            .always_on_top = true,
            .skip_taskbar = true,
            .placement = .{ .anchor = .bottom, .margin = 40 },
            .hide_on_close = true,
            .focus_on_show = false,
        });
        win.show();
        const area = win.workArea();
        win.place(.{ .anchor = .top_right, .margin = 10 });
        win.center();
        win.setClickThrough(true);
        win.setClickThrough(false);
        win.setAlwaysOnTop(false);
        win.setAlwaysOnTop(true);
        oriel.App.closeWindow("test-overlay");
        if (oriel.App.getWindow("test-overlay") == null) return .{ .ok = false, .detail = "hide_on_close window was destroyed" };
        win.hide();
        return .{
            .ok = true,
            .detail = if (area) |a|
                try std.fmt.allocPrint(gpa, "hidden → shown → placed → click-through; work area {d}x{d}; hidden on close", .{ a.width, a.height })
            else
                try std.fmt.allocPrint(gpa, "hidden → shown → placed → click-through (no work area here); hidden on close", .{}),
        };
    }

    /// Single instance (Milestone 10): launch this app again with arguments;
    /// it must hand them to this instance's on_second_instance and exit.
    pub fn test_second_instance(gpa: std.mem.Allocator, local_io: std.Io) !struct { ok: bool, detail: []const u8 } {
        if (builtin.os.tag == .macos) return .{ .ok = true, .detail = "skipped: second-instance forwarding not implemented on macOS yet" };
        second_instance_len.store(0, .release);
        const exe = try std.process.executablePathAlloc(local_io, gpa);
        var child = try std.process.spawn(local_io, .{
            .argv = &.{ exe, "--probe=hello world", "--probe=ünï" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        const term = try child.wait(local_io);
        const got = second_instance_buf[0..second_instance_len.load(.acquire)];
        const want = "[\"--probe=hello world\",\"--probe=ünï\"]";
        const exited = term == .exited and term.exited == 0;
        return .{
            .ok = exited and std.mem.eql(u8, got, want),
            .detail = try std.fmt.allocPrint(gpa, "second launch {s}; on_second_instance got {s}", .{ if (exited) "exited 0" else "did not exit cleanly", if (got.len == 0) "nothing" else got }),
        };
    }

    /// Called by the page in --auto-quit mode once everything has rendered.
    pub fn done(_: std.mem.Allocator, args: struct { failed: u32, report: []const u8 }) void {
        std.debug.print("{s}\n", .{args.report});
        oriel.App.quit(if (args.failed == 0) 0 else 1);
    }
};

fn context() oriel.CheckContext {
    return .{
        .io = io,
        .icon_png = icon_png,
        .media_port = if (oriel.options.media_server) media_port else null,
        .app_id = app_id,
    };
}

fn testOpenExternalHook(_: [*:0]const u8) void {}

/// The arguments of the last forwarded launch, as JSON (on_second_instance).
var second_instance_buf: [1024]u8 = undefined;
var second_instance_len = std.atomic.Value(usize).init(0);

/// Milestone 10: a later launch of the smoke app forwards its arguments here
/// (kept for the `second instance` check, logged, and sent to the page).
fn onSecondInstance(args: []const []const u8) void {
    std.log.info("second instance: {d} argument(s): {f}", .{ args.len, std.json.fmt(args, .{}) });
    oriel.App.emit("second-instance", .{ .args = args });
    var w: std.Io.Writer = .fixed(&second_instance_buf);
    std.json.Stringify.value(args, .{}, &w) catch return;
    second_instance_len.store(w.end, .release);
}

pub fn main(init: std.process.Init) !u8 {
    oriel.App.open_external_hook = &testOpenExternalHook;
    io = init.io;
    var headless = false;
    var auto_quit = false;
    var probe = false;
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--auto-quit")) {
            auto_quit = true;
        } else if (std.mem.startsWith(u8, arg, "--probe=")) {
            // A second launch from the "second instance" check: it only
            // forwards its arguments to the running smoke app.
            probe = true;
        } else if (std.mem.indexOf(u8, arg, "://") != null) {
            // A deep link (smoke-scheme://...): the platform shell reads it
            // from argv; `deep_link js` then reports it as current().
        } else {
            std.debug.print("usage: oriel-smoke [--check | --auto-quit] [smoke-scheme://...]\n", .{});
            return 2;
        }
    }

    // App.run (unlike oriel.main) doesn't see argv: hand it over, so a second
    // launch forwards its arguments and deep links reach the shell.
    oriel.App.setProcessArgs(try init.minimal.args.toSlice(init.arena.allocator()));

    servers_gpa = init.gpa;
    defer stopServers();

    if (headless) {
        try startServers();
        var arena_state = std.heap.ArenaAllocator.init(init.gpa);
        defer arena_state.deinit();
        const checks = try oriel.checkAll(arena_state.allocator(), context());
        var failed: usize = 0;
        for (checks) |c| {
            if (!c.ok) failed += 1;
            std.debug.print("[{s}] {s:<16} {s}\n", .{ if (c.ok) "ok" else "FAIL", c.module, c.detail });
        }
        return if (failed == 0) 0 else 1;
    }

    if (oriel.options.deep_link) {
        const DLHandler = struct {
            fn handle(_: []const u8) void {}
        };
        oriel.deep_link.onOpen(DLHandler.handle);
    }

    const config_gui: oriel.App.Config = .{
        .id = app_id,
        .title = "Oriel smoke test",
        .icon = app.icon_bytes,
        .assets = app.assets,
        // The security checks navigate to remote URLs: never hand them to a browser.
        // The probe origin may be framed (the `ipc frame` check).
        .security = .{
            .external_links = .deny,
            .allowed_origins = &.{probe_origin},
            .csp = oriel.security.default_csp ++ "; frame-src " ++ probe_origin,
        },
        .deep_link_schemes = app.url_schemes,
        .permissions = app.permissions,
        // Servers start after App.run's single-instance check: a second
        // launch forwards its arguments and exits before binding any port.
        .setup = &setupGui,
        // Single instance: a later launch's arguments land here (the
        // Milestone 10 proof: run the app, then launch it again).
        .on_second_instance = &onSecondInstance,
    };
    comptime var config_auto = config_gui;
    config_auto.start = "index.html?auto-quit";
    const api: oriel.App.Api = .{ .commands = Commands };
    return if (auto_quit) oriel.App.run(init.io, api, config_auto) else oriel.App.run(init.io, api, config_gui);
}
