// Compute-shader feasibility spike: desktop GL 4.3 through Mesa's Zink on a
// Vulkan driver bundled in Frameworks/zink. Everything is loaded with dlopen
// (RTLD_LOCAL, so Mesa's libEGL never meets ANGLE's) and runs off-screen on a
// background thread. Only the experimental IPA compiles this file's body.

#import "ZinkTest.h"
#if VOXELIUM_ZINK_EXPERIMENT
#include <dlfcn.h>
#include <mach/mach.h>
#include <time.h>

#define EGL_EGL_PROTOTYPES 0
#define GL_GLES_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl31.h>

// Desktop GL only (not in the GLES headers).
#define GL_CONTEXT_PROFILE_MASK 0x9126
#define GL_CONTEXT_CORE_PROFILE_BIT 0x00000001
#define GL_CONTEXT_COMPATIBILITY_PROFILE_BIT 0x00000002

static const int kSSBOCount = 1024;
static const int kDrawWidth = 1290, kDrawHeight = 2796, kDrawFrames = 300;

#pragma mark - Bundle lookup

static NSString *zinkDir(void) {
    return [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"zink"];
}

static NSString *eglMesaPath(void) {
    NSString *p = [zinkDir() stringByAppendingPathComponent:@"libEGL_mesa.dylib"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

/// KosmicKrisp if present, else MoltenVK.
static NSString *vulkanPath(NSString **name) {
    NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:zinkDir() error:nil] ?: @[];
    for (NSArray *c in @[@[@"libvulkan_kosmickrisp", @"KosmicKrisp"], @[@"libMoltenVK", @"MoltenVK"]]) {
        for (NSString *f in files) {
            if ([f hasPrefix:c[0]] && [f.pathExtension isEqualToString:@"dylib"]) {
                if (name) *name = c[1];
                return [zinkDir() stringByAppendingPathComponent:f];
            }
        }
    }
    return nil;
}

BOOL VXZinkBundled(void) { return eglMesaPath() != nil && vulkanPath(NULL) != nil; }

NSString *VXZinkVulkanDriverName(void) {
    NSString *name = nil;
    vulkanPath(&name);
    return name;
}

static double nowMs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static double footprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return -1;
    return info.phys_footprint / (1024.0 * 1024.0);
}

#pragma mark - Minimal Vulkan declarations (layouts as in vulkan_core.h)

typedef void *VXVkInstance;
typedef void *VXVkPhysicalDevice;
typedef int32_t VXVkResult;
typedef uint32_t VXVkBool32;
typedef void (*VXVkVoidFunction)(void);
typedef VXVkVoidFunction (*VXVkGetInstanceProcAddr)(VXVkInstance, const char *);

enum {
    VXVK_STRUCTURE_TYPE_APPLICATION_INFO = 0,
    VXVK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO = 1,
    VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2 = 1000059000,
    VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2 = 1000059001,
    VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES = 1000196000,
    VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT = 1000028000,
    VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT = 1000286000,
};

typedef struct {
    uint32_t sType;
    const void *pNext;
    const char *pApplicationName;
    uint32_t applicationVersion;
    const char *pEngineName;
    uint32_t engineVersion;
    uint32_t apiVersion;
} VXVkApplicationInfo;

typedef struct {
    uint32_t sType;
    const void *pNext;
    uint32_t flags;
    const VXVkApplicationInfo *pApplicationInfo;
    uint32_t enabledLayerCount;
    const char *const *ppEnabledLayerNames;
    uint32_t enabledExtensionCount;
    const char *const *ppEnabledExtensionNames;
} VXVkInstanceCreateInfo;

/// VkPhysicalDeviceProperties: only the leading fields are read; `rest`
/// (limits, sparse properties) is oversized so the driver never overruns it.
typedef struct {
    uint32_t apiVersion, driverVersion, vendorID, deviceID, deviceType;
    char deviceName[256];
    uint8_t pipelineCacheUUID[16];
    uint64_t rest[128];
} VXVkPhysicalDeviceProperties;

typedef struct {
    uint32_t sType;
    void *pNext;
    VXVkPhysicalDeviceProperties properties;
} VXVkPhysicalDeviceProperties2;

typedef struct {
    uint32_t sType;
    void *pNext;
    uint32_t driverID;
    char driverName[256];
    char driverInfo[256];
    uint8_t conformanceVersion[4];
} VXVkPhysicalDeviceDriverProperties;

/// VkPhysicalDeviceFeatures is 55 VkBool32s; geometryShader is [4],
/// tessellationShader [5].
typedef struct {
    uint32_t sType;
    void *pNext;
    VXVkBool32 features[55];
} VXVkPhysicalDeviceFeatures2;

typedef struct {
    uint32_t sType;
    void *pNext;
    VXVkBool32 transformFeedback, geometryStreams;
} VXVkPhysicalDeviceTransformFeedbackFeatures;

typedef struct {
    uint32_t sType;
    void *pNext;
    VXVkBool32 robustBufferAccess2, robustImageAccess2, nullDescriptor;
} VXVkPhysicalDeviceRobustness2Features;

typedef struct {
    char extensionName[256];
    uint32_t specVersion;
} VXVkExtensionProperties;

typedef VXVkResult (*VXPFN_vkEnumerateInstanceVersion)(uint32_t *);
typedef VXVkResult (*VXPFN_vkCreateInstance)(const VXVkInstanceCreateInfo *, const void *, VXVkInstance *);
typedef void (*VXPFN_vkDestroyInstance)(VXVkInstance, const void *);
typedef VXVkResult (*VXPFN_vkEnumeratePhysicalDevices)(VXVkInstance, uint32_t *, VXVkPhysicalDevice *);
typedef void (*VXPFN_vkGetPhysicalDeviceProperties)(VXVkPhysicalDevice, VXVkPhysicalDeviceProperties *);
typedef void (*VXPFN_vkGetPhysicalDeviceProperties2)(VXVkPhysicalDevice, VXVkPhysicalDeviceProperties2 *);
typedef void (*VXPFN_vkGetPhysicalDeviceFeatures2)(VXVkPhysicalDevice, VXVkPhysicalDeviceFeatures2 *);
typedef VXVkResult (*VXPFN_vkEnumerateDeviceExtensionProperties)(VXVkPhysicalDevice, const char *, uint32_t *, VXVkExtensionProperties *);

