//! oriel framework build.
//!
//! This builds only the framework: the `oriel` module, the `embed_assets`
//! build tool and the unit tests. Apps are separate packages that depend on
//! oriel and call `addApp` from their own build.zig:
//!
//!     // build.zig.zon: .oriel = .{ .path = "../oriel" }
//!     const oriel = @import("oriel");
//!     pub fn build(b: *std.Build) void {
//!         const dep = b.dependency("oriel", .{ .target = target, .optimize = optimize, .sql = false });
//!         _ = oriel.addApp(b, dep, .{ .name = "my-app", .root_source_file = b.path("src/main.zig"), ... });
//!     }

const std = @import("std");
const Scanner = @import("wayland").Scanner;
const ggml = @import("build/ggml.zig");

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

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
    // Native dependencies (DEFAULT OFF)
    sqlite_vec: bool,
    llama: bool,
    whisper: bool,
    audio_capture: bool,

    /// Modules and plugins without a macOS backend yet (PLAN.md Milestone 7,
    /// step 2). On macOS they default to off and can't be switched on.
    const unported_on_macos = [_][]const u8{
        "updater", "media_server", "fs_watch",  "dialog",        "notification",    "store",
        "menu",    "input",        "clipboard", "audio_capture", "global_shortcut",
    };

    fn fromOptions(b: *std.Build, target: std.Build.ResolvedTarget) Features {
        if (b.option(bool, "ggml_vulkan", "Enable Vulkan backend (not supported)") orelse false) {
            fatal("Vulkan is not supported yet, see README.md", .{});
        }
        if (b.option(bool, "llama_mtmd", "Enable multimodal mtmd support (not supported)") orelse false) {
            fatal("llama_mtmd is not supported yet (libmtmd is not built; its API is experimental upstream), see README.md", .{});
        }

        // Every module and plugin builds for Linux and Windows; the native
        // dependencies are opt-in on both. On macOS, only the ported ones.
        const is_macos = target.result.os.tag == .macos;
        var f: Features = undefined;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            const is_native = comptime (std.mem.eql(u8, field.name, "sqlite_vec") or
                std.mem.eql(u8, field.name, "llama") or
                std.mem.eql(u8, field.name, "whisper") or
                std.mem.eql(u8, field.name, "audio_capture"));
            const unported = comptime for (unported_on_macos) |name| {
                if (std.mem.eql(u8, name, field.name)) break true;
            } else false;
            const opt = b.option(bool, field.name, "Enable the " ++ field.name ++ " module");
            if (is_macos and unported and (opt orelse false)) {
                fatal("-D" ++ field.name ++ " is not supported on macOS yet (PLAN.md Milestone 7)", .{});
            }
            // The tray builds on macOS as a stub whose `create` fails with
            // error.NotSupported, so apps using it still run; it is off unless asked for.
            const default_on = !is_native and !(is_macos and (unported or std.mem.eql(u8, field.name, "tray")));
            @field(f, field.name) = opt orelse default_on;
        }

        if (f.sqlite_vec and !f.sql) {
            fatal("sqlite_vec requires sql to be enabled (cannot use -Dsqlite_vec with -Dsql=false)", .{});
        }

        return f;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const features = Features.fromOptions(b, target);

    const oriel = addOrielModule(b, target, optimize, features);

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

    // Host tool used by `addApp` for packaging (deb, rpm, AppImage, NSIS, desktop-entry).
    const zigimg_dep = b.dependency("zigimg", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
    const package_tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/package/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
        },
    });
    const package_tool = b.addExecutable(.{
        .name = "package_tool",
        .root_module = package_tool_mod,
    });
    b.installArtifact(package_tool);

    // Host tool used for update management (keygen and sign-update).
    const update_manifest_mod = b.createModule(.{
        .root_source_file = b.path("src/modules/update_manifest.zig"),
    });
    const update_tool = b.addExecutable(.{
        .name = "update_tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/update_tool.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "update_manifest", .module = update_manifest_mod },
            },
        }),
    });
    b.installArtifact(update_tool);
    addUpdaterSteps(b, update_tool);

    const is_linux = target.result.os.tag == .linux;
    // Unit tests run natively on Linux and macOS (Windows: see PLAN.md).
    const runs_tests = is_linux or target.result.os.tag == .macos;

    const tests = b.addTest(.{
        .root_module = oriel,
        // Zig's self-hosted linker can't handle the .sframe sections in
        // crt1.o from GCC 16 / recent glibc, so link with LLVM + LLD.
        .use_llvm = true,
        .use_lld = useLld(target),
    });
    const package_tests = b.addTest(.{
        .root_module = package_tool_mod,
        .use_llvm = true,
        .use_lld = useLld(b.graph.host),
    });
    const test_step = b.step("test", "Run unit tests");
    if (runs_tests) {
        test_step.dependOn(&b.addRunArtifact(tests).step);
        test_step.dependOn(&b.addRunArtifact(package_tests).step);
    }

    const tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/update_tool.zig"),
            .target = if (runs_tests) target else b.graph.host,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "update_manifest", .module = update_manifest_mod },
            },
        }),
        .use_llvm = true,
        .use_lld = useLld(if (runs_tests) target else b.graph.host),
    });
    if (runs_tests) {
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }

    const patch_httpz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch_httpz.zig"),
            .target = b.graph.host,
        }),
        .use_llvm = true,
        .use_lld = useLld(b.graph.host),
    });
    if (runs_tests) test_step.dependOn(&b.addRunArtifact(patch_httpz_tests).step);

    const dev_runner_tests = b.addTest(.{
        .root_module = dev_runner.root_module,
        .use_llvm = true,
        .use_lld = useLld(b.graph.host),
    });
    if (is_linux) {
        test_step.dependOn(&b.addRunArtifact(dev_runner_tests).step);

        // Kills a stand-in for `zig build dev` (SIGTERM, then SIGKILL) and checks
        // that dev_runner, the dev server's process group and the app are gone.
        const test_dev_cleanup_step = b.step("test-dev-cleanup", "Check that dev_runner and its children exit with their parent");
        const run_dev_cleanup = b.addSystemCommand(&.{"bash"});
        run_dev_cleanup.addFileArg(b.path("scripts/test-dev-cleanup.sh"));
        run_dev_cleanup.addArtifactArg(dev_runner);
        test_dev_cleanup_step.dependOn(&run_dev_cleanup.step);
    }

    // Type-check only: nothing requests these binaries, so Zig skips codegen
    // and linking. The fast inner loop for editors and coding agents.
    const check_step = b.step("check", "Type-check the framework, tests and tools (no binaries)");
    if (runs_tests) {
        for ([_]*std.Build.Module{ oriel, package_tool_mod, tool_tests.root_module, patch_httpz_tests.root_module }) |m| {
            check_step.dependOn(&b.addTest(.{ .root_module = m }).step);
        }
        // dev_runner is Linux-only (inotify, prctl, pidfd).
        if (is_linux) check_step.dependOn(&b.addTest(.{ .root_module = dev_runner.root_module }).step);
    } else {
        check_step.dependOn(&b.addTest(.{ .root_module = oriel }).step);
    }

    // The CLI is part of Oriel's own build only: apps that depend on Oriel
    // never build it (and don't pay for the `git` call below).
    if (is_linux and b.pkg_hash.len == 0) addCli(b, target, optimize, test_step, check_step);
}

