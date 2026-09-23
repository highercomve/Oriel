//! ziguri framework build.
//!
//! This builds only the framework: the `ziguri` module, the `embed_assets`
//! build tool and the unit tests. Apps are separate packages that depend on
//! ziguri and call `addApp` from their own build.zig:
//!
//!     // build.zig.zon: .ziguri = .{ .path = "../ziguri" }
//!     const ziguri = @import("ziguri");
//!     pub fn build(b: *std.Build) void {
//!         const dep = b.dependency("ziguri", .{ .target = target, .optimize = optimize, .sql = false });
//!         _ = ziguri.addApp(b, dep, .{ .name = "my-app", .root_source_file = b.path("src/main.zig"), ... });
//!     }

const std = @import("std");
const Scanner = @import("wayland").Scanner;

/// Built-in modules and plugins an app can switch on. Anything left off is
/// neither compiled nor linked, so apps only pay for what they use.
const Features = struct {
    // Built-in modules
    tray: bool,
    updater: bool,
    media_server: bool,
    sql: bool,
    fs_watch: bool,
    dialog: bool,
    notification: bool,
    store: bool,
    menu: bool,
    // App-specific plugins
    global_shortcut: bool,
    input: bool,
    clipboard: bool,

    fn fromOptions(b: *std.Build) Features {
        var f: Features = undefined;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            @field(f, field.name) = b.option(bool, field.name, "Enable the " ++ field.name ++ " module") orelse true;
        }
        return f;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const features = Features.fromOptions(b);

    const ziguri = addZiguriModule(b, target, optimize, features);

    // Host tool used by `addApp` to embed built frontends.
    const embed_assets = b.addExecutable(.{
        .name = "embed_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_assets.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(embed_assets);

    // Host tool used by `addApp` for dev mode watch + reload.
    const dev_runner = b.addExecutable(.{
        .name = "dev_runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dev_runner.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    b.installArtifact(dev_runner);

    const tests = b.addTest(.{
        .root_module = ziguri,
        // Zig's self-hosted linker can't handle the .sframe sections in
        // crt1.o from GCC 16 / recent glibc, so link with LLVM + LLD.
        .use_llvm = true,
        .use_lld = true,
    });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);
}

fn addZiguriModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    features: Features,
) *std.Build.Module {
    const options = b.addOptions();
    inline for (@typeInfo(Features).@"struct".fields) |field| {
        options.addOption(bool, field.name, @field(features, field.name));
    }

    const gobject = b.dependency("gobject", .{ .target = target, .optimize = optimize });

    const ziguri = b.addModule("ziguri", .{
        .root_source_file = b.path("src/ziguri.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "glib", .module = gobject.module("glib2") },
            .{ .name = "gobject", .module = gobject.module("gobject2") },
            .{ .name = "gio", .module = gobject.module("gio2") },
            .{ .name = "gdk", .module = gobject.module("gdk4") },
            .{ .name = "gtk", .module = gobject.module("gtk4") },
            .{ .name = "webkit", .module = gobject.module("webkit6") },
            .{ .name = "jsc", .module = gobject.module("javascriptcore6") },
            .{ .name = "soup", .module = gobject.module("soup3") },
        },
    });
    ziguri.addOptions("build_options", options);

    if (features.tray) {
        const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
        ziguri.addImport("zigimg", zigimg.module("zigimg"));
    }
    if (features.media_server) {
        const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });
        ziguri.addImport("httpz", httpz.module("httpz"));
    }
    if (features.sql) {
        const sqlite = b.dependency("sqlite", .{});
        ziguri.addIncludePath(sqlite.path("."));
        ziguri.addCSourceFile(.{
            .file = sqlite.path("sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_DEPRECATED" },
        });
    }
    if (features.input or features.clipboard) {
        const scanner = Scanner.create(b, .{});
        scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
        scanner.addCustomProtocol(b.path("protocols/wlr-data-control-unstable-v1.xml"));
        scanner.addCustomProtocol(b.path("protocols/virtual-keyboard-unstable-v1.xml"));
        scanner.generate("wl_seat", 7);
        scanner.generate("ext_data_control_manager_v1", 1);
        scanner.generate("zwlr_data_control_manager_v1", 2);
        scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
        ziguri.addImport("wayland", b.createModule(.{
            .root_source_file = scanner.result,
            .target = target,
            .optimize = optimize,
        }));
        ziguri.linkSystemLibrary("wayland-client", .{});
    }
    if (features.input) {
        ziguri.linkSystemLibrary("xkbcommon", .{});
        ziguri.linkSystemLibrary("xtst", .{});
    }
    if (features.global_shortcut or features.input) {
        ziguri.linkSystemLibrary("x11", .{});
    }
    return ziguri;
}