#define VXVK_VERSION_MAJOR(v) ((uint32_t)(v) >> 22U & 0x7FU)
#define VXVK_VERSION_MINOR(v) ((uint32_t)(v) >> 12U & 0x3FFU)
#define VXVK_VERSION_PATCH(v) ((uint32_t)(v) & 0xFFFU)
#define VXVK_MAKE_API_VERSION(major, minor) (((uint32_t)(major) << 22U) | ((uint32_t)(minor) << 12U))

#pragma mark - Test

static BOOL sUsed = NO;

@implementation VXZinkTest {
    NSMutableString *_report;
    void *_lib;
    EGLDisplay _dpy;
    EGLSurface _surface;
    EGLContext _ctx;
    int _glVersion;    // major * 10 + minor, from GL_VERSION
    int _glslVersion;  // e.g. 120 or 460, from GL_SHADING_LANGUAGE_VERSION

    PFNEGLGETPROCADDRESSPROC eglGetProcAddress_;
    PFNEGLGETERRORPROC eglGetError_;
    PFNGLGETERRORPROC glGetError_;
    PFNGLGETINTEGERVPROC glGetIntegerv_;
    PFNGLFINISHPROC glFinish_;
}

+ (BOOL)used {
    @synchronized(self) { return sUsed; }
}

- (void)log:(NSString *)fmt, ... NS_FORMAT_FUNCTION(1, 2) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[ZinkTest] %@", line);
    [_report appendFormat:@"%@\n", line];
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

- (void)logFootprint:(NSString *)when {
    [self log:@"phys_footprint %@: %.1f MB", when, footprintMB()];
}

- (void)start {
    _report = [NSMutableString string];
    BOOL first;
    @synchronized(VXZinkTest.class) {
        first = !sUsed;
        sUsed = YES;
    }
    if (!first) {
        [self log:@"Zink has already run in this launch; relaunch the app to run it again."];
        [self finish:NO];
        return;
    }
    // Mesa's shader compiler recurses deeply; the default 512 KB is too small.
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil];
    t.name = @"VoxeliumZinkTest";
    t.stackSize = 16 << 20;
    t.qualityOfService = NSQualityOfServiceUserInitiated;
    [t start];
}

- (void)run {
    @autoreleasepool {
        [self log:@"===== Zink test%@ %@", self.versionOverride ? @" (GL 4.6 override)" : @" (native version)",
                  [[NSISO8601DateFormatter new] stringFromDate:NSDate.date]];
        [self logFootprint:@"before init"];
        BOOL ok = [self runChecks];
        [self teardown];
        [self logFootprint:@"after teardown"];
        [NSThread sleepForTimeInterval:1.0];
        [self logFootprint:@"1 s after teardown"];
        [self finish:ok];
    }
}

