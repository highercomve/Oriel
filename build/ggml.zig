//! GGML, llama.cpp, and whisper.cpp build configuration for Oriel.
//!
//! Compiles ggml base and ggml-cpu (single shared ggml library), plus
//! llama.cpp and/or whisper.cpp when their corresponding feature is enabled.
//!
//! With `ggml_cuda`, the CUDA backend is built separately by nvcc into
//! `libggml-cuda.so`, which the app loads at runtime (`whisper.loadGpuBackends`,
//! `llama.loadGpuBackends`). It stays a separate library because nvcc's host
//! code uses GCC's libstdc++ while Zig builds C++ against libc++; the ggml
//! backend interface between them is plain C. The library resolves ggml's
//! own symbols from the executable (`rdynamic`, set by `addApp`).
//!
//! With `ggml_vulkan`, the Vulkan backend (any GPU vendor) is built the same
//! way into `libggml-vulkan.so`: its shaders are compiled to SPIR-V with
//! `glslc` by ggml's own generator (vulkan-shaders-gen, built for the host)
//! and embedded. The library links the Vulkan loader, so on a machine without
//! one it doesn't load and ggml stays on the CPU.

const std = @import("std");

/// A user error in the build options: a message, not a stack trace.
fn buildFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub const CudaOptions = struct {
    /// CUDA toolkit root (contains bin/nvcc and lib64).
    path: []const u8,
    /// nvcc `-arch` value: "native" (the GPUs in this machine), "sm_89",
    /// "all-major", ...; or a comma-separated list of compute capabilities
    /// ("75,86,89,120"): machine code for each, plus PTX for the newest so
    /// later GPUs can still run it.
    arch: []const u8,
    /// Link cuBLAS statically: the library then needs only the NVIDIA
    /// driver (libcuda.so.1), not a CUDA toolkit on the user's machine.
    static: bool = false,
    /// A libggml-cuda.so built earlier with the same Oriel (ggml) version and
    /// options: used as is, nvcc doesn't run (CI caches the ~70 min build).
    prebuilt: ?[]const u8 = null,
};

/// nvcc arguments selecting the GPU architectures (see `CudaOptions.arch`).
fn cudaArchArgs(b: *std.Build, arch: []const u8) []const []const u8 {
    if (std.mem.indexOfScalar(u8, arch, ',') == null and !isComputeCapability(arch)) {
        return b.allocator.dupe([]const u8, &.{b.fmt("-arch={s}", .{arch})}) catch @panic("OOM");
    }
    var args: std.ArrayList([]const u8) = .empty;
    var ptx: ?[]const u8 = null;
    var it = std.mem.tokenizeAny(u8, arch, ", ");
    while (it.next()) |cc| {
        if (!isComputeCapability(cc)) buildFail("-Dcuda_arch: \"{s}\" is not a compute capability (e.g. 89, 120a)", .{cc});
        args.append(b.allocator, b.fmt("-gencode=arch=compute_{s},code=sm_{s}", .{ cc, cc })) catch @panic("OOM");
        // Architecture-specific targets (120a: Blackwell's FP4 MMA) have no
        // forward-compatible PTX; the newest generic one provides it.
        if (std.ascii.isDigit(cc[cc.len - 1])) ptx = cc;
    }
    if (args.items.len == 0) buildFail("-Dcuda_arch: no compute capability in \"{s}\"", .{arch});
    if (ptx) |cc| args.append(b.allocator, b.fmt("-gencode=arch=compute_{s},code=compute_{s}", .{ cc, cc })) catch @panic("OOM");
    return args.items;
}

/// "89", or "120a" / "100f" (architecture- and family-specific targets).
fn isComputeCapability(s: []const u8) bool {
    if (s.len < 2) return false;
    const digits = if (s[s.len - 1] == 'a' or s[s.len - 1] == 'f') s[0 .. s.len - 1] else s;
    for (digits) |ch| if (!std.ascii.isDigit(ch)) return false;
    return true;
}

pub const VulkanOptions = struct {
    /// The `glslc` shader compiler (shaderc).
    glslc: []const u8,
    /// Directory with vulkan/vulkan.hpp and spirv/ headers, when they aren't
    /// in the compiler's default paths (Windows: the Vulkan SDK's Include).
    include: ?[]const u8 = null,
    /// The same as build paths (Android: the Vulkan-Headers and
    /// SPIRV-Headers dependencies; the NDK has neither vulkan.hpp nor spirv/).
    include_paths: []const std.Build.LazyPath = &.{},
};

/// `-Dggml_opencl` (Android): ggml-opencl compiled in, for Adreno GPUs.
pub const OpenClOptions = struct {
    /// Khronos OpenCL-Headers (the `opencl_headers` dependency).
    headers: std.Build.LazyPath,
};

/// Which optional shader extensions `glslc` supports, as ggml's CMake finds
/// them: compile each feature test and look for "extension not supported".
fn vulkanFeatures(b: *std.Build, ggml_root: std.Build.LazyPath, glslc: []const u8) []const []const u8 {
    const tests = [_]struct { ext: []const u8, file: []const u8, define: []const u8 }{
        .{ .ext = "GL_KHR_cooperative_matrix", .file = "coopmat.comp", .define = "GGML_VULKAN_COOPMAT_GLSLC_SUPPORT" },
        .{ .ext = "GL_NV_cooperative_matrix2", .file = "coopmat2.comp", .define = "GGML_VULKAN_COOPMAT2_GLSLC_SUPPORT" },
        .{ .ext = "GL_NV_cooperative_matrix_decode_vector", .file = "coopmat2_decode_vector.comp", .define = "GGML_VULKAN_COOPMAT2_DECODE_VECTOR_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_integer_dot_product", .file = "integer_dot.comp", .define = "GGML_VULKAN_INTEGER_DOT_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_bfloat16", .file = "bfloat16.comp", .define = "GGML_VULKAN_BFLOAT16_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_float_e2m1", .file = "float_e2m1.comp", .define = "GGML_VULKAN_FLOAT_E2M1_GLSLC_SUPPORT" },
        .{ .ext = "GL_EXT_float_e4m3", .file = "float_e4m3.comp", .define = "GGML_VULKAN_FLOAT_E4M3_GLSLC_SUPPORT" },
    };
    var defines: std.ArrayList([]const u8) = .empty;
    for (tests) |t| {
        const file = ggml_root.path(b, b.fmt("src/ggml-vulkan/vulkan-shaders/feature-tests/{s}", .{t.file})).getPath(b);
        const result = std.process.run(b.allocator, b.graph.io, .{
            .argv = &.{ glslc, "-o", "-", "-fshader-stage=compute", "--target-env=vulkan1.3", file },
        }) catch |err| buildFail("-Dggml_vulkan: running {s} failed ({s}); install shaderc or pass -Dglslc", .{ glslc, @errorName(err) });
        const unsupported = std.mem.indexOf(u8, result.stderr, b.fmt("extension not supported: {s}", .{t.ext})) != null;
        if (!unsupported) defines.append(b.allocator, t.define) catch @panic("OOM");
    }
    return defines.items;
}

