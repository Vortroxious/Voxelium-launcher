// Touch controls, background pause and game pause for Minecraft 26.3+ on SDL3
// (VXSDLControls.h). The controls are the GLFW path's (VXTouchControls.m); here
// their input goes through SDL's keyboard and mouse code (SDL_Voxelium*, from
// patches/sdl3/0005), so the game sees it as a keyboard and a mouse.
//
// SDL is loaded by LWJGL from Minecraft's thread; everything here runs on the
// main thread and only looks SDL's functions up by name.

#import "VXSDLControls.h"
#import "VXTouchControls.h"

#import <UIKit/UIKit.h>
#include <dlfcn.h>
#include <stdatomic.h>

#define GLFW_INCLUDE_NONE
#include "glfw/GLFW/glfw3.h"

// patches/sdl3/0005 (SDL_uikitvoxelium.m)
static void (*p_SendKey)(int scancode, bool down);
static void (*p_SendText)(const char *utf8);
static void (*p_SendMouseButton)(uint8_t button, bool down);
static void (*p_SendMouseMotion)(bool relative, float x, float y);
static bool (*p_RelativeMouseMode)(void);
static void (*p_RequestClose)(void);
// scripts/vulkan-shim.c
static void (*p_SetVulkanPaused)(int paused);
static BOOL gVulkanPaused;

static NSString *gSDLPath, *gVulkanPath;
static bool vxEventWatch(void *userdata, void *event);

static BOOL vxLoadSDL(void) {
    if (p_SendKey) return YES;
    // Already loaded by LWJGL once the game window exists; this returns that image.
    void *h = dlopen(gSDLPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        NSLog(@"[VXSDL] cannot load %@: %s", gSDLPath.lastPathComponent, dlerror());
        return NO;
    }
    p_SendMouseButton = dlsym(h, "SDL_VoxeliumSendMouseButton");
    p_SendMouseMotion = dlsym(h, "SDL_VoxeliumSendMouseMotion");
    p_SendText = dlsym(h, "SDL_VoxeliumSendText");
    p_RelativeMouseMode = dlsym(h, "SDL_VoxeliumRelativeMouseMode");
    p_RequestClose = dlsym(h, "SDL_VoxeliumRequestClose");
    p_SendKey = dlsym(h, "SDL_VoxeliumSendKey");
    bool (*addWatch)(bool (*)(void *, void *), void *) = dlsym(h, "SDL_AddEventWatch");
    if (addWatch) addWatch(vxEventWatch, NULL);
    if (!p_SendKey || !p_SendMouseButton || !p_SendMouseMotion || !p_SendText || !p_RelativeMouseMode || !p_RequestClose) {
        NSLog(@"[VXSDL] %@ has no Voxelium input hooks (patches/sdl3/0005); touch controls off", gSDLPath.lastPathComponent);
        p_SendKey = NULL;
        return NO;
    }
    return YES;
}

