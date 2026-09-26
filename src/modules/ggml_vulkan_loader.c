// Windows, -Dggml_vulkan: ggml-vulkan is compiled into the executable and
// calls a few Vulkan functions directly (the rest go through vulkan.hpp's
// dynamic dispatcher). Linking vulkan-1.lib would make the executable fail
// to start where there's no Vulkan loader (no GPU driver, some VMs), so this
// defines those functions itself and forwards them to vulkan-1.dll, loaded
// on first use. ggml_gpu.zig registers the Vulkan backend only when
// oriel_vulkan_loader_available() says the loader is there.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <vulkan/vulkan_core.h>

static HMODULE loader;
static INIT_ONCE loader_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK load_loader(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once; (void)param; (void)ctx;
    // System directory only: never a vulkan-1.dll from the current directory.
    loader = LoadLibraryExW(L"vulkan-1.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (loader && !GetProcAddress(loader, "vkGetInstanceProcAddr")) loader = NULL;
    return TRUE;
}

int oriel_vulkan_loader_available(void) {
    InitOnceExecuteOnce(&loader_once, load_loader, NULL, NULL);
    return loader != NULL;
}

// Implicit layers (overlays, capture hooks, NVIDIA's Optimus/present
// layers) are for presenting frames; ggml only computes. They can only get in
// the way, and NVIDIA's VK_LAYER_NV_optimus crashed a Zig-built process
// (a null call as a thread started) on an Optimus laptop. So the Vulkan
// instance is created without them, unless the user chose layers with the
// loader's own VK_LOADER_LAYERS_DISABLE / VK_LOADER_LAYERS_ALLOW. The
// variable is set only around the instance creation (ggml_backend_vk_reg),
// so child processes and programs the app starts don't inherit it.
static int layers_disabled;

void oriel_vulkan_layers_begin(void) {
    if (GetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", NULL, 0) || GetEnvironmentVariableW(L"VK_LOADER_LAYERS_ALLOW", NULL, 0)) return;
    layers_disabled = SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", L"~implicit~") != 0;
}

void oriel_vulkan_layers_end(void) {
    if (layers_disabled) SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", NULL);
    layers_disabled = 0;
}

// The loader exports every core function; look each one up once.
#define FORWARD(name) \
    static PFN_##name fwd_##name; \
    if (!fwd_##name) { \
        if (!oriel_vulkan_loader_available()) return_fail; \
        fwd_##name = (PFN_##name)(void *)GetProcAddress(loader, #name); \
        if (!fwd_##name) return_fail; \
    }

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name) {
#define return_fail return NULL
    FORWARD(vkGetInstanceProcAddr)
    return fwd_vkGetInstanceProcAddr(instance, name);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name) {
    FORWARD(vkGetDeviceProcAddr)
    return fwd_vkGetDeviceProcAddr(device, name);
#undef return_fail
}

// ggml only calls these once the loader is known to be there (it created an
// instance through it), so a missing loader can't happen here.
#define return_fail return

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice device, VkPhysicalDeviceFeatures2 *features) {
    FORWARD(vkGetPhysicalDeviceFeatures2)
    fwd_vkGetPhysicalDeviceFeatures2(device, features);
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer cmd, VkBuffer src, VkBuffer dst, uint32_t count, const VkBufferCopy *regions) {
    FORWARD(vkCmdCopyBuffer)
    fwd_vkCmdCopyBuffer(cmd, src, dst, count, regions);
}
#undef return_fail
