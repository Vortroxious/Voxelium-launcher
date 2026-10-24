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
// It also counts the app's device memory (vkAllocateMemory/vkFreeMemory) on
// stderr, per memory type, to tell the app's allocations from the driver's.
// For the app (Voxelium) it also holds queue submits, image acquires and
// presents while vx_vulkan_set_paused(1) is in effect: iOS refuses GPU work
// from apps in the background, and Minecraft 26.3 keeps rendering when its
// window is minimized. The thread that renders waits there until resumed.
//
// Build: clang -dynamiclib vulkan-shim.c -o libvulkan.1.dylib
//        -install_name @rpath/libvulkan.1.dylib -L<dir> -lvulkan_kosmickrisp
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>

#define SHIM_API __attribute__((visibility("default")))

extern PFN_vkVoidFunction vk_icdGetInstanceProcAddr(VkInstance instance, const char *name);

static const char kPortabilityEnumeration[] = "VK_KHR_portability_enumeration";
static PFN_vkGetDeviceProcAddr icd_GetDeviceProcAddr;

// --- Pause while the app is in the background.
static pthread_mutex_t pause_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t pause_cond = PTHREAD_COND_INITIALIZER;
static int paused;

SHIM_API void vx_vulkan_set_paused(int value)
{
   pthread_mutex_lock(&pause_lock);
   paused = value != 0;
   pthread_cond_broadcast(&pause_cond);
   pthread_mutex_unlock(&pause_lock);
}

static void wait_while_paused(const char *where)
{
   pthread_mutex_lock(&pause_lock);
   if (paused) {
      fprintf(stderr, "[vulkan-shim] app in background: %s waits\n", where);
      while (paused)
         pthread_cond_wait(&pause_cond, &pause_lock);
      fprintf(stderr, "[vulkan-shim] app in foreground: rendering resumed\n");
   }
   pthread_mutex_unlock(&pause_lock);
}

// --- Memory accounting: what the app allocates (vkAllocateMemory), per memory
// type, logged at every 32 MB step and with the memory types on first use. For
// telling the app's own allocations apart from the driver's (Metal) overhead.
static pthread_mutex_t mem_lock = PTHREAD_MUTEX_INITIALIZER;
static VkDeviceSize mem_by_type[VK_MAX_MEMORY_TYPES], mem_total, mem_logged, mem_peak;
static uint32_t mem_count, mem_types_logged;
static PFN_vkAllocateMemory icd_AllocateMemory;
static PFN_vkFreeMemory icd_FreeMemory;
static PFN_vkGetPhysicalDeviceMemoryProperties icd_GetPhysicalDeviceMemoryProperties;

// VkDeviceMemory -> (size, type), open addressing; the game holds a few thousand.
#define MEM_SLOTS 65536
static struct { VkDeviceMemory mem; VkDeviceSize size; uint32_t type; } mem_slots[MEM_SLOTS];

static size_t mem_slot(VkDeviceMemory mem)
{
   uint64_t h = (uint64_t)mem;
   h ^= h >> 33; h *= 0xff51afd7ed558ccdull; h ^= h >> 33;
   return (size_t)(h & (MEM_SLOTS - 1));
}

// Buffers and images bound to memory: what the app actually uses inside its
// allocations (an allocator such as VMA allocates larger blocks than it fills).
#define RES_SLOTS 65536
static struct { uint64_t handle; VkDeviceSize size; } res_slots[RES_SLOTS];
static VkDeviceSize res_used, res_used_peak;
static uint32_t res_count;
static PFN_vkBindBufferMemory icd_BindBufferMemory;
static PFN_vkBindImageMemory icd_BindImageMemory;
static PFN_vkBindBufferMemory2 icd_BindBufferMemory2;
static PFN_vkBindImageMemory2 icd_BindImageMemory2;
static PFN_vkGetBufferMemoryRequirements icd_GetBufferMemoryRequirements;
static PFN_vkGetImageMemoryRequirements icd_GetImageMemoryRequirements;
static PFN_vkDestroyBuffer icd_DestroyBuffer;
static PFN_vkDestroyImage icd_DestroyImage;
static VkDeviceSize res_logged;
static void mem_log_locked(const char *why);

static size_t res_slot(uint64_t h)
{
   h ^= h >> 33; h *= 0xff51afd7ed558ccdull; h ^= h >> 33;
   return (size_t)(h & (RES_SLOTS - 1));
}

