//! Smoke-test app: opens a ziguri window whose page calls into Zig to run the
//! check of every enabled module and shows the results.
//!
//!   ziguri-smoke              GUI
//!   ziguri-smoke --auto-quit  GUI, quits once the page reports (exit 1 on failure)
//!   ziguri-smoke --check      headless: run the checks, print them, exit

const std = @import("std");
const ziguri = @import("ziguri");
const app = @import("ziguri_app");

const media_port: u16 = 17893;
const icon_png = @embedFile("web/icon.png");

var io: std.Io = undefined;
var media: if (ziguri.options.media_server) ziguri.media_server.Server else void = undefined;

const Commands = struct {
    pub fn greet(gpa: std.mem.Allocator, args: struct { name: []const u8 }) ![]const u8 {
        return std.fmt.allocPrint(gpa, "Hello, {s}! (from Zig {s})", .{ args.name, @import("builtin").zig_version_string });
    }

    pub fn status(gpa: std.mem.Allocator) !struct { checks: []ziguri.Check, media_url: ?[]const u8 } {
        return .{
            .checks = try ziguri.checkAll(gpa, context()),
            .media_url = if (ziguri.options.media_server)
                try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/ping", .{media_port})
            else
                null,
        };
    }

    /// Round-trip for the events check: Zig -> JS `ping` event.
    pub fn emit_ping(_: std.mem.Allocator, args: struct { n: i64 }) void {
        ziguri.App.emit("ping", .{ .n = args.n });
    }

    /// Called by the page in --auto-quit mode once everything has rendered.
    pub fn done(_: std.mem.Allocator, args: struct { failed: u32, report: []const u8 }) void {
        std.debug.print("{s}\n", .{args.report});
        ziguri.App.quit(if (args.failed == 0) 0 else 1);
    }
};

fn context() ziguri.CheckContext {
    return .{
        .io = io,
        .icon_png = icon_png,
        .media_port = if (ziguri.options.media_server) media_port else null,
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
            std.debug.print("usage: ziguri-smoke [--check | --auto-quit]\n", .{});
            return 2;
        }
    }

    if (ziguri.options.media_server) try media.start(io, init.gpa, media_port);
    defer if (ziguri.options.media_server) media.stop();

    if (headless) {
        var arena_state = std.heap.ArenaAllocator.init(init.gpa);
        defer arena_state.deinit();
        const checks = try ziguri.checkAll(arena_state.allocator(), context());
        var failed: usize = 0;
        for (checks) |c| {
            if (!c.ok) failed += 1;
            std.debug.print("[{s}] {s:<16} {s}\n", .{ if (c.ok) "ok" else "FAIL", c.module, c.detail });
        }
        return if (failed == 0) 0 else 1;
    }

    const config_gui: ziguri.App.Config = .{
        .id = "dev.ziguri.Smoke",
        .title = "ziguri smoke test",
        .assets = app.assets,
        // The security checks navigate to remote URLs: never hand them to a browser.
        .security = .{ .external_links = .deny },
    };
    comptime var config_auto = config_gui;
    config_auto.start = "index.html?auto-quit";
    const api: ziguri.App.Api = .{ .commands = Commands };
    return if (auto_quit) ziguri.App.run(api, config_auto) else ziguri.App.run(api, config_gui);
}
