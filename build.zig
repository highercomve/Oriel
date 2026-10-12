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
const swift_build = @import("build/swift.zig");
const macos_build = @import("build/macos.zig");
const ios_entitlements = @import("build/ios_entitlements.zig");
const android_manifest = @import("build/android_manifest.zig");
const espeak_data = @import("build/espeak_data.zig");
const module_table = @import("src/core/module_table.zig");
const extension_spec = @import("src/core/extension_spec.zig");
const hooks_spec = @import("src/platform/apple/hooks_spec.zig");

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
    /// The multicast lock and LAN information; also on when the app
    /// declares `.permissions.local_network`.
    network: bool,
    /// Receiving shares and the share sheet; also on when the app declares
    /// `.share_target`.
    share: bool,
    /// Photos from the camera or the library (oriel.camera, and Android's
    /// `<input type=file accept=image/*>`); on when the app declares
    /// `.permissions.camera`.
    camera: bool,
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
    /// kokoro.cpp (text to speech): Kokoro-82M synthesis. Compiled into the
    /// shared ggml build with espeak-ng phonemization (GPL-3: the binary that
    /// links it carries espeak-ng's license, see NOTICE) and Highway SIMD.
    /// Needs `llama` or `whisper` (it shares their ggml tree).
    kokoro: bool,
    audio_capture: bool,
    /// Linux/Wayland: overlay windows as layer surfaces (gtk4-layer-shell).
    layer_shell: bool,
    /// Experimental: draw the page with native views instead of a WebView
    /// (QuickJS-ng + Yoga; Linux, Windows and Android so far). docs/native-renderer.md
    native_ui: bool,
    /// The phone's own model (`oriel.system_ai`): Gemini Nano through ML Kit
    /// on Android, Apple Foundation Models on iOS 26+. Android and iOS only.
    system_ai: bool,

    /// Resolve the flags for `target`. A module asked for where it doesn't
    /// exist (src/core/module_table.zig) resolves to off, and
    /// `oriel.<module>.available` is false: an app's flags say what it uses,
    /// once, for every target. Only on Oriel's own command line
    /// (`zig build check -Dtarget=aarch64-ios -Dtray=true`) is it an error:
    /// someone asked for something impossible.
    fn fromOptions(b: *std.Build, target: std.Build.ResolvedTarget) Features {
        const platform = module_table.platformOf(&target.result);
        // The root builder's options come from the command line; a
        // dependency's come from the app's b.dependency("oriel", .{...}).
        const command_line = b.dep_prefix.len == 0;
        var f: Features = undefined;
        var missing: std.ArrayList(u8) = .empty;
        inline for (@typeInfo(Features).@"struct".fields) |field| {
            // Every module and plugin builds for Linux, Windows and macOS;
            // the native dependencies and deep_link are opt-in everywhere.
            const opt_in = comptime (std.mem.eql(u8, field.name, "sqlite_vec") or
                std.mem.eql(u8, field.name, "llama") or
                std.mem.eql(u8, field.name, "llama_mtmd") or
                std.mem.eql(u8, field.name, "whisper") or
                std.mem.eql(u8, field.name, "kokoro") or
                std.mem.eql(u8, field.name, "audio_capture") or
                std.mem.eql(u8, field.name, "layer_shell") or
                std.mem.eql(u8, field.name, "native_ui") or
                std.mem.eql(u8, field.name, "system_ai") or
                std.mem.eql(u8, field.name, "camera") or
                std.mem.eql(u8, field.name, "deep_link"));
            // The updater is opt-in on Android: the store updates apps there.
            const android_opt_in = comptime std.mem.eql(u8, field.name, "updater");
            const opt = b.option(bool, field.name, "Enable the " ++ field.name ++ " module");
            const supported = module_table.supported(field.name, platform);
            if (!supported and opt == true) {
                if (command_line) fatal("-D" ++ field.name ++ " is not available on {s} (docs/modules.md, \"Availability\")", .{@tagName(platform)});
                missing.print(b.allocator, "{s}{s}", .{ if (missing.items.len > 0) ", " else "", field.name }) catch @panic("OOM");
            }
            @field(f, field.name) = supported and (opt orelse (!opt_in and !(android_opt_in and platform == .android)));
        }
        // One line, and only with --verbose: an unguarded use is a build
        // error naming the module anyway.
        if (missing.items.len > 0 and b.verbose) std.log.info("oriel: not available on {s}, so oriel.<module>.available = false: {s}", .{ @tagName(platform), missing.items });

        if (f.native_ui and !(target.result.os.tag == .linux or target.result.os.tag == .windows or target.result.os.tag == .macos or target.result.os.tag == .ios)) {
            fatal("-Dnative_ui is experimental: Linux, Windows, macOS, Android and iOS only so far (docs/native-renderer.md)", .{});
        }
        if (f.llama_mtmd and !f.llama) {
            fatal("llama_mtmd requires llama (-Dllama)", .{});
        }
        if (f.kokoro and !(f.llama or f.whisper)) {
            fatal("kokoro needs llama or whisper (it shares their ggml tree): -Dkokoro with -Dllama or -Dwhisper", .{});
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

    // -Dkokoro: espeak-ng's compiled runtime data (build/espeak_data.zig),
    // shipped by `addApp`; `zig build espeak-data` installs it alone.
    const tts_languages = b.option([]const u8, "tts_languages", "-Dkokoro: espeak-ng dictionaries compiled into the shipped espeak-ng-data, comma-separated (default: " ++ espeak_data.default_languages ++ ")") orelse espeak_data.default_languages;
    if (features.kokoro) if (b.lazyDependency("espeak_ng", .{})) |espeak_dep| {
        const data = espeak_data.addData(b, espeak_dep, tts_languages);
        b.step("espeak-data", "Compile espeak-ng's runtime data for -Dkokoro (zig-out/espeak-ng-data)")
            .dependOn(&b.addInstallDirectory(.{ .source_dir = data.dir, .install_dir = .prefix, .install_subdir = espeak_data.name }).step);
    };

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

        const dispatch_test = b.addExecutable(.{
            .name = "test_qjs_dispatch",
            .root_module = b.createModule(.{ .target = b.graph.host, .optimize = .ReleaseFast, .link_libc = true }),
        });
        dispatch_test.root_module.addIncludePath(qjs);
        dispatch_test.root_module.addCSourceFiles(.{
            .root = qjs,
            .files = &.{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" },
            .flags = &.{ "-std=gnu11", "-D_GNU_SOURCE", "-O2", "-fno-sanitize=undefined", "-funsigned-char", "-fwrapv" },
        });
        dispatch_test.root_module.addCSourceFile(.{
            .file = b.path("tools/test_qjs_dispatch.c"),
            .flags = &.{ "-std=gnu11", "-O2", "-UNDEBUG" },
        });
        b.step("test-native-dispatch", "Test and benchmark typed QuickJS renderer calls (POSIX host)").dependOn(&b.addRunArtifact(dispatch_test).step);
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
    // The Android manifest's generated regions (android-project), shared with
    // this build script.
    const android_manifest_mod = b.createModule(.{ .root_source_file = b.path("build/android_manifest.zig") });
    const package_tool_mod = b.createModule(.{
        .root_source_file = b.path("tools/package/main.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{
            .{ .name = "zigimg", .module = zigimg_dep.module("zigimg") },
            .{ .name = "android_manifest", .module = android_manifest_mod },
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
        const run_tests = b.addRunArtifact(tests);
        // -Dggml_cuda / -Dggml_vulkan: the tests load the GPU backend from
        // zig-out/lib (ggml_gpu.load looks in $ORIEL_GGML_LIB_DIR in tests),
        // so the GPU paths (oriel.tts's) run too.
        for (gpu_backend_libraries) |name| {
            const lib = b.named_lazy_paths.get(name) orelse continue;
            const install = b.addInstallFileWithDir(lib, .lib, b.fmt("{s}.so", .{name}));
            run_tests.step.dependOn(&install.step);
            run_tests.setEnvironmentVariable("ORIEL_GGML_LIB_DIR", b.getInstallPath(.lib, ""));
            tests.rdynamic = true;
        }
        test_step.dependOn(&run_tests.step);
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

    const module_shims_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/module_shims.zig"),
            .target = b.graph.host,
        }),
        .use_llvm = true,
        .use_lld = useLld(b.graph.host),
    });
    if (runs_tests) test_step.dependOn(&b.addRunArtifact(module_shims_tests).step);

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

    // The Android manifest's regions, as build.zig and package_tool use them.
    const android_manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/android_manifest.zig"),
            .target = if (runs_tests) target else b.graph.host,
            .optimize = optimize,
        }),
        .use_llvm = true,
        .use_lld = useLld(if (runs_tests) target else b.graph.host),
    });
    if (runs_tests) test_step.dependOn(&b.addRunArtifact(android_manifest_tests).step);

    // The swiftc command line of iOS extensions' Swift sources.
    const swift_tests = b.addTest(.{
        .root_module = b.createModule(.{ .root_source_file = b.path("build/swift.zig"), .target = b.graph.host }),
        .use_llvm = true,
        .use_lld = useLld(b.graph.host),
    });
    if (runs_tests) test_step.dependOn(&b.addRunArtifact(swift_tests).step);

    // Apple platform hooks: their selectors and declaration rules, and the
    // macOS SDK lookup (pure; the dispatcher itself needs a Mac or iOS).
    for ([_][]const u8{ "src/platform/apple/hooks_spec.zig", "build/macos.zig", "build/ios_entitlements.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{ .root_source_file = b.path(path), .target = b.graph.host }),
            .use_llvm = true,
            .use_lld = useLld(b.graph.host),
        });
        if (runs_tests) test_step.dependOn(&b.addRunArtifact(t).step);
    }

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
        for ([_]*std.Build.Module{ oriel, package_tool_mod, tool_tests.root_module, patch_httpz_tests.root_module, android_manifest_tests.root_module }) |m| {
            check_step.dependOn(&b.addTest(.{ .root_module = m }).step);
        }
    } else {
        const check_oriel = b.addTest(.{ .root_module = oriel });
        // iOS: libc headers for the C code (SQLite): the SDK's, else Zig's Darwin ones.
        if (target.result.os.tag == .ios) ios_build.configureCheck(b, check_oriel);
        if (is_android) android_build.configure(b, check_oriel, target);
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
        .{ "tools/module_shims.zig", &.{} },
        .{ "tools/embed_assets.zig", &.{.{ .name = "csp", .module = b.createModule(.{ .root_source_file = b.path("src/core/csp.zig") }) }} },
        .{ "tools/package/main.zig", &.{
            .{ .name = "zigimg", .module = zigimg_target.module("zigimg") },
            .{ .name = "android_manifest", .module = b.createModule(.{ .root_source_file = b.path("build/android_manifest.zig") }) },
        } },
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
    options.addOption(?[]const u8, "checkout_path", b.build_root.path);

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
    var feature_names: [@typeInfo(Features).@"struct".fields.len][]const u8 = undefined;
    inline for (@typeInfo(Features).@"struct".fields, 0..) |field, i| {
        options.addOption(bool, field.name, @field(features, field.name));
        feature_names[i] = field.name;
    }
    // `oriel.features` in the page lists them all (src/core/features.zig).
    options.addOption([]const []const u8, "feature_names", &feature_names);
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
    // The stand-in namespaces of modules that are off or missing on the
    // target (`oriel.<module>.available = false`), from the facades' pub
    // decls (tools/module_shims.zig).
    const module_shims = b.addRunArtifact(b.addExecutable(.{
        .name = "module_shims",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/module_shims.zig"),
            .target = b.graph.host,
        }),
    }));
    const module_shims_zig = module_shims.addOutputFileArg("module_shims.zig");
    inline for (module_table.namespaces) |n| {
        module_shims.addArg(n.name);
        module_shims.addFileArg(b.path(n.path));
    }
    oriel.addImport("module_shims", b.createModule(.{ .root_source_file = module_shims_zig }));
    // The app's extensions (`oriel.extensions`): only Oriel's own (its
    // modules built on them, `orielExtensions`) until addApp sets the table
    // it generates from AppOptions.extensions.
    oriel.addImport("oriel_extensions", b.createModule(.{
        .root_source_file = b.addWriteFiles().add("oriel_extensions.zig", extensionTableText(b, "Oriel's own build", orielExtensions(b, features), module_table.platformOf(&target.result), null)),
    }));
    // iOS and macOS platform hooks (src/platform/apple/hooks.zig): none
    // until addApp sets the table it generates from `.ios.hooks` /
    // `.macos.hooks`.
    oriel.addImport("oriel_apple_hooks", b.createModule(.{
        .root_source_file = b.addWriteFiles().add("oriel_apple_hooks.zig", appleHooksTableText(b, "Oriel's own build", &.{})),
    }));

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
            // -Dnative_ui draws every window itself: no WebView, so
            // WebKitGTK (and with it JavaScriptCore, libsoup, ICU,
            // GStreamer) is neither linked nor loaded.
            if (!features.native_ui) {
                oriel.addImport("webkit", gobject.module("webkit6"));
                oriel.addImport("jsc", gobject.module("javascriptcore6"));
                oriel.addImport("soup", gobject.module("soup3"));
            }
        }
    } else if (is_android) {
        // The NDK's libraries: logcat, ALooper (the main-thread dispatch),
        // AAudio. Without an NDK only `zig build check` works (no linking).
        if (android_build.ndk(b)) |ndk| {
            android_build.addSysroot(b, oriel, ndk, target);
            // JNI libraries allow undefined symbols: retain the NDK stubs
            // in DT_NEEDED so Android loads their implementations at launch.
            oriel.linkSystemLibrary("log", .{ .needed = true });
            oriel.linkSystemLibrary("android", .{ .needed = true });
            if (features.audio_capture) oriel.linkSystemLibrary("aaudio", .{ .needed = true });
        }
    } else if (target.result.os.tag == .ios) {
        // UIKit + WebKit through the Objective-C runtime (src/platform/apple/
        // objc.zig: no SDK headers, so `zig build check -Dtarget=aarch64-ios`
        // works anywhere). Linking needs the iOS SDK (build/ios.zig).
        if (ios_build.sdk(b, target.result)) |sdk| ios_build.link(oriel, sdk, features.audio_capture);
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
    if (cuda != null and !features.llama and !features.whisper and !features.kokoro) fatal("-Dggml_cuda needs -Dllama, -Dwhisper or -Dkokoro", .{});
    const vulkan = vulkanOptions(b, target);
    if (vulkan != null and !features.llama and !features.whisper and !features.kokoro) fatal("-Dggml_vulkan needs -Dllama, -Dwhisper or -Dkokoro", .{});
    // Windows and Android compile Vulkan in; ggml_gpu.load() registers it at runtime.
    options.addOption(bool, "ggml_vulkan_static", vulkan != null and (target.result.os.tag == .windows or is_android));
    const opencl: ?ggml.OpenClOptions = if (b.option(bool, "ggml_opencl", "Build the OpenCL backend for llama/whisper (Android: Adreno GPUs)") orelse false) blk: {
        if (!is_android) fatal("-Dggml_opencl is only supported on Android targets for now", .{});
        if (!features.llama and !features.whisper) fatal("-Dggml_opencl needs -Dllama or -Dwhisper", .{});
        const headers = b.lazyDependency("opencl_headers", .{}) orelse break :blk null;
        break :blk .{ .headers = headers.path(".") };
    } else null;
    options.addOption(bool, "ggml_opencl_static", opencl != null);
    if (features.llama or features.whisper or features.kokoro) {
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
    inline for (capability_modules) |cm| {
        if (comptime !cm.enables or !@hasField(Features, cm.module)) continue;
        if (@field(features, cm.module)) linkCapabilityModule(oriel, target, cm.module);
    }
    oriel_builds.append(b.allocator, .{ .builder = b, .features = features, .options = options, .module = oriel, .target = target }) catch @panic("OOM");
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
    /// (build-time config: `build`, for `App.Config.app`).
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
    /// Custom URL schemes handled by the application (e.g. &.{ "oriel-notes" }):
    /// declared in every package and delivered by `oriel.deep_link`.
    url_schemes: []const []const u8 = &.{},
    /// OS permissions the app needs, each with the reason the OS shows the
    /// user ("" for a default text), e.g.
    /// `.permissions = .{ .microphone = "Dictation turns your speech into text", .accessibility = "" }`.
    /// Written into the packages (Info.plist usage keys on macOS) and passed to
    /// the app in `oriel_app.build` (`App.Config.app`).
    /// Modules that need one (audio_capture) declare it themselves, and
    /// declaring a capability turns its module on (`capability_modules`:
    /// local_network → oriel.network, bluetooth → oriel.bluetooth) unless
    /// the oriel dependency's options set that module's flag.
    /// Platform declarations no kind covers go in each platform's options
    /// (`android.permissions`/`features`, `ios.usage_descriptions`,
    /// `macos.usage_descriptions`/`entitlements`, `windows.capabilities`),
    /// merged with the ones the kinds write, e.g.
    /// `.android = .{ .permissions = &.{.{ .name = "android.permission.VIBRATE" }} }`.
    /// Linux has none: nothing there declares permissions in the package.
    permissions: Permissions = .{},
    /// Extra modules for the app's code (third-party packages), added to every
    /// executable addApp builds (production, dev, `zig build check`):
    /// `.imports = &.{.{ .name = "zigimg", .module = zigimg_dep.module("zigimg") }}`.
    imports: []const std.Build.Module.Import = &.{},
    /// The isolation pattern: `.isolation = .{ .hook = b.path("isolation/hook.js") }`
    /// embeds the hook into `oriel_app.build` (`App.Config.app`; see
    /// `security.Isolation`).
    isolation: ?Isolation = null,
    /// C include directories for the app's own root module (its Zig code's
    /// `@cImport` and its C sources): the oriel module's include paths only
    /// cover the oriel module's own compilation.
    include_paths: []const std.Build.LazyPath = &.{},
    /// Android-only system entry points (see docs/android.md), declared in
    /// the generated manifest.
    android: Android = .{},
    /// iOS-only bundle settings (see docs/ios.md).
    ios: Ios = .{},
    /// macOS-only bundle settings.
    macos: Macos = .{},
    /// Windows-only package settings.
    windows: Windows = .{},
    /// Receive what other apps share (`oriel.share.onReceive`): declaring it
    /// turns on the share module. Each platform's declaration (Android intent
    /// filters, document types, ...) comes with its receive support.
    share_target: ?ShareTarget = null,
    /// oriel.camera's settings (the module is on when `.permissions.camera`
    /// is declared, or with `.camera = true` on the dependency).
    camera: Camera = .{},
    /// The app's own native code, by name, with an implementation per
    /// platform (or none): Kotlin on Android, Objective-C or Swift on iOS,
    /// Zig on the desktop. Zig calls it with `oriel.extensions.get(name)`;
    /// the page only through Zig (`oriel.extensions.expose`).
    /// docs/extensions.md
    extensions: []const Extension = &.{},

    pub const Extension = struct {
        /// Lowercase dotted words ("pantry.vision"), unique, up to 64
        /// characters; what Zig, Kotlin and the page call it.
        name: []const u8,
        android: ?AndroidExtension = null,
        ios: ?IosExtension = null,
        /// Any desktop OS, unless `linux`, `macos` or `windows` overrides it.
        desktop: ?DesktopExtension = null,
        linux: ?DesktopExtension = null,
        /// macOS: Zig (`.{ .zig = path }`, as `desktop`) or Objective-C /
        /// Swift (`.{ .objc = .{ .class = ..., .swift_sources = ... } }`,
        /// the iOS protocol and runtime). Either overrides `desktop`.
        macos: ?MacosExtension = null,
        windows: ?DesktopExtension = null,
        /// The cap on a call's input and on its reply (at most 256 MiB).
        max_bytes: usize = extension_spec.default_max_bytes,
        /// Calls running at once on the extension's workers (1..8).
        concurrency: u8 = 1,
    };

    pub const AndroidExtension = struct {
        /// The class implementing dev.oriel.OrielAppExtension, with a public
        /// zero-argument constructor ("dev.app.VisionExtension"); kept by R8.
        class: []const u8,
        /// Its Kotlin/Java files (as `android.sources`).
        sources: []const std.Build.LazyPath = &.{},
        /// Maven coordinates, merged with `android.dependencies`.
        dependencies: []const []const u8 = &.{},
        /// Files or directories shipped as APK assets under `to`.
        assets: []const Asset = &.{},
    };

    pub const IosExtension = struct {
        /// The Objective-C class (or `@objc(Name)` Swift class) conforming
        /// to OrielAppExtension (src/platform/ios/include/oriel_extension.h).
        class: []const u8,
        /// Objective-C files, compiled with `-fobjc-arc`; they can
        /// `#import "oriel_extension.h"`.
        sources: []const std.Build.LazyPath = &.{},
        /// Swift files, compiled by `swiftc` into one object (docs/extensions.md:
        /// Xcode on a Mac, or the Swift toolchain with xtool's SDK on Linux).
        swift_sources: []const std.Build.LazyPath = &.{},
        /// SDK frameworks to link ("Vision", "CoreML").
        frameworks: []const []const u8 = &.{},
        /// Frameworks newer than the app's minimum iOS: weak-linked, and
        /// only when the SDK has them (Swift sees them through
        /// `#if canImport(...)`; check the OS version before use).
        weak_frameworks: []const []const u8 = &.{},
        /// Files or directories copied into the bundle at `to` (relative to
        /// the bundle's root; `Bundle.main` finds them there). `from` is a
        /// source path (`b.path`) or a dependency's (`dep.path(...)`, e.g.
        /// a hash-pinned model archive in build.zig.zon).
        resources: []const Asset = &.{},
    };

    /// `Extension.macos`: a Zig module, or native code as on iOS.
    pub const MacosExtension = union(enum) {
        /// As `DesktopExtension.zig`.
        zig: std.Build.LazyPath,
        /// A class conforming to OrielAppExtension (oriel_extension.h), run
        /// by the same backend as on iOS. Its sources need the macOS SDK (a
        /// Mac with Xcode or the Command Line Tools); Swift raises the
        /// minimum to macOS 15.
        objc: AppleNativeExtension,
    };

    /// `MacosExtension.objc`.
    pub const AppleNativeExtension = struct {
        /// The Objective-C class (or `@objc(Name)` Swift class) conforming
        /// to OrielAppExtension, with a plain `-init`.
        class: []const u8,
        /// Objective-C files, compiled with `-fobjc-arc`; they can
        /// `#import "oriel_extension.h"`.
        sources: []const std.Build.LazyPath = &.{},
        /// Swift files, compiled by `swiftc` into one object.
        swift_sources: []const std.Build.LazyPath = &.{},
        /// SDK frameworks to link ("Vision", "CoreML").
        frameworks: []const []const u8 = &.{},
        /// Frameworks newer than the app's minimum macOS: weak-linked, and
        /// only when the SDK has them.
        weak_frameworks: []const []const u8 = &.{},
    };

    pub const DesktopExtension = struct {
        /// A Zig file: `pub fn call(ctx: *oriel.extensions.Context, method:
        /// []const u8, input: []const u8) ![]u8`, optional `pub fn
        /// onLoad(ctx) !void` and `pub fn onLifecycle(event) void`. It can
        /// import "oriel" and the app's `imports`.
        zig: std.Build.LazyPath,
    };

    /// A file or directory (`from`) placed at `to` (relative, no "..").
    pub const Asset = struct {
        from: std.Build.LazyPath,
        to: []const u8,
    };

    pub const Camera = struct {
        /// Android: images picked for `<input type="file" accept="image/*">`
        /// that the WebView can't decode (HEIC, AVIF) are transcoded to
        /// JPEG (quality 90, the long side kept or halved down to 1600 px).
        transcode: bool = true,
    };

    pub const ShareTarget = struct {
        /// MIME types; `text/plain` also means text and URL shares.
        types: []const []const u8 = &.{"*/*"},
        /// Several items at once (Android ACTION_SEND_MULTIPLE).
        multiple: bool = false,
        /// The label in the share sheet (default: the app's name).
        label: ?[]const u8 = null,
        /// Windows: also "Open with" for these extensions.
        windows_extensions: []const []const u8 = &.{},
    };

    pub const Ios = struct {
        /// UIBackgroundModes `audio`: keep capturing (audio_capture) or
        /// playing while the app is in the background.
        background_audio: bool = false,
        /// Info.plist usage keys no `.permissions` kind writes, e.g.
        /// `.{ .key = "NSMotionUsageDescription", .text = "Counts your steps" }`.
        /// A key a kind writes too takes this text.
        usage_descriptions: []const UsageDescription = &.{},
        /// Platform hooks: classes conforming to OrielPlatformHooks
        /// (src/platform/apple/include/oriel_hooks.h) that take part in
        /// Oriel's app and scene delegates and WebKit delegates. Constructed
        /// once at launch, in this order (at most 16).
        /// docs/platform-hooks.md
        hooks: []const PlatformHook = &.{},
        /// The Apple developer team ID (10 characters): the prefix of the
        /// `application-identifier` entitlement embedded in simulator
        /// builds (build/ios_entitlements.zig). Without it the identifier
        /// is `.<bundle id>`, which the simulator accepts.
        team_id: ?[]const u8 = null,
    };

    pub const Macos = struct {
        /// Info.plist usage keys no `.permissions` kind writes (as `Ios`'s).
        usage_descriptions: []const UsageDescription = &.{},
        /// Boolean hardened-runtime entitlements added to `<Name>.entitlements`
        /// (used when signing), e.g. "com.apple.security.device.bluetooth".
        entitlements: []const []const u8 = &.{},
        /// Platform hooks, as `Ios.hooks`: the app delegate, windows and
        /// WebKit delegates. Objective-C and Swift sources need the macOS
        /// SDK (a Mac with Xcode or the Command Line Tools); Swift raises
        /// the minimum to macOS 15. docs/platform-hooks.md
        hooks: []const PlatformHook = &.{},
    };

    /// An iOS or macOS platform hook (`ios.hooks`, `macos.hooks`).
    pub const PlatformHook = struct {
        /// The Objective-C class (or `@objc(Name)` Swift class) conforming
        /// to OrielPlatformHooks, with a plain `-init`. A class that is
        /// also an app extension can be listed here without sources (they
        /// come with the extension): both get one instance.
        class: []const u8,
        /// Objective-C files, compiled with `-fobjc-arc`; they can
        /// `#import "oriel_hooks.h"` (and "oriel_extension.h").
        sources: []const std.Build.LazyPath = &.{},
        /// Swift files, compiled by `swiftc` into one object, with both of
        /// Oriel's protocols visible (include/oriel_swift.h). The minimum
        /// becomes iOS 18 / macOS 15.
        swift_sources: []const std.Build.LazyPath = &.{},
        /// SDK frameworks to link ("SafariServices", "UserNotifications").
        frameworks: []const []const u8 = &.{},
    };

    /// An Info.plist usage-description key and the text the OS shows.
    /// The key ends in "UsageDescription" ([A-Za-z0-9_.~-]); the text isn't empty.
    pub const UsageDescription = struct {
        key: []const u8,
        text: []const u8,
    };

    pub const Android = struct {
        /// A Quick Settings tile with this label: taps send the system
        /// event "tile" (`oriel.android.onSystemEvent`).
        tile: ?[]const u8 = null,
        /// The Oriel keyboard, with this name in the system's keyboard list:
        /// `oriel.android.commitText` types into any app's focused field.
        input_method: ?[]const u8 = null,
        /// `<uses-permission>`s no `.permissions` kind declares, e.g.
        /// `.{ .name = "android.permission.BLUETOOTH", .max_sdk = 30 }`. One
        /// entry per name: a name a kind declares keeps that entry, but
        /// without `max_sdk` here it holds on every API level.
        permissions: []const Permission = &.{},
        /// `<uses-feature>`s, one per name (required if any declaration
        /// requires it).
        features: []const Feature = &.{},
        /// Additional vendor libraries loaded by app-owned native SDKs.
        native_libraries: []const Feature = &.{},
        /// Kotlin or Java files (helpers your Zig code calls over JNI, ...)
        /// copied on every build into the Gradle project's
        /// `app/src/main/java/<path of the file's package line>/`; a file
        /// dropped from the list is removed from there.
        sources: []const std.Build.LazyPath = &.{},
        /// Platform hooks: classes implementing `dev.oriel.OrielAndroidHooks`,
        /// constructed once at launch in this order; registration is
        /// regenerated on every Android build (docs/platform-hooks.md).
        hooks: []const AndroidHook = &.{},
        /// Maven coordinates (group:artifact:version), regenerated on every build.
        dependencies: []const []const u8 = &.{},
        /// R8 rules for release builds, kept in `app/proguard-rules.pro`
        /// between `# oriel:proguard` markers (rewritten on every build).
        proguard_rules: ?std.Build.LazyPath = null,

        pub const Permission = android_manifest.Permission;
        pub const Feature = android_manifest.Feature;
    };

    pub const AndroidHook = struct {
        /// The fully qualified Kotlin/Java class implementing
        /// `dev.oriel.OrielAndroidHooks`, with a public zero-argument
        /// constructor ("dev.app.MyHooks"). A class that is also an app
        /// extension can be listed here without sources (they come with
        /// the extension): both get one instance.
        class: []const u8,
        /// Its Kotlin/Java files, copied like `android.sources`.
        sources: []const std.Build.LazyPath = &.{},
        /// Maven coordinates, merged with `android.dependencies`.
        dependencies: []const []const u8 = &.{},
    };

    pub const Windows = struct {
        /// MSIX capabilities no `.permissions` kind declares, e.g.
        /// `.{ .name = "bluetooth", .kind = .device }`; the NSIS installer
        /// has no capabilities and ignores them.
        capabilities: []const Capability = &.{},

        pub const Capability = struct {
            name: []const u8,
            kind: Kind = .general,
            /// `<Capability>`, `<uap:Capability>`, `<rescap:Capability>`
            /// (restricted: Store review) or `<DeviceCapability>`.
            pub const Kind = enum { general, uap, restricted, device };
        };
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

/// Modules that follow the app's configuration: declaring a capability (a
/// `Permissions` kind, or an `AppOptions` field like `share_target`) turns
/// its module on, so there is no -D flag to keep in sync with it; and a
/// module that is on declares the capabilities it needs (with the default
/// reason). Entries whose capability or module doesn't exist are skipped.
const CapabilityModule = struct {
    /// A `Permissions` field or an `AppOptions` field.
    capability: []const u8,
    /// The `Features` field (`-D<module>`).
    module: []const u8,
    /// Declaring the capability turns the module on, unless the app set the
    /// module's flag itself (that wins).
    enables: bool = true,
    /// The module, on, declares the capability.
    implies: bool = false,
};

const capability_modules = [_]CapabilityModule{
    .{ .capability = "bluetooth", .module = "bluetooth", .implies = true },
    .{ .capability = "local_network", .module = "network" },
    .{ .capability = "share_target", .module = "share" },
    .{ .capability = "camera", .module = "camera" },
    // audio_capture records these; declaring them doesn't build it (whisper's
    // apps opt in to it).
    .{ .capability = "microphone", .module = "audio_capture", .enables = false, .implies = true },
    .{ .capability = "system_audio", .module = "audio_capture", .enables = false, .implies = true },
};

/// System libraries a module in `capability_modules` links, when the
/// dependency's options turn it on and when `appPermissions` does later.
fn linkCapabilityModule(module: *std.Build.Module, target: std.Build.ResolvedTarget, comptime name: []const u8) void {
    // network and share link nothing new so far (Network.framework is in
    // libSystem on Apple).
    if (comptime std.mem.eql(u8, name, "camera")) {
        const t = target.result;
        if (t.os.tag == .ios) {
            // PHPickerViewController. Without an SDK nothing links (check).
            if (ios_build.sdk(module.owner, t) != null) module.linkFramework("PhotosUI", .{});
        } else if (!t.abi.isAndroid() and module.import_table.get("zigimg") == null) {
            // The desktop decodes, scales and encodes picked photos.
            const zigimg = module.owner.dependency("zigimg", .{ .target = target, .optimize = module.optimize orelse .Debug });
            module.addImport("zigimg", zigimg.module("zigimg"));
        }
    }
}

/// The `oriel` module of each Oriel dependency instance in this build,
/// with what `appPermissions` may still change before anything is built:
/// its feature options.
const OrielBuild = struct {
    builder: *std.Build,
    features: Features,
    options: *std.Build.Step.Options,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    /// The first app's extension names (`setExtensionTable`).
    extension_names: ?[]const u8 = null,
    /// The first app's iOS or macOS hook classes (`setAppleHooksTable`).
    apple_hook_classes: ?[]const u8 = null,
};
var oriel_builds: std.ArrayList(OrielBuild) = .empty;

fn orielBuild(oriel_dep: *std.Build.Dependency) *OrielBuild {
    for (oriel_builds.items) |*ob| if (ob.builder == oriel_dep.builder) return ob;
    @panic("addApp: the dependency isn't Oriel's (b.dependency(\"oriel\", ...))");
}

fn capabilityDeclared(options: AppOptions, comptime capability: []const u8) bool {
    if (@hasField(Permissions, capability)) return @field(options.permissions, capability) != null;
    if (@hasField(AppOptions, capability)) return @field(options, capability) != null;
    return false;
}

/// Turn on the modules the app's capabilities need (`capability_modules`),
/// and return its permissions plus the ones its modules need.
/// Every app built with the dependency shares its `oriel` module, so a
/// module one of them turns on is on for all of them.
fn appPermissions(oriel_dep: *std.Build.Dependency, options: AppOptions) Permissions {
    const ob = orielBuild(oriel_dep);
    inline for (capability_modules) |cm| {
        if (comptime cm.enables and @hasField(Features, cm.module)) followCapability(oriel_dep, ob, options, cm);
    }
    var p = options.permissions;
    inline for (capability_modules) |cm| {
        if (comptime cm.implies and @hasField(Features, cm.module) and @hasField(Permissions, cm.capability)) {
            if (@field(ob.features, cm.module) and @field(p, cm.capability) == null) @field(p, cm.capability) = "";
        }
    }
    return p;
}

/// Turn `cm.module` on if the app declares `cm.capability`.
fn followCapability(oriel_dep: *std.Build.Dependency, ob: *OrielBuild, options: AppOptions, comptime cm: CapabilityModule) void {
    if (!capabilityDeclared(options, cm.capability) or @field(ob.features, cm.module)) return;
    if (oriel_dep.builder.user_input_options.contains(cm.module)) {
        std.log.warn("{s}: `{s}` is declared, but the oriel dependency has {s} = false: oriel.{s} stays off", .{ options.name, cm.capability, cm.module, cm.module });
        return;
    }
    if (!module_table.supported(cm.module, module_table.platformOf(&ob.target.result))) return;
    enableFeature(ob, cm.module);
}

/// Set a feature option of an `oriel` module after its dependency's build
/// ran (the options file is written later, when the build runs).
fn enableFeature(ob: *OrielBuild, comptime name: []const u8) void {
    const from = "pub const " ++ name ++ ": bool = false;\n";
    const to = "pub const " ++ name ++ ": bool = true;\n";
    const text = &ob.options.contents;
    const at = std.mem.indexOf(u8, text.items, from) orelse @panic("oriel build options: no " ++ name ++ " = false");
    text.replaceRange(ob.builder.allocator, at, from.len, to) catch @panic("OOM");
    @field(ob.features, name) = true;
    linkCapabilityModule(ob.module, ob.target, name);
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
/// Panics on a platform declaration (`AppOptions.android`, `.ios`, `.macos`,
/// `.windows`) that the generated manifests can't carry, for any target, so
/// a bad entry shows up on the developer's machine rather than in CI.
fn checkPlatformExtras(b: *std.Build, options: AppOptions) void {
    const macos_plist = @import("tools/package/macos.zig");
    const msix = @import("tools/package/msix.zig");
    for (options.android.permissions) |p| {
        if (!android_manifest.validName(p.name)) @panic(b.fmt("AppOptions.android.permissions: invalid name \"{s}\" (it can't be empty or have quotes, '<', '>', '&' or whitespace)", .{p.name}));
        if (p.flags) |f| if (!android_manifest.validName(f)) @panic(b.fmt("AppOptions.android.permissions: invalid flags \"{s}\" for {s}", .{ f, p.name }));
    }
    for (options.android.features) |f| {
        if (!android_manifest.validName(f.name)) @panic(b.fmt("AppOptions.android.features: invalid name \"{s}\" (it can't be empty or have quotes, '<', '>', '&' or whitespace)", .{f.name}));
    }
    inline for (.{ "ios", "macos" }) |os| for (@field(options, os).usage_descriptions) |u| {
        if (!macos_plist.validUsageKey(u.key)) @panic(b.fmt("AppOptions." ++ os ++ ".usage_descriptions: invalid key \"{s}\" (a usage key: [A-Za-z0-9_.~-], ending in UsageDescription)", .{u.key}));
        macos_plist.checkText(u.text) catch @panic(b.fmt("AppOptions." ++ os ++ ".usage_descriptions: {s} needs a text (UTF-8, no control characters)", .{u.key}));
    };
    for (options.macos.entitlements) |e| {
        if (!macos_plist.validPlistKey(e)) @panic(b.fmt("AppOptions.macos.entitlements: invalid key \"{s}\" ([A-Za-z0-9_.~-])", .{e}));
    }
    for (options.windows.capabilities) |c| {
        if (!msix.validCapabilityName(c.name)) @panic(b.fmt("AppOptions.windows.capabilities: invalid name \"{s}\" ([A-Za-z0-9._-] or {{GUID}})", .{c.name}));
    }
    checkAppleHooks(b, "ios", options.ios.hooks);
    checkAppleHooks(b, "macos", options.macos.hooks);
}

/// Panics on a `.ios.hooks` / `.macos.hooks` list the dispatcher can't take
/// (src/platform/apple/hooks_spec.zig: `check`).
fn checkAppleHooks(b: *std.Build, comptime os: []const u8, list: []const AppOptions.PlatformHook) void {
    const field = "AppOptions." ++ os ++ ".hooks";
    if (list.len > hooks_spec.max_hooks) @panic(b.fmt("{s}: at most {d} hooks", .{ field, hooks_spec.max_hooks }));
    var declared: [hooks_spec.max_hooks]hooks_spec.Declared = undefined;
    for (list, 0..) |h, i| declared[i] = .{ .class = h.class, .sources = h.sources.len, .swift_sources = h.swift_sources.len, .frameworks = h.frameworks };
    const problem = hooks_spec.check(declared[0..list.len]) orelse return;
    @panic(switch (problem) {
        .too_many => b.fmt("{s}: at most {d} hooks", .{ field, hooks_spec.max_hooks }),
        .invalid_class => |name| b.fmt("{s}: invalid class \"{s}\" (an Objective-C class name: [A-Za-z_][A-Za-z0-9_]*)", .{ field, name }),
        .duplicate_class => |name| b.fmt("{s}: \"{s}\" is listed twice", .{ field, name }),
        .too_many_sources => |name| b.fmt("{s}: {s}: at most {d} sources of each kind", .{ field, name, hooks_spec.max_sources }),
        .too_many_frameworks => |name| b.fmt("{s}: {s}: at most {d} frameworks", .{ field, name, hooks_spec.max_frameworks }),
        .invalid_framework => |f| b.fmt("{s}: {s}: invalid framework \"{s}\"", .{ field, f.class, f.name }),
    });
}

/// The source of an `oriel_apple_hooks` table: the hook classes, in
/// declaration order (validated: no quotes or backslashes).
fn appleHooksTableText(b: *std.Build, label: []const u8, list: []const AppOptions.PlatformHook) []const u8 {
    var text: std.ArrayList(u8) = .empty;
    text.print(b.allocator, "//! Generated from AppOptions.ios.hooks / .macos.hooks ({s}).\npub const classes = [_][:0]const u8{{\n", .{label}) catch @panic("OOM");
    for (list) |h| text.print(b.allocator, "    \"{s}\",\n", .{h.class}) catch @panic("OOM");
    text.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return text.items;
}

/// The `oriel_apple_hooks` table of the app's `oriel` module, for an iOS or
/// macOS target (`hooks`: that platform's list). Apps built with one Oriel
/// dependency share its module, so they must declare the same hooks.
fn setAppleHooksTable(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) void {
    const ob = orielBuild(oriel_dep);
    const list = switch (ob.target.result.os.tag) {
        .ios => options.ios.hooks,
        .macos => options.macos.hooks,
        else => return,
    };
    var names: std.ArrayList(u8) = .empty;
    for (list) |h| names.print(b.allocator, "{s};", .{h.class}) catch @panic("OOM");
    if (ob.apple_hook_classes) |prev| {
        if (!std.mem.eql(u8, prev, names.items)) @panic(b.fmt("{s}: apps sharing one oriel dependency must declare the same .{s}.hooks", .{ options.name, @tagName(ob.target.result.os.tag) }));
        return;
    }
    ob.apple_hook_classes = names.items;
    if (list.len == 0) return;
    const text = appleHooksTableText(b, options.name, list);
    ob.module.addImport("oriel_apple_hooks", b.createModule(.{ .root_source_file = b.addWriteFiles().add("oriel_apple_hooks.zig", text) }));
}

/// Panics on an `AppOptions.extensions` entry no platform could build, for
/// any target (like `checkPlatformExtras`).
fn checkExtensions(b: *std.Build, options: AppOptions) void {
    const exts = options.extensions;
    if (exts.len > extension_spec.max_extensions) @panic("AppOptions.extensions: at most 64 extensions");
    for (exts, 0..) |e, i| {
        if (!extension_spec.validName(e.name)) @panic(b.fmt("AppOptions.extensions: invalid name \"{s}\" (lowercase dotted words, [a-z][a-z0-9_]* joined by dots, up to 64 characters)", .{e.name}));
        if (extension_spec.reserved(e.name)) @panic(b.fmt("AppOptions.extensions: \"{s}\": names starting with \"oriel.\" are Oriel's own", .{e.name}));
        for (exts[0..i]) |prev| if (std.mem.eql(u8, prev.name, e.name)) @panic(b.fmt("AppOptions.extensions: \"{s}\" is declared twice", .{e.name}));
        if (e.max_bytes == 0 or e.max_bytes > extension_spec.max_bytes_limit) @panic(b.fmt("AppOptions.extensions: {s}: max_bytes must be 1..{d}", .{ e.name, extension_spec.max_bytes_limit }));
        if (e.concurrency == 0 or e.concurrency > extension_spec.max_concurrency) @panic(b.fmt("AppOptions.extensions: {s}: concurrency must be 1..{d}", .{ e.name, extension_spec.max_concurrency }));
        if (e.android) |a| {
            if (!extension_spec.validJavaClass(a.class)) @panic(b.fmt("AppOptions.extensions: {s}: invalid Android class \"{s}\" (fully qualified, e.g. dev.app.VisionExtension)", .{ e.name, a.class }));
            if (a.dependencies.len > 64) @panic(b.fmt("AppOptions.extensions: {s}: at most 64 Android dependencies", .{e.name}));
            for (a.dependencies) |d| if (!android_manifest.mavenCoordinateValid(d)) @panic(b.fmt("AppOptions.extensions: {s}: invalid Maven coordinate \"{s}\"", .{ e.name, d }));
            for (a.assets) |asset| if (!validAssetPath(asset.to)) @panic(b.fmt("AppOptions.extensions: {s}: invalid asset path \"{s}\" (relative, no \"..\")", .{ e.name, asset.to }));
        }
        if (e.ios) |x| {
            if (!extension_spec.validObjcClass(x.class)) @panic(b.fmt("AppOptions.extensions: {s}: invalid iOS class \"{s}\" (an Objective-C class name)", .{ e.name, x.class }));
            for (x.frameworks) |f| if (!validFrameworkName(f)) @panic(b.fmt("AppOptions.extensions: {s}: invalid framework \"{s}\"", .{ e.name, f }));
            for (x.weak_frameworks) |f| if (!validFrameworkName(f)) @panic(b.fmt("AppOptions.extensions: {s}: invalid framework \"{s}\"", .{ e.name, f }));
            for (x.resources) |r| if (!validAssetPath(r.to)) @panic(b.fmt("AppOptions.extensions: {s}: invalid resource path \"{s}\" (relative, no \"..\")", .{ e.name, r.to }));
        }
        if (e.macos) |m| if (m == .objc) {
            const x = m.objc;
            if (!extension_spec.validObjcClass(x.class)) @panic(b.fmt("AppOptions.extensions: {s}: invalid macOS class \"{s}\" (an Objective-C class name)", .{ e.name, x.class }));
            for (x.frameworks) |f| if (!validFrameworkName(f)) @panic(b.fmt("AppOptions.extensions: {s}: invalid framework \"{s}\"", .{ e.name, f }));
            for (x.weak_frameworks) |f| if (!validFrameworkName(f)) @panic(b.fmt("AppOptions.extensions: {s}: invalid framework \"{s}\"", .{ e.name, f }));
        };
    }
}

fn validAssetPath(path: []const u8) bool {
    if (path.len == 0 or path.len > 256 or path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        for (part) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) return false;
    }
    return true;
}

fn isAlnum(text: []const u8) bool {
    for (text) |ch| if (!std.ascii.isAlphanumeric(ch)) return false;
    return true;
}

fn validFrameworkName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

test validAssetPath {
    try std.testing.expect(validAssetPath("detectors"));
    try std.testing.expect(validAssetPath("models/yoloe.onnx"));
    try std.testing.expect(!validAssetPath("../x"));
    try std.testing.expect(!validAssetPath("/abs"));
    try std.testing.expect(!validAssetPath("a//b"));
    try std.testing.expect(!validAssetPath(""));
}

const ExtensionBackend = union(enum) { none, zig: std.Build.LazyPath, android, objc };

/// Which implementation of `e` a build for `platform` has.
fn extensionBackend(e: AppOptions.Extension, platform: module_table.Platform) ExtensionBackend {
    if (platform == .macos) if (e.macos) |m| switch (m) {
        .zig => |path| return .{ .zig = path },
        .objc => return .objc,
    };
    const desktop: ?AppOptions.DesktopExtension = switch (platform) {
        .linux => e.linux orelse e.desktop,
        .macos => e.desktop,
        .windows => e.windows orelse e.desktop,
        else => null,
    };
    if (desktop) |d| return .{ .zig = d.zig };
    return switch (platform) {
        .android => if (e.android != null) .android else .none,
        .ios => if (e.ios != null) .objc else .none,
        else => .none,
    };
}

const ZigExtension = struct { name: []const u8, path: std.Build.LazyPath };

/// The source of an `oriel_extensions` table: each extension's name, limits
/// and backend on `platform`, and an import per desktop Zig module (listed
/// in `zig_modules`; Oriel's own extensions have none).
fn extensionTableText(b: *std.Build, label: []const u8, list: []const AppOptions.Extension, platform: module_table.Platform, zig_modules: ?*std.ArrayList(ZigExtension)) []const u8 {
    var text: std.ArrayList(u8) = .empty;
    text.appendSlice(b.allocator, b.fmt("//! Generated from AppOptions.extensions and Oriel's own ({s}).\npub const list = .{{\n", .{label})) catch @panic("OOM");
    for (list, 0..) |e, i| {
        const backend = extensionBackend(e, platform);
        const class: []const u8 = switch (backend) {
            .android => e.android.?.class,
            .objc => if (platform == .macos) e.macos.?.objc.class else e.ios.?.class,
            else => "",
        };
        var impl: []const u8 = "void";
        if (backend == .zig) {
            const import_name = b.fmt("oriel_extension_{d}", .{i});
            const out = zig_modules orelse @panic("an Oriel extension with a Zig backend");
            out.append(b.allocator, .{ .name = import_name, .path = backend.zig }) catch @panic("OOM");
            impl = b.fmt("@import(\"{s}\")", .{import_name});
        }
        // Names and classes were validated: no quotes or backslashes.
        text.appendSlice(b.allocator, b.fmt("    .{{ .name = \"{s}\", .max_bytes = {d}, .concurrency = {d}, .backend = .{s}, .class = \"{s}\", .impl = {s} }},\n", .{
            e.name, e.max_bytes, e.concurrency, @tagName(backend), class, impl,
        })) catch @panic("OOM");
    }
    text.appendSlice(b.allocator, "};\n") catch @panic("OOM");
    return text.items;
}

/// Oriel's own modules built on app extensions (dogfooding the primitive):
/// named `oriel.*`, a prefix apps can't use, and merged before the app's
/// (`withOrielExtensions`). Their sources live in Oriel (`owner` is
/// Oriel's builder) and are built only when the module is on.
fn orielExtensions(owner: *std.Build, features: Features) []const AppOptions.Extension {
    const gpa = owner.allocator;
    var list: std.ArrayList(AppOptions.Extension) = .empty;
    // -Dsystem_ai (Android and iOS only: module_table): Gemini Nano through
    // ML Kit in Kotlin, Foundation Models in Swift (weak-linked, so the app
    // still runs before iOS 26). Two workers: status() answers during a
    // generate. The input carries up to 4 images of 8 MiB.
    if (features.system_ai) list.append(gpa, .{
        .name = "oriel.system_ai",
        .android = .{
            .class = "dev.oriel.OrielSystemAi",
            .sources = gpa.dupe(std.Build.LazyPath, &.{owner.path("src/modules/system_ai/OrielSystemAi.kt")}) catch @panic("OOM"),
            .dependencies = &.{"com.google.mlkit:genai-prompt:1.0.0-beta4"},
        },
        .ios = .{
            .class = "OrielSystemAiExtension",
            .swift_sources = gpa.dupe(std.Build.LazyPath, &.{owner.path("src/modules/system_ai/SystemAi.swift")}) catch @panic("OOM"),
            .weak_frameworks = &.{"FoundationModels"},
        },
        .max_bytes = 40 << 20,
        .concurrency = 2,
    }) catch @panic("OOM");
    return list.items;
}

/// `options` with Oriel's own extensions before the app's: what the
/// Android project and the iOS link see.
fn withOrielExtensions(ob: *const OrielBuild, options: AppOptions) AppOptions {
    const own = orielExtensions(ob.builder, ob.features);
    if (own.len == 0) return options;
    var out = options;
    out.extensions = std.mem.concat(ob.builder.allocator, AppOptions.Extension, &.{ own, options.extensions }) catch @panic("OOM");
    return out;
}

/// The `oriel_extensions` table of the app's `oriel` module (src/core/
/// extensions.zig): every declared name (so `get` checks it at build time)
/// with this target's backend, and an import per desktop Zig module.
/// Apps built with one Oriel dependency share its module, so they must
/// declare the same extensions.
fn setExtensionTable(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) void {
    const ob = orielBuild(oriel_dep);
    var names: std.ArrayList(u8) = .empty;
    for (options.extensions) |e| names.print(b.allocator, "{s};", .{e.name}) catch @panic("OOM");
    if (ob.extension_names) |prev| {
        if (!std.mem.eql(u8, prev, names.items)) @panic(b.fmt("{s}: apps sharing one oriel dependency must declare the same AppOptions.extensions", .{options.name}));
        return;
    }
    ob.extension_names = names.items;
    if (options.extensions.len == 0) return;

    const platform = module_table.platformOf(&ob.target.result);
    var zig_modules: std.ArrayList(ZigExtension) = .empty;
    const all = withOrielExtensions(ob, options).extensions;
    const text = extensionTableText(b, b.fmt("{s}: {s}", .{ options.name, @tagName(platform) }), all, platform, &zig_modules);
    const table = b.createModule(.{ .root_source_file = b.addWriteFiles().add("oriel_extensions.zig", text) });
    for (zig_modules.items) |z| {
        const m = b.createModule(.{
            .root_source_file = z.path,
            .target = ob.target,
            .optimize = ob.module.optimize,
            .imports = options.imports,
        });
        m.addImport("oriel", ob.module);
        table.addImport(z.name, m);
    }
    ob.module.addImport("oriel_extensions", table);
}

pub fn addApp(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) App {
    checkPlatformExtras(b, options);
    checkExtensions(b, options);
    setExtensionTable(b, oriel_dep, options);
    setAppleHooksTable(b, oriel_dep, options);
    if (oriel_dep.module("oriel").resolved_target.?.result.abi.isAndroid()) return addAndroidApp(b, oriel_dep, withOrielExtensions(orielBuild(oriel_dep), options));
    if (oriel_dep.module("oriel").resolved_target.?.result.os.tag == .ios) return addIosApp(b, oriel_dep, withOrielExtensions(orielBuild(oriel_dep), options));
    addUpdaterSteps(b, oriel_dep.artifact("update_tool"));

    const oriel = oriel_dep.module("oriel");
    // macOS: raised to macOS 15 by Swift hooks or extensions.
    const target = macosTarget(b, oriel.resolved_target.?, options);
    const optimize = oriel.optimize.?;
    // When optimize was not explicitly given on the command-line, default production to ReleaseSafe
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);
    const url_schemes = options.url_schemes;

    const permissions = appPermissions(oriel_dep, options);

    const app_icon = options.icon orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");

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
        const d = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-dev", .{options.name}), options.root_source_file, appConfigModule(b, oriel, cfg, null, app_icon, options), options.include_paths);
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
    const exe = addExe(b, oriel, target, prod_optimize, options.name, options.root_source_file, appConfigModule(b, oriel, prod_cfg, assets_dir.path(b, "assets.zig"), app_icon, options), options.include_paths);
    for (options.imports) |imp| exe.root_module.addImport(imp.name, imp.module);
    b.installArtifact(exe);

    // macOS: the Objective-C and Swift sources of `.macos.hooks` and of
    // extensions' `.macos.objc` (not in the type-check, which needs no SDK).
    if (target.result.os.tag == .macos) {
        addMacosNative(b, oriel_dep, options, exe);
        if (dev_exe) |d| addMacosNative(b, oriel_dep, options, d);
    }

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

    // -Dkokoro: espeak-ng's compiled data next to the executable
    // (zig-out/bin/espeak-ng-data; oriel.tts finds it there). The dev build
    // (`build-dev`, `dev`) runs from the same directory.
    if (espeak_data.fromDependency(b, oriel_dep.builder)) |data| {
        const install_data = b.addInstallDirectory(.{ .source_dir = data.dir, .install_dir = .bin, .install_subdir = espeak_data.name });
        b.getInstallStep().dependOn(&install_data.step);
        if (dev_exe) |d| d.step.dependOn(&install_data.step);
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
    const check_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-check", .{options.name}), options.root_source_file, appConfigModule(b, oriel, check_cfg, null, app_icon, options), options.include_paths);
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
/// Under the install prefix: Oriel's files for the APK's assets (the
/// Gradle project's `assets.srcDirs`).
const android_assets_dir = "android-assets";

fn addAndroidApp(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions) App {
    const oriel = oriel_dep.module("oriel");
    const target = android_build.resolveTarget(b, oriel.resolved_target.?);
    const optimize = oriel.optimize.?;
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);
    const url_schemes = options.url_schemes;
    const permissions = appPermissions(oriel_dep, options);
    const app_icon = options.icon orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");
    const install_dir: std.Build.InstallDir = .{ .custom = b.fmt("jniLibs/{s}", .{android_build.abiDir(target.result)}) };
    installExtensionAssets(b, options);

    // -Dkokoro: espeak-ng's compiled data as APK assets
    // (zig-out/android-assets/espeak-ng-data, the Gradle project's assets
    // dir); the Kotlin runtime extracts it to filesDir, where oriel.tts
    // finds it.
    if (espeak_data.fromDependency(b, oriel_dep.builder)) |data| {
        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = data.dir,
            .install_dir = .{ .custom = android_assets_dir },
            .install_subdir = espeak_data.name,
        }).step);
    }

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
    const lib = addAndroidLib(b, oriel, target, prod_optimize, options, appConfigModule(b, oriel, prod_cfg, assets_dir.path(b, "assets.zig"), app_icon, options));
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
    const dev_lib = addAndroidLib(b, oriel, target, dev_optimize, options, appConfigModule(b, oriel, dev_cfg, null, app_icon, options));
    android_build.requireNdk(b, dev_lib);
    @import("build/package.zig").getOrCreateStep(b, "android-dev", "Build the Android library against the dev server (zig-out/jniLibs)")
        .dependOn(&b.addInstallArtifact(dev_lib, .{ .dest_dir = .{ .override = install_dir } }).step);
    @import("build/package.zig").getOrCreateStep(b, "android-dev", "Build the Android library against the dev server (zig-out/jniLibs)")
        .dependOn(&install_launcher.step);

    // The Gradle project (android/): `zig build android-project` writes it
    // from Oriel's template (`-Dandroid_force` rewrites edited files); every
    // build refreshes its copy of the Kotlin runtime, which must match this
    // library.
    const android_vars = androidProjectVars(b, options, permissions, url_schemes, orielBuild(oriel_dep).features.camera);
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
    addAndroidAppFiles(write_project, options);
    if (force) write_project.addArg("--force");
    write_project.has_side_effects = true;
    @import("build/package.zig").getOrCreateStep(b, "android-project", "Write the Android (Gradle) project into android/ (-Dandroid_force rewrites edited files)").dependOn(&write_project.step);
    const sync_runtime = b.addRunArtifact(package_tool);
    sync_runtime.addArgs(&.{ "android-project", "--runtime-only", "--template" });
    sync_runtime.addDirectoryArg(oriel_dep.path("android/template"));
    sync_runtime.addArgs(&.{ "--out", project_dir });
    for (android_vars) |v| sync_runtime.addArgs(&.{ "--var", v });
    addAndroidAppFiles(sync_runtime, options);
    sync_runtime.has_side_effects = true;
    b.getInstallStep().dependOn(&sync_runtime.step);

    // Type-check only: nothing requests the binary.
    const check_lib = addAndroidLib(b, oriel, target, dev_optimize, options, appConfigModule(b, oriel, dev_cfg, null, app_icon, options));
    @import("build/package.zig").getOrCreateStep(b, "check", "Type-check the app (no binaries)").dependOn(&check_lib.step);

    if (fe.types_path != null) {
        const fail = b.addFail("Cannot generate TypeScript types for an Android target; run `zig build types` natively on the host.");
        @import("build/package.zig").getOrCreateStep(b, "types", "Generate TypeScript types for the Zig commands").dependOn(&fail.step);
    }
    return .{ .exe = lib, .dev_exe = dev_lib };
}

