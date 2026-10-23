// Minecraft 26.3 feasibility (Stage 1b): SDL3 hosts a window inside the app
// while it is driven from a background thread, as LWJGL drives it from
// Minecraft's render thread. libSDL3.dylib is loaded with dlopen (as LWJGL
// loads it) from Frameworks/sdl3, and Vulkan through SDL_Vulkan_LoadLibrary,
// as Minecraft's Vulkan backend does. Only the experimental IPA compiles this
// file's body, and only when scripts/build-ipa-zink-experimental.sh puts SDL's
// headers (build/deps/sdl3-out/include) on the header search path.

#import "SDLVulkanTest.h"
#if VOXELIUM_ZINK_EXPERIMENT
#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <mach/mach.h>

#if __has_include(<SDL3/SDL.h>) && __has_include(<vulkan/vulkan_core.h>)
#define VX_SDL_HEADERS 1
#define VK_NO_PROTOTYPES 1
#include <vulkan/vulkan_core.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>
#else
#define VX_SDL_HEADERS 0
#endif

#define kTestSeconds 5.0
#define kFramesInFlight 2

#pragma mark - Bundle lookup

static NSString *frameworksDir(NSString *sub) {
    return [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:sub];
}

static NSString *existing(NSString *p) {
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

static NSString *sdlPath(void) {
    return existing([frameworksDir(@"sdl3") stringByAppendingPathComponent:@"libSDL3.dylib"]);
}

BOOL VXSDLBundled(void) { return VX_SDL_HEADERS && sdlPath() != nil; }

NSString *VXSDLVulkanLibraryPath(void) {
    // The loader shim exports vkGetInstanceProcAddr, which SDL looks up; the
    // bare ICD only has vk_icdGetInstanceProcAddr.
    for (NSString *dir in @[@"zink", @"sdl3", @""]) {
        NSString *p = existing([frameworksDir(dir) stringByAppendingPathComponent:@"libvulkan.1.dylib"]);
        if (p) return p;
    }
    return existing([frameworksDir(@"zink") stringByAppendingPathComponent:@"libvulkan_kosmickrisp.dylib"]);
}

__attribute__((unused)) static double footprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / (1024.0 * 1024.0);
}

#if VX_SDL_HEADERS

#pragma mark - SDL entry points (dlsym, as LWJGL binds them)

#define VX_SDL_FUNCS(X) \
    X(SDL_GetVersion) X(SDL_GetRevision) X(SDL_GetError) X(SDL_SetHint) X(SDL_SetAppMetadataProperty) \
    X(SDL_Init) X(SDL_Quit) X(SDL_GetCurrentVideoDriver) X(SDL_GetTicksNS) X(SDL_Delay) \
    X(SDL_CreateWindow) X(SDL_DestroyWindow) X(SDL_GetWindowSize) X(SDL_GetWindowSizeInPixels) \
    X(SDL_GetWindowPixelDensity) X(SDL_GetWindowFlags) \
    X(SDL_PumpEvents) X(SDL_PollEvent) X(SDL_GetEventDescription) \
    X(SDL_Vulkan_LoadLibrary) X(SDL_Vulkan_UnloadLibrary) X(SDL_Vulkan_GetVkGetInstanceProcAddr) \
    X(SDL_Vulkan_GetInstanceExtensions) X(SDL_Vulkan_CreateSurface) X(SDL_Vulkan_DestroySurface) \
    X(SDL_CreateRenderer) X(SDL_DestroyRenderer) X(SDL_GetRendererName) X(SDL_SetRenderVSync) \
    X(SDL_GetRenderOutputSize) X(SDL_SetRenderDrawColor) X(SDL_RenderClear) X(SDL_RenderFillRect) \
    X(SDL_RenderPresent)

#define VX_DECLARE(f) static __typeof__(&f) p_##f;
VX_SDL_FUNCS(VX_DECLARE)

#pragma mark - Vulkan entry points

#define VX_VK_GLOBAL(X) \
    X(vkEnumerateInstanceExtensionProperties) X(vkEnumerateInstanceVersion) X(vkCreateInstance)
#define VX_VK_INSTANCE(X) \
    X(vkDestroyInstance) X(vkEnumeratePhysicalDevices) X(vkGetPhysicalDeviceProperties2) \
    X(vkGetPhysicalDeviceQueueFamilyProperties) X(vkEnumerateDeviceExtensionProperties) \
    X(vkCreateDevice) X(vkGetDeviceProcAddr) X(vkGetPhysicalDeviceSurfaceSupportKHR) \
    X(vkGetPhysicalDeviceSurfaceCapabilitiesKHR) X(vkGetPhysicalDeviceSurfaceFormatsKHR) \
    X(vkGetPhysicalDeviceSurfacePresentModesKHR)