// ---------------------------------------------------------------------------
// App build helper (called from an app's build.zig)
// ---------------------------------------------------------------------------

pub const AppOptions = struct {
    /// Executable name.
    name: []const u8,
    /// The app's main.zig. It can `@import("ziguri")` and `@import("ziguri_app")`
    /// (build-time config: `assets`, `dev`, `types_path`).
    root_source_file: std.Build.LazyPath,
    frontend: Frontend,
};

pub const Frontend = struct {
    /// Frontend directory, relative to the app's build root.
    dir: []const u8,
    /// Build output directory inside `dir` that gets embedded.
    dist: []const u8 = "dist",
    /// Production build command, run in `dir`. Null for a static frontend
    /// whose `dist` directory is embedded as-is.
    build_command: ?[]const []const u8 = &.{ "npm", "run", "build" },
    /// Install command, run in `dir` when `node_modules` is missing.
    install_command: ?[]const []const u8 = &.{ "npm", "install" },
    /// Dev server; null means the app has no dev mode.
    dev: ?Dev = .{},
    /// Where the generated TypeScript for the Zig commands is written,
    /// relative to `dir`. Null to skip type generation.
    types_path: ?[]const u8 = "src/ziguri.ts",

    pub const Dev = struct {
        url: []const u8 = "http://localhost:5173/",
        command: []const []const u8 = &.{ "node_modules/.bin/vite", "--port", "5173", "--strictPort" },
    };
};

pub const App = struct {
    /// Production executable with the frontend embedded (installed by `zig build`).
    exe: *std.Build.Step.Compile,
    /// Development executable loading the frontend from the dev server.
    dev_exe: ?*std.Build.Step.Compile,
};