/// `--source`/`--proguard`/`--keep-class` arguments for `android-project`:
/// the app's own Kotlin/Java files (including its hooks') and R8 rules
/// (`AppOptions.android`), and
/// its extensions' sources and classes (constructed by name in the
/// generated registry, so R8 must keep them).
fn addAndroidAppFiles(run: *std.Build.Step.Run, options: AppOptions) void {
    for (options.android.sources) |src| {
        run.addArg("--source");
        run.addFileArg(src);
    }
    for (options.android.hooks) |h| for (h.sources) |src| {
        run.addArg("--source");
        run.addFileArg(src);
    };
    for (options.extensions) |e| {
        const a = e.android orelse continue;
        for (a.sources) |src| {
            run.addArg("--source");
            run.addFileArg(src);
        }
        run.addArgs(&.{ "--keep-class", a.class });
    }
    if (options.android.proguard_rules) |rules| {
        run.addArg("--proguard");
        run.addFileArg(rules);
    }
}

/// App extensions' `.android.assets` under the APK's assets
/// (zig-out/android-assets/<to>). A `from` in the source tree that is a
/// file is installed as one; anything else as a directory.
fn installExtensionAssets(b: *std.Build, options: AppOptions) void {
    for (options.extensions) |e| {
        const a = e.android orelse continue;
        for (a.assets) |asset| {
            if (lazyPathIsFile(b, asset.from)) {
                b.getInstallStep().dependOn(&b.addInstallFileWithDir(asset.from, .{ .custom = android_assets_dir }, asset.to).step);
            } else {
                b.getInstallStep().dependOn(&b.addInstallDirectory(.{ .source_dir = asset.from, .install_dir = .{ .custom = android_assets_dir }, .install_subdir = asset.to }).step);
            }
        }
    }
}

