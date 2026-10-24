// GLFW 3.4 C API for iOS, backing LWJGL's GLFW binding (Milestone 6 step 3d).
//
// LWJGL's org.lwjgl.glfw.GLFW resolves all 117 glfw* functions from the
// library named by -Dorg.lwjgl.glfw.libname. As in PojavLauncher/Amethyst, that
// library is this app's own executable, which exports the functions below.
//
// Model: one visible window = a full-screen UIWindow above the app with a
// CAMetalLayer view and an ANGLE EGL (OpenGL ES 3) context on it. Desktop GL
// comes from MobileGlues, which LWJGL loads as its OpenGL library. Further
// windows get offscreen pbuffer surfaces with shared contexts. UIKit work runs
// on the main thread; input is queued there and delivered to callbacks on the
// caller's thread in glfwPollEvents/glfwWaitEvents, as GLFW specifies.
//
// Platform is reported as GLFW_PLATFORM_NULL so nothing tries Cocoa/AppKit.
//
// Experimental builds only (VOXELIUM_ZINK_EXPERIMENT): with VOXELIUM_GL_BACKEND=zink
// the context comes from Mesa's EGL (Zink on KosmicKrisp, desktop GL 4.6) instead of
// ANGLE. Mesa has no iOS window surface, so the game draws into a pbuffer and each
// swap reads it back and draws it into the CAMetalLayer with Metal; see "Zink".

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <stdatomic.h>

#define _GLFW_BUILD_DLL  // GLFWAPI = default visibility
#define GLFW_INCLUDE_NONE
#include "glfw/GLFW/glfw3.h"

#define EGL_EGL_PROTOTYPES 0
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <EGL/eglext_angle.h>

#import "VXGLFW.h"
#import "JVMBridge.h"
#import "VXTouchControls.h"

#if VOXELIUM_ZINK_EXPERIMENT
#import <Metal/Metal.h>
#define GL_GLES_PROTOTYPES 0
#include <GLES3/gl3.h>
#endif

// Keep every API function in the executable's export trie even though nothing
// in the app calls them directly.
#define VXAPI __attribute__((used, visibility("default")))

#pragma mark - Errors

static GLFWerrorfun gErrorCallback;
static int gLastError;
static char gLastErrorDescription[512];

static void vxError(int code, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(gLastErrorDescription, sizeof(gLastErrorDescription), fmt, ap);
    va_end(ap);
    gLastError = code;
    NSLog(@"[VXGLFW] error 0x%X: %s", code, gLastErrorDescription);
    if (gErrorCallback) gErrorCallback(code, gLastErrorDescription);
}

#pragma mark - EGL (ANGLE)

static void *gEGLLib;
static EGLDisplay gDisplay = EGL_NO_DISPLAY;
static EGLConfig gWindowConfig, gPbufferConfig;
static PFNEGLGETPROCADDRESSPROC p_eglGetProcAddress;
static PFNEGLGETERRORPROC p_eglGetError;
static PFNEGLINITIALIZEPROC p_eglInitialize;
static PFNEGLTERMINATEPROC p_eglTerminate;
static PFNEGLBINDAPIPROC p_eglBindAPI;
static PFNEGLCHOOSECONFIGPROC p_eglChooseConfig;
static PFNEGLCREATEWINDOWSURFACEPROC p_eglCreateWindowSurface;
static PFNEGLCREATEPBUFFERSURFACEPROC p_eglCreatePbufferSurface;
static PFNEGLDESTROYSURFACEPROC p_eglDestroySurface;
static PFNEGLCREATECONTEXTPROC p_eglCreateContext;
static PFNEGLDESTROYCONTEXTPROC p_eglDestroyContext;
static PFNEGLMAKECURRENTPROC p_eglMakeCurrent;
static PFNEGLSWAPBUFFERSPROC p_eglSwapBuffers;
static PFNEGLSWAPINTERVALPROC p_eglSwapInterval;
static PFNEGLQUERYSURFACEPROC p_eglQuerySurface;

#if VOXELIUM_ZINK_EXPERIMENT
// VOXELIUM_GL_BACKEND=zink (set by the launcher): Mesa's EGL from $VOXELIUM_ZINK_DIR.
static BOOL gZink;
static BOOL vxLoadMesaEGL(void);
#endif

static BOOL vxLoadEGL(void) {
    if (gDisplay != EGL_NO_DISPLAY) return YES;
#if VOXELIUM_ZINK_EXPERIMENT
    const char *backend = getenv("VOXELIUM_GL_BACKEND");
    if (backend && !strcmp(backend, "zink")) return vxLoadMesaEGL();
#endif
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libEGL.framework/libEGL"];
    gEGLLib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!gEGLLib) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "cannot load ANGLE libEGL: %s", dlerror());
        return NO;
    }
#define L(name) p_##name = (__typeof__(p_##name))dlsym(gEGLLib, #name)
    L(eglGetProcAddress); L(eglGetError); L(eglInitialize); L(eglTerminate); L(eglBindAPI);
    L(eglChooseConfig); L(eglCreateWindowSurface); L(eglCreatePbufferSurface); L(eglDestroySurface);
    L(eglCreateContext); L(eglDestroyContext); L(eglMakeCurrent); L(eglSwapBuffers);
    L(eglSwapInterval); L(eglQuerySurface);
#undef L
    PFNEGLGETPLATFORMDISPLAYEXTPROC getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYEXTPROC)dlsym(gEGLLib, "eglGetPlatformDisplayEXT");
    if (!getPlatformDisplay || !p_eglInitialize || !p_eglCreateContext) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "ANGLE libEGL is missing entry points");
        return NO;
    }
    EGLint attrs[] = {EGL_PLATFORM_ANGLE_TYPE_ANGLE, EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, EGL_NONE};
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_ANGLE_ANGLE, EGL_DEFAULT_DISPLAY, attrs);
    if (dpy == EGL_NO_DISPLAY || !p_eglInitialize(dpy, NULL, NULL)) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "eglInitialize failed: 0x%X", p_eglGetError());
        return NO;
    }
    p_eglBindAPI(EGL_OPENGL_ES_API);
    EGLint count = 0;
    EGLint windowAttrs[] = {
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_NONE};
    EGLint pbufferAttrs[] = {
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
    if (!p_eglChooseConfig(dpy, windowAttrs, &gWindowConfig, 1, &count) || count < 1 ||
        !p_eglChooseConfig(dpy, pbufferAttrs, &gPbufferConfig, 1, &count) || count < 1) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "no suitable EGL config: 0x%X", p_eglGetError());
        p_eglTerminate(dpy);
        return NO;
    }
    gDisplay = dpy;
    return YES;
}

#if VOXELIUM_ZINK_EXPERIMENT
static void vxOnMain(dispatch_block_t block);

#ifndef EGL_PLATFORM_SURFACELESS_MESA
#define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
#endif

static BOOL vxLoadMesaEGL(void) {
    const char *dir = getenv("VOXELIUM_ZINK_DIR");
    NSString *path = [(dir ? @(dir) : [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"zink"])
                      stringByAppendingPathComponent:@"libEGL_mesa.dylib"];
    gEGLLib = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!gEGLLib) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "cannot load Mesa libEGL: %s", dlerror());
        return NO;
    }
#define L(name) p_##name = (__typeof__(p_##name))dlsym(gEGLLib, #name)
    L(eglGetProcAddress); L(eglGetError); L(eglInitialize); L(eglTerminate); L(eglBindAPI);
    L(eglChooseConfig); L(eglCreateWindowSurface); L(eglCreatePbufferSurface); L(eglDestroySurface);
    L(eglCreateContext); L(eglDestroyContext); L(eglMakeCurrent); L(eglSwapBuffers);
    L(eglSwapInterval); L(eglQuerySurface);
#undef L
    PFNEGLGETPLATFORMDISPLAYPROC getPlatformDisplay = (PFNEGLGETPLATFORMDISPLAYPROC)dlsym(gEGLLib, "eglGetPlatformDisplay");
    if (!getPlatformDisplay || !p_eglInitialize || !p_eglCreateContext) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "Mesa libEGL is missing entry points");
        return NO;
    }
    EGLDisplay dpy = getPlatformDisplay(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
    EGLint major = 0, minor = 0;
    if (dpy == EGL_NO_DISPLAY || !p_eglInitialize(dpy, &major, &minor)) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "Mesa eglInitialize failed: 0x%X", p_eglGetError ? p_eglGetError() : 0);
        return NO;
    }
    p_eglBindAPI(EGL_OPENGL_API);
    // Everything renders into pbuffers: the window's is read back at each swap.
    EGLint count = 0;
    EGLint attrs[] = {
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24, EGL_STENCIL_SIZE, 8,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT, EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_NONE};
    if (!p_eglChooseConfig(dpy, attrs, &gPbufferConfig, 1, &count) || count < 1) {
        vxError(GLFW_PLATFORM_UNAVAILABLE, "no suitable Mesa EGL config: 0x%X", p_eglGetError());
        p_eglTerminate(dpy);
        return NO;
    }
    gWindowConfig = gPbufferConfig;
    gDisplay = dpy;
    gZink = YES;
    NSLog(@"[VXGLFW] Zink: Mesa EGL %d.%d (surfaceless) from %@", major, minor, path);
    return YES;
}

// Presents a Zink window: at each swap the pbuffer (GL's default framebuffer) is
// read into one of two pixel-pack buffers, and the previous frame's buffer is
// waited for, copied into a Metal buffer and drawn into the CAMetalLayer. Waiting
// for the previous frame keeps at most two frames of GL work queued: with nothing
// waiting, Zink on KosmicKrisp queues GPU work (about 1.2 MB a frame) without
// limit (docs/COMPUTE_SHADERS_RESEARCH.md).
@interface VXZinkPresenter : NSObject {
@public
    int width, height, stride;
    GLuint pbo[2];
    GLsync fence[2];
    uint64_t frame;
}
@property (nonatomic, strong) CAMetalLayer *layer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> queue;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property (nonatomic, strong) NSArray<id<MTLBuffer>> *buffers;
@property (nonatomic, strong) NSArray<id<MTLTexture>> *textures;
@property (nonatomic, strong) dispatch_semaphore_t inFlight;
@end

@implementation VXZinkPresenter
@end

static struct {
    PFNGLGETINTEGERVPROC getIntegerv;
    PFNGLBINDFRAMEBUFFERPROC bindFramebuffer;
    PFNGLBINDBUFFERPROC bindBuffer;
    PFNGLGENBUFFERSPROC genBuffers;
    PFNGLDELETEBUFFERSPROC deleteBuffers;
    PFNGLBUFFERDATAPROC bufferData;
    PFNGLPIXELSTOREIPROC pixelStorei;
    PFNGLREADPIXELSPROC readPixels;
    PFNGLFENCESYNCPROC fenceSync;
    PFNGLCLIENTWAITSYNCPROC clientWaitSync;
    PFNGLDELETESYNCPROC deleteSync;
    PFNGLMAPBUFFERRANGEPROC mapBufferRange;
    PFNGLUNMAPBUFFERPROC unmapBuffer;
    PFNGLFLUSHPROC flush;
} gZinkGL;

