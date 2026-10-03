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
const android_build = @import("build/android.zig");
const ios_build = @import("build/ios.zig");

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
    /// llama.cpp's multimodal library (mtmd): images (and audio) for vision
    /// models with their projector (mmproj GGUF). Needs `llama`.
    llama_mtmd: bool,
    whisper: bool,
    audio_capture: bool,
    /// Linux/Wayland: overlay windows as layer surfaces (gtk4-layer-shell).
    layer_shell: bool,
    /// Experimental: draw the page with native views instead of a WebView
    /// (QuickJS-ng + Yoga; Linux, Windows and Android so far). docs/native-renderer.md
    native_ui: bool,

    /// Modules that have no Android backend: off by default for Android
    /// targets. Enabled, they build as stubs with the same API (their
    /// selectors explain why), so one app source builds for every platform.
    const unavailable_on_android = [_][]const u8{ "tray", "updater", "menu", "input", "media_server", "layer_shell" };
    /// The same for iOS (docs/ios.md).
    const unavailable_on_ios = [_][]const u8{ "tray", "updater", "menu", "global_shortcut", "input", "media_server", "layer_shell", "fs_watch" };

    fn fromOptions(b: *std.Build, target: std.Build.ResolvedTarget) Features {
        // Every module and plugin builds for Linux, Windows and macOS; the
        // native dependencies are opt-in everywhere.
        const android = target.result.abi.isAndroid();
        const ios = target.result.os.tag == .ios;
        var f: Features = undefined;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            const is_native = comptime (std.mem.eql(u8, field.name, "sqlite_vec") or
                std.mem.eql(u8, field.name, "llama") or
                std.mem.eql(u8, field.name, "llama_mtmd") or
                std.mem.eql(u8, field.name, "whisper") or
                std.mem.eql(u8, field.name, "audio_capture") or
                std.mem.eql(u8, field.name, "layer_shell") or
                std.mem.eql(u8, field.name, "native_ui"));
            // deep_link is opt-in (default off), like the native dependencies.
            const is_deep_link = comptime std.mem.eql(u8, field.name, "deep_link");
            const opt = b.option(bool, field.name, "Enable the " ++ field.name ++ " module");
            const android_off = comptime for (unavailable_on_android) |n| {
                if (std.mem.eql(u8, n, field.name)) break true;
            } else false;
            const ios_off = comptime for (unavailable_on_ios) |n| {
                if (std.mem.eql(u8, n, field.name)) break true;
            } else false;
            if (ios and ios_off and opt == true) fatal("-D" ++ field.name ++ " is not available on iOS (see docs/ios.md)", .{});
            @field(f, field.name) = opt orelse (!is_native and !is_deep_link and !(android and android_off) and !(ios and ios_off));
        }
        // gtk4-layer-shell is a Wayland thing: asked for on Android, it's off.
        if (android) f.layer_shell = false;

        if (f.native_ui and !(target.result.os.tag == .linux or target.result.os.tag == .windows or target.result.os.tag == .macos or target.result.os.tag == .ios)) {
            fatal("-Dnative_ui is experimental: Linux, Windows, macOS, Android and iOS only so far (docs/native-renderer.md)", .{});
        }
        if (f.llama_mtmd and !f.llama) {
            fatal("llama_mtmd requires llama (-Dllama)", .{});
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
            .imports = &.{.{ .name = "csp", .module = b.createModule(.{ .root_source_file = b.path("src/core/csp.zig") }) }},
        }),
    });
    b.installArtifact(embed_assets);

    // Host tool used by `addApp` with -Dnative_ui: the frontend's modules as
    // QuickJS bytecode, embedded beside them (tools/qjs_modules.zig): the
    // first window doesn't parse and compile them. Built for the build
    // machine from the same QuickJS source as the engine (no sysroot or
    // target settings: see addNativeUi's qjs_bytecode).
    {
        const qjs = b.path("src/native_ui/vendor/quickjs-ng");
        const qjs_modules = b.addExecutable(.{
            .name = "qjs_modules",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/qjs_modules.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseFast,
                .link_libc = true,
            }),
        });
        qjs_modules.root_module.addIncludePath(qjs);
        qjs_modules.root_module.addCSourceFiles(.{
            .root = qjs,
            .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
            .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-O2", "-fno-sanitize=undefined", "-funsigned-char", "-fwrapv" },
        });
        qjs_modules.root_module.addCSourceFile(.{ .file = b.path("tools/qjs_modules.c"), .flags = &.{ "-std=gnu11", "-O2", "-fno-sanitize=undefined" } });
        // The runtime's sheet parser (src/native_ui/js/build.mjs), for the
        // app's .css files.
        const sheet_files = b.addWriteFiles();
        _ = sheet_files.addCopyFile(b.path("src/native_ui/sheet-compiler.js"), "sheet-compiler.js");
        const sheet_src = sheet_files.add("sheet_compiler.zig",
            \\//! src/native_ui/sheet-compiler.js, for tools/qjs_modules.zig.
            \\pub const source = @embedFile("sheet-compiler.js");
            \\
        );
        qjs_modules.root_module.addAnonymousImport("sheet_compiler", .{ .root_source_file = sheet_src });
        b.installArtifact(qjs_modules);
    }

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
    // `zig build winget -- <args>`: WinGet manifests (the release's oriel CLI).
    const run_winget = b.addRunArtifact(package_tool);
    run_winget.addArg("package-winget");
    if (b.args) |args| run_winget.addArgs(args);
    b.step("winget", "Write WinGet manifests (package_tool package-winget; args after --)").dependOn(&run_winget.step);

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

    const is_android = target.result.abi.isAndroid();
    const is_linux = target.result.os.tag == .linux and !is_android;
    // Unit tests run natively on Linux, macOS and Windows. Android targets
    // are type-checked only (`zig build check -Dtarget=aarch64-linux-android`).
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
    var dom_js_test: ?*std.Build.Step = null;
    // The native DOM against linkedom, outside the app (docs/native-dom.md):
    // `zig build dom-bench -Doptimize=ReleaseFast`, then
    // zig-out/bin/dom_bench tools/dom_bench/bench.js [linkedom bundle].
    {
        const qjs = b.path("src/native_ui/vendor/quickjs-ng");
        const dom_lib = b.addLibrary(.{
            .name = "nui_dom",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/native_ui/dom/capi.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const dom_bench = b.addExecutable(.{
            .name = "dom_bench",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
            .use_llvm = true,
            .use_lld = useLld(target),
        });
        dom_bench.root_module.addIncludePath(qjs);
        dom_bench.root_module.addIncludePath(b.path("src/native_ui/dom"));
        const qflags: []const []const u8 = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-O2", "-fno-sanitize=undefined", "-funsigned-char", "-fwrapv" };
        dom_bench.root_module.addCSourceFiles(.{ .root = qjs, .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" }, .flags = qflags });
        dom_bench.root_module.addCSourceFile(.{ .file = b.path("src/native_ui/dom/dom_qjs.c"), .flags = &.{ "-std=gnu11", "-O2", "-fno-sanitize=undefined" } });
        dom_bench.root_module.addCSourceFile(.{ .file = b.path("tools/dom_bench/main.c"), .flags = &.{ "-std=gnu11", "-O2" } });
        dom_bench.root_module.linkLibrary(dom_lib);
        const dom_bench_step = b.step("dom-bench", "Build the native DOM benchmark (tools/dom_bench)");
        dom_bench_step.dependOn(&b.addInstallArtifact(dom_bench, .{}).step);
        // The store's own tests.
        const dom_tests = b.addTest(.{
            .root_module = b.createModule(.{ .root_source_file = b.path("src/native_ui/dom/tests.zig"), .target = target, .optimize = optimize }),
            .use_llvm = true,
            .use_lld = useLld(target),
        });
        const dom_test_step = b.step("dom-test", "Run the native DOM store's tests");
        dom_test_step.dependOn(&b.addRunArtifact(dom_tests).step);
        // The bindings with QuickJS: wrapper identity and weak references.
        const js_test = b.addRunArtifact(dom_bench);
        js_test.addFileArg(b.path("tools/dom_bench/wrappers.test.js"));
        // C stdio's text mode writes CRLF on Windows.
        js_test.expectStdOutEqual(if (target.result.os.tag == .windows) "wrappers: ok\r\n" else "wrappers: ok\n");
        const dom_js_test_step = b.step("dom-js-test", "Run the native DOM's QuickJS tests (tools/dom_bench)");
        dom_js_test_step.dependOn(&js_test.step);
        dom_js_test = &js_test.step;
    }

    const test_step = b.step("test", "Run unit tests");
    if (runs_tests) {
        test_step.dependOn(&b.addRunArtifact(tests).step);
        if (dom_js_test) |t| test_step.dependOn(t);
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
        const check_oriel = b.addTest(.{ .root_module = oriel });
        // iOS: the SDK's libc headers for the C code (SQLite), when there is an SDK.
        if (target.result.os.tag == .ios) ios_build.configure(b, check_oriel);
        check_step.dependOn(&check_oriel.step);
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
    // Not for Android or iOS: the host tools never run on a phone.
    if (!is_android and target.result.os.tag != .ios) for (host_tools) |tool| {
        check_step.dependOn(&b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(tool[0]),
            .target = target,
            .optimize = optimize,
            .imports = tool[1],
        }) }).step);
    };

    // The CLI is part of Oriel's own build only: apps that depend on Oriel
    // never build it (and don't pay for the `git` call below).
    // Not for Android targets: the CLI runs on the development machine.
    if (b.pkg_hash.len == 0 and !is_android and target.result.os.tag != .ios) addCli(b, target, optimize, test_step, check_step);
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
    // distro (the CLI needs no libc anyway). The CLI is a desktop tool: an
    // Android target builds it for Linux on the same CPU.
    var query = target.query;
    if (target.result.os.tag == .linux) {
        query.abi = .musl;
        query.android_api_level = null;
    }
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
    if (target.result.abi.isAndroid()) {
        // glslc from the NDK (shader-tools), vulkan.hpp from Vulkan-Headers,
        // spirv/unified1/spirv.hpp from SPIRV-Headers.
        // The NDK's tools are x86_64 (universal on macOS): on another Linux
        // host (an ARM Chromebook's Linux) they don't run, so glslc on PATH.
        const host = b.graph.host.result;
        const ndk_runs = host.os.tag != .linux or host.cpu.arch == .x86_64;
        const ndk_glslc: ?[]const u8 = if (!ndk_runs) null else if (android_build.ndk(b)) |ndk| b.pathJoin(&.{ ndk, "shader-tools", android_build.hostTag(b), if (host.os.tag == .windows) "glslc.exe" else "glslc" }) else null;
        const headers = b.lazyDependency("vulkan_headers", .{});
        const spirv = b.lazyDependency("spirv_headers", .{});
        if (headers == null or spirv == null) return null;
        return .{
            .glslc = glslc orelse ndk_glslc orelse "glslc",
            .include = include,
            .include_paths = b.allocator.dupe(std.Build.LazyPath, &.{ headers.?.path("include"), spirv.?.path("include") }) catch @panic("OOM"),
        };
    }
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
    // -Dnative_ui_prof: the native renderer logs each stage's time
    // (src/native_ui/prof.zig); compiled out without it.
    const native_ui_prof = b.option(bool, "native_ui_prof", "Log the native renderer's stage timings (src/native_ui/prof.zig)") orelse false;
    options.addOption(bool, "native_ui_prof", native_ui_prof);
    // The native renderer's DOM: the native one (src/native_ui/dom,
    // docs/native-dom.md) by default; -Dnative_dom=false for linkedom (to
    // compare, or as a fallback).
    const native_dom = features.native_ui and (b.option(bool, "native_dom", "With -Dnative_ui: the native DOM (default), or linkedom when false (docs/native-dom.md)") orelse true);
    options.addOption(bool, "native_dom", native_dom);

    const is_android = target.result.abi.isAndroid();
    // Desktop Linux: GTK, WebKitGTK, PulseAudio, Wayland and X11. Android is
    // Linux to Zig, but has none of them.
    const is_linux = target.result.os.tag == .linux and !is_android;

    const oriel = b.addModule("oriel", .{
        .root_source_file = b.path("src/oriel.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        // Android: the app is a shared library (liboriel.so) loaded by the JVM.
        .pic = if (is_android) true else null,
    });
    oriel.addOptions("build_options", options);

    // gtk4-layer-shell (-Dlayer_shell) isn't linked: it's loaded at runtime
    // when installed (src/platform/linux/overlay.zig, preloadLayerShell), so
    // the app also runs where it isn't packaged (Ubuntu 24.04).
    if (is_linux) {
        // Lazy: only desktop Linux needs the GNOME bindings, so Android,
        // macOS and Windows builds don't fetch them.
        if (b.lazyDependency("gobject", .{ .target = target, .optimize = optimize })) |gobject| {
            oriel.addImport("glib", gobject.module("glib2"));
            oriel.addImport("gobject", gobject.module("gobject2"));
            oriel.addImport("gio", gobject.module("gio2"));
            oriel.addImport("gdk", gobject.module("gdk4"));
            oriel.addImport("gtk", gobject.module("gtk4"));
            oriel.addImport("webkit", gobject.module("webkit6"));
            oriel.addImport("jsc", gobject.module("javascriptcore6"));
            oriel.addImport("soup", gobject.module("soup3"));
        }
    } else if (is_android) {
        // The NDK's libraries: logcat, ALooper (the main-thread dispatch),
        // AAudio. Without an NDK only `zig build check` works (no linking).
        if (android_build.ndk(b)) |ndk| {
            android_build.addSysroot(b, oriel, ndk, target);
            oriel.linkSystemLibrary("log", .{});
            oriel.linkSystemLibrary("android", .{});
            if (features.audio_capture) oriel.linkSystemLibrary("aaudio", .{});
        }
    } else if (target.result.os.tag == .ios) {
        // UIKit + WebKit through the Objective-C runtime (src/platform/apple/
        // objc.zig: no SDK headers, so `zig build check -Dtarget=aarch64-ios`
        // works anywhere). Linking needs the iOS SDK (build/ios.zig).
        if (ios_build.sdk(b)) |sdk| ios_build.link(oriel, sdk, features.audio_capture);
    } else if (target.result.os.tag == .windows) {
        oriel.linkSystemLibrary("user32", .{});
        oriel.linkSystemLibrary("gdi32", .{});
        oriel.linkSystemLibrary("ole32", .{});
        oriel.linkSystemLibrary("shell32", .{});
        oriel.linkSystemLibrary("advapi32", .{});
        oriel.linkSystemLibrary("shlwapi", .{});
        oriel.linkSystemLibrary("ws2_32", .{});
        oriel.linkSystemLibrary("dwmapi", .{});
        // -Dnative_ui: the page drawn with Direct2D and DirectWrite
        // (src/native_ui/win32.zig).
        if (features.native_ui) {
            oriel.linkSystemLibrary("d2d1", .{});
            oriel.linkSystemLibrary("dwrite", .{});
            oriel.linkSystemLibrary("windowscodecs", .{});
            // Trackbars (<input type=range>).
            oriel.linkSystemLibrary("comctl32", .{});
        }
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
            // dictation's system engine (SFSpeechRecognizer, AVAudioEngine).
            oriel.linkFramework("Speech", .{});
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
    // Lazy: apps built with -Dsql=false never download SQLite.
    if (features.sql) if (b.lazyDependency("sqlite", .{})) |sqlite| {
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
    };
    if (features.native_ui) addNativeUi(b, oriel, native_ui_prof, native_dom);
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
    // Windows and Android compile Vulkan in; ggml_gpu.load() registers it at runtime.
    options.addOption(bool, "ggml_vulkan_static", vulkan != null and (target.result.os.tag == .windows or is_android));
    const opencl: ?ggml.OpenClOptions = if (b.option(bool, "ggml_opencl", "Build the OpenCL backend for llama/whisper (Android: Adreno GPUs)") orelse false) blk: {
        if (!is_android) fatal("-Dggml_opencl is only supported on Android targets for now", .{});
        if (!features.llama and !features.whisper) fatal("-Dggml_opencl needs -Dllama or -Dwhisper", .{});
        const headers = b.lazyDependency("opencl_headers", .{}) orelse break :blk null;
        break :blk .{ .headers = headers.path(".") };
    } else null;
    options.addOption(bool, "ggml_opencl_static", opencl != null);
    if (features.llama or features.whisper) {
        // Metal: on by default for macOS and iOS devices (Apple GPUs; the
        // shader sources are embedded and compiled by ggml at startup). Off
        // for the iOS simulator, whose Metal lacks what ggml's kernels need
        // (loading a model on it ends the app; llama.cpp's and whisper.cpp's
        // own iOS examples use the CPU there too).
        const apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
        const simulator = target.result.os.tag == .ios and target.result.abi == .simulator;
        const metal = b.option(bool, "ggml_metal", "Build ggml's Metal backend for llama/whisper (macOS, iOS devices; default on, off for the simulator)") orelse (apple and !simulator);
        if (metal and !apple) fatal("-Dggml_metal needs a macOS or iOS target", .{});
        // ARM extensions for ggml's CPU code: dotprod by default on Android
        // (every arm64 phone since 2018), none elsewhere.
        const arm_default: ggml.ArmLevel = if (is_android and target.result.cpu.arch == .aarch64) .dotprod else .baseline;
        const arm = b.option(ggml.ArmLevel, "ggml_arm", "ARM extensions for ggml's CPU kernels: baseline, dotprod (Android default), i8mm") orelse arm_default;
        options.addOption(ggml.ArmLevel, "ggml_arm", if (target.result.cpu.arch == .aarch64) arm else .baseline);
        ggml.addGgml(b, oriel, features, cuda, vulkan, opencl, metal, arm);
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
    /// Android-only system entry points (see docs/android.md), declared in
    /// the generated manifest.
    android: Android = .{},
    /// iOS-only bundle settings (see docs/ios.md).
    ios: Ios = .{},

    pub const Ios = struct {
        /// UIBackgroundModes `audio`: keep capturing (audio_capture) or
        /// playing while the app is in the background.
        background_audio: bool = false,
    };

    pub const Android = struct {
        /// A Quick Settings tile with this label: taps send the system
        /// event "tile" (`oriel.android.onSystemEvent`).
        tile: ?[]const u8 = null,
        /// The Oriel keyboard, with this name in the system's keyboard list:
        /// `oriel.android.commitText` types into any app's focused field.
        input_method: ?[]const u8 = null,
    };

    pub const Isolation = struct {
        /// JavaScript setting `globalThis.__ORIEL_ISOLATION_HOOK__`.
        hook: std.Build.LazyPath,
    };
};

/// See `AppOptions.permissions`.
pub const Permissions = @import("src/core/permissions/common.zig").Declared;
const PermissionKind = @import("src/core/permissions/common.zig").Kind;

/// The declared permissions plus the ones enabled modules need.
/// A boolean option the app passed to the Oriel dependency (`.native_ui = true`).
/// -Dnative_ui: the frontend's modules compiled to QuickJS bytecode
/// (qjs_modules) and embedded with it (embed_assets' extra directory).
fn addModuleBytecode(b: *std.Build, oriel_dep: *std.Build.Dependency, embed: *std.Build.Step.Run, dist: []const u8, build_fe: ?*std.Build.Step) void {
    if (!dependencyFlag(oriel_dep, "native_ui")) return;
    const modules = b.addRunArtifact(oriel_dep.artifact("qjs_modules"));
    modules.has_side_effects = true; // dist/ is produced outside the build graph
    modules.addArg(dist);
    const out = modules.addOutputDirectoryArg("modules");
    if (build_fe) |st| modules.step.dependOn(st);
    embed.addDirectoryArg(out);
}

fn dependencyFlag(oriel_dep: *std.Build.Dependency, name: []const u8) bool {
    const opt = oriel_dep.builder.user_input_options.get(name) orelse return false;
    return switch (opt.value) {
        .flag => true,
        .scalar => |s| std.mem.eql(u8, s, "true"),
        else => false,
    };
}

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
    /// How the TypeScript is generated. `.dev_exe` builds and runs the whole
    /// development executable. `.root_decls` builds a small generator that
    /// imports the app's root file and reads `pub const oriel_api: App.Api`,
    /// or else `pub const Commands` (and `pub const Events`, if any): only the
    /// command signatures are compiled, so a production build no longer
    /// compiles the whole app a second time just for the bindings.
    types_from: TypesFrom = .dev_exe,

    pub const TypesFrom = enum { dev_exe, root_decls };

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
    if (oriel_dep.module("oriel").resolved_target.?.result.abi.isAndroid()) return addAndroidApp(b, oriel_dep, options);
    if (oriel_dep.module("oriel").resolved_target.?.result.os.tag == .ios) return addIosApp(b, oriel_dep, options);
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
        // Most of a Debug rebuild is LLVM writing debug info: without it an
        // edit rebuilds in well under the time, but crashes print no
        // symbolized stack traces.
        if (!(b.option(bool, "dev_debug_info", "Debug info in the `oriel dev` build (false: faster rebuilds, no symbolized stack traces; default true)") orelse true))
            d.root_module.strip = true;
        break :blk d;
    } else null;

    // Generated TypeScript types, written by the dev build or a small
    // generator (`frontend.types_from`); no frontend needed.
    var types_step: ?*std.Build.Step = null;
    if (fe.types_path) |types_path| {
        const can_run = target.result.os.tag == b.graph.host.result.os.tag and target.result.cpu.arch == b.graph.host.result.cpu.arch;
        if (can_run) {
            const gen_exe = switch (fe.types_from) {
                .dev_exe => dev_exe orelse @panic("TypeScript generation needs a dev build (frontend.dev)"),
                .root_decls => typesGenerator(b, oriel, target, options, fe_dir, url_schemes, permissions, app_icon),
            };
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
    var build_fe_step: ?*std.Build.Step = null;
    if (fe.build_command) |cmd| {
        const build_fe = b.addSystemCommand(cmd);
        build_fe.setCwd(.{ .cwd_relative = fe_dir });
        build_fe.has_side_effects = true;
        if (install_step) |s| build_fe.step.dependOn(s);
        if (types_step) |s| build_fe.step.dependOn(s);
        embed.step.dependOn(&build_fe.step);
        build_fe_step = &build_fe.step;
    }
    addModuleBytecode(b, oriel_dep, embed, b.pathJoin(&.{ fe_dir, fe.dist }), build_fe_step);
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
        // -Dnative_ui: Windows 8+ and Common Controls 6 for its EDIT and
        // COMBOBOX fields (src/native_ui/win32.manifest).
        if (dependencyFlag(oriel_dep, "native_ui")) {
            const manifest = oriel_dep.path("src/native_ui/win32.manifest");
            exe.win32_manifest = manifest;
            if (dev_exe) |d| d.win32_manifest = manifest;
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
        // The rebuild after an edit (`zig build build-dev`) gets the same -D
        // options as this build (-Dggml_cuda, -Ddev_debug_info, ...).
        var opts = b.user_input_options.iterator();
        while (opts.next()) |o| switch (o.value_ptr.value) {
            .flag => runner.addArg(b.fmt("--build-arg=-D{s}", .{o.key_ptr.*})),
            .scalar => |v| runner.addArg(b.fmt("--build-arg=-D{s}={s}", .{ o.key_ptr.*, v })),
            .list => |l| for (l.items) |v| runner.addArg(b.fmt("--build-arg=-D{s}={s}", .{ o.key_ptr.*, v })),
            else => {},
        };
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

/// `addApp` for an Android target (`-Dtarget=aarch64-linux-android`,
/// `x86_64-linux-android`): the app is `liboriel.so`, a shared library the
/// Kotlin runtime loads (see docs/android.md). Steps:
///   zig build              build the frontend, embed it, install
///                          zig-out/jniLibs/<abi>/liboriel.so
///   zig build android-dev  the same library loading the dev server instead
///                          (reached from the device through `adb reverse`)
///   zig build check        type-check the app (no binaries)
/// The APK itself is built by Gradle (`oriel android build`).
fn addAndroidApp(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) App {
    const oriel = oriel_dep.module("oriel");
    const target = android_build.resolveTarget(b, oriel.resolved_target.?);
    const optimize = oriel.optimize.?;
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);
    const url_schemes: []const []const u8 = options.url_schemes orelse (if (options.package) |pkg| pkg.url_schemes else &.{});
    const permissions = effectivePermissions(oriel_dep, options.permissions);
    const app_icon = options.icon orelse (if (options.package) |pkg| pkg.icon else null) orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");
    const install_dir: std.Build.InstallDir = .{ .custom = b.fmt("jniLibs/{s}", .{android_build.abiDir(target.result)}) };

    var install_step: ?*std.Build.Step = null;
    if (fe.install_command) |cmd| {
        if (!pathExists(b, b.pathJoin(&.{ fe_dir, "node_modules" }))) {
            const install = b.addSystemCommand(cmd);
            install.setCwd(.{ .cwd_relative = fe_dir });
            install_step = &install.step;
        }
    }

    // Production: the frontend built and embedded.
    const embed = b.addRunArtifact(oriel_dep.artifact("embed_assets"));
    embed.has_side_effects = true;
    embed.addArg(b.pathJoin(&.{ fe_dir, fe.dist }));
    const assets_dir = embed.addOutputDirectoryArg("assets");
    var build_fe_step: ?*std.Build.Step = null;
    if (fe.build_command) |cmd| {
        const build_fe = b.addSystemCommand(cmd);
        build_fe.setCwd(.{ .cwd_relative = fe_dir });
        build_fe.has_side_effects = true;
        if (install_step) |st| build_fe.step.dependOn(st);
        embed.step.dependOn(&build_fe.step);
        build_fe_step = &build_fe.step;
    }
    addModuleBytecode(b, oriel_dep, embed, b.pathJoin(&.{ fe_dir, fe.dist }), build_fe_step);
    const prod_cfg = b.addOptions();
    prod_cfg.addOption(bool, "is_dev", false);
    prod_cfg.addOption([]const u8, "dev_url", "");
    prod_cfg.addOption([]const []const u8, "dev_command", &.{});
    prod_cfg.addOption([]const u8, "frontend_dir", fe_dir);
    prod_cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
    prod_cfg.addOption([]const []const u8, "url_schemes", url_schemes);
    addPermissionOptions(prod_cfg, permissions);
    const lib = addAndroidLib(b, oriel, target, prod_optimize, options, appConfigModule(b, oriel, prod_cfg, assets_dir.path(b, "assets.zig"), app_icon, options.isolation));
    android_build.requireNdk(b, lib);
    b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = install_dir } }).step);

    // liboriel_exec.so: the app's `main` in a process of its own, for apps
    // that start themselves as helpers (src/platform/android/launcher.zig).
    // Named like a library so the APK installs it next to liboriel.so.
    const launcher = b.addExecutable(.{
        .name = "oriel_exec",
        // Against bionic's libc.so and libdl.so (the NDK has no static libc for apps).
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = oriel_dep.path("src/platform/android/launcher.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .link_libc = true,
            .strip = true,
            .pic = true,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    launcher.pie = true;
    android_build.configure(b, launcher, target);
    if (android_build.ndk(b)) |ndk_root| android_build.addSysroot(b, launcher.root_module, ndk_root, target);
    android_build.requireNdk(b, launcher);
    const install_launcher = b.addInstallArtifact(launcher, .{ .dest_dir = .{ .override = install_dir }, .dest_sub_path = "liboriel_exec.so" });
    b.getInstallStep().dependOn(&install_launcher.step);

    // Snapdragon NPU: libggml-hexagon.so and its DSP libraries
    // (libggml-htp-v*.so), built with Qualcomm's Hexagon SDK by llama.cpp's
    // Android build at the same commit (docs/android.md). They link against
    // ggml's libggml-base.so: a stub of that name whose only content is a
    // dependency on liboriel.so gives them Oriel's own ggml.
    if (b.option([]const u8, "ggml_hexagon_prebuilt", "Directory with libggml-hexagon.so and libggml-htp-v*.so for arm64 (Snapdragon NPU)")) |dir| {
        if (target.result.cpu.arch != .aarch64) fatal("-Dggml_hexagon_prebuilt needs an arm64 target (aarch64-linux-android)", .{});
        if (!std.fs.path.isAbsolute(dir)) fatal("-Dggml_hexagon_prebuilt needs an absolute path", .{});
        var found = false;
        var d = std.Io.Dir.cwd().openDir(b.graph.io, dir, .{ .iterate = true }) catch fatal("-Dggml_hexagon_prebuilt: cannot open {s}", .{dir});
        defer d.close(b.graph.io);
        var it = d.iterate();
        while (it.next(b.graph.io) catch null) |entry| {
            const is_backend = std.mem.eql(u8, entry.name, "libggml-hexagon.so");
            if (!is_backend and !(std.mem.startsWith(u8, entry.name, "libggml-htp-") and std.mem.endsWith(u8, entry.name, ".so"))) continue;
            found = found or is_backend;
            b.getInstallStep().dependOn(&b.addInstallFileWithDir(.{ .cwd_relative = b.pathJoin(&.{ dir, entry.name }) }, install_dir, b.dupe(entry.name)).step);
        }
        if (!found) fatal("-Dggml_hexagon_prebuilt: no libggml-hexagon.so in {s}", .{dir});
        const stub_root = b.addWriteFiles().add("ggml_base_stub.zig", "// libggml-base.so for prebuilt ggml backends: its dependency on liboriel.so is the point.\n");
        const stub = b.addLibrary(.{
            .name = "ggml-base",
            .linkage = .dynamic,
            .root_module = b.createModule(.{ .root_source_file = stub_root, .target = target, .optimize = prod_optimize, .pic = true }),
            .use_llvm = true,
            .use_lld = true,
        });
        stub.root_module.linkLibrary(lib);
        android_build.configure(b, stub, target);
        android_build.requireNdk(b, stub);
        b.getInstallStep().dependOn(&b.addInstallArtifact(stub, .{ .dest_dir = .{ .override = install_dir } }).step);
    }

    // Development: the dev server's URL (through `adb reverse` on the device).
    const dev = fe.dev orelse Frontend.Dev{};
    const dev_cfg = b.addOptions();
    dev_cfg.addOption(bool, "is_dev", true);
    dev_cfg.addOption([]const u8, "dev_url", dev.url);
    // The dev server runs on the development machine, not on the device.
    dev_cfg.addOption([]const []const u8, "dev_command", &.{});
    dev_cfg.addOption([]const u8, "frontend_dir", fe_dir);
    dev_cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
    dev_cfg.addOption([]const []const u8, "url_schemes", url_schemes);
    addPermissionOptions(dev_cfg, permissions);
    const dev_lib = addAndroidLib(b, oriel, target, dev_optimize, options, appConfigModule(b, oriel, dev_cfg, null, app_icon, options.isolation));
    android_build.requireNdk(b, dev_lib);
    @import("build/package.zig").getOrCreateStep(b, "android-dev", "Build the Android library against the dev server (zig-out/jniLibs)")
        .dependOn(&b.addInstallArtifact(dev_lib, .{ .dest_dir = .{ .override = install_dir } }).step);
    @import("build/package.zig").getOrCreateStep(b, "android-dev", "Build the Android library against the dev server (zig-out/jniLibs)")
        .dependOn(&install_launcher.step);

    // The Gradle project (android/): `zig build android-project` writes it
    // from Oriel's template (`-Dandroid_force` rewrites edited files); every
    // build refreshes its copy of the Kotlin runtime, which must match this
    // library.
    const android_vars = androidProjectVars(b, options, permissions, url_schemes);
    const package_tool = oriel_dep.artifact("package_tool");
    const run_icons = b.addRunArtifact(package_tool);
    run_icons.addArgs(&.{ "resize-icons", "--input" });
    run_icons.addFileArg(app_icon);
    run_icons.addArg("--out-dir");
    const icons_dir = run_icons.addOutputDirectoryArg("icons");
    run_icons.addArg("--brand-dir");
    run_icons.addDirectoryArg(oriel_dep.path("assets/brand"));
    const project_dir = b.pathFromRoot("android");
    const force = b.option(bool, "android_force", "android-project: rewrite files that already exist (default: false)") orelse false;
    const write_project = b.addRunArtifact(package_tool);
    write_project.addArgs(&.{ "android-project", "--template" });
    write_project.addDirectoryArg(oriel_dep.path("android/template"));
    write_project.addArgs(&.{ "--out", project_dir, "--icons" });
    write_project.addDirectoryArg(icons_dir);
    for (android_vars) |v| write_project.addArgs(&.{ "--var", v });
    if (force) write_project.addArg("--force");
    write_project.has_side_effects = true;
    @import("build/package.zig").getOrCreateStep(b, "android-project", "Write the Android (Gradle) project into android/ (-Dandroid_force rewrites edited files)").dependOn(&write_project.step);
    const sync_runtime = b.addRunArtifact(package_tool);
    sync_runtime.addArgs(&.{ "android-project", "--runtime-only", "--template" });
    sync_runtime.addDirectoryArg(oriel_dep.path("android/template"));
    sync_runtime.addArgs(&.{ "--out", project_dir });
    for (android_vars) |v| sync_runtime.addArgs(&.{ "--var", v });
    sync_runtime.has_side_effects = true;
    b.getInstallStep().dependOn(&sync_runtime.step);

    // Type-check only: nothing requests the binary.
    const check_lib = addAndroidLib(b, oriel, target, dev_optimize, options, appConfigModule(b, oriel, dev_cfg, null, app_icon, options.isolation));
    @import("build/package.zig").getOrCreateStep(b, "check", "Type-check the app (no binaries)").dependOn(&check_lib.step);

    if (fe.types_path != null) {
        const fail = b.addFail("Cannot generate TypeScript types for an Android target; run `zig build types` natively on the host.");
        @import("build/package.zig").getOrCreateStep(b, "types", "Generate TypeScript types for the Zig commands").dependOn(&fail.step);
    }
    return .{ .exe = lib, .dev_exe = dev_lib };
}

fn xmlEscape(b: *std.Build, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |ch| switch (ch) {
        '&' => out.appendSlice(b.allocator, "&amp;") catch @panic("OOM"),
        '<' => out.appendSlice(b.allocator, "&lt;") catch @panic("OOM"),
        '>' => out.appendSlice(b.allocator, "&gt;") catch @panic("OOM"),
        '"' => out.appendSlice(b.allocator, "&quot;") catch @panic("OOM"),
        else => out.append(b.allocator, ch) catch @panic("OOM"),
    };
    return out.items;
}

/// `--var key=value` arguments for the Android template (android/template).
fn androidProjectVars(b: *std.Build, options: AppOptions, permissions: Permissions, url_schemes: []const []const u8) []const []const u8 {
    const pkg = options.package orelse PackageOptions{};
    const app_id = pkg.id orelse b.fmt("dev.oriel.{s}", .{options.name});
    const name = pkg.name orelse options.name;
    const version = pkg.version orelse "0.1.0";
    // versionCode from major.minor.patch: 1.2.3 -> 10203.
    var code: u32 = 0;
    var it = std.mem.splitScalar(u8, version, '.');
    for (0..3) |_| code = code * 100 + (std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0);
    if (code == 0) code = 1;

    var perms: std.ArrayList(u8) = .empty;
    const line = "    <uses-permission android:name=\"android.permission.{s}\" />\n";
    if (permissions.microphone != null) {
        perms.appendSlice(b.allocator, b.fmt(line, .{"RECORD_AUDIO"})) catch @panic("OOM");
        perms.appendSlice(b.allocator, b.fmt(line, .{"FOREGROUND_SERVICE"})) catch @panic("OOM");
        perms.appendSlice(b.allocator, b.fmt(line, .{"FOREGROUND_SERVICE_MICROPHONE"})) catch @panic("OOM");
    }
    if (permissions.camera != null) perms.appendSlice(b.allocator, b.fmt(line, .{"CAMERA"})) catch @panic("OOM");
    if (permissions.location != null) {
        perms.appendSlice(b.allocator, b.fmt(line, .{"ACCESS_COARSE_LOCATION"})) catch @panic("OOM");
        perms.appendSlice(b.allocator, b.fmt(line, .{"ACCESS_FINE_LOCATION"})) catch @panic("OOM");
    }
    if (permissions.notifications != null) perms.appendSlice(b.allocator, b.fmt(line, .{"POST_NOTIFICATIONS"})) catch @panic("OOM");

    var schemes: std.ArrayList(u8) = .empty;
    for (url_schemes) |scheme| schemes.appendSlice(b.allocator, b.fmt(
        \\            <intent-filter>
        \\                <action android:name="android.intent.action.VIEW" />
        \\                <category android:name="android.intent.category.DEFAULT" />
        \\                <category android:name="android.intent.category.BROWSABLE" />
        \\                <data android:scheme="{s}" />
        \\            </intent-filter>
        \\
    , .{scheme})) catch @panic("OOM");

    const audio_service = if (permissions.microphone != null)
        \\        <service
        \\            android:name="dev.oriel.OrielAudioService"
        \\            android:exported="false"
        \\            android:foregroundServiceType="microphone" />
        \\
        \\
    else
        "";

    var components: std.ArrayList(u8) = .empty;
    if (options.android.tile) |label| components.appendSlice(b.allocator, b.fmt(
        \\        <service
        \\            android:name="dev.oriel.OrielTileService"
        \\            android:exported="true"
        \\            android:label="{s}"
        \\            android:icon="@mipmap/ic_launcher"
        \\            android:permission="android.permission.BIND_QUICK_SETTINGS_TILE">
        \\            <intent-filter>
        \\                <action android:name="android.service.quicksettings.action.QS_TILE" />
        \\            </intent-filter>
        \\        </service>
        \\
        \\
    , .{xmlEscape(b, label)})) catch @panic("OOM");
    if (options.android.input_method) |label| components.appendSlice(b.allocator, b.fmt(
        \\        <service
        \\            android:name="dev.oriel.OrielInputMethod"
        \\            android:exported="true"
        \\            android:label="{s}"
        \\            android:permission="android.permission.BIND_INPUT_METHOD">
        \\            <intent-filter>
        \\                <action android:name="android.view.InputMethod" />
        \\            </intent-filter>
        \\            <meta-data android:name="android.view.im" android:resource="@xml/oriel_input_method" />
        \\        </service>
        \\
        \\
    , .{xmlEscape(b, label)})) catch @panic("OOM");

    // android/app to the installed libraries, relative so the project moves.
    const app_dir = b.pathFromRoot("android/app");
    const libs = b.pathJoin(&.{ b.install_prefix, "jniLibs" });
    const lib_dir = std.fs.path.relative(b.allocator, b.build_root.path orelse "/", null, app_dir, libs) catch libs;

    return b.allocator.dupe([]const u8, &.{
        b.fmt("app_id={s}", .{app_id}),
        b.fmt("name={s}", .{name}),
        b.fmt("version={s}", .{version}),
        b.fmt("version_code={d}", .{code}),
        b.fmt("lib_dir={s}", .{lib_dir}),
        b.fmt("permissions={s}", .{perms.items}),
        b.fmt("url_schemes={s}", .{schemes.items}),
        b.fmt("audio_service={s}", .{audio_service}),
        b.fmt("android_components={s}", .{components.items}),
        "width=960",
        "height=720",
        "min_width=360",
        "min_height=320",
    }) catch @panic("OOM");
}

/// The app as `liboriel.so`: a generated root that exports the JNI entry
/// point (`NativeLib.start`, which runs the app's `main`) and routes logs
/// and panics to logcat unless the app sets its own.
/// `addApp` for an iOS target (`-Dtarget=aarch64-ios`, or
/// `aarch64-ios-simulator` / `x86_64-ios-simulator`): an executable in an
/// (unsigned) `.app` bundle (see docs/ios.md). Steps:
///   zig build          build the frontend, embed it, write zig-out/ios/<Name>.app
///   zig build ios-dev  the same app loading the dev server instead
///                      (zig-out/ios-dev/<Name>.app; the device must reach
///                      the dev URL, so use the machine's LAN address)
///   zig build ios-ipa  zig-out/<Name>.ipa (Payload/<Name>.app, `zip`)
///   zig build check    type-check the app (no binaries)
/// Signing and installing are `xtool`'s (or Xcode's) job.
fn addIosApp(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) App {
    const oriel = oriel_dep.module("oriel");
    const target = ios_build.resolveTarget(b, oriel.resolved_target.?);
    const optimize = oriel.optimize.?;
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);
    const url_schemes: []const []const u8 = options.url_schemes orelse (if (options.package) |pkg| pkg.url_schemes else &.{});
    const permissions = effectivePermissions(oriel_dep, options.permissions);
    const app_icon = options.icon orelse (if (options.package) |pkg| pkg.icon else null) orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");
    const sdk = ios_build.sdk(b);
    const audio_capture = @import("build/package.zig").isFeatureEnabledDefault(oriel_dep, "audio_capture", false);

    var install_step: ?*std.Build.Step = null;
    if (fe.install_command) |cmd| {
        if (!pathExists(b, b.pathJoin(&.{ fe_dir, "node_modules" }))) {
            const install = b.addSystemCommand(cmd);
            install.setCwd(.{ .cwd_relative = fe_dir });
            install_step = &install.step;
        }
    }

    // Production: the frontend built and embedded.
    const embed = b.addRunArtifact(oriel_dep.artifact("embed_assets"));
    embed.has_side_effects = true;
    embed.addArg(b.pathJoin(&.{ fe_dir, fe.dist }));
    const assets_dir = embed.addOutputDirectoryArg("assets");
    var build_fe_step: ?*std.Build.Step = null;
    if (fe.build_command) |cmd| {
        const build_fe = b.addSystemCommand(cmd);
        build_fe.setCwd(.{ .cwd_relative = fe_dir });
        build_fe.has_side_effects = true;
        if (install_step) |st| build_fe.step.dependOn(st);
        embed.step.dependOn(&build_fe.step);
        build_fe_step = &build_fe.step;
    }
    addModuleBytecode(b, oriel_dep, embed, b.pathJoin(&.{ fe_dir, fe.dist }), build_fe_step);
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

    // Development: the dev server's URL (reached over the network).
    const dev = fe.dev orelse Frontend.Dev{};
    const dev_cfg = b.addOptions();
    dev_cfg.addOption(bool, "is_dev", true);
    // A device reaches the development machine by its LAN address; the
    // simulator shares the Mac's network, so localhost works there.
    const dev_url = b.option([]const u8, "ios_dev_url", "iOS: the dev server's URL as the device reaches it (default: frontend.dev.url)") orelse dev.url;
    dev_cfg.addOption([]const u8, "dev_url", dev_url);
    // The dev server runs on the development machine, not on the device.
    dev_cfg.addOption([]const []const u8, "dev_command", &.{});
    dev_cfg.addOption([]const u8, "frontend_dir", fe_dir);
    dev_cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
    dev_cfg.addOption([]const []const u8, "url_schemes", url_schemes);
    addPermissionOptions(dev_cfg, permissions);
    const dev_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-dev", .{options.name}), options.root_source_file, appConfigModule(b, oriel, dev_cfg, null, app_icon, options.isolation));
    for (options.imports) |imp| dev_exe.root_module.addImport(imp.name, imp.module);

    for ([_]*std.Build.Step.Compile{ exe, dev_exe }) |c| {
        if (sdk) |root| ios_build.link(c.root_module, root, audio_capture);
        ios_build.configure(b, c);
        ios_build.requireSdk(b, c);
    }

    const pkg = options.package orelse PackageOptions{};
    const display_name = pkg.name orelse options.name;
    const bundle_dir = b.fmt("{s}.app", .{display_name});
    const package_tool = oriel_dep.artifact("package_tool");
    const Bundle = struct { step: *std.Build.Step.Run, dir: std.Build.LazyPath };
    const bundles = [_]struct { *std.Build.Step.Compile, bool }{ .{ exe, false }, .{ dev_exe, true } };
    var made: [2]Bundle = undefined;
    for (bundles, 0..) |entry, idx| {
        const compile, const is_dev = entry;
        const run = b.addRunArtifact(package_tool);
        run.addArgs(&.{ "ios-app", "--out-dir" });
        const out = run.addOutputDirectoryArg("ios");
        run.addArg("--bin");
        run.addArtifactArg(compile);
        run.addArg("--icon");
        run.addFileArg(app_icon);
        run.addArgs(&.{
            "--app-id",   pkg.id orelse b.fmt("dev.oriel.{s}", .{options.name}),
            "--name",     display_name,
            "--exe-name", options.name,
            "--version",  pkg.version orelse "0.1.0",
            "--min-os",   b.fmt("{f}", .{target.result.os.version_range.semver.min}),
        });
        if (ios_build.isSimulator(target.result)) run.addArg("--simulator");
        if (options.ios.background_audio) run.addArg("--background-audio");
        if (is_dev) run.addArg("--allow-http");
        for (url_schemes) |scheme| run.addArgs(&.{ "--url-scheme", scheme });
        inline for (@typeInfo(Permissions).@"struct".fields) |f| {
            if (@field(permissions, f.name)) |reason| {
                const text = if (reason.len > 0) reason else b.fmt("{s} {s}", .{ display_name, Permissions.defaultReasonFor(f.name) });
                run.addArgs(&.{ "--permission", b.fmt("{s}={s}", .{ f.name, text }) });
            }
        }
        made[idx] = .{ .step = run, .dir = out };
    }
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = made[0].dir, .install_dir = .prefix, .install_subdir = "ios" }).step);
    @import("build/package.zig").getOrCreateStep(b, "ios-dev", "Build the iOS app against the dev server (zig-out/ios-dev)")
        .dependOn(&b.addInstallDirectory(.{ .source_dir = made[1].dir, .install_dir = .prefix, .install_subdir = "ios-dev" }).step);

    // .ipa: Payload/<Name>.app, zipped.
    const stage = b.addWriteFiles();
    _ = stage.addCopyDirectory(made[0].dir.path(b, bundle_dir), b.fmt("Payload/{s}", .{bundle_dir}), .{});
    const zip = b.addSystemCommand(&.{ "zip", "-qry" });
    zip.setCwd(stage.getDirectory());
    const ipa = zip.addOutputFileArg(b.fmt("{s}.ipa", .{display_name}));
    zip.addArg("Payload");
    @import("build/package.zig").getOrCreateStep(b, "ios-ipa", "Package the iOS app as zig-out/<Name>.ipa (unsigned)")
        .dependOn(&b.addInstallFile(ipa, b.fmt("{s}.ipa", .{display_name})).step);

    // Type-check only: nothing requests the binary.
    const check_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-check", .{options.name}), options.root_source_file, appConfigModule(b, oriel, dev_cfg, null, app_icon, options.isolation));
    for (options.imports) |imp| check_exe.root_module.addImport(imp.name, imp.module);
    // With an SDK, C dependencies (sql, whisper, ...) type-check too.
    ios_build.configure(b, check_exe);
    @import("build/package.zig").getOrCreateStep(b, "check", "Type-check the app (no binaries)").dependOn(&check_exe.step);

    if (fe.types_path != null) {
        const fail = b.addFail("Cannot generate TypeScript types for an iOS target; run `zig build types` natively on the host.");
        @import("build/package.zig").getOrCreateStep(b, "types", "Generate TypeScript types for the Zig commands").dependOn(&fail.step);
    }
    return .{ .exe = exe, .dev_exe = dev_exe };
}

