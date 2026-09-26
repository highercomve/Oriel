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
    deep_link: bool,
    // App-specific plugins
    global_shortcut: bool,
    input: bool,
    clipboard: bool,
    // Native dependencies (DEFAULT OFF)
    sqlite_vec: bool,
    llama: bool,
    whisper: bool,
    audio_capture: bool,
    /// Linux/Wayland: overlay windows as layer surfaces (gtk4-layer-shell).
    layer_shell: bool,

    fn fromOptions(b: *std.Build) Features {
        if (b.option(bool, "llama_mtmd", "Enable multimodal mtmd support (not supported)") orelse false) {
            fatal("llama_mtmd is not supported yet (libmtmd is not built; its API is experimental upstream), see README.md", .{});
        }

        // Every module and plugin builds for Linux, Windows and macOS; the
        // native dependencies are opt-in everywhere.
        var f: Features = undefined;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            const is_native = comptime (std.mem.eql(u8, field.name, "sqlite_vec") or
                std.mem.eql(u8, field.name, "llama") or
                std.mem.eql(u8, field.name, "whisper") or
                std.mem.eql(u8, field.name, "audio_capture") or
                std.mem.eql(u8, field.name, "layer_shell"));
            // deep_link is opt-in (default off), like the native dependencies.
            const is_deep_link = comptime std.mem.eql(u8, field.name, "deep_link");
            const opt = b.option(bool, field.name, "Enable the " ++ field.name ++ " module");
            @field(f, field.name) = opt orelse (!is_native and !is_deep_link);
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
    const features = Features.fromOptions(b);

    const oriel = addOrielModule(b, target, optimize, features);

    // Host tool used by `addApp` to embed built frontends.
    const embed_assets = b.addExecutable(.{
        .name = "embed_assets",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_assets.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "csp", .module = b.createModule(.{ .root_source_file = b.path("src/core/csp.zig") }) }},
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
    // Unit tests run natively on Linux, macOS and Windows.
    const runs_tests = is_linux or target.result.os.tag == .macos or target.result.os.tag == .windows;

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

    // The deep-link queue and URL validation are pure: tested even when the
    // opt-in deep_link module is off in `oriel`.
    const deep_link_queue_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/modules/deep_link/queue.zig"),
            .target = if (runs_tests) target else b.graph.host,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .use_lld = useLld(if (runs_tests) target else b.graph.host),
    });
    if (runs_tests) test_step.dependOn(&b.addRunArtifact(deep_link_queue_tests).step);

    const dev_runner_tests = b.addTest(.{
        .root_module = dev_runner.root_module,
        .use_llvm = true,
        .use_lld = useLld(b.graph.host),
    });
    if (runs_tests) {
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
    } else {
        check_step.dependOn(&b.addTest(.{ .root_module = oriel }).step);
    }

    // The host tools run on the machine that builds the app, which may be
    // Windows: check them for the selected target too, so
    // `zig build check -Dtarget=x86_64-windows` covers their Windows paths
    // (e.g. POSIX-only file permissions in package_tool, found on a Windows host).
    const zigimg_target = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    const update_manifest_target = b.createModule(.{ .root_source_file = b.path("src/modules/update_manifest.zig") });
    const host_tools = [_]struct { []const u8, []const std.Build.Module.Import }{
        .{ "tools/dev_runner.zig", &.{} },
        .{ "tools/embed_assets.zig", &.{.{ .name = "csp", .module = b.createModule(.{ .root_source_file = b.path("src/core/csp.zig") }) }} },
        .{ "tools/package/main.zig", &.{.{ .name = "zigimg", .module = zigimg_target.module("zigimg") }} },
        .{ "tools/update_tool.zig", &.{.{ .name = "update_manifest", .module = update_manifest_target }} },
    };
    for (host_tools) |tool| {
        check_step.dependOn(&b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(tool[0]),
            .target = target,
            .optimize = optimize,
            .imports = tool[1],
        }) }).step);
    }

    // The CLI is part of Oriel's own build only: apps that depend on Oriel
    // never build it (and don't pay for the `git` call below).
    if (b.pkg_hash.len == 0) addCli(b, target, optimize, test_step, check_step);
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
    // macOS: runs on macOS 13+ and any Mac CPU, not just the building one.
    const cli_target = resolveTarget(b, b.resolveTargetQuery(query));
    const updater_core_cli = b.createModule(.{
        .root_source_file = b.path("src/updater_core.zig"),
        .target = cli_target,
        .optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe,
    });
    const package_metadata_cli = b.createModule(.{
        .root_source_file = b.path("tools/package/metadata.zig"),
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
    cli_mod.addImport("package_metadata", package_metadata_cli);
    // Release builds are stripped: the binary is what install.sh downloads.
    cli_mod.strip = cli_mod.optimize != .Debug;
    const cli = b.addExecutable(.{ .name = "oriel", .root_module = cli_mod });
    b.step("cli", "Build the oriel CLI (zig-out/bin/oriel)").dependOn(&b.addInstallArtifact(cli, .{}).step);

    const updater_core_test = b.createModule(.{
        .root_source_file = b.path("src/updater_core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const package_metadata_test = b.createModule(.{
        .root_source_file = b.path("tools/package/metadata.zig"),
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
    test_mod.addImport("package_metadata", package_metadata_test);
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

/// The ggml GPU backends built as loadable libraries (named lazy paths of the
/// Oriel dependency; installed as `<name>.so` next to the executable).
pub const gpu_backend_libraries = [_][]const u8{ "libggml-cuda", "libggml-vulkan" };

/// `-Dggml_cuda`: build the CUDA backend for llama/whisper (Linux, needs the
/// CUDA toolkit). `-Dcuda_path` defaults to $CUDA_PATH or /opt/cuda,
/// `-Dcuda_arch` to "native" (the GPUs of the build machine).
fn cudaOptions(b: *std.Build, target: std.Build.ResolvedTarget) ?ggml.CudaOptions {
    const enabled = b.option(bool, "ggml_cuda", "Build the CUDA backend for llama/whisper as libggml-cuda.so (Linux; needs the CUDA toolkit)") orelse false;
    const path = b.option([]const u8, "cuda_path", "CUDA toolkit root (default: $CUDA_PATH or /opt/cuda)");
    const arch = b.option([]const u8, "cuda_arch", "nvcc -arch value, or compute capabilities like 75,86,89,120 (default: native)");
    const static = b.option(bool, "cuda_static", "Link cuBLAS statically: needs only the NVIDIA driver at runtime (default: false)") orelse false;
    const prebuilt = b.option([]const u8, "ggml_cuda_prebuilt", "Use this libggml-cuda.so (built earlier by the same Oriel version) instead of running nvcc; implies -Dggml_cuda");
    if (!enabled and prebuilt == null) return null;
    if (prebuilt) |p| if (!std.fs.path.isAbsolute(p)) fatal("-Dggml_cuda_prebuilt needs an absolute path", .{});
    if (target.result.os.tag != .linux) fatal("-Dggml_cuda is only supported on Linux targets for now", .{});
    return .{
        .path = path orelse b.graph.environ_map.get("CUDA_PATH") orelse "/opt/cuda",
        .arch = arch orelse "native",
        .static = static,
        .prebuilt = prebuilt,
    };
}

/// `-Dggml_vulkan`: build the Vulkan backend for llama/whisper (any GPU
/// vendor). Linux: libggml-vulkan.so; needs the Vulkan headers and loader,
/// SPIRV-Headers, and `glslc` (shaderc), found on PATH or given with
/// `-Dglslc`. Windows: compiled into the executable (vulkan-1.dll is loaded
/// at runtime, CPU otherwise); glslc and the headers default to the Vulkan
/// SDK's ($VULKAN_SDK), or `-Dglslc` / `-Dvulkan_include`.
fn vulkanOptions(b: *std.Build, target: std.Build.ResolvedTarget) ?ggml.VulkanOptions {
    const enabled = b.option(bool, "ggml_vulkan", "Build the Vulkan backend for llama/whisper (Linux: libggml-vulkan.so; Windows: in the executable; needs Vulkan headers and glslc)") orelse false;
    const glslc = b.option([]const u8, "glslc", "glslc shader compiler for -Dggml_vulkan (default: glslc on PATH; Windows: $VULKAN_SDK\\Bin\\glslc.exe)");
    const include = b.option([]const u8, "vulkan_include", "Vulkan and SPIR-V headers for -Dggml_vulkan (default: system paths; Windows: $VULKAN_SDK\\Include)");
    if (!enabled) return null;
    switch (target.result.os.tag) {
        .linux => return .{ .glslc = glslc orelse "glslc", .include = include },
        .windows => {
            const sdk = b.graph.environ_map.get("VULKAN_SDK");
            if (sdk == null and (glslc == null or include == null))
                fatal("-Dggml_vulkan on Windows needs the Vulkan SDK ($VULKAN_SDK), or -Dglslc and -Dvulkan_include", .{});
            return .{
                .glslc = glslc orelse b.pathJoin(&.{ sdk.?, "Bin", "glslc.exe" }),
                .include = include orelse b.pathJoin(&.{ sdk.?, "Include" }),
            };
        },
        else => fatal("-Dggml_vulkan is only supported on Linux and Windows targets for now", .{}),
    }
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

    if (is_linux and features.layer_shell) {
        // Before GTK: gtk4-layer-shell must be linked ahead of libwayland-client.
        oriel.linkSystemLibrary("gtk4-layer-shell-0", .{});
    }
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
        oriel.linkSystemLibrary("dwmapi", .{});
    } else if (target.result.os.tag == .macos) {
        // AppKit + WebKit through the Objective-C runtime (zig-objc). Its build
        // needs the Apple SDK, so only on a Mac: cross-building the framework for
        // macOS from elsewhere is not supported, but configuring a macOS target
        // must still work (the release cross-builds the macOS CLI on Linux).
        if (b.graph.host.result.os.tag == .macos) {
            if (b.lazyDependency("objc", .{ .target = target, .optimize = optimize })) |objc| {
                oriel.addImport("objc", objc.module("objc"));
            }
        }
        oriel.linkFramework("AppKit", .{});
        oriel.linkFramework("WebKit", .{});
        // Permissions (always built): AVCaptureDevice, AXIsProcessTrusted +
        // CGPreflightScreenCaptureAccess, UNUserNotificationCenter.
        oriel.linkFramework("AVFoundation", .{});
        oriel.linkFramework("ApplicationServices", .{});
        oriel.linkFramework("UserNotifications", .{});
        if (features.fs_watch) oriel.linkFramework("CoreServices", .{}); // FSEvents
        if (features.global_shortcut) oriel.linkFramework("Carbon", .{}); // RegisterEventHotKey
        if (features.audio_capture) {
            oriel.linkFramework("CoreAudio", .{});
            oriel.linkFramework("AudioToolbox", .{});
        }
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
        // Only the headers on the include path: the tarball root also has a
        // `VERSION` file, which on case-insensitive file systems (macOS)
        // shadows C++'s <version> for every C++ source in the module (ggml).
        const sqlite_headers = b.addWriteFiles();
        _ = sqlite_headers.addCopyFile(sqlite.path("sqlite3.h"), "sqlite3.h");
        _ = sqlite_headers.addCopyFile(sqlite.path("sqlite3ext.h"), "sqlite3ext.h");
        oriel.addIncludePath(sqlite_headers.getDirectory());
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
    const vulkan = vulkanOptions(b, target);
    if (vulkan != null and !features.llama and !features.whisper) fatal("-Dggml_vulkan needs -Dllama or -Dwhisper", .{});
    // Windows compiles Vulkan in; ggml_gpu.load() registers it at runtime.
    options.addOption(bool, "ggml_vulkan_static", vulkan != null and target.result.os.tag == .windows);
    if (features.llama or features.whisper) {
        // Metal: on by default for macOS (Apple GPUs; the shader sources are
        // embedded and compiled by ggml at startup).
        const metal = b.option(bool, "ggml_metal", "Build ggml's Metal backend for llama/whisper (macOS; default on)") orelse
            (target.result.os.tag == .macos);
        if (metal and target.result.os.tag != .macos) fatal("-Dggml_metal needs a macOS target", .{});
        ggml.addGgml(b, oriel, features, cuda, vulkan, metal);
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

/// The deployment target macOS builds get when the target doesn't name a
/// macOS version (native, or `-Dtarget=aarch64-macos`): an app built on a
/// newer Mac must still run on older ones. Same as package-app's default.
pub const default_macos_min: std.SemanticVersion = .{ .major = 13, .minor = 0, .patch = 0 };

/// `target` made portable across Macs, for macOS targets only:
/// - no macOS version given: `default_macos_min` (an explicit
///   `-Dtarget=aarch64-macos.14.0` wins);
/// - a native CPU (`-mcpu native`, the default): the baseline for the
///   architecture (Apple M1 for arm64, x86-64 for Intel), so code built on a
///   newer Mac or CI runner doesn't use instructions older Macs lack
///   (an explicit `-Dcpu` wins).
/// `addApp` applies it to the executables it builds (Oriel's own module keeps
/// the target the app passed, so dependencies the app shares with Oriel
/// stay one module). Use it for an app's other executables too (e.g. a CLI
/// bundled in the `.app`):
///     const target = oriel.resolveTarget(b, b.standardTargetOptions(.{}));
/// An executable that links Apple frameworks without importing `oriel`
/// needs the SDK's framework path added itself: Zig only adds it for
/// native targets, and Oriel gets it through zig-objc.
pub fn resolveTarget(b: *std.Build, target: std.Build.ResolvedTarget) std.Build.ResolvedTarget {
    if (target.result.os.tag != .macos) return target;
    var query = target.query;
    var changed = false;
    if (query.os_version_min == null) {
        query.os_version_min = .{ .semver = default_macos_min };
        changed = true;
    }
    if (query.cpu_model == .native) {
        query.cpu_model = if (target.result.cpu.arch == .aarch64)
            .{ .explicit = &std.Target.aarch64.cpu.apple_m1 }
        else
            .baseline;
        changed = true;
    }
    return if (changed) b.resolveTargetQuery(query) else target;
}

// ---------------------------------------------------------------------------
// App build helper (called from an app's build.zig)
// ---------------------------------------------------------------------------

pub const PackageOptions = @import("build/package.zig").PackageOptions;
/// `PackageOptions.contents`: what the packages hold besides the app's executable.
pub const PackageContents = @import("build/package.zig").Contents;
/// A file in `PackageContents.files`.
pub const PackageFile = @import("build/package.zig").File;

pub const AppOptions = struct {
    /// Executable name.
    name: []const u8,
    /// The app's main.zig. It can `@import("oriel")` and `@import("oriel_app")`
    /// (build-time config: `assets`, `dev`, `types_path`).
    root_source_file: std.Build.LazyPath,
    /// Application icon (PNG format, 1024x1024 recommended).
    /// Used for window icon, Windows taskbar/exe/installer, Linux desktop entry, macOS dock/bundle.
    /// Defaults to Oriel's brand icon (`assets/brand/oriel-icon-1024.png`).
    icon: ?std.Build.LazyPath = null,
    frontend: Frontend,
    /// Application packaging metadata (for deb, rpm, AppImage, NSIS setup.exe, desktop-entry).
    package: ?PackageOptions = null,
    /// Optional base64-encoded Ed25519 public key for the updater.
    update_public_key: ?[]const u8 = null,
    /// Custom URL schemes handled by the application (e.g. &.{ "oriel-notes" }).
    /// If null and package.url_schemes is set, package.url_schemes is used.
    url_schemes: ?[]const []const u8 = null,
    /// OS permissions the app needs, each with the reason the OS shows the
    /// user ("" for a default text), e.g.
    /// `.permissions = .{ .microphone = "Dictation turns your speech into text", .accessibility = "" }`.
    /// Written into the packages (Info.plist usage keys on macOS) and passed to
    /// the app as `app.permissions` (give it to `App.Config.permissions`).
    /// Modules that need one (audio_capture) declare it themselves.
    permissions: Permissions = .{},
    /// Extra modules for the app's code (third-party packages), added to every
    /// executable addApp builds (production, dev, `zig build check`):
    /// `.imports = &.{.{ .name = "zigimg", .module = zigimg_dep.module("zigimg") }}`.
    imports: []const std.Build.Module.Import = &.{},
    /// The isolation pattern: `.isolation = .{ .hook = b.path("isolation/hook.js") }`
    /// embeds the hook and exposes it as `oriel_app.isolation`; pass that to
    /// `App.Config.security.isolation` (see `security.Isolation`).
    isolation: ?Isolation = null,

    pub const Isolation = struct {
        /// JavaScript setting `globalThis.__ORIEL_ISOLATION_HOOK__`.
        hook: std.Build.LazyPath,
    };
};

/// See `AppOptions.permissions`.
pub const Permissions = @import("src/core/permissions/common.zig").Declared;
const PermissionKind = @import("src/core/permissions/common.zig").Kind;

/// The declared permissions plus the ones enabled modules need.
fn effectivePermissions(oriel_dep: *std.Build.Dependency, declared: Permissions) Permissions {
    var p = declared;
    if (@import("build/package.zig").isFeatureEnabledDefault(oriel_dep, "audio_capture", false)) {
        if (p.microphone == null) p.microphone = "";
        if (p.system_audio == null) p.system_audio = "";
    }
    return p;
}

fn addPermissionOptions(cfg: *std.Build.Step.Options, p: Permissions) void {
    inline for (@typeInfo(PermissionKind).@"enum".fields) |f| {
        cfg.addOption(?[]const u8, "permission_" ++ f.name, @field(p, f.name));
    }
}

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

    const run_combine = b.addRunArtifact(update_tool);
    run_combine.addArg("combine-manifests");
    if (b.args) |args| run_combine.addArgs(args);
    b.step("combine-manifests", "Merge per-platform update manifests into one latest.json").dependOn(&run_combine.step);
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
    const target = resolveTarget(b, oriel.resolved_target.?);
    const optimize = oriel.optimize.?;
    // When optimize was not explicitly given on the command-line, default production to ReleaseSafe
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);
    const url_schemes: []const []const u8 = options.url_schemes orelse (if (options.package) |pkg| pkg.url_schemes else &.{});

    const permissions = effectivePermissions(oriel_dep, options.permissions);

    const app_icon = options.icon orelse (if (options.package) |pkg| pkg.icon else null) orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");

    const package_tool = oriel_dep.artifact("package_tool");
    const run_icons = b.addRunArtifact(package_tool);
    run_icons.addArg("resize-icons");
    run_icons.addArg("--input");
    run_icons.addFileArg(app_icon);
    run_icons.addArg("--out-dir");
    const icons_dir = run_icons.addOutputDirectoryArg("icons");
    run_icons.addArg("--brand-dir");
    run_icons.addDirectoryArg(oriel_dep.path("assets/brand"));

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
        cfg.addOption([]const []const u8, "url_schemes", url_schemes);
        addPermissionOptions(cfg, permissions);
        const d = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-dev", .{options.name}), options.root_source_file, appConfigModule(b, oriel, cfg, null, app_icon, options.isolation));
        for (options.imports) |imp| d.root_module.addImport(imp.name, imp.module);
        break :blk d;
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
    prod_cfg.addOption([]const []const u8, "url_schemes", url_schemes);
    addPermissionOptions(prod_cfg, permissions);
    const exe = addExe(b, oriel, target, prod_optimize, options.name, options.root_source_file, appConfigModule(b, oriel, prod_cfg, assets_dir.path(b, "assets.zig"), app_icon, options.isolation));
    for (options.imports) |imp| exe.root_module.addImport(imp.name, imp.module);
    b.installArtifact(exe);

    // Windows: embed multi-resolution .ico into executable via .rc resource.
    if (target.result.os.tag == .windows) {
        const rc_file = icons_dir.path(b, "app.rc");
        exe.root_module.addWin32ResourceFile(.{
            .file = rc_file,
            .include_paths = &.{icons_dir},
        });
        if (dev_exe) |d| {
            d.root_module.addWin32ResourceFile(.{
                .file = rc_file,
                .include_paths = &.{icons_dir},
            });
        }
    }

    // -Dggml_cuda / -Dggml_vulkan: ship libggml-cuda.so / libggml-vulkan.so
    // next to the executable. They resolve ggml's symbols from the
    // executable, so those must be exported.
    for (gpu_backend_libraries) |name| {
        const lib = oriel_dep.builder.named_lazy_paths.get(name) orelse continue;
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(lib, .bin, b.fmt("{s}.so", .{name})).step);
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
        // (Windows: no parent watch; closing the console stops everything.)
        if (@import("builtin").os.tag != .windows) {
            runner.addArg(b.fmt("--watch-pid={d}", .{std.posix.getppid()}));
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
    check_cfg.addOption([]const []const u8, "url_schemes", url_schemes);
    addPermissionOptions(check_cfg, permissions);
    const check_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-check", .{options.name}), options.root_source_file, appConfigModule(b, oriel, check_cfg, null, app_icon, options.isolation));
    for (options.imports) |imp| check_exe.root_module.addImport(imp.name, imp.module);
    @import("build/package.zig").getOrCreateStep(b, "check", "Type-check the app (no binaries)").dependOn(&check_exe.step);

    @import("build/package.zig").addPackageSteps(b, oriel_dep, options, exe, dev_exe, icons_dir, app_icon, permissions);

    return .{ .exe = exe, .dev_exe = dev_exe };
}

/// The `oriel_app` module: build-time config for the app's main.zig.
fn appConfigModule(
    b: *std.Build,
    oriel: *std.Build.Module,
    cfg: *std.Build.Step.Options,
    assets: ?std.Build.LazyPath,
    icon: std.Build.LazyPath,
    isolation: ?AppOptions.Isolation,
) *std.Build.Module {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(icon, "icon.png");
    if (isolation) |iso| _ = files.addCopyFile(iso.hook, "isolation_hook.js");
    const root = files.add("oriel_app.zig", b.fmt("{s}{s}", .{
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
        \\/// Embedded application icon (PNG bytes).
        \\pub const icon_bytes: []const u8 = @embedFile("icon.png");
        \\
        \\/// Base64-encoded Ed25519 public key for verifying updates.
        \\pub const update_public_key: ?[]const u8 = cfg.update_public_key;
        \\
        \\/// Declared URL schemes handled by the application.
        \\pub const url_schemes: []const []const u8 = cfg.url_schemes;
        \\
        \\/// Declared OS permissions (`.permissions` in build.zig, plus the ones
        \\/// enabled modules need): pass to `App.Config.permissions`.
        \\pub const permissions: oriel.permissions.Declared = .{
        \\    .microphone = cfg.permission_microphone,
        \\    .camera = cfg.permission_camera,
        \\    .screen_capture = cfg.permission_screen_capture,
        \\    .accessibility = cfg.permission_accessibility,
        \\    .location = cfg.permission_location,
        \\    .notifications = cfg.permission_notifications,
        \\    .system_audio = cfg.permission_system_audio,
        \\};
        \\
        \\/// The isolation hook (`.isolation` in build.zig): pass to
        \\/// `App.Config.security.isolation`. Null without one.
        \\
        ,
        if (isolation != null)
            "pub const isolation: ?oriel.security.Isolation = .{ .hook = @embedFile(\"isolation_hook.js\") };\n"
        else
            "pub const isolation: ?oriel.security.Isolation = null;\n",
    }));
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