static BOOL vxZinkLoadGL(void) {
    if (gZinkGL.readPixels) return YES;
#define G(field, name) gZinkGL.field = (__typeof__(gZinkGL.field))p_eglGetProcAddress(name)
    G(getIntegerv, "glGetIntegerv"); G(bindFramebuffer, "glBindFramebuffer"); G(bindBuffer, "glBindBuffer");
    G(genBuffers, "glGenBuffers"); G(deleteBuffers, "glDeleteBuffers"); G(bufferData, "glBufferData");
    G(pixelStorei, "glPixelStorei"); G(readPixels, "glReadPixels"); G(fenceSync, "glFenceSync");
    G(clientWaitSync, "glClientWaitSync"); G(deleteSync, "glDeleteSync"); G(mapBufferRange, "glMapBufferRange");
    G(unmapBuffer, "glUnmapBuffer"); G(flush, "glFlush");
#undef G
    return gZinkGL.readPixels && gZinkGL.mapBufferRange && gZinkGL.fenceSync;
}

static NSString *const kVXZinkShader =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct V { float4 p [[position]]; float2 uv; };\n"
     // One triangle covering the screen. GL rows run bottom-up and the texture's
     // row 0 is GL's bottom row, so uv = q puts GL's top row at the top.
     "vertex V vx(uint id [[vertex_id]]) {\n"
     "  float2 q = float2((id << 1) & 2, id & 2);\n"
     "  V v; v.p = float4(q * 2.0 - 1.0, 0.0, 1.0); v.uv = q; return v; }\n"
     "fragment float4 fx(V in [[stage_in]], texture2d<float> t [[texture(0)]]) {\n"
     "  constexpr sampler s(filter::nearest); return float4(t.sample(s, in.uv).rgb, 1.0); }\n";

static VXZinkPresenter *vxZinkPresenterCreate(CAMetalLayer *layer) {
    VXZinkPresenter *p = [VXZinkPresenter new];
    p.device = MTLCreateSystemDefaultDevice();
    p.queue = [p.device newCommandQueue];
    NSError *error = nil;
    id<MTLLibrary> lib = [p.device newLibraryWithSource:kVXZinkShader options:nil error:&error];
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"vx"];
    d.fragmentFunction = [lib newFunctionWithName:@"fx"];
    d.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    p.pipeline = lib ? [p.device newRenderPipelineStateWithDescriptor:d error:&error] : nil;
    if (!p.pipeline) {
        NSLog(@"[VXGLFW] Zink: Metal present pipeline failed: %@", error);
        return nil;
    }
    p.inFlight = dispatch_semaphore_create(3);
    p.layer = layer;
    vxOnMain(^{
        layer.device = p.device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.opaque = YES;
        layer.maximumDrawableCount = 3;
    });
    return p;
}

// Drops queued read-backs and reallocates everything for a new framebuffer size.
// Called with the window's context current.
static void vxZinkPresenterResize(VXZinkPresenter *p, int width, int height) {
    for (int i = 0; i < 2; i++) {
        if (p->fence[i]) { gZinkGL.deleteSync(p->fence[i]); p->fence[i] = NULL; }
    }
    if (p->pbo[0]) gZinkGL.deleteBuffers(2, p->pbo);
    p->width = width;
    p->height = height;
    NSUInteger align = [p.device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
    p->stride = (int)(((NSUInteger)width * 4 + align - 1) / align * align);
    size_t size = (size_t)p->stride * height;
    GLint oldPack = 0;
    gZinkGL.getIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &oldPack);
    gZinkGL.genBuffers(2, p->pbo);
    for (int i = 0; i < 2; i++) {
        gZinkGL.bindBuffer(GL_PIXEL_PACK_BUFFER, p->pbo[i]);
        gZinkGL.bufferData(GL_PIXEL_PACK_BUFFER, (GLsizeiptr)size, NULL, GL_STREAM_READ);
    }
    gZinkGL.bindBuffer(GL_PIXEL_PACK_BUFFER, (GLuint)oldPack);
    // Wait out frames Metal still draws from the old buffers.
    for (int i = 0; i < 3; i++) dispatch_semaphore_wait(p.inFlight, DISPATCH_TIME_FOREVER);
    NSMutableArray *buffers = [NSMutableArray array], *textures = [NSMutableArray array];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:width height:height mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    for (int i = 0; i < 3; i++) {
        id<MTLBuffer> b = [p.device newBufferWithLength:size options:MTLResourceStorageModeShared];
        [buffers addObject:b];
        [textures addObject:[b newTextureWithDescriptor:td offset:0 bytesPerRow:(NSUInteger)p->stride]];
    }
    p.buffers = buffers;
    p.textures = textures;
    for (int i = 0; i < 3; i++) dispatch_semaphore_signal(p.inFlight);
    CAMetalLayer *layer = p.layer;
    vxOnMain(^{ layer.drawableSize = CGSizeMake(width, height); });
    p->frame = 0;
    NSLog(@"[VXGLFW] Zink: presenting %dx%d (row stride %d bytes)", width, height, p->stride);
}

// Shows a mapped read-back (bottom-up BGRA rows, p->stride apart) on the layer.
static void vxZinkShow(VXZinkPresenter *p, const void *pixels) {
    dispatch_semaphore_wait(p.inFlight, DISPATCH_TIME_FOREVER);
    NSUInteger slot = (NSUInteger)(p->frame % 3);
    memcpy(p.buffers[slot].contents, pixels, (size_t)p->stride * p->height);
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [p.layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(p.inFlight);
            return;
        }
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> cb = [p.queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:p.pipeline];
        [enc setFragmentTexture:p.textures[slot] atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [enc endEncoding];
        [cb presentDrawable:drawable];
        dispatch_semaphore_t sem = p.inFlight;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { dispatch_semaphore_signal(sem); }];
        [cb commit];
    }
}

// One swap: queue this frame's read-back, then wait for the previous one and show it.
static void vxZinkPresent(VXZinkPresenter *p) {
    GLint readFB = 0, pack = 0, align = 0, rowLength = 0, skipRows = 0, skipPixels = 0;
    gZinkGL.getIntegerv(GL_READ_FRAMEBUFFER_BINDING, &readFB);
    gZinkGL.getIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
    gZinkGL.getIntegerv(GL_PACK_ALIGNMENT, &align);
    gZinkGL.getIntegerv(GL_PACK_ROW_LENGTH, &rowLength);
    gZinkGL.getIntegerv(GL_PACK_SKIP_ROWS, &skipRows);
    gZinkGL.getIntegerv(GL_PACK_SKIP_PIXELS, &skipPixels);

    int cur = (int)(p->frame % 2), prev = 1 - cur;
    gZinkGL.bindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    gZinkGL.bindBuffer(GL_PIXEL_PACK_BUFFER, p->pbo[cur]);
    gZinkGL.pixelStorei(GL_PACK_ALIGNMENT, 4);
    gZinkGL.pixelStorei(GL_PACK_ROW_LENGTH, p->stride / 4);
    gZinkGL.pixelStorei(GL_PACK_SKIP_ROWS, 0);
    gZinkGL.pixelStorei(GL_PACK_SKIP_PIXELS, 0);
    gZinkGL.readPixels(0, 0, p->width, p->height, 0x80E1 /* GL_BGRA */, GL_UNSIGNED_BYTE, NULL);
    p->fence[cur] = gZinkGL.fenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    gZinkGL.flush();

    if (p->fence[prev]) {
        gZinkGL.clientWaitSync(p->fence[prev], GL_SYNC_FLUSH_COMMANDS_BIT, 2000000000ull);
        gZinkGL.deleteSync(p->fence[prev]);
        p->fence[prev] = NULL;
        gZinkGL.bindBuffer(GL_PIXEL_PACK_BUFFER, p->pbo[prev]);
        const void *pixels = gZinkGL.mapBufferRange(GL_PIXEL_PACK_BUFFER, 0, (GLsizeiptr)p->stride * p->height, GL_MAP_READ_BIT);
        if (pixels) {
            vxZinkShow(p, pixels);
            gZinkGL.unmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
    }
    p->frame++;

    gZinkGL.bindBuffer(GL_PIXEL_PACK_BUFFER, (GLuint)pack);
    gZinkGL.bindFramebuffer(GL_READ_FRAMEBUFFER, (GLuint)readFB);
    gZinkGL.pixelStorei(GL_PACK_ALIGNMENT, align);
    gZinkGL.pixelStorei(GL_PACK_ROW_LENGTH, rowLength);
    gZinkGL.pixelStorei(GL_PACK_SKIP_ROWS, skipRows);
    gZinkGL.pixelStorei(GL_PACK_SKIP_PIXELS, skipPixels);
}
#endif

#pragma mark - Main-thread helper

static void vxOnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) block();
    else dispatch_sync(dispatch_get_main_queue(), block);
}

#pragma mark - Events

typedef enum {
    VXEventCursorPos, VXEventMouseButton, VXEventScroll, VXEventKey, VXEventChar,
    VXEventFramebufferSize, VXEventWindowSize, VXEventClose, VXEventFocus,
} VXEventType;

typedef struct {
    VXEventType type;
    void *window;   // GLFWwindow *
    double x, y;    // cursor / scroll
    int a, b, c, d; // button/key, action, mods, scancode or codepoint
} VXEvent;

static pthread_mutex_t gEventLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gEventCond = PTHREAD_COND_INITIALIZER;
static VXEvent *gEvents;
static size_t gEventCount, gEventCapacity;
static BOOL gEmptyEventPosted;

static void vxPush(VXEvent e) {
    pthread_mutex_lock(&gEventLock);
    if (gEventCount == gEventCapacity) {
        gEventCapacity = gEventCapacity ? gEventCapacity * 2 : 256;
        gEvents = realloc(gEvents, gEventCapacity * sizeof(VXEvent));
    }
    gEvents[gEventCount++] = e;
    pthread_cond_signal(&gEventCond);
    pthread_mutex_unlock(&gEventLock);
}

#pragma mark - Window object

@class VXGLFWView;

