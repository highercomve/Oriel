const std = @import("std");
const oriel = @import("oriel");

/// Live telemetry with WebView, JavaScript/native, or compiled .oriel views.
pub fn build(b: *std.Build) void {
    const version: []const u8 = @import("build.zig.zon").version;
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});
    const Renderer = enum { webview, native, oriel };
    const renderer = b.option(Renderer, "renderer", "Renderer: oriel (.oriel views, the default), native, or webview") orelse .oriel;
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .native_ui = renderer != .webview,
        .zig_ui = renderer == .oriel,
        .native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings") orelse false,
        .clipboard = true,
    });
    const model_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/monitor_model.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    b.step("test", "Test histories and process filtering/sorting").dependOn(&b.addRunArtifact(model_tests).step);
    // The .oriel views, embedded by name (@embedFile("monitor.oriel")):
    // views/ is outside src/, the app module's root.
    const view_names = [_][]const u8{ "monitor", "process", "application", "disk", "settings", "actions", "confirm" };
    var imports: [view_names.len + 1]std.Build.Module.Import = undefined;
    for (view_names, imports[0..view_names.len]) |name, *view| view.* = .{
        .name = b.fmt("{s}.oriel", .{name}),
        .module = b.createModule(.{ .root_source_file = b.path(b.fmt("views/{s}.oriel", .{name})) }),
    };
    // The version (build.zig.zon's: it ships with each Oriel release, so it
    // follows Oriel's) and the renderer, for "Check for updates": a copy
    // updates from its own renderer's entry in system-monitor-latest.json.
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);
    build_info.addOption([]const u8, "renderer", @tagName(renderer));
    imports[view_names.len] = .{ .name = "monitor_build", .module = build_info.createModule() };
    _ = oriel.addApp(b, dep, .{
        .name = "oriel-system-monitor",
        .root_source_file = b.path("src/main.zig"),
        .imports = &imports,
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
            .version = version,
        },
        // Oriel's release key (variable ORIEL_UPDATE_PUBLIC_KEY): the
        // system monitor's update manifests are signed with ORIEL_UPDATE_KEY.
        .update_public_key = "BLCr3rtmVSQhkO1YFKomcAEhlvWs8P3OeFQvc7teY4o=",
    });
}
