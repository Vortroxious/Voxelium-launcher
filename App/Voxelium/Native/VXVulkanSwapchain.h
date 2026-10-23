// Vulkan swapchain test on a CAMetalLayer (Minecraft 26.3 plan, Stage 1a): loads
// a Vulkan library (the loader shim, scripts/vulkan-shim.c, in front of Mesa's
// KosmicKrisp), creates a VK_EXT_metal_surface surface, a FIFO swapchain, and
// clears it in changing colours for a few seconds with at most 2 frames in
// flight, then tears everything down. Logs phys_footprint along the way.
//
// Header-only C, so the experimental app (ZinkTest.m, on iOS) and the Mac probe
// (scripts/vk-swapchain-probe.m) run the same code.
#pragma once

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_METAL_EXT
#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_metal.h>

// CAMetalLayer is an Objective-C class: under ARC the pointer cast needs __bridge.
#if defined(__OBJC__) && __has_feature(objc_arc)
#define VXVK_LAYER(p) ((__bridge const CAMetalLayer *)(p))
#else
#define VXVK_LAYER(p) ((const CAMetalLayer *)(p))
#endif

typedef void (*vxvk_log_fn)(void *ctx, const char *line);

typedef struct {
    vxvk_log_fn log;
    void *ctx;
} vxvk_logger;

