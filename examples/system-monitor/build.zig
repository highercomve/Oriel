const std = @import("std");
const oriel = @import("oriel");

/// Live telemetry with WebView, JavaScript/native, or compiled .oriel views.
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const Renderer = enum { webview, native, oriel };
    const renderer = b.option(Renderer, "renderer", "Renderer: webview, native (default), or oriel (.oriel views)") orelse .native;
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = renderer != .webview,
        .zig_ui = renderer == .oriel,
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
        .clipboard = true,
    });
    const model_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("monitor_model.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Test histories and process filtering/sorting").dependOn(&b.addRunArtifact(model_tests).step);
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-system-monitor",
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
            .id = "dev.oriel.SystemMonitor",
            .name = "Oriel System Monitor",
            .summary = "Live CPU, memory and process monitor with Oriel and native_ui",
            .description = "A fast, lightweight desktop system monitor featuring direct kernel telemetry and native rendering.",
            .categories = "System;Monitor;",
            .version = "0.1.0",
        },
    });
}