fn addAndroidLib(
    b: *std.Build,
    oriel: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: AppOptions,
    app_config: *std.Build.Module,
) *std.Build.Step.Compile {
    const app_root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = optimize,
        .pic = true,
        .imports = &.{
            .{ .name = "oriel", .module = oriel },
            .{ .name = "oriel_app", .module = app_config },
        },
    });
    for (options.imports) |imp| app_root.addImport(imp.name, imp.module);
    const files = b.addWriteFiles();
    const root = files.add("oriel_android.zig",
        \\const std = @import("std");
        \\const oriel = @import("oriel");
        \\const app = @import("app_root");
        \\
        \\/// The app's options, logging to logcat unless it chose its own logFn.
        \\/// No per-thread signal stack unless the app asks for one: it is a
        \\/// 256 KiB thread-local that bionic allocates in every thread touching
        \\/// the library's TLS (the UI and binder threads too), and it only serves
        \\/// std's segfault handler, which a JNI library never installs (ART
        \\/// handles the signals).
        \\pub const std_options: std.Options = blk: {
        \\    var o: std.Options = if (@hasDecl(app, "std_options")) app.std_options else .{};
        \\    if (o.logFn == std.log.defaultLog) o.logFn = oriel.log.logFn;
        \\    if (o.signal_stack_size == (std.Options{}).signal_stack_size) o.signal_stack_size = null;
        \\    break :blk o;
        \\};
        \\
        \\pub const panic = if (@hasDecl(app, "panic")) app.panic else oriel.android.panic;
        \\
        \\comptime {
        \\    oriel.android.exportStart(app);
        \\}
        \\
    );
    const lib = b.addLibrary(.{
        .name = "oriel",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
            .pic = true,
            // Release libraries ship without debug info (5.3 -> 0.6 MB for
            // a hello world); Debug keeps it for ndk-stack and lldb.
            .strip = if (optimize == .Debug) null else true,
            .imports = &.{
                .{ .name = "oriel", .module = oriel },
                .{ .name = "app_root", .module = app_root },
            },
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    android_build.configure(b, lib, target);
    return lib;
}

/// The TypeScript generator for `frontend.types_from = .root_decls`: imports
/// the app's root file as a module and writes the bindings for its API
/// (`--emit-types <path>`, like the dev executable). Only the declarations
/// it names are analyzed, so it compiles in a fraction of the app's time.
fn typesGenerator(
    b: *std.Build,
    oriel: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    options: AppOptions,
    fe_dir: []const u8,
    url_schemes: []const []const u8,
    permissions: Permissions,
    app_icon: std.Build.LazyPath,
) *std.Build.Step.Compile {
    const dev = options.frontend.dev orelse Frontend.Dev{};
    const cfg = b.addOptions();
    cfg.addOption(bool, "is_dev", true);
    cfg.addOption([]const u8, "dev_url", dev.url);
    cfg.addOption([]const []const u8, "dev_command", dev.command);
    cfg.addOption([]const u8, "frontend_dir", fe_dir);
    cfg.addOption(?[]const u8, "update_public_key", options.update_public_key);
    cfg.addOption([]const []const u8, "url_schemes", url_schemes);
    addPermissionOptions(cfg, permissions);
    const app_root = b.createModule(.{
        .root_source_file = options.root_source_file,
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "oriel", .module = oriel },
            .{ .name = "oriel_app", .module = appConfigModule(b, oriel, cfg, null, app_icon, options.isolation) },
        },
    });
    for (options.imports) |imp| app_root.addImport(imp.name, imp.module);
    const files = b.addWriteFiles();
    const root = files.add("oriel_types.zig",
        \\const std = @import("std");
        \\const oriel = @import("oriel");
        \\const app = @import("app_root");
        \\
        \\const api: oriel.App.Api = if (@hasDecl(app, "oriel_api")) app.oriel_api else if (@hasDecl(app, "Commands")) .{
        \\    .commands = app.Commands,
        \\    .events = if (@hasDecl(app, "Events")) app.Events else struct {},
        \\} else @compileError("frontend.types_from = .root_decls: the root file declares neither `pub const oriel_api` nor `pub const Commands`");
        \\
        \\pub fn main(init: std.process.Init) !u8 {
        \\    const args = try init.minimal.args.toSlice(init.arena.allocator());
        \\    if (args.len != 3 or !std.mem.eql(u8, args[1], "--emit-types")) {
        \\        std.debug.print("usage: {s} --emit-types <output.ts>\n", .{args[0]});
        \\        return 2;
        \\    }
        \\    try oriel.writeTypes(init.io, init.gpa, api, args[2]);
        \\    return 0;
        \\}
        \\
    );
    return b.addExecutable(.{
        .name = b.fmt("{s}-types", .{options.name}),
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "oriel", .module = oriel },
                .{ .name = "app_root", .module = app_root },
            },
        }),
        // Like addExe: LLD for the GCC 16 crt1.o .sframe sections.
        .use_llvm = true,
        .use_lld = useLld(target),
    });
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