#define VX_VK_DEVICE(X) \
    X(vkDestroyDevice) X(vkGetDeviceQueue) X(vkDeviceWaitIdle) X(vkCreateSwapchainKHR) \
    X(vkDestroySwapchainKHR) X(vkGetSwapchainImagesKHR) X(vkAcquireNextImageKHR) X(vkQueuePresentKHR) \
    X(vkCreateCommandPool) X(vkDestroyCommandPool) X(vkAllocateCommandBuffers) X(vkResetCommandBuffer) \
    X(vkBeginCommandBuffer) X(vkEndCommandBuffer) X(vkCmdPipelineBarrier) X(vkCmdClearColorImage) \
    X(vkQueueSubmit) X(vkCreateFence) X(vkDestroyFence) X(vkWaitForFences) X(vkResetFences) \
    X(vkCreateSemaphore) X(vkDestroySemaphore)

#define VX_VK_DECLARE(f) static PFN_##f p_##f;
VX_VK_GLOBAL(VX_VK_DECLARE)
VX_VK_INSTANCE(VX_VK_DECLARE)
VX_VK_DEVICE(VX_VK_DECLARE)

static const char *vkResultName(VkResult r) {
    switch (r) {
#define R(x) case x: return #x;
    R(VK_SUCCESS) R(VK_NOT_READY) R(VK_TIMEOUT) R(VK_SUBOPTIMAL_KHR) R(VK_ERROR_OUT_OF_HOST_MEMORY)
    R(VK_ERROR_OUT_OF_DEVICE_MEMORY) R(VK_ERROR_INITIALIZATION_FAILED) R(VK_ERROR_DEVICE_LOST)
    R(VK_ERROR_LAYER_NOT_PRESENT) R(VK_ERROR_EXTENSION_NOT_PRESENT) R(VK_ERROR_FEATURE_NOT_PRESENT)
    R(VK_ERROR_INCOMPATIBLE_DRIVER) R(VK_ERROR_SURFACE_LOST_KHR) R(VK_ERROR_OUT_OF_DATE_KHR)
    R(VK_ERROR_NATIVE_WINDOW_IN_USE_KHR)
#undef R
    default: return "VkResult(other)";
    }
}

/// Hue (0..1) to an RGB clear colour.
static VkClearColorValue hueColor(double h) {
    double r = fabs(h * 6 - 3) - 1, g = 2 - fabs(h * 6 - 2), b = 2 - fabs(h * 6 - 4);
    VkClearColorValue c = {{(float)fmin(fmax(r, 0), 1), (float)fmin(fmax(g, 0), 1), (float)fmin(fmax(b, 0), 1), 1}};
    return c;
}

#endif // VX_SDL_HEADERS

#pragma mark - Test

static BOOL sVulkanUsed = NO;

@implementation VXSDLVulkanTest {
    NSMutableString *_report;
    NSMutableDictionary<NSString *, NSNumber *> *_eventCounts;
    BOOL _windowShown;
    int _fingerEvents, _mouseEvents;
#if VX_SDL_HEADERS
    void *_sdl;
    SDL_Window *_window;
    BOOL _vulkanLoaded;
    // Vulkan objects
    VkInstance _instance;
    VkSurfaceKHR _surface;
    VkPhysicalDevice _gpu;
    VkDevice _device;
    VkQueue _queue;
    uint32_t _queueFamily;
    VkSwapchainKHR _swapchain;
    VkFormat _format;
    VkExtent2D _extent;
    uint32_t _imageCount;
    VkImage _images[8];
    VkSemaphore _renderDone[8];
    VkCommandPool _pool;
    VkCommandBuffer _cmdBufs[kFramesInFlight];
    VkFence _fences[kFramesInFlight];
    VkSemaphore _acquired[kFramesInFlight];
    BOOL _resized;
    // Fingers currently down, for the renderer fallback.
    SDL_FingerID _fingerIDs[10];
    float _fingerX[10], _fingerY[10];
#endif
}

- (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[SDLTest] %@", line);
    @synchronized(self) { [_report appendFormat:@"%@\n", line]; }
    if (self.onLog) self.onLog(line);
    if (self.logPath) {
        NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
        if (!h) {
            [NSFileManager.defaultManager createFileAtPath:self.logPath contents:nil attributes:nil];
            h = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
        }
        [h seekToEndOfFile];
        [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [h closeFile];
    }
}

- (void)start {
    _report = [NSMutableString string];
    _eventCounts = [NSMutableDictionary dictionary];
    // Like Minecraft's render thread: not the main thread, and with a JVM-sized stack.
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    t.name = @"VoxeliumSDLTest";
    t.stackSize = 8 << 20;
    t.qualityOfService = NSQualityOfServiceUserInteractive;
    [t start];
}

- (void)finish:(BOOL)ok {
    NSString *report;
    @synchronized(self) { report = [_report copy]; }
    dispatch_async(dispatch_get_main_queue(), ^{
        // SDL's window asked the scene for landscape; give the launcher its portrait back.
        if (@available(iOS 16.0, *)) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if (![s isKindOfClass:UIWindowScene.class]) continue;
                UIWindowScene *scene = (UIWindowScene *)s;
                for (UIWindow *w in scene.windows) {
                    if (w.windowLevel == UIWindowLevelNormal && !w.hidden) { [w makeKeyWindow]; break; }
                }
                UIWindowSceneGeometryPreferencesIOS *prefs =
                    [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskPortrait];
                [scene requestGeometryUpdateWithPreferences:prefs errorHandler:nil];
            }
        }
        if (self.onFinish) self.onFinish(ok, report);
    });
}