- (BOOL)runChecks {
    NSString *vkName = nil;
    NSString *vk = vulkanPath(&vkName);
    NSString *egl = eglMesaPath();
    if (!vk || !egl) {
        [self log:@"Frameworks/zink is incomplete: libEGL_mesa.dylib %@, Vulkan driver %@",
                  egl ? @"found" : @"missing", vk ? vk.lastPathComponent : @"missing"];
        return NO;
    }
    [self log:@"Vulkan driver: %@ (%@)", vkName, vk.lastPathComponent];
    // KosmicKrisp needs Metal 4 and is built for iOS 26+; dlopen would fail anyway.
    NSOperatingSystemVersion os = NSProcessInfo.processInfo.operatingSystemVersion;
    if ([vkName isEqualToString:@"KosmicKrisp"] && os.majorVersion < 26) {
        [self log:@"KosmicKrisp needs iOS 26 (Metal 4); this is iOS %ld.%ld", (long)os.majorVersion, (long)os.minorVersion];
        return NO;
    }
    [self probeVulkan:vk];

    // GALLIUM_DRIVER alone fails ("DRI2: failed to create screen"); the loader
    // override is what selects Zink. LIBGL_ALWAYS_SOFTWARE would make Zink
    // demand a CPU Vulkan device.
    [self setEnv:"GALLIUM_DRIVER" value:@"zink"];
    [self setEnv:"MESA_LOADER_DRIVER_OVERRIDE" value:@"zink"];
    unsetenv("LIBGL_ALWAYS_SOFTWARE");
    [self setEnv:"ZINK_VULKAN_LIBRARY" value:vk];
    if (self.mesaLogPath) [self setEnv:"MESA_LOG_FILE" value:self.mesaLogPath];
    [self setEnv:"MESA_DEBUG" value:@"1"];
    // The default cache location (under $HOME) is not writable on iOS. One cache
    // per mode: a 2.1 context that finds the 4.6 run's #version 430 shader in a
    // shared cache reports it compiled and then crashes in glLinkProgram.
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    if (caches) {
        NSString *mode = self.versionOverride ? @"gl46override" : @"native";
        NSString *cache = [caches stringByAppendingPathComponent:[@"mesa_shader_cache_" stringByAppendingString:mode]];
        [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
        [self setEnv:"MESA_SHADER_CACHE_DIR" value:cache];
    }
    // Without the override Zink on Metal stops at GL 2.1 (no geometry shaders or
    // transform feedback), although compute and SSBOs are there.
    if (self.versionOverride) {
        [self setEnv:"MESA_GL_VERSION_OVERRIDE" value:@"4.6"];
        [self setEnv:"MESA_GLSL_VERSION_OVERRIDE" value:@"460"];
    } else {
        unsetenv("MESA_GL_VERSION_OVERRIDE");
        unsetenv("MESA_GLSL_VERSION_OVERRIDE");
    }

    double t0 = nowMs();
    if (![self setUpEGL:egl]) return NO;
    [self log:@"EGL + context ready in %.1f ms", nowMs() - t0];
    [self logFootprint:@"after context creation"];
    [self logCapabilities];

    BOOL computeOK = NO;
    // Below 4.3 the compute shader is not even compiled (see the cache note above).
    BOOL canCompute = _glVersion >= 43 && _glslVersion >= 430;
    if (canCompute) {
        computeOK = [self runCompute];
        [self logFootprint:@"after the dispatch"];
    } else {
        [self log:@"compute skipped: GL %d.%d, GLSL %d.%02d (use the GL 4.6 override)",
                  _glVersion / 10, _glVersion % 10, _glslVersion / 100, _glslVersion % 100];
    }
    BOOL drawOK = [self runDraw];
    [self logFootprint:@"after the frames"];
    if (!canCompute) {
        if (drawOK) [self log:@"VOXELIUM_ZINK_NATIVE_GL%d.%d_DRAW_OK (no compute at this version)", _glVersion / 10, _glVersion % 10];
        return drawOK;
    }
    return computeOK && drawOK;
}

- (void)setEnv:(const char *)name value:(NSString *)value {
    setenv(name, value.fileSystemRepresentation, 1);
    [self log:@"env %s=%@", name, value];
}

#pragma mark Vulkan probe

- (void)probeVulkan:(NSString *)path {
    void *vk = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!vk) {
        [self log:@"Vulkan probe: dlopen failed: %s", dlerror()];
        return;
    }
    // Mesa ICDs export vk_icdGetInstanceProcAddr; MoltenVK exports vkGetInstanceProcAddr.
    // The library stays loaded: Zink opens the same path next.
    const char *gipaName = "vkGetInstanceProcAddr";
    VXVkGetInstanceProcAddr gipa = (VXVkGetInstanceProcAddr)dlsym(vk, gipaName);
    if (!gipa) {
        gipaName = "vk_icdGetInstanceProcAddr";
        gipa = (VXVkGetInstanceProcAddr)dlsym(vk, gipaName);
    }
    if (!gipa) {
        [self log:@"Vulkan probe: no vkGetInstanceProcAddr or vk_icdGetInstanceProcAddr export"];
        return;
    }
    [self log:@"Vulkan probe: entry point %s", gipaName];

    uint32_t instanceVersion = VXVK_MAKE_API_VERSION(1, 0);
    VXPFN_vkEnumerateInstanceVersion enumVersion = (VXPFN_vkEnumerateInstanceVersion)gipa(NULL, "vkEnumerateInstanceVersion");
    if (enumVersion) enumVersion(&instanceVersion);
    [self log:@"Vulkan instance version %u.%u.%u", VXVK_VERSION_MAJOR(instanceVersion),
              VXVK_VERSION_MINOR(instanceVersion), VXVK_VERSION_PATCH(instanceVersion)];

    VXPFN_vkCreateInstance createInstance = (VXPFN_vkCreateInstance)gipa(NULL, "vkCreateInstance");
    if (!createInstance) {
        [self log:@"Vulkan probe: vkCreateInstance not found"];
        return;
    }
    VXVkApplicationInfo app = {
        .sType = VXVK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Voxelium Zink probe",
        .pEngineName = "Voxelium",
        .apiVersion = instanceVersion >= VXVK_MAKE_API_VERSION(1, 1) ? VXVK_MAKE_API_VERSION(1, 3) : VXVK_MAKE_API_VERSION(1, 0),
    };
    // Vulkan 1.0 instances need the extension for the *2 queries.
    const char *exts[] = {"VK_KHR_get_physical_device_properties2"};
    BOOL v10 = instanceVersion < VXVK_MAKE_API_VERSION(1, 1);
    VXVkInstanceCreateInfo ci = {
        .sType = VXVK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledExtensionCount = v10 ? 1 : 0,
        .ppEnabledExtensionNames = v10 ? exts : NULL,
    };
    VXVkInstance instance = NULL;
    double t0 = nowMs();
    VXVkResult r = createInstance(&ci, NULL, &instance);
    if (r != 0 || !instance) {
        [self log:@"vkCreateInstance failed: %d", r];
        return;
    }
    [self log:@"vkCreateInstance OK in %.1f ms", nowMs() - t0];

#define VK_FN(type, name) type name = (type)gipa(instance, #name)
    VK_FN(VXPFN_vkDestroyInstance, vkDestroyInstance);
    VK_FN(VXPFN_vkEnumeratePhysicalDevices, vkEnumeratePhysicalDevices);
    VK_FN(VXPFN_vkGetPhysicalDeviceProperties, vkGetPhysicalDeviceProperties);
    VK_FN(VXPFN_vkGetPhysicalDeviceProperties2, vkGetPhysicalDeviceProperties2);
    VK_FN(VXPFN_vkGetPhysicalDeviceFeatures2, vkGetPhysicalDeviceFeatures2);
    VK_FN(VXPFN_vkEnumerateDeviceExtensionProperties, vkEnumerateDeviceExtensionProperties);
#undef VK_FN
    if (!vkGetPhysicalDeviceProperties2) vkGetPhysicalDeviceProperties2 = (VXPFN_vkGetPhysicalDeviceProperties2)gipa(instance, "vkGetPhysicalDeviceProperties2KHR");
    if (!vkGetPhysicalDeviceFeatures2) vkGetPhysicalDeviceFeatures2 = (VXPFN_vkGetPhysicalDeviceFeatures2)gipa(instance, "vkGetPhysicalDeviceFeatures2KHR");

    uint32_t count = 0;
    VXVkPhysicalDevice devices[4] = {0};
    if (vkEnumeratePhysicalDevices) {
        vkEnumeratePhysicalDevices(instance, &count, NULL);
        if (count > 4) count = 4;
        vkEnumeratePhysicalDevices(instance, &count, devices);
    }
    [self log:@"Vulkan physical devices: %u", count];
    for (uint32_t i = 0; i < count; i++) {
        VXVkPhysicalDeviceDriverProperties driver = {.sType = VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES};
        VXVkPhysicalDeviceProperties2 props = {.sType = VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &driver};
        if (vkGetPhysicalDeviceProperties2) {
            vkGetPhysicalDeviceProperties2(devices[i], &props);
        } else if (vkGetPhysicalDeviceProperties) {
            vkGetPhysicalDeviceProperties(devices[i], &props.properties);
        }
        VXVkPhysicalDeviceProperties *p = &props.properties;
        [self log:@"[%u] %s apiVersion=%u.%u.%u driverID=%u driver=%s (%s) vendor=0x%X type=%u", i, p->deviceName,
                  VXVK_VERSION_MAJOR(p->apiVersion), VXVK_VERSION_MINOR(p->apiVersion), VXVK_VERSION_PATCH(p->apiVersion),
                  driver.driverID, driver.driverName, driver.driverInfo, p->vendorID, p->deviceType];

        BOOL hasTF = NO, hasRobust2 = NO;
        if (vkEnumerateDeviceExtensionProperties) {
            uint32_t n = 0;
            vkEnumerateDeviceExtensionProperties(devices[i], NULL, &n, NULL);
            VXVkExtensionProperties *ext = calloc(n ?: 1, sizeof(*ext));
            vkEnumerateDeviceExtensionProperties(devices[i], NULL, &n, ext);
            for (uint32_t e = 0; e < n; e++) {
                if (!strcmp(ext[e].extensionName, "VK_EXT_transform_feedback")) hasTF = YES;
                if (!strcmp(ext[e].extensionName, "VK_EXT_robustness2") || !strcmp(ext[e].extensionName, "VK_KHR_robustness2")) hasRobust2 = YES;
            }
            free(ext);
            [self log:@"[%u] %u device extensions; transform_feedback %@, robustness2 %@", i, n,
                      hasTF ? @"advertised" : @"absent", hasRobust2 ? @"advertised" : @"absent"];
        }
        if (vkGetPhysicalDeviceFeatures2) {
            VXVkPhysicalDeviceRobustness2Features robust = {.sType = VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT};
            VXVkPhysicalDeviceTransformFeedbackFeatures tf = {.sType = VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TRANSFORM_FEEDBACK_FEATURES_EXT};
            // Chain only structures whose extension the device advertises.
            void *chain = NULL;
            if (hasRobust2) { robust.pNext = chain; chain = &robust; }
            if (hasTF) { tf.pNext = chain; chain = &tf; }
            VXVkPhysicalDeviceFeatures2 f = {.sType = VXVK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = chain};
            vkGetPhysicalDeviceFeatures2(devices[i], &f);
            [self log:@"[%u] geometryShader=%u tessellationShader=%u transformFeedback=%u geometryStreams=%u "
                      @"robustBufferAccess2=%u robustImageAccess2=%u nullDescriptor=%u", i,
                      f.features[4], f.features[5], tf.transformFeedback, tf.geometryStreams,
                      robust.robustBufferAccess2, robust.robustImageAccess2, robust.nullDescriptor];
        }
    }
    if (vkDestroyInstance) vkDestroyInstance(instance, NULL);
}