static void res_add_locked(uint64_t handle, VkDeviceSize size)
{
   size_t i = res_slot(handle);
   while (res_slots[i].handle)
      i = (i + 1) & (RES_SLOTS - 1);
   res_slots[i].handle = handle;
   res_slots[i].size = size;
   res_used += size;
   res_count++;
   if (res_used > res_used_peak)
      res_used_peak = res_used;
   if (res_used >= res_logged + (64u << 20)) {
      res_logged = res_used & ~((VkDeviceSize)(64u << 20) - 1);
      mem_log_locked("in use");
   }
}

static void res_remove_locked(uint64_t handle)
{
   size_t i = res_slot(handle);
   for (size_t probes = 0; res_slots[i].handle && probes < RES_SLOTS; probes++, i = (i + 1) & (RES_SLOTS - 1)) {
      if (res_slots[i].handle != handle)
         continue;
      res_used -= res_slots[i].size;
      res_count--;
      res_slots[i].handle = 0;
      for (size_t j = (i + 1) & (RES_SLOTS - 1); res_slots[j].handle; j = (j + 1) & (RES_SLOTS - 1)) {
         typeof(res_slots[0]) e = res_slots[j];
         res_slots[j].handle = 0;
         size_t k = res_slot(e.handle);
         while (res_slots[k].handle)
            k = (k + 1) & (RES_SLOTS - 1);
         res_slots[k] = e;
      }
      return;
   }
}

static void mem_log_locked(const char *why)
{
   char line[512];
   int n = snprintf(line, sizeof(line), "[vulkan-shim] memory %s: %llu MB in %u allocations (peak %llu MB); "
                    "used by %u buffers/images %llu MB (peak %llu MB):",
                    why, (unsigned long long)(mem_total >> 20), mem_count, (unsigned long long)(mem_peak >> 20),
                    res_count, (unsigned long long)(res_used >> 20), (unsigned long long)(res_used_peak >> 20));
   for (uint32_t t = 0; t < VK_MAX_MEMORY_TYPES && n < (int)sizeof(line) - 24; t++) {
      if (mem_by_type[t])
         n += snprintf(line + n, sizeof(line) - n, " type%u %llu MB", t, (unsigned long long)(mem_by_type[t] >> 20));
   }
   fprintf(stderr, "%s\n", line);
}

