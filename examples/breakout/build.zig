const std = @import("std");
const oriel = @import("oriel");

/// Breakout: a canvas game with an interface around it, for comparing the
/// renderers: `-Drenderer=webview` (default), `native` (the page on native
/// widgets) and `oriel` (views/breakout.oriel and Zig, no JavaScript).
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const Renderer = enum { webview, native, oriel };
    const renderer = b.option(Renderer, "renderer", "Renderer: webview, native, or oriel (.oriel views)") orelse .webview;
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = renderer != .webview,
        .zig_ui = renderer == .oriel,
        // -Dnative_ui_prof: the native renderer logs its stage timings.
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
    });
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-breakout",
        .root_source_file = b.path("main.zig"),
        .frontend = .{
            .dir = if (renderer == .oriel) "views" else "web",
            .dist = ".",
            .build_command = null,
            .install_command = null,
            .dev = null,
            .types_path = null,
        },
        .package = .{
            .id = "dev.oriel.Breakout",
            .name = "Breakout",
            .summary = "Breakout in a canvas, native renderer or WebView",
            .version = "0.1.0",
        },
    });
    // The rules draw with oriel.canvas, which the WebView build leaves out:
    // the tests get their own Oriel, for this machine, with it.
    const test_dep = b.dependency("oriel", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .native_ui = true,
    });
    const game_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("game.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "oriel", .module = test_dep.module("oriel") }},
    }) });
    b.step("test-game", "Check Breakout's Zig physics rules").dependOn(&b.addRunArtifact(game_tests).step);
}