#pragma mark EGL

- (void *)egl:(const char *)name {
    void *p = dlsym(_lib, name);
    if (!p && eglGetProcAddress_) p = (void *)eglGetProcAddress_(name);
    if (!p) [self log:@"missing EGL symbol %s", name];
    return p;
}

- (void *)gl:(const char *)name {
    void *p = (void *)eglGetProcAddress_(name);
    if (!p) [self log:@"missing GL symbol %s", name];
    return p;
}

- (BOOL)setUpEGL:(NSString *)path {
    _lib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!_lib) {
        [self log:@"dlopen(%@) failed: %s", path.lastPathComponent, dlerror()];
        return NO;
    }
    [self log:@"loaded zink/%@", path.lastPathComponent];

    eglGetProcAddress_ = (PFNEGLGETPROCADDRESSPROC)dlsym(_lib, "eglGetProcAddress");
    eglGetError_ = [self egl:"eglGetError"];
    // EGL 1.5's eglGetPlatformDisplay takes EGLAttrib*, the EXT one EGLint*; only NULL is passed.
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay = dlsym(_lib, "eglGetPlatformDisplay") ?: [self egl:"eglGetPlatformDisplayEXT"];
    PFNEGLINITIALIZEPROC initialize = [self egl:"eglInitialize"];
    PFNEGLQUERYSTRINGPROC queryString = [self egl:"eglQueryString"];
    PFNEGLBINDAPIPROC bindAPI = [self egl:"eglBindAPI"];
    PFNEGLCHOOSECONFIGPROC chooseConfig = [self egl:"eglChooseConfig"];
    PFNEGLCREATEPBUFFERSURFACEPROC createPbuffer = [self egl:"eglCreatePbufferSurface"];
    PFNEGLCREATECONTEXTPROC createContext = [self egl:"eglCreateContext"];
    PFNEGLMAKECURRENTPROC makeCurrent = [self egl:"eglMakeCurrent"];
    if (!eglGetProcAddress_ || !eglGetError_ || !getPlatformDisplay || !initialize || !queryString || !bindAPI ||
        !chooseConfig || !createPbuffer || !createContext || !makeCurrent) {
        return NO;
    }

    _dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint major = 0, minor = 0;
    if (_dpy == EGL_NO_DISPLAY || !initialize(_dpy, &major, &minor)) {
        [self log:@"eglInitialize (surfaceless) failed: 0x%X", eglGetError_()];
        _dpy = EGL_NO_DISPLAY;
        return NO;
    }
    [self log:@"EGL %d.%d vendor=%s version=%s", major, minor, queryString(_dpy, EGL_VENDOR), queryString(_dpy, EGL_VERSION)];
    [self log:@"EGL client APIs: %s", queryString(_dpy, EGL_CLIENT_APIS)];
    [self log:@"EGL extensions: %s", queryString(_dpy, EGL_EXTENSIONS)];

    if (!bindAPI(EGL_OPENGL_API)) {
        [self log:@"eglBindAPI(EGL_OPENGL_API) failed: 0x%X", eglGetError_()];
        return NO;
    }
    // No colour sizes: everything renders into FBOs, the pbuffer only makes the context current.
    EGLint configAttrs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_NONE,
    };
    EGLConfig config = NULL;
    EGLint count = 0;
    if (!chooseConfig(_dpy, configAttrs, &config, 1, &count) || count < 1) {
        [self log:@"eglChooseConfig found no desktop GL pbuffer config: 0x%X", eglGetError_()];
        return NO;
    }
    EGLint pbufferAttrs[] = {EGL_WIDTH, 1, EGL_HEIGHT, 1, EGL_NONE};
    _surface = createPbuffer(_dpy, config, pbufferAttrs);
    if (_surface == EGL_NO_SURFACE) {
        // Rendering goes to an FBO anyway, so a surfaceless context will do.
        [self log:@"eglCreatePbufferSurface failed (0x%X); trying EGL_KHR_surfaceless_context", eglGetError_()];
    }

    // 4.3 core first (compute shaders and SSBOs are core there), then older.
    const int versions[][2] = {{4, 3}, {4, 2}, {4, 1}, {4, 0}, {3, 3}, {3, 2}};
    for (size_t i = 0; i < sizeof(versions) / sizeof(versions[0]) && _ctx == EGL_NO_CONTEXT; i++) {
        EGLint attrs[] = {
            EGL_CONTEXT_MAJOR_VERSION, versions[i][0], EGL_CONTEXT_MINOR_VERSION, versions[i][1],
            EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT, EGL_NONE,
        };
        _ctx = createContext(_dpy, config, EGL_NO_CONTEXT, attrs);
        if (_ctx != EGL_NO_CONTEXT) [self log:@"created OpenGL %d.%d core context", versions[i][0], versions[i][1]];
        else [self log:@"OpenGL %d.%d core context refused: 0x%X", versions[i][0], versions[i][1], eglGetError_()];
    }
    if (_ctx == EGL_NO_CONTEXT) {
        // Without MESA_GL_VERSION_OVERRIDE every core request fails with
        // EGL_BAD_MATCH; the default context is then GL 2.1.
        EGLint attrs[] = {EGL_NONE};
        _ctx = createContext(_dpy, config, EGL_NO_CONTEXT, attrs);
        if (_ctx != EGL_NO_CONTEXT) [self log:@"created default (compatibility) OpenGL context"];
    }
    if (_ctx == EGL_NO_CONTEXT || !makeCurrent(_dpy, _surface, _surface, _ctx)) {
        [self log:@"context creation/makeCurrent failed: 0x%X", eglGetError_()];
        return NO;
    }

    glGetError_ = [self gl:"glGetError"];
    glGetIntegerv_ = [self gl:"glGetIntegerv"];
    glFinish_ = [self gl:"glFinish"];
    return glGetError_ && glGetIntegerv_ && glFinish_;
}

