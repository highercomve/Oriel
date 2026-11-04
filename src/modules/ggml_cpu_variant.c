// The CPU backend ggml's registry adds (ggml-backend-reg.cpp is compiled with
// -Dggml_backend_cpu_reg=oriel_ggml_cpu_reg; build/ggml.zig): the
// x86-64-v3 build of ggml's CPU kernels (AVX2, FMA, F16C), libggml-cpu-x64v3.so
// next to the executable, when this CPU runs it, else the built-in baseline
// kernels the executable is compiled with so it starts on any x86-64 CPU.
// The v3 kernels read a prompt ~10x and generate ~2.5x faster on the CPU.
// ORIEL_GGML_CPU_BASELINE=1 keeps the built-in ones.
//
// Not through ggml_backend_load: this runs while the registry is being
// built, which ggml_backend_load would wait for.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "ggml-backend.h"

ggml_backend_reg_t ggml_backend_cpu_reg(void);
ggml_backend_reg_t oriel_ggml_cpu_reg(void);

static const char variant[] = "libggml-cpu-x64v3.so";

ggml_backend_reg_t oriel_ggml_cpu_reg(void) {
    static ggml_backend_reg_t chosen = NULL;
    if (chosen) return chosen;
    chosen = ggml_backend_cpu_reg();
    const char *baseline = getenv("ORIEL_GGML_CPU_BASELINE");
    if (baseline && baseline[0] && strcmp(baseline, "0") != 0) return chosen;

    char path[PATH_MAX];
    ssize_t n = readlink("/proc/self/exe", path, sizeof(path) - sizeof(variant) - 1);
    if (n <= 0) return chosen;
    path[n] = 0;
    char *slash = strrchr(path, '/');
    if (!slash) return chosen;
    memcpy(slash + 1, variant, sizeof(variant));

    // Left mapped even when unused: like the GPU backends (ggml_gpu.zig's
    // `pin`), a Zig-built library's C++ destructors stay registered with
    // atexit, so unloading it would crash at exit.
    void *lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) return chosen;
    int (*score)(void) = (int (*)(void))dlsym(lib, "oriel_cpu_variant_score");
    ggml_backend_reg_t (*reg)(void) = (ggml_backend_reg_t (*)(void))dlsym(lib, "oriel_cpu_variant_reg");
    // 0: this CPU lacks a feature the library was compiled for.
    if (!score || !reg || score() <= 0) return chosen;
    ggml_backend_reg_t r = reg();
    if (r) chosen = r;
    return chosen;
}