#if !VX_SDL_HEADERS

- (void)run {
    [self log:@"The SDL + Vulkan test is not compiled in: SDL's headers were not found (run scripts/build-sdl3.sh, then build the experimental IPA)."];
    [self finish:NO];
}

#else

- (void)run {
    @autoreleasepool {
        [self log:@"===== SDL + Vulkan test %@", [[NSISO8601DateFormatter new] stringFromDate:NSDate.date]];
        [self log:@"test thread: %@, main thread: %@", NSThread.currentThread.name, NSThread.isMainThread ? @"YES" : @"NO"];
        [self log:@"phys_footprint before: %.1f MB", footprintMB()];
        BOOL ok = [self runChecks];
        [self teardown];
        [self log:@"phys_footprint after teardown: %.1f MB", footprintMB()];
        [self log:@"events: %@ (finger %d, mouse %d)", [self eventSummary], _fingerEvents, _mouseEvents];
        [self log:@"%@", ok ? @"VOXELIUM_SDL_TEST_OK" : @"SDL test failed"];
        [self finish:ok];
    }
}

- (NSString *)eventSummary {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in [_eventCounts.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, _eventCounts[k]]];
    }
    return parts.count ? [parts componentsJoinedByString:@" "] : @"none";
}

- (NSString *)sdlError {
    const char *e = p_SDL_GetError ? p_SDL_GetError() : NULL;
    return e && *e ? @(e) : @"(no SDL error)";
}

- (BOOL)loadSDL {
    NSString *path = sdlPath();
    if (!path) {
        [self log:@"Frameworks/sdl3/libSDL3.dylib is not bundled (scripts/build-sdl3.sh)"];
        return NO;
    }
    _sdl = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_sdl) {
        [self log:@"dlopen libSDL3.dylib failed: %s", dlerror()];
        return NO;
    }
#define VX_LOAD(f) \
    p_##f = (__typeof__(&f))dlsym(_sdl, #f); \
    if (!p_##f) { [self log:@"libSDL3.dylib lacks %s", #f]; return NO; }
    VX_SDL_FUNCS(VX_LOAD)
#undef VX_LOAD
    int v = p_SDL_GetVersion();
    [self log:@"SDL %d.%d.%d (%s) from %@", SDL_VERSIONNUM_MAJOR(v), SDL_VERSIONNUM_MINOR(v), SDL_VERSIONNUM_MICRO(v),
              p_SDL_GetRevision(), path.lastPathComponent];
    return YES;
}