static void vxvk_logf(const vxvk_logger *l, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void vxvk_logf(const vxvk_logger *l, const char *fmt, ...) {
    char line[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    l->log(l->ctx, line);
}

static double vxvk_footprint_mb(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / 1048576.0;
}

static double vxvk_now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static int vxvk_has_ext(const VkExtensionProperties *e, uint32_t n, const char *name) {
    for (uint32_t i = 0; i < n; i++)
        if (!strcmp(e[i].extensionName, name)) return 1;
    return 0;
}

static const char *vxvk_present_mode_name(VkPresentModeKHR m) {
    switch (m) {
    case VK_PRESENT_MODE_IMMEDIATE_KHR: return "IMMEDIATE";
    case VK_PRESENT_MODE_MAILBOX_KHR: return "MAILBOX";
    case VK_PRESENT_MODE_FIFO_KHR: return "FIFO";
    case VK_PRESENT_MODE_FIFO_RELAXED_KHR: return "FIFO_RELAXED";
    default: return "other";
    }
}

// Returns 0 when frames were presented and everything was torn down.
// `layer` is a CAMetalLayer *; `width`/`height` are used when the surface does
// not report a current extent.
static int vxvk_run_swapchain_test(const char *library, void *layer, uint32_t width, uint32_t height,
                                   double seconds, const vxvk_logger *L) {
#define FAIL(...) do { vxvk_logf(L, "VK_SWAPCHAIN_FAIL " __VA_ARGS__); goto done; } while (0)
#define CHECK(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) FAIL(#call " = %d", r_); } while (0)
    int ok = 0;
    void *lib = NULL;
    VkInstance inst = VK_NULL_HANDLE;
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    VkDevice dev = VK_NULL_HANDLE;
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    VkCommandPool pool = VK_NULL_HANDLE;
    enum { FRAMES = 2, MAX_IMAGES = 8 };
    VkFence fences[FRAMES] = {0};
    VkSemaphore acquired[FRAMES] = {0}, rendered[MAX_IMAGES] = {0};
    VkCommandBuffer cmds[FRAMES] = {0};
    VkImage images[MAX_IMAGES];
    uint32_t imageCount = 0;
    VkExtensionProperties *iexts = NULL, *dexts = NULL;

    vxvk_logf(L, "phys_footprint before Vulkan: %.1f MB", vxvk_footprint_mb());
    lib = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!lib) FAIL("dlopen %s: %s", library, dlerror());
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
    if (!gipa) FAIL("no vkGetInstanceProcAddr in %s", library);
#define GI(name) PFN_##name name = (PFN_##name)gipa(inst, #name); if (!name) FAIL("missing " #name)
    GI(vkEnumerateInstanceVersion);
    GI(vkEnumerateInstanceExtensionProperties);
    GI(vkCreateInstance);
    uint32_t version = 0;
    vkEnumerateInstanceVersion(&version);
    uint32_t niext = 0;
    CHECK(vkEnumerateInstanceExtensionProperties(NULL, &niext, NULL));
    iexts = calloc(niext, sizeof(*iexts));
    CHECK(vkEnumerateInstanceExtensionProperties(NULL, &niext, iexts));
    int portability = vxvk_has_ext(iexts, niext, "VK_KHR_portability_enumeration");
    vxvk_logf(L, "instance: Vulkan %u.%u.%u, %u extensions; VK_KHR_surface=%d VK_EXT_metal_surface=%d VK_KHR_portability_enumeration=%d",
              VK_API_VERSION_MAJOR(version), VK_API_VERSION_MINOR(version), VK_API_VERSION_PATCH(version), niext,
              vxvk_has_ext(iexts, niext, "VK_KHR_surface"), vxvk_has_ext(iexts, niext, "VK_EXT_metal_surface"), portability);
    if (!vxvk_has_ext(iexts, niext, "VK_KHR_surface") || !vxvk_has_ext(iexts, niext, "VK_EXT_metal_surface"))
        FAIL("the driver has no Metal surface support");

    // As SDL and Minecraft do on Apple platforms: portability enumeration when offered.
    const char *ienable[3] = {"VK_KHR_surface", "VK_EXT_metal_surface", "VK_KHR_portability_enumeration"};
    VkApplicationInfo app = {VK_STRUCTURE_TYPE_APPLICATION_INFO, NULL, "Voxelium swapchain test", 1, "none", 0, VK_API_VERSION_1_2};
    VkInstanceCreateInfo ici = {VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, NULL,
                                portability ? VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR : 0,
                                &app, 0, NULL, portability ? 3u : 2u, ienable};
    double t0 = vxvk_now_ms();
    CHECK(vkCreateInstance(&ici, NULL, &inst));
    GI(vkDestroyInstance); GI(vkEnumeratePhysicalDevices); GI(vkGetPhysicalDeviceProperties);
    GI(vkGetPhysicalDeviceQueueFamilyProperties); GI(vkEnumerateDeviceExtensionProperties);
    GI(vkCreateDevice); GI(vkGetDeviceProcAddr); GI(vkCreateMetalSurfaceEXT); GI(vkDestroySurfaceKHR);
    GI(vkGetPhysicalDeviceSurfaceSupportKHR); GI(vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
    GI(vkGetPhysicalDeviceSurfaceFormatsKHR); GI(vkGetPhysicalDeviceSurfacePresentModesKHR);

    uint32_t npd = 1;
    VkPhysicalDevice pd = VK_NULL_HANDLE;
    VkResult er = vkEnumeratePhysicalDevices(inst, &npd, &pd);
    if ((er != VK_SUCCESS && er != VK_INCOMPLETE) || !npd) FAIL("no physical device (%d)", er);
    VkPhysicalDeviceProperties props;
    vkGetPhysicalDeviceProperties(pd, &props);
    vxvk_logf(L, "device: %s, Vulkan %u.%u.%u, driver 0x%x", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion),
              VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion), props.driverVersion);

    {
        // In its own scope: under ARC the struct holds an Objective-C pointer,
        // which a goto may not jump over.
        VkMetalSurfaceCreateInfoEXT sci = {VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT, NULL, 0, VXVK_LAYER(layer)};
        CHECK(vkCreateMetalSurfaceEXT(inst, &sci, NULL, &surface));
    }

    uint32_t nq = 0, qfam = UINT32_MAX;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
    VkQueueFamilyProperties qprops[16];
    if (nq > 16) nq = 16;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qprops);
    for (uint32_t i = 0; i < nq && qfam == UINT32_MAX; i++) {
        VkBool32 present = VK_FALSE;
        vkGetPhysicalDeviceSurfaceSupportKHR(pd, i, surface, &present);
        if ((qprops[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) qfam = i;
    }
    if (qfam == UINT32_MAX) FAIL("no graphics queue that can present to the layer");

    uint32_t ndext = 0;
    CHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &ndext, NULL));
    dexts = calloc(ndext, sizeof(*dexts));
    CHECK(vkEnumerateDeviceExtensionProperties(pd, NULL, &ndext, dexts));
    int subset = vxvk_has_ext(dexts, ndext, "VK_KHR_portability_subset");
    vxvk_logf(L, "device: %u extensions; VK_KHR_swapchain=%d VK_KHR_portability_subset=%d",
              ndext, vxvk_has_ext(dexts, ndext, "VK_KHR_swapchain"), subset);
    if (!vxvk_has_ext(dexts, ndext, "VK_KHR_swapchain")) FAIL("no VK_KHR_swapchain");

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, NULL, 0, qfam, 1, &prio};
    const char *denable[2] = {"VK_KHR_swapchain", "VK_KHR_portability_subset"};
    VkDeviceCreateInfo dci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, NULL, 0, 1, &qci, 0, NULL, subset ? 2u : 1u, denable, NULL};
    CHECK(vkCreateDevice(pd, &dci, NULL, &dev));
