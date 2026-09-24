//! GGML, llama.cpp, and whisper.cpp build configuration for Oriel.
//!
//! Compiles ggml base and ggml-cpu (single shared ggml library), plus
//! llama.cpp and/or whisper.cpp when their corresponding feature is enabled.

const std = @import("std");

pub fn addGgml(
    b: *std.Build,
    oriel: *std.Build.Module,
    features: anytype,
) void {
    if (!features.llama and !features.whisper) return;

    const llama_dep = if (features.llama) b.lazyDependency("llama", .{}) else null;
    const whisper_dep = if (features.whisper) b.lazyDependency("whisper", .{}) else null;

    if (features.llama and llama_dep == null) return;
    if (features.whisper and whisper_dep == null) return;

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

    const c_flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600", "-DGGML_USE_CPU" };
    const cpp_flags = &.{ "-std=c++17", "-D_GNU_SOURCE", "-D_XOPEN_SOURCE=600", "-DGGML_USE_CPU" };

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
    }

    // whisper.cpp sources
    if (features.whisper) {
        const w = whisper_dep.?;
        oriel.addIncludePath(w.path("include"));
        oriel.addIncludePath(w.path("src"));

        const whisper_flags = &.{
            "-std=c++17",
            "-D_GNU_SOURCE",
            "-D_XOPEN_SOURCE=600",
            "-DGGML_USE_CPU",
            "-DWHISPER_VERSION=\"1.9.4\"",
            "-DWHISPER_BUILD_COMMIT=\"v1.9.4\"",
        };

        oriel.addCSourceFiles(.{
            .root = w.path("src"),
            .files = &.{"whisper.cpp"},
            .flags = whisper_flags,
        });
    }
}

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