- (BOOL)runChecks {
    if (![self loadSDL]) return NO;

    // What Minecraft 26.3 sets before SDL_Init (RenderSystem.initBackendSystem).
    p_SDL_SetAppMetadataProperty(SDL_PROP_APP_METADATA_NAME_STRING, "Voxelium SDL test");
    p_SDL_SetHint("SDL_NO_SIGNAL_HANDLERS", "1");
    p_SDL_SetHint(SDL_HINT_VIDEO_MINIMIZE_ON_FOCUS_LOSS, "0");
    p_SDL_SetHint(SDL_HINT_QUIT_ON_LAST_WINDOW_CLOSE, "0");
    p_SDL_SetHint(SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");

    // No SDL_SetMainReady(): Minecraft never calls it (patches/sdl3/0003).
    double t0 = CACurrentMediaTime();
    if (!p_SDL_Init(SDL_INIT_VIDEO)) {
        [self log:@"SDL_Init(SDL_INIT_VIDEO) failed: %@", [self sdlError]];
        return NO;
    }
    [self log:@"SDL_Init(VIDEO) ok in %.0f ms, video driver %s", (CACurrentMediaTime() - t0) * 1000,
              p_SDL_GetCurrentVideoDriver() ?: "(none)"];

    // Minecraft loads Vulkan before it creates its window (VulkanBackend);
    // SDL_CreateWindow(SDL_WINDOW_VULKAN) would otherwise load libvulkan.dylib.
    NSString *vk = self.sdlOnly ? nil : VXSDLVulkanLibraryPath();
    if (self.sdlOnly) {
        [self log:@"Vulkan skipped (SDL only)"];
    } else if (!vk) {
        [self log:@"no Vulkan library bundled (Frameworks/zink/libvulkan.1.dylib or libvulkan_kosmickrisp.dylib); SDL only"];
    } else {
        @synchronized(VXSDLVulkanTest.class) { sVulkanUsed = YES; }
        if (p_SDL_Vulkan_LoadLibrary(vk.fileSystemRepresentation)) {
            _vulkanLoaded = YES;
            [self log:@"SDL_Vulkan_LoadLibrary(%@) ok", vk.lastPathComponent];
        } else {
            [self log:@"SDL_Vulkan_LoadLibrary(%@) failed: %@", vk.lastPathComponent, [self sdlError]];
            [self log:@"continuing with SDL only (window + touches through SDL's Metal renderer)"];
        }
    }

    SDL_WindowFlags flags = SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_RESIZABLE | (_vulkanLoaded ? SDL_WINDOW_VULKAN : 0);
    t0 = CACurrentMediaTime();
    _window = p_SDL_CreateWindow("Voxelium SDL test", 854, 480, flags);
    if (!_window) {
        [self log:@"SDL_CreateWindow failed: %@", [self sdlError]];
        return NO;
    }
    [self logWindow:[NSString stringWithFormat:@"SDL_CreateWindow ok in %.0f ms:", (CACurrentMediaTime() - t0) * 1000]];
    _windowShown = YES;

    BOOL ok;
    if (_vulkanLoaded) {
        ok = [self runVulkan];
    } else {
        ok = [self runRenderer];
    }
    [self logWindow:@"window at the end:"];
    return ok;
}

- (void)logWindow:(NSString *)prefix {
    int w = 0, h = 0, pw = 0, ph = 0;
    p_SDL_GetWindowSize(_window, &w, &h);
    p_SDL_GetWindowSizeInPixels(_window, &pw, &ph);
    [self log:@"%@ %dx%d points, %dx%d pixels, density %.2f, flags 0x%llx", prefix, w, h, pw, ph,
              p_SDL_GetWindowPixelDensity(_window), (unsigned long long)p_SDL_GetWindowFlags(_window)];
}

/// Polls and logs every event (SDL_PumpEvents runs inside SDL_PollEvent).
- (void)pollEvents {
    SDL_Event ev;
    while (p_SDL_PollEvent(&ev)) {
        char desc[512];
        p_SDL_GetEventDescription(&ev, desc, sizeof desc);
        // SDL's description starts with the event name, then its fields.
        NSString *d = @(desc);
        NSString *name = [d componentsSeparatedByString:@" "].firstObject ?: @"?";
        _eventCounts[name] = @(_eventCounts[name].intValue + 1);
        if (ev.type >= SDL_EVENT_FINGER_DOWN && ev.type <= SDL_EVENT_FINGER_CANCELED) _fingerEvents++;
        if (ev.type >= SDL_EVENT_MOUSE_MOTION && ev.type <= SDL_EVENT_MOUSE_WHEEL) _mouseEvents++;
        [self log:@"event %@", d];
        switch (ev.type) {
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_RESIZED:
        case SDL_EVENT_WINDOW_METAL_VIEW_RESIZED:
            _resized = YES;
            break;
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION:
            [self setFinger:ev.tfinger.fingerID x:ev.tfinger.x y:ev.tfinger.y];
            break;
        case SDL_EVENT_FINGER_UP:
        case SDL_EVENT_FINGER_CANCELED:
            [self removeFinger:ev.tfinger.fingerID];
            break;
        default:
            break;
        }
    }
}

- (void)setFinger:(SDL_FingerID)fid x:(float)x y:(float)y {
    int freeSlot = -1;
    for (int i = 0; i < 10; i++) {
        if (_fingerIDs[i] == fid) { _fingerX[i] = x; _fingerY[i] = y; return; }
        if (!_fingerIDs[i] && freeSlot < 0) freeSlot = i;
    }
    if (freeSlot >= 0) { _fingerIDs[freeSlot] = fid; _fingerX[freeSlot] = x; _fingerY[freeSlot] = y; }
}

- (void)removeFinger:(SDL_FingerID)fid {
    for (int i = 0; i < 10; i++) if (_fingerIDs[i] == fid) _fingerIDs[i] = 0;
}

#pragma mark SDL only: Metal renderer

- (BOOL)runRenderer {
    SDL_Renderer *r = p_SDL_CreateRenderer(_window, NULL);
    if (!r) {
        [self log:@"SDL_CreateRenderer failed: %@; polling events only", [self sdlError]];
    } else {
        p_SDL_SetRenderVSync(r, 1);
        int ow = 0, oh = 0;
        p_SDL_GetRenderOutputSize(r, &ow, &oh);
        [self log:@"SDL renderer %s, output %dx%d", p_SDL_GetRendererName(r), ow, oh];
    }
    Uint64 start = p_SDL_GetTicksNS();
    int frames = 0;
    double nextReport = 1;
    for (;;) {
        double t = (p_SDL_GetTicksNS() - start) / 1e9;
        if (t >= kTestSeconds) break;
        [self pollEvents];
        if (r) {
            VkClearColorValue c = hueColor(fmod(t / kTestSeconds, 1));
            p_SDL_SetRenderDrawColor(r, (Uint8)(c.float32[0] * 255), (Uint8)(c.float32[1] * 255), (Uint8)(c.float32[2] * 255), 255);
            p_SDL_RenderClear(r);
            int ow = 0, oh = 0;
            p_SDL_GetRenderOutputSize(r, &ow, &oh);
            p_SDL_SetRenderDrawColor(r, 255, 255, 255, 255);
            for (int i = 0; i < 10; i++) {
                if (!_fingerIDs[i]) continue;
                SDL_FRect rect = {_fingerX[i] * ow - 60, _fingerY[i] * oh - 60, 120, 120};
                p_SDL_RenderFillRect(r, &rect);
            }
            p_SDL_RenderPresent(r);
        } else {
            p_SDL_Delay(16);
        }
        frames++;
        if (t >= nextReport) {
            [self log:@"t=%.1f s: %d frames, footprint %.1f MB", t, frames, footprintMB()];
            nextReport += 1;
        }
    }
    [self log:@"renderer: %d frames in %.1f s", frames, kTestSeconds];
    if (r) p_SDL_DestroyRenderer(r);
    [self log:@"VOXELIUM_SDL_WINDOW_OK (window from a background thread%@)", r ? @", Metal renderer frames" : @""];
    return YES;
}

#pragma mark Vulkan

- (BOOL)check:(VkResult)r what:(const char *)what {
    if (r == VK_SUCCESS) return YES;
    [self log:@"%s failed: %s (%d)", what, vkResultName(r), r];
    return NO;
}

- (BOOL)runVulkan {
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)p_SDL_Vulkan_GetVkGetInstanceProcAddr();
    if (!gipa) {
        [self log:@"SDL_Vulkan_GetVkGetInstanceProcAddr returned NULL: %@", [self sdlError]];
        return NO;
    }
#define VX_VK_LOAD_GLOBAL(f) p_##f = (PFN_##f)gipa(VK_NULL_HANDLE, #f);
    VX_VK_GLOBAL(VX_VK_LOAD_GLOBAL)
#undef VX_VK_LOAD_GLOBAL
    if (!p_vkCreateInstance || !p_vkEnumerateInstanceExtensionProperties) {
        [self log:@"vkCreateInstance/vkEnumerateInstanceExtensionProperties not found"];
        return NO;
    }
    uint32_t apiVersion = VK_API_VERSION_1_0;
    if (p_vkEnumerateInstanceVersion) p_vkEnumerateInstanceVersion(&apiVersion);
    [self log:@"Vulkan instance version %u.%u.%u", VK_API_VERSION_MAJOR(apiVersion), VK_API_VERSION_MINOR(apiVersion), VK_API_VERSION_PATCH(apiVersion)];

    uint32_t n = 0;
    p_vkEnumerateInstanceExtensionProperties(NULL, &n, NULL);
    VkExtensionProperties *props = calloc(n ? n : 1, sizeof *props);
    p_vkEnumerateInstanceExtensionProperties(NULL, &n, props);
    NSMutableArray *have = [NSMutableArray array];
    for (uint32_t i = 0; i < n; i++) [have addObject:@(props[i].extensionName)];
    free(props);
    [self log:@"instance extensions (%u): %@", n, [have componentsJoinedByString:@" "]];

    Uint32 sdlCount = 0;
    const char *const *sdlExt = p_SDL_Vulkan_GetInstanceExtensions(&sdlCount);
    if (!sdlExt) {
        [self log:@"SDL_Vulkan_GetInstanceExtensions failed: %@", [self sdlError]];
        return NO;
    }
    const char *exts[16];
    uint32_t extCount = 0;
    NSMutableArray *want = [NSMutableArray array];
    for (Uint32 i = 0; i < sdlCount && extCount < 14; i++) {
        exts[extCount++] = sdlExt[i];
        [want addObject:@(sdlExt[i])];
    }
    [self log:@"SDL_Vulkan_GetInstanceExtensions: %@", [want componentsJoinedByString:@" "]];
    VkInstanceCreateFlags iflags = 0;
    if ([have containsObject:@VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME]) {
        exts[extCount++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
        iflags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    }
    for (NSString *e in want) {
        if (![have containsObject:e]) [self log:@"warning: the driver does not list %@, which SDL needs", e];
    }

    VkApplicationInfo app = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Voxelium SDL test",
        .pEngineName = "Voxelium",
        .apiVersion = VK_API_VERSION_1_2, // what Minecraft 26.3 asks for
    };
    VkInstanceCreateInfo ici = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .flags = iflags,
        .pApplicationInfo = &app,
        .enabledExtensionCount = extCount,
        .ppEnabledExtensionNames = exts,
    };
    if (![self check:p_vkCreateInstance(&ici, NULL, &_instance) what:"vkCreateInstance"]) return NO;