@interface VXGLFWWindowObj : NSObject <VXInputSink> {
@public
    int width, height;          // window size, points
    int fbWidth, fbHeight;      // framebuffer size, pixels
    float scale;
    BOOL shouldClose, visible, focused, offscreen;
    void *userPointer;
    int cursorMode, stickyKeys, stickyMouse, lockKeyMods, rawMotion;
    double cursorX, cursorY;
    char keys[GLFW_KEY_LAST + 1];
    char buttons[GLFW_MOUSE_BUTTON_LAST + 1];
    int hintMajor, hintMinor, hintProfile, hintForward, hintClientAPI;
    EGLSurface surface;
    EGLContext context;
    GLFWwindowposfun posCB; GLFWwindowsizefun sizeCB; GLFWwindowclosefun closeCB;
    GLFWwindowrefreshfun refreshCB; GLFWwindowfocusfun focusCB; GLFWwindowiconifyfun iconifyCB;
    GLFWwindowmaximizefun maximizeCB; GLFWframebuffersizefun fbCB; GLFWwindowcontentscalefun scaleCB;
    GLFWkeyfun keyCB; GLFWcharfun charCB; GLFWcharmodsfun charModsCB; GLFWmousebuttonfun mouseCB;
    GLFWcursorposfun cursorCB; GLFWcursorenterfun enterCB; GLFWscrollfun scrollCB; GLFWdropfun dropCB;
}
@property (nonatomic, strong) UIWindow *uiWindow;
@property (nonatomic, strong) VXGLFWView *view;
@property (nonatomic, copy) NSString *title;
#if VOXELIUM_ZINK_EXPERIMENT
// Zink: the on-screen window's pbuffer is shown through this (nil otherwise).
@property (nonatomic, strong) VXZinkPresenter *zink;
#endif
@end


static NSMutableArray<VXGLFWWindowObj *> *gWindows;
static VXGLFWWindowObj *gVisibleWindow;
static __thread VXGLFWWindowObj *__unsafe_unretained tCurrent;

static inline VXGLFWWindowObj *W(GLFWwindow *w) { return (__bridge VXGLFWWindowObj *)(void *)w; }
static inline GLFWwindow *H(VXGLFWWindowObj *w) { return (GLFWwindow *)(__bridge void *)w; }

#pragma mark - Keyboard mapping (USB HID usage -> GLFW key)

static int vxKeyFromHID(long usage) {
    if (usage >= 0x04 && usage <= 0x1D) return GLFW_KEY_A + (int)(usage - 0x04);
    if (usage >= 0x1E && usage <= 0x26) return GLFW_KEY_1 + (int)(usage - 0x1E);
    if (usage >= 0x3A && usage <= 0x45) return GLFW_KEY_F1 + (int)(usage - 0x3A);
    if (usage >= 0x59 && usage <= 0x61) return GLFW_KEY_KP_1 + (int)(usage - 0x59);
    switch (usage) {
        case 0x27: return GLFW_KEY_0;          case 0x28: return GLFW_KEY_ENTER;
        case 0x29: return GLFW_KEY_ESCAPE;     case 0x2A: return GLFW_KEY_BACKSPACE;
        case 0x2B: return GLFW_KEY_TAB;        case 0x2C: return GLFW_KEY_SPACE;
        case 0x2D: return GLFW_KEY_MINUS;      case 0x2E: return GLFW_KEY_EQUAL;
        case 0x2F: return GLFW_KEY_LEFT_BRACKET; case 0x30: return GLFW_KEY_RIGHT_BRACKET;
        case 0x31: return GLFW_KEY_BACKSLASH;  case 0x33: return GLFW_KEY_SEMICOLON;
        case 0x34: return GLFW_KEY_APOSTROPHE; case 0x35: return GLFW_KEY_GRAVE_ACCENT;
        case 0x36: return GLFW_KEY_COMMA;      case 0x37: return GLFW_KEY_PERIOD;
        case 0x38: return GLFW_KEY_SLASH;      case 0x39: return GLFW_KEY_CAPS_LOCK;
        case 0x46: return GLFW_KEY_PRINT_SCREEN; case 0x47: return GLFW_KEY_SCROLL_LOCK;
        case 0x48: return GLFW_KEY_PAUSE;      case 0x49: return GLFW_KEY_INSERT;
        case 0x4A: return GLFW_KEY_HOME;       case 0x4B: return GLFW_KEY_PAGE_UP;
        case 0x4C: return GLFW_KEY_DELETE;     case 0x4D: return GLFW_KEY_END;
        case 0x4E: return GLFW_KEY_PAGE_DOWN;  case 0x4F: return GLFW_KEY_RIGHT;
        case 0x50: return GLFW_KEY_LEFT;       case 0x51: return GLFW_KEY_DOWN;
        case 0x52: return GLFW_KEY_UP;         case 0x53: return GLFW_KEY_NUM_LOCK;
        case 0x54: return GLFW_KEY_KP_DIVIDE;  case 0x55: return GLFW_KEY_KP_MULTIPLY;
        case 0x56: return GLFW_KEY_KP_SUBTRACT; case 0x57: return GLFW_KEY_KP_ADD;
        case 0x58: return GLFW_KEY_KP_ENTER;   case 0x62: return GLFW_KEY_KP_0;
        case 0x63: return GLFW_KEY_KP_DECIMAL;
        case 0xE0: return GLFW_KEY_LEFT_CONTROL; case 0xE1: return GLFW_KEY_LEFT_SHIFT;
        case 0xE2: return GLFW_KEY_LEFT_ALT;   case 0xE3: return GLFW_KEY_LEFT_SUPER;
        case 0xE4: return GLFW_KEY_RIGHT_CONTROL; case 0xE5: return GLFW_KEY_RIGHT_SHIFT;
        case 0xE6: return GLFW_KEY_RIGHT_ALT;  case 0xE7: return GLFW_KEY_RIGHT_SUPER;
        default: return GLFW_KEY_UNKNOWN;
    }
}

static int vxMods(UIKeyModifierFlags f) {
    int m = 0;
    if (f & UIKeyModifierShift) m |= GLFW_MOD_SHIFT;
    if (f & UIKeyModifierControl) m |= GLFW_MOD_CONTROL;
    if (f & UIKeyModifierAlternate) m |= GLFW_MOD_ALT;
    if (f & UIKeyModifierCommand) m |= GLFW_MOD_SUPER;
    if (f & UIKeyModifierAlphaShift) m |= GLFW_MOD_CAPS_LOCK;
    if (f & UIKeyModifierNumericPad) m |= GLFW_MOD_NUM_LOCK;
    return m;
}

#pragma mark - Input helpers (UI thread -> event queue)

static void vxSendKey(VXGLFWWindowObj *w, int key, int action) {
    if (!w) return;
    vxPush((VXEvent){.type = VXEventKey, .window = H(w), .a = key, .b = action, .c = 0, .d = glfwGetKeyScancode(key)});
}

static void vxSendButton(VXGLFWWindowObj *w, int button, int action) {
    if (!w) return;
    vxPush((VXEvent){.type = VXEventMouseButton, .window = H(w), .a = button, .b = action});
}

static void vxSendScroll(VXGLFWWindowObj *w, double dy) {
    if (!w) return;
    vxPush((VXEvent){.type = VXEventScroll, .window = H(w), .x = 0, .y = dy});
}

static void vxSendChar(VXGLFWWindowObj *w, UTF32Char cp) {
    if (!w || cp < 32 || cp == 127) return;
    vxPush((VXEvent){.type = VXEventChar, .window = H(w), .a = (int)cp});
}

// The on-screen controls (VXTouchControls.m) send their input to the window.
@implementation VXGLFWWindowObj
- (void)vxKey:(int)key action:(int)action { vxSendKey(self, key, action); }
- (void)vxMouseButton:(int)button action:(int)action { vxSendButton(self, button, action); }
- (void)vxChar:(UInt32)codepoint { vxSendChar(self, codepoint); }
- (void)vxCursorAt:(CGPoint)p { vxPush((VXEvent){.type = VXEventCursorPos, .window = H(self), .x = p.x, .y = p.y}); }
// Captured cursor (mouse look): relative motion, encoded as a = 1 with the delta in x/y.
- (void)vxCursorDelta:(CGPoint)d { vxPush((VXEvent){.type = VXEventCursorPos, .window = H(self), .x = d.x, .y = d.y, .a = 1}); }
- (void)vxQuit { vxPush((VXEvent){.type = VXEventClose, .window = H(self)}); }
- (BOOL)vxInGame { return cursorMode == GLFW_CURSOR_DISABLED; }
- (CGSize)vxFramebufferSize { return CGSizeMake(fbWidth, fbHeight); }
- (CGFloat)vxPixelsPerPoint { return scale; }
@end


#pragma mark - Game view (touch + hardware keyboard)

// The CAMetalLayer view the game draws on. Touch gestures and the controls come
// from VXTouchView; this adds the hardware keyboard and size changes.
@interface VXGLFWView : VXTouchView
@property (nonatomic, weak) VXGLFWWindowObj *owner;
@end

@implementation VXGLFWView

+ (Class)layerClass { return CAMetalLayer.class; }

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)handlePresses:(NSSet<UIPress *> *)presses action:(int)action {
    VXGLFWWindowObj *w = self.owner;
    if (!w) return;
    for (UIPress *press in presses) {
        UIKey *key = press.key;
        if (!key) continue;
        int glfwKey = vxKeyFromHID(key.keyCode);
        int mods = vxMods(key.modifierFlags);
        vxPush((VXEvent){.type = VXEventKey, .window = H(w), .a = glfwKey, .b = action, .c = mods, .d = (int)key.keyCode});
        if (action == GLFW_PRESS && !(key.modifierFlags & (UIKeyModifierControl | UIKeyModifierCommand))) {
            NSString *chars = key.characters;
            [chars enumerateSubstringsInRange:NSMakeRange(0, chars.length)
                                      options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *s, NSRange r, NSRange er, BOOL *stop) {
                UTF32Char cp = 0;
                if ([s getBytes:&cp maxLength:sizeof(cp) usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding
                        options:0 range:NSMakeRange(0, s.length) remainingRange:NULL] && cp >= 32 && cp != 127) {
                    vxPush((VXEvent){.type = VXEventChar, .window = H(w), .a = (int)cp, .c = mods});
                }
            }];
        }
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self handlePresses:presses action:GLFW_PRESS]; }
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self handlePresses:presses action:GLFW_RELEASE]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self handlePresses:presses action:GLFW_RELEASE]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    VXGLFWWindowObj *w = self.owner;
    if (!w) return;
    CGSize s = self.bounds.size;
    int pw = (int)lround(s.width * w->scale), ph = (int)lround(s.height * w->scale);
    if ((int)s.width != w->width || (int)s.height != w->height) {
        vxPush((VXEvent){.type = VXEventWindowSize, .window = H(w), .a = (int)s.width, .b = (int)s.height});
    }
    if (pw != w->fbWidth || ph != w->fbHeight) {
        vxPush((VXEvent){.type = VXEventFramebufferSize, .window = H(w), .a = pw, .b = ph});
    }
}

@end

@interface VXGLFWViewController : UIViewController
@property (nonatomic, strong) VXGLFWView *glView;
@end

@implementation VXGLFWViewController
- (void)loadView { self.view = self.glView; }
// Minecraft is a landscape game.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.glView becomeFirstResponder];
}
@end

#pragma mark - Init / terminate / version / errors

