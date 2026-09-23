//! GhostPen Lite: global hotkey -> read selection/clipboard -> rewrite -> paste.
//!
//! Run options:
//!   ghostpen-lite                  GUI window + tray icon + global hotkey
//!   ghostpen-lite --auto-quit      Headless/webview check
//!   ghostpen-lite --test-pipeline  Headless pipeline test: hotkey -> clipboard -> rewrite
//!                                  -> clipboard, run on a worker inside the app (exit 0 = ok)

const std = @import("std");
const oriel = @import("oriel");
const app = @import("oriel_app");

const icon_png = @embedFile("icon.png");

var global_io: std.Io = undefined;
/// Pipelines finished (tests wait on it).
var pipelines_done: std.atomic.Value(u32) = .init(0);
var tray_instance: ?*oriel.tray.Tray = null;

const Commands = struct {
    // Clipboard reads block (the selection owner may be another app, or
    // our own main loop), so they run on the worker pool.
    pub const async_commands = .{ "rewrite", "trigger_pipeline", "read_clipboard" };

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
        const original = try oriel.clipboard.readText(gpa);
        const transformed = try rewrite(gpa, local_io, .{ .text = original });

        try oriel.clipboard.writeText(transformed);
        oriel.input.paste() catch {};

        oriel.App.emit("pipeline_completed", .{
            .original = original,
            .rewritten = transformed,
        });

        return .{
            .original = original,
            .rewritten = transformed,
        };
    }

    pub fn read_clipboard(gpa: std.mem.Allocator) ![]const u8 {
        return try oriel.clipboard.readText(gpa);
    }

    pub fn write_clipboard(_: std.mem.Allocator, args: struct { text: []const u8 }) !void {
        try oriel.clipboard.writeText(args.text);
    }

    pub fn send_notification(_: std.mem.Allocator, args: struct { title: []const u8, body: []const u8 }) !void {
        try oriel.notification.notify(.{
            .title = args.title,
            .body = args.body,
        });
    }

    pub fn done(_: std.mem.Allocator, args: struct { failed: u32, report: []const u8 }) void {
        std.debug.print("{s}\n", .{args.report});
        oriel.App.quit(if (args.failed == 0) 0 else 1);
    }
};

/// Runs on the main thread: hand the (blocking) pipeline to a worker.
fn onHotkey(id: []const u8) void {
    oriel.App.emit("hotkey_pressed", .{ .id = id });
    oriel.App.spawn(hotkeyPipeline, .{}) catch |err| {
        std.log.err("hotkey pipeline: {s}", .{@errorName(err)});
    };
}

fn hotkeyPipeline() !void {
    defer _ = pipelines_done.fetchAdd(1, .release);
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = try Commands.trigger_pipeline(arena.allocator(), global_io);
}

fn onTrayMenu(id: []const u8, _: ?bool) void {
    if (std.mem.eql(u8, id, "toggle")) {
        oriel.App.toggleWindow();
    } else if (std.mem.eql(u8, id, "rewrite")) {
        onHotkey("tray_action");
    } else if (std.mem.eql(u8, id, "quit")) {
        oriel.App.quit(0);
    }
}

fn setup() anyerror!void {
    // 1. Register global shortcut CTRL+ALT+G
    oriel.global_shortcut.register(std.heap.smp_allocator, .{
        .id = "ghostpen_rewrite",
        .description = "GhostPen text rewrite hotkey",
        .trigger = "CTRL+ALT+G",
    }, &onHotkey) catch |err| {
        std.log.warn("failed to register hotkey: {s}", .{@errorName(err)});
    };

    // 2. Setup Tray icon
    tray_instance = oriel.tray.Tray.create(std.heap.smp_allocator, .{
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

    var auto_quit = false;
    var test_pipeline = false;
    for (init.minimal.args.vector[1..]) |arg_z| {
        const arg = std.mem.span(arg_z);
        if (std.mem.eql(u8, arg, "--test-pipeline")) {
            test_pipeline = true;
        } else if (std.mem.eql(u8, arg, "--auto-quit")) {
            auto_quit = true;
        }
    }

    const config_gui: oriel.App.Config = .{
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
    comptime var config_test = config_gui;
    config_test.setup = &testSetup;

    const api: oriel.App.Api = .{ .commands = Commands };
    if (test_pipeline) return oriel.App.run(init.io, api, config_test);
    return if (auto_quit) oriel.App.run(init.io, api, config_auto) else oriel.App.run(init.io, api, config_gui);
}

/// `--test-pipeline`: register the hotkey on the main thread, then drive
/// the pipeline from a worker like a real hotkey press would.
fn testSetup() anyerror!void {
    std.debug.print("Testing GhostPen Lite pipeline headlessly...\n", .{});
    oriel.global_shortcut.register(std.heap.smp_allocator, .{
        .id = "test_hotkey",
        .trigger = "ctrl+alt+g",
    }, &onHotkey) catch |err| {
        std.debug.print("[FAIL] global_shortcut.register: {s}\n", .{@errorName(err)});
        return quitFromWorker(1);
    };
    try oriel.App.spawn(testPipelineWorker, .{});
}

fn testPipelineWorker() void {
    quitFromWorker(if (testPipeline(std.heap.smp_allocator)) 0 else |err| blk: {
        std.debug.print("[FAIL] pipeline: {s}\n", .{@errorName(err)});
        break :blk 1;
    });
}

fn testPipeline(gpa: std.mem.Allocator) !void {
    // 1. Set the clipboard (handed to the main loop).
    const initial_text = "clean architecture in zig";
    try oriel.clipboard.writeText(initial_text);

    // 2. Press the hotkey: the callback spawns the pipeline on another worker.
    const before = pipelines_done.load(.acquire);
    if (!oriel.global_shortcut.trigger("test_hotkey")) return error.TriggerFailed;
    var waited_ms: u32 = 0;
    while (pipelines_done.load(.acquire) == before) : (waited_ms += 10) {
        if (waited_ms > 10_000) return error.PipelineTimeout;
        global_io.sleep(.fromMilliseconds(10), .awake) catch {};
    }

    // 3. Read the clipboard back.
    const result = try oriel.clipboard.readText(gpa);
    defer gpa.free(result);
    const expected = "[✨ Rewritten: clean architecture in zig]";
    if (!std.mem.eql(u8, result, expected)) {
        std.debug.print("[FAIL] Expected clipboard '{s}', got '{s}'\n", .{ expected, result });
        return error.UnexpectedClipboard;
    }
    std.debug.print("[ok] GhostPen Lite pipeline verified: hotkey -> clipboard read -> rewrite -> clipboard write -> paste\n", .{});
}

fn quitFromWorker(code: u8) void {
    oriel.App.quit(code);
}
