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
const app_id = "dev.oriel.Smoke";
const icon_png = @embedFile("web/icon.png");

var io: std.Io = undefined;
var media: if (oriel.options.media_server) oriel.media_server.Server else void = undefined;
var test_media_root: []const u8 = "";
var expected_sample_hex: [200]u8 = undefined;
const test_total_file_size: u64 = 44 + 1024 * 1024;

fn createTestMediaFile(local_io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    const tmp_path = ".zig-cache/tmp/smoke-media";
    try std.Io.Dir.cwd().createDirPath(local_io, tmp_path);
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
        media_url: ?[]const u8,
        media_app_url: ?[]const u8,
        expected_sample_hex: ?[]const u8,
        total_file_size: u64,
    } {
        return .{
            .checks = try oriel.checkAll(gpa, context()),
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

    pub const async_commands = .{ "async_sleep", "clipboard_roundtrip" };

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

pub fn main(init: std.process.Init) !u8 {
    oriel.App.open_external_hook = &testOpenExternalHook;
    io = init.io;
    var headless = false;
    var auto_quit = false;
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--auto-quit")) {
            auto_quit = true;
        } else {
            std.debug.print("usage: oriel-smoke [--check | --auto-quit]\n", .{});
            return 2;
        }
    }

    if (oriel.options.media_server) {
        test_media_root = try createTestMediaFile(io, init.gpa);
        errdefer init.gpa.free(test_media_root);
        try media.start(io, init.gpa, oriel.media_server.Options{
            .port = media_port,
            .root_dir = test_media_root,
        });
        errdefer media.stop();
        // The same directory at app://app/media/ (no TCP port involved).
        try oriel.media_server.scheme.setRoot(test_media_root, .inside_root);
    }
    defer if (oriel.options.media_server) {
        oriel.media_server.scheme.clearRoot();
        media.stop();
        init.gpa.free(test_media_root);
    };

    if (headless) {
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
        .assets = app.assets,
        // The security checks navigate to remote URLs: never hand them to a browser.
        .security = .{ .external_links = .deny },
        .deep_link_schemes = app.url_schemes,
    };
    comptime var config_auto = config_gui;
    config_auto.start = "index.html?auto-quit";
    const api: oriel.App.Api = .{ .commands = Commands };
    return if (auto_quit) oriel.App.run(init.io, api, config_auto) else oriel.App.run(init.io, api, config_gui);
}