static BOOL gInitialized;
static uint64_t gTimerBase;
static double gTimerOffset;
static mach_timebase_info_data_t gTimebase;
static GLFWmonitorfun gMonitorCallback;
static GLFWjoystickfun gJoystickCallback;
static void *gMonitorUserPointer;
struct GLFWmonitor { int unused; };
static struct GLFWmonitor gMonitor;
static GLFWmonitor *gMonitorList[1] = {&gMonitor};
static GLFWvidmode gVideoMode;
static int gHints[0x40000];  // indexed by (hint - 0x20000); only touched for known hints
static NSString *gClipboard;
static char *gClipboardC;

static void vxResetHints(void);

VXAPI int glfwInit(void) {
    if (gInitialized) return GLFW_TRUE;
    if (!vxLoadEGL()) return GLFW_FALSE;
    mach_timebase_info(&gTimebase);
    gTimerBase = mach_absolute_time();
    gTimerOffset = 0;
    gWindows = [NSMutableArray array];
    __block CGSize px;
    __block int fps;
    vxOnMain(^{
        UIScreen *screen = UIScreen.mainScreen;
        CGSize n = screen.nativeBounds.size;  // portrait pixels
        px = CGSizeMake(MAX(n.width, n.height), MIN(n.width, n.height));  // report landscape
        fps = (int)screen.maximumFramesPerSecond;
    });
    gVideoMode = (GLFWvidmode){.width = (int)px.width, .height = (int)px.height,
                               .redBits = 8, .greenBits = 8, .blueBits = 8, .refreshRate = fps};
    vxResetHints();
    gInitialized = YES;
#if VOXELIUM_ZINK_EXPERIMENT
    const char *displayKind = gZink ? "Mesa Zink (surfaceless)" : "ANGLE Metal";
#else
    const char *displayKind = "ANGLE Metal";
#endif
    NSLog(@"[VXGLFW] initialised: %s display, screen %dx%d @%d Hz", displayKind, gVideoMode.width, gVideoMode.height, fps);
    return GLFW_TRUE;
}

VXAPI void glfwTerminate(void) {
    if (!gInitialized) return;
    for (VXGLFWWindowObj *w in [gWindows copy]) glfwDestroyWindow(H(w));
    gInitialized = NO;
}

VXAPI void glfwInitHint(int hint, int value) {}
VXAPI void glfwInitAllocator(const GLFWallocator *allocator) {}

VXAPI void glfwGetVersion(int *major, int *minor, int *rev) {
    if (major) *major = GLFW_VERSION_MAJOR;
    if (minor) *minor = GLFW_VERSION_MINOR;
    if (rev) *rev = GLFW_VERSION_REVISION;
}

VXAPI const char *glfwGetVersionString(void) { return "3.4.0 Voxelium (UIKit + ANGLE/EGL)"; }

VXAPI int glfwGetError(const char **description) {
    int code = gLastError;
    if (description) *description = code ? gLastErrorDescription : NULL;
    gLastError = GLFW_NO_ERROR;
    return code;
}

VXAPI GLFWerrorfun glfwSetErrorCallback(GLFWerrorfun callback) {
    GLFWerrorfun prev = gErrorCallback;
    gErrorCallback = callback;
    return prev;
}

VXAPI int glfwGetPlatform(void) { return GLFW_PLATFORM_NULL; }
VXAPI int glfwPlatformSupported(int platform) { return platform == GLFW_PLATFORM_NULL; }

#pragma mark - Monitors

VXAPI GLFWmonitor **glfwGetMonitors(int *count) {
    if (count) *count = 1;
    return gMonitorList;
}
VXAPI GLFWmonitor *glfwGetPrimaryMonitor(void) { return &gMonitor; }
VXAPI void glfwGetMonitorPos(GLFWmonitor *m, int *x, int *y) { if (x) *x = 0; if (y) *y = 0; }
VXAPI void glfwGetMonitorWorkarea(GLFWmonitor *m, int *x, int *y, int *w, int *h) {
    if (x) *x = 0;
    if (y) *y = 0;
    if (w) *w = gVideoMode.width;
    if (h) *h = gVideoMode.height;
}
VXAPI void glfwGetMonitorPhysicalSize(GLFWmonitor *m, int *wmm, int *hmm) {
    // ~460 ppi class panel; only used for DPI heuristics.
    if (wmm) *wmm = (int)lround(gVideoMode.width / 460.0 * 25.4);
    if (hmm) *hmm = (int)lround(gVideoMode.height / 460.0 * 25.4);
}
VXAPI void glfwGetMonitorContentScale(GLFWmonitor *m, float *xs, float *ys) {
    __block float s;
    vxOnMain(^{ s = (float)UIScreen.mainScreen.nativeScale; });
    if (xs) *xs = s;
    if (ys) *ys = s;
}
VXAPI const char *glfwGetMonitorName(GLFWmonitor *m) { return "iPhone Display"; }
VXAPI void glfwSetMonitorUserPointer(GLFWmonitor *m, void *p) { gMonitorUserPointer = p; }
VXAPI void *glfwGetMonitorUserPointer(GLFWmonitor *m) { return gMonitorUserPointer; }
VXAPI GLFWmonitorfun glfwSetMonitorCallback(GLFWmonitorfun cb) {
    GLFWmonitorfun prev = gMonitorCallback;
    gMonitorCallback = cb;
    return prev;
}
VXAPI const GLFWvidmode *glfwGetVideoModes(GLFWmonitor *m, int *count) {
    if (count) *count = 1;
    return &gVideoMode;
}
VXAPI const GLFWvidmode *glfwGetVideoMode(GLFWmonitor *m) { return &gVideoMode; }
VXAPI void glfwSetGamma(GLFWmonitor *m, float gamma) {}
VXAPI const GLFWgammaramp *glfwGetGammaRamp(GLFWmonitor *m) {
    vxError(GLFW_FEATURE_UNAVAILABLE, "gamma ramps are not available on iOS");
    return NULL;
}
VXAPI void glfwSetGammaRamp(GLFWmonitor *m, const GLFWgammaramp *ramp) {}

#pragma mark - Window hints

#define HINT(h) gHints[(h) - 0x20000]

static void vxResetHints(void) {
    memset(gHints, 0, sizeof(gHints));
    HINT(GLFW_VISIBLE) = GLFW_TRUE;
    HINT(GLFW_FOCUSED) = GLFW_TRUE;
    HINT(GLFW_CLIENT_API) = GLFW_OPENGL_API;
    HINT(GLFW_CONTEXT_VERSION_MAJOR) = 1;
    HINT(GLFW_CONTEXT_VERSION_MINOR) = 0;
    HINT(GLFW_OPENGL_PROFILE) = GLFW_OPENGL_ANY_PROFILE;
}

VXAPI void glfwDefaultWindowHints(void) { vxResetHints(); }

VXAPI void glfwWindowHint(int hint, int value) {
    if (hint >= 0x20000 && hint < 0x20000 + (int)(sizeof(gHints) / sizeof(gHints[0]))) HINT(hint) = value;
}

VXAPI void glfwWindowHintString(int hint, const char *value) {}

#pragma mark - Windows

static EGLContext vxCreateContext(VXGLFWWindowObj *w, EGLContext share) {
#if VOXELIUM_ZINK_EXPERIMENT
    if (gZink) {
        // Desktop GL core. Mesa gives the highest version it supports for a core
        // request (4.6 with MESA_GL_VERSION_OVERRIDE=4.6), so ask for the game's.
        p_eglBindAPI(EGL_OPENGL_API);
        int major = w->hintMajor >= 3 ? w->hintMajor : 3, minor = w->hintMajor >= 3 ? w->hintMinor : 2;
        if (major == 3 && minor < 2) minor = 2;
        EGLint flags = w->hintForward ? EGL_CONTEXT_OPENGL_FORWARD_COMPATIBLE_BIT_KHR : 0;
        EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, major, EGL_CONTEXT_MINOR_VERSION, minor,
                          EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
                          EGL_CONTEXT_FLAGS_KHR, flags, EGL_NONE};
        EGLContext c = p_eglCreateContext(gDisplay, gWindowConfig, share, attrs);
        if (c == EGL_NO_CONTEXT)
            NSLog(@"[VXGLFW] Zink: GL %d.%d core context refused: 0x%X (MESA_GL_VERSION_OVERRIDE=%s)",
                  major, minor, p_eglGetError(), getenv("MESA_GL_VERSION_OVERRIDE") ?: "unset");
        return c;
    }
#endif
    for (int minor = 2; minor >= 0; minor--) {
        EGLint attrs[] = {EGL_CONTEXT_MAJOR_VERSION, 3, EGL_CONTEXT_MINOR_VERSION, minor, EGL_NONE};
        EGLContext c = p_eglCreateContext(gDisplay, gWindowConfig, share, attrs);
        if (c != EGL_NO_CONTEXT) return c;
    }
    return EGL_NO_CONTEXT;
}

// App lifecycle → game. Leaving the app (home gesture, app switcher, lock) should
// not lose the world when iOS later kills the process (swipe-away gives 5 s):
//  - resign active: report focus lost and, when the cursor is captured (in game, no
//    screen open), press ESC. Minecraft opens its pause menu, and the integrated
//    server saves the world as it pauses ("Saving and pausing game...").
//    The app is still running while inactive, so this is processed right away.
//  - enter background: hold a background task for a few seconds so that save can finish.
//  - become active: report focus regained (the pause menu stays open).
// While in the background the render thread waits in glfwSwapBuffers: iOS refuses GPU
// work from background apps, and a failed Metal command buffer made Minecraft crash
// ("Can't map buffer") after the app was swiped away on the title screen. The
// integrated server keeps saving meanwhile (it does not render).
static UIBackgroundTaskIdentifier gBackgroundTask;
static atomic_bool gInBackground;
static BOOL gHasBackgroundTask;

static void vxEndBackgroundTask(void) {
    if (!gHasBackgroundTask) return;
    gHasBackgroundTask = NO;
    [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
}

// Memory as iOS sees it: the app's footprint (what jetsam limits) and how much more it
// may use before being killed. Logged every 10 s while the game draws and on memory
// warnings, so a run that ends without a crash report shows whether memory ran out.
static void vxLogMemory(const char *why) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0, graphics = 0, remaining = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        footprint = info.phys_footprint;
        // GPU (Metal/IOSurface) memory charged to the app, and what iOS says is left
        // before the per-process limit (iOS 26: 3376 MB here, "ActiveHard").
        if (count >= TASK_VM_INFO_REV5_COUNT) {
            graphics = (uint64_t)info.ledger_tag_graphics_footprint;
            remaining = info.limit_bytes_remaining;
        }
    }
    static uint64_t lowestAvailable = UINT64_MAX, peakFootprint = 0;
    uint64_t available = os_proc_available_memory();
    if (available < lowestAvailable) lowestAvailable = available;
    if (footprint > peakFootprint) peakFootprint = footprint;
    NSLog(@"[VXMEM] %s: footprint %llu MB (peak %llu MB; GPU %llu MB, rest %llu MB), iOS allows %llu MB more "
          @"(lowest %llu MB, limit remaining %llu MB)", why, footprint >> 20, peakFootprint >> 20, graphics >> 20,
          (footprint - MIN(graphics, footprint)) >> 20, available >> 20, lowestAvailable >> 20, remaining >> 20);
}

