// Android, -Dggml_vulkan: ggml-vulkan is compiled into liboriel.so (a
// separate libggml-vulkan.so couldn't see ggml's symbols: the JVM loads
// liboriel.so with local visibility). Like src/modules/ggml_vulkan_loader.c
// on Windows, the few Vulkan functions ggml calls directly are defined here
// and forward to the system's libvulkan.so, opened on first use; ggml_gpu.zig
// registers the Vulkan backend only when it was found.

#include <vulkan/vulkan_core.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stddef.h>

static void *loader;
static pthread_once_t loader_once = PTHREAD_ONCE_INIT;
static PFN_vkGetInstanceProcAddr fwd_vkGetInstanceProcAddr;
static PFN_vkGetDeviceProcAddr fwd_vkGetDeviceProcAddr;
static PFN_vkGetPhysicalDeviceFeatures2 fwd_vkGetPhysicalDeviceFeatures2;
static PFN_vkCmdCopyBuffer fwd_vkCmdCopyBuffer;

static void load_loader(void) {
    void *m = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
    if (!m) return;
    fwd_vkGetInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(m, "vkGetInstanceProcAddr");
    fwd_vkGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)dlsym(m, "vkGetDeviceProcAddr");
    fwd_vkGetPhysicalDeviceFeatures2 = (PFN_vkGetPhysicalDeviceFeatures2)dlsym(m, "vkGetPhysicalDeviceFeatures2");
    fwd_vkCmdCopyBuffer = (PFN_vkCmdCopyBuffer)dlsym(m, "vkCmdCopyBuffer");
    if (!fwd_vkGetInstanceProcAddr || !fwd_vkGetDeviceProcAddr || !fwd_vkGetPhysicalDeviceFeatures2 || !fwd_vkCmdCopyBuffer) {
        // No pointer may outlive the library.
        fwd_vkGetInstanceProcAddr = NULL;
        fwd_vkGetDeviceProcAddr = NULL;
        fwd_vkGetPhysicalDeviceFeatures2 = NULL;
        fwd_vkCmdCopyBuffer = NULL;
        dlclose(m);
        return;
    }
    loader = m;
}

int oriel_vulkan_loader_available(void) {
    pthread_once(&loader_once, load_loader);
    return loader != NULL;
}

// No implicit layers to keep out on Android (apps get only their own).
void oriel_vulkan_layers_begin(void) {}
void oriel_vulkan_layers_end(void) {}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name) {
    if (!oriel_vulkan_loader_available()) return NULL;
    return fwd_vkGetInstanceProcAddr(instance, name);
}

VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name) {
    if (!oriel_vulkan_loader_available()) return NULL;
    return fwd_vkGetDeviceProcAddr(device, name);
}

VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(VkPhysicalDevice device, VkPhysicalDeviceFeatures2 *features) {
    if (oriel_vulkan_loader_available()) fwd_vkGetPhysicalDeviceFeatures2(device, features);
}

VKAPI_ATTR void VKAPI_CALL vkCmdCopyBuffer(VkCommandBuffer cmd, VkBuffer src, VkBuffer dst, uint32_t count, const VkBufferCopy *regions) {
    if (oriel_vulkan_loader_available()) fwd_vkCmdCopyBuffer(cmd, src, dst, count, regions);
}