#define GD(name) PFN_##name name = (PFN_##name)vkGetDeviceProcAddr(dev, #name); if (!name) FAIL("missing " #name)
    GD(vkDestroyDevice); GD(vkGetDeviceQueue); GD(vkDeviceWaitIdle); GD(vkCreateSwapchainKHR);
    GD(vkDestroySwapchainKHR); GD(vkGetSwapchainImagesKHR); GD(vkAcquireNextImageKHR); GD(vkQueuePresentKHR);
    GD(vkCreateCommandPool); GD(vkDestroyCommandPool); GD(vkAllocateCommandBuffers); GD(vkBeginCommandBuffer);
    GD(vkEndCommandBuffer); GD(vkResetCommandBuffer); GD(vkCmdPipelineBarrier); GD(vkCmdClearColorImage);
    GD(vkQueueSubmit); GD(vkCreateFence); GD(vkDestroyFence); GD(vkWaitForFences); GD(vkResetFences);
    GD(vkCreateSemaphore); GD(vkDestroySemaphore);
    VkQueue queue;
    vkGetDeviceQueue(dev, qfam, 0, &queue);
    vxvk_logf(L, "instance + device in %.1f ms; phys_footprint %.1f MB", vxvk_now_ms() - t0, vxvk_footprint_mb());

    VkSurfaceCapabilitiesKHR caps;
    CHECK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(pd, surface, &caps));
    uint32_t nfmt = 0, npm = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &nfmt, NULL);
    VkSurfaceFormatKHR fmts[32];
    if (nfmt > 32) nfmt = 32;
    vkGetPhysicalDeviceSurfaceFormatsKHR(pd, surface, &nfmt, fmts);
    vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface, &npm, NULL);
    VkPresentModeKHR pms[8];
    if (npm > 8) npm = 8;
    vkGetPhysicalDeviceSurfacePresentModesKHR(pd, surface, &npm, pms);
    char modes[128] = "";
    for (uint32_t i = 0; i < npm; i++) {
        strlcat(modes, vxvk_present_mode_name(pms[i]), sizeof modes);
        if (i + 1 < npm) strlcat(modes, ",", sizeof modes);
    }
    VkSurfaceFormatKHR fmt = fmts[0];
    for (uint32_t i = 0; i < nfmt; i++)
        if (fmts[i].format == VK_FORMAT_B8G8R8A8_UNORM) fmt = fmts[i];
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) extent = (VkExtent2D){width, height};
    uint32_t want = caps.minImageCount < 3 ? 3 : caps.minImageCount;
    if (caps.maxImageCount && want > caps.maxImageCount) want = caps.maxImageCount;
    vxvk_logf(L, "surface: %ux%u (current %ux%u), images %u-%u, %u formats (using %d), present modes %s",
              extent.width, extent.height, caps.currentExtent.width, caps.currentExtent.height,
              caps.minImageCount, caps.maxImageCount, nfmt, fmt.format, modes);

    VkSwapchainCreateInfoKHR swci = {VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR, NULL, 0, surface, want,
                                     fmt.format, fmt.colorSpace, extent, 1,
                                     VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
                                     VK_SHARING_MODE_EXCLUSIVE, 0, NULL, caps.currentTransform,
                                     VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR, VK_PRESENT_MODE_FIFO_KHR, VK_TRUE, VK_NULL_HANDLE};
    CHECK(vkCreateSwapchainKHR(dev, &swci, NULL, &swapchain));
    CHECK(vkGetSwapchainImagesKHR(dev, swapchain, &imageCount, NULL));
    if (imageCount > MAX_IMAGES) FAIL("%u swapchain images", imageCount);
    CHECK(vkGetSwapchainImagesKHR(dev, swapchain, &imageCount, images));

    VkCommandPoolCreateInfo pci = {VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, NULL,
                                   VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, qfam};
    CHECK(vkCreateCommandPool(dev, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, NULL, pool,
                                       VK_COMMAND_BUFFER_LEVEL_PRIMARY, FRAMES};
    CHECK(vkAllocateCommandBuffers(dev, &cai, cmds));
    VkFenceCreateInfo fci = {VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, NULL, VK_FENCE_CREATE_SIGNALED_BIT};
    VkSemaphoreCreateInfo semci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, NULL, 0};
    for (int i = 0; i < FRAMES; i++) {
        CHECK(vkCreateFence(dev, &fci, NULL, &fences[i]));
        CHECK(vkCreateSemaphore(dev, &semci, NULL, &acquired[i]));
    }
    for (uint32_t i = 0; i < imageCount; i++) CHECK(vkCreateSemaphore(dev, &semci, NULL, &rendered[i]));
    vxvk_logf(L, "swapchain: %u images, FIFO, at most %d frames in flight; phys_footprint %.1f MB",
              imageCount, FRAMES, vxvk_footprint_mb());

    // Present: clear each image to a colour that cycles through red, green and blue.
    uint32_t frames = 0;
    double start = vxvk_now_ms(), last = start, worst = 0, firstFrame = 0;
    while (vxvk_now_ms() - start < seconds * 1000.0) {
        int f = (int)(frames % FRAMES);
        CHECK(vkWaitForFences(dev, 1, &fences[f], VK_TRUE, 2000000000ull));
        uint32_t idx = 0;
        VkResult ar = vkAcquireNextImageKHR(dev, swapchain, 1000000000ull, acquired[f], VK_NULL_HANDLE, &idx);
        if (ar == VK_ERROR_OUT_OF_DATE_KHR) {
            vxvk_logf(L, "acquire: out of date after %u frames (layer resized); stopping", frames);
            break;
        }
        if (ar != VK_SUCCESS && ar != VK_SUBOPTIMAL_KHR) FAIL("vkAcquireNextImageKHR = %d", ar);
        CHECK(vkResetFences(dev, 1, &fences[f]));
        VkCommandBuffer cb = cmds[f];
        CHECK(vkResetCommandBuffer(cb, 0));
        VkCommandBufferBeginInfo bi = {VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, NULL,
                                       VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, NULL};
        CHECK(vkBeginCommandBuffer(cb, &bi));
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        VkImageMemoryBarrier toDst = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, NULL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
                                      VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                                      VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED, images[idx], range};
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0,
                             0, NULL, 0, NULL, 1, &toDst);
        double t = (vxvk_now_ms() - start) / 1000.0;
        int phase = (int)t % 3;
        float k = (float)(t - (int)t);
        VkClearColorValue colour = {{phase == 0 ? 1.0f - k : phase == 2 ? k : 0.0f,
                                     phase == 0 ? k : phase == 1 ? 1.0f - k : 0.0f,
                                     phase == 1 ? k : phase == 2 ? 1.0f - k : 0.0f, 1.0f}};
        vkCmdClearColorImage(cb, images[idx], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &range);
        VkImageMemoryBarrier toPresent = toDst;
        toPresent.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
        toPresent.dstAccessMask = 0;
        toPresent.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        toPresent.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0,
                             0, NULL, 0, NULL, 1, &toPresent);
        CHECK(vkEndCommandBuffer(cb));
        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si = {VK_STRUCTURE_TYPE_SUBMIT_INFO, NULL, 1, &acquired[f], &waitStage, 1, &cb, 1, &rendered[idx]};
        CHECK(vkQueueSubmit(queue, 1, &si, fences[f]));
        VkPresentInfoKHR pi = {VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, NULL, 1, &rendered[idx], 1, &swapchain, &idx, NULL};
        VkResult pr = vkQueuePresentKHR(queue, &pi);
        if (pr != VK_SUCCESS && pr != VK_SUBOPTIMAL_KHR && pr != VK_ERROR_OUT_OF_DATE_KHR) FAIL("vkQueuePresentKHR = %d", pr);
        double now = vxvk_now_ms();
        if (frames == 0) firstFrame = now - start;
        else if (now - last > worst) worst = now - last;
        last = now;
        frames++;
        if (frames % 120 == 0) vxvk_logf(L, "frame %u: phys_footprint %.1f MB", frames, vxvk_footprint_mb());
    }
    vkDeviceWaitIdle(dev);
    double total = vxvk_now_ms() - start;
    vxvk_logf(L, "presented %u frames in %.0f ms (%.1f fps; first %.1f ms, longest gap %.1f ms); phys_footprint %.1f MB",
              frames, total, frames * 1000.0 / total, firstFrame, worst, vxvk_footprint_mb());
    ok = frames > 0;