/// Add a ziguri app to `b` with these steps:
///   zig build          build the frontend, embed it, install the app
///   zig build run      run the production build
///   zig build dev      run against the dev server (hot reload)
///   zig build types    regenerate the frontend's TypeScript command types
pub fn addApp(b: *std.Build, ziguri_dep: *std.Build.Dependency, options: AppOptions) App {
    const ziguri = ziguri_dep.module("ziguri");
    const target = ziguri.resolved_target.?;
    const optimize = ziguri.optimize.?;
    // When optimize was not explicitly given on the command-line, default production to ReleaseSafe
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);

    // `npm install` once, when node_modules is missing.
    var install_step: ?*std.Build.Step = null;
    if (fe.install_command) |cmd| {
        const node_modules = b.pathJoin(&.{ fe_dir, "node_modules" });
        if (!pathExists(b, node_modules)) {
            const install = b.addSystemCommand(cmd);
            install.setCwd(.{ .cwd_relative = fe_dir });
            install_step = &install.step;
        }
    }

    // Dev executable: no embedded assets, loads the dev server.
    const dev_exe: ?*std.Build.Step.Compile = if (fe.dev) |dev| blk: {
        const cfg = b.addOptions();
        cfg.addOption(bool, "is_dev", true);
        cfg.addOption([]const u8, "dev_url", dev.url);
        cfg.addOption([]const []const u8, "dev_command", dev.command);
        cfg.addOption([]const u8, "frontend_dir", fe_dir);
        break :blk addExe(b, ziguri, target, dev_optimize, b.fmt("{s}-dev", .{options.name}), options.root_source_file, appConfigModule(b, ziguri, cfg, null));
    } else null;

    // Generated TypeScript types, written by the dev build (no frontend needed).
    var types_step: ?*std.Build.Step = null;
    if (fe.types_path) |types_path| {
        const gen_exe = dev_exe orelse @panic("TypeScript generation needs a dev build (frontend.dev)");
        const gen = b.addRunArtifact(gen_exe);
        gen.addArgs(&.{ "--emit-types", b.pathJoin(&.{ fe_dir, types_path }) });
        gen.has_side_effects = true;
        types_step = &gen.step;
        b.step("types", "Generate TypeScript types for the Zig commands").dependOn(&gen.step);
    }

    // Production: build the frontend, embed dist/, compile.
    const embed = b.addRunArtifact(ziguri_dep.artifact("embed_assets"));
    embed.has_side_effects = true; // dist/ is produced outside the build graph
    embed.addArg(b.pathJoin(&.{ fe_dir, fe.dist }));
    const assets_dir = embed.addOutputDirectoryArg("assets");
    if (fe.build_command) |cmd| {
        const build_fe = b.addSystemCommand(cmd);
        build_fe.setCwd(.{ .cwd_relative = fe_dir });
        build_fe.has_side_effects = true;
        if (install_step) |s| build_fe.step.dependOn(s);
        if (types_step) |s| build_fe.step.dependOn(s);
        embed.step.dependOn(&build_fe.step);
    }
    const prod_cfg = b.addOptions();
    prod_cfg.addOption(bool, "is_dev", false);
    prod_cfg.addOption([]const u8, "dev_url", "");
    prod_cfg.addOption([]const []const u8, "dev_command", &.{});
    prod_cfg.addOption([]const u8, "frontend_dir", fe_dir);
    const exe = addExe(b, ziguri, target, prod_optimize, options.name, options.root_source_file, appConfigModule(b, ziguri, prod_cfg, assets_dir.path(b, "assets.zig")));
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the production build").dependOn(&run.step);

    if (dev_exe) |d| {
        const install_dev = b.addInstallArtifact(d, .{});
        b.step("build-dev", "Build development executable").dependOn(&install_dev.step);

        const runner = b.addRunArtifact(ziguri_dep.artifact("dev_runner"));
        runner.addArgs(&.{
            b.fmt("--zig={s}", .{b.graph.zig_exe}),
            b.fmt("--project-dir={s}", .{b.build_root.path orelse "."}),
            b.fmt("--watch-dir={s}", .{b.pathJoin(&.{ b.build_root.path orelse ".", "src" })}),
            b.fmt("--frontend-dir={s}", .{fe_dir}),
            b.fmt("--app-bin={s}", .{b.getInstallPath(.bin, d.name)}),
        });

        if (fe.dev) |dev| {
            if (dev.command.len > 0) {
                runner.addArg("--dev-cmd");
                for (dev.command) |c| runner.addArg(c);
                runner.addArg("--dev-cmd-end");
            }
        }

        if (b.args) |args| {
            runner.addArg("--app-args");
            runner.addArgs(args);
        }

        runner.step.dependOn(&install_dev.step);
        if (install_step) |s| runner.step.dependOn(s);
        if (types_step) |s| runner.step.dependOn(s);

        b.step("dev", "Run against the frontend dev server (hot reload & Zig reload)").dependOn(&runner.step);
    }

    return .{ .exe = exe, .dev_exe = dev_exe };
}

/// The `ziguri_app` module: build-time config for the app's main.zig.
fn appConfigModule(
    b: *std.Build,
    ziguri: *std.Build.Module,
    cfg: *std.Build.Step.Options,
    assets: ?std.Build.LazyPath,
) *std.Build.Module {
    const files = b.addWriteFiles();
    const root = files.add("ziguri_app.zig",
        \\const ziguri = @import("ziguri");
        \\const cfg = @import("cfg");
        \\
        \\/// Embedded frontend files (empty in dev builds).
        \\pub const assets: []const ziguri.App.Asset = if (cfg.is_dev) &.{} else @import("assets").files;
        \\
        \\/// Dev-server settings (null in production builds).
        \\pub const dev: ?ziguri.App.Dev = if (cfg.is_dev) .{
        \\    .url = cfg.dev_url,
        \\    .command = cfg.dev_command,
        \\    .cwd = cfg.frontend_dir,
        \\} else null;
        \\
    );
    const mod = b.createModule(.{ .root_source_file = root });
    mod.addImport("ziguri", ziguri);
    mod.addOptions("cfg", cfg);
    if (assets) |a| {
        const assets_mod = b.createModule(.{ .root_source_file = a });
        assets_mod.addImport("ziguri", ziguri);
        mod.addImport("assets", assets_mod);
    }
    return mod;
}

fn addExe(
    b: *std.Build,
    ziguri: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    app_config: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ziguri", .module = ziguri },
                .{ .name = "ziguri_app", .module = app_config },
            },
        }),
        // See the note on the test step: LLD is required on GCC 16 systems.
        .use_llvm = true,
        .use_lld = true,
    });
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}
