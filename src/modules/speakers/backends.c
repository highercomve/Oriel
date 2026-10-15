// voice-detect.cpp's backend calls ggml_backend_load_all once (renamed to
// this in build/ggml.zig). That would dlopen every libggml-*.so in the
// executable's directory and the current one, and could register CUDA and
// Vulkan for the same card. The CPU backend is compiled in, and the GPU
// ones are registered by ggml_gpu.load: nothing to do here.
void oriel_speakers_load_backends(void);
void oriel_speakers_load_backends(void) {}