static void vxSetVulkanPaused(BOOL paused) {
    if (!p_SetVulkanPaused) {
        void *h = dlopen(gVulkanPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        p_SetVulkanPaused = h ? dlsym(h, "vx_vulkan_set_paused") : NULL;
        if (!p_SetVulkanPaused) {
            NSLog(@"[VXSDL] %@ cannot pause rendering (no vx_vulkan_set_paused)", gVulkanPath.lastPathComponent);
            return;
        }
    }
    p_SetVulkanPaused(paused);
    gVulkanPaused = paused;
}

// GLFW key (the controls' layouts) -> SDL scancode (USB HID usage), 0 if none.
static int vxScancode(int key) {
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) return 4 + (key - GLFW_KEY_A);
    if (key >= GLFW_KEY_1 && key <= GLFW_KEY_9) return 30 + (key - GLFW_KEY_1);
    if (key >= GLFW_KEY_F1 && key <= GLFW_KEY_F12) return 58 + (key - GLFW_KEY_F1);
    if (key >= GLFW_KEY_KP_1 && key <= GLFW_KEY_KP_9) return 89 + (key - GLFW_KEY_KP_1);
    switch (key) {
        case GLFW_KEY_0: return 39;              case GLFW_KEY_ENTER: return 40;
        case GLFW_KEY_ESCAPE: return 41;         case GLFW_KEY_BACKSPACE: return 42;
        case GLFW_KEY_TAB: return 43;            case GLFW_KEY_SPACE: return 44;
        case GLFW_KEY_MINUS: return 45;          case GLFW_KEY_EQUAL: return 46;
        case GLFW_KEY_LEFT_BRACKET: return 47;   case GLFW_KEY_RIGHT_BRACKET: return 48;
        case GLFW_KEY_BACKSLASH: return 49;      case GLFW_KEY_SEMICOLON: return 51;
        case GLFW_KEY_APOSTROPHE: return 52;     case GLFW_KEY_GRAVE_ACCENT: return 53;
        case GLFW_KEY_COMMA: return 54;          case GLFW_KEY_PERIOD: return 55;
        case GLFW_KEY_SLASH: return 56;          case GLFW_KEY_CAPS_LOCK: return 57;
        case GLFW_KEY_PRINT_SCREEN: return 70;   case GLFW_KEY_SCROLL_LOCK: return 71;
        case GLFW_KEY_PAUSE: return 72;          case GLFW_KEY_INSERT: return 73;
        case GLFW_KEY_HOME: return 74;           case GLFW_KEY_PAGE_UP: return 75;
        case GLFW_KEY_DELETE: return 76;         case GLFW_KEY_END: return 77;
        case GLFW_KEY_PAGE_DOWN: return 78;      case GLFW_KEY_RIGHT: return 79;
        case GLFW_KEY_LEFT: return 80;           case GLFW_KEY_DOWN: return 81;
        case GLFW_KEY_UP: return 82;             case GLFW_KEY_NUM_LOCK: return 83;
        case GLFW_KEY_KP_DIVIDE: return 84;      case GLFW_KEY_KP_MULTIPLY: return 85;
        case GLFW_KEY_KP_SUBTRACT: return 86;    case GLFW_KEY_KP_ADD: return 87;
        case GLFW_KEY_KP_ENTER: return 88;       case GLFW_KEY_KP_0: return 98;
        case GLFW_KEY_KP_DECIMAL: return 99;     case GLFW_KEY_KP_EQUAL: return 103;
        case GLFW_KEY_MENU: return 118;
        case GLFW_KEY_LEFT_CONTROL: return 224;  case GLFW_KEY_LEFT_SHIFT: return 225;
        case GLFW_KEY_LEFT_ALT: return 226;      case GLFW_KEY_LEFT_SUPER: return 227;
        case GLFW_KEY_RIGHT_CONTROL: return 228; case GLFW_KEY_RIGHT_SHIFT: return 229;
        case GLFW_KEY_RIGHT_ALT: return 230;     case GLFW_KEY_RIGHT_SUPER: return 231;
        default: return 0;
    }
}

// GLFW mouse button -> SDL button (SDL_BUTTON_LEFT 1, MIDDLE 2, RIGHT 3, X1 4, X2 5).
static uint8_t vxSDLButton(int button) {
    switch (button) {
        case GLFW_MOUSE_BUTTON_LEFT: return 1;
        case GLFW_MOUSE_BUTTON_RIGHT: return 3;
        case GLFW_MOUSE_BUTTON_MIDDLE: return 2;
        default: return (uint8_t)(button + 1);
    }
}

// The render scale SDL applies (patches/sdl3/0005 reads the same variable).
static CGFloat vxRenderScale(void) {
    const char *s = getenv("VOXELIUM_RENDER_SCALE");
    double v = s ? atof(s) : 1.0;
    return (v > 0.1 && v <= 1.0) ? v : 1.0;
}

@interface VXSDLSink : NSObject <VXInputSink>
@property (nonatomic, weak) UIView *view;   // SDL's view (the game window's content)
@end

@implementation VXSDLSink
- (void)vxKey:(int)key action:(int)action {
    int sc = vxScancode(key);
    if (sc && p_SendKey) p_SendKey(sc, action != GLFW_RELEASE);
}
- (void)vxMouseButton:(int)button action:(int)action {
    if (p_SendMouseButton) p_SendMouseButton(vxSDLButton(button), action != GLFW_RELEASE);
}
- (void)vxChar:(UInt32)codepoint {
    if (!p_SendText) return;
    NSString *s = [[NSString alloc] initWithBytes:&codepoint length:sizeof(codepoint) encoding:NSUTF32LittleEndianStringEncoding];
    if (s.length) p_SendText(s.UTF8String);
}
- (void)vxCursorAt:(CGPoint)p {
    if (p_SendMouseMotion) p_SendMouseMotion(false, (float)p.x, (float)p.y);
}
- (void)vxCursorDelta:(CGPoint)d {
    if (p_SendMouseMotion) p_SendMouseMotion(true, (float)d.x, (float)d.y);
}
- (void)vxQuit {
    NSLog(@"[VXSDL] Quit game (runtime menu): asking the game window to close");
    if (p_RequestClose) p_RequestClose();
}
- (BOOL)vxInGame { return p_RelativeMouseMode && p_RelativeMouseMode(); }
- (CGFloat)vxPixelsPerPoint { return UIScreen.mainScreen.nativeScale * vxRenderScale(); }
- (CGSize)vxFramebufferSize {
    CGSize s = self.view.bounds.size;
    CGFloat k = self.vxPixelsPerPoint;
    return CGSizeMake((int)(s.width * k), (int)(s.height * k));  // SDL truncates the same way
}
@end