/// ggml's Metal backend, compiled into the executable. The kernel sources
/// are embedded by tools/metal_embed.zig (GGML_METAL_EMBED_LIBRARY, as
/// ggml's CMake does), so neither Xcode's `metal` compiler nor a .metallib
/// is needed: ggml compiles them for the GPU at startup.
fn addMetalBackend(b: *std.Build, oriel: *std.Build.Module, ggml_root: std.Build.LazyPath, cpp_flags: []const []const u8, metal_defs: []const []const u8) void {
    const metal_dir = ggml_root.path(b, "src/ggml-metal");
    oriel.addIncludePath(metal_dir);
    oriel.addCSourceFiles(.{
        .root = metal_dir,
        .files = &.{ "ggml-metal.cpp", "ggml-metal-device.cpp", "ggml-metal-common.cpp", "ggml-metal-ops.cpp", "ggml-metal-tuning.cpp" },
        .flags = cpp_flags,
    });
    // Newer ggml (llama's) splits kernel fusion into its own file; the
    // ggml whisper.cpp ships (a whisper-only build) doesn't have it yet.
    const fusion = metal_dir.path(b, "ggml-metal-fusion.cpp");
    if (std.Io.Dir.cwd().access(b.graph.io, fusion.getPath(b), .{})) |_| {
        oriel.addCSourceFile(.{ .file = fusion, .flags = cpp_flags });
    } else |_| {}
    // Objective-C with manual retain/release, like upstream (no ARC).
    const objc_flags = std.mem.concat(b.allocator, []const u8, &.{ &.{ "-fno-objc-arc", "-D_DARWIN_C_SOURCE", "-fno-sanitize=undefined" }, metal_defs }) catch @panic("OOM");
    oriel.addCSourceFiles(.{
        .root = metal_dir,
        .files = &.{ "ggml-metal-device.m", "ggml-metal-context.m" },
        .flags = objc_flags,
    });
    const embed_tool = b.addExecutable(.{
        .name = "metal_embed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/metal_embed.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(embed_tool);
    run.addDirectoryArg(ggml_root.path(b, "src"));
    oriel.addAssemblyFile(run.addOutputFileArg("ggml-metal-embed.s"));
    oriel.linkFramework("Foundation", .{});
    oriel.linkFramework("Metal", .{});
    oriel.linkFramework("MetalKit", .{});
}

/// `-Dggml_arm`: the ARM extensions ggml's CPU code is compiled for (only
/// ggml, llama.cpp and whisper.cpp; the rest of the app keeps the target's
/// baseline). ggml picks its kernels at compile time: without dotprod its
/// quantized dot products are emulated, and its repacked matmul kernels
/// (q4_0, q8_0: 4x4 with dotprod, 4x8 with i8mm) are off. A CPU without
/// the extension is refused at model load (ggml_gpu.cpuSupported), not
/// crashed on.
pub const ArmLevel = enum {
    baseline,
    /// ARMv8.2 dotprod and fp16: every Cortex-A55/A75 and later (2018 on).
    dotprod,
    /// dotprod, fp16 and i8mm: Armv8.6 and v9 cores (Cortex-A510/A710/X2
    /// and later; Tensor G3, Snapdragon 8 Gen 1, Dimensity 9000 and later).
    i8mm,
};

pub fn addGgml(
    b: *std.Build,
    oriel: *std.Build.Module,
    features: anytype,
    cuda: ?CudaOptions,
    vulkan: ?VulkanOptions,
    opencl: ?OpenClOptions,
    metal: bool,
    arm: ArmLevel,
) void {
    if (!features.llama and !features.whisper and !features.kokoro) return;
    const llama_dep = if (features.llama) b.lazyDependency("llama", .{}) else null;
    const whisper_dep = if (features.whisper) b.lazyDependency("whisper", .{}) else null;
    const kokoro_dep = if (features.kokoro) b.lazyDependency("kokoro", .{}) else null;

    if (features.llama and llama_dep == null) return;
    if (features.whisper and whisper_dep == null) return;
    if (features.kokoro and kokoro_dep == null) return;

    // Link C++ runtime for ggml/llama/whisper
    oriel.link_libcpp = true;

    // Generated version headers
    const write_files = b.addWriteFiles();
    _ = write_files.add("ggml-version.h",
        \\#pragma once
        \\#define GGML_VERSION "0.23.0"
        \\#define GGML_COMMIT "b10809"
        \\
    );
    if (features.llama) {
        _ = write_files.add("llama-version.h",
            \\#pragma once
            \\#define LLAMA_VERSION "b10809"
            \\#define LLAMA_COMMIT "64a155d"
            \\
        );
    }
    oriel.addIncludePath(write_files.getDirectory());

    // Single ggml tree: pick llama if available, else whisper
    const ggml_dep = llama_dep orelse whisper_dep.?;
    const ggml_root = ggml_dep.path("ggml");

    oriel.addIncludePath(ggml_root.path(b, "include"));
    oriel.addIncludePath(ggml_root.path(b, "src"));
    oriel.addIncludePath(ggml_root.path(b, "src/ggml-cpu"));
    oriel.addIncludePath(ggml_root.path(b, "src/ggml-cpu/amx"));

    // Zig's Debug builds trap on C undefined behaviour; ggml does pointer
    // arithmetic on NULL on purpose (ggml_graph_nbytes sizes a graph that
    // way), so its sanitizer checks are off.
    // _XOPEN_SOURCE hides the BSD types (u_int, ...) that <sys/sysctl.h>
    // needs on macOS unless _DARWIN_C_SOURCE is set too (as ggml's CMake does).
    const darwin: []const []const u8 = if (oriel.resolved_target.?.result.os.tag.isDarwin()) &.{"-D_DARWIN_C_SOURCE"} else &.{};
    // GGML_USE_METAL makes ggml-backend-reg.cpp register the Metal device.
    const metal_defs: []const []const u8 = if (metal) &.{ "-DGGML_USE_METAL", "-DGGML_METAL_EMBED_LIBRARY" } else &.{};
    // ggml and whisper.cpp are compiled optimized in every build mode: at
    // -O0 (a Debug app) whisper ran ~30x slower on the CPU, 223 s for 8 s
    // of audio on a Pixel. Clang takes the last -O, so this one wins.
    const opt_level: []const []const u8 = if (oriel.optimize == .Debug or oriel.optimize == null) &.{"-O2"} else &.{};
    // Features as cc1 flags: after Zig's own -target-feature list, so they win.
    const dotprod: []const []const u8 = &.{ "-Xclang", "-target-feature", "-Xclang", "+dotprod", "-Xclang", "-target-feature", "-Xclang", "+fullfp16" };
    const i8mm: []const []const u8 = &.{ "-Xclang", "-target-feature", "-Xclang", "+i8mm" };
    const arm_flags: []const []const u8 = if (oriel.resolved_target.?.result.cpu.arch != .aarch64) &.{} else switch (arm) {
        .baseline => &.{},
        .dotprod => dotprod,
        .i8mm => std.mem.concat(b.allocator, []const u8, &.{ dotprod, i8mm }) catch @panic("OOM"),
    };
    const opt = std.mem.concat(b.allocator, []const u8, &.{ opt_level, arm_flags }) catch @panic("OOM");
    const c_flags = std.mem.concat(b.allocator, []const u8, &.{ opt, &.{ "-std=c11", "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600", "-DGGML_USE_CPU", "-fno-sanitize=undefined" }, darwin, metal_defs }) catch @panic("OOM");
    const cpp_flags = std.mem.concat(b.allocator, []const u8, &.{ opt, &.{ "-std=c++17", "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600", "-DGGML_USE_CPU", "-fno-sanitize=undefined" }, darwin, metal_defs }) catch @panic("OOM");

    // GGML base sources
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src"),
        .files = &.{
            "ggml.c",
            "ggml-alloc.c",
            "ggml-quants.c",
        },
        .flags = c_flags,
    });
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src"),
        .files = &.{
            "ggml.cpp",
            "ggml-backend.cpp",
            "ggml-backend-meta.cpp",
            "ggml-opt.cpp",
            "ggml-threading.cpp",
            "gguf.cpp",
            "ggml-backend-dl.cpp",
            "ggml-backend-reg.cpp",
        },
        .flags = cpp_flags,
    });

    // GGML CPU backend sources
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src/ggml-cpu"),
        .files = &.{
            "ggml-cpu.c",
            "quants.c",
        },
        .flags = c_flags,
    });
    oriel.addCSourceFiles(.{
        .root = ggml_root.path(b, "src/ggml-cpu"),
        .files = &.{
            "binary-ops.cpp",
            "ggml-cpu.cpp",
            "hbm.cpp",
            "iqp.cpp",
            "ops.cpp",
            "repack.cpp",
            "traits.cpp",
            "unary-ops.cpp",
            "vec.cpp",
            "amx/amx.cpp",
            "amx/mmq.cpp",
        },
        .flags = cpp_flags,
    });

    // Arch-specific CPU sources
    const target_arch = oriel.resolved_target.?.result.cpu.arch;
    if (target_arch == .x86_64) {
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/x86/quants.c"},
            .flags = c_flags,
        });
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/x86/repack.cpp"},
            .flags = cpp_flags,
        });
    } else if (target_arch.isArm() or target_arch.isAARCH64()) {
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/arm/quants.c"},
            .flags = c_flags,
        });
        oriel.addCSourceFiles(.{
            .root = ggml_root.path(b, "src/ggml-cpu"),
            .files = &.{"arch/arm/repack.cpp"},
            .flags = cpp_flags,
        });
    }

    if (cuda) |opts| b.addNamedLazyPath("libggml-cuda", if (opts.prebuilt) |p| .{ .cwd_relative = p } else addCudaBackend(b, ggml_root, opts));
    if (opencl) |opts| addOpenClStatic(b, oriel, ggml_root, cpp_flags, opts);
    if (vulkan) |opts| {
        // Windows and Android: compiled in (see addVulkanStatic).
        if (oriel.resolved_target.?.result.os.tag == .windows or oriel.resolved_target.?.result.abi.isAndroid())
            addVulkanStatic(b, oriel, ggml_root, cpp_flags, opts)
        else
            b.addNamedLazyPath("libggml-vulkan", addVulkanBackend(b, oriel, ggml_root, write_files.getDirectory(), opts));
    }
    if (metal) addMetalBackend(b, oriel, ggml_root, cpp_flags, metal_defs);

    // llama.cpp sources
    if (features.llama) {
        const l = llama_dep.?;
        oriel.addIncludePath(l.path("include"));
        oriel.addIncludePath(l.path("src"));
        oriel.addIncludePath(l.path("src/models"));

        oriel.addCSourceFiles(.{
            .root = l.path("src"),
            .files = &(llama_core_sources ++ llama_model_sources),
            .flags = cpp_flags,
        });
        if (features.llama_mtmd) addMtmd(b, oriel, l, c_flags, cpp_flags);

        // JSON schema → GBNF grammar (llama.JsonSchema): llama.cpp's converter
        // and its JSON type from `common`, not the whole library. The shim's
        // common.h comes first: it stands in for common/common.h.
        oriel.addIncludePath(b.path("src/modules/llama/shim"));
        oriel.addIncludePath(l.path("common"));
        oriel.addIncludePath(l.path("vendor"));
        oriel.addCSourceFiles(.{
            .root = l.path("common"),
            // json-schema.cpp and trie.cpp/unicode.cpp: what the converter
            // and its JSON type now reference from `common` (the shim's
            // common.h stands in for the whole library).
            .files = &.{ "json-schema-to-grammar.cpp", "json.cpp", "json-schema.cpp", "trie.cpp", "unicode.cpp" },
            .flags = cpp_flags,
        });
        oriel.addCSourceFiles(.{
            .root = b.path("src/modules/llama"),
            .files = &.{"json_schema_grammar.cpp"},
            .flags = cpp_flags,
        });
    }

    // whisper.cpp sources
    if (features.whisper) {
        const w = whisper_dep.?;
        oriel.addIncludePath(w.path("include"));
        oriel.addIncludePath(w.path("src"));

        const whisper_flags = std.mem.concat(b.allocator, []const u8, &.{ opt, &.{
            "-std=c++17",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
            "-DGGML_USE_CPU",
            "-fno-sanitize=undefined",
            "-DWHISPER_VERSION=\"1.9.4\"",
            "-DWHISPER_BUILD_COMMIT=\"v1.9.4\"",
        }, darwin }) catch @panic("OOM");

        oriel.addCSourceFiles(.{
            .root = w.path("src"),
            .files = &.{"whisper.cpp"},
            .flags = whisper_flags,
        });
        // Silero VAD v6.2.0 in ggml format (whisper.VadModel): 885 KB, the
        // same bytes as ggml-org/whisper-vad's ggml-silero-v6.2.0.bin.
        oriel.addAnonymousImport("whisper_vad_model", .{ .root_source_file = w.path("models/for-tests-silero-v6.2.0-ggml.bin") });
    }

    // kokoro.cpp TTS sources (Kokoro-82M synthesis), with espeak-ng for
    // phonemization and Highway for the CPU synthesis SIMD. The data dir
    // espeak-ng needs at runtime is not a build artifact: the app passes its
    // own directory through KOKORO_ESPEAK_DATA_PATH at init.
    if (features.kokoro) {
        const k = kokoro_dep.?;
        const hwy_dep = b.lazyDependency("highway", .{}) orelse return;
        const espeak_dep = b.lazyDependency("espeak_ng", .{}) orelse return;

        const kokoro_flags = std.mem.concat(b.allocator, []const u8, &.{ opt, &.{
            "-std=c++17",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
            "-DGGML_USE_CPU",
            "-fno-sanitize=undefined",
            "-DKOKORO_BUILD",
        }, darwin }) catch @panic("OOM");

        oriel.addIncludePath(k.path("include"));
        oriel.addIncludePath(k.path("src"));
        oriel.addCSourceFiles(.{
            .root = k.path("src"),
            .files = &.{ "kokoro.cpp", "core/gguf_loader.cpp", "core/simd_math.cpp" },
            .flags = kokoro_flags,
        });

        // Highway's runtime library (used through simd_math.cpp): headers
        // only for the SIMD ops, these nine sources for targets/dispatch.
        oriel.addIncludePath(hwy_dep.path("."));
        oriel.addCSourceFiles(.{
            .root = hwy_dep.path("hwy"),
            .files = &.{
                "abort.cc",
                "aligned_allocator.cc",
                "nanobenchmark.cc",
                "per_target.cc",
                "perf_counters.cc",
                "print.cc",
                "profiler.cc",
                "targets.cc",
                "timer.cc",
            },
            .flags = kokoro_flags,
        });

        // libespeak-ng (GPL-3): phonemization only, so the optional audio
        // backends stay off. Its own config.h is generated here (espeak-ng's
        // CMake builds it from configure); our flags keep it minimal.
        const espeak_config = b.addWriteFiles();
        _ = espeak_config.add("config.h",
            \\#pragma once
            \\#define LIBESPEAK_NG_EXPORT 1
            \\#define HAVE_MKSTEMP 1
            \\#define USE_ASYNC 0
            \\#define USE_KLATT 1
            \\#define USE_LIBPCAUDIO 0
            \\#define USE_LIBSONIC 0
            \\#define USE_MBROLA 0
            \\#define USE_SPEECHPLAYER 0
            \\#define PACKAGE_VERSION "1.52.0"
            \\#define PATH_ESPEAK_DATA "."
            \\
        );
        oriel.addIncludePath(espeak_config.getDirectory());
        oriel.addIncludePath(espeak_dep.path("src/include"));
        oriel.addIncludePath(espeak_dep.path("src/libespeak-ng"));
        oriel.addIncludePath(espeak_dep.path("src/ucd-tools/src/include"));
        {
            const espeak_cflags = std.mem.concat(b.allocator, []const u8, &.{ opt, &.{
                "-std=c11",
                "-D_GNU_SOURCE",
                "-D_XOPEN_SOURCE=600",
                "-fno-sanitize=undefined",
            }, darwin }) catch @panic("OOM");
            oriel.addCSourceFiles(.{
                .root = espeak_dep.path("src/libespeak-ng"),
                .files = &.{
                    "common.c",
                    "compiledict.c",
                    "espeak_api.c",
                    "error.c",
                    "ieee80.c",
                    "intonation.c",
                    "langopts.c",
                    "mnemonics.c",
                    "numbers.c",
                    "phoneme.c",
                    "phonemelist.c",
                    "readclause.c",
                    "setlengths.c",
                    "soundicon.c",
                    "spect.c",
                    "ssml.c",
                    "synthdata.c",
                    "synthesize.c",
                    "speech.c",
                    "tr_languages.c",
                    "translate.c",
                    "translateword.c",
                    "voices.c",
                    "wavegen.c",
                    "klatt.c",
                    "dictionary.c",
                    "encoding.c",
                },
                .flags = espeak_cflags,
            });
            oriel.addCSourceFiles(.{
                .root = espeak_dep.path("src/ucd-tools/src"),
                .files = &.{
                    "case.c",
                    "categories.c",
                    "ctype.c",
                    "proplist.c",
                    "scripts.c",
                    "tostring.c",
                },
                .flags = espeak_cflags,
            });
        }
    }
}