done:
    if (dev) {
        PFN_vkDeviceWaitIdle wait = (PFN_vkDeviceWaitIdle)gipa(inst, "vkDeviceWaitIdle");
        PFN_vkGetDeviceProcAddr gdpa = (PFN_vkGetDeviceProcAddr)gipa(inst, "vkGetDeviceProcAddr");
        if (wait) wait(dev);
        PFN_vkDestroySemaphore ds = (PFN_vkDestroySemaphore)gdpa(dev, "vkDestroySemaphore");
        PFN_vkDestroyFence df = (PFN_vkDestroyFence)gdpa(dev, "vkDestroyFence");
        PFN_vkDestroyCommandPool dp = (PFN_vkDestroyCommandPool)gdpa(dev, "vkDestroyCommandPool");
        PFN_vkDestroySwapchainKHR dsw = (PFN_vkDestroySwapchainKHR)gdpa(dev, "vkDestroySwapchainKHR");
        PFN_vkDestroyDevice dd = (PFN_vkDestroyDevice)gdpa(dev, "vkDestroyDevice");
        for (int i = 0; i < FRAMES; i++) {
            if (fences[i]) df(dev, fences[i], NULL);
            if (acquired[i]) ds(dev, acquired[i], NULL);
        }
        for (uint32_t i = 0; i < MAX_IMAGES; i++) if (rendered[i]) ds(dev, rendered[i], NULL);
        if (pool) dp(dev, pool, NULL);
        if (swapchain) dsw(dev, swapchain, NULL);
        dd(dev, NULL);
    }
    if (inst) {
        PFN_vkDestroySurfaceKHR dsurf = (PFN_vkDestroySurfaceKHR)gipa(inst, "vkDestroySurfaceKHR");
        PFN_vkDestroyInstance di = (PFN_vkDestroyInstance)gipa(inst, "vkDestroyInstance");
        if (surface && dsurf) dsurf(inst, surface, NULL);
        if (di) di(inst, NULL);
    }
    free(iexts);
    free(dexts);
    vxvk_logf(L, "phys_footprint after teardown: %.1f MB", vxvk_footprint_mb());
    if (ok) vxvk_logf(L, "VOXELIUM_VK_SWAPCHAIN_OK");
    return ok ? 0 : 1;
#undef GI
#undef GD
#undef CHECK
#undef FAIL
}
