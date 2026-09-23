//! GhostPen Lite: global hotkey -> read selection/clipboard -> rewrite -> paste.
//!
//! Run options:
//!   ghostpen-lite                  GUI window + tray icon + global hotkey
//!   ghostpen-lite --auto-quit      Headless/webview check
//!   ghostpen-lite --test-pipeline  Headless CLI pipeline test (X11 XTest + clipboard)

const std = @import("std");
const ziguri = @import("ziguri");
const app = @import("ziguri_app");

const icon_png = @embedFile("icon.png");

var global_io: std.Io = undefined;
var tray_instance: ?*ziguri.tray.Tray = null;

const Commands = struct {
    pub const async_commands = .{ "rewrite", "trigger_pipeline" };

    /// Mock LLM text rewriter.
    pub fn rewrite(gpa: std.mem.Allocator, _: std.Io, args: struct { text: []const u8 }) ![]const u8 {
        const trimmed = std.mem.trim(u8, args.text, " \t\r\n");
        if (trimmed.len == 0) {
            return try std.fmt.allocPrint(gpa, "[✨ Rewritten: (empty input)]", .{});
        }
        return try std.fmt.allocPrint(gpa, "[✨ Rewritten: {s}]", .{trimmed});
    }

    /// Full pipeline: read clipboard -> rewrite -> write back to clipboard -> paste.
    pub fn trigger_pipeline(gpa: std.mem.Allocator, local_io: std.Io) !struct { original: []const u8, rewritten: []const u8 } {
        const original = try ziguri.clipboard.readText(gpa);
        const transformed = try rewrite(gpa, local_io, .{ .text = original });

        try ziguri.clipboard.writeText(transformed);
        ziguri.input.paste() catch {};

        ziguri.App.emit("pipeline_completed", .{
            .original = original,
            .rewritten = transformed,
        });

        return .{
            .original = original,
            .rewritten = transformed,
        };
    }

    pub fn read_clipboard(gpa: std.mem.Allocator) ![]const u8 {
        return try ziguri.clipboard.readText(gpa);
    }

    pub fn write_clipboard(_: std.mem.Allocator, args: struct { text: []const u8 }) !void {
        try ziguri.clipboard.writeText(args.text);
    }

    pub fn send_notification(_: std.mem.Allocator, args: struct { title: []const u8, body: []const u8 }) !void {
        try ziguri.notification.notify(.{
            .title = args.title,
            .body = args.body,
        });
    }

    pub fn done(_: std.mem.Allocator, args: struct { failed: u32, report: []const u8 }) void {
        std.debug.print("{s}\n", .{args.report});
        ziguri.App.quit(if (args.failed == 0) 0 else 1);
    }
};

fn onHotkey(id: []const u8) void {
    ziguri.App.emit("hotkey_pressed", .{ .id = id });
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = Commands.trigger_pipeline(arena.allocator(), global_io) catch {};
}

fn onTrayMenu(id: []const u8, _: ?bool) void {
    if (std.mem.eql(u8, id, "toggle")) {
        ziguri.App.toggleWindow();
    } else if (std.mem.eql(u8, id, "rewrite")) {
        onHotkey("tray_action");
    } else if (std.mem.eql(u8, id, "quit")) {
        ziguri.App.quit(0);
    }
}

fn setup() anyerror!void {
    // 1. Register global shortcut CTRL+ALT+G
    ziguri.global_shortcut.register(std.heap.smp_allocator, .{
        .id = "ghostpen_rewrite",
        .description = "GhostPen text rewrite hotkey",
        .trigger = "CTRL+ALT+G",
    }, &onHotkey) catch |err| {
        std.log.warn("failed to register hotkey: {s}", .{@errorName(err)});
    };

    // 2. Setup Tray icon
    tray_instance = ziguri.tray.Tray.create(std.heap.smp_allocator, .{
        .id = "ghostpen-lite",
        .title = "GhostPen Lite",
        .icon = .{ .png = icon_png },
        .menu = &.{
            .{ .item = .{ .id = "toggle", .label = "Toggle Window" } },
            .{ .item = .{ .id = "rewrite", .label = "Rewrite Clipboard (Ctrl+Alt+G)" } },
            .{ .item = .{ .id = "quit", .label = "Quit" } },
        },
        .on_menu = &onTrayMenu,
    }) catch null;
}

pub fn main(init: std.process.Init) !u8 {
    global_io = init.io;
    ziguri.io = init.io;
    ziguri.App.io = init.io;

    var auto_quit = false;
    for (init.minimal.args.vector[1..]) |arg_z| {
        const arg = std.mem.span(arg_z);
        if (std.mem.eql(u8, arg, "--test-pipeline")) {
            return testPipelineHeadless(init.gpa);
        } else if (std.mem.eql(u8, arg, "--auto-quit")) {
            auto_quit = true;
        }
    }

    const config_gui: ziguri.App.Config = .{
        .id = "com.ghostpen.lite",
        .title = "GhostPen Lite",
        .width = 680,
        .height = 560,
        .assets = app.assets,
        .start = "index.html",
        .setup = &setup,
    };
    comptime var config_auto = config_gui;
    config_auto.start = "index.html?auto-quit";

    const api: ziguri.App.Api = .{ .commands = Commands };
    return if (auto_quit) ziguri.App.run(api, config_auto) else ziguri.App.run(api, config_gui);
}

fn testPipelineHeadless(gpa: std.mem.Allocator) u8 {
    std.debug.print("Testing GhostPen Lite pipeline headlessly...\n", .{});

    // 1. Register shortcut
    ziguri.global_shortcut.register(gpa, .{
        .id = "test_hotkey",
        .trigger = "ctrl+alt+g",
    }, &onHotkey) catch |err| {
        std.debug.print("[FAIL] global_shortcut.register: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer ziguri.global_shortcut.deinit(gpa);

    // 2. Set clipboard
    const initial_text = "clean architecture in zig";
    ziguri.clipboard.writeText(initial_text) catch |err| {
        std.debug.print("[FAIL] clipboard.writeText: {s}\n", .{@errorName(err)});
        return 1;
    };

    // 3. Trigger shortcut
    const ok = ziguri.global_shortcut.trigger("test_hotkey");
    if (!ok) {
        std.debug.print("[FAIL] global_shortcut.trigger failed\n", .{});
        return 1;
    }

    // 4. Read clipboard back
    const result = ziguri.clipboard.readText(gpa) catch |err| {
        std.debug.print("[FAIL] clipboard.readText: {s}\n", .{@errorName(err)});
        return 1;
    };
    defer gpa.free(result);

    const expected = "[✨ Rewritten: clean architecture in zig]";
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("[FAIL] Expected clipboard '{s}', got '{s}'\n", .{ expected, result });
        return 1;
    }

    std.debug.print("[ok] GhostPen Lite pipeline verified: clipboard read -> rewrite -> clipboard write -> paste\n", .{});
    return 0;
}