#define VX_VK_LOAD_INSTANCE(f) \
    p_##f = (PFN_##f)gipa(_instance, #f); \
    if (!p_##f) { [self log:@"%s not found", #f]; return NO; }
    VX_VK_INSTANCE(VX_VK_LOAD_INSTANCE)
#undef VX_VK_LOAD_INSTANCE

    double t0 = CACurrentMediaTime();
    if (!p_SDL_Vulkan_CreateSurface(_window, _instance, NULL, &_surface)) {
        [self log:@"SDL_Vulkan_CreateSurface failed: %@", [self sdlError]];
        return NO;
    }
    [self log:@"SDL_Vulkan_CreateSurface ok in %.0f ms", (CACurrentMediaTime() - t0) * 1000];

    if (![self pickDevice]) return NO;
    if (![self createSwapchain]) return NO;
    if (![self createFrameObjects]) return NO;
    return [self renderLoop];
}

- (BOOL)pickDevice {
    uint32_t n = 0;
    p_vkEnumeratePhysicalDevices(_instance, &n, NULL);
    if (n == 0) {
        [self log:@"no Vulkan physical devices"];
        return NO;
    }
    VkPhysicalDevice gpus[4];
    n = MIN(n, 4u);
    p_vkEnumeratePhysicalDevices(_instance, &n, gpus);
    _gpu = gpus[0];

    VkPhysicalDeviceDriverProperties driver = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
    VkPhysicalDeviceProperties2 p2 = {.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &driver};
    p_vkGetPhysicalDeviceProperties2(_gpu, &p2);
    uint32_t v = p2.properties.apiVersion;
    [self log:@"device: %s, Vulkan %u.%u.%u, driver %s (%s)", p2.properties.deviceName, VK_API_VERSION_MAJOR(v),
              VK_API_VERSION_MINOR(v), VK_API_VERSION_PATCH(v), driver.driverName, driver.driverInfo];

    uint32_t qn = 0;
    p_vkGetPhysicalDeviceQueueFamilyProperties(_gpu, &qn, NULL);
    VkQueueFamilyProperties qf[16];
    qn = MIN(qn, 16u);
    p_vkGetPhysicalDeviceQueueFamilyProperties(_gpu, &qn, qf);
    _queueFamily = UINT32_MAX;
    for (uint32_t i = 0; i < qn; i++) {
        VkBool32 present = VK_FALSE;
        p_vkGetPhysicalDeviceSurfaceSupportKHR(_gpu, i, _surface, &present);
        if ((qf[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) { _queueFamily = i; break; }
    }
    if (_queueFamily == UINT32_MAX) {
        [self log:@"no queue family with graphics and present support for the SDL surface"];
        return NO;
    }

    uint32_t en = 0;
    p_vkEnumerateDeviceExtensionProperties(_gpu, NULL, &en, NULL);
    VkExtensionProperties *ep = calloc(en ? en : 1, sizeof *ep);
    p_vkEnumerateDeviceExtensionProperties(_gpu, NULL, &en, ep);
    BOOL swapchain = NO, portability = NO;
    for (uint32_t i = 0; i < en; i++) {
        if (!strcmp(ep[i].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) swapchain = YES;
        if (!strcmp(ep[i].extensionName, "VK_KHR_portability_subset")) portability = YES;
    }
    free(ep);
    if (!swapchain) {
        [self log:@"the device has no VK_KHR_swapchain"];
        return NO;
    }
    const char *dext[2] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"};
    float prio = 1;
    VkDeviceQueueCreateInfo qci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = _queueFamily,
        .queueCount = 1,
        .pQueuePriorities = &prio,
    };
    VkDeviceCreateInfo dci = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &qci,
        .enabledExtensionCount = portability ? 2 : 1, // the spec requires portability_subset when offered
        .ppEnabledExtensionNames = dext,
    };
    if (![self check:p_vkCreateDevice(_gpu, &dci, NULL, &_device) what:"vkCreateDevice"]) return NO;
#define VX_VK_LOAD_DEVICE(f) \
    p_##f = (PFN_##f)p_vkGetDeviceProcAddr(_device, #f); \
    if (!p_##f) { [self log:@"%s not found", #f]; return NO; }
    VX_VK_DEVICE(VX_VK_LOAD_DEVICE)
#undef VX_VK_LOAD_DEVICE
    p_vkGetDeviceQueue(_device, _queueFamily, 0, &_queue);
    [self log:@"device created (queue family %u%@)", _queueFamily, portability ? @", VK_KHR_portability_subset" : @""];
    return YES;
}

- (BOOL)createSwapchain {
    VkSurfaceCapabilitiesKHR caps;
    if (![self check:p_vkGetPhysicalDeviceSurfaceCapabilitiesKHR(_gpu, _surface, &caps) what:"vkGetPhysicalDeviceSurfaceCapabilitiesKHR"]) return NO;
    VkExtent2D extent = caps.currentExtent;
    if (extent.width == UINT32_MAX) {
        int pw = 0, ph = 0;
        p_SDL_GetWindowSizeInPixels(_window, &pw, &ph);
        extent.width = (uint32_t)MAX(pw, 1);
        extent.height = (uint32_t)MAX(ph, 1);
    }
    if (extent.width == 0 || extent.height == 0) {
        [self log:@"surface extent is 0x0; not creating a swapchain"];
        return NO;
    }
    if (!(caps.supportedUsageFlags & VK_IMAGE_USAGE_TRANSFER_DST_BIT)) {
        [self log:@"swapchain images do not support TRANSFER_DST (usage 0x%x); this test clears with vkCmdClearColorImage", caps.supportedUsageFlags];
        return NO;
    }
    uint32_t fn = 0;
    p_vkGetPhysicalDeviceSurfaceFormatsKHR(_gpu, _surface, &fn, NULL);
    VkSurfaceFormatKHR formats[32];
    fn = MIN(fn, 32u);
    p_vkGetPhysicalDeviceSurfaceFormatsKHR(_gpu, _surface, &fn, formats);
    if (fn == 0) {
        [self log:@"no surface formats"];
        return NO;
    }
    VkSurfaceFormatKHR fmt = formats[0];
    for (uint32_t i = 0; i < fn; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_UNORM) { fmt = formats[i]; break; }
    }
    uint32_t pn = 0;
    p_vkGetPhysicalDeviceSurfacePresentModesKHR(_gpu, _surface, &pn, NULL);
    uint32_t count = MAX(caps.minImageCount, 2u) + 1;
    if (caps.maxImageCount) count = MIN(count, caps.maxImageCount);
    count = MIN(count, 8u);
    VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    if (!(caps.supportedCompositeAlpha & alpha)) {
        for (uint32_t b = 1; b; b <<= 1) if (caps.supportedCompositeAlpha & b) { alpha = (VkCompositeAlphaFlagBitsKHR)b; break; }
    }
    VkSwapchainKHR old = _swapchain;
    VkSwapchainCreateInfoKHR sci = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = _surface,
        .minImageCount = count,
        .imageFormat = fmt.format,
        .imageColorSpace = fmt.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = alpha,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR, // always supported; paces to the display
        .clipped = VK_TRUE,
        .oldSwapchain = old,
    };
    VkSwapchainKHR sc;
    if (![self check:p_vkCreateSwapchainKHR(_device, &sci, NULL, &sc) what:"vkCreateSwapchainKHR"]) return NO;
    if (old) p_vkDestroySwapchainKHR(_device, old, NULL);
    _swapchain = sc;
    _format = fmt.format;
    _extent = extent;
    uint32_t oldCount = _imageCount;
    _imageCount = 8;
    p_vkGetSwapchainImagesKHR(_device, _swapchain, &_imageCount, _images);
    // The old swapchain's semaphores are idle: recreation waits for the device.
    for (uint32_t i = 0; i < oldCount; i++) {
        p_vkDestroySemaphore(_device, _renderDone[i], NULL);
        _renderDone[i] = VK_NULL_HANDLE;
    }
    VkSemaphoreCreateInfo semi = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    for (uint32_t i = 0; i < _imageCount; i++) {
        if (![self check:p_vkCreateSemaphore(_device, &semi, NULL, &_renderDone[i]) what:"vkCreateSemaphore"]) return NO;
    }
    [self log:@"swapchain %ux%u, %u images (min %u), format %d, colour space %d, %u present modes, FIFO, transform 0x%x, alpha 0x%x",
              extent.width, extent.height, _imageCount, caps.minImageCount, fmt.format, fmt.colorSpace, pn,
              caps.currentTransform, alpha];
    return YES;
}

