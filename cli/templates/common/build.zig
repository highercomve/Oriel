const std = @import("std");
const oriel = @import("oriel");

pub fn build(b: *std.Build) void {
    // On macOS, a target without a version builds for macOS 13+ (not just
    // the Mac building it); pass this target to every executable you add.
    const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
    const optimize = b.standardOptimizeOption(.{});

    // Oriel's built-in modules and plugins. Switch on what the app uses:
    // anything left off is neither compiled nor linked.
    const dep = b.dependency("oriel", .{
        .target = target,
        .optimize = optimize,
        .tray = false,
        .menu = false,
        .store = false,
        .dialog = false,
        .notification = false,
        .updater = false,
        .sql = false,
        .fs_watch = false,
        .media_server = false,
        .global_shortcut = false,
        .input = false,
        .clipboard = false,
    });

    // Frontend in frontend/ (@@build_summary@@).
    // zig build          production build
    // zig build run      run it
@@dev_steps@@    // zig build check    type-check src/ without building
    // zig build package  installers: deb/rpm/AppImage (Linux), setup.exe (Windows), .app/.dmg (macOS)
    _ = oriel.addApp(b, dep, .{
        .name = "@@name@@",
        .root_source_file = b.path("src/main.zig"),
        .icon = b.path("icon.png"), // High-resolution PNG (1024x1024 recommended)
        .frontend = @@frontend@@,
        .package = .{
            .id = "@@app_id@@",
            .name = "@@title@@",
            // .publisher = "Your Name <you@example.com>", // default: from the app id
            .summary = "@@title@@, built with Oriel",
            .version = "0.1.0",
        },
        // The isolation pattern: every call from the frontend to Zig goes
        // through isolation/hook.js first, in a frame the page can't reach.
        // .isolation = .{ .hook = b.path("isolation/hook.js") },
    });
}