static void vxInstallLifecycleObservers(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        NSOperationQueue *main = NSOperationQueue.mainQueue;
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            VXGLFWWindowObj *w = gVisibleWindow;
            if (!w) return;
            vxPush((VXEvent){.type = VXEventFocus, .window = H(w), .a = GLFW_FALSE});
            BOOL inGame = w->cursorMode == GLFW_CURSOR_DISABLED;
            if (inGame) {
                vxSendKey(w, GLFW_KEY_ESCAPE, GLFW_PRESS);
                vxSendKey(w, GLFW_KEY_ESCAPE, GLFW_RELEASE);
            }
            NSLog(@"[VXGLFW] app resigning active: focus lost%s", inGame ? ", sent ESC to pause and save" : "");
        }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            if (!gVisibleWindow || gHasBackgroundTask) return;
            gBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Minecraft save"
                                                                        expirationHandler:^{ vxEndBackgroundTask(); }];
            gHasBackgroundTask = gBackgroundTask != UIBackgroundTaskInvalid;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ vxEndBackgroundTask(); });
            NSLog(@"[VXGLFW] app in background: holding a background task for 8 s");
        }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            atomic_store(&gInBackground, true);
        }];
        [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            atomic_store(&gInBackground, false);
        }];
        [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            vxLogMemory("iOS memory warning");
            VXJVMRequestGC("iOS memory warning");
            static uint64_t lastNotice;
            uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
            if (gVisibleWindow && now - lastNotice > 60ull * NSEC_PER_SEC) {   // at most once a minute
                lastNotice = now;
                NSLog(@"[VXMEM] showing the low-memory notice in game");
                [gVisibleWindow.view.overlay showNotice:@"Memory is almost full. Lower the render distance "
                                                        @"(Options → Video Settings) to avoid a crash."];
            }
        }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
            vxEndBackgroundTask();
            VXGLFWWindowObj *w = gVisibleWindow;
            if (!w) return;
            vxPush((VXEvent){.type = VXEventFocus, .window = H(w), .a = GLFW_TRUE});
            NSLog(@"[VXGLFW] app active again: focus regained");
        }];
    });
}

VXAPI GLFWwindow *glfwCreateWindow(int width, int height, const char *title, GLFWmonitor *monitor, GLFWwindow *share) {
    if (!gInitialized) {
        vxError(GLFW_NOT_INITIALIZED, "glfwCreateWindow before glfwInit");
        return NULL;
    }
    VXGLFWWindowObj *w = [VXGLFWWindowObj new];
    w.title = title ? @(title) : @"";
    w->hintMajor = HINT(GLFW_CONTEXT_VERSION_MAJOR);
    w->hintMinor = HINT(GLFW_CONTEXT_VERSION_MINOR);
    w->hintProfile = HINT(GLFW_OPENGL_PROFILE);
    w->hintForward = HINT(GLFW_OPENGL_FORWARD_COMPAT);
    w->hintClientAPI = HINT(GLFW_CLIENT_API);
    w->cursorMode = GLFW_CURSOR_NORMAL;
    w->focused = YES;
    // Only one on-screen window; others (e.g. hidden helper contexts) are offscreen.
    // The first window is the game's full-screen window even when created hidden:
    // Minecraft 26.2 creates it with GLFW_VISIBLE = 0 and calls glfwShowWindow only
    // later, in the Minecraft constructor; treating it as offscreen left the game
    // running (sound) behind the launcher with nothing on screen. It is shown at
    // once, so the later glfwShowWindow changes nothing. Further windows are offscreen.
    w->offscreen = gVisibleWindow != nil;

    if (w->offscreen) {
        w->width = MAX(width, 1);
        w->height = MAX(height, 1);
        w->fbWidth = w->width;
        w->fbHeight = w->height;
        w->scale = 1;
        EGLint attrs[] = {EGL_WIDTH, w->fbWidth, EGL_HEIGHT, w->fbHeight, EGL_NONE};
        w->surface = p_eglCreatePbufferSurface(gDisplay, gPbufferConfig, attrs);
    } else {
        __block EGLSurface surface = EGL_NO_SURFACE;
        vxOnMain(^{
            UIWindowScene *scene = nil;
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
            }
            VXGLFWView *view = [[VXGLFWView alloc] initWithFrame:UIScreen.mainScreen.bounds];
            view.owner = w;
            view.sink = w;
            view.multipleTouchEnabled = YES;
            VXControlsOverlay *overlay = [[VXControlsOverlay alloc] initWithOwner:w];
            overlay.gameView = view;
            overlay.multipleTouchEnabled = YES;
            view.overlay = overlay;
            [view addSubview:overlay];
            view.backgroundColor = UIColor.blackColor;
            // Render-resolution scale: VOXELIUM_RENDER_SCALE (default 1.0 = native pixels).
            const char *rs = getenv("VOXELIUM_RENDER_SCALE");
            double renderScale = rs ? atof(rs) : 1.0;
            if (renderScale <= 0.1 || renderScale > 1.0) renderScale = 1.0;
            w->scale = (float)(UIScreen.mainScreen.nativeScale * renderScale);
            view.contentScaleFactor = w->scale;
            VXGLFWViewController *vc = [VXGLFWViewController new];
            vc.glView = view;
            UIWindow *uiWindow = scene ? [[UIWindow alloc] initWithWindowScene:scene]
                                       : [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            uiWindow.rootViewController = vc;
            uiWindow.windowLevel = UIWindowLevelNormal + 1;
            [uiWindow makeKeyAndVisible];
            if (@available(iOS 16.0, *)) {
                [vc setNeedsUpdateOfSupportedInterfaceOrientations];
                if (scene) {
                    UIWindowSceneGeometryPreferencesIOS *prefs =
                        [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscape];
                    [scene requestGeometryUpdateWithPreferences:prefs errorHandler:^(NSError *error) {
                        NSLog(@"[VXGLFW] landscape request failed: %@", error);
                    }];
                }
            }
            [uiWindow layoutIfNeeded];
            w.uiWindow = uiWindow;
            w.view = view;
            CGSize s = view.bounds.size;
            w->width = (int)s.width;
            w->height = (int)s.height;
            w->fbWidth = (int)lround(s.width * w->scale);
            w->fbHeight = (int)lround(s.height * w->scale);
#if VOXELIUM_ZINK_EXPERIMENT
            if (gZink) {
                // No window surfaces in Mesa here: a pbuffer of the framebuffer size,
                // shown on the layer at each swap (vxZinkPresent).
                EGLint pb[] = {EGL_WIDTH, w->fbWidth, EGL_HEIGHT, w->fbHeight, EGL_NONE};
                surface = p_eglCreatePbufferSurface(gDisplay, gPbufferConfig, pb);
                return;
            }
#endif
            surface = p_eglCreateWindowSurface(gDisplay, gWindowConfig, (__bridge EGLNativeWindowType)view.layer, NULL);
        });
        w->surface = surface;
        w->visible = YES;
        gVisibleWindow = w;
        vxInstallLifecycleObservers();
    }
    if (w->surface == EGL_NO_SURFACE) {
        vxError(GLFW_PLATFORM_ERROR, "EGL surface creation failed: 0x%X", p_eglGetError());
        if (gVisibleWindow == w) gVisibleWindow = nil;
        vxOnMain(^{ w.uiWindow.hidden = YES; });
        return NULL;
    }
    w->context = vxCreateContext(w, share ? W(share)->context : EGL_NO_CONTEXT);
    if (w->context == EGL_NO_CONTEXT) {
        vxError(GLFW_VERSION_UNAVAILABLE, "EGL context creation failed: 0x%X", p_eglGetError());
        p_eglDestroySurface(gDisplay, w->surface);
        if (gVisibleWindow == w) gVisibleWindow = nil;
        vxOnMain(^{ w.uiWindow.hidden = YES; });
        return NULL;
    }
#if VOXELIUM_ZINK_EXPERIMENT
    if (gZink && !w->offscreen) {
        w.zink = vxZinkPresenterCreate((CAMetalLayer *)w.view.layer);
        if (!w.zink) {
            vxError(GLFW_PLATFORM_ERROR, "Zink: cannot set up Metal presentation");
            p_eglDestroyContext(gDisplay, w->context);
            p_eglDestroySurface(gDisplay, w->surface);
            if (gVisibleWindow == w) gVisibleWindow = nil;
            vxOnMain(^{ w.uiWindow.hidden = YES; });
            return NULL;
        }
    }
#endif
    EGLint ew = 0, eh = 0;
    p_eglQuerySurface(gDisplay, w->surface, EGL_WIDTH, &ew);
    p_eglQuerySurface(gDisplay, w->surface, EGL_HEIGHT, &eh);
    if (ew > 0 && eh > 0) { w->fbWidth = ew; w->fbHeight = eh; }
    [gWindows addObject:w];
    NSLog(@"[VXGLFW] window \"%@\" %s: %dx%d pt, framebuffer %dx%d px (requested %dx%d, GL %d.%d profile 0x%X)",
          w.title, w->offscreen ? "offscreen" : "on-screen", w->width, w->height, w->fbWidth, w->fbHeight,
          width, height, w->hintMajor, w->hintMinor, w->hintProfile);
    return H(w);
}