- (void)logCapabilities {
    PFNGLGETSTRINGPROC getString = [self gl:"glGetString"];
    PFNGLGETSTRINGIPROC getStringi = [self gl:"glGetStringi"];
    PFNGLGETINTEGERI_VPROC getIntegeri = [self gl:"glGetIntegeri_v"];
    if (!getString) return;
    [self log:@"GL_VENDOR=%s", getString(GL_VENDOR)];
    [self log:@"GL_RENDERER=%s", getString(GL_RENDERER)];
    [self log:@"GL_VERSION=%s", getString(GL_VERSION)];
    [self log:@"GL_SHADING_LANGUAGE_VERSION=%s", getString(GL_SHADING_LANGUAGE_VERSION)];

    // GL_MAJOR_VERSION and GL_NUM_EXTENSIONS are GL 3.0+, so parse the strings.
    int major = 0, minor = 0, glslMajor = 0, glslMinor = 0;
    GLint profile = 0;
    const char *version = (const char *)getString(GL_VERSION);
    const char *glsl = (const char *)getString(GL_SHADING_LANGUAGE_VERSION);
    if (version) sscanf(version, "%d.%d", &major, &minor);
    if (glsl) sscanf(glsl, "%d.%d", &glslMajor, &glslMinor);
    _glVersion = major * 10 + minor;
    _glslVersion = glslMajor * 100 + glslMinor;
    if (_glVersion >= 32) glGetIntegerv_(GL_CONTEXT_PROFILE_MASK, &profile);
    NSString *profileName = profile & GL_CONTEXT_CORE_PROFILE_BIT ? @"core"
                          : profile & GL_CONTEXT_COMPATIBILITY_PROFILE_BIT ? @"compatibility"
                          : _glVersion >= 32 ? [NSString stringWithFormat:@"unknown (0x%X)", profile] : @"none (pre-3.2)";
    [self log:@"context %d.%d, profile %@", major, minor, profileName];

    NSMutableSet<NSString *> *exts = [NSMutableSet set];
    if (_glVersion >= 30 && getStringi) {
        GLint n = 0;
        glGetIntegerv_(GL_NUM_EXTENSIONS, &n);
        for (GLint i = 0; i < n; i++) {
            const GLubyte *e = getStringi(GL_EXTENSIONS, (GLuint)i);
            if (e) [exts addObject:@((const char *)e)];
        }
    } else {
        const char *all = (const char *)getString(GL_EXTENSIONS);
        if (all) [exts addObjectsFromArray:[@(all) componentsSeparatedByString:@" "]];
        [exts removeObject:@""];
    }
    [self log:@"%lu extensions", (unsigned long)exts.count];
    for (NSString *e in @[@"GL_ARB_compute_shader", @"GL_ARB_shader_storage_buffer_object", @"GL_ARB_shader_image_load_store",
                          @"GL_ARB_geometry_shader4", @"GL_ARB_tessellation_shader", @"GL_ARB_transform_feedback3",
                          @"GL_ARB_multi_draw_indirect", @"GL_ARB_gpu_shader5"]) {
        [self log:@"%@: %@", e, [exts containsObject:e] ? @"yes" : @"no"];
    }
    if (getIntegeri) {
        GLint count[3] = {0}, size[3] = {0};
        for (GLuint i = 0; i < 3; i++) {
            getIntegeri(GL_MAX_COMPUTE_WORK_GROUP_COUNT, i, &count[i]);
            getIntegeri(GL_MAX_COMPUTE_WORK_GROUP_SIZE, i, &size[i]);
        }
        GLint invocations = 0;
        glGetIntegerv_(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, &invocations);
        [self log:@"GL_MAX_COMPUTE_WORK_GROUP_COUNT=(%d, %d, %d)", count[0], count[1], count[2]];
        [self log:@"GL_MAX_COMPUTE_WORK_GROUP_SIZE=(%d, %d, %d) invocations=%d", size[0], size[1], size[2], invocations];
    }
    GLenum err = glGetError_();
    if (err != GL_NO_ERROR) [self log:@"glGetError after queries: 0x%X (expected when compute is unsupported)", err];
}

#pragma mark Shaders

- (GLuint)compile:(GLenum)type source:(const char *)src {
    PFNGLCREATESHADERPROC createShader = [self gl:"glCreateShader"];
    PFNGLSHADERSOURCEPROC shaderSource = [self gl:"glShaderSource"];
    PFNGLCOMPILESHADERPROC compileShader = [self gl:"glCompileShader"];
    PFNGLGETSHADERIVPROC getShaderiv = [self gl:"glGetShaderiv"];
    PFNGLGETSHADERINFOLOGPROC getShaderInfoLog = [self gl:"glGetShaderInfoLog"];
    if (!createShader || !shaderSource || !compileShader || !getShaderiv || !getShaderInfoLog) return 0;
    GLuint s = createShader(type);
    shaderSource(s, 1, &src, NULL);
    compileShader(s);
    GLint ok = 0;
    getShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char info[2048] = {0};
        getShaderInfoLog(s, sizeof(info), NULL, info);
        [self log:@"shader compile failed: %s", info];
        return 0;
    }
    return s;
}

