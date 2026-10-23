// libvulkan.1.dylib for iOS: a minimal Vulkan "loader" in front of one ICD,
// Mesa's KosmicKrisp (libvulkan_kosmickrisp.dylib, scripts/build-zink.sh vulkan).
//
// iOS has no Vulkan loader. SDL's SDL_Vulkan_LoadLibrary and LWJGL's VK.create
// dlopen a library and look up the standard vkGetInstanceProcAddr; a bare Mesa
// ICD exports only vk_icdGetInstanceProcAddr. This exports the loader's global
// entry points and forwards everything else to the ICD. Like a loader it:
//   - reports no layers (vkEnumerateInstanceLayerProperties);
//   - offers VK_KHR_portability_enumeration, which apps on Apple platforms
//     enable for MoltenVK, and removes it (and its create flag) before the
//     conformant ICD sees it;
//   - answers vkGetDeviceProcAddr from the ICD once an instance exists.
//
// Build: clang -dynamiclib vulkan-shim.c -o libvulkan.1.dylib
//        -install_name @rpath/libvulkan.1.dylib -L<dir> -lvulkan_kosmickrisp
#include <stdlib.h>
#include <string.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#define SHIM_API __attribute__((visibility("default")))

extern PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);

static const char kPortabilityEnumeration[] = "VK_KHR_portability_enumeration";
static PFN_vkGetDeviceProcAddr icd_GetDeviceProcAddr;

SHIM_API VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name);

SHIM_API VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceVersion(uint32_t *version)
{
   PFN_vkEnumerateInstanceVersion f =
      (PFN_vkEnumerateInstanceVersion)vk_icdGetInstanceProcAddr(NULL, "vkEnumerateInstanceVersion");
   if (!f) {
      *version = VK_API_VERSION_1_0;
      return VK_SUCCESS;
   }
   return f(version);
}

SHIM_API VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceLayerProperties(uint32_t *count, VkLayerProperties *props)
{
   *count = 0;
   return VK_SUCCESS;
}

SHIM_API VKAPI_ATTR VkResult VKAPI_CALL
vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, VkExtensionProperties *props)
{
   if (layer)
      return VK_ERROR_LAYER_NOT_PRESENT;
   PFN_vkEnumerateInstanceExtensionProperties f =
      (PFN_vkEnumerateInstanceExtensionProperties)vk_icdGetInstanceProcAddr(NULL, "vkEnumerateInstanceExtensionProperties");
   uint32_t n = 0;
   VkResult r = f(NULL, &n, NULL);
   if (r != VK_SUCCESS)
      return r;
   // The ICD's list plus VK_KHR_portability_enumeration (a loader extension).
   if (!props) {
      *count = n + 1;
      return VK_SUCCESS;
   }
   VkExtensionProperties *all = calloc(n + 1, sizeof(*all));
   if (!all)
      return VK_ERROR_OUT_OF_HOST_MEMORY;
   r = f(NULL, &n, all);
   if (r != VK_SUCCESS && r != VK_INCOMPLETE) {
      free(all);
      return r;
   }
   strcpy(all[n].extensionName, kPortabilityEnumeration);
   all[n].specVersion = 1;
   uint32_t total = n + 1, copy = *count < total ? *count : total;
   memcpy(props, all, copy * sizeof(*props));
   free(all);
   *count = copy;
   return copy < total ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_CreateInstance(const VkInstanceCreateInfo *info, const VkAllocationCallbacks *alloc, VkInstance *instance)
{
   PFN_vkCreateInstance f = (PFN_vkCreateInstance)vk_icdGetInstanceProcAddr(NULL, "vkCreateInstance");
   VkInstanceCreateInfo ci = *info;
   const char **names = NULL;
   if (ci.enabledExtensionCount) {
      names = malloc(ci.enabledExtensionCount * sizeof(*names));
      if (!names)
         return VK_ERROR_OUT_OF_HOST_MEMORY;
      uint32_t kept = 0;
      for (uint32_t i = 0; i < info->enabledExtensionCount; i++) {
         if (strcmp(info->ppEnabledExtensionNames[i], kPortabilityEnumeration))
            names[kept++] = info->ppEnabledExtensionNames[i];
      }
      ci.enabledExtensionCount = kept;
      ci.ppEnabledExtensionNames = names;
   }
   ci.flags &= ~VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
   VkResult r = f(&ci, alloc, instance);
   free(names);
   if (r == VK_SUCCESS && !icd_GetDeviceProcAddr)
      icd_GetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)vk_icdGetInstanceProcAddr(*instance, "vkGetDeviceProcAddr");
   return r;
}

SHIM_API VKAPI_ATTR VkResult VKAPI_CALL
vkCreateInstance(const VkInstanceCreateInfo *info, const VkAllocationCallbacks *alloc, VkInstance *instance)
{
   return shim_CreateInstance(info, alloc, instance);
}

SHIM_API VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetDeviceProcAddr(VkDevice device, const char *name)
{
   return icd_GetDeviceProcAddr ? icd_GetDeviceProcAddr(device, name) : NULL;
}

SHIM_API VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL
vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
   if (!name)
      return NULL;
   if (!strcmp(name, "vkGetInstanceProcAddr"))
      return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
   if (!strcmp(name, "vkCreateInstance"))
      return (PFN_vkVoidFunction)shim_CreateInstance;
   if (!strcmp(name, "vkEnumerateInstanceLayerProperties"))
      return (PFN_vkVoidFunction)vkEnumerateInstanceLayerProperties;
   if (!strcmp(name, "vkEnumerateInstanceExtensionProperties"))
      return (PFN_vkVoidFunction)vkEnumerateInstanceExtensionProperties;
   if (!strcmp(name, "vkEnumerateInstanceVersion"))
      return (PFN_vkVoidFunction)vkEnumerateInstanceVersion;
   if (!strcmp(name, "vkGetDeviceProcAddr") && instance)
      return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
   return vk_icdGetInstanceProcAddr(instance, name);
}
