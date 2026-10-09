// kokoro.cpp's GPU backends through ggml's backend registry.
//
// kokoro.cpp (built with KOKORO_HAS_VULKAN / KOKORO_HAS_CUDA) creates its
// GPU backend with ggml_backend_vk_init / ggml_backend_cuda_init, which
// live in the backend libraries Oriel loads at runtime (libggml-vulkan.so,
// libggml-cuda.so: ggml_gpu.load) or, on Windows and Android, in a Vulkan
// backend registered only when a loader is present. build/ggml.zig renames
// those calls to the functions below (-Dggml_backend_vk_init=...), which
// find the device among the registered ones instead: no GPU registered,
// no device, and kokoro.cpp stays on the CPU.

#include <stddef.h>

#include "ggml-backend.h"

// The `index`th GPU device of the backend registered as `reg_name`
// ("Vulkan", "CUDA"), or NULL.
static ggml_backend_dev_t gpu_device(const char * reg_name, size_t index) {
    ggml_backend_reg_t reg = ggml_backend_reg_by_name(reg_name);
    if (!reg) return NULL;
    size_t n = 0;
    for (size_t i = 0; i < ggml_backend_reg_dev_count(reg); i++) {
        ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, i);
        enum ggml_backend_dev_type t = ggml_backend_dev_type(dev);
        if (t != GGML_BACKEND_DEVICE_TYPE_GPU && t != GGML_BACKEND_DEVICE_TYPE_IGPU) continue;
        if (n++ == index) return dev;
    }
    return NULL;
}

static int gpu_count(const char * reg_name) {
    int n = 0;
    while (gpu_device(reg_name, (size_t)n)) n++;
    return n;
}

static ggml_backend_t gpu_init(const char * reg_name, size_t index) {
    ggml_backend_dev_t dev = gpu_device(reg_name, index);
    return dev ? ggml_backend_dev_init(dev, NULL) : NULL;
}

int oriel_kokoro_vk_device_count(void) { return gpu_count("Vulkan"); }
ggml_backend_t oriel_kokoro_vk_init(size_t dev_num) { return gpu_init("Vulkan", dev_num); }

int oriel_kokoro_cuda_device_count(void) { return gpu_count("CUDA"); }
ggml_backend_t oriel_kokoro_cuda_init(int device) { return device < 0 ? NULL : gpu_init("CUDA", (size_t)device); }