- (GLuint)link:(GLuint)a :(GLuint)b {
    PFNGLCREATEPROGRAMPROC createProgram = [self gl:"glCreateProgram"];
    PFNGLATTACHSHADERPROC attachShader = [self gl:"glAttachShader"];
    PFNGLLINKPROGRAMPROC linkProgram = [self gl:"glLinkProgram"];
    PFNGLGETPROGRAMIVPROC getProgramiv = [self gl:"glGetProgramiv"];
    PFNGLGETPROGRAMINFOLOGPROC getProgramInfoLog = [self gl:"glGetProgramInfoLog"];
    if (!createProgram || !attachShader || !linkProgram || !getProgramiv || !getProgramInfoLog) return 0;
    GLuint p = createProgram();
    attachShader(p, a);
    if (b) attachShader(p, b);
    PFNGLBINDATTRIBLOCATIONPROC bindAttribLocation = [self gl:"glBindAttribLocation"];
    if (bindAttribLocation) bindAttribLocation(p, 0, "pos");  // GLSL 1.20 has no layout(location)
    linkProgram(p);
    GLint linked = 0;
    getProgramiv(p, GL_LINK_STATUS, &linked);
    if (!linked) {
        char info[2048] = {0};
        getProgramInfoLog(p, sizeof(info), NULL, info);
        [self log:@"program link failed: %s", info];
        return 0;
    }
    return p;
}

#pragma mark Compute

- (BOOL)runCompute {
    PFNGLGENBUFFERSPROC genBuffers = [self gl:"glGenBuffers"];
    PFNGLBINDBUFFERPROC bindBuffer = [self gl:"glBindBuffer"];
    PFNGLBUFFERDATAPROC bufferData = [self gl:"glBufferData"];
    PFNGLBINDBUFFERBASEPROC bindBufferBase = [self gl:"glBindBufferBase"];
    PFNGLUSEPROGRAMPROC useProgram = [self gl:"glUseProgram"];
    PFNGLDISPATCHCOMPUTEPROC dispatchCompute = [self gl:"glDispatchCompute"];
    PFNGLMEMORYBARRIERPROC memoryBarrier = [self gl:"glMemoryBarrier"];
    PFNGLMAPBUFFERRANGEPROC mapBufferRange = [self gl:"glMapBufferRange"];
    PFNGLUNMAPBUFFERPROC unmapBuffer = [self gl:"glUnmapBuffer"];
    if (!genBuffers || !bindBuffer || !bufferData || !bindBufferBase || !useProgram || !dispatchCompute ||
        !memoryBarrier || !mapBufferRange || !unmapBuffer) {
        [self log:@"compute entry points missing; skipping the dispatch"];
        return NO;
    }
    const char *cs =
        "#version 430\n"
        "layout(local_size_x = 64) in;\n"
        "layout(std430, binding = 0) buffer Out { uint data[]; };\n"
        "void main() { uint i = gl_GlobalInvocationID.x; data[i] = i * 3u + 1u; }\n";
    double t0 = nowMs();
    GLuint s = [self compile:GL_COMPUTE_SHADER source:cs];
    GLuint program = s ? [self link:s :0] : 0;
    double compileMs = nowMs() - t0;
    if (!program) {
        [self log:@"compute shader unavailable (%.1f ms)", compileMs];
        return NO;
    }
    [self log:@"compute shader compiled and linked in %.1f ms", compileMs];

    // Fill with a sentinel so unwritten elements show up as mismatches.
    GLuint *init = malloc(kSSBOCount * sizeof(GLuint));
    memset(init, 0xFF, kSSBOCount * sizeof(GLuint));
    GLuint ssbo = 0;
    genBuffers(1, &ssbo);
    bindBuffer(GL_SHADER_STORAGE_BUFFER, ssbo);
    bufferData(GL_SHADER_STORAGE_BUFFER, kSSBOCount * sizeof(GLuint), init, GL_DYNAMIC_READ);
    free(init);
    bindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, ssbo);
    useProgram(program);

    t0 = nowMs();
    dispatchCompute(kSSBOCount / 64, 1, 1);
    memoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT | GL_BUFFER_UPDATE_BARRIER_BIT);
    glFinish_();
    double dispatchMs = nowMs() - t0;

    t0 = nowMs();
    const GLuint *data = mapBufferRange(GL_SHADER_STORAGE_BUFFER, 0, kSSBOCount * sizeof(GLuint), GL_MAP_READ_BIT);
    BOOL ok = data != NULL;
    if (!data) {
        [self log:@"glMapBufferRange failed: 0x%X", glGetError_()];
    } else {
        for (int i = 0; i < kSSBOCount; i++) {
            GLuint want = (GLuint)i * 3u + 1u;
            if (data[i] != want) {
                [self log:@"compute mismatch at [%d]: got %u (0x%08X), want %u", i, data[i], data[i], want];
                ok = NO;
                break;
            }
        }
        unmapBuffer(GL_SHADER_STORAGE_BUFFER);
    }
    double readMs = nowMs() - t0;
    GLenum err = glGetError_();
    [self log:@"dispatch(16,1,1) + barrier + finish %.2f ms, map/read-back %.2f ms, glError=0x%X", dispatchMs, readMs, err];
    useProgram(0);
    if (ok && err == GL_NO_ERROR) {
        [self log:@"VOXELIUM_ZINK_COMPUTE_OK"];
        return YES;
    }
    return NO;
}

#pragma mark Draw

