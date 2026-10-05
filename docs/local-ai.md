# Local AI, chat, and dictation

[Back to Oriel](../README.md) · [Documentation](README.md)

## Local AI inference (`oriel.llama` and `oriel.whisper`)

Oriel provides opt-in native C/C++ inference bindings for [llama.cpp](https://github.com/ggml-org/llama.cpp) (text LLMs) and [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (speech recognition).

### Enabling llama and whisper

- **Command-line flags:** `oriel build -Dllama` for llama.cpp, `oriel build -Dwhisper` for whisper.cpp, or both `oriel build -Dllama -Dwhisper`.
- **In an app's `build.zig`:** pass `.llama = true` and/or `.whisper = true` in `b.dependency("oriel", ...)`:
  ```zig
  const oriel_dep = b.dependency("oriel", .{
      .target = target,
      .optimize = optimize,
      .llama = true,
      .whisper = true,
  });
  ```
- **Licenses:** MIT (both llama.cpp and whisper.cpp).

### Shared GGML architecture

Both `llama.cpp` and `whisper.cpp` vendor GGML internally. To eliminate duplicate symbol collisions and ODR violations when both modules are enabled simultaneously, Oriel compiles a single unified instance of `ggml` and `ggml-cpu` (`build/ggml.zig`) and compiles both `llama` and `whisper` source files against that common instance.

### Build times

- **sqlite-vec:** one C file, a second or two.
- **llama.cpp + whisper.cpp:** about 45 s cold on first build (empty cache, 16 threads); cached rebuilds don't recompile them.
- **Default build overhead:** When omitted, nothing is downloaded, compiled or linked.

### CPU architecture flags & distributable builds

`ggml-cpu` compiles architecture-optimized SIMD routines (e.g. AVX, AVX2, FMA, F16C on x86_64, NEON/ARMv8 on aarch64).
- By default, Zig targets the host machine CPU, compiling with full host CPU instructions.
- **For distributable release builds** (e.g. creating deb, rpm, or AppImage packages for distribution to end-user machines), specify a baseline CPU target to avoid illegal instruction crashes (`SIGILL`) on older hardware:
  ```sh
  oriel build -Doptimize=ReleaseSafe -Dcpu=x86_64_v2 -Dllama -Dwhisper
  ```
  Or `-Dcpu=baseline` for maximum portability across 64-bit systems.

### GPU backends (CUDA, Metal & Vulkan)

- **CUDA (Linux):** `-Dggml_cuda` (plus `-Dwhisper` and/or `-Dllama`) builds
  ggml's CUDA backend with `nvcc` into `libggml-cuda.so`; `addApp` installs it
  next to the executable:
  ```sh
  oriel build -Dllama -Dwhisper -Dggml_cuda
  ```
  At runtime call `oriel.ggml_gpu.load(io)` before loading a model: it loads
  the backend from the executable's directory only and returns the number of
  GPUs (0 = CPU fallback, the app still works without an NVIDIA GPU or the library).
  - Needs the CUDA toolkit: `-Dcuda_path` (default `$CUDA_PATH` or
    `/opt/cuda`), `-Dcuda_arch` (nvcc `-arch`, default `native` = the GPUs
    of the build machine; use e.g. `all-major` for distribution):
    ```sh
    oriel build -Dggml_cuda -Dcuda_arch=all-major
    ```
    A comma-separated list of compute capabilities builds machine code for
    each and PTX for the newest generic one (later GPUs JIT it; Blackwell needs the architecture-specific `120a`), e.g. Turing, Ampere,
    Ada and Blackwell GeForce: `-Dcuda_arch=75,86,89,120a`.
  - The library links cuBLAS 13 dynamically, so users need the CUDA runtime
    (cuBLAS) installed; without it the library doesn't load and ggml uses
    Vulkan (if built with `-Dggml_vulkan`) or the CPU. `-Dcuda_static=true`
    links cuBLAS in instead: it then needs only the NVIDIA driver, but is
    ~590 MB (cuBLASLt's kernels).
  - `-Dggml_cuda_prebuilt=/abs/path/libggml-cuda.so` uses a library built
    earlier (same Oriel ggml and options) instead of running nvcc, and implies
    `-Dggml_cuda`: CI can cache the slow multi-architecture build (~70 min on
    a hosted runner) and rebuild it only when ggml or the options change.
  - First build compiles ~140 CUDA files (~3–4 min on 16 cores), cached after.
  - Why a separate library: nvcc's host code uses GCC's libstdc++ while Zig
    builds C++ against libc++; the ggml backend interface between them is
    plain C. The executable is linked with `rdynamic` so the library
    resolves ggml's symbols from it.
  - Measured (GhostPen Lite, RTX 4070, 11 s clip, incl. model load):
    small 3.2 s on CPU → 0.8 s on CUDA; large-v3-turbo q8 1.1 s on CUDA.
- **Metal (macOS):** on by default for macOS targets (`-Dggml_metal=false`
  to turn it off). ggml's Metal backend is compiled into the executable and
  its kernel sources are embedded (`tools/metal_embed.zig`, like
  `GGML_METAL_EMBED_LIBRARY`), so no Xcode `metal` compiler step is needed;
  ggml compiles them for the GPU when the model loads. `ggml_gpu.load` /
  `gpuName` report it (e.g. "Apple M1").
  - Measured (GhostPen Lite, Apple M1 in a VM, 5.9 s clip, tiny.en,
    incl. model load): 7.3 s on CPU → 0.95–1.4 s on Metal.
- **Vulkan (Linux):** `-Dggml_vulkan` builds ggml's Vulkan backend (any GPU
  vendor: NVIDIA, AMD, Intel) into `libggml-vulkan.so`, installed and packaged
  like the CUDA one:
  ```sh
  oriel build -Dllama -Dwhisper -Dggml_vulkan
  ```
  - Needs the Vulkan headers and SPIRV-Headers, the Vulkan loader, and
    `glslc` (shaderc) on PATH or `-Dglslc=/path/to/glslc`. Arch:
    `vulkan-headers spirv-headers vulkan-icd-loader shaderc`; Debian/Ubuntu:
    `libvulkan-dev spirv-headers glslc`.
  - ggml's `vulkan-shaders-gen` is built for the host and compiles the ~145
    shaders to SPIR-V (one cached step each, as ggml's CMake does), which are
    embedded in the library. First build ~2 min on 16 cores.
  - The library links `libvulkan.so.1`: on a machine without a Vulkan loader
    or driver it doesn't load, and the app runs on the CPU. So a Vulkan build
    is safe to ship to everyone.
  - With both `-Dggml_cuda` and `-Dggml_vulkan`, `ggml_gpu.load` loads CUDA
    first and Vulkan only if CUDA found no GPU (one card is never registered
    twice).
- **Vulkan (Windows):** the same `-Dggml_vulkan`, compiled into the
  executable (a DLL couldn't take ggml's symbols from it), so there is no
  extra file to ship:
  ```powershell
  oriel build -Dllama -Dwhisper -Dggml_vulkan
  ```
  - Needs the [Vulkan SDK](https://vulkan.lunarg.com/) for `glslc` and the
    headers (`$VULKAN_SDK`; or `-Dglslc` and `-Dvulkan_include`). The
    shaders make the executable ~55 MB larger (the installer compresses it).
  - The executable doesn't link `vulkan-1.lib`: it loads `vulkan-1.dll`
    from System32 at runtime, and `ggml_gpu.load` registers Vulkan only
    when that works, so the app starts and runs on the CPU without it.
  - The Vulkan instance is created without implicit layers (overlays,
    capture hooks, NVIDIA's Optimus layer, which crashed the process on an
    Optimus laptop): ggml only computes. Setting `VK_LOADER_LAYERS_DISABLE`
    or `VK_LOADER_LAYERS_ALLOW` yourself overrides that.
  - Measured (GhostPen, GTX 1070 Max-Q vs i7-8750H): Qwen3.5 2B Q4_K_M
    generates 55 tokens/s on Vulkan vs 15 on the CPU; whisper base
    transcribes a 6 s clip in 0.35 s vs 2.7 s.

### Multimodal (`mtmd`): images for vision models

`-Dllama_mtmd` (with `-Dllama`) builds llama.cpp's multimodal library
(`tools/mtmd`) into the app: images (and audio) for models that come with a
projector, the `mmproj-*.gguf` file next to the model on Hugging Face. Its C API
(`mtmd.h`, `mtmd-helper.h`) is in `oriel.llama.c`:

```zig
var mp = c.mtmd_context_params_default();
mp.use_gpu = true;
const vision = c.mtmd_init_from_file("mmproj-F16.gguf", model, mp);
const bmp = c.mtmd_helper_bitmap_init_from_buf(vision, png.ptr, png.len, false, c.mtmd_helper_init_opt_default()).bitmap;
// The prompt holds c.mtmd_default_marker() where the image goes:
_ = c.mtmd_tokenize(vision, chunks, &input_text, &bitmaps, 1);
_ = c.mtmd_helper_eval_chunks(vision, ctx, chunks, 0, 0, 512, true, &n_past);
// ... then sample as for text.
```

- Built from the same sources as llama.cpp's CMake (`add_library(mtmd ...)`),
  with the header-only `stb_image` (PNG, JPEG, BMP, GIF), `miniaudio` and
  `vendor/hash`. Video (`MTMD_VIDEO`, which runs `ffmpeg`) stays off.
- The projector runs on the same GPU backend as the model (CUDA, Vulkan,
  Metal) or the CPU.
- Upstream marks the API experimental ("subject to many BREAKING CHANGES"),
  so pin llama.cpp with Oriel's version. GhostPen uses it for Extract Text
  on its built-in models.

### Runtime API

#### llama.cpp (`oriel.llama`)

```zig
const oriel = @import("oriel");

// Optional: silence internal ggml/llama stderr logging
oriel.llama.silenceLogs();

// Initialize backend
oriel.llama.initBackend();
defer oriel.llama.deinitBackend();

// Inspect system CPU features detected by backend
const sys_info = try oriel.llama.systemInfo(gpa); // owned copy
defer gpa.free(sys_info);
std.log.info("Llama system info: {s}", .{sys_info});

// Load GGUF model with default params
const params = oriel.llama.modelDefaultParams();
const model = oriel.llama.loadModel("path/to/model.gguf", params) catch |err| {
    std.log.err("Failed to load model: {s}", .{@errorName(err)});
    return err;
};
defer model.deinit();
```

#### whisper.cpp (`oriel.whisper`)

```zig
const oriel = @import("oriel");

// Optional: silence internal ggml/whisper stderr logging
oriel.whisper.silenceLogs();

// Inspect whisper backend info
const sys_info = try oriel.whisper.systemInfo(gpa); // owned copy
defer gpa.free(sys_info);
std.log.info("Whisper system info: {s}", .{sys_info});

// Load GGML speech model with default context params
const params = oriel.whisper.contextDefaultParams();
const ctx = oriel.whisper.loadModel("path/to/whisper-base.bin", params) catch |err| {
    std.log.err("Failed to load whisper context: {s}", .{@errorName(err)});
    return err;
};
defer ctx.deinit();
```

## Chat with a local LLM (`oriel.chat`)

Chat and completion with llama.cpp, with the tuning built in: enable `.llama = true`, then

```zig
oriel.chat.init(init.io, init.gpa, models_dir);              // once, at startup
try oriel.chat.download("qwen2.5-0.5b");                      // or copy the GGUF there
const r = try oriel.chat.generate(gpa, &.{
    .{ .role = "system", .content = "Answer briefly." },
    .{ .role = "user", .content = "What is Zig?" },
}, .{});                                                      // from an async command
// the page gets chat:token events as the reply is written; r.text is all of it
oriel.chat.cancel();                                          // Stop, from any thread
```

- **Models:** small multilingual instruct models in q4_0 (Qwen2.5 0.5B and 1.5B, Llama 3.2 1B),
  and on desktops Qwen3.5 9B and Gemma 4 12B (q4_K_M; 16 GB of memory), downloaded from Hugging
  Face (`download`, `delete`, `status`); `.model = "auto"` is the largest on the device.
- **Out of the box:**
  - The model's own chat template (from its GGUF), so `messages` are plain `{ role, content }`.
    Qwen3.5 and Gemma 4 answer without thinking first, unless `.think = true` (the thinking is
    kept out of the reply).
  - Tuned like llama-server: a resident threadpool, 2048-token prompt batches on desktops, a q8_0
    KV cache with flash attention (f16 without it), the context capped at the model's and halved
    when memory runs out, and the CPU when the model doesn't fit on the GPU.
  - `.schema`: a JSON schema the reply follows.
  - Tokens stream to the page as whole UTF-8 characters.
  - Each turn reuses the conversation's KV cache, so only the new message is evaluated.
  - A conversation longer than the context drops its oldest turns; the system prompt stays.
  - The CPU or the GPU per device and model (`.backend = .auto`), from what `compare()` measured,
    and a warm-up for GPU models.
- **Building blocks:** `oriel.llama` (the C API, JSON-schema grammars) and `oriel.ggml_gpu`.
- `examples/showcase`'s Chat tab uses all of it, with a mic that dictates the message (`oriel.dictation`).

## Voice to text (`oriel.dictation`)

Live dictation and transcription with the tuning built in: enable `.whisper = true, .audio_capture = true`, then

```zig
oriel.dictation.init(init.io, init.gpa, models_dir);           // once, at startup
const s = try oriel.dictation.start(.{ .language = "de" });     // from a worker (loads models)
// ... the page gets dictation:partial / dictation:final / dictation:level events
const r = try oriel.dictation.stop(gpa);                        // r.text: everything said
const t = try oriel.dictation.transcribeFile(gpa, "talk.wav", .{});
```

- **Engines** (`.engine`): `.whisper` (every platform, ~99 languages, offline), `.system` (the
  platform's recognizer, no download; Android's SpeechRecognizer, Google's on-device model on a
  Pixel) and `.auto` (the system engine on Android when it runs on the device, else whisper).
- **What whisper gets without tuning:** q8_0 models (tiny/base/small; `download`, `delete`,
  `status`), Silero voice detection, whisper's window sized to the clip, live text from the
  next smaller model on the device (the draft) while the chosen model writes each phrase, and
  the CPU or the GPU per device and model (`.backend = .auto`): what `compare` measured
  (remembered next to the models), else the GPU on desktops and the CPU on phones.
- **Files:** `transcribeFile` reads WAV (PCM or float, any rate and channels);
  `transcribeSamples` takes 16 kHz mono samples from any decoder.
- **Building blocks:** `oriel.whisper`, `oriel.audio_capture` and `oriel.ggml_gpu` stay public
  for pipelines of your own.
- `examples/showcase`'s Dictate tab uses all of it (and its System tab dictates into other apps).
