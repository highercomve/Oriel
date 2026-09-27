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
static PFN_vkGetInstanceProcAddr fwd_vkGetInstanceProcAddr;
static PFN_vkGetDeviceProcAddr fwd_vkGetDeviceProcAddr;
static PFN_vkGetPhysicalDeviceFeatures2 fwd_vkGetPhysicalDeviceFeatures2;
static PFN_vkCmdCopyBuffer fwd_vkCmdCopyBuffer;

// Load vulkan-1.dll and look up every function ggml calls directly, once
// (InitOnce publishes them to all threads). A loader missing any of them
// counts as no loader: the Vulkan backend is then never registered, so the
// forwarders below never run without their target.
static BOOL CALLBACK load_loader(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once; (void)param; (void)ctx;
    // System directory only: never a vulkan-1.dll from the current directory.
    HMODULE m = LoadLibraryExW(L"vulkan-1.dll", NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!m) return TRUE;
    fwd_vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)(void *)GetProcAddress(m, "vkGetInstanceProcAddr");
    fwd_vkGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)(void *)GetProcAddress(m, "vkGetDeviceProcAddr");
    fwd_vkGetPhysicalDeviceFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)(void *)GetProcAddress(m, "vkGetPhysicalDeviceFeatures2");
    fwd_vkCmdCopyBuffer = (PFN_vkCmdCopyBuffer)(void *)GetProcAddress(m, "vkCmdCopyBuffer");
    if (!fwd_vkGetInstanceProcAddr || !fwd_vkGetDeviceProcAddr || !fwd_vkGetPhysicalDeviceFeatures2 || !fwd_vkCmdCopyBuffer) {
        FreeLibrary(m);
        return TRUE;
    }
    loader = m;
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
// variable is set only around the instance creation (ggml_backend_vk_reg,
// serialized by ggml_gpu.load), so programs the app starts later don't
// inherit it.
static int layers_disabled;

void oriel_vulkan_layers_begin(void) {
    if (GetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", NULL, 0) || GetEnvironmentVariableW(L"VK_LOADER_LAYERS_ALLOW", NULL, 0)) return;
    layers_disabled = SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", L"~implicit~") != 0;
}

void oriel_vulkan_layers_end(void) {
    if (layers_disabled) SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", NULL);
    layers_disabled = 0;
}

// The forwarders: ggml calls these only after the backend was registered,
// which needs oriel_vulkan_loader_available() (every pointer found). The
// two ProcAddr functions check anyway: returning NULL is their way to fail.
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name) {
    if (!oriel_vulkan_loader_available()) return NULL;
    return fwd_vkGetInstanceProcAddr(instance, name);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name) {
    if (!oriel_vulkan_loader_available()) return NULL;
    return fwd_vkGetDeviceProcAddr(device, name);
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice device, VkPhysicalDeviceFeatures2 *features) {
    fwd_vkGetPhysicalDeviceFeatures2(device, features);
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer cmd, VkBuffer src, VkBuffer dst, uint32_t count, const VkBufferCopy *regions) {
    fwd_vkCmdCopyBuffer(cmd, src, dst, count, regions);
}