/// -Dnative_ui: QuickJS-ng (the page's JavaScript) and Yoga (flexbox
/// layout), compiled into the oriel module. docs/native-renderer.md
fn addNativeUi(b: *std.Build, oriel: *std.Build.Module, prof: bool, native_dom: bool) void {
    const no_ubsan = "-fno-sanitize=undefined"; // both rely on unspecified C behavior
    // The Apple backends draw with CoreGraphics and CoreText (apple_draw.zig).
    if (oriel.resolved_target) |t| if (t.result.os.tag == .macos or t.result.os.tag == .ios) {
        oriel.linkFramework("CoreGraphics", .{});
        oriel.linkFramework("CoreText", .{});
        oriel.linkFramework("ImageIO", .{}); // <img>
    };
    // QuickJS-ng lives in the repo (src/native_ui/vendor/quickjs-ng, see its
    // README.md): tuned for the renderer.
    {
        const qjs = b.path("src/native_ui/vendor/quickjs-ng");
        oriel.addIncludePath(qjs);
        oriel.addCSourceFiles(.{
            .root = qjs,
            .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
            .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-O2", no_ubsan, "-funsigned-char", "-fwrapv" },
        });
        // The page's `__host` and the entry points engine.zig calls.
        // -Dnative_ui_prof: `__host.prof` is true (render.js logs its stages).
        // -Dnative_dom: the shim installs the native DOM (dom_qjs.c; its Zig
        // side, dom/capi.zig, comes in through engine.zig).
        var shim_flags: std.ArrayList([]const u8) = .empty;
        shim_flags.appendSlice(b.allocator, &.{ "-std=gnu11", "-O2", no_ubsan }) catch @panic("OOM");
        if (prof) shim_flags.append(b.allocator, "-DORIEL_NUI_PROF=1") catch @panic("OOM");
        if (native_dom) shim_flags.append(b.allocator, "-DORIEL_NATIVE_DOM=1") catch @panic("OOM");
        oriel.addCSourceFile(.{ .file = b.path("src/native_ui/qjs_shim.c"), .flags = shim_flags.items });
        if (native_dom) {
            oriel.addIncludePath(b.path("src/native_ui/dom"));
            oriel.addCSourceFile(.{ .file = b.path("src/native_ui/dom/dom_qjs.c"), .flags = &.{ "-std=gnu11", "-O2", no_ubsan } });
        }

        // runtime.js as QuickJS bytecode, compiled on the build machine by
        // tools/qjs_bytecode.c (the same QuickJS): the engine loads it
        // instead of parsing and compiling the source on every window.
        const compiler = b.addExecutable(.{
            .name = "qjs_bytecode",
            .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true }),
        });
        compiler.root_module.addIncludePath(qjs);
        compiler.root_module.addCSourceFiles(.{
            .root = qjs,
            .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
            .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-O2", no_ubsan, "-funsigned-char", "-fwrapv" },
        });
        compiler.root_module.addCSourceFile(.{ .file = b.path("tools/qjs_bytecode.c"), .flags = &.{ "-std=gnu11", "-O2", no_ubsan } });
        const compile = b.addRunArtifact(compiler);
        compile.addFileArg(b.path(if (native_dom) "src/native_ui/runtime-native.js" else "src/native_ui/runtime.js"));
        const bytecode = compile.addOutputFileArg("runtime.qjsbc");
        const files = b.addWriteFiles();
        _ = files.addCopyFile(bytecode, "runtime.qjsbc");
        const module_src = files.add("runtime_bytecode.zig",
            \\//! runtime.js compiled to QuickJS bytecode (build.zig, addNativeUi).
            \\pub const data = @embedFile("runtime.qjsbc");
            \\
        );
        oriel.addAnonymousImport("runtime_bytecode", .{ .root_source_file = module_src });
    }
    if (b.lazyDependency("yoga", .{})) |yoga| {
        oriel.addIncludePath(yoga.path("."));
        oriel.addCSourceFiles(.{
            .root = yoga.path("yoga"),
            .files = &.{
                "YGConfig.cpp",           "YGEnums.cpp",         "YGNode.cpp",             "YGNodeLayout.cpp",
                "YGNodeStyle.cpp",        "YGPixelGrid.cpp",     "YGValue.cpp",            "algorithm/AbsoluteLayout.cpp",
                "algorithm/Baseline.cpp", "algorithm/Cache.cpp", "algorithm/FlexLine.cpp", "config/Config.cpp",
                "debug/AssertFatal.cpp",  "debug/Log.cpp",       "event/event.cpp",        "node/LayoutResults.cpp",
                "node/Node.cpp",
            },
            .flags = &.{ "-std=c++20", "-O2", no_ubsan, "-fno-exceptions" },
        });
        oriel.addCSourceFile(.{
            .file = patchedYogaLayout(b, yoga.path("yoga/algorithm/CalculateLayout.cpp")),
            .flags = &.{ "-std=c++20", "-O2", no_ubsan, "-fno-exceptions" },
        });
        // PixelGrid.cpp without its fmod calls, telling the tree each
        // node's unrounded box; and a setter for a node's laid-out width
        // (see the files).
        oriel.addCSourceFiles(.{
            .root = b.path("src/native_ui/yoga"),
            .files = &.{ "PixelGrid.cpp", "oriel.cpp" },
            .flags = &.{ "-std=c++20", "-O2", no_ubsan, "-fno-exceptions" },
        });
        oriel.link_libcpp = true;
    }
}