/// Compile ggml-cuda with nvcc (one cached step per source) and link it into
/// a loadable backend module. Returns the path of `libggml-cuda.so`.
fn addCudaBackend(b: *std.Build, ggml_root: std.Build.LazyPath, opts: CudaOptions) std.Build.LazyPath {
    const nvcc = b.pathJoin(&.{ opts.path, "bin", "nvcc" });
    const link = b.addSystemCommand(&.{ nvcc, "-shared", "-o" });
    const lib = link.addOutputFileArg("libggml-cuda.so");
    for (cuda_sources) |src| {
        const cc = b.addSystemCommand(&.{
            nvcc,                "-std=c++17",             "-O3",
            "-use_fast_math",    "-extended-lambda",       "-compress-mode=size",
            "-Xcompiler",        "-fPIC -Wno-pedantic",    "-DNDEBUG",
            // Build as a dynamically loaded backend (exports ggml_backend_init).
            "-DGGML_BACKEND_DL", "-DGGML_BACKEND_BUILD",   "-DGGML_BACKEND_SHARED",
            "-DGGML_SHARED",     "-DGGML_CUDA_USE_GRAPHS", "-DGGML_SCHED_MAX_COPIES=4",
        });
        cc.addArgs(fattn_defines);
        cc.addArgs(cudaArchArgs(b, opts.arch));
        cc.addPrefixedDirectoryArg("-I", ggml_root.path(b, "include"));
        cc.addPrefixedDirectoryArg("-I", ggml_root.path(b, "src"));
        cc.addPrefixedDirectoryArg("-I", ggml_root.path(b, "src/ggml-cuda"));
        cc.addArg("-c");
        cc.addFileArg(ggml_root.path(b, b.fmt("src/ggml-cuda/{s}", .{src})));
        cc.addArg("-o");
        const obj = cc.addOutputFileArg(b.fmt("{s}.o", .{std.fs.path.stem(src)}));
        link.addFileArg(obj);
    }
    // cudart is linked statically by nvcc; the driver stays dynamic.
    if (opts.static) {
        // Only the kernels ggml calls are kept, but cuBLASLt's are large.
        link.addArgs(cudaArchArgs(b, opts.arch));
        link.addArgs(&.{ "-lcublas_static", "-lcublasLt_static", "-lculibos", "-lcuda" });
    } else {
        link.addArgs(&.{ "-lcublas", "-lcublasLt", "-lcuda" });
    }
    return lib;
}

