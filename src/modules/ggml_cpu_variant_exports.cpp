// The entry points of libggml-cpu-x64v3.so (build/ggml.zig `addCpuVariant`),
// what src/modules/ggml_cpu_variant.c looks up. Everything else in the
// library is hidden: the executable exports its own (baseline) copy of
// ggml's CPU functions for the GPU backends, and the library must call its
// own.
#include "ggml-backend.h"

extern "C" {
// ggml-cpu.cpp's GGML_BACKEND_DL_IMPL and cpu-feats.cpp's
// GGML_BACKEND_DL_SCORE_IMPL (hidden here).
ggml_backend_reg_t ggml_backend_init(void);
int ggml_backend_score(void);

__attribute__((visibility("default"))) ggml_backend_reg_t oriel_cpu_variant_reg(void) {
    return ggml_backend_init();
}

__attribute__((visibility("default"))) int oriel_cpu_variant_score(void) {
    return ggml_backend_score();
}
}