VXAPI void glfwDestroyWindow(GLFWwindow *window) {
    if (!window) return;
    VXGLFWWindowObj *w = W(window);
    if (tCurrent == w) {
        p_eglMakeCurrent(gDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        tCurrent = nil;
    }
#if VOXELIUM_ZINK_EXPERIMENT
    if (w.zink) {
        // Let Metal finish with the frames it still shows; the GL objects go with the
        // context. Signal back after waiting: libdispatch traps when a semaphore is
        // released below its initial value (crash on quitting the game, 2026-10-22).
        dispatch_semaphore_t sem = w.zink.inFlight;
        for (int i = 0; i < 3; i++) dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        for (int i = 0; i < 3; i++) dispatch_semaphore_signal(sem);
        w.zink = nil;
    }
#endif
    if (w->context) p_eglDestroyContext(gDisplay, w->context);
    if (w->surface) p_eglDestroySurface(gDisplay, w->surface);
    w->context = EGL_NO_CONTEXT;
    w->surface = EGL_NO_SURFACE;
    if (gVisibleWindow == w) gVisibleWindow = nil;
    if (!w->offscreen) {
        NSLog(@"[VXGLFW] touches: %@", VXTouchStats());
    }
    vxOnMain(^{
        w.view.owner = nil;
        w.view.sink = nil;
        w.uiWindow.hidden = YES;
        w.uiWindow.rootViewController = nil;
        w.uiWindow = nil;
    });
    // Drop queued events for this window.
    pthread_mutex_lock(&gEventLock);
    size_t j = 0;
    for (size_t i = 0; i < gEventCount; i++) if (gEvents[i].window != window) gEvents[j++] = gEvents[i];
    gEventCount = j;
    pthread_mutex_unlock(&gEventLock);
    [gWindows removeObject:w];
}

VXAPI int glfwWindowShouldClose(GLFWwindow *window) { return window && W(window)->shouldClose; }
VXAPI void glfwSetWindowShouldClose(GLFWwindow *window, int value) { if (window) W(window)->shouldClose = value != 0; }
VXAPI void glfwSetWindowTitle(GLFWwindow *window, const char *title) { if (window && title) W(window).title = @(title); }
// GLFW 3.4; required by LWJGL 3.4.1 (Minecraft 26.x). UTF-8, valid until the title changes.
VXAPI const char *glfwGetWindowTitle(GLFWwindow *window) { return window ? W(window).title.UTF8String : NULL; }

// IME preedit API (GLFW's IME branch; LWJGL 3.4.1 binds these as optional and
// Minecraft 26.x calls glfwSetPreeditCallback during start-up, which fails with a
// NullPointerException when the function is missing). Text input on iOS goes through
// VXKeyboardProxy as plain char events, so there is never preedit text: the setters
// keep the callback (and return the previous one, as GLFW does) but never call it.
static void *gPreeditCB, *gIMEStatusCB, *gPreeditCandidateCB;
static int gPreeditRect[4];
VXAPI void *glfwSetPreeditCallback(GLFWwindow *window, void *cb) { void *p = gPreeditCB; gPreeditCB = cb; return p; }
VXAPI void *glfwSetIMEStatusCallback(GLFWwindow *window, void *cb) { void *p = gIMEStatusCB; gIMEStatusCB = cb; return p; }
VXAPI void *glfwSetPreeditCandidateCallback(GLFWwindow *window, void *cb) { void *p = gPreeditCandidateCB; gPreeditCandidateCB = cb; return p; }
VXAPI void glfwResetPreeditText(GLFWwindow *window) {}
VXAPI void glfwGetPreeditCursorRectangle(GLFWwindow *window, int *x, int *y, int *w, int *h) {
    if (x) *x = gPreeditRect[0];
    if (y) *y = gPreeditRect[1];
    if (w) *w = gPreeditRect[2];
    if (h) *h = gPreeditRect[3];
}
VXAPI void glfwSetPreeditCursorRectangle(GLFWwindow *window, int x, int y, int w, int h) {
    gPreeditRect[0] = x; gPreeditRect[1] = y; gPreeditRect[2] = w; gPreeditRect[3] = h;
}
VXAPI unsigned int *glfwGetPreeditCandidate(GLFWwindow *window, int index, int *textCount) {
    if (textCount) *textCount = 0;
    return NULL;
}
VXAPI void glfwSetWindowIcon(GLFWwindow *window, int count, const GLFWimage *images) {}
VXAPI void glfwGetWindowPos(GLFWwindow *window, int *x, int *y) { if (x) *x = 0; if (y) *y = 0; }
VXAPI void glfwSetWindowPos(GLFWwindow *window, int x, int y) {}
VXAPI void glfwGetWindowSize(GLFWwindow *window, int *width, int *height) {
    if (width) *width = window ? W(window)->width : 0;
    if (height) *height = window ? W(window)->height : 0;
}
VXAPI void glfwSetWindowSizeLimits(GLFWwindow *window, int minw, int minh, int maxw, int maxh) {}
VXAPI void glfwSetWindowAspectRatio(GLFWwindow *window, int numer, int denom) {}
VXAPI void glfwSetWindowSize(GLFWwindow *window, int width, int height) {}  // always full screen
VXAPI void glfwGetFramebufferSize(GLFWwindow *window, int *width, int *height) {
    if (width) *width = window ? W(window)->fbWidth : 0;
    if (height) *height = window ? W(window)->fbHeight : 0;
}
VXAPI void glfwGetWindowFrameSize(GLFWwindow *window, int *l, int *t, int *r, int *b) {
    if (l) *l = 0; if (t) *t = 0; if (r) *r = 0; if (b) *b = 0;
}
VXAPI void glfwGetWindowContentScale(GLFWwindow *window, float *xs, float *ys) {
    float s = window ? W(window)->scale : 1;
    if (xs) *xs = s;
    if (ys) *ys = s;
}
VXAPI float glfwGetWindowOpacity(GLFWwindow *window) { return 1.0f; }
VXAPI void glfwSetWindowOpacity(GLFWwindow *window, float opacity) {}
VXAPI void glfwIconifyWindow(GLFWwindow *window) {}
VXAPI void glfwRestoreWindow(GLFWwindow *window) {}
VXAPI void glfwMaximizeWindow(GLFWwindow *window) {}
VXAPI void glfwShowWindow(GLFWwindow *window) {
    if (!window || W(window)->offscreen) return;
    VXGLFWWindowObj *w = W(window);
    w->visible = YES;
    vxOnMain(^{ w.uiWindow.hidden = NO; });
}
VXAPI void glfwHideWindow(GLFWwindow *window) {
    if (!window || W(window)->offscreen) return;
    VXGLFWWindowObj *w = W(window);
    w->visible = NO;
    vxOnMain(^{ w.uiWindow.hidden = YES; });
}
VXAPI void glfwFocusWindow(GLFWwindow *window) {}
VXAPI void glfwRequestWindowAttention(GLFWwindow *window) {}
VXAPI GLFWmonitor *glfwGetWindowMonitor(GLFWwindow *window) {
    return window && !W(window)->offscreen ? &gMonitor : NULL;
}
VXAPI void glfwSetWindowMonitor(GLFWwindow *window, GLFWmonitor *monitor, int x, int y, int w, int h, int refresh) {}

VXAPI int glfwGetWindowAttrib(GLFWwindow *window, int attrib) {
    if (!window) return 0;
    VXGLFWWindowObj *w = W(window);
    switch (attrib) {
        case GLFW_FOCUSED: return w->focused;
        case GLFW_ICONIFIED: return GLFW_FALSE;
        case GLFW_MAXIMIZED: return !w->offscreen;
        case GLFW_HOVERED: return GLFW_TRUE;
        case GLFW_VISIBLE: return w->visible;
        case GLFW_RESIZABLE: return GLFW_FALSE;
        case GLFW_DECORATED: return GLFW_FALSE;
        case GLFW_FLOATING: return GLFW_FALSE;
        case GLFW_TRANSPARENT_FRAMEBUFFER: return GLFW_FALSE;
        case GLFW_FOCUS_ON_SHOW: return GLFW_TRUE;
        // Desktop GL is what callers get (via MobileGlues on top of the ES context).
        case GLFW_CLIENT_API: return w->hintClientAPI ? w->hintClientAPI : GLFW_OPENGL_API;
        case GLFW_CONTEXT_CREATION_API: return GLFW_EGL_CONTEXT_API;
        case GLFW_CONTEXT_VERSION_MAJOR: return w->hintMajor;
        case GLFW_CONTEXT_VERSION_MINOR: return w->hintMinor;
        case GLFW_CONTEXT_REVISION: return 0;
        case GLFW_OPENGL_FORWARD_COMPAT: return w->hintForward;
        case GLFW_OPENGL_PROFILE: return w->hintProfile;
        default: return 0;
    }
}
VXAPI void glfwSetWindowAttrib(GLFWwindow *window, int attrib, int value) {}
VXAPI void glfwSetWindowUserPointer(GLFWwindow *window, void *pointer) { if (window) W(window)->userPointer = pointer; }
VXAPI void *glfwGetWindowUserPointer(GLFWwindow *window) { return window ? W(window)->userPointer : NULL; }

#define SETCB(field, type)                       \
    if (!window) return NULL;                    \
    VXGLFWWindowObj *w = W(window);              \
    type prev = w->field;                        \
    w->field = callback;                         \
    return prev;

VXAPI GLFWwindowposfun glfwSetWindowPosCallback(GLFWwindow *window, GLFWwindowposfun callback) { SETCB(posCB, GLFWwindowposfun) }
VXAPI GLFWwindowsizefun glfwSetWindowSizeCallback(GLFWwindow *window, GLFWwindowsizefun callback) { SETCB(sizeCB, GLFWwindowsizefun) }
VXAPI GLFWwindowclosefun glfwSetWindowCloseCallback(GLFWwindow *window, GLFWwindowclosefun callback) { SETCB(closeCB, GLFWwindowclosefun) }
VXAPI GLFWwindowrefreshfun glfwSetWindowRefreshCallback(GLFWwindow *window, GLFWwindowrefreshfun callback) { SETCB(refreshCB, GLFWwindowrefreshfun) }
VXAPI GLFWwindowfocusfun glfwSetWindowFocusCallback(GLFWwindow *window, GLFWwindowfocusfun callback) { SETCB(focusCB, GLFWwindowfocusfun) }
VXAPI GLFWwindowiconifyfun glfwSetWindowIconifyCallback(GLFWwindow *window, GLFWwindowiconifyfun callback) { SETCB(iconifyCB, GLFWwindowiconifyfun) }
VXAPI GLFWwindowmaximizefun glfwSetWindowMaximizeCallback(GLFWwindow *window, GLFWwindowmaximizefun callback) { SETCB(maximizeCB, GLFWwindowmaximizefun) }
VXAPI GLFWframebuffersizefun glfwSetFramebufferSizeCallback(GLFWwindow *window, GLFWframebuffersizefun callback) { SETCB(fbCB, GLFWframebuffersizefun) }
VXAPI GLFWwindowcontentscalefun glfwSetWindowContentScaleCallback(GLFWwindow *window, GLFWwindowcontentscalefun callback) { SETCB(scaleCB, GLFWwindowcontentscalefun) }
VXAPI GLFWkeyfun glfwSetKeyCallback(GLFWwindow *window, GLFWkeyfun callback) { SETCB(keyCB, GLFWkeyfun) }
VXAPI GLFWcharfun glfwSetCharCallback(GLFWwindow *window, GLFWcharfun callback) { SETCB(charCB, GLFWcharfun) }
VXAPI GLFWcharmodsfun glfwSetCharModsCallback(GLFWwindow *window, GLFWcharmodsfun callback) { SETCB(charModsCB, GLFWcharmodsfun) }
VXAPI GLFWmousebuttonfun glfwSetMouseButtonCallback(GLFWwindow *window, GLFWmousebuttonfun callback) { SETCB(mouseCB, GLFWmousebuttonfun) }
VXAPI GLFWcursorposfun glfwSetCursorPosCallback(GLFWwindow *window, GLFWcursorposfun callback) { SETCB(cursorCB, GLFWcursorposfun) }
VXAPI GLFWcursorenterfun glfwSetCursorEnterCallback(GLFWwindow *window, GLFWcursorenterfun callback) { SETCB(enterCB, GLFWcursorenterfun) }
VXAPI GLFWscrollfun glfwSetScrollCallback(GLFWwindow *window, GLFWscrollfun callback) { SETCB(scrollCB, GLFWscrollfun) }
VXAPI GLFWdropfun glfwSetDropCallback(GLFWwindow *window, GLFWdropfun callback) { SETCB(dropCB, GLFWdropfun) }

#pragma mark - Event processing

static BOOL vxWindowAlive(void *window) {
    for (VXGLFWWindowObj *w in gWindows) if (H(w) == window) return YES;
    return NO;
}

static void vxDispatch(VXEvent e) {
    if (!vxWindowAlive(e.window)) return;
    VXGLFWWindowObj *w = W(e.window);
    GLFWwindow *h = e.window;
    switch (e.type) {
        case VXEventCursorPos:
            if (e.a == 1) {  // relative (captured cursor)
                w->cursorX += e.x;
                w->cursorY += e.y;
            } else {
                w->cursorX = e.x;
                w->cursorY = e.y;
            }
            if (w->cursorCB) w->cursorCB(h, w->cursorX, w->cursorY);
            break;
        case VXEventMouseButton:
            if (e.a >= 0 && e.a <= GLFW_MOUSE_BUTTON_LAST) w->buttons[e.a] = (char)e.b;
            if (w->mouseCB) w->mouseCB(h, e.a, e.b, 0);
            break;
        case VXEventScroll:
            if (w->scrollCB) w->scrollCB(h, e.x, e.y);
            break;
        case VXEventKey:
            if (e.a >= 0 && e.a <= GLFW_KEY_LAST) {
                int action = e.b;
                if (action == GLFW_PRESS && w->keys[e.a] == GLFW_PRESS) action = GLFW_REPEAT;
                w->keys[e.a] = (char)(e.b == GLFW_RELEASE ? GLFW_RELEASE : GLFW_PRESS);
                if (w->keyCB) w->keyCB(h, e.a, e.d, action, e.c);
            } else if (w->keyCB) {
                w->keyCB(h, GLFW_KEY_UNKNOWN, e.d, e.b, e.c);
            }
            break;
        case VXEventChar:
            if (w->charCB) w->charCB(h, (unsigned int)e.a);
            if (w->charModsCB) w->charModsCB(h, (unsigned int)e.a, e.c);
            break;
        case VXEventFramebufferSize:
            w->fbWidth = e.a;
            w->fbHeight = e.b;
            if (w->fbCB) w->fbCB(h, e.a, e.b);
            break;
        case VXEventWindowSize:
            w->width = e.a;
            w->height = e.b;
            if (w->sizeCB) w->sizeCB(h, e.a, e.b);
            break;
        case VXEventClose:
            w->shouldClose = YES;
            if (w->closeCB) w->closeCB(h);
            break;
        case VXEventFocus:
            w->focused = e.a != 0;
            if (w->focusCB) w->focusCB(h, e.a);
            break;
    }
}

static void vxDrain(void) {
    pthread_mutex_lock(&gEventLock);
    size_t n = gEventCount;
    VXEvent *batch = n ? malloc(n * sizeof(VXEvent)) : NULL;
    if (n) memcpy(batch, gEvents, n * sizeof(VXEvent));
    gEventCount = 0;
    gEmptyEventPosted = NO;
    pthread_mutex_unlock(&gEventLock);
    for (size_t i = 0; i < n; i++) vxDispatch(batch[i]);
    free(batch);
}

VXAPI void glfwPollEvents(void) { vxDrain(); }

static void vxWait(double timeout) {
    pthread_mutex_lock(&gEventLock);
    if (gEventCount == 0 && !gEmptyEventPosted) {
        if (timeout < 0) {
            pthread_cond_wait(&gEventCond, &gEventLock);
        } else {
            struct timespec ts;
            clock_gettime(CLOCK_REALTIME, &ts);
            double t = ts.tv_sec + ts.tv_nsec / 1e9 + timeout;
            ts.tv_sec = (time_t)t;
            ts.tv_nsec = (long)((t - ts.tv_sec) * 1e9);
            pthread_cond_timedwait(&gEventCond, &gEventLock, &ts);
        }
    }
    pthread_mutex_unlock(&gEventLock);
    vxDrain();
}

VXAPI void glfwWaitEvents(void) { vxWait(-1); }
VXAPI void glfwWaitEventsTimeout(double timeout) { vxWait(timeout > 0 ? timeout : 0); }
VXAPI void glfwPostEmptyEvent(void) {
    pthread_mutex_lock(&gEventLock);
    gEmptyEventPosted = YES;
    pthread_cond_signal(&gEventCond);
    pthread_mutex_unlock(&gEventLock);
}

#pragma mark - Input state

VXAPI int glfwGetInputMode(GLFWwindow *window, int mode) {
    if (!window) return 0;
    VXGLFWWindowObj *w = W(window);
    switch (mode) {
        case GLFW_CURSOR: return w->cursorMode;
        case GLFW_STICKY_KEYS: return w->stickyKeys;
        case GLFW_STICKY_MOUSE_BUTTONS: return w->stickyMouse;
        case GLFW_LOCK_KEY_MODS: return w->lockKeyMods;
        case GLFW_RAW_MOUSE_MOTION: return w->rawMotion;
        default: return 0;
    }
}

VXAPI void glfwSetInputMode(GLFWwindow *window, int mode, int value) {
    if (!window) return;
    VXGLFWWindowObj *w = W(window);
    switch (mode) {
        case GLFW_CURSOR:
            if (w->cursorMode != value) {
                NSLog(@"[VXGLFW] cursor mode 0x%X", value);
                // On-screen game controls only while the game captures the cursor.
                BOOL inGame = value == GLFW_CURSOR_DISABLED;
                VXControlsOverlay *overlay = w.view.overlay;
                dispatch_async(dispatch_get_main_queue(), ^{ overlay.inGame = inGame; });
            }
            w->cursorMode = value;
            break;
        case GLFW_STICKY_KEYS: w->stickyKeys = value; break;
        case GLFW_STICKY_MOUSE_BUTTONS: w->stickyMouse = value; break;
        case GLFW_LOCK_KEY_MODS: w->lockKeyMods = value; break;
        case GLFW_RAW_MOUSE_MOTION: w->rawMotion = value; break;
    }
}

VXAPI int glfwRawMouseMotionSupported(void) { return GLFW_TRUE; }

VXAPI const char *glfwGetKeyName(int key, int scancode) {
    static char names[GLFW_KEY_LAST + 1][2];
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
        names[key][0] = (char)('a' + (key - GLFW_KEY_A));
        return names[key];
    }
    if (key >= GLFW_KEY_0 && key <= GLFW_KEY_9) {
        names[key][0] = (char)('0' + (key - GLFW_KEY_0));
        return names[key];
    }
    switch (key) {
        case GLFW_KEY_MINUS: return "-";        case GLFW_KEY_EQUAL: return "=";
        case GLFW_KEY_LEFT_BRACKET: return "["; case GLFW_KEY_RIGHT_BRACKET: return "]";
        case GLFW_KEY_BACKSLASH: return "\\";   case GLFW_KEY_SEMICOLON: return ";";
        case GLFW_KEY_APOSTROPHE: return "'";   case GLFW_KEY_GRAVE_ACCENT: return "`";
        case GLFW_KEY_COMMA: return ",";        case GLFW_KEY_PERIOD: return ".";
        case GLFW_KEY_SLASH: return "/";
        default: return NULL;
    }
}