/// `zig build cli`: the `oriel` command-line tool (cli/), a static binary
/// with no GTK dependency. `-Dtarget=aarch64-linux-musl` cross-compiles it.
fn addCli(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    check_step: *std.Build.Step,
) void {
    const zon = @import("build.zig.zon");
    const version = b.option([]const u8, "cli-version", "Version reported by `oriel --version` (default: build.zig.zon)") orelse zon.version;
    const oriel_ref = b.option([]const u8, "oriel-ref", "Git ref of Oriel that `oriel init` pins (default: this checkout's tag or commit)") orelse
        gitRef(b) orelse "main";
    const update_public_key = b.option([]const u8, "update-public-key", "Base64 Ed25519 public key for `oriel update` (default: null)");

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "oriel_ref", oriel_ref);
    options.addOption(?[]const u8, "update_public_key", update_public_key);

    // Linux builds use musl so the binary is fully static and runs on any
    // distro (the CLI needs no libc anyway).
    var query = target.query;
    if (target.result.os.tag == .linux) query.abi = .musl;
    const cli_target = b.resolveTargetQuery(query);
    const updater_core_cli = b.createModule(.{
        .root_source_file = b.path("src/updater_core.zig"),
        .target = cli_target,
        .optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe,
    });
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = cli_target,
        .optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe,
    });
    cli_mod.addOptions("build_options", options);
    cli_mod.addImport("updater_core", updater_core_cli);
    // Release builds are stripped: the binary is what install.sh downloads.
    cli_mod.strip = cli_mod.optimize != .Debug;
    const cli = b.addExecutable(.{ .name = "oriel", .root_module = cli_mod });
    b.step("cli", "Build the oriel CLI (zig-out/bin/oriel)").dependOn(&b.addInstallArtifact(cli, .{}).step);

    const updater_core_test = b.createModule(.{
        .root_source_file = b.path("src/updater_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);
    test_mod.addImport("updater_core", updater_core_test);
    const cli_tests = b.addTest(.{ .root_module = test_mod, .use_llvm = true, .use_lld = useLld(target) });
    test_step.dependOn(&b.addRunArtifact(cli_tests).step);
    check_step.dependOn(&b.addTest(.{ .root_module = test_mod }).step);
    // Also `main` and everything it reaches (not referenced by the tests).
    check_step.dependOn(&b.addExecutable(.{ .name = "oriel-check", .root_module = cli_mod }).step);
}

/// The tag at HEAD if there is one, else the commit; null outside a git checkout.
fn gitRef(b: *std.Build) ?[]const u8 {
    const root = b.build_root.path orelse ".";
    var code: u8 = undefined;
    const argvs = [_][]const []const u8{
        &.{ "git", "-C", root, "describe", "--tags", "--exact-match", "HEAD" },
        &.{ "git", "-C", root, "rev-parse", "HEAD" },
    };
    for (argvs) |argv| {
        const out = b.runAllowFail(argv, &code, .ignore) catch continue;
        const ref = std.mem.trim(u8, out, " \t\r\n");
        if (ref.len > 0) return ref;
    }
    return null;
}

/// `-Dggml_cuda`: build the CUDA backend for llama/whisper (Linux, needs the
/// CUDA toolkit). `-Dcuda_path` defaults to $CUDA_PATH or /opt/cuda,
/// `-Dcuda_arch` to "native" (the GPUs of the build machine).
fn cudaOptions(b: *std.Build, target: std.Build.ResolvedTarget) ?ggml.CudaOptions {
    const enabled = b.option(bool, "ggml_cuda", "Build the CUDA backend for llama/whisper as libggml-cuda.so (Linux; needs the CUDA toolkit)") orelse false;
    const path = b.option([]const u8, "cuda_path", "CUDA toolkit root (default: $CUDA_PATH or /opt/cuda)");
    const arch = b.option([]const u8, "cuda_arch", "nvcc -arch value (default: native)");
    if (!enabled) return null;
    if (target.result.os.tag != .linux) fatal("-Dggml_cuda is only supported on Linux targets for now", .{});
    return .{
        .path = path orelse b.graph.environ_map.get("CUDA_PATH") orelse "/opt/cuda",
        .arch = arch orelse "native",
    };
}

fn addOrielModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    features: Features,
) *std.Build.Module {
    const options = b.addOptions();
    inline for (@typeInfo(Features).@"struct".fields) |field| {
        options.addOption(bool, field.name, @field(features, field.name));
    }

    const is_linux = target.result.os.tag == .linux;

    const oriel = b.addModule("oriel", .{
        .root_source_file = b.path("src/oriel.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    oriel.addOptions("build_options", options);

    if (is_linux) {
        const gobject = b.dependency("gobject", .{ .target = target, .optimize = optimize });
        oriel.addImport("glib", gobject.module("glib2"));
        oriel.addImport("gobject", gobject.module("gobject2"));
        oriel.addImport("gio", gobject.module("gio2"));
        oriel.addImport("gdk", gobject.module("gdk4"));
        oriel.addImport("gtk", gobject.module("gtk4"));
        oriel.addImport("webkit", gobject.module("webkit6"));
        oriel.addImport("jsc", gobject.module("javascriptcore6"));
        oriel.addImport("soup", gobject.module("soup3"));
    } else if (target.result.os.tag == .windows) {
        oriel.linkSystemLibrary("user32", .{});
        oriel.linkSystemLibrary("gdi32", .{});
        oriel.linkSystemLibrary("ole32", .{});
        oriel.linkSystemLibrary("shell32", .{});
        oriel.linkSystemLibrary("advapi32", .{});
        oriel.linkSystemLibrary("shlwapi", .{});
        oriel.linkSystemLibrary("ws2_32", .{});
    } else if (target.result.os.tag == .macos) {
        // AppKit + WebKit through the Objective-C runtime (zig-objc).
        if (b.lazyDependency("objc", .{ .target = target, .optimize = optimize })) |objc| {
            oriel.addImport("objc", objc.module("objc"));
        }
        oriel.linkFramework("AppKit", .{});
        oriel.linkFramework("WebKit", .{});
    }

    if (features.tray or (target.result.os.tag == .windows and features.clipboard)) {
        const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
        oriel.addImport("zigimg", zigimg.module("zigimg"));
    }
    if (features.media_server) {
        const httpz = b.dependency("httpz", .{ .target = target, .optimize = optimize });
        oriel.addImport("httpz", if (target.result.os.tag == .windows)
            patchedHttpz(b, httpz, target, optimize)
        else
            httpz.module("httpz"));
    }
    if (features.sql) {
        const sqlite = b.dependency("sqlite", .{});
        oriel.addIncludePath(sqlite.path("."));
        oriel.addCSourceFile(.{
            .file = sqlite.path("sqlite3.c"),
            .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_DQS=0", "-DSQLITE_OMIT_DEPRECATED" },
        });
    }
    if (features.sqlite_vec) {
        if (b.lazyDependency("sqlite_vec", .{})) |sqlite_vec| {
            oriel.addIncludePath(sqlite_vec.path("."));
            oriel.addCSourceFile(.{
                .file = sqlite_vec.path("sqlite-vec.c"),
                .flags = &.{ "-DSQLITE_CORE", "-DSQLITE_VEC_STATIC" },
            });
        }
    }
    const cuda = cudaOptions(b, target);
    if (cuda != null and !features.llama and !features.whisper) fatal("-Dggml_cuda needs -Dllama or -Dwhisper", .{});
    if (features.llama or features.whisper) {
        ggml.addGgml(b, oriel, features, cuda);
    }
    if (is_linux and (features.input or features.clipboard)) {
        const scanner = Scanner.create(b, .{});
        scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
        scanner.addCustomProtocol(b.path("protocols/wlr-data-control-unstable-v1.xml"));
        scanner.addCustomProtocol(b.path("protocols/virtual-keyboard-unstable-v1.xml"));
        scanner.generate("wl_seat", 7);
        scanner.generate("ext_data_control_manager_v1", 1);
        scanner.generate("zwlr_data_control_manager_v1", 2);
        scanner.generate("zwp_virtual_keyboard_manager_v1", 1);
        oriel.addImport("wayland", b.createModule(.{
            .root_source_file = scanner.result,
            .target = target,
            .optimize = optimize,
        }));
        oriel.linkSystemLibrary("wayland-client", .{});
    }
    if (is_linux and features.audio_capture) {
        oriel.linkSystemLibrary("libpulse", .{});
        oriel.linkSystemLibrary("libpulse-simple", .{});
    }
    if (is_linux and features.input) {
        oriel.linkSystemLibrary("xkbcommon", .{});
        oriel.linkSystemLibrary("xtst", .{});
    }
    if (is_linux and (features.global_shortcut or features.input)) {
        oriel.linkSystemLibrary("x11", .{});
    }
    return oriel;
}

/// http.zig for Windows targets: the same sources with the Winsock shutdown
/// fixes of tools/patch_httpz.zig applied, wired like http.zig's own
/// build.zig wires its module (metrics, websocket, `build` options).
fn patchedHttpz(
    b: *std.Build,
    httpz: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const tool = b.addExecutable(.{
        .name = "patch_httpz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch_httpz.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addDirectoryArg(httpz.path("src"));
    const src = run.addOutputDirectoryArg("httpz-src");

    const dep_opts = .{ .target = target, .optimize = optimize };
    const module = b.createModule(.{
        .root_source_file = src.path(b, "httpz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "metrics", .module = httpz.builder.dependency("metrics", dep_opts).module("metrics") },
            .{ .name = "websocket", .module = httpz.builder.dependency("websocket", dep_opts).module("websocket") },
        },
    });
    const options = b.addOptions();
    options.addOption(bool, "httpz_blocking", false);
    module.addOptions("build", options);
    return module;
}

// ---------------------------------------------------------------------------
// App build helper (called from an app's build.zig)
// ---------------------------------------------------------------------------

pub const PackageOptions = @import("build/package.zig").PackageOptions;

pub const AppOptions = struct {
    /// Executable name.
    name: []const u8,
    /// The app's main.zig. It can `@import("oriel")` and `@import("oriel_app")`
    /// (build-time config: `assets`, `dev`, `types_path`).
    root_source_file: std.Build.LazyPath,
    frontend: Frontend,
    /// Application packaging metadata (for deb, rpm, AppImage, NSIS setup.exe, desktop-entry).
    package: ?PackageOptions = null,
    /// Optional base64-encoded Ed25519 public key for the updater.
    update_public_key: ?[]const u8 = null,
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
    types_path: ?[]const u8 = "src/oriel.ts",

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

/// Add `keygen` and `sign-update` build steps to `b`.
/// Idempotent: a second call (e.g. from a second `addApp`) is a no-op.
pub fn addUpdaterSteps(b: *std.Build, update_tool: *std.Build.Step.Compile) void {
    if (b.top_level_steps.get("keygen") != null) return;
    const run_keygen = b.addRunArtifact(update_tool);
    run_keygen.addArg("keygen");
    if (b.args) |args| run_keygen.addArgs(args);
    b.step("keygen", "Generate an Ed25519 keypair for update signing").dependOn(&run_keygen.step);

    const run_sign = b.addRunArtifact(update_tool);
    run_sign.addArg("sign-update");
    if (b.args) |args| run_sign.addArgs(args);
    b.step("sign-update", "Sign an update artifact and generate manifest JSON").dependOn(&run_sign.step);
}

/// Add a oriel app to `b` with these steps:
///   zig build          build the frontend, embed it, install the app
///   zig build run      run the production build
///   zig build dev      run against the dev server (hot reload)
///   zig build types    regenerate the frontend's TypeScript command types
///   zig build check    type-check the app without building binaries
/// plus the packaging steps (`package`, `package-<format>`, `desktop-entry`).
/// Calling it more than once is allowed: top-level steps are shared, so
/// e.g. `zig build run` or `zig build package` acts on every app added.
pub fn addApp(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) App {
    addUpdaterSteps(b, oriel_dep.artifact("update_tool"));

    const oriel = oriel_dep.module("oriel");
    const target = oriel.resolved_target.?;
    const optimize = oriel.optimize.?;
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
        cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
        break :blk addExe(b, oriel, target, dev_optimize, b.fmt("{s}-dev", .{options.name}), options.root_source_file, appConfigModule(b, oriel, cfg, null));
    } else null;

    // Generated TypeScript types, written by the dev build (no frontend needed).
    var types_step: ?*std.Build.Step = null;
    if (fe.types_path) |types_path| {
        const can_run = target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch;
        if (can_run) {
            const gen_exe = dev_exe orelse @panic("TypeScript generation needs a dev build (frontend.dev)");
            const gen = b.addRunArtifact(gen_exe);
            gen.addArgs(&.{ "--emit-types", b.pathJoin(&.{ fe_dir, types_path }) });
            gen.has_side_effects = true;
            types_step = &gen.step;
            @import("build/package.zig").getOrCreateStep(b, "types", "Generate TypeScript types for the Zig commands").dependOn(&gen.step);
        } else {
            const types_step_named = @import("build/package.zig").getOrCreateStep(b, "types", "Generate TypeScript types for the Zig commands");
            const fail = b.addFail("Cannot generate TypeScript types when cross-compiling; run `zig build types` natively on the host.");
            types_step_named.dependOn(&fail.step);
        }
    }

    // Production: build the frontend, embed dist/, compile.
    const embed = b.addRunArtifact(oriel_dep.artifact("embed_assets"));
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
    prod_cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
    const exe = addExe(b, oriel, target, prod_optimize, options.name, options.root_source_file, appConfigModule(b, oriel, prod_cfg, assets_dir.path(b, "assets.zig")));
    b.installArtifact(exe);

    // -Dggml_cuda: ship libggml-cuda.so next to the executable. It resolves
    // ggml's symbols from the executable, so those must be exported.
    if (oriel_dep.builder.named_lazy_paths.get("libggml-cuda")) |cuda_lib| {
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(cuda_lib, .bin, "libggml-cuda.so").step);
        exe.rdynamic = true;
        if (dev_exe) |d| d.rdynamic = true;
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    @import("build/package.zig").getOrCreateStep(b, "run", "Run the production build").dependOn(&run.step);

    if (dev_exe) |d| {
        const install_dev = b.addInstallArtifact(d, .{});
        @import("build/package.zig").getOrCreateStep(b, "build-dev", "Build development executable").dependOn(&install_dev.step);

        const runner = b.addRunArtifact(oriel_dep.artifact("dev_runner"));
        runner.addArgs(&.{
            b.fmt("--zig={s}", .{b.graph.zig_exe}),
            b.fmt("--project-dir={s}", .{b.build_root.path orelse "."}),
            b.fmt("--watch-dir={s}", .{b.pathJoin(&.{ b.build_root.path orelse ".", "src" })}),
            b.fmt("--frontend-dir={s}", .{fe_dir}),
            b.fmt("--app-bin={s}", .{b.getInstallPath(.bin, d.name)}),
        });
        // This script runs in the build runner, a child of the `zig` process.
        // A SIGTERM/SIGKILL to `zig` alone leaves the build runner (and so
        // dev_runner's direct parent) alive, so dev_runner watches `zig` itself.
        if (@import("builtin").os.tag == .linux) {
            runner.addArg(b.fmt("--watch-pid={d}", .{std.os.linux.getppid()}));
        }

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

        @import("build/package.zig").getOrCreateStep(b, "dev", "Run against the frontend dev server (hot reload & Zig reload)").dependOn(&runner.step);
    }

    // Type-check only (`zig build check`, `oriel check`): built with a dev
    // configuration so no frontend build or embedded assets are needed, and
    // nothing requests the binary, so Zig skips codegen and linking. Apps
    // without dev mode get the default dev settings (the URL is checked at
    // comptime, so it must be a real one).
    const check_dev = fe.dev orelse Frontend.Dev{};
    const check_cfg = b.addOptions();
    check_cfg.addOption(bool, "is_dev", true);
    check_cfg.addOption([]const u8, "dev_url", check_dev.url);
    check_cfg.addOption([]const []const u8, "dev_command", check_dev.command);
    check_cfg.addOption([]const u8, "frontend_dir", fe_dir);
    check_cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
    const check_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-check", .{options.name}), options.root_source_file, appConfigModule(b, oriel, check_cfg, null));
    @import("build/package.zig").getOrCreateStep(b, "check", "Type-check the app (no binaries)").dependOn(&check_exe.step);

    @import("build/package.zig").addPackageSteps(b, oriel_dep, options, exe, dev_exe);

    return .{ .exe = exe, .dev_exe = dev_exe };
}

/// The `oriel_app` module: build-time config for the app's main.zig.
fn appConfigModule(
    b: *std.Build,
    oriel: *std.Build.Module,
    cfg: *std.Build.Step.Options,
    assets: ?std.Build.LazyPath,
) *std.Build.Module {
    const files = b.addWriteFiles();
    const root = files.add("oriel_app.zig",
        \\const oriel = @import("oriel");
        \\const cfg = @import("cfg");
        \\
        \\/// Embedded frontend files (empty in dev builds).
        \\pub const assets: []const oriel.App.Asset = if (cfg.is_dev) &.{} else @import("assets").files;
        \\
        \\/// Dev-server settings (null in production builds).
        \\pub const dev: ?oriel.App.Dev = if (cfg.is_dev) .{
        \\    .url = cfg.dev_url,
        \\    .command = cfg.dev_command,
        \\    .cwd = cfg.frontend_dir,
        \\} else null;
        \\
        \\/// Base64-encoded Ed25519 public key for verifying updates.
        \\pub const update_public_key: ?[]const u8 = cfg.update_public_key;
        \\
    );
    const mod = b.createModule(.{ .root_source_file = root });
    mod.addImport("oriel", oriel);
    mod.addOptions("cfg", cfg);
    if (assets) |a| {
        const assets_mod = b.createModule(.{ .root_source_file = a });
        assets_mod.addImport("oriel", oriel);
        mod.addImport("assets", assets_mod);
    }
    return mod;
}

fn addExe(
    b: *std.Build,
    oriel: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    app_config: *std.Build.Module,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = root_source_file,
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "oriel", .module = oriel },
                .{ .name = "oriel_app", .module = app_config },
            },
        }),
        // See the note on the test step: LLD is required on GCC 16 systems.
        .use_llvm = true,
        .use_lld = useLld(target),
    });
    if (target.result.os.tag == .windows) {
        exe.subsystem = .Windows;
    }
    return exe;
}

/// LLD for ELF and COFF (see the note on the test step); LLD has no Mach-O
/// support in Zig, so macOS uses Zig's own linker.
fn useLld(target: std.Build.ResolvedTarget) bool {
    return target.result.ofmt != .macho;
}

fn pathExists(b: *std.Build, path: []const u8) bool {
    std.Io.Dir.cwd().access(b.graph.io, path, .{}) catch return false;
    return true;
}