/// Build vulkan-shaders-gen for the host, with the shader features `glslc`
/// supports, and run it once for the header every shader source includes.
fn vulkanShadersGen(b: *std.Build, ggml_root: std.Build.LazyPath, glslc: []const u8, defines: *std.ArrayList([]const u8)) struct { gen: *std.Build.Step.Compile, header: *std.Build.Step.Run, header_file: std.Build.LazyPath } {
    const shaders_dir = ggml_root.path(b, "src/ggml-vulkan/vulkan-shaders");
    for (vulkanFeatures(b, ggml_root, glslc)) |f| defines.append(b.allocator, b.fmt("-D{s}", .{f})) catch @panic("OOM");
    const gen = b.addExecutable(.{
        .name = "vulkan-shaders-gen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
            .link_libcpp = true,
        }),
    });
    gen.root_module.addCSourceFile(.{
        .file = shaders_dir.path(b, "vulkan-shaders-gen.cpp"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{ &.{"-std=c++17"}, defines.items }) catch @panic("OOM"),
    });
    const header = b.addRunArtifact(gen);
    header.addArg("--output-dir");
    _ = header.addOutputDirectoryArg("spv");
    header.addArg("--target-hpp");
    const header_file = header.addOutputFileArg(vulkan_shaders_header);
    return .{ .gen = gen, .header = header, .header_file = header_file };
}