/// Yoga's CalculateLayout.cpp with its multi-line alignment (flex-wrap)
/// placing items as CSS does: an item aligned to the start of its line is
/// put after its leading margin (Yoga put it at the line's top, its margin
/// lost: a margin: 10px chip in a wrapping row sat 10 px high), and a
/// centered one is centered with its margins. The build stops if Yoga's
/// text changed (look at the fix again).
fn patchedYogaLayout(b: *std.Build, src: std.Build.LazyPath) std.Build.LazyPath {
    const io = b.graph.io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, src.getPath(b), b.allocator, .limited(1 << 22)) catch |e|
        std.debug.panic("yoga: can't read CalculateLayout.cpp: {s}", .{@errorName(e)});
    const fixes = [_][2][]const u8{
        .{
            \\              child->setLayoutPosition(
            \\                  currentLead +
            \\                      child->style().computeFlexStartPosition(
            \\                          crossAxis, direction, availableInnerWidth),
            \\                  flexStartEdge(crossAxis));
            \\              break;
            \\            }
            \\            case Align::FlexEnd: {
            ,
            \\              child->setLayoutPosition(
            \\                  currentLead +
            \\                      child->style().computeFlexStartMargin(
            \\                          crossAxis, direction, availableInnerWidth) +
            \\                      child->style().computeFlexStartPosition(
            \\                          crossAxis, direction, availableInnerWidth),
            \\                  flexStartEdge(crossAxis));
            \\              break;
            \\            }
            \\            case Align::FlexEnd: {
        },
        .{
            \\              child->setLayoutPosition(
            \\                  currentLead + (lineHeight - childHeight) / 2,
            \\                  flexStartEdge(crossAxis));
            ,
            \\              child->setLayoutPosition(
            \\                  currentLead +
            \\                      child->style().computeFlexStartMargin(
            \\                          crossAxis, direction, availableInnerWidth) +
            \\                      (lineHeight - childHeight -
            \\                       child->style().computeMarginForAxis(
            \\                           crossAxis, availableInnerWidth)) /
            \\                          2,
            \\                  flexStartEdge(crossAxis));
        },
    };
    var out: []const u8 = text;
    for (fixes) |fix| {
        if (std.mem.count(u8, out, fix[0]) != 1) std.debug.panic("yoga: CalculateLayout.cpp changed; patchedYogaLayout's fix no longer applies", .{});
        out = std.mem.replaceOwned(u8, b.allocator, out, fix[0], fix[1]) catch @panic("OOM");
    }
    const files = b.addWriteFiles();
    return files.add("CalculateLayout.cpp", out);
}
