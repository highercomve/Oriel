//! Smoke-test app: opens a oriel window whose page calls into Zig to run the
//! check of every enabled module and shows the results.
//!
//!   oriel-smoke              GUI
//!   oriel-smoke --auto-quit  GUI, quits once the page reports (exit 1 on failure)
//!   oriel-smoke --check      headless: run the checks, print them, exit

const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

const media_port: u16 = 17893;
const app_id = "dev.oriel.Smoke";
const icon_png = @embedFile("web/icon.png");

var io: std.Io = undefined;
var media: if (oriel.options.media_server) oriel.media_server.Server else void = undefined;

const Commands = struct {
    pub fn greet(gpa: std.mem.Allocator, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(gpa, "Hello, {s}! (from Zig {s})", .{ args.name, @import("builtin").zig_version_string });
    }

    pub fn status(gpa: std.mem.Allocator) !struct { checks: []oriel.Check, media_url: ?[]const u8 } {
        return .{
            .checks = try oriel.checkAll(gpa, context()),
            .media_url = if (oriel.options.media_server)
                try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/ping", .{media_port})
            else
                null,
        };
    }

    pub const async_commands = .{ "async_sleep", "clipboard_roundtrip" };

    /// Write then read back the clipboard in-process, from a worker thread
    /// (the path async commands and hotkey handlers use). Must not hang:
    /// this process owns the selection it reads.
    pub fn clipboard_roundtrip(gpa: std.mem.Allocator) !struct { ok: bool, detail: []const u8 } {
        if (!oriel.options.clipboard) return .{ .ok = true, .detail = "clipboard plugin disabled" };
        const text = try std.fmt.allocPrint(gpa, "oriel smoke clipboard {d}", .{std.c.getpid()});
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

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    var headless = false;
    var auto_quit = false;
    for (init.minimal.args.vector[1..]) |arg_z| {
        const arg = std.mem.span(arg_z);
        if (std.mem.eql(u8, arg, "--check")) {
            headless = true;
        } else if (std.mem.eql(u8, arg, "--auto-quit")) {
            auto_quit = true;
        } else {
            std.debug.print("usage: oriel-smoke [--check | --auto-quit]\n", .{});
            return 2;
        }
    }

    if (oriel.options.media_server) try media.start(io, init.gpa, media_port);
    defer if (oriel.options.media_server) media.stop();

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

    const config_gui: oriel.App.Config = .{
        .id = app_id,
        .title = "Oriel smoke test",
        .assets = app.assets,
        // The security checks navigate to remote URLs: never hand them to a browser.
        .security = .{ .external_links = .deny },
    };
    comptime var config_auto = config_gui;
    config_auto.start = "index.html?auto-quit";
    const api: oriel.App.Api = .{ .commands = Commands };
    return if (auto_quit) oriel.App.run(init.io, api, config_auto) else oriel.App.run(init.io, api, config_gui);
}