- (BOOL)runDraw {
    PFNGLGENFRAMEBUFFERSPROC genFramebuffers = [self gl:"glGenFramebuffers"];
    PFNGLBINDFRAMEBUFFERPROC bindFramebuffer = [self gl:"glBindFramebuffer"];
    PFNGLGENRENDERBUFFERSPROC genRenderbuffers = [self gl:"glGenRenderbuffers"];
    PFNGLBINDRENDERBUFFERPROC bindRenderbuffer = [self gl:"glBindRenderbuffer"];
    PFNGLRENDERBUFFERSTORAGEPROC renderbufferStorage = [self gl:"glRenderbufferStorage"];
    PFNGLFRAMEBUFFERRENDERBUFFERPROC framebufferRenderbuffer = [self gl:"glFramebufferRenderbuffer"];
    PFNGLCHECKFRAMEBUFFERSTATUSPROC checkFramebufferStatus = [self gl:"glCheckFramebufferStatus"];
    PFNGLGENVERTEXARRAYSPROC genVertexArrays = [self gl:"glGenVertexArrays"];
    PFNGLBINDVERTEXARRAYPROC bindVertexArray = [self gl:"glBindVertexArray"];
    PFNGLUSEPROGRAMPROC useProgram = [self gl:"glUseProgram"];
    PFNGLGETUNIFORMLOCATIONPROC getUniformLocation = [self gl:"glGetUniformLocation"];
    PFNGLUNIFORM1FPROC uniform1f = [self gl:"glUniform1f"];
    PFNGLVIEWPORTPROC viewport = [self gl:"glViewport"];
    PFNGLCLEARCOLORPROC clearColor = [self gl:"glClearColor"];
    PFNGLCLEARPROC clear = [self gl:"glClear"];
    PFNGLDRAWARRAYSPROC drawArrays = [self gl:"glDrawArrays"];
    PFNGLGENBUFFERSPROC genBuffers = [self gl:"glGenBuffers"];
    PFNGLBINDBUFFERPROC bindBuffer = [self gl:"glBindBuffer"];
    PFNGLBUFFERDATAPROC bufferData = [self gl:"glBufferData"];
    PFNGLENABLEVERTEXATTRIBARRAYPROC enableAttrib = [self gl:"glEnableVertexAttribArray"];
    PFNGLVERTEXATTRIBPOINTERPROC attribPointer = [self gl:"glVertexAttribPointer"];
    PFNGLFLUSHPROC flush = [self gl:"glFlush"];
    PFNGLREADPIXELSPROC readPixels = [self gl:"glReadPixels"];
    if (!genFramebuffers || !bindFramebuffer || !genRenderbuffers || !bindRenderbuffer || !renderbufferStorage ||
        !framebufferRenderbuffer || !checkFramebufferStatus || !genBuffers || !bindBuffer || !bufferData ||
        !enableAttrib || !attribPointer || !useProgram ||
        !getUniformLocation || !uniform1f || !viewport || !clearColor || !clear || !drawArrays || !flush || !readPixels) {
        return NO;
    }

    // Full-screen quad. GLSL 1.20 when Zink runs at its native GL 2.1.
    BOOL modern = _glslVersion >= 330;
    const char *vs = modern
        ? "#version 330 core\n"
          "layout(location = 0) in vec2 pos;\n"
          "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n"
        : "#version 120\n"
          "attribute vec2 pos;\n"
          "void main() { gl_Position = vec4(pos, 0.0, 1.0); }\n";
    // Blue is 0.25 on the last frame (299).
    const char *fs = modern
        ? "#version 330 core\n"
          "uniform float frame;\n"
          "out vec4 color;\n"
          "void main() { color = vec4(gl_FragCoord.xy / vec2(1290.0, 2796.0), frame / 1196.0, 1.0); }\n"
        : "#version 120\n"
          "uniform float frame;\n"
          "void main() { gl_FragColor = vec4(gl_FragCoord.xy / vec2(1290.0, 2796.0), frame / 1196.0, 1.0); }\n";
    double t0 = nowMs();
    GLuint v = [self compile:GL_VERTEX_SHADER source:vs];
    GLuint f = [self compile:GL_FRAGMENT_SHADER source:fs];
    GLuint program = v && f ? [self link:v :f] : 0;
    if (!program) return NO;
    [self log:@"draw shaders compiled and linked in %.1f ms", nowMs() - t0];

    GLuint fbo = 0, rb = 0, vao = 0;
    genRenderbuffers(1, &rb);
    bindRenderbuffer(GL_RENDERBUFFER, rb);
    renderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, kDrawWidth, kDrawHeight);
    genFramebuffers(1, &fbo);
    bindFramebuffer(GL_FRAMEBUFFER, fbo);
    framebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    GLenum status = checkFramebufferStatus(GL_FRAMEBUFFER);
    if (status != GL_FRAMEBUFFER_COMPLETE) {
        [self log:@"FBO %dx%d incomplete: 0x%X", kDrawWidth, kDrawHeight, status];
        return NO;
    }
    // Core profile needs a VAO; GL 2.1 draws with the default one.
    if (modern && genVertexArrays && bindVertexArray) {
        genVertexArrays(1, &vao);
        bindVertexArray(vao);
    }
    const GLfloat quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    GLuint vbo = 0;
    genBuffers(1, &vbo);
    bindBuffer(GL_ARRAY_BUFFER, vbo);
    bufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    enableAttrib(0);
    attribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, NULL);
    useProgram(program);
    GLint frameLoc = getUniformLocation(program, "frame");
    viewport(0, 0, kDrawWidth, kDrawHeight);
    clearColor(0.0f, 0.0f, 0.0f, 1.0f);

    void (^frame)(int) = ^(int i) {
        clear(GL_COLOR_BUFFER_BIT);
        uniform1f(frameLoc, (GLfloat)i);
        drawArrays(GL_TRIANGLE_STRIP, 0, 4);
    };
    // Memory over time: the first run grew about 2 MB per frame. Three ways of
    // ending a frame show whether that is a leak or work queued without a wait.
    // 1. glFlush only (no swap, nothing ever waits for the GPU).
    double firstMs = 0;
    t0 = nowMs();
    for (int i = 0; i < kDrawFrames; i++) {
        frame(i);
        if (i == 0) {
            glFinish_();
            firstMs = nowMs() - t0;
            t0 = nowMs();
        } else {
            flush();
        }
        if ((i + 1) % 50 == 0) [self logFootprint:[NSString stringWithFormat:@"flush-only frame %d", i + 1]];
    }
    glFinish_();
    double restMs = nowMs() - t0;
    [self log:@"%dx%d full-screen quad: first frame %.2f ms, then %d frames %.1f ms (%.3f ms/frame, %.1f fps)",
              kDrawWidth, kDrawHeight, firstMs, kDrawFrames - 1, restMs,
              restMs / (kDrawFrames - 1), (kDrawFrames - 1) / (restMs / 1000.0)];
    [self logFootprint:@"after flush-only frames + glFinish"];

    // 2. glFinish every frame: the CPU waits for each frame.
    t0 = nowMs();
    for (int i = 0; i < kDrawFrames; i++) {
        frame(i);
        glFinish_();
        if ((i + 1) % 50 == 0) [self logFootprint:[NSString stringWithFormat:@"finish-each frame %d", i + 1]];
    }
    double finishMs = nowMs() - t0;
    [self log:@"finish-each: %d frames %.1f ms (%.3f ms/frame)", kDrawFrames, finishMs, finishMs / kDrawFrames];

    // 3. A fence per frame, waiting for the one two frames back, as swap
    //    throttling does in a game.
    PFNGLFENCESYNCPROC fenceSync = [self gl:"glFenceSync"];
    PFNGLCLIENTWAITSYNCPROC clientWaitSync = [self gl:"glClientWaitSync"];
    PFNGLDELETESYNCPROC deleteSync = [self gl:"glDeleteSync"];
    if (fenceSync && clientWaitSync && deleteSync) {
        GLsync fences[2] = {0};
        t0 = nowMs();
        for (int i = 0; i < kDrawFrames; i++) {
            frame(i);
            GLsync *slot = &fences[i % 2];
            if (*slot) {
                clientWaitSync(*slot, GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull);
                deleteSync(*slot);
            }
            *slot = fenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
            flush();
            if ((i + 1) % 50 == 0) [self logFootprint:[NSString stringWithFormat:@"fenced frame %d", i + 1]];
        }
        for (int k = 0; k < 2; k++) {
            if (fences[k]) {
                clientWaitSync(fences[k], GL_SYNC_FLUSH_COMMANDS_BIT, 1000000000ull);
                deleteSync(fences[k]);
            }
        }
        double fencedMs = nowMs() - t0;
        [self log:@"fenced (2 in flight): %d frames %.1f ms (%.3f ms/frame)", kDrawFrames, fencedMs, fencedMs / kDrawFrames];
    } else {
        [self log:@"glFenceSync unavailable; fenced frames skipped"];
    }
    glFinish_();

    GLubyte px[4] = {0};
    readPixels(kDrawWidth / 2, kDrawHeight / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
    GLenum err = glGetError_();
    // Expected at the centre: (0.5, 0.5, 0.25) -> about (128, 128, 64).
    BOOL ok = err == GL_NO_ERROR && abs(px[0] - 128) <= 3 && abs(px[1] - 128) <= 3 && abs(px[2] - 64) <= 3;
    [self log:@"read-back centre=(%d,%d,%d,%d) glError=0x%X %@", px[0], px[1], px[2], px[3], err, ok ? @"OK" : @"WRONG"];
    bindFramebuffer(GL_FRAMEBUFFER, 0);
    return ok;
}