- (BOOL)createFrameObjects {
    VkCommandPoolCreateInfo pci = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = _queueFamily,
    };
    if (![self check:p_vkCreateCommandPool(_device, &pci, NULL, &_pool) what:"vkCreateCommandPool"]) return NO;
    VkCommandBufferAllocateInfo ai = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = _pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = kFramesInFlight,
    };
    if (![self check:p_vkAllocateCommandBuffers(_device, &ai, _cmdBufs) what:"vkAllocateCommandBuffers"]) return NO;
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .flags = VK_FENCE_CREATE_SIGNALED_BIT};
    VkSemaphoreCreateInfo semi = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
    for (int i = 0; i < kFramesInFlight; i++) {
        if (![self check:p_vkCreateFence(_device, &fci, NULL, &_fences[i]) what:"vkCreateFence"]) return NO;
        if (![self check:p_vkCreateSemaphore(_device, &semi, NULL, &_acquired[i]) what:"vkCreateSemaphore"]) return NO;
    }
    return YES;
}

- (BOOL)recreateSwapchain:(const char *)why {
    p_vkDeviceWaitIdle(_device);
    [self log:@"recreating the swapchain (%s)", why];
    _resized = NO;
    return [self createSwapchain];
}

- (void)record:(VkCommandBuffer)cmd image:(VkImage)image color:(VkClearColorValue)color {
    VkCommandBufferBeginInfo bi = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    p_vkBeginCommandBuffer(cmd, &bi);
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier toClear = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = range,
    };
    p_vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &toClear);
    p_vkCmdClearColorImage(cmd, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &color, 1, &range);
    VkImageMemoryBarrier toPresent = toClear;
    toPresent.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    toPresent.dstAccessMask = 0;
    toPresent.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    toPresent.newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    p_vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &toPresent);
    p_vkEndCommandBuffer(cmd);
}

