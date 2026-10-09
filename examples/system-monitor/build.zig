const std = @import("std");
const oriel = @import("oriel");

/// System monitor: live CPU, memory and process telemetry rendered via
/// Oriel's native renderer (`-Dnative_ui`) or system WebView.
pub fn build(b: *std.Build) void {
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = b.option(bool, "native_ui", "Draw the page with native widgets instead of a WebView (experimental)") orelse true,
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
        .native_dom = b.option(bool, "native_dom", "With -Dnative_ui: the native DOM (default), or linkedom when false"),
        .clipboard = true,
    });
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-system-monitor",
        .root_source_file = b.path("main.zig"),
        .frontend = .{
            .dir = "web",
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