static VXSDLSink *gSink;
static VXTouchView *gTouchView;
static NSTimer *gTimer;
static UIBackgroundTaskIdentifier gBackgroundTask;
static BOOL gHasBackgroundTask;

#pragma mark - Diagnostics (app state, SDL's quit and window events, main-thread stalls)

static void vxNote(NSString *what) {
    NSLog(@"[VXSDL] %@ (controls %s, in game %d, rendering %s)", what, gTouchView ? "on" : "off",
          gTouchView ? gSink.vxInGame : 0, gVulkanPaused ? "paused" : "running");
}

// Every SDL event that can end or pause the game, as SDL posts it (on the posting
// thread), with where it came from for the ones that make Minecraft quit:
// SDL_EVENT_QUIT and SDL_EVENT_WINDOW_CLOSE_REQUESTED (Window.onQuitRequested) and
// SDL_EVENT_TERMINATING (Window.requestClose).
static bool vxEventWatch(void *userdata, void *event) {
    const uint8_t *e = event;
    uint32_t type = *(const uint32_t *)e;
    const char *name = NULL;
    switch (type) {
        case 0x100: name = "QUIT"; break;
        case 0x101: name = "TERMINATING"; break;
        case 0x102: name = "LOW_MEMORY"; break;
        case 0x103: name = "WILL_ENTER_BACKGROUND"; break;
        case 0x104: name = "DID_ENTER_BACKGROUND"; break;
        case 0x105: name = "WILL_ENTER_FOREGROUND"; break;
        case 0x106: name = "DID_ENTER_FOREGROUND"; break;
        case 0x206: name = "WINDOW_RESIZED"; break;
        case 0x207: name = "WINDOW_PIXEL_SIZE_CHANGED"; break;
        case 0x209: name = "WINDOW_MINIMIZED"; break;
        case 0x20B: name = "WINDOW_RESTORED"; break;
        case 0x20E: name = "WINDOW_FOCUS_GAINED"; break;
        case 0x20F: name = "WINDOW_FOCUS_LOST"; break;
        case 0x210: name = "WINDOW_CLOSE_REQUESTED"; break;
        default: return true;
    }
    int32_t d1 = *(const int32_t *)(e + 20), d2 = *(const int32_t *)(e + 24);   // SDL_WindowEvent data1/data2
    if (type >= 0x200) NSLog(@"[VXSDL] SDL event %s %d,%d (thread %@)", name, d1, d2, NSThread.isMainThread ? @"main" : @"other");
    else NSLog(@"[VXSDL] SDL event %s (thread %@)", name, NSThread.isMainThread ? @"main" : @"other");
    if (type == 0x100 || type == 0x101 || type == 0x210) {
        NSArray<NSString *> *stack = NSThread.callStackSymbols;
        NSLog(@"[VXSDL]   sent from: %@", [[stack subarrayWithRange:NSMakeRange(0, MIN(stack.count, 14))] componentsJoinedByString:@" | "]);
    }
    return true;
}

// The main thread runs vxTick 20 times a second; a background thread reports when
// it stops doing so for more than 2 s (a hang), and when it is back.
static _Atomic uint64_t gLastTick;
static void vxStartStallWatch(void) {
    static dispatch_source_t t;
    t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(t, ^{
        static BOOL stalled;
        uint64_t last = gLastTick, now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (!last) return;
        if (now - last > 2 * NSEC_PER_SEC && !stalled) {
            stalled = YES;
            NSLog(@"[VXSDL] main thread has not run for %llu ms", (now - last) / NSEC_PER_MSEC);
        } else if (now - last < NSEC_PER_SEC && stalled) {
            stalled = NO;
            NSLog(@"[VXSDL] main thread running again");
        }
    });
    dispatch_resume(t);
}

// SDL's game window: a UIWindow whose root view controller is SDL's.
static UIViewController *vxFindSDLViewController(void) {
    Class sdlClass = NSClassFromString(@"SDL_uikitviewcontroller");
    if (!sdlClass) return nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && [window.rootViewController isKindOfClass:sdlClass]) return window.rootViewController;
        }
    }
    return nil;
}