#pragma mark Finish

- (void)teardown {
    if (_dpy == EGL_NO_DISPLAY) return;
    PFNEGLMAKECURRENTPROC makeCurrent = [self egl:"eglMakeCurrent"];
    PFNEGLDESTROYCONTEXTPROC destroyContext = [self egl:"eglDestroyContext"];
    PFNEGLDESTROYSURFACEPROC destroySurface = [self egl:"eglDestroySurface"];
    PFNEGLTERMINATEPROC terminate = [self egl:"eglTerminate"];
    [self log:@"tearing down EGL"];
    if (makeCurrent) makeCurrent(_dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (_ctx != EGL_NO_CONTEXT && destroyContext) destroyContext(_dpy, _ctx);
    if (_surface != EGL_NO_SURFACE && destroySurface) destroySurface(_dpy, _surface);
    if (terminate) terminate(_dpy);
    _dpy = EGL_NO_DISPLAY;
    [self log:@"EGL torn down"];
}

- (void)finish:(BOOL)ok {
    [self log:@"%@", ok ? @"VOXELIUM_ZINK_OK" : @"Zink test FAILED"];
    NSString *report = [_report copy];
    void (^done)(BOOL, NSString *) = self.onFinish;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (done) done(ok, report);
    });
}

@end

#pragma mark - Vulkan swapchain test (KosmicKrisp WSI, Minecraft 26.3 plan)

#import <QuartzCore/CAMetalLayer.h>
#include "VXVulkanSwapchain.h"

static NSString *vulkanShimPath(void) {
    NSString *p = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"vulkan/libvulkan.1.dylib"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

BOOL VXVulkanWSIBundled(void) { return vulkanShimPath() != nil; }

@interface VXVulkanLayerView : UIView
@end
@implementation VXVulkanLayerView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

@implementation VXVulkanSwapchainTestViewController {
    NSMutableString *_report;
    BOOL _started;
}

static void vxvkAppLog(void *ctx, const char *line) {
    VXVulkanSwapchainTestViewController *vc = (__bridge VXVulkanSwapchainTestViewController *)ctx;
    [vc appendLine:@(line)];
}

- (void)appendLine:(NSString *)line {
    NSLog(@"[VulkanSwapchain] %@", line);
    @synchronized (self) { [_report appendFormat:@"%@\n", line]; }
    if (!self.logPath) return;
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    if (!h) {
        [NSFileManager.defaultManager createFileAtPath:self.logPath contents:nil attributes:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    }
    [h seekToEndOfFile];
    [h writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

- (void)loadView {
    VXVulkanLayerView *v = [VXVulkanLayerView new];
    v.backgroundColor = UIColor.blackColor;
    v.contentScaleFactor = UIScreen.mainScreen.nativeScale;
    self.view = v;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started) return;
    _started = YES;
    _report = [NSMutableString string];
    [self appendLine:[NSString stringWithFormat:@"===== Vulkan swapchain test %@ (%@)",
                      [[NSISO8601DateFormatter new] stringFromDate:NSDate.date],
                      NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"]]];
    NSString *lib = vulkanShimPath();
    CAMetalLayer *layer = (CAMetalLayer *)self.view.layer;
    CGSize px = CGSizeMake(self.view.bounds.size.width * self.view.contentScaleFactor,
                           self.view.bounds.size.height * self.view.contentScaleFactor);
    __weak typeof(self) weakSelf = self;
    // From a background thread, as Java will drive Vulkan through SDL3 and LWJGL.
    [NSThread detachNewThreadWithBlock:^{
        __strong typeof(weakSelf) me = weakSelf;
        if (!me) return;
        int status = 1;
        if (!lib) {
            [me appendLine:@"VK_SWAPCHAIN_FAIL Frameworks/vulkan/libvulkan.1.dylib is not bundled"];
        } else if (!NSProcessInfo.processInfo.isiOSAppOnMac &&
                   ![NSProcessInfo.processInfo isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){26, 0, 0}]) {
            [me appendLine:@"VK_SWAPCHAIN_FAIL KosmicKrisp needs iOS 26 (Metal 4)"];
        } else {
            vxvk_logger L = {vxvkAppLog, (__bridge void *)me};
            status = vxvk_run_swapchain_test(lib.fileSystemRepresentation, (__bridge void *)layer,
                                             (uint32_t)px.width, (uint32_t)px.height, 5.0, &L);
        }
        NSString *report;
        @synchronized (me) { report = [me->_report copy]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (me.onFinish) me.onFinish(status == 0, report);
        });
    }];
}

@end

#endif