const vulkan_shaders_header = "ggml-vulkan-shaders.hpp";

/// The files in `shaders_dir` ending in `ext`, sorted: the .comp sources
/// vulkan-shaders-gen compiles (ggml's CMake globs them too) and the .glsl
/// files they #include. Listed rather than hard-coded because llama.cpp's
/// and whisper.cpp's ggml trees have different shaders.
fn vulkanShaderFiles(b: *std.Build, shaders_dir: std.Build.LazyPath, ext: []const u8) []const []const u8 {
    const io = b.graph.io;
    const path = shaders_dir.getPath(b);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err|
        buildFail("-Dggml_vulkan: can't open {s} ({s})", .{ path, @errorName(err) });
    defer dir.close(io);
    var files: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch |err| buildFail("-Dggml_vulkan: can't list {s} ({s})", .{ path, @errorName(err) })) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ext)) files.append(b.allocator, b.dupe(entry.name)) catch @panic("OOM");
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return files.items;
}

/// One generated .cpp per shader source (cached, parallel steps).
fn addVulkanShaders(b: *std.Build, m: *std.Build.Module, ggml_root: std.Build.LazyPath, gen: *std.Build.Step.Compile, glslc: []const u8, flags: []const []const u8) void {
    const shaders_dir = ggml_root.path(b, "src/ggml-vulkan/vulkan-shaders");
    const includes = vulkanShaderFiles(b, shaders_dir, ".glsl");
    for (vulkanShaderFiles(b, shaders_dir, ".comp")) |src| {
        const run = b.addRunArtifact(gen);
        run.addArgs(&.{ "--glslc", glslc, "--source" });
        run.addFileArg(shaders_dir.path(b, src));
        run.addArg("--output-dir");
        _ = run.addOutputDirectoryArg("spv");
        // Only its basename is used (the #include in the generated source).
        run.addArgs(&.{ "--target-hpp", vulkan_shaders_header, "--target-cpp" });
        const cpp = run.addOutputFileArg(b.fmt("{s}.cpp", .{src}));
        // Shaders #include the .glsl files next to them.
        for (includes) |inc| run.addFileInput(shaders_dir.path(b, inc));
        m.addCSourceFile(.{ .file = cpp, .flags = flags });
    }
}

/// Windows: ggml-vulkan compiled into the executable. A DLL couldn't take
/// ggml's symbols from the executable (no rdynamic), and linking vulkan-1.lib
/// would keep the app from starting without a Vulkan loader: instead
/// src/modules/ggml_vulkan_loader.c provides vkGetInstanceProcAddr from
/// vulkan-1.dll when present, and ggml_gpu.load() registers the backend
/// only then (GGML_USE_VULKAN stays off, so ggml doesn't register it itself).
fn addVulkanStatic(b: *std.Build, oriel: *std.Build.Module, ggml_root: std.Build.LazyPath, cpp_flags: []const []const u8, opts: VulkanOptions) void {
    var defines: std.ArrayList([]const u8) = .empty;
    const sg = vulkanShadersGen(b, ggml_root, opts.glslc, &defines);
    if (opts.include) |inc| oriel.addIncludePath(.{ .cwd_relative = inc });
    for (opts.include_paths) |inc| oriel.addIncludePath(inc);
    oriel.addIncludePath(sg.header_file.dirname());
    oriel.addIncludePath(ggml_root.path(b, "src/ggml-vulkan"));
    const flags = std.mem.concat(b.allocator, []const u8, &.{ cpp_flags, defines.items }) catch @panic("OOM");
    oriel.addCSourceFile(.{ .file = ggml_root.path(b, "src/ggml-vulkan/ggml-vulkan.cpp"), .flags = flags });
    addVulkanShaders(b, oriel, ggml_root, sg.gen, opts.glslc, flags);
    const loader = if (oriel.resolved_target.?.result.abi.isAndroid()) "src/modules/ggml_vulkan_loader_android.c" else "src/modules/ggml_vulkan_loader.c";
    oriel.addCSourceFile(.{ .file = b.path(loader), .flags = &.{"-std=c11"} });
}