static VKAPI_ATTR void VKAPI_CALL
shim_GetPhysicalDeviceMemoryProperties(VkPhysicalDevice pd, VkPhysicalDeviceMemoryProperties *props)
{
   icd_GetPhysicalDeviceMemoryProperties(pd, props);
   pthread_mutex_lock(&mem_lock);
   if (!mem_types_logged) {
      mem_types_logged = 1;
      for (uint32_t i = 0; i < props->memoryHeapCount; i++)
         fprintf(stderr, "[vulkan-shim] memory heap %u: %llu MB, flags 0x%x\n", i,
                 (unsigned long long)(props->memoryHeaps[i].size >> 20), props->memoryHeaps[i].flags);
      for (uint32_t i = 0; i < props->memoryTypeCount; i++)
         fprintf(stderr, "[vulkan-shim] memory type %u: heap %u, flags 0x%x\n", i,
                 props->memoryTypes[i].heapIndex, props->memoryTypes[i].propertyFlags);
   }
   pthread_mutex_unlock(&mem_lock);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_AllocateMemory(VkDevice device, const VkMemoryAllocateInfo *info, const VkAllocationCallbacks *alloc, VkDeviceMemory *mem)
{
   VkResult r = icd_AllocateMemory(device, info, alloc, mem);
   if (r != VK_SUCCESS) {
      fprintf(stderr, "[vulkan-shim] vkAllocateMemory(%llu MB, type %u) failed: %d\n",
              (unsigned long long)(info->allocationSize >> 20), info->memoryTypeIndex, r);
      return r;
   }
   pthread_mutex_lock(&mem_lock);
   size_t i = mem_slot(*mem);
   while (mem_slots[i].mem)
      i = (i + 1) & (MEM_SLOTS - 1);
   mem_slots[i].mem = *mem;
   mem_slots[i].size = info->allocationSize;
   mem_slots[i].type = info->memoryTypeIndex;
   if (info->memoryTypeIndex < VK_MAX_MEMORY_TYPES)
      mem_by_type[info->memoryTypeIndex] += info->allocationSize;
   mem_total += info->allocationSize;
   mem_count++;
   if (mem_total > mem_peak)
      mem_peak = mem_total;
   if (info->allocationSize >= (64u << 20))
      fprintf(stderr, "[vulkan-shim] large allocation: %llu MB, type %u\n",
              (unsigned long long)(info->allocationSize >> 20), info->memoryTypeIndex);
   if (mem_total >= mem_logged + (32u << 20)) {
      mem_logged = mem_total & ~((VkDeviceSize)(32u << 20) - 1);
      mem_log_locked("up");
   }
   pthread_mutex_unlock(&mem_lock);
   return r;
}

static VKAPI_ATTR void VKAPI_CALL
shim_FreeMemory(VkDevice device, VkDeviceMemory mem, const VkAllocationCallbacks *alloc)
{
   if (mem) {
      pthread_mutex_lock(&mem_lock);
      size_t i = mem_slot(mem);
      for (size_t probes = 0; mem_slots[i].mem && probes < MEM_SLOTS; probes++, i = (i + 1) & (MEM_SLOTS - 1)) {
         if (mem_slots[i].mem != mem)
            continue;
         if (mem_slots[i].type < VK_MAX_MEMORY_TYPES)
            mem_by_type[mem_slots[i].type] -= mem_slots[i].size;
         mem_total -= mem_slots[i].size;
         mem_count--;
         // Re-insert the rest of the cluster so lookups keep working.
         mem_slots[i].mem = VK_NULL_HANDLE;
         for (size_t j = (i + 1) & (MEM_SLOTS - 1); mem_slots[j].mem; j = (j + 1) & (MEM_SLOTS - 1)) {
            typeof(mem_slots[0]) e = mem_slots[j];
            mem_slots[j].mem = VK_NULL_HANDLE;
            size_t k = mem_slot(e.mem);
            while (mem_slots[k].mem)
               k = (k + 1) & (MEM_SLOTS - 1);
            mem_slots[k] = e;
         }
         break;
      }
      if (mem_total + (32u << 20) <= mem_logged) {
         mem_logged = mem_total & ~((VkDeviceSize)(32u << 20) - 1);
         mem_log_locked("down");
      }
      pthread_mutex_unlock(&mem_lock);
   }
   icd_FreeMemory(device, mem, alloc);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_BindBufferMemory(VkDevice device, VkBuffer buffer, VkDeviceMemory memory, VkDeviceSize offset)
{
   VkResult r = icd_BindBufferMemory(device, buffer, memory, offset);
   if (r == VK_SUCCESS && icd_GetBufferMemoryRequirements) {
      VkMemoryRequirements req;
      icd_GetBufferMemoryRequirements(device, buffer, &req);
      pthread_mutex_lock(&mem_lock);
      res_add_locked((uint64_t)buffer, req.size);
      pthread_mutex_unlock(&mem_lock);
   }
   return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_BindImageMemory(VkDevice device, VkImage image, VkDeviceMemory memory, VkDeviceSize offset)
{
   VkResult r = icd_BindImageMemory(device, image, memory, offset);
   if (r == VK_SUCCESS && icd_GetImageMemoryRequirements) {
      VkMemoryRequirements req;
      icd_GetImageMemoryRequirements(device, image, &req);
      pthread_mutex_lock(&mem_lock);
      res_add_locked((uint64_t)image, req.size);
      pthread_mutex_unlock(&mem_lock);
   }
   return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_BindBufferMemory2(VkDevice device, uint32_t count, const VkBindBufferMemoryInfo *infos)
{
   VkResult r = icd_BindBufferMemory2(device, count, infos);
   if (r == VK_SUCCESS && icd_GetBufferMemoryRequirements) {
      for (uint32_t i = 0; i < count; i++) {
         VkMemoryRequirements req;
         icd_GetBufferMemoryRequirements(device, infos[i].buffer, &req);
         pthread_mutex_lock(&mem_lock);
         res_add_locked((uint64_t)infos[i].buffer, req.size);
         pthread_mutex_unlock(&mem_lock);
      }
   }
   return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_BindImageMemory2(VkDevice device, uint32_t count, const VkBindImageMemoryInfo *infos)
{
   VkResult r = icd_BindImageMemory2(device, count, infos);
   if (r == VK_SUCCESS && icd_GetImageMemoryRequirements) {
      for (uint32_t i = 0; i < count; i++) {
         VkMemoryRequirements req;
         icd_GetImageMemoryRequirements(device, infos[i].image, &req);
         pthread_mutex_lock(&mem_lock);
         res_add_locked((uint64_t)infos[i].image, req.size);
         pthread_mutex_unlock(&mem_lock);
      }
   }
   return r;
}

static VKAPI_ATTR void VKAPI_CALL
shim_DestroyBuffer(VkDevice device, VkBuffer buffer, const VkAllocationCallbacks *alloc)
{
   if (buffer) {
      pthread_mutex_lock(&mem_lock);
      res_remove_locked((uint64_t)buffer);
      pthread_mutex_unlock(&mem_lock);
   }
   icd_DestroyBuffer(device, buffer, alloc);
}

static VKAPI_ATTR void VKAPI_CALL
shim_DestroyImage(VkDevice device, VkImage image, const VkAllocationCallbacks *alloc)
{
   if (image) {
      pthread_mutex_lock(&mem_lock);
      res_remove_locked((uint64_t)image);
      pthread_mutex_unlock(&mem_lock);
   }
   icd_DestroyImage(device, image, alloc);
}

// The ICD's entry points behind the wrappers (one device: the game's).
static PFN_vkQueueSubmit icd_QueueSubmit;
static PFN_vkQueueSubmit2 icd_QueueSubmit2;
static PFN_vkQueueSubmit2 icd_QueueSubmit2KHR;
static PFN_vkAcquireNextImageKHR icd_AcquireNextImageKHR;
static PFN_vkAcquireNextImage2KHR icd_AcquireNextImage2KHR;
static PFN_vkQueuePresentKHR icd_QueuePresentKHR;

static VKAPI_ATTR VkResult VKAPI_CALL
shim_QueueSubmit(VkQueue queue, uint32_t count, const VkSubmitInfo *submits, VkFence fence)
{
   wait_while_paused("vkQueueSubmit");
   return icd_QueueSubmit(queue, count, submits, fence);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_QueueSubmit2(VkQueue queue, uint32_t count, const VkSubmitInfo2 *submits, VkFence fence)
{
   wait_while_paused("vkQueueSubmit2");
   return icd_QueueSubmit2(queue, count, submits, fence);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_QueueSubmit2KHR(VkQueue queue, uint32_t count, const VkSubmitInfo2 *submits, VkFence fence)
{
   wait_while_paused("vkQueueSubmit2KHR");
   return icd_QueueSubmit2KHR(queue, count, submits, fence);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_AcquireNextImageKHR(VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout,
                         VkSemaphore semaphore, VkFence fence, uint32_t *index)
{
   wait_while_paused("vkAcquireNextImageKHR");
   return icd_AcquireNextImageKHR(device, swapchain, timeout, semaphore, fence, index);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_AcquireNextImage2KHR(VkDevice device, const VkAcquireNextImageInfoKHR *info, uint32_t *index)
{
   wait_while_paused("vkAcquireNextImage2KHR");
   return icd_AcquireNextImage2KHR(device, info, index);
}

static VKAPI_ATTR VkResult VKAPI_CALL
shim_QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *info)
{
   wait_while_paused("vkQueuePresentKHR");
   return icd_QueuePresentKHR(queue, info);
}

// Returns the wrapper for a held entry point, keeping the ICD's in `real`,
// or `real` itself for every other name.
static PFN_vkVoidFunction wrap(const char *name, PFN_vkVoidFunction real)
{
   if (!real)
      return NULL;
#define WRAP(fn) \
   if (!strcmp(name, "vk" #fn)) { icd_##fn = (void *)real; return (PFN_vkVoidFunction)shim_##fn; }
   WRAP(QueueSubmit)
   WRAP(QueueSubmit2)
   WRAP(QueueSubmit2KHR)
   WRAP(AcquireNextImageKHR)
   WRAP(AcquireNextImage2KHR)
   WRAP(QueuePresentKHR)
   WRAP(AllocateMemory)
   WRAP(FreeMemory)
   WRAP(GetPhysicalDeviceMemoryProperties)
   WRAP(BindBufferMemory)
   WRAP(BindImageMemory)
   WRAP(BindBufferMemory2)
   WRAP(BindImageMemory2)
   WRAP(DestroyBuffer)
   WRAP(DestroyImage)
#undef WRAP
   // Looked up for the accounting only; returned unwrapped.
   if (!strcmp(name, "vkGetBufferMemoryRequirements")) icd_GetBufferMemoryRequirements = (void *)real;
   if (!strcmp(name, "vkGetImageMemoryRequirements")) icd_GetImageMemoryRequirements = (void *)real;
   return real;
}

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
   return icd_GetDeviceProcAddr && name ? wrap(name, icd_GetDeviceProcAddr(device, name)) : NULL;
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
   return wrap(name, vk_icdGetInstanceProcAddr(instance, name));
}