VXAPI int glfwGetKeyScancode(int key) {
    for (long usage = 0; usage < 0xE8; usage++) if (vxKeyFromHID(usage) == key && key != GLFW_KEY_UNKNOWN) return (int)usage;
    return -1;
}

VXAPI int glfwGetKey(GLFWwindow *window, int key) {
    if (!window || key < 0 || key > GLFW_KEY_LAST) return GLFW_RELEASE;
    return W(window)->keys[key] ? GLFW_PRESS : GLFW_RELEASE;
}

VXAPI int glfwGetMouseButton(GLFWwindow *window, int button) {
    if (!window || button < 0 || button > GLFW_MOUSE_BUTTON_LAST) return GLFW_RELEASE;
    return W(window)->buttons[button] ? GLFW_PRESS : GLFW_RELEASE;
}

VXAPI void glfwGetCursorPos(GLFWwindow *window, double *x, double *y) {
    if (x) *x = window ? W(window)->cursorX : 0;
    if (y) *y = window ? W(window)->cursorY : 0;
}

VXAPI void glfwSetCursorPos(GLFWwindow *window, double x, double y) {
    if (!window) return;
    W(window)->cursorX = x;
    W(window)->cursorY = y;
}

struct GLFWcursor { int shape; };

VXAPI GLFWcursor *glfwCreateCursor(const GLFWimage *image, int xhot, int yhot) {
    struct GLFWcursor *c = calloc(1, sizeof(*c));
    return c;
}
VXAPI GLFWcursor *glfwCreateStandardCursor(int shape) {
    struct GLFWcursor *c = calloc(1, sizeof(*c));
    c->shape = shape;
    return c;
}
VXAPI void glfwDestroyCursor(GLFWcursor *cursor) { free(cursor); }
VXAPI void glfwSetCursor(GLFWwindow *window, GLFWcursor *cursor) {}

#pragma mark - Joysticks (none yet)

VXAPI int glfwJoystickPresent(int jid) { return GLFW_FALSE; }
VXAPI const float *glfwGetJoystickAxes(int jid, int *count) { if (count) *count = 0; return NULL; }
VXAPI const unsigned char *glfwGetJoystickButtons(int jid, int *count) { if (count) *count = 0; return NULL; }
VXAPI const unsigned char *glfwGetJoystickHats(int jid, int *count) { if (count) *count = 0; return NULL; }
VXAPI const char *glfwGetJoystickName(int jid) { return NULL; }
VXAPI const char *glfwGetJoystickGUID(int jid) { return NULL; }
VXAPI void glfwSetJoystickUserPointer(int jid, void *pointer) {}
VXAPI void *glfwGetJoystickUserPointer(int jid) { return NULL; }
VXAPI int glfwJoystickIsGamepad(int jid) { return GLFW_FALSE; }
VXAPI GLFWjoystickfun glfwSetJoystickCallback(GLFWjoystickfun callback) {
    GLFWjoystickfun prev = gJoystickCallback;
    gJoystickCallback = callback;
    return prev;
}
VXAPI int glfwUpdateGamepadMappings(const char *string) { return GLFW_TRUE; }
VXAPI const char *glfwGetGamepadName(int jid) { return NULL; }
VXAPI int glfwGetGamepadState(int jid, GLFWgamepadstate *state) { return GLFW_FALSE; }

#pragma mark - Clipboard

VXAPI void glfwSetClipboardString(GLFWwindow *window, const char *string) {
    NSString *s = string ? @(string) : @"";
    vxOnMain(^{ UIPasteboard.generalPasteboard.string = s; });
}