/// Android: ggml-opencl compiled into liboriel.so with its kernels embedded
/// (tools/embed_cl.zig) and the Adreno-tuned matmul kernels. OpenCL itself
/// comes from the device's libOpenCL.so through src/modules/ggml_opencl_loader.c,
/// and ggml_gpu.load() registers the backend only on an Adreno GPU (ggml's
/// OpenCL kernels target it; other GPUs get Vulkan).
fn addOpenClStatic(b: *std.Build, oriel: *std.Build.Module, ggml_root: std.Build.LazyPath, cpp_flags: []const []const u8, opts: OpenClOptions) void {
    const cl_dir = ggml_root.path(b, "src/ggml-opencl");
    const embed = b.addExecutable(.{
        .name = "embed_cl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/embed_cl.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(embed);
    run.addDirectoryArg(cl_dir.path(b, "kernels"));
    const kernels = run.addOutputDirectoryArg("kernels");
    oriel.addIncludePath(opts.headers);
    oriel.addIncludePath(kernels);
    const flags = std.mem.concat(b.allocator, []const u8, &.{ cpp_flags, &.{
        "-DGGML_OPENCL_EMBED_KERNELS",
        "-DGGML_OPENCL_SOA_Q",
        "-DGGML_OPENCL_TARGET_VERSION=300",
        "-DGGML_OPENCL_USE_ADRENO_KERNELS",
        "-DCL_USE_DEPRECATED_OPENCL_1_2_APIS",
    } }) catch @panic("OOM");
    oriel.addCSourceFiles(.{ .root = cl_dir, .files = &.{ "ggml-opencl.cpp", "cl-program-cache.cpp" }, .flags = flags });
    oriel.addCSourceFile(.{ .file = b.path("src/modules/ggml_opencl_loader.c"), .flags = &.{"-std=c11"} });
}

/// Generate the Vulkan shaders (one cached step per .comp source, as ggml's
/// CMake does) and build `libggml-vulkan.so` from them and ggml-vulkan.cpp.
/// Returns the library's path.
fn addVulkanBackend(
    b: *std.Build,
    oriel: *std.Build.Module,
    ggml_root: std.Build.LazyPath,
    version_headers: std.Build.LazyPath,
    opts: VulkanOptions,
) std.Build.LazyPath {
    const vk_dir = ggml_root.path(b, "src/ggml-vulkan");
    var defines: std.ArrayList([]const u8) = .empty;
    const sg = vulkanShadersGen(b, ggml_root, opts.glslc, &defines);

    const lib = b.addLibrary(.{
        .name = "ggml-vulkan",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .target = oriel.resolved_target.?,
            .optimize = oriel.optimize.?,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    // ggml's own symbols come from the executable (rdynamic), like CUDA's.
    lib.linker_allow_shlib_undefined = true;
    const m = lib.root_module;
    m.linkSystemLibrary("vulkan", .{});
    if (opts.include) |inc| m.addIncludePath(.{ .cwd_relative = inc });
    m.addIncludePath(sg.header_file.dirname());
    m.addIncludePath(version_headers);
    m.addIncludePath(ggml_root.path(b, "include"));
    m.addIncludePath(ggml_root.path(b, "src"));
    m.addIncludePath(vk_dir);
    const flags = std.mem.concat(b.allocator, []const u8, &.{
        &.{
            "-std=c++17",              "-D_GNU_SOURCE",     "-DNDEBUG",
            "-fno-sanitize=undefined",
            // Build as a dynamically loaded backend (exports ggml_backend_init).
            "-DGGML_BACKEND_DL", "-DGGML_BACKEND_BUILD",
            "-DGGML_BACKEND_SHARED",   "-DGGML_SHARED",     "-DGGML_SCHED_MAX_COPIES=4",
        },
        defines.items,
    }) catch @panic("OOM");
    m.addCSourceFile(.{ .file = vk_dir.path(b, "ggml-vulkan.cpp"), .flags = flags });
    // The header must exist before any source that includes it compiles.
    lib.step.dependOn(&sg.header.step);
    addVulkanShaders(b, m, ggml_root, sg.gen, opts.glslc, flags);
    return lib.getEmittedBin();
}

/// llama.cpp's multimodal library (tools/mtmd: images and audio for vision
/// models, through their projector GGUF), with the header-only libraries it
/// includes (stb_image, miniaudio, subprocess.h) and vendor/hash. Video
/// (MTMD_VIDEO, which runs ffmpeg) stays off.
fn addMtmd(b: *std.Build, oriel: *std.Build.Module, l: *std.Build.Dependency, c_flags: []const []const u8, cpp_flags: []const []const u8) void {
    const vendor = l.path("vendor");
    oriel.addIncludePath(l.path("tools/mtmd"));
    oriel.addIncludePath(vendor);
    const warn: []const []const u8 = &.{ "-Wno-cast-qual", "-w" };
    const mtmd_flags = std.mem.concat(b.allocator, []const u8, &.{ cpp_flags, warn }) catch @panic("OOM");
    oriel.addCSourceFiles(.{ .root = l.path("tools/mtmd"), .files = &mtmd_sources, .flags = mtmd_flags });
    // vendor/hash: its sources include their siblings by name.
    oriel.addIncludePath(vendor.path(b, "hash"));
    oriel.addCSourceFiles(.{ .root = vendor.path(b, "hash"), .files = &.{"hash.cpp"}, .flags = mtmd_flags });
    const hash_c = std.mem.concat(b.allocator, []const u8, &.{ c_flags, warn }) catch @panic("OOM");
    oriel.addCSourceFiles(.{ .root = vendor.path(b, "hash"), .files = &.{ "xxhash/xxhash.c", "sha256/sha256.c" }, .flags = hash_c });
    // sha1 is compiled as C++ (it lives in a namespace, like upstream).
    oriel.addCSourceFile(.{ .file = vendor.path(b, "hash/sha1/sha1.c"), .flags = mtmd_flags, .language = .cpp });
}

/// tools/mtmd/CMakeLists.txt `add_library(mtmd ...)`.
const mtmd_sources = [_][]const u8{
    "mtmd.cpp",
    "mtmd-audio.cpp",
    "mtmd-image.cpp",
    "mtmd-helper.cpp",
    "mtmd-helper-gen.cpp",
    "clip.cpp",
    "models/cogvlm.cpp",
    "models/conformer.cpp",
    "models/deepseek4v.cpp",
    "models/dots3note.cpp",
    "models/dotsocr.cpp",
    "models/exaone4_5.cpp",
    "models/gemma4a.cpp",
    "models/gemma4v.cpp",
    "models/gemma4ua.cpp",
    "models/gemma4uv.cpp",
    "models/glm4v.cpp",
    "models/granite-speech.cpp",
    "models/granite4-vision.cpp",
    "models/hunyuanvl.cpp",
    "models/internvl.cpp",
    "models/kimivl.cpp",
    "models/kimik25.cpp",
    "models/nemotron-v2-vl.cpp",
    "models/muse-glimmer.cpp",
    "models/llama4.cpp",
    "models/llava.cpp",
    "models/minicpmv.cpp",
    "models/paddleocr.cpp",
    "models/pixtral.cpp",
    "models/qwen2vl.cpp",
    "models/minimax-m3.cpp",
    "models/qwen3vl.cpp",
    "models/mimovl.cpp",
    "models/qwen3a.cpp",
    "models/mimo-audio.cpp",
    "models/qwen3tts-spkenc.cpp",
    "models/qwen3tts-gen.cpp",
    "models/pockettts-seanet.cpp",
    "models/pockettts-spkenc.cpp",
    "models/pockettts-gen.cpp",
    "models/step3vl.cpp",
    "models/siglip.cpp",
    "models/whisper-enc.cpp",
    "models/deepseekocr.cpp",
    "models/deepseekocr2.cpp",
    "models/mobilenetv5.cpp",
    "models/youtuvl.cpp",
    "models/yasa2.cpp",
    "models/parakeet.cpp",
};

const cuda_sources = [_][]const u8{
    "acc.cu",
    "add-id.cu",
    "allreduce.cu",
    "arange.cu",
    "argmax.cu",
    "argsort.cu",
    "binbcast.cu",
    "clamp.cu",
    "col2im-1d.cu",
    "concat.cu",
    "conv2d.cu",
    "conv2d-dw.cu",
    "conv2d-transpose.cu",
    "convert.cu",
    "conv-transpose-1d.cu",
    "count-equal.cu",
    "cpy.cu",
    "cross-entropy-loss.cu",
    "cumsum.cu",
    "diag.cu",
    "diagmask.cu",
    "dsv4-hc.cu",
    "fattn.cu",
    "fattn-tile.cu",
    "fill.cu",
    "fwht.cu",
    "gated_delta_net.cu",
    "getrows.cu",
    "ggml-cuda.cu",
    "gla.cu",
    "im2col.cu",
    "lightning-indexer.cu",
    "mean.cu",
    "mmf.cu",
    "mmid.cu",
    "mmq.cu",
    "mmvf.cu",
    "mmvq.cu",
    "moe-weighted-reduction.cu",
    "norm.cu",
    "opt-step-adamw.cu",
    "opt-step-sgd.cu",
    "out-prod.cu",
    "pad.cu",
    "pad_reflect_1d.cu",
    "pool1d.cu",
    "pool2d.cu",
    "quantize.cu",
    "roll.cu",
    "rope.cu",
    "scale.cu",
    "set.cu",
    "set-rows.cu",
    "snake.cu",
    "softcap.cu",
    "softmax.cu",
    "solve_tri.cu",
    "ssm-conv.cu",
    "ssm-scan.cu",
    "sum.cu",
    "sumrows.cu",
    "top-k.cu",
    "topk-moe.cu",
    "tri.cu",
    "tsembd.cu",
    "unary.cu",
    "upscale.cu",
    "wkv.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_16-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_16-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_16-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_1-ncols2_16.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_1-ncols2_32.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_1-ncols2_8.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_16.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_32.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_2-ncols2_8.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_32-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_32-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_16.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_4-ncols2_8.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_64-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_1.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_2.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_4.cu",
    "template-instances/fattn-mma-f16-instance-ncols1_8-ncols2_8.cu",
    "template-instances/fattn-tile-instance-dkq112-dv112.cu",
    "template-instances/fattn-tile-instance-dkq128-dv128.cu",
    "template-instances/fattn-tile-instance-dkq192-dv128.cu",
    "template-instances/fattn-tile-instance-dkq256-dv256.cu",
    "template-instances/fattn-tile-instance-dkq320-dv256.cu",
    "template-instances/fattn-tile-instance-dkq40-dv40.cu",
    "template-instances/fattn-tile-instance-dkq512-dv512.cu",
    "template-instances/fattn-tile-instance-dkq576-dv512.cu",
    "template-instances/fattn-tile-instance-dkq64-dv64.cu",
    "template-instances/fattn-tile-instance-dkq72-dv72.cu",
    "template-instances/fattn-tile-instance-dkq80-dv80.cu",
    "template-instances/fattn-tile-instance-dkq96-dv96.cu",
    "template-instances/mmf-instance-ncols_10.cu",
    "template-instances/mmf-instance-ncols_11.cu",
    "template-instances/mmf-instance-ncols_12.cu",
    "template-instances/mmf-instance-ncols_13.cu",
    "template-instances/mmf-instance-ncols_14.cu",
    "template-instances/mmf-instance-ncols_15.cu",
    "template-instances/mmf-instance-ncols_16.cu",
    "template-instances/mmf-instance-ncols_1.cu",
    "template-instances/mmf-instance-ncols_2.cu",
    "template-instances/mmf-instance-ncols_3.cu",
    "template-instances/mmf-instance-ncols_4.cu",
    "template-instances/mmf-instance-ncols_5.cu",
    "template-instances/mmf-instance-ncols_6.cu",
    "template-instances/mmf-instance-ncols_7.cu",
    "template-instances/mmf-instance-ncols_8.cu",
    "template-instances/mmf-instance-ncols_9.cu",
    "template-instances/mmq-instance-iq1_s.cu",
    "template-instances/mmq-instance-iq2_s.cu",
    "template-instances/mmq-instance-iq2_xs.cu",
    "template-instances/mmq-instance-iq2_xxs.cu",
    "template-instances/mmq-instance-iq3_s.cu",
    "template-instances/mmq-instance-iq3_xxs.cu",
    "template-instances/mmq-instance-iq4_nl.cu",
    "template-instances/mmq-instance-iq4_xs.cu",
    "template-instances/mmq-instance-mxfp4.cu",
    "template-instances/mmq-instance-nvfp4.cu",
    "template-instances/mmq-instance-q1_0.cu",
    "template-instances/mmq-instance-q2_0.cu",
    "template-instances/mmq-instance-q2_k.cu",
    "template-instances/mmq-instance-q3_k.cu",
    "template-instances/mmq-instance-q4_0.cu",
    "template-instances/mmq-instance-q4_1.cu",
    "template-instances/mmq-instance-q4_k.cu",
    "template-instances/mmq-instance-q5_0.cu",
    "template-instances/mmq-instance-q5_1.cu",
    "template-instances/mmq-instance-q5_k.cu",
    "template-instances/mmq-instance-q6_k.cu",
    "template-instances/mmq-instance-q8_0.cu",
    "template-instances/fattn-vec-instance-f16-f16.cu",
    "template-instances/fattn-vec-instance-q4_0-q4_0.cu",
    "template-instances/fattn-vec-instance-q8_0-q8_0.cu",
    "template-instances/fattn-vec-instance-bf16-bf16.cu",
};

/// The FlashAttention K/V type combinations whose vec-kernel instances are
/// compiled (mirrors `cuda_sources`' fattn-vec-instance list).
const fattn_compiled = [_][]const u8{ "f16-f16", "q4_0-q4_0", "q8_0-q8_0", "bf16-bf16" };

const fattn_types = [_][]const u8{ "q4_0", "q4_1", "q5_0", "q5_1", "q8_0", "bf16", "f16" };

/// `-DGGML_CUDA_FA_<K>_<V>=0|1` for every combination: fattn.cu picks the vec
/// kernel with `if constexpr (GGML_CUDA_FA_K_V)`, and upstream's CMake
/// defines all 49 (the ones without a compiled instance as 0, where the
/// kernel falls back to f16).
fn fattnArg(comptime kv: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10000);
        const dash = std.mem.indexOfScalar(u8, kv, '-').?;
        var name: [kv.len]u8 = undefined;
        for (kv[0..dash], 0..) |c, i| name[i] = std.ascii.toUpper(c);
        name[dash] = '_';
        for (kv[dash + 1 ..], 0..) |c, i| name[dash + 1 + i] = std.ascii.toUpper(c);
        var compiled = false;
        for (fattn_compiled) |c| compiled = compiled or std.mem.eql(u8, c, kv);
        return std.fmt.comptimePrint("-DGGML_CUDA_FA_{s}={d}", .{ name, @intFromBool(compiled) });
    }
}

const fattn_defines = blk: {
    @setEvalBranchQuota(20000);
    var out: []const []const u8 = &.{};
    for (fattn_types) |k| for (fattn_types) |v| {
        out = out ++ [_][]const u8{fattnArg(k ++ "-" ++ v)};
    };
    break :blk out;
};

const llama_core_sources = [_][]const u8{
    "llama.cpp",
    "llama-adapter.cpp",
    "llama-arch.cpp",
    "llama-batch.cpp",
    "llama-chat.cpp",
    "llama-context.cpp",
    "llama-cparams.cpp",
    "llama-grammar.cpp",
    "llama-graph.cpp",
    "llama-hparams.cpp",
    "llama-impl.cpp",
    "llama-io.cpp",
    "llama-kv-cache.cpp",
    "llama-kv-cache-dsa.cpp",
    "llama-kv-cache-dsa-iswa.cpp",
    "llama-kv-cache-dsv4.cpp",
    "llama-kv-cache-iswa.cpp",
    "llama-kv-cache-msa.cpp",
    "llama-memory.cpp",
    "llama-memory-hybrid.cpp",
    "llama-memory-hybrid-idx.cpp",
    "llama-memory-hybrid-iswa.cpp",
    "llama-memory-recurrent.cpp",
    "llama-mmap.cpp",
    "llama-model-loader.cpp",
    "llama-model-saver.cpp",
    "llama-model.cpp",
    "llama-quant.cpp",
    "llama-sampler.cpp",
    "llama-vocab.cpp",
    "unicode.cpp",
    "unicode-data.cpp",
};

const llama_model_sources = [_][]const u8{
    "models/afmoe.cpp",
    "models/apertus.cpp",
    "models/arcee.cpp",
    "models/arctic.cpp",
    "models/arwkv7.cpp",
    "models/baichuan.cpp",
    "models/bailingmoe.cpp",
    "models/bailingmoe2.cpp",
    "models/bailingmoe3.cpp",
    "models/bert.cpp",
    "models/bitnet.cpp",
    "models/bloom.cpp",
    "models/chameleon.cpp",
    "models/chatglm.cpp",
    "models/clip.cpp",
    "models/codeshell.cpp",
    "models/cogvlm.cpp",
    "models/cohere2.cpp",
    "models/cohere2moe.cpp",
    "models/command-r.cpp",
    "models/dbrx.cpp",
    "models/deci.cpp",
    "models/deepseek.cpp",
    "models/deepseek2.cpp",
    "models/deepseek2ocr.cpp",
    "models/deepseek32.cpp",
    "models/deepseek4.cpp",
    "models/delta-net-base.cpp",
    "models/dflash.cpp",
    "models/dots1.cpp",
    "models/dots3note.cpp",
    "models/dream.cpp",
    "models/eagle3.cpp",
    "models/ernie4-5.cpp",
    "models/ernie4-5-moe.cpp",
    "models/eurobert.cpp",
    "models/exaone.cpp",
    "models/exaone-moe.cpp",
    "models/exaone4.cpp",
    "models/falcon.cpp",
    "models/falcon-h1.cpp",
    "models/gemma.cpp",
    "models/gemma-embedding.cpp",
    "models/gemma2.cpp",
    "models/gemma3.cpp",
    "models/gemma3n.cpp",
    "models/gemma4.cpp",
    "models/gemma4-assistant.cpp",
    "models/glm-dsa.cpp",
    "models/glm4.cpp",
    "models/glm4-moe.cpp",
    "models/gpt2.cpp",
    "models/gptneox.cpp",
    "models/granite.cpp",
    "models/hy-v4.cpp",
    "models/granite-hybrid.cpp",
    "models/granite-moe.cpp",
    "models/granite-swa.cpp",
    "models/granite-switch.cpp",
    "models/grok.cpp",
    "models/grovemoe.cpp",
    "models/hunyuan-dense.cpp",
    "models/hunyuan-moe.cpp",
    "models/hunyuan-vl.cpp",
    "models/hy-v3.cpp",
    "models/internlm2.cpp",
    "models/jais.cpp",
    "models/jais2.cpp",
    "models/jamba.cpp",
    "models/jina-bert-v2.cpp",
    "models/jina-bert-v3.cpp",
    "models/kimi-k3.cpp",
    "models/kimi-linear.cpp",
    "models/laguna.cpp",
    "models/lfm2.cpp",
    "models/lfm2moe.cpp",
    "models/llada.cpp",
    "models/llada-moe.cpp",
    "models/llama.cpp",
    "models/llama-embed.cpp",
    "models/llama4.cpp",
    "models/maincoder.cpp",
    "models/mamba.cpp",
    "models/mamba-base.cpp",
    "models/mamba2.cpp",
    "models/mellum.cpp",
    "models/mimo2.cpp",
    "models/minicpm.cpp",
    "models/minicpm3.cpp",
    "models/minimax-01.cpp",
    "models/minimax-m2.cpp",
    "models/minimax-m3.cpp",
    "models/mistral3.cpp",
    "models/mistral4.cpp",
    "models/maple.cpp",
    "models/modern-bert.cpp",
    "models/mpt.cpp",
    "models/muse-glimmer.cpp",
    "models/nanbeige.cpp",
    "models/nemotron.cpp",
    "models/nemotron-h.cpp",
    "models/nemotron-h-moe.cpp",
    "models/neo-bert.cpp",
    "models/nomic-bert.cpp",
    "models/nomic-bert-moe.cpp",
    "models/olmo.cpp",
    "models/olmo2.cpp",
    "models/olmoe.cpp",
    "models/openai-moe.cpp",
    "models/openelm.cpp",
    "models/orion.cpp",
    "models/paddleocr.cpp",
    "models/pangu-embed.cpp",
    "models/phi2.cpp",
    "models/phi3.cpp",
    "models/spark2-5.cpp",
    "models/phimoe.cpp",
    "models/plamo.cpp",
    "models/plamo2.cpp",
    "models/plamo3.cpp",
    "models/plm.cpp",
    "models/pockettts.cpp",
    "models/qwen.cpp",
    "models/qwen2.cpp",
    "models/qwen2moe.cpp",
    "models/qwen2vl.cpp",
    "models/qwen3.cpp",
    "models/qwen35.cpp",
    "models/qwen35moe.cpp",
    "models/qwen3moe.cpp",
    "models/qwen3next.cpp",
    "models/qwen3tts.cpp",
    "models/qwen3vl.cpp",
    "models/qwen3vlmoe.cpp",
    "models/qwen4exp.cpp",
    "models/refact.cpp",
    "models/rnd1.cpp",
    "models/rwkv6.cpp",
    "models/rwkv6-base.cpp",
    "models/rwkv6qwen2.cpp",
    "models/rwkv7.cpp",
    "models/rwkv7-base.cpp",
    "models/seed-oss.cpp",
    "models/smallthinker.cpp",
    "models/smollm3.cpp",
    "models/stablelm.cpp",
    "models/starcoder.cpp",
    "models/starcoder2.cpp",
    "models/step35.cpp",
    "models/t5.cpp",
    "models/t5encoder.cpp",
    "models/talkie.cpp",
    "models/wavtokenizer-dec.cpp",
    "models/xverse.cpp",
};