- (BOOL)renderLoop {
    Uint64 start = p_SDL_GetTicksNS();
    int frames = 0, frame = 0, recreated = 0;
    double nextReport = 1, peak = 0;
    for (;;) {
        double t = (p_SDL_GetTicksNS() - start) / 1e9;
        if (t >= kTestSeconds) break;
        [self pollEvents];
        if (_resized) {
            if (![self recreateSwapchain:"window resized"]) return NO;
            recreated++;
        }
        // At most kFramesInFlight frames queued: wait for this slot's last submit.
        VkResult r = p_vkWaitForFences(_device, 1, &_fences[frame], VK_TRUE, 2000000000ull);
        if (![self check:r what:"vkWaitForFences (2 s)"]) return NO;
        uint32_t index = 0;
        r = p_vkAcquireNextImageKHR(_device, _swapchain, 2000000000ull, _acquired[frame], VK_NULL_HANDLE, &index);
        if (r == VK_ERROR_OUT_OF_DATE_KHR) {
            if (![self recreateSwapchain:"acquire: out of date"]) return NO;
            recreated++;
            continue;
        }
        if (r != VK_SUCCESS && r != VK_SUBOPTIMAL_KHR && ![self check:r what:"vkAcquireNextImageKHR"]) return NO;
        p_vkResetFences(_device, 1, &_fences[frame]);
        p_vkResetCommandBuffer(_cmdBufs[frame], 0);
        [self record:_cmdBufs[frame] image:_images[index] color:hueColor(fmod(t / kTestSeconds, 1))];
        VkPipelineStageFlags waitStage = VK_PIPELINE_STAGE_TRANSFER_BIT;
        VkSubmitInfo si = {
            .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &_acquired[frame],
            .pWaitDstStageMask = &waitStage,
            .commandBufferCount = 1,
            .pCommandBuffers = &_cmdBufs[frame],
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &_renderDone[index],
        };
        if (![self check:p_vkQueueSubmit(_queue, 1, &si, _fences[frame]) what:"vkQueueSubmit"]) return NO;
        VkPresentInfoKHR pi = {
            .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &_renderDone[index],
            .swapchainCount = 1,
            .pSwapchains = &_swapchain,
            .pImageIndices = &index,
        };
        r = p_vkQueuePresentKHR(_queue, &pi);
        frames++;
        frame = (frame + 1) % kFramesInFlight;
        if (r == VK_ERROR_OUT_OF_DATE_KHR || r == VK_SUBOPTIMAL_KHR) {
            if (![self recreateSwapchain:r == VK_SUBOPTIMAL_KHR ? "present: suboptimal" : "present: out of date"]) return NO;
            recreated++;
        } else if (![self check:r what:"vkQueuePresentKHR"]) {
            return NO;
        }
        double mb = footprintMB();
        peak = MAX(peak, mb);
        if (t >= nextReport) {
            [self log:@"t=%.1f s: %d frames presented, %ux%u, footprint %.1f MB", t, frames, _extent.width, _extent.height, mb];
            nextReport += 1;
        }
    }
    p_vkDeviceWaitIdle(_device);
    [self log:@"presented %d frames in %.1f s (%.1f fps), %d swapchain recreations, peak footprint %.1f MB",
              frames, kTestSeconds, frames / kTestSeconds, recreated, peak];
    if (frames == 0) return NO;
    [self log:@"VOXELIUM_SDL_VULKAN_OK (swapchain frames on SDL_Vulkan_CreateSurface)"];
    return YES;
}