VXAPI const char *glfwGetClipboardString(GLFWwindow *window) {
    __block NSString *s = nil;
    vxOnMain(^{ s = UIPasteboard.generalPasteboard.string; });
    gClipboard = s ?: @"";
    free(gClipboardC);
    gClipboardC = strdup(gClipboard.UTF8String);
    return gClipboardC;
}

#pragma mark - Time

static double vxNow(void) {
    uint64_t t = mach_absolute_time() - gTimerBase;
    return (double)t * gTimebase.numer / gTimebase.denom / 1e9;
}

VXAPI double glfwGetTime(void) { return gInitialized ? vxNow() - gTimerOffset : 0; }
VXAPI void glfwSetTime(double time) { gTimerOffset = vxNow() - time; }
VXAPI uint64_t glfwGetTimerValue(void) { return mach_absolute_time(); }
VXAPI uint64_t glfwGetTimerFrequency(void) {
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    return (uint64_t)(1e9 * tb.denom / tb.numer);
}

#pragma mark - Context

// gl4es (Minecraft 1.13 - 1.16.5) is built without an init constructor on Apple and
// has no GLX/EGL of its own here: it must be pointed at the GLES functions and
// initialised once a GLES context is current, before LWJGL makes its first GL call
// (without that, gl4es_glGetError dereferenced a NULL glstate on 1.16.5). Do that
// when the first context becomes current; LWJGL's later dlopen of the same path
// then gets this already-initialised copy. ANGLE's eglGetProcAddress returns every
// GLES entry point.
static void *vxGLESProc(const char *name) { return p_eglGetProcAddress ? (void *)p_eglGetProcAddress(name) : NULL; }

static void vxInitGL4ESIfUsed(void) {
    static BOOL done;
    if (done) return;
    done = YES;
    const char *lib = getenv("VOXELIUM_GL_LIBRARY");
    if (!lib || !strstr(lib, "gl4es")) return;
    void *h = dlopen(lib, RTLD_NOW | RTLD_LOCAL);
    if (!h) { NSLog(@"[VXGLFW] gl4es: dlopen failed: %s", dlerror()); return; }
    void (*setProc)(void *(*)(const char *)) = (void (*)(void *(*)(const char *)))dlsym(h, "set_getprocaddress");
    void (*init)(void) = (void (*)(void))dlsym(h, "initialize_gl4es");
    if (setProc) setProc(vxGLESProc);
    if (init) init();
    NSLog(@"[VXGLFW] gl4es initialised on the current ANGLE context (set_getprocaddress=%d, initialize_gl4es=%d)", setProc != NULL, init != NULL);
}

VXAPI void glfwMakeContextCurrent(GLFWwindow *window) {
    if (!gInitialized) return;
    VXGLFWWindowObj *w = window ? W(window) : nil;
    BOOL ok = w ? p_eglMakeCurrent(gDisplay, w->surface, w->surface, w->context)
                : p_eglMakeCurrent(gDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (!ok) {
        vxError(GLFW_PLATFORM_ERROR, "eglMakeCurrent failed: 0x%X", p_eglGetError());
        return;
    }
    tCurrent = w;
    if (w && !w->offscreen) vxInitGL4ESIfUsed();
}

VXAPI GLFWwindow *glfwGetCurrentContext(void) { return tCurrent ? H(tCurrent) : NULL; }

VXAPI void glfwSwapBuffers(GLFWwindow *window) {
    if (!window) return;
    VXGLFWWindowObj *w = W(window);
    if (!w->offscreen) {
        static uint64_t lastMemoryLog;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (now - lastMemoryLog > 10ull * NSEC_PER_SEC) {
            lastMemoryLog = now;
            vxLogMemory("in game");
        }
        if (atomic_load(&gInBackground)) {
            NSLog(@"[VXGLFW] in background: rendering paused");
            while (atomic_load(&gInBackground)) usleep(50 * 1000);
            NSLog(@"[VXGLFW] in foreground: rendering resumed");
        }
    }
#if VOXELIUM_ZINK_EXPERIMENT
    if (w.zink) {
        if (tCurrent != w || !vxZinkLoadGL()) return;
        // The framebuffer size follows the view (rotation); the pbuffer cannot, so
        // replace it. Minecraft draws into its own targets and blits to this one.
        VXZinkPresenter *z = w.zink;
        if (z->width != w->fbWidth || z->height != w->fbHeight) {
            EGLint pb[] = {EGL_WIDTH, w->fbWidth, EGL_HEIGHT, w->fbHeight, EGL_NONE};
            EGLSurface fresh = (z->width == 0) ? w->surface : p_eglCreatePbufferSurface(gDisplay, gPbufferConfig, pb);
            if (fresh == EGL_NO_SURFACE || !p_eglMakeCurrent(gDisplay, fresh, fresh, w->context)) {
                vxError(GLFW_PLATFORM_ERROR, "Zink: resizing the pbuffer to %dx%d failed: 0x%X", w->fbWidth, w->fbHeight, p_eglGetError());
                return;
            }
            if (fresh != w->surface) {
                p_eglDestroySurface(gDisplay, w->surface);
                w->surface = fresh;
            }
            EGLint ew = 0, eh = 0;
            p_eglQuerySurface(gDisplay, w->surface, EGL_WIDTH, &ew);
            p_eglQuerySurface(gDisplay, w->surface, EGL_HEIGHT, &eh);
            vxZinkPresenterResize(z, ew > 0 ? ew : w->fbWidth, eh > 0 ? eh : w->fbHeight);
        }
        vxZinkPresent(z);
        return;
    }
#endif
    if (!p_eglSwapBuffers(gDisplay, w->surface)) {
        vxError(GLFW_PLATFORM_ERROR, "eglSwapBuffers failed: 0x%X", p_eglGetError());
    }
}

VXAPI void glfwSwapInterval(int interval) {
    if (gInitialized && p_eglSwapInterval) p_eglSwapInterval(gDisplay, interval);
}

// Desktop GL entry points come from the GL library LWJGL loaded: MobileGlues, or
// gl4es for Minecraft 1.13 - 1.16.5 ($VOXELIUM_GL_LIBRARY, set by the launcher;
// MobileGlues when unset, e.g. in the GLFW test). gl4es exports no plain gl* names
// on Apple, only OSMesaGetProcAddress. Otherwise fall back to ANGLE's GLES ones.
static void *vxGLLibrary(void) {
    static void *lib;
    if (!lib) {
        const char *env = getenv("VOXELIUM_GL_LIBRARY");
        NSString *p = env ? @(env) : [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libmobileglues.dylib"];
        lib = dlopen(p.fileSystemRepresentation, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL);
    }
    return lib;
}

VXAPI GLFWglproc glfwGetProcAddress(const char *procname) {
    void *lib = vxGLLibrary();
    void *p = NULL;
    if (lib) {
        typedef void *(*Lookup)(const char *);
        Lookup osmesa = (Lookup)dlsym(lib, "OSMesaGetProcAddress");
        p = osmesa ? osmesa(procname) : NULL;
        if (!p) p = dlsym(lib, procname);
    }
    if (!p && p_eglGetProcAddress) p = (void *)p_eglGetProcAddress(procname);
    return (GLFWglproc)p;
}

VXAPI int glfwExtensionSupported(const char *extension) {
    typedef const unsigned char *(*GetStringi)(unsigned int, unsigned int);
    typedef void (*GetIntegerv)(unsigned int, int *);
    GetStringi getStringi = (GetStringi)glfwGetProcAddress("glGetStringi");
    GetIntegerv getIntegerv = (GetIntegerv)glfwGetProcAddress("glGetIntegerv");
    if (!getStringi || !getIntegerv || !extension) return GLFW_FALSE;
    int n = 0;
    getIntegerv(0x821D /* GL_NUM_EXTENSIONS */, &n);
    for (int i = 0; i < n; i++) {
        const unsigned char *e = getStringi(0x1F03 /* GL_EXTENSIONS */, (unsigned int)i);
        if (e && strcmp((const char *)e, extension) == 0) return GLFW_TRUE;
    }
    return GLFW_FALSE;
}

#pragma mark - Native access (GLFWNativeCocoa / GLFWNativeNSGL / GLFWNativeEGL)

// LWJGL's native-access classes require these symbols when first used.
// Minecraft's MacosUtil asks for the Cocoa window before toggling fullscreen
// and skips all AppKit calls when it is NULL, which it always is on iOS.
VXAPI uint32_t glfwGetCocoaMonitor(GLFWmonitor *monitor) { return 0; }
VXAPI void *glfwGetCocoaWindow(GLFWwindow *window) { return NULL; }
// GLFW 3.4; LWJGL 3.4.1's GLFWNativeCocoa requires it (Minecraft 26.2's MacosUtil loads
// that class: "A required function is missing: glfwGetCocoaView"). NULL like the window:
// MacosUtil then skips its NSWindow colour-space call.
VXAPI void *glfwGetCocoaView(GLFWwindow *window) { return NULL; }
VXAPI void *glfwGetNSGLContext(GLFWwindow *window) { return NULL; }
VXAPI EGLDisplay glfwGetEGLDisplay(void) { return gDisplay; }
VXAPI EGLContext glfwGetEGLContext(GLFWwindow *window) { return window ? W(window)->context : EGL_NO_CONTEXT; }
VXAPI EGLSurface glfwGetEGLSurface(GLFWwindow *window) { return window ? W(window)->surface : EGL_NO_SURFACE; }
VXAPI EGLConfig glfwGetEGLConfig(GLFWwindow *window) {
    if (!window) return NULL;
    return W(window)->offscreen ? gPbufferConfig : gWindowConfig;
}

#pragma mark - App-facing helpers

NSString *VXGLFWLibraryPath(void) { return NSBundle.mainBundle.executablePath; }

NSString *VXGLFWSelfCheck(void) {
    // LWJGL dlopen()s this path and dlsym()s every glfw* function from it.
    void *h = dlopen(VXGLFWLibraryPath().fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    if (!h) return [NSString stringWithFormat:@"dlopen(executable) FAILED: %s", dlerror()];
    void *init = dlsym(h, "glfwInit");
    void *swap = dlsym(h, "glfwSwapBuffers");
    return [NSString stringWithFormat:@"dlopen(executable) ok; glfwInit=%s glfwSwapBuffers=%s",
            init == (void *)glfwInit ? "ok" : (init ? "different address" : "missing"),
            swap == (void *)glfwSwapBuffers ? "ok" : (swap ? "different address" : "missing")];
}

// Minecraft 26.3+ draws through SDL3 and Vulkan, so glfwSwapBuffers never runs and
// cannot log memory. Log it on a timer instead (every 10 s), and on memory warnings
// (with a GC), until Stage 4 moves the overlay and gauge to the SDL path.
void VXStartMemoryLog(const char *label) {
    static dispatch_source_t timer;
    static dispatch_once_t once;
    const char *why = strdup(label);
    dispatch_once(&once, ^{
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{ vxLogMemory(why); });
        dispatch_resume(timer);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            vxLogMemory("iOS memory warning");
            VXJVMRequestGC("iOS memory warning");
        }];
    });
}