static void vxDetach(void) {
    if (!gTouchView) return;
    NSLog(@"[VXSDL] game window gone; touches: %@", VXTouchStats());
    [gTouchView removeFromSuperview];
    gTouchView = nil;
}

static void vxAttach(UIViewController *vc) {
    if (!vxLoadSDL()) return;
    UIView *host = vc.view;
    gSink = [VXSDLSink new];
    gSink.view = host;
    VXTouchView *view = [[VXTouchView alloc] initWithFrame:host.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.backgroundColor = UIColor.clearColor;
    view.multipleTouchEnabled = YES;
    view.sink = gSink;
    VXControlsOverlay *overlay = [[VXControlsOverlay alloc] initWithOwner:gSink];
    overlay.gameView = host;   // SDL's view takes the hardware keyboard
    overlay.multipleTouchEnabled = YES;
    view.overlay = overlay;
    [view addSubview:overlay];
    [host addSubview:view];
    gTouchView = view;
    CGSize fb = gSink.vxFramebufferSize;
    NSLog(@"[VXSDL] touch controls on the game window: %.0fx%.0f pt, framebuffer %.0fx%.0f px (render scale %.2f)",
          host.bounds.size.width, host.bounds.size.height, fb.width, fb.height, vxRenderScale());
}

// Main-thread poll (20 Hz): attach to the game window when it appears, keep the
// controls above SDL's Metal view (added when Minecraft creates its Vulkan
// surface), and show the game controls while the game has captured the mouse.
static void vxTick(void) {
    gLastTick = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    UIViewController *vc = vxFindSDLViewController();
    if (gTouchView && gTouchView.superview != vc.view) vxDetach();
    if (!gTouchView && vc) vxAttach(vc);
    if (!gTouchView) return;
    UIView *host = gTouchView.superview;
    if (host.subviews.lastObject != gTouchView) [host bringSubviewToFront:gTouchView];
    gTouchView.overlay.inGame = gSink.vxInGame;
}

static void vxEndBackgroundTask(void) {
    if (!gHasBackgroundTask) return;
    gHasBackgroundTask = NO;
    [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
}

static void vxObserveLifecycle(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    NSOperationQueue *main = NSOperationQueue.mainQueue;
    // As in VXGLFW: in the world, Escape opens the pause menu, which pauses and saves.
    // Registered before SDL_Init, so this runs before SDL drops keyboard focus.
    [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        vxNote(@"app resigning active");
        if (!gTouchView || !gSink.vxInGame) return;
        [gSink vxKey:GLFW_KEY_ESCAPE action:GLFW_PRESS];
        [gSink vxKey:GLFW_KEY_ESCAPE action:GLFW_RELEASE];
        NSLog(@"[VXSDL] app resigning active: sent ESC to pause and save");
    }];
    // iOS refuses GPU work from background apps, and Minecraft keeps rendering while
    // minimized: hold its Vulkan submits and presents until the app is back. The
    // integrated server keeps saving meanwhile; a background task gives it 8 s.
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        vxNote(@"app entered background");
        if (!gTouchView) return;
        vxSetVulkanPaused(YES);
        if (!gHasBackgroundTask) {
            gBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Minecraft save"
                                                                         expirationHandler:^{ vxEndBackgroundTask(); }];
            gHasBackgroundTask = gBackgroundTask != UIBackgroundTaskInvalid;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ vxEndBackgroundTask(); });
        }
        NSLog(@"[VXSDL] app in background: rendering paused, holding a background task for 8 s");
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        vxNote(@"app entering foreground");
        if (gVulkanPaused) vxSetVulkanPaused(NO);
        vxEndBackgroundTask();
    }];
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        vxNote(@"app active");
    }];
    [nc addObserverForName:UIApplicationWillTerminateNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        vxNote(@"app being terminated by iOS");
    }];
    [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:main usingBlock:^(NSNotification *n) {
        static uint64_t lastNotice;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (gTouchView && now - lastNotice > 60ull * NSEC_PER_SEC) {   // at most once a minute
            lastNotice = now;
            NSLog(@"[VXMEM] showing the low-memory notice in game");
            [gTouchView.overlay showNotice:@"Memory is almost full. Lower the render distance "
                                           @"(Options → Video Settings) to avoid a crash."];
        }
    }];
}

void VXSDLControlsStart(NSString *sdlLibraryPath, NSString *vulkanLibraryPath) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gSDLPath = [sdlLibraryPath copy];
        gVulkanPath = [vulkanLibraryPath copy];
        vxObserveLifecycle();
        gTimer = [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) { vxTick(); }];
        vxStartStallWatch();
    });
}