- (void)teardown {
    if (_device) {
        p_vkDeviceWaitIdle(_device);
        for (int i = 0; i < kFramesInFlight; i++) {
            if (_fences[i]) p_vkDestroyFence(_device, _fences[i], NULL);
            if (_acquired[i]) p_vkDestroySemaphore(_device, _acquired[i], NULL);
        }
        for (uint32_t i = 0; i < _imageCount; i++) {
            if (_renderDone[i]) p_vkDestroySemaphore(_device, _renderDone[i], NULL);
        }
        if (_pool) p_vkDestroyCommandPool(_device, _pool, NULL);
        if (_swapchain) p_vkDestroySwapchainKHR(_device, _swapchain, NULL);
        p_vkDestroyDevice(_device, NULL);
        _device = VK_NULL_HANDLE;
    }
    if (_surface) p_SDL_Vulkan_DestroySurface(_instance, _surface, NULL);
    if (_instance) p_vkDestroyInstance(_instance, NULL);
    _surface = VK_NULL_HANDLE;
    _instance = VK_NULL_HANDLE;
    if (_window) {
        p_SDL_DestroyWindow(_window);
        _window = NULL;
        [self log:@"SDL_DestroyWindow ok"];
    }
    if (_vulkanLoaded) {
        p_SDL_Vulkan_UnloadLibrary();
        _vulkanLoaded = NO;
    }
    if (_sdl) {
        [self pollEvents]; // the window's last events
        p_SDL_Quit();
        [self log:@"SDL_Quit ok"];
        // libSDL3 stays loaded, as LWJGL leaves it (SDL_Init works again after SDL_Quit).
    }
}

#endif // VX_SDL_HEADERS

+ (BOOL)vulkanUsed {
    @synchronized(VXSDLVulkanTest.class) { return sVulkanUsed; }
}

@end
#endif