/// Whether `path` is a regular file now: only paths in the source tree can
/// be looked at while configuring (generated ones count as directories).
fn lazyPathIsFile(b: *std.Build, path: std.Build.LazyPath) bool {
    const p = switch (path) {
        .src_path => |s| s.owner.pathFromRoot(s.sub_path),
        .cwd_relative => |c| c,
        .dependency => |d| d.dependency.builder.pathFromRoot(d.sub_path),
        else => return false,
    };
    const stat = std.Io.Dir.cwd().statFile(b.graph.io, p, .{}) catch return false;
    return stat.kind == .file;
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

/// versionCode from major.minor.patch (a -prerelease or +build suffix
/// ignored): 1.2.3 -> 10203; missing parts are 0; 0.0.0 is 1.
fn androidVersionCode(version: []const u8) !u32 {
    const core_end = std.mem.indexOfAny(u8, version, "-+") orelse version.len;
    var code: u32 = 0;
    var it = std.mem.splitScalar(u8, version[0..core_end], '.');
    for (0..3) |i| {
        const part = it.next() orelse "0";
        if (part.len == 0) return error.EmptyVersionPart;
        for (part) |c| if (!std.ascii.isDigit(c)) return error.NonNumericVersionPart;
        const n = std.fmt.parseInt(u32, part, 10) catch return error.VersionPartTooLarge;
        if (i > 0 and n >= 100) return error.VersionPartTooLarge;
        code = std.math.mul(u32, code, 100) catch return error.VersionPartTooLarge;
        code = std.math.add(u32, code, n) catch return error.VersionPartTooLarge;
    }
    if (it.next() != null) return error.TooManyVersionParts;
    // Google Play's ceiling.
    if (code > 2_100_000_000) return error.VersionPartTooLarge;
    return if (code == 0) 1 else code;
}

test androidVersionCode {
    try std.testing.expectEqual(@as(u32, 10203), try androidVersionCode("1.2.3"));
    try std.testing.expectEqual(@as(u32, 10203), try androidVersionCode("1.2.3-rc.1"));
    try std.testing.expectEqual(@as(u32, 10000), try androidVersionCode("1"));
    try std.testing.expectEqual(@as(u32, 1), try androidVersionCode("0.0.0"));
    try std.testing.expectError(error.VersionPartTooLarge, androidVersionCode("1.100.0"));
    try std.testing.expectError(error.VersionPartTooLarge, androidVersionCode("1.2.100"));
    try std.testing.expectError(error.NonNumericVersionPart, androidVersionCode("1.x.3"));
    try std.testing.expectError(error.EmptyVersionPart, androidVersionCode("1..3"));
    try std.testing.expectError(error.TooManyVersionParts, androidVersionCode("1.2.3.4"));
}

/// Panics when `text` (substituted into the Android template's Kotlin
/// strings and strings.xml) holds a character either would interpret:
/// `"` `$` `\` (Kotlin), `&` `<` `>` `'` (XML / aapt), a leading `@` or `?`
/// (an aapt resource reference), or a control character.
fn androidCheckTemplateText(b: *std.Build, field: []const u8, text: []const u8) void {
    if (androidTemplateTextValid(text)) return;
    @panic(b.fmt("{s} '{s}': the Android project can't hold \" $ \\ & < > ' or control characters, nor a leading @ or ?", .{ field, text }));
}

fn androidTemplateTextValid(text: []const u8) bool {
    if (text.len == 0) return false;
    if (text[0] == '@' or text[0] == '?') return false;
    for (text) |c| switch (c) {
        '"', '$', '\\', '&', '<', '>', '\'' => return false,
        else => if (c < 0x20 or c == 0x7f) return false,
    };
    return true;
}

test androidTemplateTextValid {
    try std.testing.expect(androidTemplateTextValid("My App 2"));
    try std.testing.expect(!androidTemplateTextValid("Say \"hi\""));
    try std.testing.expect(!androidTemplateTextValid("${'$'}evil"));
    try std.testing.expect(!androidTemplateTextValid("Tom & Jerry"));
    try std.testing.expect(!androidTemplateTextValid("@string/x"));
}

/// `--var key=value` arguments for the Android template (android/template).
fn androidProjectVars(b: *std.Build, options: AppOptions, permissions: Permissions, url_schemes: []const []const u8, camera: bool) []const []const u8 {
    const pkg = options.package orelse PackageOptions{};
    const app_id = pkg.id orelse b.fmt("dev.oriel.{s}", .{options.name});
    const name = pkg.name orelse options.name;
    const version = pkg.version orelse "0.1.0";
    // One value goes into settings.gradle.kts / build.gradle.kts ("..."
    // Kotlin strings) and res/values/strings.xml: what either would read as
    // markup is refused rather than escaped (the template has one @@name@@).
    androidCheckTemplateText(b, "package.name", name);
    androidCheckTemplateText(b, "package.version", version);
    const code = androidVersionCode(version) catch |err| @panic(b.fmt(
        "package.version '{s}': {s} (Android's versionCode is MAJOR*10000 + MINOR*100 + PATCH: numeric parts, minor and patch below 100)",
        .{ version, @errorName(err) },
    ));

    // The manifest's generated regions (build/android_manifest.zig), rewritten
    // on every build by the `--runtime-only` sync.
    // The app's own entries are merged in (checked by checkPlatformExtras).
    const perms = android_manifest.permissionsXmlWithExtras(b.allocator, permissions, options.android.permissions) catch |err|
        @panic(b.fmt("AndroidManifest.xml permissions: {s}", .{@errorName(err)}));
    const features = android_manifest.featuresXmlWithExtras(b.allocator, permissions, options.android.features) catch |err|
        @panic(b.fmt("AndroidManifest.xml features: {s}", .{@errorName(err)}));

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
    , .{xmlEscape(b, label)})) catch @panic("OOM");

    // oriel.camera: the camera app writes into this provider, and OrielCamera
    // treats its presence as "the module is on".
    if (camera) components.appendSlice(b.allocator, android_manifest.captureProviderXml(options.camera.transcode)) catch @panic("OOM");

    const native_libraries_xml = android_manifest.nativeLibrariesXml(b.allocator, options.android.native_libraries) catch |err|
        @panic(b.fmt("android.native_libraries: {s}", .{@errorName(err)}));
    components.appendSlice(b.allocator, native_libraries_xml) catch @panic("OOM");

    // android/app to the installed libraries, relative so the project moves.
    const app_dir = b.pathFromRoot("android/app");
    const libs = b.pathJoin(&.{ b.install_prefix, "jniLibs" });
    const lib_dir = std.fs.path.relative(b.allocator, b.build_root.path orelse "/", null, app_dir, libs) catch libs;
    const assets = b.pathJoin(&.{ b.install_prefix, android_assets_dir });
    const assets_dir = std.fs.path.relative(b.allocator, b.build_root.path orelse "/", null, app_dir, assets) catch assets;

    // Platform hooks, in declaration order.
    var hooks: std.ArrayList(u8) = .empty;
    var bad_hook: []const u8 = "";
    var hook_names: std.ArrayList([]const u8) = .empty;
    for (options.android.hooks) |h| hook_names.append(b.allocator, h.class) catch @panic("OOM");
    const hook_classes = android_manifest.hookClasses(b.allocator, hook_names.items, &bad_hook) catch |err| switch (err) {
        error.TooManyHooks => @panic("android.hooks: at most 64 classes are supported"),
        error.DuplicateHook => @panic(b.fmt("android.hooks: duplicate class '{s}'", .{bad_hook})),
        error.InvalidHookClass => @panic(b.fmt("android.hooks: invalid class name '{s}'", .{bad_hook})),
        error.OutOfMemory => @panic("OOM"),
    };
    for (hook_classes) |class_name| {
        hooks.appendSlice(b.allocator, b.fmt("{s}(),", .{class_name})) catch @panic("OOM");
    }

    var dependencies: std.ArrayList(u8) = .empty;
    if (options.android.dependencies.len > 64) @panic("android.dependencies: at most 64 dependencies");
    for (options.android.dependencies) |coordinate| {
        if (!android_manifest.mavenCoordinateValid(coordinate))
            @panic(b.fmt("android.dependencies: invalid Maven coordinate '{s}'", .{coordinate}));
        dependencies.appendSlice(b.allocator, b.fmt("    add(\"implementation\", \"{s}\")\n", .{coordinate})) catch @panic("OOM");
    }
    // Hooks' dependencies join the app's (each once).
    for (options.android.hooks) |h| for (h.dependencies) |coordinate| {
        if (!android_manifest.mavenCoordinateValid(coordinate))
            @panic(b.fmt("android.hooks: {s}: invalid Maven coordinate '{s}'", .{ h.class, coordinate }));
        const line = b.fmt("    add(\"implementation\", \"{s}\")\n", .{coordinate});
        if (std.mem.indexOf(u8, dependencies.items, line) == null) dependencies.appendSlice(b.allocator, line) catch @panic("OOM");
    };
    // App extensions' dependencies join the app's (each once); their
    // classes go into the generated registry (OrielExtensions.kt).
    var app_extensions: std.ArrayList(u8) = .empty;
    for (options.extensions) |e| {
        const a = e.android orelse continue;
        for (a.dependencies) |coordinate| {
            const line = b.fmt("    add(\"implementation\", \"{s}\")\n", .{coordinate});
            if (std.mem.indexOf(u8, dependencies.items, line) == null) dependencies.appendSlice(b.allocator, line) catch @panic("OOM");
        }
        app_extensions.appendSlice(b.allocator, b.fmt("        \"{s}\" -> {s}()\n", .{ e.name, a.class })) catch @panic("OOM");
    }

    return b.allocator.dupe([]const u8, &.{
        b.fmt("android_hooks={s}", .{hooks.items}),
        b.fmt("app_extensions={s}", .{app_extensions.items}),
        b.fmt("android_dependencies={s}", .{dependencies.items}),
        b.fmt("app_id={s}", .{app_id}),
        b.fmt("name={s}", .{name}),
        b.fmt("version={s}", .{version}),
        b.fmt("version_code={d}", .{code}),
        b.fmt("lib_dir={s}", .{lib_dir}),
        b.fmt("assets_dir={s}", .{assets_dir}),
        b.fmt("permissions={s}", .{perms}),
        b.fmt("features={s}", .{features}),
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
    const target = iosTarget(b, oriel.resolved_target.?, options);
    const optimize = oriel.optimize.?;
    const prod_optimize = if (b.user_input_options.contains("optimize")) optimize else .ReleaseSafe;
    const dev_optimize = if (b.user_input_options.contains("optimize")) optimize else .Debug;
    const fe = options.frontend;
    const fe_dir = b.pathFromRoot(fe.dir);
    const url_schemes = options.url_schemes;
    const permissions = appPermissions(oriel_dep, options);
    const app_icon = options.icon orelse oriel_dep.path("assets/brand/oriel-icon-1024.png");
    const sdk = ios_build.sdk(b, target.result);
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
    const exe = addExe(b, oriel, target, prod_optimize, options.name, options.root_source_file, appConfigModule(b, oriel, prod_cfg, assets_dir.path(b, "assets.zig"), app_icon, options), options.include_paths);
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
    const dev_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-dev", .{options.name}), options.root_source_file, appConfigModule(b, oriel, dev_cfg, null, app_icon, options), options.include_paths);
    for (options.imports) |imp| dev_exe.root_module.addImport(imp.name, imp.module);

    // Simulator builds carry their entitlements in __TEXT sections, as
    // Xcode's do: daemons such as nsurlsessiond (background URLSessions)
    // and the keychain identify the app by its application-identifier.
    const sim_entitlements: ?std.Build.LazyPath = if (ios_build.isSimulator(target.result)) blk: {
        const bundle_id = if (options.package) |pkg| pkg.id orelse b.fmt("dev.oriel.{s}", .{options.name}) else b.fmt("dev.oriel.{s}", .{options.name});
        if (options.ios.team_id) |t| if (t.len != 10 or !isAlnum(t)) @panic(b.fmt("AppOptions.ios.team_id \"{s}\": a team ID is 10 letters and digits", .{t}));
        const app_id = ios_entitlements.applicationIdentifier(b.allocator, options.ios.team_id, bundle_id) catch @panic("OOM");
        const source = ios_entitlements.cSource(b.allocator, .{ .application_identifier = app_id }) catch @panic("OOM");
        break :blk b.addWriteFiles().add("oriel_simulator_entitlements.c", source);
    } else null;

    for ([_]*std.Build.Step.Compile{ exe, dev_exe }) |c| {
        if (sim_entitlements) |src| c.root_module.addCSourceFile(.{ .file = src });
        if (sdk) |root| ios_build.link(c.root_module, root, audio_capture);
        ios_build.configure(b, c);
        ios_build.requireSdk(b, c);
        addIosExtensions(b, oriel_dep, options, c, sdk);
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
        if (options.share_target) |st| for (st.types) |t| run.addArgs(&.{ "--document-type", t });
        inline for (@typeInfo(Permissions).@"struct".fields) |f| {
            if (@field(permissions, f.name)) |reason| {
                const text = if (reason.len > 0) reason else b.fmt("{s} {s}", .{ display_name, Permissions.defaultReasonFor(f.name) });
                run.addArgs(&.{ "--permission", b.fmt("{s}={s}", .{ f.name, text }) });
            }
        }
        for (options.ios.usage_descriptions) |u| run.addArgs(&.{ "--usage-key", b.fmt("{s}={s}", .{ u.key, u.text }) });
        made[idx] = .{ .step = run, .dir = out };
        // -Dkokoro: espeak-ng's compiled data at the bundle's root, its
        // resource directory (<Name>.app/espeak-ng-data; oriel.tts finds it).
        // App extensions' `.ios.resources` go there too.
        const espeak = espeak_data.fromDependency(b, oriel_dep.builder);
        const resources = iosExtensionResources(b, options);
        if (espeak != null or resources.len > 0) {
            const with_data = b.addWriteFiles();
            _ = with_data.addCopyDirectory(out.path(b, bundle_dir), bundle_dir, .{});
            if (espeak) |data| _ = with_data.addCopyDirectory(data.dir, b.fmt("{s}/{s}", .{ bundle_dir, espeak_data.name }), .{});
            for (resources) |res| {
                const dest = b.fmt("{s}/{s}", .{ bundle_dir, res.name });
                if (lazyPathIsFile(b, res.path)) _ = with_data.addCopyFile(res.path, dest) else _ = with_data.addCopyDirectory(res.path, dest, .{});
            }
            made[idx].dir = with_data.getDirectory();
        }
        // On a Mac, sign the simulator bundle ad hoc as Xcode does: the
        // signature then names the bundle ID and seals Info.plist and the
        // resources (the linker's own signature covers the executable only).
        if (ios_build.isSimulator(target.result) and b.graph.host.result.os.tag == .macos) {
            const sign = b.addSystemCommand(&.{ "sh", "-c", "cp -R \"$0\"/. \"$1\" && chmod -R u+w \"$1\" && codesign --force --sign - --timestamp=none \"$1/$2\"" });
            sign.addDirectoryArg(made[idx].dir);
            const signed = sign.addOutputDirectoryArg("ios-signed");
            sign.addArg(bundle_dir);
            made[idx].dir = signed;
        }
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
    const check_exe = addExe(b, oriel, target, dev_optimize, b.fmt("{s}-check", .{options.name}), options.root_source_file, appConfigModule(b, oriel, dev_cfg, null, app_icon, options), options.include_paths);
    for (options.imports) |imp| check_exe.root_module.addImport(imp.name, imp.module);
    // C dependencies (sql, whisper, ...) type-check too: against the SDK, else Zig's Darwin headers.
    ios_build.configureCheck(b, check_exe);
    @import("build/package.zig").getOrCreateStep(b, "check", "Type-check the app (no binaries)").dependOn(&check_exe.step);

    if (fe.types_path != null) {
        const fail = b.addFail("Cannot generate TypeScript types for an iOS target; run `zig build types` natively on the host.");
        @import("build/package.zig").getOrCreateStep(b, "types", "Generate TypeScript types for the Zig commands").dependOn(&fail.step);
    }
    return .{ .exe = exe, .dev_exe = dev_exe };
}

/// `options` comes with Oriel's own extensions (`withOrielExtensions`), so
/// -Dsystem_ai's Swift backend counts too; so do `.ios.hooks`.
fn hasSwift(options: AppOptions) bool {
    for (options.extensions) |e| if (e.ios) |x| if (x.swift_sources.len > 0) return true;
    return hooksHaveSwift(options.ios.hooks);
}

fn hooksHaveSwift(list: []const AppOptions.PlatformHook) bool {
    for (list) |h| if (h.swift_sources.len > 0) return true;
    return false;
}

/// Whether the macOS build has Swift sources: `.macos.hooks` or extensions'
/// `.macos.objc`.
fn hasMacosSwift(options: AppOptions) bool {
    for (options.extensions) |e| if (e.macos) |m| if (m == .objc and m.objc.swift_sources.len > 0) return true;
    return hooksHaveSwift(options.macos.hooks);
}

/// The app's iOS target: Oriel's minimum, raised to iOS 18 when the app
/// has Swift sources (`swift_build.min_ios`). An explicit lower version
/// (`-Dtarget=aarch64-ios.16.0`) with Swift sources is a build error.
fn iosTarget(b: *std.Build, target: std.Build.ResolvedTarget, options: AppOptions) std.Build.ResolvedTarget {
    const resolved = ios_build.resolveTarget(b, target);
    if (!hasSwift(options)) return resolved;
    const min = resolved.result.os.version_range.semver.min;
    if (min.order(swift_build.min_ios) != .lt) return resolved;
    if (target.query.os_version_min != null)
        fatal("iOS {d}.{d} is below what Swift supports here: with .ios.swift_sources, .ios.hooks' Swift sources (or -Dsystem_ai, Oriel's Swift backend) the minimum is iOS {d}.{d} (docs/extensions.md)", .{ min.major, min.minor, swift_build.min_ios.major, swift_build.min_ios.minor });
    var query = target.query;
    query.os_version_min = .{ .semver = swift_build.min_ios };
    return b.resolveTargetQuery(query);
}

/// The app's macOS executables' target (`resolveTarget`), raised to macOS
/// 15 when the app has macOS Swift sources (`swift_build.min_macos`). A
/// version below that other than `default_macos_min` (which
/// `resolveTarget` fills in) is a build error.
fn macosTarget(b: *std.Build, target: std.Build.ResolvedTarget, options: AppOptions) std.Build.ResolvedTarget {
    const resolved = resolveTarget(b, target);
    if (resolved.result.os.tag != .macos or !hasMacosSwift(options)) return resolved;
    const min = resolved.result.os.version_range.semver.min;
    if (min.order(swift_build.min_macos) != .lt) return resolved;
    const explicit: ?std.SemanticVersion = if (target.query.os_version_min) |v| switch (v) {
        .semver => |sv| sv,
        else => null,
    } else null;
    if (explicit) |v| if (v.order(default_macos_min) != .eq)
        fatal("macOS {d}.{d} is below what Swift supports here: with Swift sources in .macos.hooks or an extension's .macos.objc the minimum is macOS {d}.{d} (docs/platform-hooks.md)", .{ min.major, min.minor, swift_build.min_macos.major, swift_build.min_macos.minor });
    var query = resolved.query;
    query.os_version_min = .{ .semver = swift_build.min_macos };
    return b.resolveTargetQuery(query);
}

/// One extension's or hook's native sources on iOS or macOS.
const AppleUnit = struct {
    /// For messages: "app.vision: .ios.swift_sources".
    who: []const u8,
    /// The Swift module of its Swift sources.
    module_name: []const u8,
    sources: []const std.Build.LazyPath = &.{},
    swift_sources: []const std.Build.LazyPath = &.{},
    frameworks: []const []const u8 = &.{},
    weak_frameworks: []const []const u8 = &.{},
};

/// The include directories of the app's Objective-C and Swift sources:
/// oriel_hooks.h and oriel_swift.h, oriel_extension.h.
fn appleIncludes(oriel_dep: *std.Build.Dependency) [2]std.Build.LazyPath {
    return .{ oriel_dep.path("src/platform/apple/include"), oriel_dep.path("src/platform/ios/include") };
}

/// Add `unit` to `compile` (an app executable, not its type-check, which
/// builds without an SDK): Objective-C sources with ARC, frameworks, and
/// its Swift sources as one object (build/swift.zig). The caller adds the
/// include paths (`appleIncludes`) and, for macOS, the SDK's paths. Returns
/// whether a Swift object was added (the caller links the runtime once).
fn addAppleUnit(b: *std.Build, oriel_dep: *std.Build.Dependency, compile: *std.Build.Step.Compile, unit: AppleUnit, sdk: ?[]const u8) bool {
    const target = compile.rootModuleTarget();
    const macos = target.os.tag == .macos;
    for (unit.sources) |src| compile.root_module.addCSourceFile(.{ .file = src, .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" } });
    for (unit.frameworks) |f| compile.root_module.linkFramework(f, .{});
    // Weak and only where the SDK has them; Swift doesn't autolink them
    // (that link would be strong).
    var no_autolink: std.ArrayList([]const u8) = .empty;
    if (sdk) |root| for (unit.weak_frameworks) |f| {
        const dir = b.pathJoin(&.{ root, "System/Library/Frameworks", b.fmt("{s}.framework", .{f}) });
        std.Io.Dir.cwd().access(b.graph.io, dir, .{}) catch continue;
        compile.root_module.linkFramework(f, .{ .weak = true });
        no_autolink.appendSlice(b.allocator, &.{ "-Xfrontend", "-disable-autolink-framework", "-Xfrontend", f }) catch @panic("OOM");
    };
    if (unit.swift_sources.len == 0) return false;
    const root = sdk orelse {
        if (macos) {
            macos_build.requireSdk(b, compile, unit.who);
        } else {
            compile.step.dependOn(&b.addFail(b.fmt("{s} need the iOS SDK and its Swift modules, and there is no Apple SDK: on Linux, `oriel ios setup` with Xcode.xip " ++
                "(xtool extracts both into ~/.swiftpm/swift-sdks/darwin.artifactbundle), or -Dapple_sdk=<iPhoneOS.sdk> plus -Dswift_resource_dir=<the Darwin Swift resource dir>; on a Mac, Xcode (docs/extensions.md)", .{unit.who})).step);
        }
        return false;
    };
    const swiftc = swift_build.findSwiftc(b) orelse {
        compile.step.dependOn(&b.addFail(b.fmt("{s} need swiftc: Xcode on a Mac, or the Swift toolchain (swift.org) on Linux with xtool's SDK; or set $SWIFTC (docs/extensions.md)", .{unit.who})).step);
        return false;
    };
    if (b.graph.host.result.os.tag != .macos and swift_build.resourceDir(b, root, target) == null) {
        compile.step.dependOn(&b.addFail(b.fmt("{s}: a Linux swiftc has no Darwin standard library: build against xtool's SDK (`oriel ios setup` with Xcode.xip; its darwin.artifactbundle has the Swift modules), or pass -Dswift_resource_dir (docs/extensions.md)", .{unit.who})).step);
        return false;
    }
    // Zig ignores swiftc's autolinking: the frameworks the sources import.
    swift_build.linkImportedFrameworks(compile.root_module, root, unit.swift_sources, unit.weak_frameworks);
    const includes = appleIncludes(oriel_dep);
    const obj = swift_build.compile(b, swiftc, unit.swift_sources, unit.module_name, target, root, includes[0].path(b, "oriel_swift.h"), &includes, compile.root_module.optimize orelse .Debug, no_autolink.items);
    compile.root_module.addObjectFile(obj);
    return true;
}

/// "OrielExtension_app_vision" for extension "app.vision".
fn extensionModuleName(b: *std.Build, name: []const u8) []const u8 {
    const module_name = b.dupe(b.fmt("OrielExtension_{s}", .{name}));
    std.mem.replaceScalar(u8, module_name, '.', '_');
    return module_name;
}

/// "OrielHooks_MyHooks" for hook class "MyHooks".
fn hookModuleName(b: *std.Build, class: []const u8) []const u8 {
    var buf: [160]u8 = undefined;
    return b.dupe(hooks_spec.swiftModuleName(&buf, class) orelse @panic("hook class name too long"));
}

/// App extensions' and platform hooks' iOS parts for one of the app's
/// executables (build/swift.zig for Swift).
fn addIosExtensions(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions, compile: *std.Build.Step.Compile, sdk: ?[]const u8) void {
    var any = false;
    var swift = false;
    for (options.extensions) |e| {
        const x = e.ios orelse continue;
        any = any or x.sources.len > 0 or x.swift_sources.len > 0;
        // Oriel's own (oriel.system_ai): name the flag that asked for Swift.
        const who = if (extension_spec.reserved(e.name)) b.fmt("{s}: -D{s}'s Swift sources (Oriel's backend)", .{ e.name, e.name["oriel.".len..] }) else b.fmt("{s}: .ios.swift_sources", .{e.name});
        if (addAppleUnit(b, oriel_dep, compile, .{
            .who = who,
            .module_name = extensionModuleName(b, e.name),
            .sources = x.sources,
            .swift_sources = x.swift_sources,
            .frameworks = x.frameworks,
            .weak_frameworks = x.weak_frameworks,
        }, sdk)) swift = true;
    }
    for (options.ios.hooks) |h| {
        any = any or h.sources.len > 0 or h.swift_sources.len > 0;
        if (addAppleUnit(b, oriel_dep, compile, .{
            .who = b.fmt(".ios.hooks {s}: its sources", .{h.class}),
            .module_name = hookModuleName(b, h.class),
            .sources = h.sources,
            .swift_sources = h.swift_sources,
            .frameworks = h.frameworks,
        }, sdk)) swift = true;
    }
    if (any) for (appleIncludes(oriel_dep)) |dir| compile.root_module.addIncludePath(dir);
    if (swift) swift_build.linkRuntime(compile, sdk.?);
}

/// App extensions' `.macos.objc` and `.macos.hooks` for one of the app's
/// macOS executables (not the type-check): their Objective-C and Swift
/// sources against the macOS SDK (build/macos.zig), which they need.
fn addMacosNative(b: *std.Build, oriel_dep: *std.Build.Dependency, options: AppOptions, compile: *std.Build.Step.Compile) void {
    var units: std.ArrayList(AppleUnit) = .empty;
    for (options.extensions) |e| {
        const m = e.macos orelse continue;
        if (m != .objc) continue;
        const x = m.objc;
        units.append(b.allocator, .{
            .who = b.fmt("{s}: .macos.objc sources", .{e.name}),
            .module_name = extensionModuleName(b, e.name),
            .sources = x.sources,
            .swift_sources = x.swift_sources,
            .frameworks = x.frameworks,
            .weak_frameworks = x.weak_frameworks,
        }) catch @panic("OOM");
    }
    for (options.macos.hooks) |h| units.append(b.allocator, .{
        .who = b.fmt(".macos.hooks {s}: its sources", .{h.class}),
        .module_name = hookModuleName(b, h.class),
        .sources = h.sources,
        .swift_sources = h.swift_sources,
        .frameworks = h.frameworks,
    }) catch @panic("OOM");
    var any = false;
    for (units.items) |u| any = any or u.sources.len > 0 or u.swift_sources.len > 0;
    if (units.items.len == 0) return;
    const sdk = macos_build.sdk(b);
    if (any) {
        for (appleIncludes(oriel_dep)) |dir| compile.root_module.addIncludePath(dir);
        if (sdk) |root| macos_build.addPaths(compile.root_module, root) else {
            macos_build.requireSdk(b, compile, "Objective-C and Swift sources of .macos.hooks and extensions' .macos.objc");
            return;
        }
    }
    var swift = false;
    for (units.items) |u| {
        if (addAppleUnit(b, oriel_dep, compile, u, sdk)) swift = true;
    }
    if (swift) swift_build.linkRuntime(compile, sdk.?);
}

const IosResource = struct { path: std.Build.LazyPath, name: []const u8 };

/// Every extension's `.ios.resources`. Whether each is a file or a
/// directory is read while configuring, so `from` must exist then: a source
/// path or a (fetched) dependency's, not a build step's output.
fn iosExtensionResources(b: *std.Build, options: AppOptions) []const IosResource {
    var out: std.ArrayList(IosResource) = .empty;
    for (options.extensions) |e| {
        const x = e.ios orelse continue;
        for (x.resources) |res| {
            if (res.from == .generated) @panic(b.fmt("AppOptions.extensions: {s}: .ios.resources \"{s}\": a build step's output can't be a resource; use a source or dependency path", .{ e.name, res.to }));
            out.append(b.allocator, .{ .path = res.from, .name = res.to }) catch @panic("OOM");
        }
    }
    return out.items;
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
    for (options.include_paths) |p| app_root.addIncludePath(p);
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
            .{ .name = "oriel_app", .module = appConfigModule(b, oriel, cfg, null, app_icon, options) },
        },
    });
    for (options.include_paths) |p| app_root.addIncludePath(p);
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
    options: AppOptions,
) *std.Build.Module {
    const isolation = options.isolation;
    const pkg = options.package orelse PackageOptions{};
    const app_id = pkg.id orelse b.fmt("dev.oriel.{s}", .{options.name});
    const files = b.addWriteFiles();
    _ = files.addCopyFile(icon, "icon.png");
    if (isolation) |iso| _ = files.addCopyFile(iso.hook, "isolation_hook.js");
    const root = files.add("oriel_app.zig", b.fmt("{s}{f}{s}{s}", .{
        \\const oriel = @import("oriel");
        \\const cfg = @import("cfg");
        \\
        \\/// Everything build.zig declares: pass to `App.Config.app`.
        \\pub const build: oriel.App.Build = .{
        \\    .id = id,
        \\    .assets = assets,
        \\    .dev = dev,
        \\    .icon = icon_bytes,
        \\    .url_schemes = url_schemes,
        \\    .permissions = permissions,
        \\    .isolation = isolation,
        \\};
        \\
        \\/// Base64-encoded Ed25519 public key for verifying updates.
        \\pub const update_public_key: ?[]const u8 = cfg.update_public_key;
        \\
        \\/// The app id (`.package.id`, else "dev.oriel.<name>").
        \\const id: [:0]const u8 = "
        ,
        std.zig.fmtString(app_id),
        \\";
        \\
        \\/// Embedded frontend files (empty in dev builds).
        \\const assets: []const oriel.App.Asset = if (cfg.is_dev) &.{} else @import("assets").files;
        \\
        \\/// Dev-server settings (null in production builds).
        \\const dev: ?oriel.App.Dev = if (cfg.is_dev) .{
        \\    .url = cfg.dev_url,
        \\    .command = cfg.dev_command,
        \\    .cwd = cfg.frontend_dir,
        \\} else null;
        \\
        \\/// Embedded application icon (PNG bytes).
        \\const icon_bytes: []const u8 = @embedFile("icon.png");
        \\
        \\/// Declared URL schemes handled by the application.
        \\const url_schemes: []const []const u8 = cfg.url_schemes;
        \\
        \\/// Declared OS permissions (`.permissions` in build.zig, plus the ones
        \\/// enabled modules need): only these can be requested.
        \\const permissions: oriel.permissions.Declared = .{
        \\    .microphone = cfg.permission_microphone,
        \\    .camera = cfg.permission_camera,
        \\    .screen_capture = cfg.permission_screen_capture,
        \\    .accessibility = cfg.permission_accessibility,
        \\    .location = cfg.permission_location,
        \\    .notifications = cfg.permission_notifications,
        \\    .system_audio = cfg.permission_system_audio,
        \\    .bluetooth = cfg.permission_bluetooth,
        \\    .local_network = cfg.permission_local_network,
        \\};
        \\
        \\/// The isolation hook (`.isolation` in build.zig). Null without one.
        \\
        ,
        if (isolation != null)
            "const isolation: ?oriel.security.Isolation = .{ .hook = @embedFile(\"isolation_hook.js\") };\n"
        else
            "const isolation: ?oriel.security.Isolation = null;\n",
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
    include_paths: []const std.Build.LazyPath,
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
    for (include_paths) |p| exe.root_module.addIncludePath(p);
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
                "YGConfig.cpp",        "YGEnums.cpp",            "YGNode.cpp",             "YGNodeLayout.cpp",
                "YGNodeStyle.cpp",     "YGPixelGrid.cpp",        "YGValue.cpp",            "algorithm/AbsoluteLayout.cpp",
                "algorithm/Cache.cpp", "algorithm/FlexLine.cpp", "config/Config.cpp",      "debug/AssertFatal.cpp",
                "debug/Log.cpp",       "event/event.cpp",        "node/LayoutResults.cpp", "node/Node.cpp",
            },
            .flags = &.{ "-std=c++20", "-O2", no_ubsan, "-fno-exceptions" },
        });
        oriel.addCSourceFile(.{
            .file = patchedYogaLayout(b, yoga.path("yoga/algorithm/CalculateLayout.cpp")),
            .flags = &.{ "-std=c++20", "-O2", no_ubsan, "-fno-exceptions" },
        });
        oriel.addCSourceFile(.{
            .file = patchedYogaBaseline(b, yoga.path("yoga/algorithm/Baseline.cpp")),
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

/// Yoga's Baseline.cpp with a box's baseline taken from where its first
/// child will sit (the box's top padding and border, and how it aligns the
/// child), not from the child's laid-out position: while the row around the
/// box is being sized that is a previous layout's (0 the first time), so a
/// button beside text sat 3 px high and the row came out 3 px taller than
/// WebKit's (29, not 26). The build stops if Yoga's text changed (look at
/// the fix again).
fn patchedYogaBaseline(b: *std.Build, src: std.Build.LazyPath) std.Build.LazyPath {
    const io = b.graph.io;
    const text = std.Io.Dir.cwd().readFileAlloc(io, src.getPath(b), b.allocator, .limited(1 << 20)) catch |e|
        std.debug.panic("yoga: can't read Baseline.cpp: {s}", .{@errorName(e)});
    const fixes = [_][2][]const u8{
        .{
            \\float calculateBaseline(const yoga::Node* node) {
            ,
            \\// Oriel (build.zig patchedYogaBaseline): where the baseline child's
            \\// top sits in `node`, from the node's own top padding and border and
            \\// how it places the child (a column: justify-content over all its
            \\// children; a row: the child's alignment), as the layout will.
            \\static float orielChildTop(const yoga::Node* node, const yoga::Node* child) {
            \\  const auto& s = node->style();
            \\  const float width = node->getLayout().measuredDimension(Dimension::Width);
            \\  const float height = node->getLayout().measuredDimension(Dimension::Height);
            \\  const float childHeight = child->getLayout().measuredDimension(Dimension::Height);
            \\  if (std::isnan(height) || std::isnan(childHeight)) {
            \\    return child->getLayout().position(PhysicalEdge::Top);
            \\  }
            \\  const float lead = s.computeFlexStartPaddingAndBorder(FlexDirection::Column, Direction::LTR, width);
            \\  const float inner = height - lead -
            \\      s.computeFlexEndPaddingAndBorder(FlexDirection::Column, Direction::LTR, width);
            \\  const float margin = child->style().computeFlexStartMargin(FlexDirection::Column, Direction::LTR, width);
            \\  float at = 0;
            \\  if (isColumn(s.flexDirection())) {
            \\    float used = 0;
            \\    for (auto c : node->getLayoutChildren()) {
            \\      if (c->style().positionType() == PositionType::Absolute) continue;
            \\      used += c->getLayout().measuredDimension(Dimension::Height) +
            \\          c->style().computeMarginForAxis(FlexDirection::Column, width);
            \\    }
            \\    if (s.justifyContent() == Justify::Center) at = (inner - used) / 2;
            \\    else if (s.justifyContent() == Justify::FlexEnd) at = inner - used;
            \\  } else {
            \\    const float outer = childHeight + child->style().computeMarginForAxis(FlexDirection::Column, width);
            \\    const Align align = resolveChildAlignment(node, child);
            \\    if (align == Align::Center) at = (inner - outer) / 2;
            \\    else if (align == Align::FlexEnd) at = inner - outer;
            \\  }
            \\  return lead + at + margin;
            \\}
            \\
            \\float calculateBaseline(const yoga::Node* node) {
        },
        .{
            \\  return baseline + baselineChild->getLayout().position(PhysicalEdge::Top);
            ,
            \\  return baseline + orielChildTop(node, baselineChild);
        },
    };
    var out: []const u8 = text;
    for (fixes) |fix| {
        if (std.mem.count(u8, out, fix[0]) != 1) std.debug.panic("yoga: Baseline.cpp changed; patchedYogaBaseline's fix no longer applies", .{});
        out = std.mem.replaceOwned(u8, b.allocator, out, fix[0], fix[1]) catch @panic("OOM");
    }
    const files = b.addWriteFiles();
    return files.add("Baseline.cpp", out);
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
